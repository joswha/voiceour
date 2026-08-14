"""Decoder-bias (shallow-fusion) tests.

These cover the opt-in biased beam decode end to end without a downloaded
checkpoint:

* the beam n-best fork (:meth:`NBestParakeetTDT.decode_beam_nbest`) is driven
  with a synthetic tiny TDT stand-in that supplies precomputed ``features`` and
  fixed joint logits -- no encoder, no weights, no Metal;
* the MLX backend wiring (:meth:`MLXBackend.transcribe`) is exercised with a
  fake model exposing only ``vocabulary`` plus a recording executor, so the
  cap, the unrepresentable-skip, the snapshot threading, and the
  single-submission-on-the-MLX-thread invariant are all observable.

The greedy default path and the unbiased beam fork stay byte-identical: with no
bias every hypothesis keeps ``raw_score == score`` and biasing is never entered.
"""

from __future__ import annotations

import wave
from threading import Event

import mlx.core as mx
import pytest
from parakeet_mlx.alignment import AlignedResult
from parakeet_mlx.parakeet import Beam, DecodingConfig

from voiceoour_asr.backends.mlx import MAX_BIAS_PHRASES, MLXBackend, _DecodeOutput
from voiceoour_asr.decoding.nbest import NBestParakeetTDT
from voiceoour_asr.decoding.trie import PhraseTrie
from voiceoour_asr.decoding.vocabulary import WORD_BOUNDARY_MARKER, PieceVocabulary
from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    AudioMeta,
    BiasPhrase,
    ConfidenceMode,
    ErrorMessage,
    Result,
    TranscribeRequest,
)

# --------------------------------------------------------------------------- #
# Synthetic tiny TDT stand-in for the beam n-best fork (no checkpoint).
# --------------------------------------------------------------------------- #


class _FakeTDT:
    """Minimal object exposing exactly what ``decode_beam_nbest`` touches.

    ``decode_beam_nbest`` consumes precomputed ``features`` and only reads
    ``vocabulary`` / ``durations`` / ``max_symbols`` / ``time_ratio`` and calls
    ``decoder`` / ``joint``. The joint returns fixed logits (independent of its
    inputs) so the beam explores a small deterministic tree. Blank id is
    ``len(vocabulary)``; a single duration keeps every step advancing by one.
    """

    def __init__(self, token_logits: list[float]) -> None:
        self.vocabulary = ["x", "y"]  # blank id == 2
        self.durations = [1]
        self.max_symbols = None
        self.time_ratio = 1.0
        # Logits over [x, y, blank]; a single duration logit is appended.
        self._joint = mx.array([[[token_logits + [0.0]]]])

    def decoder(self, tokens, hidden):
        z = mx.zeros((1, 1, 1))
        return z, (z, z)

    def joint(self, feature_slice, decoder_out):
        return self._joint


def _decode(fake: _FakeTDT, *, steps: int = 1, top_k: int = 5, bias=None):
    """Run the beam n-best fork over ``steps`` synthetic time frames."""
    features = mx.zeros((1, steps, 4))  # B=1, S=steps, joint dim=4
    lengths = mx.array([steps])
    config = DecodingConfig(decoding=Beam(beam_size=5, length_penalty=0.0))
    per_batch = NBestParakeetTDT.decode_beam_nbest(
        fake,
        features,
        lengths,
        config=config,
        top_k=top_k,
        bias=bias,
    )
    return per_batch[0]


def test_unbiased_fork_keeps_raw_score_equal_to_score():
    # Zero-boost baseline: no bias -> every hypothesis has raw_score == score.
    fake = _FakeTDT([2.0, 1.0, 0.0])
    for hyp in _decode(fake, steps=2, top_k=20):
        assert hyp.raw_score == hyp.score


def test_bias_raises_target_rank_but_leaves_raw_score_untouched():
    fake = _FakeTDT([2.0, 1.0, 0.0])  # x > y > blank

    unbiased = _decode(fake)
    ub = {h.text: h for h in unbiased}
    assert unbiased[0].text == "x"  # without bias, "x" ranks first
    assert ub["y"].score == ub["y"].raw_score

    # Bias phrase = token id 1 ("y") with a strong weight.
    trie = PhraseTrie([([1], 10.0)], blank_id=2)
    biased = _decode(fake, bias=trie)
    b = {h.text: h for h in biased}

    assert biased[0].text == "y"  # bias lifts "y" to the top
    # The boosted phrase's raw_score is the untouched pre-bias value ...
    assert b["y"].raw_score == pytest.approx(ub["y"].raw_score)
    # ... while its ranking score absorbed the positive bias delta.
    assert b["y"].score > b["y"].raw_score
    # A non-bias hypothesis is neither boosted nor rewritten.
    assert b["x"].score == pytest.approx(b["x"].raw_score)
    assert b["x"].raw_score == pytest.approx(ub["x"].raw_score)


