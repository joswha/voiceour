"""Report generation for Voiceour benchmark runner outputs."""

from __future__ import annotations

import argparse
import json
import math
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .metrics import (
    accepted_repair_precision,
    candidate_recall_at_k,
    canonical_term_prf,
    case_f1,
    cer,
    contains_exact_term,
    fwer,
    hard_negative_false_replacement_rate,
    nbest_oracle_coverage,
    no_op_preservation,
    over_edit_rate,
    percentiles,
    preservation_rate,
    punct_f1,
    reliability_metrics,
    risk_coverage_points,
    rtfx,
    selector_accuracy,
    uwer,
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def _row_text(row: dict[str, Any], key: str) -> str:
    value = row.get(key)
    return value if isinstance(value, str) else ""


def _metric_or_none(func, refs: list[str], hyps: list[str]):
    if not refs:
        return None
    return func(refs, hyps)


def _single_uwer(reference: str, hypothesis: str) -> float:
    return uwer([reference], [hypothesis])


def _validated_ids(rows: list[dict[str, Any]], source: str) -> list[str]:
    ids: list[str] = []
    for row in rows:
        row_id = row.get("id")
        if not isinstance(row_id, str) or not row_id:
            raise ValueError(f"{source} row has invalid id: {row_id!r}")
        ids.append(row_id)

    seen: set[str] = set()
    duplicates: set[str] = set()
    for row_id in ids:
        if row_id in seen:
            duplicates.add(row_id)
        seen.add(row_id)
    if duplicates:
        names = ", ".join(sorted(duplicates))
        raise ValueError(f"duplicate {source} ids: {names}")
    return ids


def _joined_rows(manifest_rows: list[dict[str, Any]], result_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    manifest_ids = _validated_ids(manifest_rows, "manifest")
    result_ids = _validated_ids(result_rows, "result")
    unknown_ids = sorted(set(result_ids) - set(manifest_ids))
    if unknown_ids:
        raise ValueError(f"unknown result ids not present in manifest: {', '.join(unknown_ids)}")

    manifest_by_id = dict(zip(manifest_ids, manifest_rows, strict=True))
    return [{"input": manifest_by_id[result["id"]], "result": result} for result in result_rows]


def _timing_values(rows: list[dict[str, Any]], stage: str) -> list[int | None]:
    values: list[int | None] = []
    for row in rows:
        timings = row["result"].get("timings_ms") or {}
        value = timings.get(stage)
        values.append(value if isinstance(value, int | float) else None)
    return values


def _raw_source(input_row: dict[str, Any], result_row: dict[str, Any]) -> str:
    if isinstance(input_row.get("raw_text"), str):
        return input_row["raw_text"]
    return _row_text(result_row, "raw_transcript")


def _content_reference(input_row: dict[str, Any]) -> str | None:
    if isinstance(input_row.get("reference"), str):
        return input_row["reference"]
    if isinstance(input_row.get("formatted_reference"), str):
        return input_row["formatted_reference"]
    return None


def _first_value(row: dict[str, Any], keys: tuple[str, ...]) -> tuple[bool, Any]:
    for key in keys:
        if key in row:
            return True, row[key]
    return False, None


def _string_sequence(value: Any, keys: tuple[str, ...]) -> list[str] | None:
    if not isinstance(value, list):
        return None
    strings: list[str] = []
    for item in value:
        if isinstance(item, str):
            strings.append(item)
            continue
        if isinstance(item, dict):
            for key in keys:
                candidate = item.get(key)
                if isinstance(candidate, str):
                    strings.append(candidate)
                    break
    return strings


def _candidate_ids(result_row: dict[str, Any]) -> tuple[bool, list[str] | None]:
    found, value = _first_value(result_row, ("candidate_term_ids", "candidates"))
    return found, _string_sequence(value, ("term_id", "id", "canonical_term"))


def _nbest_texts(result_row: dict[str, Any]) -> tuple[bool, list[str] | None]:
    found, value = _first_value(result_row, ("nbest_hypotheses", "nbest", "n_best", "hypotheses"))
    return found, _string_sequence(value, ("text", "transcript", "hypothesis"))


def _selected_term_id(result_row: dict[str, Any]) -> tuple[bool, str | None]:
    found, value = _first_value(result_row, ("selected_term_id", "selector_term_id", "repair_term_id"))
    return found, value if isinstance(value, str) else None


def _tech_basic_metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    inputs = [row["input"] for row in rows]
    results = [row["result"] for row in rows]
    terms = [input_row["canonical_term"] for input_row in inputs]
    expected = [input_row["expect_term"] for input_row in inputs]
    final_texts = [
        value if isinstance((value := result_row.get("final_text")), str) else None for result_row in results
    ]
    raw_texts = [
        input_row["raw_text"]
        if isinstance(input_row.get("raw_text"), str)
        else result_row["raw_transcript"]
        if isinstance(result_row.get("raw_transcript"), str)
        else None
        for input_row, result_row in zip(inputs, results, strict=True)
    ]
    false_replacements = [
        contains_exact_term(final_text, term) if not should_appear else None
        for term, should_appear, final_text in zip(terms, expected, final_texts, strict=True)
    ]
    metrics: dict[str, Any] = {
        "canonical_term": canonical_term_prf(terms, expected, final_texts),
        "hard_negatives": hard_negative_false_replacement_rate(expected, false_replacements),
        "no_op_preservation": no_op_preservation(raw_texts, final_texts, [not value for value in expected]),
    }

    untouched: list[bool | None] = []
    has_untouched_observations = False
    for result_row in results:
        found, value = _first_value(result_row, ("untouched_span_preserved", "untouched_spans_preserved"))
        observation = value if isinstance(value, bool) else None
        untouched.append(observation)
        has_untouched_observations |= found and observation is not None
    if has_untouched_observations:
        metrics["untouched_span_preservation"] = preservation_rate(untouched)
    return metrics


def _tech_breakdown(rows: list[dict[str, Any]], dimension: str) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        input_row = row["input"]
        result_row = row["result"]
        if dimension == "source":
            _, value = _first_value(result_row, ("candidate_source", "term_source", "source"))
            if not isinstance(value, str):
                value = input_row.get("project_scope")
        elif dimension == "class":
            value = input_row.get("term_class")
        else:
            value = result_row.get("risk_class", input_row.get("hard_negative_kind"))
        if isinstance(value, str) and value:
            grouped.setdefault(value, []).append(row)
    return {name: _tech_basic_metrics(group_rows) for name, group_rows in sorted(grouped.items())}


def _tech_terms_metrics(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    labeled = [
        row
        for row in rows
        if isinstance(row["input"].get("canonical_term"), str) and isinstance(row["input"].get("expect_term"), bool)
    ]
    if not labeled:
        return None

    inputs = [row["input"] for row in labeled]
    results = [row["result"] for row in labeled]
    terms = [input_row["canonical_term"] for input_row in inputs]
    expected_ids = [
        input_row.get("term_id") if input_row["expect_term"] and isinstance(input_row.get("term_id"), str) else None
        for input_row in inputs
    ]
    candidate_observations = [_candidate_ids(result_row) for result_row in results]
    candidate_lists = [value for _, value in candidate_observations]
    selected_observations = [_selected_term_id(result_row) for result_row in results]
    selected_ids = [value for _, value in selected_observations]

    metrics = _tech_basic_metrics(labeled)
    if any(found for found, _ in candidate_observations):
        metrics["candidate_recall"] = {
            "at_1": candidate_recall_at_k(expected_ids, candidate_lists, 1),
            "at_5": candidate_recall_at_k(expected_ids, candidate_lists, 5),
        }
        if any(found for found, _ in selected_observations):
            metrics["selector_accuracy"] = selector_accuracy(expected_ids, candidate_lists, selected_ids)

    nbest_observations = [_nbest_texts(result_row) for result_row in results]
    if any(found for found, _ in nbest_observations):
        metrics["nbest_oracle_coverage"] = nbest_oracle_coverage(
            [term if input_row["expect_term"] else None for term, input_row in zip(terms, inputs, strict=True)],
            [value for _, value in nbest_observations],
        )

    accepted_observations = [_first_value(result_row, ("repair_accepted", "accepted_repair")) for result_row in results]
    accepted = [value if isinstance(value, bool) else None for _, value in accepted_observations]
    if any(found and isinstance(value, bool) for found, value in accepted_observations):
        metrics["accepted_repair"] = accepted_repair_precision(expected_ids, selected_ids, accepted)

    confidence_observations = [
        _first_value(result_row, ("repair_confidence", "selector_confidence", "confidence")) for result_row in results
    ]
    confidences = [
        value if isinstance(value, int | float) and not isinstance(value, bool) else None
        for _, value in confidence_observations
    ]
    outcomes: list[bool | None] = []
    for input_row, result_row, selected_found, selected_id in zip(
        inputs, results, [found for found, _ in selected_observations], selected_ids, strict=True
    ):
        correct_found, correct_value = _first_value(result_row, ("repair_correct", "selection_correct"))
        if correct_found and isinstance(correct_value, bool):
            outcomes.append(correct_value)
        elif selected_found:
            expected_id = input_row.get("term_id") if input_row["expect_term"] else None
            outcomes.append(selected_id == expected_id)
        else:
            outcomes.append(None)
    if any(found for found, _ in confidence_observations) and any(outcome is not None for outcome in outcomes):
        reliability = reliability_metrics(confidences, outcomes)
        if reliability is not None:
            metrics["reliability"] = reliability
            metrics["risk_coverage"] = risk_coverage_points(confidences, outcomes)

    breakdowns = {
        dimension: values
        for dimension in ("source", "class", "risk")
        if (values := _tech_breakdown(labeled, dimension))
    }
    if breakdowns:
        metrics["breakdowns"] = breakdowns
    return metrics


def _confidence_by_mode(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    groups: dict[str, list[tuple[float, bool | None]]] = {}
    for row in rows:
        result_row = row["result"]
        mode = result_row.get("confidence_mode")
        confidence = result_row.get("confidence")
        if not isinstance(mode, str) or mode == "none":
            continue
        if not isinstance(confidence, int | float) or isinstance(confidence, bool):
            continue
        reference = _content_reference(row["input"])
        outcome = (
            _single_uwer(reference, _row_text(result_row, "raw_transcript")) == 0.0 if reference is not None else None
        )
        groups.setdefault(mode, []).append((float(confidence), outcome))
    if not groups:
        return None
    by_mode: dict[str, Any] = {}
    for mode, pairs in sorted(groups.items()):
        confidences = [confidence for confidence, _ in pairs]
        outcomes = [outcome for _, outcome in pairs]
        entry: dict[str, Any] = {"count": len(pairs), "mean_confidence": sum(confidences) / len(confidences)}
        if all(math.isfinite(value) and 0.0 <= value <= 1.0 for value in confidences):
            reliability = reliability_metrics(confidences, outcomes)
            if reliability is not None:
                entry["reliability"] = reliability
                entry["risk_coverage"] = risk_coverage_points(confidences, outcomes)
        by_mode[mode] = entry
    return by_mode


def build_report(
    results_jsonl: Path, manifest_jsonl: Path, tier: str, mode: str, output_dir: Path | None = None
) -> tuple[dict[str, Any], Path]:
    raw_results = read_jsonl(results_jsonl)
    meta = raw_results[0] if raw_results and raw_results[0].get("type") == "bench_meta" else {}
    result_rows = [row for row in raw_results if row.get("type") == "row"]
    manifest_rows = read_jsonl(manifest_jsonl)
    joined = _joined_rows(manifest_rows, result_rows)
    successful = [row for row in joined if not row["result"].get("error")]
    errors = [row for row in joined if row["result"].get("error")]

    content_refs: list[str] = []
    raw_hyps: list[str] = []
    final_hyps: list[str] = []
    formatted_refs: list[str] = []
    formatted_hyps: list[str] = []
    raw_sources: list[str] = []
    final_sources: list[str] = []
    audio_seconds: list[float | None] = []
    asr_ms: list[int | None] = []

    for row in successful:
        input_row = row["input"]
        result_row = row["result"]
        reference = _content_reference(input_row)
        if reference is not None:
            content_refs.append(reference)
            raw_hyps.append(_row_text(result_row, "raw_transcript"))
            final_hyps.append(_row_text(result_row, "final_text"))
        formatted_reference = input_row.get("formatted_reference")
        if isinstance(formatted_reference, str):
            formatted_refs.append(formatted_reference)
            formatted_hyps.append(_row_text(result_row, "final_text"))
        raw_sources.append(_raw_source(input_row, result_row))
        final_sources.append(_row_text(result_row, "final_text"))
        audio_value = result_row.get("audio_s", input_row.get("audio_s"))
        audio_seconds.append(float(audio_value) if isinstance(audio_value, int | float) else None)
        timings = result_row.get("timings_ms") or {}
        asr_value = timings.get("asr")
        asr_ms.append(int(asr_value) if isinstance(asr_value, int | float) else None)

    metrics: dict[str, Any] = {
        "uwer_raw": _metric_or_none(uwer, content_refs, raw_hyps),
        "uwer_final": _metric_or_none(uwer, content_refs, final_hyps),
        "cer_final": _metric_or_none(cer, content_refs, final_hyps),
        "fwer_final": _metric_or_none(fwer, formatted_refs, formatted_hyps),
        "punct_f1": _metric_or_none(punct_f1, formatted_refs, formatted_hyps),
        "case_f1": _metric_or_none(case_f1, formatted_refs, formatted_hyps),
        "over_edit_rate": over_edit_rate(raw_sources, final_sources) if raw_sources else None,
        "rtfx": rtfx(audio_seconds, asr_ms),
        "latency_ms": {
            stage: percentiles(_timing_values(successful, stage))
            for stage in ("asr", "asr_load", "asr_inference", "cleanup", "refine", "total")
        },
    }
    tech_terms = _tech_terms_metrics(successful)
    if tech_terms is not None:
        metrics["tech_terms"] = tech_terms
    confidence_by_mode = _confidence_by_mode(successful)
    if confidence_by_mode is not None:
        metrics["confidence_by_mode"] = confidence_by_mode

    worst: list[dict[str, Any]] = []
    for row in successful:
        input_row = row["input"]
        result_row = row["result"]
        reference = _content_reference(input_row)
        if reference is None:
            continue
        final_text = _row_text(result_row, "final_text")
        worst.append(
            {
                "id": result_row.get("id"),
                "uwer_final": _single_uwer(reference, final_text),
                "reference": reference,
                "raw_transcript": _row_text(result_row, "raw_transcript"),
                "final_text": final_text,
                "error": result_row.get("error"),
            }
        )
    worst.sort(key=lambda item: item["uwer_final"], reverse=True)

    report: dict[str, Any] = {
        "generated_at": datetime.now(UTC).isoformat(),
        "tier": tier,
        "mode": mode,
        "meta": meta,
        "counts": {
            "manifest_rows": len(manifest_rows),
            "result_rows": len(result_rows),
            "successful_rows": len(successful),
            "error_rows": len(errors),
            "formatted_reference_rows": len(formatted_refs),
        },
        "successful_row_ids": sorted(row["result"]["id"] for row in successful),
        "error_row_ids": sorted(row["result"]["id"] for row in errors),
        "metrics": metrics,
        "worst_10": worst[:10],
        "anchors": {"librispeech_parakeet_tdt_0_6b_v3_nemo": {"test_clean_wer": 1.93, "test_other_wer": 3.59}}
        if tier == "librispeech"
        else {},
        "inputs": {"results_jsonl": str(results_jsonl), "manifest_jsonl": str(manifest_jsonl)},
    }

    output_dir = output_dir or repo_root() / "benchmarks" / "results"
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    # Same reason the results JSONL carries the backend: an A/B sweep writes one
    # report per backend for the same tier and mode. The backend comes from the
    # run's own metadata, so the report can never claim a backend it did not read.
    backend = meta.get("backend")
    parts = [stamp, tier, backend, mode] if isinstance(backend, str) and backend else [stamp, tier, mode]
    output_path = output_dir / f"{'-'.join(parts)}.json"
    output_path.write_text(json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    return report, output_path


def _format_value(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.4f}"
    return str(value)


def markdown_table(report: dict[str, Any]) -> str:
    metrics = report["metrics"]
    rows = [
        ("tier", report["tier"]),
        ("mode", report["mode"]),
        # The backend is the variable under test in an A/B; two tables that omit
        # it are indistinguishable on screen.
        ("backend", (report.get("meta") or {}).get("backend")),
        ("rows", report["counts"]["successful_rows"]),
        ("errors", report["counts"]["error_rows"]),
        ("uwer raw", metrics.get("uwer_raw")),
        ("uwer final", metrics.get("uwer_final")),
        ("cer final", metrics.get("cer_final")),
        ("fwer final", metrics.get("fwer_final")),
        (
            "punct micro F1",
            (metrics.get("punct_f1") or {}).get("micro", {}).get("f1") if metrics.get("punct_f1") else None,
        ),
        (
            "case overall F1",
            (metrics.get("case_f1") or {}).get("overall", {}).get("f1") if metrics.get("case_f1") else None,
        ),
        ("over-edit", metrics.get("over_edit_rate")),
        ("RTFx", metrics.get("rtfx")),
        ("p95 total ms", metrics.get("latency_ms", {}).get("total", {}).get("p95")),
    ]
    tech_terms = metrics.get("tech_terms")
    if isinstance(tech_terms, dict):
        canonical = tech_terms.get("canonical_term") or {}
        hard_negatives = tech_terms.get("hard_negatives") or {}
        candidate = tech_terms.get("candidate_recall") or {}
        rows.extend(
            [
                ("canonical term precision", canonical.get("precision")),
                ("canonical term recall", canonical.get("recall")),
                ("canonical term F1", canonical.get("f1")),
                ("hard-negative false replacement rate", hard_negatives.get("rate")),
                ("hard-negative false replacements / 10k", hard_negatives.get("per_10k_opportunities")),
                ("candidate Recall@1", (candidate.get("at_1") or {}).get("recall")),
                ("candidate Recall@5", (candidate.get("at_5") or {}).get("recall")),
                ("n-best oracle coverage", (tech_terms.get("nbest_oracle_coverage") or {}).get("coverage")),
                ("selector accuracy", (tech_terms.get("selector_accuracy") or {}).get("accuracy")),
                ("accepted-repair precision", (tech_terms.get("accepted_repair") or {}).get("precision")),
                ("Brier score", (tech_terms.get("reliability") or {}).get("brier")),
                ("ECE", (tech_terms.get("reliability") or {}).get("ece")),
            ]
        )
    lines = ["| metric | value |", "| --- | ---: |"]
    lines.extend(f"| {name} | {_format_value(value)} |" for name, value in rows)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build a Voiceour benchmark report from runner JSONL output.")
    parser.add_argument("results_jsonl", type=Path)
    parser.add_argument("manifest_jsonl", type=Path)
    parser.add_argument("--tier", required=True)
    parser.add_argument("--mode", required=True)
    args = parser.parse_args(argv)
    report, output_path = build_report(args.results_jsonl, args.manifest_jsonl, args.tier, args.mode)
    print(markdown_table(report))
    print(f"\nReport: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
