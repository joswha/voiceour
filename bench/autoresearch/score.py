"""Score one `autoresearch.sh` run over the frozen general + jargon corpora.

Reads the `voiceour-bench pipeline` results for a run shaped as
`warmup_passes + timed_passes` sequential passes over the general corpus
(`bench/autoresearch/corpus.manifest.jsonl`, ids suffixed `#p<n>`) followed by
exactly one pass over the jargon corpus
(`benchmarks/data/jargon/manifest.jsonl`, ids suffixed `#j0`), enforces the
run's identity and correctness gates, and prints `METRIC`/`ASI` lines.

U-WER, FWER, and percentiles come from `voiceour_bench.metrics`, so the
harness cannot drift away from the definitions the published reports use.

Metric definitions:

- `uwer_mix` — the primary metric: pooled U-WER of `final_text` against
  `reference` over the union of the general corpus and the jargon corpus
  (one decode per row). General rows guard against regression; jargon rows
  carry the headroom contextual-decoding research is chasing. Pooling is by
  normalized reference words, exactly `voiceour_bench.metrics.uwer`.
- `uwer_general` / `uwer_jargon` — the same quantity per corpus.
- `jargon_term_recall` — fraction of jargon positive rows whose final text
  contains the row's canonical term surface exactly, case-sensitively, with
  `[A-Za-z0-9_]` boundaries. U-WER is case-folded, so this is the metric that
  sees orthographic binding (`kubectl`, `SwiftUI`) succeed or fail.
- `jargon_false_terms` — over jargon negative rows: count of (row, surface)
  pairs where any known canonical surface appears in the final text but not in
  the reference. Catches false replacements and false re-casings
  (`rust` -> `Rust`) that case-folded U-WER cannot see.
- `fwer_negative` — case-preserving formatted WER over the negative rows, the
  broad-spectrum guard for prose damage on ordinary sentences.
- `asr_inference_p95_ms` / `asr_inference_p50_ms` — median across the general
  corpus's timed passes of that pass's percentile of sidecar-reported
  `timings_ms.asr_inference`. Jargon rows are excluded: their short-utterance
  distribution would dilute the tail the ceiling protects.
- `rtfx` — timed general audio seconds over summed client `timings_ms.asr`
  seconds, matching `docs/benchmarks.md`.
- `load_ms` — the sidecar's model-load time, constant across the process.
- `peak_phys_footprint_mb` / `peak_rss_mb` — sampler peaks over the whole run.
- `error_rows` — rows the runner could not transcribe; any is a hard failure.

Hard gates (exit nonzero): model pin mismatch, incomplete or duplicated row
sets, error rows, transcript drift across general passes, non-constant load,
unsampled memory, inference p95 above the ceiling, RTFx below the floor,
footprint above the ceiling. Latency, throughput, and memory are guards here,
not trades: accuracy work must not buy U-WER with them.

Exit status is 0 only when every gate passes; each failure prints one
`score.py: FAIL: <reason>` line on stderr so a single run names everything
that is wrong.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import sys
from pathlib import Path

from voiceour_bench.metrics import fwer, percentiles, rtfx, uwer

PINNED_MODEL_ID = "ggml-org/parakeet-GGUF"
PINNED_REVISION = "35156454d1a39de06863303dd209fd2bed6ee079"
PINNED_FILE = "ggml-parakeet-tdt-0.6b-v3-f16.bin"
GENERAL_SUFFIX = "#p"
JARGON_SUFFIX = "#j"

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
    return re.compile(
        r"(?<![A-Za-z0-9_])" + re.escape(surface) + r"(?![A-Za-z0-9_])"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, type=Path)
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

    lines = read_jsonl(args.results)
    meta = [line for line in lines if line.get("type") == "bench_meta"]
    rows = [line for line in lines if line.get("type") == "row"]
    if len(meta) != 1:
        raise SystemExit(f"score.py: FAIL: expected exactly one bench_meta line, found {len(meta)}")

    identity = meta[0]
    if identity.get("model_id") != PINNED_MODEL_ID:
        fail(f"model_id {identity.get('model_id')!r} != {PINNED_MODEL_ID!r}")
    if identity.get("model_revision") != PINNED_REVISION:
        fail(f"model_revision {identity.get('model_revision')!r} != {PINNED_REVISION!r}")
    if identity.get("model_file") != PINNED_FILE:
        fail(f"model_file {identity.get('model_file')!r} != {PINNED_FILE!r}")
    if identity.get("backend") != "parakeet":
        fail(f"backend {identity.get('backend')!r} != 'parakeet'")

    total_passes = args.warmup_passes + args.timed_passes
    if args.timed_passes < 3:
        fail(f"timed_passes {args.timed_passes} is below the required three repetitions")

    by_pass: dict[int, dict[str, dict]] = {index: {} for index in range(total_passes)}
    jargon_rows: dict[str, dict] = {}
    error_rows = 0
    for row in rows:
        raw_id = str(row.get("id", ""))
        if row.get("error") is not None:
            error_rows += 1
        row_id, separator, suffix = raw_id.rpartition("#")
        if not separator or len(suffix) < 2:
            fail(f"row id {raw_id!r} carries no pass suffix")
            continue
        kind, index_text = suffix[0], suffix[1:]
        if kind == "p" and index_text.isdigit():
            index = int(index_text)
            if index not in by_pass:
                fail(f"row {raw_id!r} names pass {index}, outside 0..{total_passes - 1}")
                continue
            if row_id in by_pass[index]:
                fail(f"row {row_id!r} appears twice in pass {index}")
                continue
            by_pass[index][row_id] = row
        elif kind == "j" and index_text == "0":
            if row_id in jargon_rows:
                fail(f"jargon row {row_id!r} appears twice")
                continue
            jargon_rows[row_id] = row
        else:
            fail(f"row id {raw_id!r} carries unknown suffix {suffix!r}")

    if error_rows:
        offenders = sorted(row["id"] for row in rows if row.get("error") is not None)[:5]
        fail(f"{error_rows} error rows, first: {offenders}")

    expected_general = set(general_ids)
    for index in range(total_passes):
        observed = set(by_pass[index])
        if observed != expected_general:
            fail(
                f"general pass {index} row set differs from the corpus: "
                f"missing {sorted(expected_general - observed)[:5]}, "
                f"extra {sorted(observed - expected_general)[:5]}"
            )
    observed_jargon = set(jargon_rows)
    if observed_jargon != set(jargon_ids):
        fail(
            "jargon row set differs from the corpus: "
            f"missing {sorted(set(jargon_ids) - observed_jargon)[:5]}, "
            f"extra {sorted(observed_jargon - set(jargon_ids))[:5]}"
        )

    # Determinism within the run: every general pass, warmup included, must
    # reproduce pass 0's transcripts byte for byte.
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
            fail(f"pass {index} transcripts differ from pass 0 on {len(drifted)} rows, first: {drifted[:3]}")

    timed_indexes = list(range(args.warmup_passes, total_passes))
    pass_p95: list[float] = []
    pass_p50: list[float] = []
    timed_audio: list[float] = []
    timed_asr: list[float] = []
    for index in timed_indexes:
        inference = [row["timings_ms"]["asr_inference"] for row in by_pass[index].values()]
        if any(value is None for value in inference):
            fail(f"pass {index} has rows with no asr_inference timing")
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
    } | {row["timings_ms"]["asr_load"] for row in jargon_rows.values()}
    if len(loads) != 1:
        fail(f"asr_load is not constant across the process: {sorted(loads)}")
    load_ms = float(sorted(loads)[0])

    if args.peak_footprint_bytes <= 0:
        fail(f"peak_footprint_bytes {args.peak_footprint_bytes} is not a positive sample")
    if args.peak_resident_bytes <= 0:
        fail(f"peak_resident_bytes {args.peak_resident_bytes} is not a positive sample")

    # --- accuracy -----------------------------------------------------------

    general_refs = {row["id"]: row["reference"] for row in general}
    jargon_refs = {row["id"]: row["reference"] for row in jargon}

    general_pairs = [
        (row_id, reference_pass[row_id]) for row_id in general_ids if row_id in reference_pass
    ]
    jargon_pairs = [
        (row_id, jargon_rows[row_id]) for row_id in jargon_ids if row_id in jargon_rows
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

    # --- term binding -------------------------------------------------------

    positives = [
        (row_id, terms[row_id]["canonical"])
        for row_id, _ in jargon_pairs
        if "canonical" in terms[row_id]
    ]
    surfaces = sorted({canonical for _, canonical in positives})
    patterns = {surface: surface_pattern(surface) for surface in surfaces}

    term_hits = 0
    missed_terms: list[str] = []
    domain_totals: dict[str, int] = {}
    domain_hits: dict[str, int] = {}
    for row_id, canonical in positives:
        domain = terms[row_id]["domain"]
        domain_totals[domain] = domain_totals.get(domain, 0) + 1
        if patterns[canonical].search(jargon_rows[row_id]["final_text"]):
            term_hits += 1
            domain_hits[domain] = domain_hits.get(domain, 0) + 1
        else:
            missed_terms.append(f"{row_id}:{canonical}")
    term_recall = term_hits / len(positives) if positives else 0.0

    negatives = [row_id for row_id, _ in jargon_pairs if "canonical" not in terms[row_id]]
    false_terms = 0
    false_examples: list[str] = []
    for row_id in negatives:
        final_text = jargon_rows[row_id]["final_text"]
        reference = jargon_refs[row_id]
        for surface in surfaces:
            pattern = patterns[surface]
            if pattern.search(final_text) and not pattern.search(reference):
                false_terms += 1
                if len(false_examples) < 5:
                    false_examples.append(f"{row_id}:{surface}")
    neg_refs = [jargon_refs[row_id] for row_id in negatives]
    neg_finals = [jargon_rows[row_id]["final_text"] for row_id in negatives]
    fwer_negative = finite("fwer_negative", fwer(neg_refs, neg_finals))

    # --- latency / throughput ----------------------------------------------

    p95 = finite("asr_inference_p95_ms", statistics.median(pass_p95))
    p50 = finite("asr_inference_p50_ms", statistics.median(pass_p50))
    throughput = rtfx(timed_audio, timed_asr)
    if throughput is None:
        fail("rtfx has no finite value")
        throughput = 0.0
    throughput = finite("rtfx", float(throughput))

    footprint_mb = args.peak_footprint_bytes / 1e6
    if p95 > args.latency_ceiling_ms:
        fail(
            f"inference p95 {p95:.2f} ms exceeds the latency ceiling "
            f"{args.latency_ceiling_ms:.2f} ms; accuracy must not be bought with latency"
        )
    if throughput < args.rtfx_floor:
        fail(f"rtfx {throughput:.2f} is below the floor {args.rtfx_floor:.2f}")
    if footprint_mb > args.footprint_ceiling_mb:
        fail(
            f"peak footprint {footprint_mb:.1f} MB exceeds the ceiling "
            f"{args.footprint_ceiling_mb:.1f} MB"
        )

    if FAILURES:
        for reason in FAILURES:
            print(f"score.py: FAIL: {reason}", file=sys.stderr)
        return 1

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
    print(f"ASI general_transcript_sha256={transcript_sha([(i, r['raw_transcript']) for i, r in general_pairs])}")
    print(f"ASI jargon_transcript_sha256={transcript_sha([(i, r['raw_transcript']) for i, r in jargon_pairs])}")
    print(f"ASI general_rows={len(general_ids)}")
    print(f"ASI jargon_rows={len(jargon_ids)}")
    print(f"ASI jargon_positive_rows={len(positives)}")
    print(f"ASI jargon_negative_rows={len(negatives)}")
    print(f"ASI jargon_distinct_surfaces={len(surfaces)}")
    for domain in sorted(domain_totals):
        print(
            f"ASI term_recall_{domain}={domain_hits.get(domain, 0)}/{domain_totals[domain]}"
        )
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
    print(f"ASI asr_wall_ms_sum_timed={sum(timed_asr):.0f}")
    print(f"ASI model_id={identity['model_id']}")
    print(f"ASI model_revision={identity['model_revision']}")
    print(f"ASI model_file={identity['model_file']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
