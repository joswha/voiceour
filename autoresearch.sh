#!/usr/bin/env bash
#
# Deterministic, offline, exclusive-hardware benchmark of the shipping Parakeet
# f16 sidecar on this Mac, for the three-bets research session (contextual
# decoding, heterogeneous execution, quantization).
#
# Regime: one `voiceour-bench pipeline` process, therefore one persistent
# `voiceour-asr` child, walks `WARMUP_PASSES + TIMED_PASSES` sequential passes
# over the frozen 96-row general corpus (latency + regression guard), then one
# pass over the frozen 456-row jargon corpus (term-binding headroom). Pass 0 is
# warmup and is discarded from latency: the model load, the embedded Metal
# shader library, and the per-shape Metal pipelines all materialise on first
# use, and the general corpus spans five duration buckets.
#
# The primary metric is `uwer_mix`: pooled final-text U-WER over the union of
# both corpora. General rows make regressions visible; jargon rows carry the
# improvement headroom. Latency, throughput, and memory are hard guards, not
# trades: the run is rejected if general inference p95, RTFx, or the sidecar's
# peak physical footprint cross their ceilings. Term binding is reported by
# case-sensitive metrics (`jargon_term_recall`, `jargon_false_terms`,
# `fwer_negative`) because U-WER is case-folded and cannot see orthography.
#
# Gates. The script exits nonzero, before timing where it can, on: a missing
# prerequisite; a competing Voiceour/ASR process; a model artifact that is not
# the pinned f16 revision by SHA-256; corpus manifests or term annotations that
# are not the frozen ones; any error row; any transcript that differs across
# general passes; an unsampled or zero memory peak; a guard ceiling breach; a
# malformed metric.
#
# The script performs no network access. Model acquisition is refused rather
# than attempted: a cache miss is a missing prerequisite, not something a
# benchmark may go and fix.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

readonly WARMUP_PASSES=1
readonly TIMED_PASSES=3
readonly ROW_TIMEOUT_MS=120000
readonly LATENCY_CEILING_MS=300
readonly RTFX_FLOOR=40
readonly FOOTPRINT_CEILING_MB=2500

readonly GENERAL_CORPUS="bench/autoresearch/corpus.manifest.jsonl"
readonly JARGON_CORPUS="benchmarks/data/jargon/manifest.jsonl"
readonly JARGON_TERMS="bench/autoresearch/jargon.terms.json"
readonly SCORER="bench/autoresearch/score.py"
readonly WORK=".build/autoresearch"
readonly MEM_SAMPLER="bench/autoresearch/mem_sampler.py"

readonly MODEL_VARIANT="f16"
readonly MODEL_FILE="ggml-parakeet-tdt-0.6b-v3-f16.bin"
readonly MODEL_SHA256="833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
readonly MODEL_BYTES=1255897319
readonly MODEL_DIR="$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml"
readonly GENERAL_CORPUS_SHA256="885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749"
readonly JARGON_CORPUS_SHA256="576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf"
readonly JARGON_TERMS_SHA256="2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5"
readonly EXPECTED_METRIC_COUNT=13

die() {
    printf 'autoresearch.sh: FAIL: %s\n' "$1" >&2
    exit 1
}

log() {
    printf 'autoresearch.sh: %s\n' "$1" >&2
}

# --- prerequisites ---------------------------------------------------------

for tool in swift shasum sysctl sw_vers pgrep ps uv python3; do
    command -v "$tool" >/dev/null 2>&1 || die "missing prerequisite: $tool"
done

for file in "$GENERAL_CORPUS" "$JARGON_CORPUS" "$JARGON_TERMS" "$SCORER"; do
    [ -f "$file" ] || die "missing prerequisite file: $file"
done
[ -d bench/.venv ] || die "missing bench/.venv; run 'cd bench && uv --no-config sync --all-groups' once, with network"

pin() {
    local path="$1" expected="$2"
    local observed
    observed="$(shasum -a 256 "$path" | cut -d' ' -f1)"
    [ "$observed" = "$expected" ] || die "$path sha256 $observed != frozen $expected"
}
pin "$GENERAL_CORPUS" "$GENERAL_CORPUS_SHA256"
pin "$JARGON_CORPUS" "$JARGON_CORPUS_SHA256"
pin "$JARGON_TERMS" "$JARGON_TERMS_SHA256"

# The corpus audio is a gitignored local dataset. Name a broken dataset here
# rather than letting it arrive later as hundreds of error rows.
python3 - "$GENERAL_CORPUS" "$JARGON_CORPUS" <<'PY' || die 'corpus audio is not fully present'
import json
import sys
from pathlib import Path

