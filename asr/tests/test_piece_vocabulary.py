from __future__ import annotations

import pytest

from voiceour_asr.decoding.vocabulary import WORD_BOUNDARY_MARKER, PieceVocabulary

M = WORD_BOUNDARY_MARKER  # "▁"

# Small synthetic lowercase SentencePiece inventory (index == token id).
# Word-start pieces carry the U+2581 marker; interior pieces do not.
PIECES = [
    "<blk>",  # 0  blank / non-word token
    M,  # 1  bare word-start marker
    M + "hello",  # 2
    M + "wor",  # 3
    "ld",  # 4  interior
    M + "new",  # 5
    "york",  # 6  interior "york"
    M + "york",  # 7  word-start "york"
    M + "camel",  # 8
    M + "case",  # 9
    M + "cat",  # 10
]


@pytest.fixture
def vocab() -> PieceVocabulary:
    return PieceVocabulary(PIECES)


def test_index_is_token_id_and_lowercase_detected(vocab: PieceVocabulary) -> None:
    assert len(vocab) == len(PIECES)
    assert vocab.lowercase is True


def test_representable_multi_piece_term(vocab: PieceVocabulary) -> None:
    # "hello world" -> ▁hello | ▁wor | ld
    assert vocab.segment("hello world") == [2, 3, 4]


def test_camelcase_boundary_and_lowercasing(vocab: PieceVocabulary) -> None:
    # camelCase splits into two spoken words and lowercases: ▁camel | ▁case
    assert vocab.segment("camelCase") == [8, 9]


def test_word_boundary_marker_selects_word_start_vs_interior(
    vocab: PieceVocabulary,
) -> None:
    # Glued single word: "york" is interior after "▁new".
    assert vocab.segment("newyork") == [5, 6]
    # Two words: the U+2581 marker forces the word-start "▁york" piece instead.
    assert vocab.segment("new york") == [5, 7]


def test_unrepresentable_term_returns_none(vocab: PieceVocabulary) -> None:
    # "▁cat" matches but the residual "s" has no covering piece -> None.
    assert vocab.segment("cats") is None
    # Fully out-of-inventory characters are also unrepresentable.
    assert vocab.segment("zzz") is None


def test_empty_and_punctuation_only_are_unrepresentable(
    vocab: PieceVocabulary,
) -> None:
    assert vocab.segment("") is None
    assert vocab.segment("   ") is None
    assert vocab.segment("!!!") is None


def test_segmentation_is_deterministic(vocab: PieceVocabulary) -> None:
    first = vocab.segment("hello world")
    second = vocab.segment("hello world")
    assert first == second == [2, 3, 4]
    # A fresh list each call: mutating one result must not affect the next.
    assert first is not second
    first.append(999)
    assert vocab.segment("hello world") == [2, 3, 4]


@pytest.mark.parametrize(
    ("term", "expected"),
    [
        ("hello world", M + "hello" + M + "world"),
        ("camelCase", M + "camel" + M + "case"),
        ("HTTPServer", M + "http" + M + "server"),  # acronym -> word split
        ("GPT4", M + "gpt" + M + "4"),  # letter<->digit split
        ("new york", M + "new" + M + "york"),
        ("newyork", M + "newyork"),
        ("GPT-4 turbo", M + "gpt" + M + "4" + M + "turbo"),  # punctuation drops
    ],
)
def test_surface_form_word_boundaries(vocab: PieceVocabulary, term: str, expected: str) -> None:
    assert vocab.surface_form(term) == expected


def test_mixed_case_inventory_preserves_case() -> None:
    # A non-lowercase inventory is treated as case-sensitive rendering, so the
    # written term's casing is preserved (never fabricated) during matching.
    mixed = PieceVocabulary(["<blk>", M, M + "Camel", "Case"])
    assert mixed.lowercase is False
    assert mixed.surface_form("CamelCase") == M + "Camel" + M + "Case"
    # ▁Camel | (bare ▁ marker) | Case  -- no "▁Case" piece exists.
    assert mixed.segment("CamelCase") == [2, 1, 3]