def test_bias_threads_trie_state_across_steps_and_survives_merges():
    fake = _FakeTDT([1.0, 1.0, -1.0])
    unbiased = {h.text: h for h in _decode(fake, steps=2, top_k=20)}
    # Phrase "xy" = token ids [0, 1]; boosts partial then completed matches.
    trie = PhraseTrie([([0, 1], 5.0)], blank_id=2)
    biased = {h.text: h for h in _decode(fake, steps=2, top_k=20, bias=trie)}

    shared = set(biased) & set(unbiased)
    assert "xy" in shared  # the completed 2-token phrase is present
    # raw_score is the pre-bias path score for every hypothesis, unchanged by
    # bias -- including hypotheses formed by recombining (merging) paths such
    # as the single-token "x"/"y" reached via a blank on either side.
    for text in shared:
        assert biased[text].raw_score == pytest.approx(unbiased[text].raw_score)
    # Completing the phrase earns the largest bias boost of any hypothesis.
    boost = {t: biased[t].score - biased[t].raw_score for t in biased}
    assert boost["xy"] == pytest.approx(max(boost.values()))
    assert boost["xy"] > 0.0


# --------------------------------------------------------------------------- #
# MLX backend wiring: cap, unrepresentable-skip, snapshot, single submission.
# --------------------------------------------------------------------------- #

# Small synthetic lowercase SentencePiece inventory (index == token id).
PIECES = [
    "<blk>",  # 0
    WORD_BOUNDARY_MARKER + "hello",  # 1
    WORD_BOUNDARY_MARKER + "world",  # 2
    WORD_BOUNDARY_MARKER + "cat",  # 3
]


class _FakeModel:
    """Model stand-in exposing only what the bias branch reads off-thread."""

    def __init__(self, vocabulary: list[str]) -> None:
        self.vocabulary = vocabulary


class _ImmediateFuture:
    def __init__(self, value) -> None:
        self._value = value

    def result(self):
        return self._value


class _RecordingExecutor:
    """Synchronous executor that records every submission for assertions."""

    def __init__(self) -> None:
        self.submissions: list[tuple] = []

    def submit(self, fn, *args, **kwargs):
        self.submissions.append((fn, args, kwargs))
        return _ImmediateFuture(fn(*args, **kwargs))


def _wav(path):
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(16000)
        writer.writeframes(b"\x00\x00" * 16000)
    return path


def _request(path, *, bias_phrases=None, bias_snapshot_id=None):
    return TranscribeRequest(
        request_id="req-1",
        audio=AudioMeta(
            path=str(path),
            format="wav",
            sample_rate_hz=16000,
            channels=1,
            duration_ms=1000,
            byte_count=32000,
        ),
        bias_phrases=bias_phrases,
        bias_snapshot_id=bias_snapshot_id,
    )


def _bias_backend(monkeypatch, vocabulary):
    backend = MLXBackend()
    backend._model = _FakeModel(vocabulary)
    monkeypatch.setattr(backend, "_load_model", lambda: None)
    recorder = _RecordingExecutor()
    backend._mlx_thread = recorder
    captured: dict = {}

    def fake_infer(audio_path, use_beam, bias=None, bias_snapshot_id=None):
        captured["use_beam"] = use_beam
        captured["bias"] = bias
        captured["bias_snapshot_id"] = bias_snapshot_id
        return _DecodeOutput(
            mode="beam" if bias is not None else ("beam" if use_beam else "greedy"),
            beam_size=5 if (bias is not None or use_beam) else None,
            primary=AlignedResult(text="hello", sentences=[]),
            ranked=[(AlignedResult(text="hello", sentences=[]), -1.0, -1.0)],
            bias_enabled=bias is not None,
            bias_snapshot_id=bias_snapshot_id if bias is not None else None,
        )

    monkeypatch.setattr(backend, "_infer_on_mlx_thread", fake_infer)
    return backend, captured, recorder


