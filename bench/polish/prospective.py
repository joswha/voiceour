#!/usr/bin/env python3
"""Seal a prospective polish cohort: English dictations made after a freeze, so no earlier analysis saw them.

    python3 bench/polish/prospective.py freeze  [--source <recent-sessions.json>] [--out-dir <dir>]
    python3 bench/polish/prospective.py collect [--out-dir <dir>]
    python3 bench/polish/prospective.py seal    [--out-dir <dir>]
    python3 bench/polish/prospective.py status  [--out-dir <dir>]

`freeze` records the wall-clock UTC cutoff and the exact set of ids History holds at that moment, and keeps no
text. `collect` reads the frozen History file and appends to `cohort.jsonl` ({"id", "input"}, the input of
`voiceour-bench polish`) every row created after the cutoff (`createdAt`, seconds since 2001-01-01 UTC) whose id
was neither frozen nor collected before and whose text passes the lab's English filter: not blank, at least 90%
ASCII. History keeps only the newest 500 dictations, so run collect before 500 more pile up: a run that cannot
show it saw every row since the previous observation records a possible gap. Rerunning collect over the same
History adds nothing. `seal` ends accumulation and records the cohort's row count and sha256; `status` checks it.

The output directory holds private text. It must lie outside this repository, every git work tree and the
History file's directory; it is 0700 and its files 0600; every write is an atomic replace under a lock, so an
interrupted run leaves the previous files. Every command prints counts only, never text or ids, and nothing here
uses the network or logs.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
import stat
import sys
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = Path.home() / "Library" / "Application Support" / "Voiceour" / "recent-sessions.json"
# Not inside ~/polish-lab/private: `history_eval.py purge` deletes that directory whole.
DEFAULT_OUT_DIR = Path.home() / "polish-lab" / "private-prospective"
WINDOW = 500  # RecentSessionStore keeps the newest 500 sessions.
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=UTC)  # Foundation's reference date; History encodes Date as seconds since it.
VERSION = 1
FREEZE, STATE, COHORT, LOCK = "freeze.json", "state.json", "cohort.jsonl", ".lock"


class Refused(Exception):
    """A refusal. Its message never holds transcript text or ids."""


def lab_english(text):
    """The lab's History filter (`history_eval.py prepare`): not blank, at least 90% ASCII characters."""
    return bool(text.strip()) and sum(ch.isascii() for ch in text) >= 0.9 * len(text)


def apple_seconds(moment):
    return (moment - APPLE_EPOCH) / timedelta(seconds=1)


def _is_seconds(value):
    return isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value)


def load_source(path):
    """History rows as (id, createdAt, text); refuses the whole file when any row is malformed, as the app does."""
    try:
        rows = json.loads(Path(path).read_bytes())
    except FileNotFoundError:
        raise Refused(f"no History file at {path}") from None
    except ValueError:  # JSONDecodeError and UnicodeDecodeError
        raise Refused(f"{path} is not valid JSON") from None
    if not isinstance(rows, list):
        raise Refused(f"{path} is not a JSON array of sessions")
    out, seen = [], set()
    for n, row in enumerate(rows, 1):
        if not (
            isinstance(row, dict)
            and isinstance(row.get("id"), str)
            and row["id"]
            and isinstance(row.get("text"), str)
            and _is_seconds(row.get("createdAt"))
        ):
            raise Refused(f"History row {n} lacks a valid id, createdAt or text")
        if row["id"] in seen:
            raise Refused(f"History row {n} repeats an earlier id")
        seen.add(row["id"])
        out.append((row["id"], float(row["createdAt"]), row["text"]))
    return out


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _ids_sha256(ids):
    return _sha256("\n".join(sorted(ids)).encode())


def _json_bytes(value):
    return (json.dumps(value, indent=1, sort_keys=True) + "\n").encode()


def _inside(path, root):
    return path == root or root in path.parents


def _private_dir(out_dir, create, source=None):
    """The resolved output directory, 0700 and owned by this user. Every check runs before anything is created."""
    path = Path(out_dir).expanduser().absolute()
    if path.is_symlink():
        raise Refused(f"{path} is a symlink; name the directory itself")
    resolved = path.resolve()
    if _inside(resolved, REPO_ROOT) or any((p / ".git").exists() for p in (resolved, *resolved.parents)):
        raise Refused(f"{resolved} lies inside a git work tree; private text never goes there")
    if source is not None:
        _apart_from_source(resolved, source)
    if not resolved.exists():
        if not create:
            raise Refused(f"no prospective cohort at {resolved}; run freeze first")
        resolved.mkdir(mode=0o700, parents=True)
    info = os.lstat(resolved)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Refused(f"{resolved} is not a directory owned by this user")
    os.chmod(resolved, 0o700)
    return resolved


