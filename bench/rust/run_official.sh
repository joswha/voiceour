#!/bin/sh
# Official, serialized measurement run for the Rust rewrite experiments (docs/rust-evaluation.md).
#
# Run on a quiet machine: no builds, no other benchmarks, AC power. Every comparison is paired and
# same-process (see bench/rust/analysis/README.md); this script only sequences the runs and records
# host state around each one. Sections run in the order given; with no arguments, all of them:
#
#   bench/rust/run_official.sh [ledger] [cold] [tail] [mel] [encoder] [text] [mercury] [combined] [analyze]
#
# Environment: RUST_BENCH_OUT (default .build/rust-bench/official/<UTC stamp>), PASSES (default 5).
# Prerequisites: `swift build -c release --product voiceour-bench`, `--product voiceour-asr`,
# `cargo build --release` in every bench/rust crate, `swift build -c release` in both Swift harness
# packages, and the encoder/mel dumps under .build/rust-bench/dumps (voiceour-bench dump-states).
# Candle bootstrap: the encoder section needs bench/rust/encoder-candle/vendor/, an untracked copy of
# candle-metal-kernels 0.11.0 that pins the Metal Shading Language version (without it every candle
# call failed to compile its Metal library under the voiceour-bench host). Create it once on a clean
# checkout with bench/rust/encoder-candle/patches/vendor-candle-metal-kernels.sh, THEN run
# `cargo build --release` in bench/rust/encoder-candle (see its README, "Metal toolchain").
#
# Guards (this script stops, with the files it already wrote left in place):
# - OUT is made absolute once, and no output file or directory is ever overwritten: use a new
#   RUST_BENCH_OUT for a new run. Completed datasets stay untouched.
# - The machine must be on AC power before and after every measurement (host log line + pmset).
# - Every measured file is checked with `paired_stats.py --check` straight after it is written: a
#   truncated or duplicated grid, a missing completion footer, a failed call or a non-finite
#   output stops the run. A harness that exits nonzero (its run_end footer reports an invalid run)
#   stops it too. Analysis refuses such files again, so a partial file is never summarized.
#
# Encoder section: one Rust candidate per process. The six candidates hold about 8.5 GiB of weights
# when loaded together, risking memory pressure on a 24 GB laptop and allowing one engine's
# allocator and cache state to affect the next. Each candidate therefore runs in its own voiceour-bench process, with only its
# own library loaded, against that process's own native ggml-metal and ggml-metal@aa arms, and
# writes b4.<engine>-<arm>.<corpus>.jsonl. Each file is analyzed alone against its own baseline;
# baseline replicates are never pooled across candidate processes. All six candidates, all three
# corpora and 3 timed passes are kept.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=${RUST_BENCH_OUT:-.build/rust-bench/official/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
PASSES=${PASSES:-5}
CORPORA="general96 jargon456 librispeech128"
ENCODER_CANDIDATES="candle:f16w+fused candle:f16+fused mlx:f32 mlx:f32-mm16 mlx:f16 mlx:compiled-f16"
BENCH=.build/release/voiceour-bench
STATS=bench/rust/analysis/paired_stats.py
LIB=bench/rust

die() {
    echo "run_official: $*" >&2
    exit 1
}

manifest() {
    case $1 in
        general96) echo bench/autoresearch/corpus.manifest.jsonl ;;
        jargon456) echo benchmarks/data/jargon/manifest.jsonl ;;
        librispeech128) echo benchmarks/data/librispeech/manifest.jsonl ;;
        *) echo "unknown corpus $1" >&2; exit 64 ;;
    esac
}

require_ac() {
    source=$(pmset -g batt | head -n 1)
    case $source in
        *"AC Power"*) ;;
        *) die "not on AC power while '$1' ($source); refusing to measure" ;;
    esac
}

# Logs the host state, then refuses to go on unless the machine is on AC power. Called before and
# after every measurement.
host() {
    {
        printf '== %s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        uptime
        pmset -g batt | head -n 1
        pmset -g therm 2>&1 | grep -v '^Note' || true
        printf 'swap: %s\n' "$(sysctl -n vm.swapusage 2>&1)"
    } >> "$OUT/host.log"
    require_ac "$1"
}

