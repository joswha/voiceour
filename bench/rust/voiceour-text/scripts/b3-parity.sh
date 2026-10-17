#!/usr/bin/env bash
# Bet B3 equivalence: runs the production Swift text path, the Rust port and the optimized
# Swift copies (swift-opt, swift-opt-repr) over every (cases, glossary) pair of the generated
# input matrix and compares each candidate with the production Swift record: every stage of
# every case (composed, cleaned, output text and SHA-256, repair events) plus the compiled
# snapshot and repair partition. Exits non-zero on any difference. Correctness only: no timing
# is taken here.
#
#   bench/rust/voiceour-text/scripts/b3-parity.sh [jobs]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
JOBS=${1:-4}
IN=$ROOT/.build/rust-bench/b3/inputs
OUT=$ROOT/.build/rust-bench/b3/parity
mkdir -p "$OUT"

(cd "$ROOT/bench/rust/voiceour-text" && cargo build --release --quiet)
(cd "$ROOT/bench/rust/swift-text-harness" && swift build -c release >/dev/null)
SWIFT=$(cd "$ROOT/bench/rust/swift-text-harness" && swift build -c release --show-bin-path)/swift-text-bench
RUST=$ROOT/bench/rust/voiceour-text/target/release/text-bench
[ -f "$IN/manifest.json" ] || "$RUST" gen-inputs --out "$IN"

pairs=()
for glossary in default7 user-jargon repair-vocab; do
    pairs+=("fixtures:$glossary" "realistic:$glossary")
done
for glossary in "$IN"/glossaries/scale-*.json; do
    pairs+=("realistic:$(basename "$glossary" .json)")
done
for cases in "$IN"/cases/fuzz-*.jsonl; do
    name=$(basename "$cases" .jsonl)
    pairs+=("$name:$name")
done

# One summary line per (candidate, pair): "<candidate> <compare summary line>".
run_pair() {
    local cases=${1%%:*} glossary=${1##*:}
    local stem="$OUT/$cases.$glossary"
    local args=(--cases "$IN/cases/$cases.jsonl" --glossary "$IN/glossaries/$glossary.json")
    "$SWIFT" parity "${args[@]}" --out "$stem.swift.jsonl" 2>/dev/null
    "$RUST" parity "${args[@]}" --out "$stem.rust.jsonl" 2>/dev/null
    "$SWIFT" parity --impl swift-opt "${args[@]}" --out "$stem.swift-opt.jsonl" 2>/dev/null
    "$SWIFT" parity --impl swift-opt-repr "${args[@]}" --out "$stem.swift-opt-repr.jsonl" 2>/dev/null
    local candidate report
    for candidate in rust swift-opt swift-opt-repr; do
        report=$stem.compare.txt
        [ "$candidate" = rust ] || report=$stem.compare-$candidate.txt
        "$RUST" compare "$stem.swift.jsonl" "$stem.$candidate.jsonl" --max-diffs 3 > "$report" 2>&1 || true
        printf '%s %s\n' "$candidate" "$(tail -n 1 "$report")"
    done
}
export -f run_pair
export SWIFT RUST IN OUT

printf '%s\n' "${pairs[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_pair "$@"' _ {} | sort | tee "$OUT/summary.txt"

status=0
for candidate in rust swift-opt swift-opt-repr; do
    total=0
    same=0
    while read -r _ _ counts _; do
        same=$((same + ${counts%%/*}))
        total=$((total + ${counts##*/}))
    done < <(grep "^$candidate " "$OUT/summary.txt")
    echo "B3 parity $candidate vs swift: $same/$total cases identical across ${#pairs[@]} (cases, glossary) pairs"
    [ "$total" -gt 0 ] && [ "$same" -eq "$total" ] || status=1
done
grep -q "meta problems [1-9]" "$OUT/summary.txt" && status=1
exit $status
