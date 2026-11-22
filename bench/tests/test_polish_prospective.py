"""bench/polish/prospective.py over synthetic History files: it never reads the real History or a live private dir."""
import json
import os
import stat
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
import prospective  # noqa: E402
from prospective import Refused, apple_seconds, collect, freeze, seal, status  # noqa: E402

T0 = datetime(2026, 11, 22, 12, 0, 0, 123456, tzinfo=UTC)
LATER = T0 + timedelta(hours=1)
CUTOFF = apple_seconds(T0)
MARK = "zebraquartz"  # in every synthetic text, so a leak shows up in output


def session(n, offset, text=None):
    return {
        "id": f"{n:08X}-0000-4000-8000-000000000000",
        "createdAt": CUTOFF + offset,
        "text": f"{MARK} dictation number {n}." if text is None else text,
        "mutedDuringCapture": False,
    }


def write_source(path, sessions):
    path.parent.mkdir(parents=True, exist_ok=True)
    newest_first = sorted(sessions, key=lambda s: s["createdAt"], reverse=True)
    path.write_text(json.dumps(newest_first, indent=2, sort_keys=True), encoding="utf-8")
    return path


def cohort_rows(out):
    return [json.loads(line) for line in (out / "cohort.jsonl").read_text(encoding="utf-8").splitlines()]


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


@pytest.fixture
def lab(tmp_path):
    return tmp_path / "support" / "recent-sessions.json", tmp_path / "private" / "cohort"


@pytest.fixture
def open_umask():
    previous = os.umask(0)
    yield
    os.umask(previous)


def test_freeze_records_cutoff_and_every_id_but_no_text(lab, open_umask):
    source, out = lab
    sessions = [session(1, -100), session(2, -50, "これは日本語です"), session(3, -10, "")]
    write_source(source, sessions)

    summary = freeze(source, out, T0)

    record = json.loads((out / "freeze.json").read_text(encoding="utf-8"))
    assert record["cutoff_utc"] == T0.isoformat() == summary["cutoff_utc"]
    assert record["ids"] == sorted(s["id"] for s in sessions)
    assert summary["frozen_ids"] == 3
    assert record["source"] == str(source.resolve())
    assert MARK not in (out / "freeze.json").read_text(encoding="utf-8")
    assert sorted(p.name for p in out.iterdir()) == [".lock", "freeze.json"]
    assert mode(out) == 0o700
    assert mode(out / "freeze.json") == 0o600


def test_collect_keeps_only_new_unseen_english_rows(lab, open_umask):
    source, out = lab
    old, skewed = session(1, -100), session(2, 50)  # a frozen id counts as seen even when stamped after the cutoff
    write_source(source, [old, skewed])
    freeze(source, out, T0)
    late, before = session(3, 40), session(4, -5)  # `before` reached History after freeze but predates the cutoff
    early = session(5, 10)
    japanese, blank = session(6, 20, "これは日本語のテキストです"), session(7, 30, "  \n ")
    write_source(source, [old, skewed, late, before, early, japanese, blank])

    summary = collect(out, LATER)

    assert cohort_rows(out) == [{"id": s["id"], "input": s["text"]} for s in (early, late)]
    assert summary == {
        "source_rows": 7,
        "preexisting": 2,
        "before_cutoff": 1,
        "already_collected": 0,
        "not_english_or_empty": 2,
        "added": 2,
        "cohort_rows": 2,
        "possible_gap": False,
    }
    assert mode(out / "cohort.jsonl") == 0o600
    assert mode(out / "state.json") == 0o600


def test_english_filter_matches_the_lab_threshold():
    assert prospective.lab_english("abcdefghi\u00e9")  # 9 of 10 ASCII
    assert not prospective.lab_english("abcdefgh\u00e9\u00e9")  # 8 of 10
    assert not prospective.lab_english(" \t\n")
    assert not prospective.lab_english("")


def test_collect_is_idempotent(lab):
    source, out = lab
    write_source(source, [session(1, -100)])
    freeze(source, out, T0)
    write_source(source, [session(1, -100), session(2, 10), session(3, 20)])
    collect(out, LATER)
    before = (out / "cohort.jsonl").read_bytes()

    summary = collect(out, LATER + timedelta(minutes=5))

    assert (out / "cohort.jsonl").read_bytes() == before
    assert (summary["added"], summary["already_collected"], summary["cohort_rows"]) == (0, 2, 2)
    assert status(out)["collect_runs"] == 2


def test_rows_evicted_from_the_window_stay_in_the_cohort_and_gaps_are_recorded(lab):
    source, out = lab
    anchor = session(1, -100)
    write_source(source, [anchor])
    freeze(source, out, T0)
    first, second = session(2, 10), session(3, 20)
    write_source(source, [anchor, first, second])
    collect(out, LATER)

    third = session(4, 30)
    write_source(source, [second, third])  # `first` and the anchor left; `second` was seen, so nothing was missed
    assert collect(out, LATER)["possible_gap"] is False

    fourth, fifth = session(5, 40), session(6, 50)
    write_source(source, [fourth, fifth])  # every row newer than the last run's newest: some may have been dropped
    summary = collect(out, LATER)

    assert summary["possible_gap"] is True
    assert [row["id"] for row in cohort_rows(out)] == [s["id"] for s in (first, second, third, fourth, fifth)]
    assert status(out)["possible_gaps"] == 1


def test_empty_history_at_freeze_flags_a_gap_only_once_the_window_could_have_filled(lab, monkeypatch):
    source, out = lab
    write_source(source, [])
    freeze(source, out, T0)
    write_source(source, [session(1, 10), session(2, 20)])
    assert collect(out, LATER)["possible_gap"] is False

    other = out.parent / "other"
    write_source(source, [])
    freeze(source, other, T0)
    write_source(source, [session(1, 10), session(2, 20)])
    monkeypatch.setattr(prospective, "WINDOW", 2)
    assert collect(other, LATER)["possible_gap"] is True