def test_unrepresentable_phrases_are_skipped_not_errored(monkeypatch, tmp_path):
    monkeypatch.delenv("VOICEOOUR_ASR_DECODING", raising=False)
    backend, captured, recorder = _bias_backend(monkeypatch, PIECES)

    request = _request(
        _wav(tmp_path / "a.wav"),
        bias_phrases=[
            BiasPhrase(text="hello"),  # -> [1]
            BiasPhrase(text="zzz"),  # unrepresentable -> skipped
            BiasPhrase(text="world"),  # -> [2]
        ],
        bias_snapshot_id="snap-7",
    )
    result = backend.transcribe(request, Event())

    assert isinstance(result, Result)
    # Only the two representable phrases made it into the trie.
    assert isinstance(captured["bias"], PhraseTrie)
    assert len(captured["bias"]) == 2
    # Bias metadata is threaded through to the decoder info + confidence mode.
    assert captured["bias_snapshot_id"] == "snap-7"
    assert result.decoder.bias_enabled is True
    assert result.decoder.bias_snapshot_id == "snap-7"
    assert result.decoder.mode == "beam"
    assert result.transcript.confidence_mode is ConfidenceMode.BEAM_LOGPROB


def test_oversize_bias_list_rejected(monkeypatch, tmp_path):
    backend, captured, recorder = _bias_backend(monkeypatch, PIECES)

    # One over the cap, all representable -> rejected before any submission.
    request = _request(
        _wav(tmp_path / "b.wav"),
        bias_phrases=[BiasPhrase(text="hello") for _ in range(MAX_BIAS_PHRASES + 1)],
    )
    result = backend.transcribe(request, Event())

    assert isinstance(result, ErrorMessage)
    assert result.code is ErrorCode.BIAS_LIST_TOO_LARGE
    assert recorder.submissions == []  # rejected before touching the MLX thread


def test_bias_list_at_cap_is_accepted(monkeypatch, tmp_path):
    backend, captured, recorder = _bias_backend(monkeypatch, PIECES)

    request = _request(
        _wav(tmp_path / "c.wav"),
        bias_phrases=[BiasPhrase(text="hello") for _ in range(MAX_BIAS_PHRASES)],
    )
    result = backend.transcribe(request, Event())

    assert isinstance(result, Result)
    assert result.decoder.bias_enabled is True


def test_biased_decode_is_a_single_mlx_submission(monkeypatch, tmp_path):
    backend, captured, recorder = _bias_backend(monkeypatch, PIECES)

    request = _request(
        _wav(tmp_path / "d.wav"),
        bias_phrases=[BiasPhrase(text="hello", weight=3.0)],
        bias_snapshot_id="snap-9",
    )
    result = backend.transcribe(request, Event())

    assert isinstance(result, Result)
    # Exactly one submission onto the single MLX thread (segmentation + trie
    # build happen off-thread; only the beam is submitted).
    assert len(recorder.submissions) == 1
    _fn, args, _kwargs = recorder.submissions[0]
    # Biased path forwards (audio_path, use_beam=True, bias_trie, snapshot_id).
    assert len(args) == 4
    assert args[1] is True
    assert isinstance(args[2], PhraseTrie)
    assert args[3] == "snap-9"


def test_empty_bias_leaves_default_path_unchanged(monkeypatch, tmp_path):
    monkeypatch.delenv("VOICEOOUR_ASR_DECODING", raising=False)
    backend, captured, recorder = _bias_backend(monkeypatch, PIECES)

    # No bias phrases -> default (greedy) submission, byte-identical two-arg call.
    result = backend.transcribe(_request(_wav(tmp_path / "e.wav")), Event())

    assert isinstance(result, Result)
    assert captured["bias"] is None
    assert captured["use_beam"] is False
    assert result.decoder.bias_enabled is False
    assert result.decoder.bias_snapshot_id is None
    assert len(recorder.submissions) == 1
    _fn, args, _kwargs = recorder.submissions[0]
    assert len(args) == 2  # (audio_path, use_beam) -- no bias args appended


def test_segmenter_gate_matches_backend_skip_semantics():
    # The backend's skip relies on PieceVocabulary.segment returning None for
    # unrepresentable terms; assert that contract directly on the inventory used.
    vocab = PieceVocabulary(PIECES)
    assert vocab.segment("hello") == [1]
    assert vocab.segment("zzz") is None
