import json
import os
import random
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
import blind_review as br  # noqa: E402


def test_identical_arms_share_one_judgment_per_case():
    src = {"one": "Keep it.", "two": "Um, check again."}
    raw = {"one": src["one"], "two": "Check again."}
    _, mapping = br.design(src, {"source": src, "raw": raw, "merged": raw}, 2, random.Random(3))
    key = {"version": 1, "study": "s", "arms": ["source", "raw", "merged"], "cases": mapping}
    marks = [[{"meaning": "same", "cleanup": "missed" if a == ["source"] else "enough"} for a in c["slots"]]
             for c in mapping]
    report = br.score(key, {"version": 1, "study": "s", "ratings": marks})
    assert report["per_arm"]["raw"] == report["per_arm"]["merged"] == {"meaning_same": 2, "cleanup_enough": 2}
    source_raw = next(row for row in report["paired"] if row["arms"] == ["source", "raw"])
    assert source_raw["second_only_usable"] == 1


def test_no_results_until_every_version_rated():
    key = {"version": 1, "study": "sealed", "arms": ["source", "other"], "cases": [{"slots": [["source", "other"]]}]}
    with pytest.raises(ValueError, match="stay blind"):
        br.score(key, {"study": "sealed", "version": 1, "ratings": [[{"meaning": "same"}]]})
    with pytest.raises(ValueError, match="this study"):
        br.score(key, {"study": "old", "version": 1, "ratings": []})
    result = br.score(key, {"study": "sealed", "version": 1, "ratings": [[{"meaning": "unsure", "cleanup": "enough"}]]})
    assert result["paired"][0]["rated_without_uncertainty"] == 0


def test_page_hides_names_ids_and_verdicts_and_escapes_source(tmp_path):
    src, pred, out = tmp_path / "src", tmp_path / "pred", tmp_path / "blind"
    def write(path, field, text):
        path.write_text(json.dumps({"id": "sensitive-example-id", field: text}) + "\n")
    write(src, "input", "Um, leave <img onerror=alert(1)> alone.")
    write(pred, "output", "Leave <img onerror=alert(1)> alone.")
    result = br.prepare(src, [f"secretmodel={pred}"], [], out, 60)
    assert result["sampled"] == 1
    page = (out / "review.html").read_text()
    assert "&lt;img" in page and "<img" not in page
    assert "secretmodel" not in page and "sensitive-example-id" not in page
    assert "secretmodel/raw" in (out / "key.json").read_text()
    assert stat.S_IMODE(os.stat(out).st_mode) == 0o700
    assert stat.S_IMODE(os.stat(out / "review.html").st_mode) == 0o600
    assert stat.S_IMODE(os.stat(out / "key.json").st_mode) == 0o600
    with pytest.raises(FileExistsError):
        br.prepare(src, [f"secretmodel={pred}"], [], out, 60)


def test_mismatch_duplicate_and_repo_destination_fail_closed(tmp_path):
    src = tmp_path / "source"
    src.write_text('{"id":"a","input":"Hello."}\n')
    pred = tmp_path / "rows"
    pred.write_text('{"id":"b","output":"Hello."}\n')
    dest = tmp_path / "study"
    with pytest.raises(ValueError, match="ids do not match"):
        br.prepare(src, [f"candidate={pred}"], [], dest, 10)
    assert not dest.exists()
    tree = tmp_path / "repo"
    (tree / ".git").mkdir(parents=True)
    with pytest.raises(ValueError, match="Git work tree"):
        br.prepare(src, [], [], tree / "private-study", 10)
    pred.write_text(pred.read_text() * 2)
    with pytest.raises(ValueError, match="duplicate row"):
        br.read_rows(pred, "output")
