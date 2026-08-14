#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/Voiceour.app"
if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi
"$ROOT/scripts/bundle.sh" >/dev/null
open -n "$APP" --args --asr-backend "${VOICEOUR_ASR_BACKEND:-parakeet}" "$@"
