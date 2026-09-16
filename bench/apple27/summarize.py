"""Score matched Apple 27 prototype rows using Voiceour's existing benchmark metrics."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

from coreai_common import digest, read_json, write_json

from voiceour_bench import metrics
from voiceour_bench.normalizer import english_normalize


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def row_map(objects: list[dict]) -> dict[str, dict]:
    result = {}
    for row in objects:
        if row.get("type") != "row":
            continue
        if row["id"] in result:
            raise ValueError(f"Duplicate result id: {row['id']}")
        result[row["id"]] = row
    return result


def special_tokens(text: str, *, numbers: bool) -> list[str]:
    tokens = english_normalize(text).split()
    if numbers:
        return [token for token in tokens if re.search(r"\d", token)]
    return [token for token in tokens if token in {"not", "no", "never", "without", "neither", "nor"}]


def quality(inputs: list[dict], results: dict[str, dict], key: str) -> dict:
    references = [row["reference"] for row in inputs]
    formatted = [row.get("formatted_reference", row["reference"]) for row in inputs]
    hypotheses = []
    for row in inputs:
        output = results.get(row["id"], {})
        text = output.get(key, "")
        if key == "final_text" and output.get("error"):
            text = ""
        hypotheses.append(text)
    return {
        "uwer": metrics.uwer(references, hypotheses),
        "cer": metrics.cer(references, hypotheses),
        "formatted_wer": metrics.fwer(formatted, hypotheses),
        "punctuation_micro_f1": metrics.punct_f1(formatted, hypotheses)["micro"]["f1"],
        "case_f1": metrics.case_f1(formatted, hypotheses)["overall"]["f1"],
        "technical_terms": metrics.canonical_term_prf(
            [row.get("canonical_term") for row in inputs],
            [bool(row.get("expect_term")) for row in inputs],
            hypotheses,
        ),
    }


def score(inputs: list[dict], path: Path, baseline: dict[str, dict]) -> dict:
    objects = read_jsonl(path)
    results = row_map(objects)
    expected = {row["id"] for row in inputs}
    extra = set(results) - expected
    if extra:
        raise ValueError(f"Unexpected ids in {path}: {sorted(extra)}")
    missing = expected - set(results)
    failed = [row for row in inputs if row["id"] not in results or results[row["id"]].get("error")]
    metadata = [row for row in objects if row.get("type") != "row"]
    blocked = any(row.get("type") == "blocked" for row in metadata)
    groups = {"all": inputs}
    for tier in sorted({row.get("tier", "unknown") for row in inputs}):
        groups[tier] = [row for row in inputs if row.get("tier", "unknown") == tier]
    scores = {}
    for tier, group in groups.items():
        completed = [
            results[row["id"]] for row in group if row["id"] in results and not results[row["id"]].get("error")
        ]
        scores[tier] = {
            "rows": len(group),
            "completed": len(completed),
            "errors_or_missing": len(group) - len(completed),
            # A recognizer that returns nothing for a clip with speech is a failure the
            # metrics only show as deletions; name it so it cannot pass as a clean run.
            "empty_transcripts": sum(
                1
                for row in group
                if not row.get("expect_silence")
                and row["id"] in results
                and not results[row["id"]].get("error")
                and not (results[row["id"]].get("raw_transcript") or "").strip()
            ),
            "raw": quality(group, results, "raw_transcript") if not blocked else None,
            "final": quality(group, results, "final_text") if not blocked else None,
            "asr_ms": metrics.percentiles(row.get("timings_ms", {}).get("asr_inference") for row in completed),
            "previously_seen_shape_asr_ms": metrics.percentiles(
                row.get("timings_ms", {}).get("asr_inference")
                for row in completed
                if row.get("details", {}).get("first_seen_shape_calls") == 0
            ),
            "first_seen_shape_rows": sum(
                (row.get("details", {}).get("first_seen_shape_calls") or 0) > 0 for row in completed
            ),
            "postprocess_ms": metrics.percentiles(row.get("timings_ms", {}).get("postprocess") for row in completed),
            "total_ms": metrics.percentiles(row.get("timings_ms", {}).get("total") for row in completed),
            "rtfx": metrics.rtfx(
                [row.get("audio_s") for row in completed],
                [row.get("timings_ms", {}).get("asr_inference") for row in completed],
            ),
        }
    changes = []
    number_changes = []
    negation_changes = []
    raw_changes = []
    final_changes = []
    for row in inputs:
        before = baseline.get(row["id"])
        after = results.get(row["id"])
        if not before or not after or before.get("error") or after.get("error"):
            continue
        original = before["cleaned_text"]
        generated = after["final_text"]
        reference = row["reference"]
        before_error = metrics.uwer([reference], [original])
        after_error = metrics.uwer([reference], [generated])
        changes.append(
            "improved" if after_error < before_error else "worsened" if after_error > before_error else "unchanged"
        )
        if special_tokens(original, numbers=True) != special_tokens(generated, numbers=True):
            number_changes.append(row["id"])
        if special_tokens(original, numbers=False) != special_tokens(generated, numbers=False):
            negation_changes.append(row["id"])
        raw_changes.append(original)
        final_changes.append(generated)
    run_path = path.with_suffix(".run.json")
    return {
        "path": str(path),
        "results_sha256": digest(path),
        "status": "blocked" if blocked else "partial" if missing else "completed_with_errors" if failed else "complete",
        "expected_rows": len(inputs),
        "received_rows": len(results),
        "errors_or_missing": len(failed),
        "errors": [
            {"id": row["id"], "error": results.get(row["id"], {}).get("error", "missing_result")} for row in failed
        ],
        "metadata": metadata,
        "scores": scores,
        "versus_baseline_final": {
            "row_wer_changes": dict(Counter(changes)),
            "content_edit_rate": metrics.over_edit_rate(raw_changes, final_changes) if raw_changes else None,
            "number_token_changes": number_changes,
            "negation_token_changes": negation_changes,
            "note": "Changed token lists flag inspection candidates, not proven semantic errors.",
        },
        "process_measurement": read_json(run_path) if run_path.exists() else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--result", action="append", required=True, metavar="NAME=PATH")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    inputs = read_jsonl(arguments.manifest)
    baseline = row_map(read_jsonl(arguments.baseline))
    if len({row["id"] for row in inputs}) != len(inputs):
        raise ValueError("Duplicate manifest ids")
    results = {}
    for specification in arguments.result:
        name, path = specification.split("=", 1)
        if name in results:
            raise ValueError(f"Duplicate candidate name: {name}")
        results[name] = score(inputs, Path(path), baseline)
    report = {
        "schema_version": 1,
        "experiment": "macOS 27 native model prototypes",
        "manifest_sha256": digest(arguments.manifest),
        "rows": len(inputs),
        "candidates": results,
        "limitations": [
            "Exploratory shared-desktop run; not an idle-machine production promotion gate.",
            "Apple system model weights are OS-managed and not independently revision-pinnable.",
            "Process-first timing is not guaranteed model-cold; platform services can retain models.",
            "Per-backend timing boundaries are recorded in metadata; input conversion may differ.",
            "Client RSS excludes shared Apple model services and may exclude the Parakeet sidecar; "
            "not an apples-to-apples model-memory comparison.",
            "Errors/missing outputs are counted; final-text quality treats them as empty outputs, "
            "never silently drops them.",
            "Natural-speech and synthetic technical-term tiers are reported separately.",
        ],
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    write_json(arguments.output, report)
    for name, result in results.items():
        total = result["scores"]["all"]
        print(
            json.dumps(
                {
                    "candidate": name,
                    "status": result["status"],
                    "errors": result["errors_or_missing"],
                    "raw_uwer": total["raw"]["uwer"] if total["raw"] else None,
                    "final_uwer": total["final"]["uwer"] if total["final"] else None,
                    "asr_ms": total["asr_ms"],
                    "postprocess_ms": total["postprocess_ms"],
                }
            )
        )


if __name__ == "__main__":
    main()
