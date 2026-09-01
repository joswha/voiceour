#!/usr/bin/env bash
#
# Deterministic, offline, exclusive-hardware benchmark of the shipping Parakeet
# f16 sidecar on this Mac — segment 5, maximum power: the machine is assumed
# plugged in, energy is not measured, and the primary metric is
# `jargon_term_recall` over the frozen 456-row jargon corpus.
#
# Regime: one `voiceour-bench pipeline` process (persistent `voiceour-asr`
# child) walks WARMUP_PASSES + TIMED_PASSES sequential passes over the frozen
# 96-row general corpus (latency + regression guard), then TWO identical
# invocations over the frozen jargon corpus (recall + cross-process
# determinism: pass 1 must be byte-identical to pass 2 in raw and final text).
#
# Hard gates, each a nonzero exit before a metric is reported: a missing
# prerequisite; a competing Voiceour/ASR process; a model artifact that is not
# the pinned f16 revision by SHA-256; corpus manifests or term annotations that
# are not the frozen ones; any error row; any transcript differing across
# timed general passes; a jargon determinism mismatch; any false jargon term;
# `uwer_mix` above its frozen ceiling; general inference p95 above its
# ceiling; RTFx below its floor; an unsampled memory peak or one above its
# ceiling; a malformed metric.
#
# The script performs no network access. Model acquisition is refused rather
# than attempted: a cache miss is a missing prerequisite, not something a
# benchmark may go and fix.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

readonly WARMUP_PASSES=1
readonly TIMED_PASSES=3
readonly JARGON_PASSES=2
readonly ROW_TIMEOUT_MS=120000
readonly LATENCY_CEILING_MS=230
readonly RTFX_FLOOR=100
readonly FOOTPRINT_CEILING_MB=2500
readonly UWER_MIX_CEILING=0.037509

readonly GENERAL_CORPUS="bench/autoresearch/corpus.manifest.jsonl"
readonly JARGON_CORPUS="benchmarks/data/jargon/manifest.jsonl"
readonly JARGON_TERMS="bench/autoresearch/jargon.terms.json"
readonly REPAIR_VOCABULARY="bench/autoresearch/repair.vocabulary.json"
readonly SCORER="bench/autoresearch/score_v5.py"
readonly WORK=".build/autoresearch"
readonly MEM_SAMPLER="bench/autoresearch/mem_sampler.py"

# Candidate configuration. Empty COREML_ENCODER = native. A non-empty path
# requires the pinned directory digest to match.
readonly COREML_ENCODER="$PWD/.build/asr-research/three-bets/palettize6/standard/parakeet_encoder_6bit.mlmodelc"
readonly COREML_ENCODER_DIGEST="adffa42216599bdb01611a6e06cb8f26448cb3a66078b8fbed66dbe8b6cb544d"
readonly COREML_MAX_S="15.0"
readonly COREML_ENCODER_SHORT="$PWD/.build/asr-research/three-bets/palettize6/short/parakeet_encoder_6bit.mlmodelc"
readonly COREML_ENCODER_SHORT_DIGEST="1d995f0ef5a92e14f92214b93af46126a78427513be7d6ea695cae421f6a16e6"
readonly COREML_SHORT_MAX_S="8.0"
readonly COREML_ENCODER_TINY="$PWD/.build/asr-research/three-bets/palettize6/tiny/parakeet_encoder_6bit.mlmodelc"
readonly COREML_ENCODER_TINY_DIGEST="e77ac4a6fc6299868fce308b652b363a3fd98d7024a225b6920f691ff66add05"
readonly COREML_TINY_MAX_S="6.0"
readonly ASSIST_MODEL="$PWD/.build/asr-research/models-v2/ggml-parakeet-tdt-0.6b-v2-f16.bin"
readonly ASSIST_MODEL_SHA256="1af0aed998520343d0f9b9b96b3b351accccb2d87a53c98f08015c5b408256cd"
readonly ASSIST_MAX_S="15.0"

