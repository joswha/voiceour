#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT/fixtures/audio"
mkdir -p "$OUT_DIR"
# `say` only writes AIFF/CAF, so the WAV the sidecar reads goes through one
# conversion. The intermediate is not a fixture and does not survive the script.
AIFF="$OUT_DIR/hello.aiff"
trap 'rm -f "$AIFF"' EXIT
say -o "$AIFF" "hello world testing NVIDIA Parakeet and NSPasteboard"
afconvert -f WAVE -d LEI16@16000 -c 1 "$AIFF" "$OUT_DIR/hello_16k_mono.wav"
printf '%s\n' "$OUT_DIR/hello_16k_mono.wav"