missing = []
for manifest in sys.argv[1:]:
    with open(manifest, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                path = json.loads(line)["audio_path"]
                if not Path(path).is_file():
                    missing.append(path)
if missing:
    print(f"{len(missing)} corpus audio files are missing, first: {missing[:3]}", file=sys.stderr)
    raise SystemExit(1)
PY

# --- exclusive hardware ----------------------------------------------------
#
# Only the workloads this repository can start are detectable by name. An
# unrelated GPU consumer is not, which is why the timing protocol also requires
# the operator to keep the machine otherwise idle.

competing=""
for name in Voiceour voiceour-asr voiceour-bench; do
    pids="$(pgrep -x "$name" 2>/dev/null | tr '\n' ' ')"
    [ -n "$pids" ] && competing="$competing $name($pids)"
done
pids="$(pgrep -f 'granite_probe|granite_punctuator_probe|coreml.*probe' 2>/dev/null | tr '\n' ' ')"
[ -n "$pids" ] && competing="$competing research-probe($pids)"
[ -z "$competing" ] || die "competing ASR/GPU process(es) still running:$competing
stop them first (e.g. 'make stop')"

# --- model identity --------------------------------------------------------

model_path="$MODEL_DIR/$MODEL_FILE"
[ -f "$model_path" ] || die "pinned model artifact is not cached: $model_path"

observed_bytes="$(stat -f%z "$model_path")"
[ "$observed_bytes" = "$MODEL_BYTES" ] ||
    die "model artifact is $observed_bytes bytes, pinned $MODEL_BYTES"

observed_model_sha="$(shasum -a 256 "$model_path" | cut -d' ' -f1)"
[ "$observed_model_sha" = "$MODEL_SHA256" ] ||
    die "model artifact sha256 $observed_model_sha != pinned $MODEL_SHA256"

# --- build, outside the timed region ---------------------------------------

mkdir -p "$WORK"
readonly BUILD_LOG="$WORK/build.log"

log 'building release binaries'
for product in voiceour-asr voiceour-bench; do
    if ! swift build -c release --product "$product" >"$BUILD_LOG" 2>&1; then
        tail -40 "$BUILD_LOG" >&2
        die "release build of $product failed"
    fi
done

readonly BENCH_BIN=".build/release/voiceour-bench"
readonly SIDECAR_BIN=".build/release/voiceour-asr"
[ -x "$BENCH_BIN" ] || die "missing $BENCH_BIN"
[ -x "$SIDECAR_BIN" ] || die "missing $SIDECAR_BIN"

# A derived weight arena is persistent product state. Prepare it before memory
# sampling so every measured run is the same warm-launch workload.
readonly PREPARE_LOG="$WORK/prepare.log"
log 'preparing deterministic runtime cache state'
if ! env -i \
    PATH=/usr/bin:/bin \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    VOICEOUR_MODEL_VARIANT="$MODEL_VARIANT" \
    "$SIDECAR_BIN" --prove fixtures/audio/hello_16k_mono.wav \
    >"$PREPARE_LOG" 2>&1
then
    tail -40 "$PREPARE_LOG" >&2
    die 'sidecar runtime-cache preparation failed'
fi

# Let the proof load's Metal work leave the thermal state before timing. The
# latency ceiling here is a guard with real headroom, not a +6% tripwire, so a
# short settle suffices.
sleep 10

# --- run manifest ----------------------------------------------------------
#
# A pure function of the corpora and the pass counts: general rows repeat in
# corpus order once per pass with a `#p<n>` suffix, then jargon rows appear
# once with a `#j0` suffix.

readonly RUN_MANIFEST="$WORK/run.manifest.jsonl"
readonly RUN_RESULTS="$WORK/run.results.jsonl"
readonly MEM_PEAK_FILE="$WORK/peak-memory"

python3 - "$GENERAL_CORPUS" "$JARGON_CORPUS" "$RUN_MANIFEST" "$WARMUP_PASSES" "$TIMED_PASSES" <<'PY' || die 'run manifest expansion failed'
import json
import sys

general_path, jargon_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]
total_passes = int(sys.argv[4]) + int(sys.argv[5])