def _apart_from_source(directory, source):
    if _inside(directory, Path(source).parent):
        raise Refused(f"{directory} lies inside the History file's directory")


def _write_private(path, data):
    """Atomically replaces `path` with `data` as a 0600 file."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    dir_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


@contextlib.contextmanager
def _locked(directory):
    fd = os.open(directory / LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused(f"another prospective run holds {directory / LOCK}") from None
        yield
    finally:
        os.close(fd)


def _load_json(path, what):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        raise Refused(f"{path.parent} holds no {what}; run freeze first") from None
    except ValueError:
        raise Refused(f"{path} is not valid JSON") from None


def _load_freeze(directory):
    record = _load_json(directory / FREEZE, "freeze")
    try:
        ids = record["ids"]
        valid = (
            record["version"] == VERSION
            and isinstance(ids, list)
            and all(isinstance(i, str) for i in ids)
            and len(set(ids)) == len(ids)
            and record["ids_sha256"] == _ids_sha256(ids)
            and isinstance(record["source"], str)
            and (record["high_water_apple"] is None or _is_seconds(record["high_water_apple"]))
            and datetime.fromisoformat(record["cutoff_utc"]).utcoffset() == timedelta(0)
        )
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        raise Refused(f"{directory / FREEZE} is not a valid freeze record")
    return record


def _load_state(directory, frozen):
    path = directory / STATE
    if not path.exists():
        return {"version": VERSION, "high_water_apple": frozen["high_water_apple"], "runs": [], "sealed": None}
    state = _load_json(path, "state")
    try:
        sealed = state["sealed"]
        valid = (
            state["version"] == VERSION
            and (state["high_water_apple"] is None or _is_seconds(state["high_water_apple"]))
            and isinstance(state["runs"], list)
            and all(isinstance(run["at_utc"], str) and isinstance(run["possible_gap"], bool) for run in state["runs"])
            and (sealed is None or (isinstance(sealed["at_utc"], str) and isinstance(sealed["rows"], int)
                                    and isinstance(sealed["sha256"], str)))
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise Refused(f"{path} is not a valid state record")
    return state


def _load_cohort(directory, frozen_ids):
    """The cohort file's bytes and ids; refuses a file that is not exactly unfrozen, unique {"id", "input"} rows."""
    path = directory / COHORT
    if not path.exists():
        return b"", set()
    data = path.read_bytes()
    if data and not data.endswith(b"\n"):
        raise Refused(f"{path} ends mid-line")
    ids = set()
    for n, line in enumerate(data.splitlines(), 1):
        try:
            row = json.loads(line)
        except ValueError:
            raise Refused(f"{path} line {n} is not JSON") from None
        if not (
            isinstance(row, dict)
            and set(row) == {"id", "input"}
            and isinstance(row["id"], str)
            and isinstance(row["input"], str)
            and row["id"] not in ids
            and row["id"] not in frozen_ids
        ):
            raise Refused(f"{path} line {n} is not a new, unique cohort row")
        ids.add(row["id"])
    return data, ids


def freeze(source, out_dir, now):
    """Records `now` (taken before History is read) and every id History holds. Writes no text."""
    source = Path(source).expanduser().resolve()
    rows = load_source(source)
    directory = _private_dir(out_dir, create=True, source=source)
    with _locked(directory):
        if any(p.name != LOCK for p in directory.iterdir()):
            raise Refused(f"{directory} is not empty; freeze only into a new directory")
        ids = sorted(rid for rid, _, _ in rows)
        record = {
            "version": VERSION,
            "cutoff_utc": now.astimezone(UTC).isoformat(),
            "source": str(source),
            "source_rows": len(rows),
            "high_water_apple": max((created for _, created, _ in rows), default=None),
            "ids_sha256": _ids_sha256(ids),
            "ids": ids,
        }
        _write_private(directory / FREEZE, _json_bytes(record))
    return {
        "cutoff_utc": record["cutoff_utc"],
        "frozen_ids": len(ids),
        "ids_sha256": record["ids_sha256"],
        "out_dir": str(directory),
    }


