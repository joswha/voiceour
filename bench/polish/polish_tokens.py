"""Lossless word spans for the bench edit policy. Offsets never depend on two different tokenizers."""
import re
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Word:
    raw: str
    body: str
    key: str
    punct: str
    gap: str
    literal: bool


_TECHNICAL = re.compile(r"\d|[^\w'’]|_|[A-Z].*[A-Z]|[a-z][A-Z]")
# Contractions use apostrophes inside a word. An unmatched opening quote protects the rest of the input.
_QUOTED = re.compile(r'''`[^`]*(?:`|$)|"[^"]*(?:"|$)|“[^”]*(?:”|$)|(?<!\w)'[^'\n]*(?:'(?!\w)|$)|‘[^’]*(?:’|$)''')


def protected(body, terms=()):
    return body in terms or bool(_TECHNICAL.search(body))


def scan(text, terms=()):
    words = []
    phrases = [re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE) for term in terms if term]
    spans = sorted((m.start(), m.end()) for p in [_QUOTED, *phrases] for m in p.finditer(text))
    span = end = 0
    for m in re.finditer(r"\S+", text):
        raw = m[0]
        while span < len(spans) and spans[span][1] <= m.start():
            span += 1
        quoted = span < len(spans) and spans[span][0] < m.end()
        body = raw.rstrip(",.;:!?") or raw
        # Treat a trailing dot in a path conservatively; /a/. and /a are different spellings.
        if any(ch in body for ch in "/\\") and raw.endswith("."):
            body = raw
        words.append(Word(raw, body, body.lower().replace("’", "'"), raw[len(body):], text[end:m.start()],
                          quoted or protected(body)))
        end = m.end()
    return words
