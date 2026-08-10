"""Written-term to BPE token-id segmenter for shallow-fusion bias phrases.

This module turns a user-supplied *written* term (e.g. ``"camelCase"``,
``"New York"``, ``"GPT4"``) into the sequence of SentencePiece token ids the
Parakeet model would emit for the equivalent *spoken* rendering, or reports the
term as unrepresentable. It is the term -> token-id segmenter used by
shallow-fusion biasing; forced-candidate scoring remains unimplemented for a
different reason (see
:data:`voiceoour_asr.decoding.nbest.FORCED_CANDIDATE_SCORING_AVAILABLE`).

The segmenter is pure string logic: it is built from a flat ``vocabulary`` list
(the model's SentencePiece inventory, where ``index == token id``) and performs
deterministic maximal-munch matching against that inventory. It imports no MLX /
Metal and needs no downloaded checkpoint, so it is fully unit-testable against a
small synthetic piece inventory.

NeMo-style SentencePiece marks the *start of a word* with the U+2581 "lower one
eighth block" marker (``"\u2581"``); interior sub-word pieces carry no marker.
A written term is normalized into spoken-ish word-start units before matching:
whitespace and punctuation separate words, and camelCase / letter<->digit /
acronym boundaries inside a run each begin a new word, because that is how the
model renders such compounds ("camelCase" -> "camel case").

Representability is defined by the maximal-munch procedure itself: a term is
representable iff greedily consuming the longest matching piece at each position
covers the whole normalized surface. When any residual cannot be covered by the
inventory, :meth:`PieceVocabulary.segment` returns ``None`` (the explicit
unrepresentable gate). The function is total and deterministic.
"""

from __future__ import annotations

from collections.abc import Iterable

__all__ = ["WORD_BOUNDARY_MARKER", "PieceVocabulary"]

#: SentencePiece word-start marker (U+2581 LOWER ONE EIGHTH BLOCK, "▁").
WORD_BOUNDARY_MARKER = "\u2581"


def _boundary_before(prev: str, ch: str, nxt: str) -> bool:
    """Whether a new spoken word starts at ``ch`` given its neighbours.

    ``prev`` is the preceding character, ``ch`` the current one, and ``nxt`` the
    following character (``""`` at end of run). All three come from a single
    alphanumeric run, so casing/digit transitions are the only signals.
    """
    prev_digit = prev.isdigit()
    ch_digit = ch.isdigit()
    # letter <-> digit transition, either direction ("gpt4" -> "gpt", "4").
    if prev_digit != ch_digit:
        return True
    if ch_digit:  # digit -> digit: stays one word.
        return False
    ch_upper = ch.isupper()
    if not ch_upper:
        return False
    # camelCase: lower/uncased -> upper starts a new word ("camelCase").
    if not prev.isupper():
        return True
    # Acronym -> word: an UPPER run followed by "Upper + lower" splits before
    # the final upper ("HTTPServer" -> "HTTP", "Server").
    return bool(nxt) and nxt.islower()


def _subsplit(run: str) -> list[str]:
    """Split one alphanumeric run into word-start units at case/digit seams."""
    if not run:
        return []
    parts: list[str] = []
    start = 0
    n = len(run)
    for i in range(1, n):
        nxt = run[i + 1] if i + 1 < n else ""
        if _boundary_before(run[i - 1], run[i], nxt):
            parts.append(run[start:i])
            start = i
    parts.append(run[start:])
    return parts


def _split_words(term: str) -> list[str]:
    """Normalize a written term into ordered spoken-ish word-start units.

    Whitespace and punctuation delimit words and are dropped; each remaining
    alphanumeric run is further split at camelCase / letter<->digit / acronym
    seams. Casing is preserved here (applied later by the vocabulary).
    """
    words: list[str] = []
    current: list[str] = []
    for ch in term:
        if ch.isalnum():
            current.append(ch)
        elif current:
            words.extend(_subsplit("".join(current)))
            current.clear()
    if current:
        words.extend(_subsplit("".join(current)))
    return words


class PieceVocabulary:
    """Maximal-munch segmenter over a flat SentencePiece piece inventory.

    Parameters
    ----------
    vocabulary:
        Flat list of SentencePiece pieces where the list index is the token id
        (NeMo convention). Word-start pieces carry the U+2581 prefix; interior
        pieces do not. Duplicate piece strings resolve to their lowest id for
        determinism.
    """

    def __init__(self, vocabulary: Iterable[str]) -> None:
        self._pieces: list[str] = list(vocabulary)
        self._piece_to_id: dict[str, int] = {}
        for token_id, piece in enumerate(self._pieces):
            # First occurrence wins so lookups are deterministic.
            self._piece_to_id.setdefault(piece, token_id)
        self._max_piece_len = max((len(piece) for piece in self._pieces), default=0)
        # Match the inventory's rendering: an all-lowercase inventory means the
        # model renders lowercase, so terms are lowercased before matching. A
        # mixed/upper inventory is treated as case-sensitive (case preserved).
        self._lowercase = not any(piece != piece.lower() for piece in self._pieces)

    def __len__(self) -> int:
        return len(self._pieces)

    @property
    def lowercase(self) -> bool:
        """Whether terms are lowercased to match the inventory rendering."""
        return self._lowercase

    def surface_form(self, term: str) -> str:
        """Return the normalized U+2581-marked surface string for ``term``.

        Each spoken-ish word is prefixed with the word-boundary marker and, when
        the inventory renders lowercase, lowercased. Exposed primarily so the
        word-boundary/normalization behaviour is directly observable and
        testable; :meth:`segment` matches against exactly this surface.
        """
        words = _split_words(term)
        if self._lowercase:
            words = [word.lower() for word in words]
        return "".join(WORD_BOUNDARY_MARKER + word for word in words)

    def segment(self, term: str) -> list[int] | None:
        """Segment ``term`` into token ids, or ``None`` if unrepresentable.

        Deterministic maximal-munch: at each position consume the longest
        inventory piece that matches the remaining surface. If no piece matches
        at some position the term cannot be represented and ``None`` is returned
        (this includes the empty / punctuation-only surface).
        """
        surface = self.surface_form(term)
        if not surface:
            return None
        ids: list[int] = []
        i = 0
        n = len(surface)
        max_len = self._max_piece_len
        piece_to_id = self._piece_to_id
        while i < n:
            matched = False
            for length in range(min(max_len, n - i), 0, -1):
                token_id = piece_to_id.get(surface[i : i + length])
                if token_id is not None:
                    ids.append(token_id)
                    i += length
                    matched = True
                    break
            if not matched:
                return None  # unrepresentable gate
        return ids
