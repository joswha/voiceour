"""Opt-in beam n-best decoding for the Parakeet-TDT MLX model.

The default production decode path stays greedy (see
:meth:`parakeet_mlx.parakeet.ParakeetTDT.decode_greedy`); this module adds a
richer beam decoder that surfaces a *ranked* top-k list of hypotheses instead of
collapsing the beam to a single best path the way the upstream
:meth:`ParakeetTDT.decode_beam` does. Each returned hypothesis carries both a
``score`` (used for ranking) and a ``raw_score`` (the pre-bias path score).
With no biasing applied the two are identical. When a
:class:`~voiceoour_asr.decoding.trie.PhraseTrie` bias is supplied (opt-in),
:meth:`NBestParakeetTDT.decode_beam_nbest` adds the trie's shallow-fusion delta
into ``score`` *before* the beam selection step -- boosting the logprobs of
naturally explored tokens that continue a bias phrase -- while ``raw_score``
keeps the model's own summed token/duration logprob path score untouched.
Ranking then reflects the bias, but ``raw_score`` never conflates
decoder-biased support with independent acoustic evidence.

Shallow-fusion biasing (perturbing the search via the trie) is distinct from
*forced candidate scoring* (injecting a bias phrase as a full hypothesis the
beam never explored and fabricating a model score for it), which remains
unimplemented; see :data:`FORCED_CANDIDATE_SCORING_AVAILABLE` and
:func:`forced_candidate_scoring_note`.

The pure ranking logic (:func:`rank_hypotheses`) is separated from the MLX beam
search so it can be unit-tested on synthetic hypotheses without a checkpoint or
any GPU work.
"""

from __future__ import annotations

import math
import typing
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from parakeet_mlx.alignment import AlignedToken
from parakeet_mlx.parakeet import Beam, DecodingConfig, ParakeetTDT

from voiceoour_asr.decoding import text_from_tokens

if TYPE_CHECKING:  # pragma: no cover - typing only; PhraseTrie is passed in
    from voiceoour_asr.decoding.trie import PhraseTrie

__all__ = [
    "NBestHypothesis",
    "rank_hypotheses",
    "NBestParakeetTDT",
    "build_nbest_model",
    "DEFAULT_BEAM_SIZE",
    "FORCED_CANDIDATE_SCORING_AVAILABLE",
    "forced_candidate_scoring_note",
]

DEFAULT_BEAM_SIZE = 5


def _logaddexp(a: float, b: float) -> float:
    """Numerically stable ``log(exp(a) + exp(b))`` for beam recombination."""
    m = a if a > b else b
    return m + math.log(math.exp(a - m) + math.exp(b - m))


#: Forced-candidate scoring would require force-decoding a bias phrase's token
#: ids through the model to fabricate a score for a hypothesis the beam never
#: explored; only shallow-fusion trie biasing (over vocabulary.py-segmented ids)
#: is implemented, so the capability is reported as unavailable.
FORCED_CANDIDATE_SCORING_AVAILABLE = False


def forced_candidate_scoring_note() -> str:
    """Return the honest feasibility note for forced-candidate scoring."""
    return (
        "Forced candidate scoring is not implemented: adding a bias phrase to "
        "the beam as a full hypothesis it never explored would require "
        "force-decoding the phrase's token ids through the model to fabricate a "
        "score. Shallow-fusion Biasing -- boosting the logprobs of naturally "
        "explored tokens via a PhraseTrie over segmented token ids -- is used "
        "instead (see decode_beam_nbest's `bias` argument)."
    )


@dataclass
class NBestHypothesis:
    """A ranked beam hypothesis exposed to the wire layer.

    ``score`` is the (length-normalizable) beam log-prob used for ranking.
    ``raw_score`` is the pre-bias score; it equals ``score`` whenever no biasing
    has been applied.
    """

    text: str
    score: float
    raw_score: float
    tokens: list[AlignedToken] = field(default_factory=list)


