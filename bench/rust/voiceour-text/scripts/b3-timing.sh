#!/usr/bin/env bash
# Bet B3 official timing: orchestrator only, on a quiet machine, after b3-parity.sh passed.
#
# For every glossary and stage it runs one swift-text-bench process with the in-process arms
# (swift, swift@aa: the shipped VoiceCore code; rust-ffi: the Rust port through
# libvoiceour_text.dylib; swift-opt, swift-opt-repr: the optimized Swift copies), then the
# separate-process Rust CLI (rust, rust@aa) on the same rows and order, then the
# once-per-process ordinary-word load, then paired statistics per file.
#
#   bench/rust/voiceour-text/scripts/b3-timing.sh [rows] [passes]
#     rows    realistic rows per text/compile run (default 300; 1310 = every row, ~4x longer)
#     passes  measured passes after warm-up pass 0 (default 10)
# Output (B3_TIMING_OUT overrides the directory): .build/rust-bench/b3/timing/
# {inproc,rust}.<stage>.<glossary>.jsonl and, per stage and glossary, report.<stage>.<glossary>.{md,json}.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
ROWS=${1:-300}
PASSES=${2:-10}
IN=$ROOT/.build/rust-bench/b3/inputs
PARITY=$ROOT/.build/rust-bench/b3/parity
OUT=${B3_TIMING_OUT:-$ROOT/.build/rust-bench/b3/timing}
STATS=$ROOT/bench/rust/analysis/paired_stats.py
mkdir -p "$OUT"

(cd "$ROOT/bench/rust/voiceour-text" && cargo build --release --quiet)
(cd "$ROOT/bench/rust/swift-text-harness" && swift build -c release >/dev/null)
SWIFT=$(cd "$ROOT/bench/rust/swift-text-harness" && swift build -c release --show-bin-path)/swift-text-bench
RUST=$ROOT/bench/rust/voiceour-text/target/release/text-bench

CASES=$OUT/realistic-$ROWS.jsonl
head -n "$ROWS" "$IN/cases/realistic.jsonl" > "$CASES"
ARMS=swift,swift@aa,rust-ffi,swift-opt,swift-opt-repr

# Active terms: scale-0 0, scale-10 10, scale-50 50, scale-100 98, default7 7, user-jargon /
# scale-1000 / scale-5000 100 (production caps the snapshot at 100; 1000 and 5000 change the
# compile stage and which 100 terms are active).
for glossary in scale-0 scale-10 scale-50 scale-100 default7 user-jargon scale-1000 scale-5000; do
    for stage in text compile engine; do
        args=(--stage "$stage" --cases "$CASES" --glossary "$IN/glossaries/$glossary.json" --passes "$PASSES")
        case $stage in
            text) args+=(--ref "$PARITY/realistic.$glossary.swift.jsonl" --corpus "realistic$ROWS") ;;
            compile) args+=(--corpus "realistic$ROWS") ;;
            engine) args+=(--engine-reps 20 --corpus engine) ;;
        esac
        echo "== $stage $glossary" >&2
        "$SWIFT" bench "${args[@]}" --arms "$ARMS" --out "$OUT/inproc.$stage.$glossary.jsonl"
        "$RUST" bench "${args[@]}" --arms rust,rust@aa --out "$OUT/rust.$stage.$glossary.jsonl"
        python3 "$STATS" "$OUT/inproc.$stage.$glossary.jsonl" "$OUT/rust.$stage.$glossary.jsonl" \
            --pair swift:swift@aa --pair rust:rust@aa \
            --pair swift:rust --pair swift:rust-ffi --pair rust:rust-ffi \
            --pair swift:swift-opt --pair swift:swift-opt-repr --pair swift-opt-repr:swift-opt \
            --pair swift-opt:rust --pair swift-opt:rust-ffi --pair swift-opt-repr:rust-ffi \
            --json "$OUT/report.$stage.$glossary.json" --md "$OUT/report.$stage.$glossary.md"
    done
done

ordinary=(--stage ordinary --cases "$IN/cases/fixtures.jsonl" --glossary "$IN/glossaries/default7.json" --passes "$PASSES"
    --corpus ordinary)
"$SWIFT" bench "${ordinary[@]}" --arms swift,swift@aa --out "$OUT/inproc.ordinary.jsonl"
"$RUST" bench "${ordinary[@]}" --arms rust,rust@aa --out "$OUT/rust.ordinary.jsonl"
python3 "$STATS" "$OUT/inproc.ordinary.jsonl" "$OUT/rust.ordinary.jsonl" --pair swift:swift@aa --pair rust:rust@aa \
    --pair swift:rust --json "$OUT/report.ordinary.json" --md "$OUT/report.ordinary.md"

# The rust-ffi boundary alone (stage 3 echo): the marshalling share of every rust-ffi text row.
"$SWIFT" bench --stage boundary --cases "$CASES" --glossary "$IN/glossaries/default7.json" --passes "$PASSES" \
    --arms rust-ffi,rust-ffi@aa --corpus "realistic$ROWS" --out "$OUT/inproc.boundary.jsonl"
python3 "$STATS" "$OUT/inproc.boundary.jsonl" --pair rust-ffi:rust-ffi@aa \
    --json "$OUT/report.boundary.json" --md "$OUT/report.boundary.md"
echo "B3 timing: $OUT" >&2
