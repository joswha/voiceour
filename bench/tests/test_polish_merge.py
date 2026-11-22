import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from polishlab import merge_allowed, verify  # noqa: E402


@pytest.mark.parametrize(("src", "candidate"), [
    ("We shouldn't send this.", "We should send this."),
    ("Is the sample ready?", "Is the sample ready."),
    ("It moves, you know?", "It moves?"),
    ("Keep ./sample and run the job.", "Keep /sample and run the job."),
    ('Pass "1  2" to the encoder.', 'Pass "1 2" to the encoder.'),
    ("Check -R and keep the other flags.", "Check -r and keep the other flags."),
    ("Set the alias to `um file`.", "Set the alias to `file`."),
    ("Wait for approval. Then send it.", "Wait for approval then send it."),
    ("Don't send it, no wait, send it later.", "Send it now."),
])
def test_refused_changes_do_not_reach_delivery(src, candidate):
    assert not verify(src, candidate)[0]
    assert merge_allowed(src, candidate) == src


def test_free_filler_edit_survives_independent_bad_edit():
    src = "Um, can you keep the setting at 14 minutes?"
    raw = "Can you keep the setting at 140 minutes?"
    assert not verify(src, raw)[0]
    assert merge_allowed(src, raw) == "Can you keep the setting at 14 minutes?"


def test_glossary_phrase_keeps_internal_spelling():
    src = "Please call it Echo Blue in the notes."
    changed = "Please call it Echo blue in the notes."
    assert not verify(src, changed, ("Echo Blue",))[0]
    assert merge_allowed(src, changed, ("Echo Blue",)) == src
