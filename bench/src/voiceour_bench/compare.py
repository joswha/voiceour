"""Compare two Voiceour benchmark JSON reports."""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

UWER_MAX_DELTA = 0.0035


def _parse_gate(value: str) -> tuple[str, float]:
    metric, separator, raw_delta = value.rpartition(":")
    if not separator or not metric:
        raise argparse.ArgumentTypeError("gate must use metric:max_delta")
    try:
        max_delta = float(raw_delta)
    except ValueError as error:
        raise argparse.ArgumentTypeError("gate max_delta must be a number") from error
    if not math.isfinite(max_delta):
        raise argparse.ArgumentTypeError("gate max_delta must be finite")
    return metric, max_delta


def _flatten_numbers(prefix: str, value: Any) -> Iterator[tuple[str, float]]:
    if isinstance(value, bool):
        return
    if isinstance(value, int | float):
        yield prefix, float(value)
    elif isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            yield from _flatten_numbers(child_prefix, child)


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Print metric deltas between two benchmark reports.")
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--gate",
        action="append",
        default=[],
        type=_parse_gate,
        metavar="METRIC:MAX_DELTA",
        help=(
            "fail when candidate minus baseline exceeds MAX_DELTA; the formal "
            f"U-WER gate is uwer_final:{UWER_MAX_DELTA}"
        ),
    )
    args = parser.parse_args(argv)

    baseline_report = _load(args.baseline)
    candidate_report = _load(args.candidate)

    # Refuse to compare reports that did not score the same rows. Only rows without
    # an `error` are scored, so a backend that rejects some inputs is silently
    # measured on an easier corpus: ARK rejects clips over 30 s, which drops 16 of
    # the 128 LibriSpeech rows, and the rows it drops are the longest ones. A delta
    # between 128 scored rows and 112 is not a delta, and a gate computed from it is
    # worse than no gate because it looks like evidence.
    baseline_counts = baseline_report.get("counts", {})
    candidate_counts = candidate_report.get("counts", {})
    baseline_scored = baseline_counts.get("successful_rows")
    candidate_scored = candidate_counts.get("successful_rows")
    if baseline_scored != candidate_scored:
        print(
            f"REFUSING TO COMPARE: baseline scored {baseline_scored} rows, candidate scored "
            f"{candidate_scored} (errors: {baseline_counts.get('error_rows')} vs "
            f"{candidate_counts.get('error_rows')}). Re-run both over the intersection, "
            "or compare only within one row set.",
            file=sys.stderr,
        )
        return 2

    baseline = dict(_flatten_numbers("", baseline_report.get("metrics", {})))
    candidate = dict(_flatten_numbers("", candidate_report.get("metrics", {})))
    keys = sorted(set(baseline) | set(candidate))
    print("| metric | baseline | candidate | delta |")
    print("| --- | ---: | ---: | ---: |")
    for key in keys:
        before = baseline.get(key)
        after = candidate.get(key)
        if before is None or after is None:
            delta = "n/a"
        else:
            delta = f"{after - before:+.4f}"
        before_text = "n/a" if before is None else f"{before:.4f}"
        after_text = "n/a" if after is None else f"{after:.4f}"
        print(f"| {key} | {before_text} | {after_text} | {delta} |")

    failures: list[str] = []
    for metric, max_delta in args.gate:
        before = baseline.get(metric)
        after = candidate.get(metric)
        if before is None or after is None:
            failures.append(f"{metric}: unavailable in baseline or candidate")
            continue
        delta = after - before
        if delta > max_delta and not math.isclose(delta, max_delta, rel_tol=1e-12, abs_tol=1e-12):
            failures.append(f"{metric}: delta {delta:+.6f} exceeds {max_delta:+.6f}")
    for failure in failures:
        print(f"GATE FAILED: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