def rank_hypotheses(
    candidates: Sequence[NBestHypothesis],
    *,
    top_k: int,
    length_penalty: float = 0.0,
) -> list[NBestHypothesis]:
    """Rank beam hypotheses best-first and keep at most ``top_k``.

    Ranking is by length-normalized ``score`` (``score / len(tokens)**penalty``),
    matching the selection upstream ``decode_beam`` uses for its single best
    pick. ``raw_score`` is never consulted for ordering: it is the pre-bias
    score carried through untouched, so once biasing shifts ``score`` the
    original model score is still reported. Ties preserve input order (stable
    sort), and ``top_k`` is clamped to ``[0, len(candidates)]``.
    """
    if top_k <= 0:
        return []

    def normalized(hyp: NBestHypothesis) -> float:
        length = max(1, len(hyp.tokens))
        return hyp.score / (length**length_penalty)

    ordered = sorted(candidates, key=normalized, reverse=True)
    return ordered[:top_k]


def build_nbest_model(model: object) -> NBestParakeetTDT:
    """Promote an already-loaded ``ParakeetTDT`` to expose n-best beam decoding.

    The n-best methods are purely additive, so we rebind the instance's class in
    place instead of reloading weights or spinning up a second MLX context. This
    keeps all Metal work on the caller's single dedicated MLX thread and adds no
    load latency. ``ParakeetTDTCTC`` (a ``ParakeetTDT`` subclass) is accepted;
    only the TDT decode path is exercised and its instance state is preserved.
    """
    if isinstance(model, NBestParakeetTDT):
        return model
    if not isinstance(model, ParakeetTDT):
        raise TypeError(f"beam n-best decoding requires a ParakeetTDT model, got {type(model).__name__}")
    model.__class__ = NBestParakeetTDT
    return typing.cast("NBestParakeetTDT", model)


