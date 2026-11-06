#!/bin/sh
# Official, serialized measurement run for the Rust text and renderer experiments
# (bench/rust/voiceour-text, bench/rust/mercury-raster).
#
# Run on a quiet machine: no builds, no other benchmarks, AC power. Every comparison is paired and
# same-process (see bench/rust/analysis/README.md); this script only sequences the runs and records
# host state around each one. Sections run in the order given; with no arguments, all of them:
#
#   bench/rust/run_official.sh [text] [mercury] [analyze]
#
# Environment: RUST_BENCH_OUT (default .build/rust-bench/official/<UTC stamp>), PASSES (default 5).
# Prerequisites: `cargo build --release` in bench/rust/voiceour-text and bench/rust/mercury-raster,
# and `swift build -c release` in both Swift harness packages.
#
# Guards (this script stops, with the files it already wrote left in place):
# - OUT is made absolute once, and no output file or directory is ever overwritten: use a new
#   RUST_BENCH_OUT for a new run. Completed datasets stay untouched.
# - The machine must be on AC power before and after every measurement (host log line + pmset).
# - Every measured file is checked with `paired_stats.py --check` straight after it is written: a
#   truncated or duplicated grid, a missing completion footer, a failed call or a non-finite
#   output stops the run. A harness that exits nonzero (its run_end footer reports an invalid run)
#   stops it too. Analysis refuses such files again, so a partial file is never summarized.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=${RUST_BENCH_OUT:-.build/rust-bench/official/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
PASSES=${PASSES:-5}
STATS=bench/rust/analysis/paired_stats.py
LIB=bench/rust

die() {
    echo "run_official: $*" >&2
    exit 1
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

# Analysis never reads a file that failed its check: --check repeats the strict gate, and the
# analyzer refuses an incomplete grid or footer on its own. The text section analyzes its own
# files inside b3-timing.sh.
run_analyze() {
    python3 "$STATS" --check "$OUT/b6.jsonl" --all-vs swift --json "$OUT/b6.stats.json" --md "$OUT/b6.stats.md"
    python3 "$STATS" --check "$OUT/b6.jsonl" --pair swift-simd:rust-neon --pair swift-simd-unchecked:rust-neon \
        --pair swift:rust --json "$OUT/b6.pairs.json" --md "$OUT/b6.pairs.md"
}

sections=${*:-"text mercury analyze"}
printf 'output: %s\n' "$OUT"
for section in $sections; do
    case $section in
        text|mercury|analyze) "run_$section" ;;
        *) echo "unknown section $section" >&2; exit 64 ;;
    esac
done