readonly MODEL_VARIANT="f16"
readonly MODEL_FILE="ggml-parakeet-tdt-0.6b-v3-f16.bin"
readonly MODEL_SHA256="833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
readonly MODEL_BYTES=1255897319
readonly MODEL_DIR="$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml"
readonly GENERAL_CORPUS_SHA256="885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749"
readonly JARGON_CORPUS_SHA256="576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf"
readonly JARGON_TERMS_SHA256="2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5"
readonly REPAIR_VOCABULARY_SHA256="650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8"
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

for file in "$GENERAL_CORPUS" "$JARGON_CORPUS" "$JARGON_TERMS" "$REPAIR_VOCABULARY" "$SCORER"; do
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
pin "$REPAIR_VOCABULARY" "$REPAIR_VOCABULARY_SHA256"

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

# --- coreml candidate identity ---------------------------------------------

coreml_env_args=""
if [ -n "$COREML_ENCODER" ]; then
    [ -e "$COREML_ENCODER" ] || die "coreml encoder artifact missing: $COREML_ENCODER"
    [ -n "$COREML_ENCODER_DIGEST" ] || die 'coreml encoder digest pin is empty'
    observed_coreml_digest="$(cd "$COREML_ENCODER" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
    [ "$observed_coreml_digest" = "$COREML_ENCODER_DIGEST" ] ||
        die "coreml encoder digest $observed_coreml_digest != pinned $COREML_ENCODER_DIGEST"
    coreml_env_args="VOICEOUR_COREML_ENCODER=$COREML_ENCODER VOICEOUR_COREML_MAX_S=$COREML_MAX_S"
    if [ -n "$COREML_ENCODER_SHORT" ]; then
        [ -e "$COREML_ENCODER_SHORT" ] || die "coreml short encoder artifact missing: $COREML_ENCODER_SHORT"
        [ -n "$COREML_ENCODER_SHORT_DIGEST" ] || die 'coreml short encoder digest pin is empty'
        observed_short_digest="$(cd "$COREML_ENCODER_SHORT" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
        [ "$observed_short_digest" = "$COREML_ENCODER_SHORT_DIGEST" ] ||
            die "coreml short encoder digest $observed_short_digest != pinned $COREML_ENCODER_SHORT_DIGEST"
        coreml_env_args="$coreml_env_args VOICEOUR_COREML_ENCODER_SHORT=$COREML_ENCODER_SHORT VOICEOUR_COREML_SHORT_MAX_S=$COREML_SHORT_MAX_S"
    fi
    if [ -n "$COREML_ENCODER_TINY" ]; then
        [ -e "$COREML_ENCODER_TINY" ] || die "coreml tiny encoder artifact missing: $COREML_ENCODER_TINY"
        [ -n "$COREML_ENCODER_TINY_DIGEST" ] || die 'coreml tiny encoder digest pin is empty'
        observed_tiny_digest="$(cd "$COREML_ENCODER_TINY" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
        [ "$observed_tiny_digest" = "$COREML_ENCODER_TINY_DIGEST" ] ||
            die "coreml tiny encoder digest $observed_tiny_digest != pinned $COREML_ENCODER_TINY_DIGEST"
        coreml_env_args="$coreml_env_args VOICEOUR_COREML_ENCODER_TINY=$COREML_ENCODER_TINY VOICEOUR_COREML_TINY_MAX_S=$COREML_TINY_MAX_S"
    fi
    coreml_env_args="$coreml_env_args VOICEOUR_TAIL_BACKEND=cpu VOICEOUR_TAIL_QUANT=q8_0 VOICEOUR_CPU_POOL=persistent"
fi
if [ -n "$ASSIST_MODEL" ]; then
    [ -e "$ASSIST_MODEL" ] || die "assist model artifact missing: $ASSIST_MODEL"
    [ -n "$ASSIST_MODEL_SHA256" ] || die 'assist model sha pin is empty'
    observed_assist_sha="$(shasum -a 256 "$ASSIST_MODEL" | cut -d' ' -f1)"
    [ "$observed_assist_sha" = "$ASSIST_MODEL_SHA256" ] ||
        die "assist model sha $observed_assist_sha != pinned $ASSIST_MODEL_SHA256"
    coreml_env_args="$coreml_env_args VOICEOUR_ASSIST_MODEL=$ASSIST_MODEL VOICEOUR_ASSIST_MAX_S=$ASSIST_MAX_S"
