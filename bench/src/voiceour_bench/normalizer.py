"""English text normalization for Voiceour benchmark metrics.

This project uses the packaged Whisper English normalizer (`whisper-normalizer`).
The package was import-tested during setup on numbers, contractions, and filler
words, so no vendored normalizer copy is needed.
"""

from __future__ import annotations

from functools import lru_cache

from whisper_normalizer.english import EnglishNumberNormalizer, EnglishTextNormalizer


@lru_cache(maxsize=1)
def _normalizer() -> EnglishTextNormalizer:
    return EnglishTextNormalizer()


@lru_cache(maxsize=1)
def _number_normalizer() -> EnglishNumberNormalizer:
    return EnglishNumberNormalizer()


def english_normalize(text: str | None) -> str:
    """Return Whisper-style normalized English text with collapsed whitespace."""

    normalized = _normalizer()(text or "")
    return " ".join(normalized.split())


def english_number_normalize(text: str) -> str:
    """Canonicalize English number expressions without deleting other words."""

    normalized = _number_normalizer()(text.lower())
    return " ".join(normalized.split())