# Never overwrite an output of an earlier run.
fresh() {
    [ ! -e "$1" ] || die "$1 already exists; official outputs are never overwritten (use a new RUST_BENCH_OUT)"
}

# The strict gate on one measured file: refuses an incomplete grid or footer, runtime errors and
# reported failures (exit 2), which stops this script.
verify() {
    python3 "$STATS" --check "$1" || die "$1 failed the integrity check; the file is kept for diagnosis"
}

encoder_lib() {
    case $1 in
        candle:*) echo "$LIB/encoder-candle/target/release/libencoder_candle.dylib" ;;
        mlx:*) echo "$LIB/encoder-mlx/target/release/libencoder_mlx.dylib" ;;
        *) die "unknown encoder candidate $1" ;;
    esac
}

# candle:f16w+fused -> candle-f16w-fused (a file-name part: no colon, no plus).
encoder_slug() {
    printf '%s' "$1" | tr ':+' '--'
}

require_candle_bootstrap() {
    vendored=$LIB/encoder-candle/vendor/candle-metal-kernels/src/kernel.rs
    [ -f "$vendored" ] || die "$LIB/encoder-candle/vendor is missing: run $LIB/encoder-candle/patches/vendor-candle-metal-kernels.sh, then cargo build --release in $LIB/encoder-candle"
    candle=$(encoder_lib candle:)
    [ -f "$candle" ] || die "$candle is missing: cargo build --release in $LIB/encoder-candle"
    [ "$candle" -nt "$vendored" ] || die "$candle is older than the vendored candle-metal-kernels: cargo build --release in $LIB/encoder-candle"
}

run_ledger() {
    for c in $CORPORA; do
        fresh "$OUT/ledger.$c.jsonl"
        host "ledger $c start"
        "$BENCH" stage-profile --input "$(manifest "$c")" --output "$OUT/ledger.$c.jsonl" --passes 3 \
            --sidecar --vocabulary bench/autoresearch/repair.vocabulary.json
        host "ledger $c end"
        verify "$OUT/ledger.$c.jsonl"
    done
}

run_cold() {
    fresh "$OUT/cold.manifest.jsonl"
    head -n 1 "$(manifest general96)" > "$OUT/cold.manifest.jsonl"
    for i in 1 2 3 4 5; do
        fresh "$OUT/cold.$i.jsonl"
        host "cold $i start"
        "$BENCH" stage-profile --input "$OUT/cold.manifest.jsonl" --output "$OUT/cold.$i.jsonl" --passes 1 --sidecar
        host "cold $i end"
        verify "$OUT/cold.$i.jsonl"
    done
}

run_tail() {
    for c in $CORPORA; do
        fresh "$OUT/b1.$c.jsonl"
        host "tail $c start"
        "$BENCH" tail-bench --dumps ".build/rust-bench/dumps/$c" --output "$OUT/b1.$c.jsonl" --passes "$PASSES" \
            --rust-tail-lib "$LIB/tdt-tail/target/release/libtdt_tail.dylib" \
            --rust-arms naive,precompute,rawargmax,f16w,mt,best,spec,accel,q8,c-best
        host "tail $c end"
        verify "$OUT/b1.$c.jsonl"
    done
}

run_mel() {
    for c in $CORPORA; do
        fresh "$OUT/b2.$c.jsonl"
        host "mel $c start"
        "$BENCH" mel-bench --dumps ".build/rust-bench/dumps/$c" --output "$OUT/b2.$c.jsonl" --passes "$PASSES" \
            --rust-mel-lib "$LIB/mel-frontend/target/release/libmel_frontend.dylib" \
            --rust-arms faithful-mt,sparse,best,realfft,vdsp --transcripts
        host "mel $c end"
        verify "$OUT/b2.$c.jsonl"
    done
}

run_encoder() {
    require_candle_bootstrap
    for c in $CORPORA; do
        for cand in $ENCODER_CANDIDATES; do
            slug=$(encoder_slug "$cand")
            lib=$(encoder_lib "$cand")
            out=$OUT/b4.$slug.$c.jsonl
            fresh "$out"
            host "encoder $c $cand start"
            "$BENCH" encoder-bench --dumps ".build/rust-bench/dumps/$c" --output "$out" --passes 3 \
                --rust-encoder-lib "$lib" --rust-arms "$cand"
            host "encoder $c $cand end"
            verify "$out"
        done
    done
}

