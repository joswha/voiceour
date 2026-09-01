"""Score a maximum-power harness run (segment 5): recall-primary, no energy.

Inputs: one general results file covering warmup+timed passes over the 96-row
general corpus, and two jargon results files (identical invocations) over the
456-row jargon corpus.

Primary metric: jargon_term_recall (case-sensitive canonical containment over
non-negative rows of the frozen terms file). Hard gates, each a nonzero exit:
any error row; any transcript differing across timed general passes; jargon
pass 1 not byte-identical to pass 2 (raw and final); jargon_false_terms > 0;
uwer_mix above its ceiling; general inference p95 above its ceiling; RTFx below
its floor; peak footprint above its ceiling.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from voiceour_bench.metrics import contains_exact_term, uwer  # noqa: E402


def fail(message: str) -> None:
    print(f"score_v5.py: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise SystemExit(f"score_v5.py: FAIL: {path}:{number} is not JSON: {error}") from error
    return rows


def rows_by_id(lines: list[dict], label: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    errors = 0
    for row in (line for line in lines if line.get("type") == "row"):
        if row.get("error") is not None:
            errors += 1
        out[str(row.get("id", ""))] = row
    if errors:
        fail(f"{label}: {errors} error rows")
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--general-results", required=True, type=Path)
    parser.add_argument("--jargon-results-1", required=True, type=Path)
    parser.add_argument("--jargon-results-2", required=True, type=Path)
    parser.add_argument("--general-corpus", required=True, type=Path)
    parser.add_argument("--jargon-corpus", required=True, type=Path)
    parser.add_argument("--jargon-terms", required=True, type=Path)
    parser.add_argument("--warmup-passes", required=True, type=int)
    parser.add_argument("--timed-passes", required=True, type=int)
    parser.add_argument("--peak-footprint-bytes", required=True, type=int)
    parser.add_argument("--peak-resident-bytes", required=True, type=int)
    parser.add_argument("--latency-ceiling-ms", required=True, type=float)
    parser.add_argument("--rtfx-floor", required=True, type=float)
    parser.add_argument("--footprint-ceiling-mb", required=True, type=float)
    parser.add_argument("--uwer-mix-ceiling", required=True, type=float)
    args = parser.parse_args()

    general_corpus = read_jsonl(args.general_corpus)
    jargon_corpus = read_jsonl(args.jargon_corpus)
    terms = json.loads(args.jargon_terms.read_text(encoding="utf-8"))

    general_rows = rows_by_id(read_jsonl(args.general_results), "general")
    jargon_1 = rows_by_id(read_jsonl(args.jargon_results_1), "jargon pass 1")
    jargon_2 = rows_by_id(read_jsonl(args.jargon_results_2), "jargon pass 2")

    total_passes = args.warmup_passes + args.timed_passes
    if args.timed_passes < 3:
        fail(f"timed_passes {args.timed_passes} is below the required three repetitions")

    # --- general passes: presence, cross-pass identity, latency ---------------
    for row in general_corpus:
        for index in range(total_passes):
            if f"{row['id']}#p{index}" not in general_rows:
                fail(f"general row {row['id']}#p{index} missing")

    timed_range = range(args.warmup_passes, total_passes)
    for row in general_corpus:
        reference_pass = general_rows[f"{row['id']}#p{args.warmup_passes}"]
        for index in timed_range:
            candidate = general_rows[f"{row['id']}#p{index}"]
            for field in ("raw_transcript", "final_text"):
                if candidate.get(field) != reference_pass.get(field):
                    fail(f"general row {row['id']} pass {index} {field} differs across timed passes")

    pass_p95: list[float] = []
    pass_p50: list[float] = []
    total_audio_s = 0.0
    total_infer_ms = 0.0
    for index in timed_range:
        latencies = sorted(
            float(general_rows[f"{row['id']}#p{index}"]["timings_ms"]["asr_inference"])
            for row in general_corpus
        )
        count = len(latencies)
        pass_p95.append(latencies[min(count - 1, int(round(0.95 * (count - 1))))])
        pass_p50.append(statistics.median(latencies))
        total_audio_s += sum(float(row["audio_s"]) for row in general_corpus)
        total_infer_ms += sum(
            float(general_rows[f"{row['id']}#p{index}"]["timings_ms"]["asr_inference"])
            for row in general_corpus
        )
    p95 = statistics.median(pass_p95)
    p50 = statistics.median(pass_p50)
    rtfx_value = (total_audio_s * 1000.0) / total_infer_ms if total_infer_ms > 0 else 0.0
    load_ms = statistics.median(
        float(row.get("timings_ms", {}).get("asr_load", 0)) for row in general_rows.values()
    )

    # --- jargon passes: presence, determinism pair ----------------------------
    for row in jargon_corpus:
        row_id = f"{row['id']}#j0"
        if row_id not in jargon_1 or row_id not in jargon_2:
            fail(f"jargon row {row_id} missing from a pass")
        for field in ("raw_transcript", "final_text"):
            if jargon_1[row_id].get(field) != jargon_2[row_id].get(field):
                fail(f"jargon row {row_id} {field} differs between pass 1 and pass 2")

    # --- accuracy -------------------------------------------------------------
    general_refs = [row["reference"] for row in general_corpus]
    general_hyps = [
        general_rows[f"{row['id']}#p{args.warmup_passes}"]["final_text"] for row in general_corpus
    ]
    jargon_refs = [row["reference"] for row in jargon_corpus]
    jargon_hyps = [jargon_1[f"{row['id']}#j0"]["final_text"] for row in jargon_corpus]

    uwer_general = uwer(general_refs, general_hyps)
    uwer_jargon = uwer(jargon_refs, jargon_hyps)
    uwer_mix = uwer(general_refs + jargon_refs, general_hyps + jargon_hyps)

    expected = {row_id: info for row_id, info in terms.items() if info.get("domain") != "negative"}
    negatives = {row_id: info for row_id, info in terms.items() if info.get("domain") == "negative"}
    recall_hits = sum(
        1
        for row_id, info in expected.items()
        if info.get("canonical")
        and contains_exact_term(jargon_1[f"{row_id}#j0"]["final_text"], info["canonical"])
    )
    recall = recall_hits / len(expected) if expected else 0.0
    false_terms = sum(
        1
        for row_id, info in negatives.items()
        if info.get("canonical")
        and contains_exact_term(jargon_1[f"{row_id}#j0"]["final_text"], info["canonical"])
    )
    misses = [
        f"{row_id}:{info['canonical']}"
        for row_id, info in sorted(expected.items())
        if info.get("canonical")
        and not contains_exact_term(jargon_1[f"{row_id}#j0"]["final_text"], info["canonical"])
    ]

    # --- gates ----------------------------------------------------------------
    footprint_mb = args.peak_footprint_bytes / 1e6
    if false_terms > 0:
        fail(f"jargon_false_terms {false_terms} > 0")
    if uwer_mix > args.uwer_mix_ceiling:
        fail(f"uwer_mix {uwer_mix:.6f} exceeds ceiling {args.uwer_mix_ceiling}")
    if p95 > args.latency_ceiling_ms:
        fail(f"general inference p95 {p95:.2f} ms exceeds ceiling {args.latency_ceiling_ms}")
    if rtfx_value < args.rtfx_floor:
        fail(f"RTFx {rtfx_value:.2f} below floor {args.rtfx_floor}")
    if footprint_mb > args.footprint_ceiling_mb:
        fail(f"peak footprint {footprint_mb:.1f} MB exceeds ceiling {args.footprint_ceiling_mb}")

    # --- metrics --------------------------------------------------------------
    print(f"METRIC jargon_term_recall={recall:.6f}")
    print(f"METRIC uwer_mix={uwer_mix:.6f}")
    print(f"METRIC uwer_general={uwer_general:.6f}")
    print(f"METRIC uwer_jargon={uwer_jargon:.6f}")
    print(f"METRIC jargon_false_terms={false_terms}")
    print(f"METRIC asr_inference_p95_ms={p95:g}")
    print(f"METRIC asr_inference_p50_ms={p50:g}")
    print(f"METRIC rtfx={rtfx_value:.4f}")
    print(f"METRIC load_ms={load_ms:g}")
    print(f"METRIC peak_phys_footprint_mb={footprint_mb:.3f}")
    print(f"METRIC peak_rss_mb={args.peak_resident_bytes / 1e6:.3f}")
    print("METRIC error_rows=0")
    print(f"METRIC recall_hits={recall_hits}")

    domains: dict[str, list[str]] = {}
    for row_id, info in expected.items():
        domains.setdefault(info.get("domain", "?"), []).append(row_id)
    domain_recall = {
        domain: sum(
            1
            for row_id in ids
            if contains_exact_term(
                jargon_1[f"{row_id}#j0"]["final_text"], expected[row_id]["canonical"]
            )
        )
        for domain, ids in sorted(domains.items())
    }
    print(
        "ASI term_recall_by_domain="
        + "|".join(f"{domain}:{hits}/{len(domains[domain])}" for domain, hits in domain_recall.items())
    )
    print(f"ASI term_misses={len(misses)}")
    print("ASI term_miss_examples=" + "|".join(misses[:8]))
    print(f"ASI pass_p95_ms={','.join(f'{value:g}' for value in pass_p95)}")
    print(f"ASI pass_p50_ms={','.join(f'{value:g}' for value in pass_p50)}")
    import hashlib

    jargon_blob = "\n".join(
        jargon_1[f"{row['id']}#j0"]["final_text"] for row in jargon_corpus
    ).encode()
    general_blob = "\n".join(general_hyps).encode()
    print(f"ASI jargon_transcript_sha256={hashlib.sha256(jargon_blob).hexdigest()}")
    print(f"ASI general_transcript_sha256={hashlib.sha256(general_blob).hexdigest()}")


if __name__ == "__main__":
    main()
