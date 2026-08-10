#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$ROOT"
VOICEOOUR_ASR_BACKEND="${VOICEOOUR_ASR_BACKEND:-fake}" VOICEOOUR_REPO_ROOT="$ROOT" VOICEOOUR_ASR_DIR="$ROOT/asr" "$ROOT/.build/debug/VoiceOour" "$@"
