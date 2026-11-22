import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from guided_cases import candidates  # noqa: E402
from polishlab import verify  # noqa: E402


def test_source_only_candidates_protect_literals_and_negation():
    src = "Um, do not change 40 to 400 in OutputBuffer."
    values = candidates(src)
    assert src in values
    assert "Do not change 40 to 400 in OutputBuffer." in values
    assert all("40 to 400 in OutputBuffer" in s and "not" in s and verify(src, s)[0] for s in values)


def test_candidate_budget_one_keeps_identity():
    src = "Can you, um, keep the original order?"
    assert candidates(src, limit=1) == [src]


@pytest.mark.parametrize("text", ["", "\t", " input "])
def test_invalid_candidates_fail_before_decoding(text):
    with pytest.raises(ValueError):
        candidates(text)
