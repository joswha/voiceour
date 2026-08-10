#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/VoiceOour.app"
if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi
"$ROOT/scripts/bundle.sh" >/dev/null
open -n "$APP" --args --repo-root "$ROOT" --asr-dir "$ROOT/asr" --asr-backend "${VOICEOOUR_ASR_BACKEND:-mlx}" "$@"
