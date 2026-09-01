"""Score one segment-3 `autoresearch.sh` run: energy primary, accuracy as guards.

Segment 3 splits the run into two `voiceour-bench pipeline` invocations:
- general96 with `#p<n>` pass suffixes (1 warmup + timed passes): latency metrics,
  general accuracy, cross-pass determinism — unchanged from segment 2.
- jargon456 with `#j<r>` rep suffixes (JARGON_REPS identical repetitions in one
  process), wrapped by `energy_sampler.py`: the energy window. `energy_j` is the
  primary metric: system compute-rail joules (CPU+GPU+ANE) over the window divided
  by the rep count. Attribution rests on the harness's exclusive-hardware gates.

Accuracy is a hard guard, not a trade: `uwer_mix` above the ceiling
(segment-2 baseline .034009 + .0035 NI margin) rejects the run, as do the
existing latency/throughput/memory/error/determinism/term-safety gates. Energy
must never be bought with accuracy or latency.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
import re
from pathlib import Path

from voiceour_bench.metrics import fwer, percentiles, rtfx, uwer

PINNED_MODEL_ID = "ggml-org/parakeet-GGUF"
PINNED_REVISION = "35156454d1a39de06863303dd209fd2bed6ee079"
PINNED_FILE = "ggml-parakeet-tdt-0.6b-v3-f16.bin"

FAILURES: list[str] = []


def fail(reason: str) -> None:
    FAILURES.append(reason)


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
                raise SystemExit(f"score.py: FAIL: {path}:{number} is not JSON: {error}")
    return rows


def transcript_sha(pairs: list[tuple[str, str]]) -> str:
    blob = "".join(f"{row_id}\t{text}\n" for row_id, text in pairs)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def median_absolute_deviation(values: list[float]) -> float:
    center = statistics.median(values)
    return statistics.median([abs(value - center) for value in values])


def finite(name: str, value: float) -> float:
    if value != value or value in (float("inf"), float("-inf")):
        raise SystemExit(f"score.py: FAIL: {name} is not finite: {value}")
    return value


def surface_pattern(surface: str) -> re.Pattern[str]:
    return re.compile(r"(?<![A-Za-z0-9_])" + re.escape(surface) + r"(?![A-Za-z0-9_])")


def check_meta(meta: list[dict], label: str) -> dict:
    if len(meta) != 1:
        raise SystemExit(f"score.py: FAIL: {label}: expected one bench_meta, found {len(meta)}")
    identity = meta[0]
    if identity.get("model_id") != PINNED_MODEL_ID:
        fail(f"{label}: model_id {identity.get('model_id')!r} != {PINNED_MODEL_ID!r}")
    if identity.get("model_revision") != PINNED_REVISION:
        fail(f"{label}: model_revision {identity.get('model_revision')!r} != {PINNED_REVISION!r}")
    if identity.get("model_file") != PINNED_FILE:
        fail(f"{label}: model_file {identity.get('model_file')!r} != {PINNED_FILE!r}")
    if identity.get("backend") != "parakeet":
        fail(f"{label}: backend {identity.get('backend')!r} != 'parakeet'")
    return identity


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--general-results", required=True, type=Path)
    parser.add_argument("--jargon-results", required=True, type=Path)
    parser.add_argument("--energy-json", required=True, type=Path)
    parser.add_argument("--general-corpus", required=True, type=Path)
    parser.add_argument("--jargon-corpus", required=True, type=Path)
    parser.add_argument("--jargon-terms", required=True, type=Path)
    parser.add_argument("--warmup-passes", required=True, type=int)
    parser.add_argument("--timed-passes", required=True, type=int)
    parser.add_argument("--jargon-reps", required=True, type=int)
    parser.add_argument("--peak-footprint-bytes", required=True, type=int)
    parser.add_argument("--peak-resident-bytes", required=True, type=int)
    parser.add_argument("--latency-ceiling-ms", required=True, type=float)
    parser.add_argument("--rtfx-floor", required=True, type=float)
    parser.add_argument("--footprint-ceiling-mb", required=True, type=float)
    parser.add_argument("--uwer-mix-ceiling", required=True, type=float)
    args = parser.parse_args()

    general = read_jsonl(args.general_corpus)
    jargon = read_jsonl(args.jargon_corpus)
    terms = json.loads(args.jargon_terms.read_text(encoding="utf-8"))

    general_ids = [row["id"] for row in general]
    jargon_ids = [row["id"] for row in jargon]
    for name, ids in (("general", general_ids), ("jargon", jargon_ids)):
        if len(set(ids)) != len(ids):
            raise SystemExit(f"score.py: FAIL: {name} corpus has duplicate ids")
    if set(terms) != set(jargon_ids):
        raise SystemExit("score.py: FAIL: jargon term annotations do not cover the corpus")

    general_lines = read_jsonl(args.general_results)
    jargon_lines = read_jsonl(args.jargon_results)
    g_identity = check_meta(
        [l for l in general_lines if l.get("type") == "bench_meta"], "general"
    )
    j_identity = check_meta(
        [l for l in jargon_lines if l.get("type") == "bench_meta"], "jargon"
    )
    for key in ("model_id", "model_revision", "model_file", "backend", "vocabulary_sha256"):
        if g_identity.get(key) != j_identity.get(key):
            fail(f"bench_meta {key} differs between invocations")

    total_passes = args.warmup_passes + args.timed_passes
    if args.timed_passes < 3:
        fail(f"timed_passes {args.timed_passes} is below the required three repetitions")
    if args.jargon_reps < 3:
        fail(f"jargon_reps {args.jargon_reps} is below the required three repetitions")

    by_pass: dict[int, dict[str, dict]] = {index: {} for index in range(total_passes)}
    by_rep: dict[int, dict[str, dict]] = {index: {} for index in range(args.jargon_reps)}
    error_rows = 0

    for row in (l for l in general_lines if l.get("type") == "row"):
        raw_id = str(row.get("id", ""))
        if row.get("error") is not None:
            error_rows += 1
        row_id, separator, suffix = raw_id.rpartition("#")
        if not separator or len(suffix) < 2 or suffix[0] != "p" or not suffix[1:].isdigit():
            fail(f"general row id {raw_id!r} carries no #p<n> suffix")
            continue
        index = int(suffix[1:])
        if index not in by_pass:
            fail(f"general row {raw_id!r} names pass {index}, outside 0..{total_passes - 1}")
            continue
        if row_id in by_pass[index]:
            fail(f"general row {row_id!r} appears twice in pass {index}")
            continue
        by_pass[index][row_id] = row

    for row in (l for l in jargon_lines if l.get("type") == "row"):
        raw_id = str(row.get("id", ""))
        if row.get("error") is not None:
            error_rows += 1
        row_id, separator, suffix = raw_id.rpartition("#")
        if not separator or len(suffix) < 2 or suffix[0] != "j" or not suffix[1:].isdigit():
            fail(f"jargon row id {raw_id!r} carries no #j<r> suffix")
            continue
        index = int(suffix[1:])
        if index not in by_rep:
            fail(f"jargon row {raw_id!r} names rep {index}, outside 0..{args.jargon_reps - 1}")
            continue
        if row_id in by_rep[index]:
            fail(f"jargon row {row_id!r} appears twice in rep {index}")
            continue
        by_rep[index][row_id] = row

    if error_rows:
        fail(f"{error_rows} error rows")

    expected_general = set(general_ids)
    for index in range(total_passes):
        if set(by_pass[index]) != expected_general:
            fail(f"general pass {index} row set differs from the corpus")
    expected_jargon = set(jargon_ids)
    for index in range(args.jargon_reps):
        if set(by_rep[index]) != expected_jargon:
            fail(f"jargon rep {index} row set differs from the corpus")

    reference_pass = by_pass[0]
    for index in range(1, total_passes):
        drifted = [
            row_id
            for row_id in general_ids
            if row_id in by_pass[index]
            and row_id in reference_pass
            and by_pass[index][row_id]["raw_transcript"] != reference_pass[row_id]["raw_transcript"]
        ]
        if drifted:
            fail(f"general pass {index} transcripts differ from pass 0 on {len(drifted)} rows")
    reference_rep = by_rep[0]
    for index in range(1, args.jargon_reps):
        drifted = [
            row_id
            for row_id in jargon_ids
            if row_id in by_rep[index]
            and row_id in reference_rep
            and by_rep[index][row_id]["raw_transcript"] != reference_rep[row_id]["raw_transcript"]
        ]
        if drifted:
            fail(f"jargon rep {index} transcripts differ from rep 0 on {len(drifted)} rows")

    timed_indexes = list(range(args.warmup_passes, total_passes))
    pass_p95: list[float] = []
    pass_p50: list[float] = []
    timed_audio: list[float] = []
    timed_asr: list[float] = []
    for index in timed_indexes:
        inference = [row["timings_ms"]["asr_inference"] for row in by_pass[index].values()]
        if any(value is None for value in inference):
            fail(f"general pass {index} has rows with no asr_inference timing")
            continue
        buckets = percentiles(inference)
        pass_p95.append(float(buckets["p95"]))
        pass_p50.append(float(buckets["p50"]))
        for row in by_pass[index].values():
            timed_audio.append(row["audio_s"])
            timed_asr.append(row["timings_ms"]["asr"])
    if not pass_p95:
        raise SystemExit("score.py: FAIL: no timed pass produced inference timings")

    loads = {
        row["timings_ms"]["asr_load"]
        for pass_rows in by_pass.values()
        for row in pass_rows.values()
    }
    if len(loads) != 1:
        fail(f"general asr_load is not constant across the process: {sorted(loads)}")
    load_ms = float(sorted(loads)[0])

    if args.peak_footprint_bytes <= 0:
        fail("peak_footprint_bytes is not a positive sample")
    if args.peak_resident_bytes <= 0:
        fail("peak_resident_bytes is not a positive sample")

    # --- energy ------------------------------------------------------------

    energy = json.loads(args.energy_json.read_text(encoding="utf-8"))
    if energy.get("command_exit") != 0:
        fail(f"energy window command exited {energy.get('command_exit')}")
    rails = energy.get("rails", {})
    compute_j = float(rails.get("compute_j", 0.0))
    dram_j = float(rails.get("dram_j", 0.0))
    if compute_j <= 0.0:
        fail(f"energy window observed non-positive compute_j {compute_j}")
    energy_j = finite("energy_j", compute_j / args.jargon_reps)
    energy_dram_j = finite("energy_dram_j", dram_j / args.jargon_reps)

    # --- accuracy ----------------------------------------------------------

    general_refs = {row["id"]: row["reference"] for row in general}
    jargon_refs = {row["id"]: row["reference"] for row in jargon}
    general_pairs = [
        (row_id, reference_pass[row_id]) for row_id in general_ids if row_id in reference_pass
    ]
    jargon_pairs = [
        (row_id, reference_rep[row_id]) for row_id in jargon_ids if row_id in reference_rep
    ]

    g_refs = [general_refs[row_id] for row_id, _ in general_pairs]
    g_finals = [row["final_text"] for _, row in general_pairs]
    g_raws = [row["raw_transcript"] for _, row in general_pairs]
    j_refs = [jargon_refs[row_id] for row_id, _ in jargon_pairs]
    j_finals = [row["final_text"] for _, row in jargon_pairs]
    j_raws = [row["raw_transcript"] for _, row in jargon_pairs]

    uwer_general = finite("uwer_general", uwer(g_refs, g_finals))
    uwer_jargon = finite("uwer_jargon", uwer(j_refs, j_finals))
    uwer_mix = finite("uwer_mix", uwer(g_refs + j_refs, g_finals + j_finals))
    uwer_mix_raw = finite("uwer_mix_raw", uwer(g_refs + j_refs, g_raws + j_raws))

    positives = [
        (row_id, terms[row_id]["canonical"])
        for row_id, _ in jargon_pairs
        if "canonical" in terms[row_id]
    ]
    surfaces = sorted({canonical for _, canonical in positives})
    patterns = {surface: surface_pattern(surface) for surface in surfaces}
    term_hits = 0
    domain_totals: dict[str, int] = {}
    domain_hits: dict[str, int] = {}
    missed_terms: list[str] = []
    for row_id, canonical in positives:
        domain = terms[row_id]["domain"]
        domain_totals[domain] = domain_totals.get(domain, 0) + 1
        if patterns[canonical].search(reference_rep[row_id]["final_text"]):
            term_hits += 1
            domain_hits[domain] = domain_hits.get(domain, 0) + 1
        else:
            missed_terms.append(f"{row_id}:{canonical}")
    term_recall = term_hits / len(positives) if positives else 0.0

    negatives = [row_id for row_id, _ in jargon_pairs if "canonical" not in terms[row_id]]
    false_terms = 0
    false_examples: list[str] = []
    for row_id in negatives:
        final_text = reference_rep[row_id]["final_text"]
        reference = jargon_refs[row_id]
        for surface in surfaces:
            pattern = patterns[surface]
            if pattern.search(final_text) and not pattern.search(reference):
                false_terms += 1
                if len(false_examples) < 5:
                    false_examples.append(f"{row_id}:{surface}")
    neg_refs = [jargon_refs[row_id] for row_id in negatives]
    neg_finals = [reference_rep[row_id]["final_text"] for row_id in negatives]
    fwer_negative = finite("fwer_negative", fwer(neg_refs, neg_finals))

    # --- latency / throughput / guards -------------------------------------

    p95 = finite("asr_inference_p95_ms", statistics.median(pass_p95))
    p50 = finite("asr_inference_p50_ms", statistics.median(pass_p50))
    throughput = rtfx(timed_audio, timed_asr)
    if throughput is None:
        fail("rtfx has no finite value")
        throughput = 0.0
    throughput = finite("rtfx", float(throughput))
    footprint_mb = args.peak_footprint_bytes / 1e6

    if uwer_mix > args.uwer_mix_ceiling:
        fail(
            f"uwer_mix {uwer_mix:.6f} exceeds the NI ceiling {args.uwer_mix_ceiling:.6f}; "
            "energy must not be bought with accuracy"
        )
    if p95 > args.latency_ceiling_ms:
        fail(
            f"inference p95 {p95:.2f} ms exceeds the ceiling {args.latency_ceiling_ms:.2f} ms; "
            "energy must not be bought with latency"
        )
    if throughput < args.rtfx_floor:
        fail(f"rtfx {throughput:.2f} is below the floor {args.rtfx_floor:.2f}")
    if footprint_mb > args.footprint_ceiling_mb:
        fail(f"peak footprint {footprint_mb:.1f} MB exceeds the ceiling {args.footprint_ceiling_mb:.1f} MB")

    if FAILURES:
        for reason in FAILURES:
            print(f"score.py: FAIL: {reason}", file=sys.stderr)
        return 1

    print(f"METRIC energy_j={energy_j:.3f}")
    print(f"METRIC energy_dram_j={energy_dram_j:.3f}")
    print(f"METRIC uwer_mix={uwer_mix:.6f}")
    print(f"METRIC uwer_general={uwer_general:.6f}")
    print(f"METRIC uwer_jargon={uwer_jargon:.6f}")
    print(f"METRIC jargon_term_recall={term_recall:.6f}")
    print(f"METRIC jargon_false_terms={false_terms}")
    print(f"METRIC fwer_negative={fwer_negative:.6f}")
    print(f"METRIC asr_inference_p95_ms={p95:.4f}")
    print(f"METRIC asr_inference_p50_ms={p50:.4f}")
    print(f"METRIC rtfx={throughput:.4f}")
    print(f"METRIC load_ms={load_ms:.0f}")
    print(f"METRIC peak_phys_footprint_mb={footprint_mb:.3f}")
    print(f"METRIC peak_rss_mb={args.peak_resident_bytes / 1e6:.3f}")
    print(f"METRIC error_rows={error_rows}")

    print(f"ASI uwer_mix_raw={uwer_mix_raw:.6f}")
    print(f"ASI energy_compute_j_total={compute_j:.3f}")
    print(f"ASI energy_cpu_j={float(rails.get('cpu_j', 0.0)):.3f}")
    print(f"ASI energy_gpu_j={float(rails.get('gpu_j', 0.0)):.3f}")
    print(f"ASI energy_ane_j={float(rails.get('ane_j', 0.0)):.3f}")
    print(f"ASI energy_dram_j_total={dram_j:.3f}")
    print(f"ASI energy_window_ms={float(energy.get('window_elapsed_ms', 0.0)):.0f}")
    print(f"ASI energy_command_ms={float(energy.get('command_elapsed_ms', 0.0)):.0f}")
    print(f"ASI uwer_mix_ceiling={args.uwer_mix_ceiling:.6f}")
    print(
        "ASI general_transcript_sha256="
        + transcript_sha([(i, r["raw_transcript"]) for i, r in general_pairs])
    )
    print(
        "ASI jargon_transcript_sha256="
        + transcript_sha([(i, r["raw_transcript"]) for i, r in jargon_pairs])
    )
    print(f"ASI general_rows={len(general_ids)}")
    print(f"ASI jargon_rows={len(jargon_ids)}")
    print(f"ASI jargon_reps={args.jargon_reps}")
    for domain in sorted(domain_totals):
        print(f"ASI term_recall_{domain}={domain_hits.get(domain, 0)}/{domain_totals[domain]}")
    print(f"ASI term_misses={len(missed_terms)}")
    print("ASI term_miss_examples=" + "|".join(missed_terms[:5]))
    print("ASI false_term_examples=" + "|".join(false_examples))
    print(f"ASI warmup_passes={args.warmup_passes}")
    print(f"ASI timed_passes={args.timed_passes}")
    print("ASI pass_p95_ms=" + ",".join(f"{value:.1f}" for value in pass_p95))
    print("ASI pass_p50_ms=" + ",".join(f"{value:.1f}" for value in pass_p50))
    print(f"ASI pass_p95_mad_ms={median_absolute_deviation(pass_p95):.4f}")
    print(f"ASI latency_ceiling_ms={args.latency_ceiling_ms:.1f}")
    print(f"ASI rtfx_floor={args.rtfx_floor:.1f}")
    print(f"ASI footprint_ceiling_mb={args.footprint_ceiling_mb:.1f}")
    print(f"ASI peak_phys_footprint_bytes={args.peak_footprint_bytes}")
    print(f"ASI peak_rss_bytes={args.peak_resident_bytes}")
    print(f"ASI vocabulary_sha256={g_identity.get('vocabulary_sha256', 'absent')}")
    print(f"ASI model_id={g_identity['model_id']}")
    print(f"ASI model_revision={g_identity['model_revision']}")
    print(f"ASI model_file={g_identity['model_file']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
