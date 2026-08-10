"""Decoding-time evidence mapping for the Parakeet MLX backend.

The functions here turn ``parakeet_mlx`` alignment structures (``AlignedResult``
with its ``AlignedSentence`` / ``AlignedToken`` children) into the additive wire
evidence: ``Transcript.segments``, per-segment ``Word`` lists with per-word
confidence, and an aggregate ``Transcript.confidence``.

They are deliberately kept free of any MLX / Metal imports and operate purely on
duck-typed alignment objects, so the mapping is unit-testable with synthetic
``parakeet_mlx.alignment`` dataclasses and no downloaded checkpoint. The beam
n-best decoder lives in :mod:`voiceoour_asr.decoding.nbest` and is imported
lazily only when the caller opts into beam decoding.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from typing import TYPE_CHECKING

from voiceoour_asr.protocol import ConfidenceMode, Segment, Transcript, Word

if TYPE_CHECKING:  # pragma: no cover - typing only, avoids importing mlx at runtime
    from parakeet_mlx.alignment import AlignedResult, AlignedToken

__all__ = [
    "aligned_result_to_transcript",
    "geometric_mean_confidence",
    "tokens_to_words",
    "text_from_tokens",
]


def _seconds_to_ms(seconds: float) -> int:
    return int(round(float(seconds) * 1000.0))


def geometric_mean_confidence(values: Sequence[float]) -> float | None:
    """Geometric mean of confidence values in log space.

    Mirrors ``parakeet_mlx.alignment.AlignedSentence`` (which uses the geometric
    mean of its token confidences) so aggregate confidence is consistent with
    the per-sentence values the model already computes. Returns ``None`` when
    there is nothing to aggregate, so callers can leave the field ``nil`` rather
    than fabricate a score.
    """
    clean = [float(v) for v in values if v is not None]
    if not clean:
        return None
    total = 0.0
    for value in clean:
        total += math.log(max(value, 0.0) + 1e-10)
    return math.exp(total / len(clean))


def _word_starts(text: str) -> bool:
    # SentencePiece marks word starts with U+2581 ("▁"); parakeet's tokenizer
    # decodes that to a leading space. Accept either so synthetic tokens work.
    return text.startswith(" ") or text.startswith("\u2581")


def text_from_tokens(tokens: Sequence[AlignedToken]) -> str:
    """Reconstruct display text from a token run (used for hypothesis text)."""
    return "".join(token.text for token in tokens).replace("\u2581", " ").strip()


def tokens_to_words(tokens: Sequence[AlignedToken]) -> list[Word]:
    """Group subword tokens into words carrying per-word confidence.

    A new word begins at each token whose decoded text starts a word (leading
    space / ``▁``); intermediate subwords are folded into the current word. Each
    word's confidence is the geometric mean of its constituent token
    confidences, and its span is the first token's start to the last token's
    end. Tokens that reduce to empty text are dropped rather than emitted as
    blank words.
    """
    words: list[Word] = []
    group: list[AlignedToken] = []

    def flush() -> None:
        if not group:
            return
        text = text_from_tokens(group)
        if not text:
            return
        words.append(
            Word(
                text=text,
                start_ms=_seconds_to_ms(group[0].start),
                end_ms=_seconds_to_ms(group[-1].end),
                confidence=geometric_mean_confidence([t.confidence for t in group]),
            )
        )

    for token in tokens:
        if group and _word_starts(token.text):
            flush()
            group = []
        group.append(token)
    flush()
    return words


def aligned_result_to_transcript(
    result: AlignedResult,
    *,
    confidence_mode: ConfidenceMode,
    language: str | None = "en",
) -> Transcript:
    """Map a parakeet ``AlignedResult`` into a wire ``Transcript``.

    Each aligned sentence becomes a ``Segment`` with its word list; the
    aggregate ``Transcript.confidence`` is the geometric mean over every token
    confidence in the result. Empty results leave ``segments`` and
    ``confidence`` as ``None``.
    """
    segments: list[Segment] = []
    token_confidences: list[float] = []
    for sentence in result.sentences:
        words = tokens_to_words(sentence.tokens)
        token_confidences.extend(token.confidence for token in sentence.tokens)
        segments.append(
            Segment(
                start_ms=_seconds_to_ms(sentence.start),
                end_ms=_seconds_to_ms(sentence.end),
                text=sentence.text.strip(),
                words=words or None,
            )
        )
    return Transcript(
        text=result.text,
        language=language,
        segments=segments or None,
        confidence=geometric_mean_confidence(token_confidences),
        confidence_mode=confidence_mode,
    )
