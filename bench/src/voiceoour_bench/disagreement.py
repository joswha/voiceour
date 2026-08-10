"""Backend-disagreement analysis for VoiceOour ASR routing decisions.

Compares two backend runs (e.g. Apple SpeechAnalyzer vs. Parakeet) over the same
utterances and reports, per corpus, how often their transcripts disagree and how
often such a disagreement coincides with exactly one backend recovering a labeled
canonical term the other missed. That exclusive-recovery-on-disagreement rate is
the routing signal: it estimates how much a second backend would add if consulted
only when the primary is uncertain.

Everything here is pure and deterministic. Transcript equality uses the same
Whisper-style English normalization the WER metrics use, so "disagreement" tracks
content differences rather than casing/punctuation. Term recovery uses the exact,
case-sensitive canonical-surface match shared with the term metrics.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .metrics import contains_exact_term
from .normalizer import english_normalize

DEFAULT_TEXT_FIELD = "raw_transcript"
_FALLBACK_FIELDS: tuple[str, ...] = ("raw_transcript", "final_text")


@dataclass(frozen=True)
class RunRecord:
    """A single aligned utterance from one backend run."""

    transcript: str
    canonical_term: str | None
    expect_term: bool


@dataclass(frozen=True)
class Run:
    """One backend's results joined against its manifest, keyed by utterance id."""

    label: str
    records: dict[str, RunRecord]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped:
                rows.append(json.loads(stripped))
    return rows


def _row_text(row: dict[str, Any], field_name: str) -> str:
    value = row.get(field_name)
    if isinstance(value, str):
        return value
    for fallback in _FALLBACK_FIELDS:
        if fallback == field_name:
            continue
        candidate = row.get(fallback)
        if isinstance(candidate, str):
            return candidate
    return ""


def build_run(
    result_rows: list[dict[str, Any]],
    manifest_rows: list[dict[str, Any]],
    *,
    label: str,
    text_field: str = DEFAULT_TEXT_FIELD,
) -> Run:
    """Join result rows against manifest rows into a keyed run.

    Rows tagged ``bench_meta`` are ignored; every other row with a string ``id``
    contributes a record. The last row wins on duplicate ids.
    """

    manifest_by_id: dict[str, dict[str, Any]] = {}
    for row in manifest_rows:
        rid = row.get("id")
        if isinstance(rid, str):
            manifest_by_id[rid] = row

    records: dict[str, RunRecord] = {}
    for row in result_rows:
        if row.get("type") == "bench_meta":
            continue
        rid = row.get("id")
        if not isinstance(rid, str):
            continue
        manifest = manifest_by_id.get(rid, {})
        canonical = manifest.get("canonical_term")
        canonical = canonical if isinstance(canonical, str) and canonical else None
        expect = manifest.get("expect_term")
        records[rid] = RunRecord(
            transcript=_row_text(row, text_field),
            canonical_term=canonical,
            expect_term=expect if isinstance(expect, bool) else False,
        )
    return Run(label=label, records=records)


def _derive_label(meta: dict[str, Any], results_path: Path) -> str:
    for key in ("backend", "engine", "asr_backend", "model", "mode"):
        value = meta.get(key)
        if isinstance(value, str) and value:
            return value
    return results_path.stem


def load_run(
    results_path: Path,
    manifest_path: Path,
    *,
    label: str | None = None,
    text_field: str = DEFAULT_TEXT_FIELD,
) -> Run:
    raw = read_jsonl(results_path)
    meta = raw[0] if raw and raw[0].get("type") == "bench_meta" else {}
    result_rows = [row for row in raw if row.get("type") == "row"]
    manifest_rows = read_jsonl(manifest_path)
    resolved_label = label or _derive_label(meta, results_path)
    return build_run(result_rows, manifest_rows, label=resolved_label, text_field=text_field)


def align_ids(run_a: Run, run_b: Run) -> list[str]:
    """Return the sorted shared ids, refusing to align mismatched id sets."""

    ids_a = set(run_a.records)
    ids_b = set(run_b.records)
    if ids_a != ids_b:
        only_a = sorted(ids_a - ids_b)
        only_b = sorted(ids_b - ids_a)
        raise ValueError(
            "cannot align runs with mismatched id sets: "
            f"{len(only_a)} only in {run_a.label!r} (e.g. {only_a[:5]}), "
            f"{len(only_b)} only in {run_b.label!r} (e.g. {only_b[:5]})"
        )
    return sorted(ids_a)