class NBestParakeetTDT(ParakeetTDT):
    """``ParakeetTDT`` that can emit a ranked beam n-best instead of one path."""

    def decode_beam_nbest(
        self,
        features,
        lengths=None,
        last_token=None,
        hidden_state=None,
        *,
        # noqa is deliberate: this method is a fork of upstream
        # ParakeetTDT.decode_beam and mirrors its signature, including this
        # default. The shared instance is only read here -- nothing in this
        # method assigns to a `config` attribute -- so the usual mutable-default
        # hazard does not apply.
        config: DecodingConfig = DecodingConfig(),  # noqa: B008
        top_k: int = DEFAULT_BEAM_SIZE,
        bias: PhraseTrie | None = None,
    ):
        """Fork of :meth:`ParakeetTDT.decode_beam` returning ranked top-k.

        The beam search loop mirrors upstream. Two things differ: (1) selection
        keeps every finished hypothesis as an :class:`NBestHypothesis` ranked via
        :func:`rank_hypotheses` instead of collapsing to a single best; (2) when
        ``bias`` is a :class:`~voiceoour_asr.decoding.trie.PhraseTrie`, its
        per-token delta is injected into each candidate's ``score`` *before* the
        beam selection step and the trie state is threaded through every
        hypothesis, while ``raw_score`` keeps the summed pre-bias token/duration
        logprob path score. ``score`` (biased) drives ranking; ``raw_score``
        stays the model's own evidence. With ``bias is None`` the two scores are
        identical and the result matches the unbiased fork.

        Returns ``(per_batch_ranked, per_batch_hidden)`` where
        ``per_batch_ranked`` is a list (one entry per batch item) of ranked
        ``NBestHypothesis`` lists.
        """
        import mlx.core as mx
        import mlx.nn as nn
        from parakeet_mlx import tokenizer

        assert isinstance(config.decoding, Beam)  # type guarantee

        beam_token = min(config.decoding.beam_size, len(self.vocabulary) + 1)
        beam_duration = min(config.decoding.beam_size, len(self.durations))
        max_candidates = round(config.decoding.beam_size * config.decoding.patience)
        root_state = bias.root if bias is not None else 0

        @dataclass
        class _Hyp:
            score: float
            raw_score: float
            step: int
            last_token: int | None
            hidden_state: tuple | None
            stuck: int
            trie_state: int
            hypothesis: list[AlignedToken]

            def __hash__(self) -> int:
                return hash((self.step, tuple(x.id for x in self.hypothesis)))

        B, S, *_ = features.shape

        if hidden_state is None:
            hidden_state = list([None] * B)
        if lengths is None:
            lengths = mx.array([S] * B)
        if last_token is None:
            last_token = list([None] * B)

        results: list[list[NBestHypothesis]] = []
        results_hidden = []
        for batch in range(B):
            feature = features[batch : batch + 1]
            length = int(lengths[batch])

            finished_hypothesis: list[_Hyp] = []
            active_beam: list[_Hyp] = [
                _Hyp(
                    score=0.0,
                    raw_score=0.0,
                    step=0,
                    last_token=last_token[batch],
                    hidden_state=hidden_state[batch],
                    stuck=0,
                    trie_state=root_state,
                    hypothesis=[],
                )
            ]

            while len(finished_hypothesis) < max_candidates and active_beam:
                candidates: dict[int, _Hyp] = {}

                for hypothesis in active_beam:
                    decoder_out, (hidden, cell) = self.decoder(
                        mx.array([[hypothesis.last_token]]) if hypothesis.last_token is not None else None,
                        hypothesis.hidden_state,
                    )
                    decoder_out = decoder_out.astype(feature.dtype)
                    decoder_hidden = (
                        hidden.astype(feature.dtype),
                        cell.astype(feature.dtype),
                    )

                    joint_out = self.joint(feature[:, hypothesis.step : hypothesis.step + 1], decoder_out)

                    token_logits, duration_logits = (
                        joint_out[0, 0, 0, : len(self.vocabulary) + 1],
                        joint_out[0, 0, 0, len(self.vocabulary) + 1 :],
                    )
                    token_logprobs, duration_logprobs = (
                        nn.log_softmax(token_logits, -1),
                        nn.log_softmax(duration_logits, -1),
                    )

                    token_k, duration_k = (
                        typing.cast(
                            list[int],
                            mx.argpartition(token_logprobs, -beam_token)[-beam_token:].tolist(),
                        ),
                        typing.cast(
                            list[int],
                            mx.argpartition(duration_logprobs, -beam_duration)[-beam_duration:].tolist(),
                        ),
                    )

                    token_logprobs = typing.cast(list[float], token_logprobs.tolist())
                    duration_logprobs = typing.cast(list[float], duration_logprobs.tolist())

                    for token in token_k:
                        is_blank = token == len(self.vocabulary)
                        # Shallow-fusion bias: advance the phrase trie on the
                        # emitted (non-blank) token. Blank/duration decisions are
                        # search no-ops and never perturb the bias state.
                        if bias is not None and not is_blank:
                            next_trie_state, bias_delta = bias.advance(hypothesis.trie_state, token)
                        else:
                            next_trie_state, bias_delta = hypothesis.trie_state, 0.0
                        for decision in duration_k:
                            duration = self.durations[decision]
                            stuck = 0 if duration != 0 else hypothesis.stuck + 1

                            if self.max_symbols is not None and stuck >= self.max_symbols:
                                step = hypothesis.step + 1
                                stuck = 0
                            else:
                                step = hypothesis.step + duration

                            raw_increment = token_logprobs[token] * (
                                1 - config.decoding.duration_reward
                            ) + duration_logprobs[decision] * (config.decoding.duration_reward)

                            new_hypothesis = _Hyp(
                                # score carries the running bias delta; raw_score
                                # keeps the pure pre-bias path score.
                                score=hypothesis.score + raw_increment + bias_delta,
                                raw_score=hypothesis.raw_score + raw_increment,
                                step=step,
                                last_token=hypothesis.last_token if is_blank else token,
                                hidden_state=hypothesis.hidden_state if is_blank else decoder_hidden,
                                stuck=stuck,
                                trie_state=hypothesis.trie_state if is_blank else next_trie_state,
                                hypothesis=hypothesis.hypothesis
                                if is_blank
                                else (
                                    list(hypothesis.hypothesis)
                                    + [
                                        AlignedToken(
                                            id=token,
                                            start=hypothesis.step * self.time_ratio,
                                            duration=duration * self.time_ratio,
                                            confidence=math.exp(token_logprobs[token] + duration_logprobs[decision]),
                                            text=tokenizer.decode([token], self.vocabulary),
                                        )
                                    ]
                                ),
                            )

                            key = hash(new_hypothesis)
                            if key in candidates:
                                other_hypothesis = candidates[key]
                                # Recombine paths reaching the same (step, tokens)
                                # state: marginalize both scores by log-sum-exp.
                                # The token sequence is identical, so the trie
                                # state matches and raw_score stays consistent.
                                score = _logaddexp(other_hypothesis.score, new_hypothesis.score)
                                raw_score = _logaddexp(
                                    other_hypothesis.raw_score,
                                    new_hypothesis.raw_score,
                                )
                                if new_hypothesis.score > other_hypothesis.score:
                                    candidates[key] = new_hypothesis
                                candidates[key].score = score
                                candidates[key].raw_score = raw_score
                            else:
                                candidates[key] = new_hypothesis

                finished_hypothesis.extend(
                    [hypothesis for hypothesis in candidates.values() if hypothesis.step >= length]
                )
                active_beam = sorted(
                    [hypothesis for hypothesis in candidates.values() if hypothesis.step < length],
                    key=lambda x: x.score,
                    reverse=True,
                )[: config.decoding.beam_size]

            finished_hypothesis = finished_hypothesis + active_beam

            nbest = [
                NBestHypothesis(
                    text=text_from_tokens(hyp.hypothesis),
                    score=hyp.score,
                    raw_score=hyp.raw_score,
                    tokens=hyp.hypothesis,
                )
                for hyp in finished_hypothesis
            ]
            results.append(rank_hypotheses(nbest, top_k=top_k, length_penalty=config.decoding.length_penalty))
            results_hidden.append(hidden_state[batch])

        return results, results_hidden

    def generate_nbest(
        self,
        mel,
        *,
        decoding_config: DecodingConfig,
        top_k: int = DEFAULT_BEAM_SIZE,
        bias: PhraseTrie | None = None,
    ):
        """Beam-decode ``mel`` and return per-batch ranked hypotheses.

        Each returned entry is a list of ``(AlignedResult, score, raw_score)``
        tuples ordered best-first, mirroring :meth:`ParakeetTDT.generate` but for
        the full ranked beam rather than a single result. An optional ``bias``
        :class:`~voiceoour_asr.decoding.trie.PhraseTrie` is forwarded to
        :meth:`decode_beam_nbest` for opt-in shallow-fusion biasing.
        """
        import mlx.core as mx
        from parakeet_mlx.alignment import sentences_to_result, tokens_to_sentences

        if len(mel.shape) == 2:
            mel = mx.expand_dims(mel, 0)

        features, lengths = self.encoder(mel)
        mx.eval(features, lengths)

        per_batch, _ = self.decode_beam_nbest(features, lengths, config=decoding_config, top_k=top_k, bias=bias)

        out = []
        for hyps in per_batch:
            ranked = [
                (
                    sentences_to_result(tokens_to_sentences(hyp.tokens, decoding_config.sentence)),
                    hyp.score,
                    hyp.raw_score,
                )
                for hyp in hyps
            ]
            out.append(ranked)
        return out