def read_rows(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


general = read_rows(general_path)
jargon = read_rows(jargon_path)

with open(output_path, "w", encoding="utf-8") as out:
    for index in range(total_passes):
        for row in general:
            expanded = dict(row)
            expanded["id"] = f"{row['id']}#p{index}"
            out.write(json.dumps(expanded, sort_keys=True) + "\n")
    for row in jargon:
        expanded = dict(row)
        expanded["id"] = f"{row['id']}#j0"
        out.write(json.dumps(expanded, sort_keys=True) + "\n")
PY

# --- timed region ----------------------------------------------------------
#
# The sidecar environment is the app's allowlist shape, not the parent's: an
# inherited VOICEOUR_* value must not be able to change which artifact is
# loaded or where it is read from.

rm -f "$RUN_RESULTS" "$MEM_PEAK_FILE"
printf '0 0 0 0\n' >"$MEM_PEAK_FILE"

python3 "$MEM_SAMPLER" "$MEM_PEAK_FILE" &
readonly SAMPLER_PID=$!

cleanup() {
    kill "$SAMPLER_PID" 2>/dev/null
    wait "$SAMPLER_PID" 2>/dev/null
}
trap cleanup EXIT

total_rows=$((($(wc -l <"$GENERAL_CORPUS") * (WARMUP_PASSES + TIMED_PASSES)) + $(wc -l <"$JARGON_CORPUS")))
log "running $((WARMUP_PASSES + TIMED_PASSES)) general passes + 1 jargon pass ($total_rows rows)"
run_started="$(date +%s)"
env -i \
    PATH=/usr/bin:/bin \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    VOICEOUR_MODEL_VARIANT="$MODEL_VARIANT" \
    "$BENCH_BIN" pipeline \
    --input "$RUN_MANIFEST" \
    --output "$RUN_RESULTS" \
    --timeout-ms "$ROW_TIMEOUT_MS" \
    >"$WORK/run.log" 2>&1
bench_status=$?
run_elapsed=$(($(date +%s) - run_started))

cleanup
trap - EXIT

read -r peak_footprint_bytes peak_resident_bytes mem_samples resident_layout_validated <"$MEM_PEAK_FILE"
peak_footprint_bytes="${peak_footprint_bytes:-0}"
peak_resident_bytes="${peak_resident_bytes:-0}"
mem_samples="${mem_samples:-0}"
resident_layout_validated="${resident_layout_validated:-0}"

# An unsampled run has no memory guard. Fail rather than report a zero that
# would look like a spectacular improvement.
[ "$mem_samples" -ge 200 ] ||
    die "memory sampler collected only $mem_samples samples; expected >= 200"
[ "$peak_footprint_bytes" -gt 0 ] || die 'memory sampler observed no footprint'
[ "$peak_resident_bytes" -gt 0 ] || die 'memory sampler observed no resident size'
[ "$resident_layout_validated" -eq 1 ] ||
    die 'memory sampler resident field did not agree with ps'

if [ "$bench_status" -ne 0 ]; then
    tail -20 "$WORK/run.log" >&2
    die "voiceour-bench exited $bench_status"
fi

# --- scoring, outside the timed region -------------------------------------

scored="$WORK/metrics.txt"
(
    cd bench || exit 1
    PYTHONWARNINGS=ignore uv --no-config run --offline python autoresearch/score.py \
        --results "../$RUN_RESULTS" \
        --general-corpus "../$GENERAL_CORPUS" \
        --jargon-corpus "../$JARGON_CORPUS" \
        --jargon-terms "../$JARGON_TERMS" \
        --warmup-passes "$WARMUP_PASSES" \
        --timed-passes "$TIMED_PASSES" \
        --peak-footprint-bytes "$peak_footprint_bytes" \
        --peak-resident-bytes "$peak_resident_bytes" \
        --latency-ceiling-ms "$LATENCY_CEILING_MS" \
        --rtfx-floor "$RTFX_FLOOR" \
        --footprint-ceiling-mb "$FOOTPRINT_CEILING_MB"
) >"$scored"
score_status=$?

if [ "$score_status" -ne 0 ]; then
    cat "$scored" >&2
    die "scoring rejected the run (exit $score_status)"
fi

metric_count="$(grep -c '^METRIC ' "$scored" || true)"
[ "$metric_count" -eq "$EXPECTED_METRIC_COUNT" ] ||
    die "expected $EXPECTED_METRIC_COUNT METRIC lines, found $metric_count"
grep -Eq '^METRIC uwer_mix=[0-9]+(\.[0-9]+)?$' "$scored" ||
    die 'malformed primary metric line'

cat "$scored"

# --- environment identity --------------------------------------------------

printf 'ASI general_corpus_sha256=%s\n' "$GENERAL_CORPUS_SHA256"
printf 'ASI jargon_corpus_sha256=%s\n' "$JARGON_CORPUS_SHA256"
printf 'ASI jargon_terms_sha256=%s\n' "$JARGON_TERMS_SHA256"
printf 'ASI model_sha256=%s\n' "$observed_model_sha"
printf 'ASI model_bytes=%s\n' "$observed_bytes"
printf 'ASI sidecar_sha256=%s\n' "$(shasum -a 256 "$SIDECAR_BIN" | cut -d' ' -f1)"
printf 'ASI bench_sha256=%s\n' "$(shasum -a 256 "$BENCH_BIN" | cut -d' ' -f1)"
printf 'ASI hw_model=%s\n' "$(sysctl -n hw.model)"
printf 'ASI hw_chip=%s\n' "$(sysctl -n machdep.cpu.brand_string | tr ' ' '_')"
printf 'ASI hw_cpu_threads=%s\n' "$(sysctl -n hw.logicalcpu)"
printf 'ASI hw_perf_cores=%s\n' "$(sysctl -n hw.perflevel0.logicalcpu)"
printf 'ASI hw_eff_cores=%s\n' "$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || printf '0')"
printf 'ASI hw_memory_bytes=%s\n' "$(sysctl -n hw.memsize)"
printf 'ASI os_version=%s\n' "$(sw_vers -productVersion)"
printf 'ASI os_build=%s\n' "$(sw_vers -buildVersion)"
printf 'ASI kernel=%s\n' "$(uname -r)"
printf 'ASI swift_version=%s\n' "$(swift --version 2>/dev/null | head -1 | tr ' ' '_')"
printf 'ASI timed_region_s=%s\n' "$run_elapsed"

exit 0