def _term_label(record_a: RunRecord, record_b: RunRecord) -> tuple[str | None, bool]:
    if record_a.canonical_term is not None:
        return record_a.canonical_term, record_a.expect_term
    if record_b.canonical_term is not None:
        return record_b.canonical_term, record_b.expect_term
    return None, False


def _ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def disagreement_summary(run_a: Run, run_b: Run) -> dict[str, Any]:
    """Compute the JSON-able disagreement + term-recovery routing summary.

    Raises ``ValueError`` (via :func:`align_ids`) when the two runs do not cover
    exactly the same utterance ids.
    """

    ids = align_ids(run_a, run_b)

    disagreements = 0
    disagreeing_ids: list[str] = []
    term_opportunities = 0
    both_have = neither_have = only_a = only_b = 0
    disagreement_term_opportunities = 0
    recovered_one_missed = 0
    a_recovers_on_disagreement = 0
    b_recovers_on_disagreement = 0

    for rid in ids:
        record_a = run_a.records[rid]
        record_b = run_b.records[rid]
        disagree = english_normalize(record_a.transcript) != english_normalize(record_b.transcript)
        if disagree:
            disagreements += 1
            disagreeing_ids.append(rid)

        canonical, expect = _term_label(record_a, record_b)
        if expect and canonical:
            term_opportunities += 1
            a_has = contains_exact_term(record_a.transcript, canonical)
            b_has = contains_exact_term(record_b.transcript, canonical)
            if a_has and b_has:
                both_have += 1
            elif a_has:
                only_a += 1
            elif b_has:
                only_b += 1
            else:
                neither_have += 1
            if disagree:
                disagreement_term_opportunities += 1
                if a_has and not b_has:
                    a_recovers_on_disagreement += 1
                    recovered_one_missed += 1
                elif b_has and not a_has:
                    b_recovers_on_disagreement += 1
                    recovered_one_missed += 1

    aligned = len(ids)
    exclusive_recovery = only_a + only_b
    return {
        "run_a": run_a.label,
        "run_b": run_b.label,
        "aligned": aligned,
        "disagreements": disagreements,
        "disagreement_rate": _ratio(disagreements, aligned),
        "term_opportunities": term_opportunities,
        "term_recovery": {
            "both": both_have,
            "neither": neither_have,
            "only_run_a": only_a,
            "only_run_b": only_b,
            "exclusive_recovery": exclusive_recovery,
            "exclusive_recovery_rate": _ratio(exclusive_recovery, term_opportunities),
        },
        "routing_signal": {
            "disagreement_term_opportunities": disagreement_term_opportunities,
            "term_recovery_on_disagreement": recovered_one_missed,
            "term_recovery_on_disagreement_rate": _ratio(recovered_one_missed, disagreement_term_opportunities),
            "run_a_recovers_on_disagreement": a_recovers_on_disagreement,
            "run_b_recovers_on_disagreement": b_recovers_on_disagreement,
        },
        "disagreeing_ids": disagreeing_ids,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare two backend runs for transcript disagreement and the term-recovery routing signal.",
    )
    parser.add_argument("--run-a-results", type=Path, required=True)
    parser.add_argument("--run-a-manifest", type=Path, required=True)
    parser.add_argument("--run-b-results", type=Path, required=True)
    parser.add_argument("--run-b-manifest", type=Path, required=True)
    parser.add_argument("--run-a-label", default=None, help="label for run A (defaults to backend meta or file stem)")
    parser.add_argument("--run-b-label", default=None, help="label for run B (defaults to backend meta or file stem)")
    parser.add_argument(
        "--text-field", default=DEFAULT_TEXT_FIELD, help="result field to compare (default raw_transcript)"
    )
    parser.add_argument("--out", type=Path, default=None, help="write JSON summary here instead of stdout")
    args = parser.parse_args(argv)

    run_a = load_run(args.run_a_results, args.run_a_manifest, label=args.run_a_label, text_field=args.text_field)
    run_b = load_run(args.run_b_results, args.run_b_manifest, label=args.run_b_label, text_field=args.text_field)
    summary = disagreement_summary(run_a, run_b)

    text = json.dumps(summary, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if args.out is not None:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
