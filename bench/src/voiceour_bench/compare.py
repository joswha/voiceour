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


def _format_ids(ids: set[str], limit: int = 10) -> str:
    ordered = sorted(ids)
    shown = ", ".join(ordered[:limit])
    if len(ordered) > limit:
        shown = f"{shown}, ... (+{len(ordered) - limit} more)"
    return f"[{shown}]"


def _validated_id_sets(
    successful: Any,
    errors: Any,
    report: dict[str, Any],
) -> tuple[dict[str, set[str]] | None, str | None]:
    if not isinstance(successful, list) or not isinstance(errors, list):
        return None, "row-id evidence must contain successful and errors lists"
    if not all(isinstance(row_id, str) and row_id for row_id in [*successful, *errors]):
        return None, "row-id evidence contains a missing or non-string id"
    successful_set = set(successful)
    error_set = set(errors)
    if len(successful_set) != len(successful):
        return None, "successful row-id evidence contains duplicates"
    if len(error_set) != len(errors):
        return None, "error row-id evidence contains duplicates"
    overlap = successful_set & error_set
    if overlap:
        return None, f"row ids appear as both successful and errors: {_format_ids(overlap)}"

    counts = report.get("counts")
    counts = counts if isinstance(counts, dict) else {}
    expected_successful = counts.get("successful_rows")
    expected_errors = counts.get("error_rows")
    if expected_successful != len(successful_set):
        return (
            None,
            f"successful row-id evidence has {len(successful_set)} ids but counts.successful_rows "
            f"is {expected_successful}",
        )
    if expected_errors != len(error_set):
        return (
            None,
            f"error row-id evidence has {len(error_set)} ids but counts.error_rows is {expected_errors}",
        )
    return {"successful": successful_set, "errors": error_set}, None


def _complete_row_ids(
    report: dict[str, Any],
) -> tuple[dict[str, set[str]] | None, str | None]:
    if "successful_row_ids" not in report or "error_row_ids" not in report:
        worst = report.get("worst_10")
        worst_ids = (
            {
                row["id"]
                for row in worst
                if isinstance(row, dict) and isinstance(row.get("id"), str)
            }
            if isinstance(worst, list)
            else set()
        )
        partial = (
            f"; worst_10 is only partial evidence {_format_ids(worst_ids)}"
            if worst_ids
            else ""
        )
        return None, f"report predates row-id recording{partial}"
    return _validated_id_sets(
        report.get("successful_row_ids"),
        report.get("error_row_ids"),
        report,
    )


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

    baseline_meta = baseline_report.get("meta")
    candidate_meta = candidate_report.get("meta")
    baseline_meta = baseline_meta if isinstance(baseline_meta, dict) else {}
    candidate_meta = candidate_meta if isinstance(candidate_meta, dict) else {}
    provenance = (
        ("tier", baseline_report.get("tier"), candidate_report.get("tier")),
        ("backend", baseline_meta.get("backend"), candidate_meta.get("backend")),
        ("model_id", baseline_meta.get("model_id"), candidate_meta.get("model_id")),
        (
            "model_revision",
            baseline_meta.get("model_revision"),
            candidate_meta.get("model_revision"),
        ),
    )
    for field, baseline_value, candidate_value in provenance:
        if baseline_value != candidate_value:
            print(
                f"REFUSING TO COMPARE: metadata field {field} differs: "
                f"baseline={baseline_value!r}, candidate={candidate_value!r}.",
                file=sys.stderr,
            )
            return 2

    baseline_ids, baseline_id_error = _complete_row_ids(baseline_report)
    candidate_ids, candidate_id_error = _complete_row_ids(candidate_report)
    if baseline_ids is None or candidate_ids is None:
        details = []
        if baseline_id_error is not None:
            details.append(f"baseline {args.baseline.name}: {baseline_id_error}")
        if candidate_id_error is not None:
            details.append(f"candidate {args.candidate.name}: {candidate_id_error}")
        print(f"REFUSING TO COMPARE: {'; '.join(details)}.", file=sys.stderr)
        return 2

    for kind in ("successful", "errors"):
        missing = baseline_ids[kind] - candidate_ids[kind]
        extra = candidate_ids[kind] - baseline_ids[kind]
        if missing or extra:
            print(
                f"REFUSING TO COMPARE: {kind} row ids differ; "
                f"candidate missing {_format_ids(missing)}, "
                f"candidate extra {_format_ids(extra)}.",
                file=sys.stderr,
            )
            return 2

    baseline = dict(_flatten_numbers("", baseline_report.get("metrics", {})))
    candidate = dict(_flatten_numbers("", candidate_report.get("metrics", {})))

    # A gate was once run with baseline and candidate inverted and still exited 0, so keep the
    # provenance visible in the output a human reads before the comparison table.
    print(
        f"baseline: {args.baseline.name} backend={baseline_meta.get('backend', '?')} "
        f"started={baseline_meta.get('started_at', '?')}"
    )
    print(
        f"candidate: {args.candidate.name} backend={candidate_meta.get('backend', '?')} "
        f"started={candidate_meta.get('started_at', '?')}"
    )
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