def collect(out_dir, now):
    """Appends every new English History row since the cutoff to the cohort; idempotent over the same History."""
    directory = _private_dir(out_dir, create=False)
    with _locked(directory):
        frozen = _load_freeze(directory)
        _apart_from_source(directory, frozen["source"])
        state = _load_state(directory, frozen)
        if state["sealed"]:
            raise Refused("the cohort is sealed; collect adds nothing to it")
        frozen_ids = set(frozen["ids"])
        data, have = _load_cohort(directory, frozen_ids)
        rows = load_source(frozen["source"])
        cutoff = apple_seconds(datetime.fromisoformat(frozen["cutoff_utc"]))
        counts = dict.fromkeys(("preexisting", "before_cutoff", "already_collected", "not_english_or_empty"), 0)
        new = []
        for rid, created, text in rows:
            if rid in frozen_ids:
                counts["preexisting"] += 1
            elif created <= cutoff:
                counts["before_cutoff"] += 1
            elif rid in have:
                counts["already_collected"] += 1
            elif not lab_english(text):
                counts["not_english_or_empty"] += 1
            else:
                new.append((created, rid, text))
        new.sort()
        # History drops its oldest rows first, so a row no newer than the last observation's newest proves every
        # later row is still here. With none, rows made since then may have left before this run saw them.
        high_water = state["high_water_apple"]
        if high_water is None:
            possible_gap = len(rows) >= WINDOW
        else:
            possible_gap = not any(created <= high_water for _, created, _ in rows)
        if new or not (directory / COHORT).exists():
            data += b"".join((json.dumps({"id": rid, "input": text}) + "\n").encode() for _, rid, text in new)
            _write_private(directory / COHORT, data)
        if rows:
            state["high_water_apple"] = max(created for _, created, _ in rows)
        run = {"at_utc": now.astimezone(UTC).isoformat(), "source_rows": len(rows), "added": len(new)}
        state["runs"].append(run | {"possible_gap": possible_gap})
        _write_private(directory / STATE, _json_bytes(state))
    return {
        "source_rows": len(rows),
        **counts,
        "added": len(new),
        "cohort_rows": len(have) + len(new),
        "possible_gap": possible_gap,
    }


def seal(out_dir, now):
    """Ends accumulation: records the cohort's row count and sha256."""
    directory = _private_dir(out_dir, create=False)
    with _locked(directory):
        frozen = _load_freeze(directory)
        state = _load_state(directory, frozen)
        if state["sealed"]:
            raise Refused("the cohort is already sealed")
        data, ids = _load_cohort(directory, set(frozen["ids"]))
        if not ids:
            raise Refused("the cohort is empty; collect before sealing")
        state["sealed"] = {"at_utc": now.astimezone(UTC).isoformat(), "rows": len(ids), "sha256": _sha256(data)}
        _write_private(directory / STATE, _json_bytes(state))
    return {
        "sealed_at_utc": state["sealed"]["at_utc"],
        "cohort_rows": len(ids),
        "cohort_sha256": state["sealed"]["sha256"],
        "collect_runs": len(state["runs"]),
        "possible_gaps": sum(run["possible_gap"] for run in state["runs"]),
    }


def status(out_dir):
    """Counts and hashes of the cohort; reads no History."""
    directory = _private_dir(out_dir, create=False)
    frozen = _load_freeze(directory)
    state = _load_state(directory, frozen)
    data, ids = _load_cohort(directory, set(frozen["ids"]))
    sealed = state["sealed"]
    return {
        "cutoff_utc": frozen["cutoff_utc"],
        "frozen_ids": len(frozen["ids"]),
        "ids_sha256": frozen["ids_sha256"],
        "cohort_rows": len(ids),
        "cohort_sha256": _sha256(data),
        "collect_runs": len(state["runs"]),
        "last_collect_utc": state["runs"][-1]["at_utc"] if state["runs"] else None,
        "possible_gaps": sum(run["possible_gap"] for run in state["runs"]),
        "sealed_at_utc": sealed["at_utc"] if sealed else None,
        "seal_intact": (sealed["sha256"] == _sha256(data) and sealed["rows"] == len(ids)) if sealed else None,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command", required=True)
    freezer = commands.add_parser("freeze", help="record the cutoff and the ids History holds now; no text")
    freezer.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="History file (recent-sessions.json)")
    helps = {
        "collect": "append new English History rows since the cutoff to cohort.jsonl",
        "seal": "end accumulation; record the cohort's row count and sha256",
        "status": "print counts and hashes; reads no History",
    }
    for name, text in helps.items():
        commands.add_parser(name, help=text)
    for sub in commands.choices.values():
        sub.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR, help="private cohort directory")
    args = parser.parse_args(argv)
    now = datetime.now(UTC)
    try:
        if args.command == "freeze":
            summary = freeze(args.source, args.out_dir, now)
        elif args.command == "collect":
            summary = collect(args.out_dir, now)
        elif args.command == "seal":
            summary = seal(args.out_dir, now)
        else:
            summary = status(args.out_dir)
    except (Refused, OSError) as error:
        print(f"prospective {args.command}: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=1))
    if summary.get("possible_gap"):
        print(
            "warning: History may have dropped dictations made since the previous run before this one saw them; "
            f"collect before {WINDOW} more dictations pile up",
            file=sys.stderr,
        )
    if summary.get("seal_intact") is False:
        print("warning: cohort.jsonl no longer matches its seal", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
