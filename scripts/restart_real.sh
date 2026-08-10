#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/VoiceOour.app"
if [ ! -x "$APP/Contents/MacOS/VoiceOour" ]; then
  "$ROOT/scripts/bundle.sh" >/dev/null
fi
pkill -f "$APP/Contents/MacOS/VoiceOour" 2>/dev/null || true
if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi
open -n "$APP" --args --repo-root "$ROOT" --asr-dir "$ROOT/asr" --asr-backend "${VOICEOOUR_ASR_BACKEND:-mlx}" "$@"
