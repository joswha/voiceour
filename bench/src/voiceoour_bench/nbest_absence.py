"""N-best target-absence analysis — the Stage 5 (KWS) gate condition.

For every positive utterance (``expect_term`` true) this reports whether the
labeled canonical term is present in ANY decoded hypothesis (rank-0 plus every
n-best alternative), or absent from the entire beam. A high absence rate is the
precondition the exploration doc requires before a separate keyword spotter /
large-list retriever can be justified: reranking cannot recover a term that is
absent from every hypothesis, so persistent absence is what points past n-best
toward an independent acoustic channel.

Pure and deterministic. Term presence uses the exact, case-sensitive canonical
surface match shared with the term metrics. Absence is measured over the union
of the row's ``hypotheses`` texts (falling back to the single final transcript
when a run carries no n-best evidence).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .metrics import contains_exact_term

_FINAL_FIELDS: tuple[str, ...] = ("raw_transcript", "final_text", "cleaned_text")


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: expected a JSON object")
            rows.append(value)
    return rows


def hypothesis_texts(result_row: dict[str, Any]) -> list[str]:
    """Return every hypothesis text for a row (n-best union, else the final text)."""
    hyps = result_row.get("hypotheses")
    texts: list[str] = []
    if isinstance(hyps, list):
        for h in hyps:
            if isinstance(h, dict) and isinstance(h.get("text"), str):
                texts.append(h["text"])
    if texts:
        return texts
    for field in _FINAL_FIELDS:
        value = result_row.get(field)
        if isinstance(value, str) and value:
            return [value]
    return []


def target_absence(manifest_rows: list[dict[str, Any]], result_rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Compute the n-best target-absence rate over positive (expect_term) rows."""
    manifest_by_id = {r["id"]: r for r in manifest_rows if "id" in r}
    results_by_id = {r["id"]: r for r in result_rows if r.get("type") == "row" and "id" in r}

    opportunities = 0
    absent = 0
    covered = 0
    absent_ids: list[str] = []
    max_hyps = 0
    for row_id, man in manifest_by_id.items():
        if man.get("expect_term") is not True:
            continue
        term = man.get("canonical_term")
        if not isinstance(term, str) or not term:
            continue
        result = results_by_id.get(row_id)
        if result is None:
            continue
        opportunities += 1
        texts = hypothesis_texts(result)
        max_hyps = max(max_hyps, len(texts))
        if any(contains_exact_term(text, term) for text in texts):
            covered += 1
        else:
            absent += 1
            absent_ids.append(row_id)

    absence_rate = absent / opportunities if opportunities else None
    return {
        "opportunities": opportunities,
        "covered_in_nbest": covered,
        "absent_from_nbest": absent,
        "absence_rate": absence_rate,
        "max_hypotheses_seen": max_hyps,
        "absent_ids": sorted(absent_ids),
    }


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="N-best target-absence (Stage 5 KWS gate).")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)

    summary = target_absence(_read_jsonl(args.manifest), _read_jsonl(args.results))
    payload = json.dumps(summary, indent=2, sort_keys=True)
    if args.out:
        args.out.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
