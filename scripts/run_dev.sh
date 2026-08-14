#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --package-path "$ROOT"
VOICEOUR_ASR_BACKEND="${VOICEOUR_ASR_BACKEND:-fake}" VOICEOUR_REPO_ROOT="$ROOT" "$ROOT/.build/debug/Voiceour" "$@"
