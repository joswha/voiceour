"""Score one `autoresearch.sh` run of the frozen latency corpus.

Reads the `voiceour-bench pipeline` results for a run shaped as
`warmup_passes + timed_passes` sequential passes over
`bench/autoresearch/corpus.manifest.jsonl`, enforces the run's identity and
correctness gates, and prints `METRIC`/`ASI` lines on stdout.

Percentiles and U-WER come from `voiceour_bench.metrics`, so the harness cannot
drift away from the definitions the published reports and the keep-time
400/100 gate use.

Metric definitions:

- `asr_inference_p95_ms` — median across timed passes of that pass's p95 of the
  sidecar-reported `timings_ms.asr_inference`. Sidecar-reported so the number
  excludes IPC and WAV decode; a repetition-level percentile so one slow pass
  cannot be averaged away inside a pooled tail.
- `asr_inference_p50_ms` — the same reduction over each pass's p50.
- `rtfx` — timed audio seconds over summed client-side `timings_ms.asr`
  seconds, matching `docs/benchmarks.md`. Warmup rows are excluded, so the
  one-off model load never enters this ratio.
- `load_ms` — the sidecar's own model-load time, constant across a process.
- `peak_rss_bytes` — supplied by the harness, which samples the sidecar.
- `uwer` — U-WER of `final_text` against `reference`, the quantity the
  keep-time 0.0035 gate compares.
- `error_rows` — rows the runner could not transcribe.

Exit status is 0 only when every gate passes; each failure prints one
`score.py: FAIL: <reason>` line on stderr so a single run names everything
that is wrong.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from pathlib import Path

from voiceour_bench.metrics import percentiles, rtfx, uwer

PINNED_MODEL_ID = "ggml-org/parakeet-GGUF"
PINNED_REVISION = "35156454d1a39de06863303dd209fd2bed6ee079"
PINNED_FILE = "ggml-parakeet-tdt-0.6b-v3-f16.bin"
PASS_SEPARATOR = "#p"

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
                raise SystemExit(f"score.py: FAIL: {path}: malformed JSON on line {number}: {error}") from error
    return rows


def transcript_blob(pairs: list[tuple[str, str]]) -> str:
    return "".join(
        json.dumps({"id": row_id, "raw_transcript": text}, ensure_ascii=False, sort_keys=True) + "\n"
        for row_id, text in sorted(pairs)
    )


def median_absolute_deviation(values: list[float]) -> float:
    center = statistics.median(values)
    return statistics.median([abs(value - center) for value in values])


def finite(name: str, value: float) -> float:
    if value != value or value in (float("inf"), float("-inf")):
        fail(f"metric {name} is not finite: {value!r}")
        return 0.0
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--golden", required=True, type=Path)
    parser.add_argument("--warmup-passes", required=True, type=int)
    parser.add_argument("--timed-passes", required=True, type=int)
    parser.add_argument("--peak-rss-bytes", required=True, type=int)
    parser.add_argument(
        "--bless-golden",
        action="store_true",
        help="write the observed transcripts to --golden instead of comparing against it",
    )
    args = parser.parse_args()

    corpus = read_jsonl(args.corpus)
    corpus_ids = [row["id"] for row in corpus]
    if len(set(corpus_ids)) != len(corpus_ids):
        raise SystemExit("score.py: FAIL: corpus manifest has duplicate ids")

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
    error_rows = 0
    for row in rows:
        row_id, separator, suffix = str(row.get("id", "")).rpartition(PASS_SEPARATOR)
        if not separator or not suffix.isdigit():
            fail(f"row id {row.get('id')!r} does not carry a {PASS_SEPARATOR}<n> pass suffix")
            continue
        index = int(suffix)
        if index not in by_pass:
            fail(f"row {row['id']!r} names pass {index}, outside 0..{total_passes - 1}")
            continue
        if row_id in by_pass[index]:
            fail(f"row {row_id!r} appears twice in pass {index}")
            continue
        by_pass[index][row_id] = row
        if row.get("error") is not None:
            error_rows += 1

    if error_rows:
        offenders = sorted(row["id"] for row in rows if row.get("error") is not None)[:5]
        fail(f"{error_rows} error rows, first: {offenders}")

    expected = set(corpus_ids)
    for index in range(total_passes):
        observed = set(by_pass[index])
        if observed != expected:
            fail(
                f"pass {index} row set differs from the corpus: "
                f"missing {sorted(expected - observed)[:5]}, extra {sorted(observed - expected)[:5]}"
            )

    # Transcript identity, across passes and against the golden. Checked over
    # every pass including warmup: a change that only perturbs the cold pass is
    # still a transcript change.
    reference_pass = by_pass[0]
    observed_pairs: list[tuple[str, str]] = []
    for row_id in corpus_ids:
        row = reference_pass.get(row_id)
        if row is None:
            continue
        observed_pairs.append((row_id, row["raw_transcript"]))
    for index in range(1, total_passes):
        drifted = [
            row_id
            for row_id in corpus_ids
            if row_id in by_pass[index]
            and row_id in reference_pass
            and by_pass[index][row_id]["raw_transcript"] != reference_pass[row_id]["raw_transcript"]
        ]
        if drifted:
            fail(f"pass {index} transcripts differ from pass 0 on {len(drifted)} rows, first: {drifted[:3]}")

    blob = transcript_blob(observed_pairs)
    transcript_sha = hashlib.sha256(blob.encode("utf-8")).hexdigest()
    if args.bless_golden:
        args.golden.write_text(blob, encoding="utf-8")
        print(f"score.py: wrote golden transcripts to {args.golden}", file=sys.stderr)
    else:
        if not args.golden.is_file():
            fail(f"golden transcript file {args.golden} is missing")
        else:
            golden = {row["id"]: row["raw_transcript"] for row in read_jsonl(args.golden)}
            if set(golden) != expected:
                fail(
                    "golden row set differs from the corpus: "
                    f"missing {sorted(expected - set(golden))[:5]}, extra {sorted(set(golden) - expected)[:5]}"
                )
            mismatched = [row_id for row_id, text in observed_pairs if golden.get(row_id) != text]
            if mismatched:
                fail(f"{len(mismatched)} transcripts differ from the golden, first: {mismatched[:3]}")

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

    loads = {row["timings_ms"]["asr_load"] for pass_rows in by_pass.values() for row in pass_rows.values()}
    if len(loads) != 1:
        fail(f"asr_load is not constant across the process: {sorted(loads)}")
    load_ms = float(sorted(loads)[0])

    if args.peak_rss_bytes <= 0:
        fail(f"peak_rss_bytes {args.peak_rss_bytes} is not a positive sample")

    corpus_references = {row["id"]: row["reference"] for row in corpus}
    references = [corpus_references[row_id] for row_id, _ in observed_pairs]
    final_texts = [reference_pass[row_id]["final_text"] for row_id, _ in observed_pairs]
    raw_texts = [text for _, text in observed_pairs]
    uwer_final = finite("uwer", uwer(references, final_texts))
    uwer_raw = finite("uwer_raw", uwer(references, raw_texts))

    p95 = finite("asr_inference_p95_ms", statistics.median(pass_p95))
    p50 = finite("asr_inference_p50_ms", statistics.median(pass_p50))
    throughput = rtfx(timed_audio, timed_asr)
    if throughput is None:
        fail("rtfx has no finite value")
        throughput = 0.0
    throughput = finite("rtfx", float(throughput))

    buckets: dict[str, int] = {}
    for row in corpus:
        buckets[row["duration_bucket"]] = buckets.get(row["duration_bucket"], 0) + 1

    if FAILURES:
        for reason in FAILURES:
            print(f"score.py: FAIL: {reason}", file=sys.stderr)
        return 1

    print(f"METRIC asr_inference_p95_ms={p95:.4f}")
    print(f"METRIC asr_inference_p50_ms={p50:.4f}")
    print(f"METRIC rtfx={throughput:.4f}")
    print(f"METRIC load_ms={load_ms:.0f}")
    print(f"METRIC peak_rss_bytes={args.peak_rss_bytes}")
    print(f"METRIC uwer={uwer_final:.6f}")
    print(f"METRIC error_rows={error_rows}")

    print(f"ASI transcript_sha256={transcript_sha}")
    print(f"ASI corpus_rows={len(corpus_ids)}")
    print(f"ASI corpus_audio_s={sum(row['audio_s'] for row in corpus):.3f}")
    for name in sorted(buckets):
        print(f"ASI duration_bucket_{name}={buckets[name]}")
    print(f"ASI warmup_passes={args.warmup_passes}")
    print(f"ASI timed_passes={args.timed_passes}")
    print("ASI pass_p95_ms=" + ",".join(f"{value:.1f}" for value in pass_p95))
    print("ASI pass_p50_ms=" + ",".join(f"{value:.1f}" for value in pass_p50))
    print(f"ASI pass_p95_mad_ms={median_absolute_deviation(pass_p95):.4f}")
    print(f"ASI pass_p95_min_ms={min(pass_p95):.1f}")
    print(f"ASI pass_p95_max_ms={max(pass_p95):.1f}")
    print(f"ASI uwer_raw={uwer_raw:.6f}")
    print(f"ASI asr_wall_ms_sum_timed={sum(timed_asr):.0f}")
    print(f"ASI model_id={identity['model_id']}")
    print(f"ASI model_revision={identity['model_revision']}")
    print(f"ASI model_file={identity['model_file']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
