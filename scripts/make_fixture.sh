#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT/fixtures/audio"
mkdir -p "$OUT_DIR"
say -o "$OUT_DIR/hello.aiff" "hello world testing NVIDIA Parakeet and NSPasteboard"
afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT_DIR/hello.aiff" "$OUT_DIR/hello_16k_mono.wav"
printf '%s\n' "$OUT_DIR/hello_16k_mono.wav"