def test_private_text_never_goes_into_a_git_work_tree_or_beside_history(lab, tmp_path):
    source, _ = lab
    write_source(source, [session(1, -100)])
    inside_repo = prospective.REPO_ROOT / "bench" / "polish" / ".prospective-must-not-exist"
    work_tree = tmp_path / "work"
    (work_tree / ".git").mkdir(parents=True)
    for out in (inside_repo, work_tree / "cohort", source.parent / "lab"):
        with pytest.raises(Refused):
            freeze(source, out, T0)
        assert not out.exists()


def test_freeze_refuses_a_symlink_or_a_used_directory(lab, tmp_path):
    source, out = lab
    write_source(source, [session(1, -100)])
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real, target_is_directory=True)
    with pytest.raises(Refused, match="symlink"):
        freeze(source, link, T0)

    freeze(source, out, T0)
    with pytest.raises(Refused, match="not empty"):
        freeze(source, out, T0 + timedelta(days=1))
    assert json.loads((out / "freeze.json").read_text(encoding="utf-8"))["cutoff_utc"] == T0.isoformat()


def test_collect_seal_and_status_need_a_freeze(tmp_path):
    for run in (lambda d: collect(d, LATER), lambda d: seal(d, LATER), status):
        with pytest.raises(Refused, match="freeze first"):
            run(tmp_path / "missing")
    assert not (tmp_path / "missing").exists()


def test_malformed_history_is_refused_without_echoing_it(tmp_path):
    source, out = tmp_path / "support" / "recent-sessions.json", tmp_path / "out"
    source.parent.mkdir()
    broken = [
        json.dumps([session(1, -1) | {"createdAt": True}]),
        json.dumps([{"id": "X", "text": f"{MARK} without a date"}]),
        json.dumps([session(1, -1), session(1, -2)]),
        json.dumps({"sessions": [session(1, -1)]}),
        f'[{{"text": "{MARK}"',
    ]
    for text in broken:
        source.write_text(text, encoding="utf-8")
        with pytest.raises(Refused) as error:
            freeze(source, out, T0)
        assert MARK not in str(error.value)
    assert not out.exists()


def test_seal_ends_collection_and_status_checks_it(lab):
    source, out = lab
    write_source(source, [session(1, -100)])
    freeze(source, out, T0)
    with pytest.raises(Refused, match="empty"):
        seal(out, LATER)
    write_source(source, [session(1, -100), session(2, 10)])
    collect(out, LATER)

    sealed = seal(out, LATER)

    assert sealed["cohort_rows"] == 1
    write_source(source, [session(1, -100), session(2, 10), session(3, 20)])
    with pytest.raises(Refused, match="sealed"):
        collect(out, LATER)
    assert status(out)["seal_intact"] is True
    (out / "cohort.jsonl").write_text(json.dumps({"id": session(2, 10)["id"], "input": "edited"}) + "\n")
    assert status(out)["seal_intact"] is False
    assert prospective.main(["status", "--out-dir", str(out)]) == 1


def test_an_interrupted_collect_keeps_the_previous_files(lab, monkeypatch):
    source, out = lab
    write_source(source, [session(1, -100)])
    freeze(source, out, T0)
    write_source(source, [session(1, -100), session(2, 10)])
    collect(out, LATER)
    cohort, state = (out / "cohort.jsonl").read_bytes(), (out / "state.json").read_bytes()
    write_source(source, [session(1, -100), session(2, 10), session(3, 20)])

    def refuse_replace(*_):
        raise OSError("disk full")

    with monkeypatch.context() as patch:
        patch.setattr(prospective.os, "replace", refuse_replace)
        with pytest.raises(OSError):
            collect(out, LATER)
    assert (out / "cohort.jsonl").read_bytes() == cohort
    assert (out / "state.json").read_bytes() == state
    assert sorted(p.name for p in out.iterdir()) == [".lock", "cohort.jsonl", "freeze.json", "state.json"]

    write_private = prospective._write_private

    def fail_on_state(path, data):
        if path.name == "state.json":
            raise OSError("interrupted")
        write_private(path, data)

    with monkeypatch.context() as patch:
        patch.setattr(prospective, "_write_private", fail_on_state)
        with pytest.raises(OSError):
            collect(out, LATER)
    assert len(cohort_rows(out)) == 2  # the cohort landed, its run record did not

    summary = collect(out, LATER)
    assert (summary["added"], summary["already_collected"]) == (0, 2)
    assert [row["id"] for row in cohort_rows(out)] == [session(2, 10)["id"], session(3, 20)["id"]]


def test_cli_prints_counts_never_text_or_ids(tmp_path, capsys):
    source, out = tmp_path / "support" / "recent-sessions.json", tmp_path / "cohort"
    now = apple_seconds(datetime.now(UTC))
    old = session(1, 0) | {"createdAt": now - 1000}
    write_source(source, [old])
    args = ["--out-dir", str(out)]

    assert prospective.main(["freeze", "--source", str(source), *args]) == 0
    fresh = [session(n, 0) | {"createdAt": now + 1000 + n} for n in (2, 3)]
    write_source(source, fresh)  # `old` left the window before any collect saw it: a possible gap
    assert prospective.main(["collect", *args]) == 0
    assert prospective.main(["seal", *args]) == 0
    assert prospective.main(["status", *args]) == 0

    captured = capsys.readouterr()
    assert "warning" in captured.err
    for s in (old, *fresh):
        assert s["id"] not in captured.out + captured.err
    assert MARK not in captured.out + captured.err
    assert len(cohort_rows(out)) == 2
