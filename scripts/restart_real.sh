#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/Voiceour.app"
if [ ! -x "$APP/Contents/MacOS/Voiceour" ]; then
  "$ROOT/scripts/bundle.sh" >/dev/null
fi
pkill -f "$APP/Contents/MacOS/Voiceour" 2>/dev/null || true
if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi
open -n "$APP" --args --asr-backend "${VOICEOUR_ASR_BACKEND:-parakeet}" "$@"
