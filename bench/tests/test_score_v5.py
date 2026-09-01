from __future__ import annotations

import importlib.util
from pathlib import Path


def load_score_v5():
    path = Path(__file__).resolve().parents[1] / "autoresearch" / "score_v5.py"
    spec = importlib.util.spec_from_file_location("score_v5_for_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_negative_guard_detects_taught_surface_absent_from_reference() -> None:
    scorer = load_score_v5()
    false_rows = getattr(scorer, "negative_false_term_rows", lambda *_: {})

    actual = false_rows(
        {
            "spoken-phrase": {"reference": "I am ready to begin"},
            "spoken-acronym": {"reference": "IAM controls this role"},
        },
        {
            "spoken-phrase#j0": {"final_text": "IAM ready to begin"},
            "spoken-acronym#j0": {"final_text": "IAM controls this role"},
        },
        ["IAM"],
    )

    assert actual == {"spoken-phrase": ["IAM"]}
