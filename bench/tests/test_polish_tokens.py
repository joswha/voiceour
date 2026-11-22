import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from polish_tokens import scan  # noqa: E402


@pytest.mark.parametrize("text", [
    'Use "the right screen" and not "the left screen".',
    'Type `send  ok` exactly, please.',
    'Say “keep 1.0” before going on.',
    "Do not change the gloss term First Light at all.",
])
def test_quote_or_glossary_protects_interiors(text):
    words = scan(text, ("First Light",))
    literal = [w for w in words if w.literal]
    assert len(literal) >= 2
    assert "".join(w.gap + w.raw for w in words) == text


@pytest.mark.parametrize("raw,body", [(".env,", ".env"), ("..", ".."), (".75", ".75"), ("./src/.", "./src/."),
                                      ("flags.toml?", "flags.toml"), ("-r", "-r"), ("buttonID", "buttonID")])
def test_literal_body_keeps_semantic_prefixes(raw, body):
    word, = scan(raw)
    assert word.body == body and word.literal