run_text() {
    fresh "$OUT/b3"
    host "text start"
    B3_TIMING_OUT="$OUT/b3" "$LIB/voiceour-text/scripts/b3-timing.sh" 300 "$PASSES"
    host "text end"
    for f in "$OUT"/b3/inproc.*.jsonl "$OUT"/b3/rust.*.jsonl; do
        verify "$f"
    done
}

run_mercury() {
    fresh "$OUT/b6.jsonl"
    host "mercury start"
    "$LIB/swift-mercury-harness/.build/release/swift-mercury-harness" time \
        --arms swift,swift@aa,swift-simd,swift-simd-unchecked,rust,rust-neon --passes 10 --out "$OUT/b6.jsonl"
    host "mercury end"
    verify "$OUT/b6.jsonl"
}

run_combined() {
    for c in $CORPORA; do
        fresh "$OUT/b7.$c.jsonl"
        host "combined $c start"
        "$BENCH" combined-bench --dumps ".build/rust-bench/dumps/$c" --output "$OUT/b7.$c.jsonl" --passes "$PASSES" \
            --rust-mel-lib "$LIB/mel-frontend/target/release/libmel_frontend.dylib" \
            --rust-tail-lib "$LIB/tdt-tail/target/release/libtdt_tail.dylib"
        host "combined $c end"
        verify "$OUT/b7.$c.jsonl"
    done
}

# Analysis never reads a file that failed its check: --check repeats the strict gate, and the
# analyzer refuses an incomplete grid or footer on its own. B4 runs one analysis per candidate file:
# each against that process's own ggml-metal baseline and ggml-metal@aa replicate, never pooled.
run_analyze() {
    for c in $CORPORA; do
        python3 "$STATS" --check --stage-profile --stage-parts mel,encode,tail "$OUT/ledger.$c.jsonl" \
            --json "$OUT/ledger.$c.stats.json" --md "$OUT/ledger.$c.stats.md"
        python3 "$STATS" --check "$OUT/b1.$c.jsonl" --all-vs cpp-metal \
            --json "$OUT/b1.$c.stats.json" --md "$OUT/b1.$c.stats.md"
        python3 "$STATS" --check "$OUT/b1.$c.jsonl" --pair cpp-cpu:rust:best --pair cpp-cpu:rust:c-best \
            --pair rust:mt:rust:best --pair rust:c-best:rust:best \
            --json "$OUT/b1.$c.pairs.json" --md "$OUT/b1.$c.pairs.md"
        python3 "$STATS" --check "$OUT/b2.$c.jsonl" --all-vs cpp \
            --json "$OUT/b2.$c.stats.json" --md "$OUT/b2.$c.stats.md"
        for cand in $ENCODER_CANDIDATES; do
            slug=$(encoder_slug "$cand")
            python3 "$STATS" --check "$OUT/b4.$slug.$c.jsonl" --all-vs ggml-metal \
                --json "$OUT/b4.$slug.$c.stats.json" --md "$OUT/b4.$slug.$c.stats.md"
        done
        python3 "$STATS" --check "$OUT/b7.$c.jsonl" --all-vs native \
            --json "$OUT/b7.$c.stats.json" --md "$OUT/b7.$c.stats.md"
    done
    python3 "$STATS" --check "$OUT/b6.jsonl" --all-vs swift --json "$OUT/b6.stats.json" --md "$OUT/b6.stats.md"
    python3 "$STATS" --check "$OUT/b6.jsonl" --pair swift-simd:rust-neon --pair swift-simd-unchecked:rust-neon \
        --pair swift:rust --json "$OUT/b6.pairs.json" --md "$OUT/b6.pairs.md"
}

sections=${*:-"ledger cold tail mel encoder text mercury combined analyze"}
printf 'output: %s\n' "$OUT"
for section in $sections; do
    case $section in
        ledger|cold|tail|mel|encoder|text|mercury|combined|analyze) "run_$section" ;;
        *) echo "unknown section $section" >&2; exit 64 ;;
    esac
done