fi

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
    $coreml_env_args \
    "$SIDECAR_BIN" --prove fixtures/audio/hello_16k_mono.wav \
    >"$PREPARE_LOG" 2>&1
then
    tail -40 "$PREPARE_LOG" >&2
    die 'sidecar runtime-cache preparation failed'
fi

# Let the proof load's Metal work leave the thermal state before timing.
sleep 5

# --- run manifests ---------------------------------------------------------

readonly GENERAL_MANIFEST="$WORK/general.manifest.jsonl"
readonly JARGON_MANIFEST="$WORK/jargon.manifest.jsonl"
readonly RUN_RESULTS_GENERAL="$WORK/general.results.jsonl"
readonly MEM_PEAK_FILE="$WORK/peak-memory"

python3 - "$GENERAL_CORPUS" "$JARGON_CORPUS" "$GENERAL_MANIFEST" "$JARGON_MANIFEST" "$WARMUP_PASSES" "$TIMED_PASSES" <<'PY' || die 'run manifest expansion failed'
import json
import sys

general_path, jargon_path = sys.argv[1], sys.argv[2]
general_out, jargon_out = sys.argv[3], sys.argv[4]
total_passes = int(sys.argv[5]) + int(sys.argv[6])


def read_rows(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


general = read_rows(general_path)
jargon = read_rows(jargon_path)

with open(general_out, "w", encoding="utf-8") as out:
    for index in range(total_passes):
        for row in general:
            expanded = dict(row)
            expanded["id"] = f"{row['id']}#p{index}"
            out.write(json.dumps(expanded, sort_keys=True) + "\n")

with open(jargon_out, "w", encoding="utf-8") as out:
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

rm -f "$RUN_RESULTS_GENERAL" "$MEM_PEAK_FILE"
printf '0 0 0 0\n' >"$MEM_PEAK_FILE"

python3 "$MEM_SAMPLER" "$MEM_PEAK_FILE" &
readonly SAMPLER_PID=$!

cleanup() {
    kill "$SAMPLER_PID" 2>/dev/null
    wait "$SAMPLER_PID" 2>/dev/null
}
trap cleanup EXIT

log "running $((WARMUP_PASSES + TIMED_PASSES)) general passes ($(wc -l <"$GENERAL_CORPUS" | tr -d ' ') rows each)"
run_started="$(date +%s)"
env -i \
    PATH=/usr/bin:/bin \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    VOICEOUR_MODEL_VARIANT="$MODEL_VARIANT" \
    $coreml_env_args \
    "$BENCH_BIN" pipeline \
    --input "$GENERAL_MANIFEST" \
    --output "$RUN_RESULTS_GENERAL" \
    --timeout-ms "$ROW_TIMEOUT_MS" \
    --vocabulary "$REPAIR_VOCABULARY" \
    >"$WORK/run.log" 2>&1
bench_status=$?
if [ "$bench_status" -ne 0 ]; then
    cleanup
    trap - EXIT
    tail -20 "$WORK/run.log" >&2
    die "general voiceour-bench exited $bench_status"
fi

log "running $JARGON_PASSES jargon passes ($(wc -l <"$JARGON_CORPUS" | tr -d ' ') rows each)"
jargon_pass=1
while [ "$jargon_pass" -le "$JARGON_PASSES" ]; do
    pass_results="$WORK/jargon.$jargon_pass.results.jsonl"
    rm -f "$pass_results"
    env -i \
        PATH=/usr/bin:/bin \
        HOME="$HOME" \
        TMPDIR="${TMPDIR:-/tmp}" \
        VOICEOUR_MODEL_VARIANT="$MODEL_VARIANT" \
        $coreml_env_args \
        "$BENCH_BIN" pipeline \
        --input "$JARGON_MANIFEST" \
        --output "$pass_results" \
        --timeout-ms "$ROW_TIMEOUT_MS" \
        --vocabulary "$REPAIR_VOCABULARY" \
        >"$WORK/jargon.$jargon_pass.log" 2>&1
    pass_status=$?
    if [ "$pass_status" -ne 0 ]; then
        cleanup
        trap - EXIT
        tail -20 "$WORK/jargon.$jargon_pass.log" >&2
        die "jargon pass $jargon_pass voiceour-bench exited $pass_status"
    fi
    jargon_pass=$((jargon_pass + 1))
done
run_elapsed=$(($(date +%s) - run_started))

cleanup
trap - EXIT

read -r peak_footprint_bytes peak_resident_bytes mem_samples resident_layout_validated <"$MEM_PEAK_FILE"
peak_footprint_bytes="${peak_footprint_bytes:-0}"
peak_resident_bytes="${peak_resident_bytes:-0}"
mem_samples="${mem_samples:-0}"
resident_layout_validated="${resident_layout_validated:-0}"

[ "$mem_samples" -ge 200 ] ||
    die "memory sampler collected only $mem_samples samples; expected >= 200"
[ "$peak_footprint_bytes" -gt 0 ] || die 'memory sampler observed no footprint'
[ "$peak_resident_bytes" -gt 0 ] || die 'memory sampler observed no resident size'
[ "$resident_layout_validated" -eq 1 ] ||
    die 'memory sampler resident field did not agree with ps'

# --- scoring, outside the timed region -------------------------------------

scored="$WORK/metrics.txt"
(
    cd bench || exit 1
    PYTHONWARNINGS=ignore uv --no-config run --offline python autoresearch/score_v5.py \
        --general-results "../$RUN_RESULTS_GENERAL" \
        --jargon-results-1 "../$WORK/jargon.1.results.jsonl" \
        --jargon-results-2 "../$WORK/jargon.2.results.jsonl" \
        --general-corpus "../$GENERAL_CORPUS" \
        --jargon-corpus "../$JARGON_CORPUS" \
        --jargon-terms "../$JARGON_TERMS" \
        --warmup-passes "$WARMUP_PASSES" \
        --timed-passes "$TIMED_PASSES" \
        --peak-footprint-bytes "$peak_footprint_bytes" \
        --peak-resident-bytes "$peak_resident_bytes" \
        --latency-ceiling-ms "$LATENCY_CEILING_MS" \
        --rtfx-floor "$RTFX_FLOOR" \
        --footprint-ceiling-mb "$FOOTPRINT_CEILING_MB" \
        --uwer-mix-ceiling "$UWER_MIX_CEILING"
) >"$scored"
score_status=$?

if [ "$score_status" -ne 0 ]; then
    cat "$scored" >&2
    die "scoring rejected the run (exit $score_status)"
fi

metric_count="$(grep -c '^METRIC ' "$scored" || true)"
[ "$metric_count" -eq "$EXPECTED_METRIC_COUNT" ] ||
    die "expected $EXPECTED_METRIC_COUNT METRIC lines, found $metric_count"
grep -Eq '^METRIC jargon_term_recall=[0-9]+(\.[0-9]+)?$' "$scored" ||
    die 'malformed primary metric line'

cat "$scored"

# --- environment identity --------------------------------------------------

printf 'ASI general_corpus_sha256=%s\n' "$GENERAL_CORPUS_SHA256"
printf 'ASI jargon_corpus_sha256=%s\n' "$JARGON_CORPUS_SHA256"
printf 'ASI jargon_terms_sha256=%s\n' "$JARGON_TERMS_SHA256"
printf 'ASI repair_vocabulary_sha256=%s\n' "$REPAIR_VOCABULARY_SHA256"
printf 'ASI coreml_encoder=%s\n' "${COREML_ENCODER:-native}"
printf 'ASI coreml_encoder_digest=%s\n' "${COREML_ENCODER_DIGEST:-none}"
printf 'ASI coreml_max_s=%s\n' "$COREML_MAX_S"
printf 'ASI coreml_encoder_short=%s\n' "${COREML_ENCODER_SHORT:-none}"
printf 'ASI coreml_short_digest=%s\n' "${COREML_ENCODER_SHORT_DIGEST:-none}"
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
