#!/usr/bin/env bash
# Real-speaker technical-speech mining pipeline — full six-stage run for one talk.
#
# Usage:
#   ./run_all.sh <talk-id> <media-url> [index-url]
#
# Runs inside the envs/nemo uv project. Stage 4 needs exclusive use of the
# single 8 GB GPU on this host (a concurrent training process pins ~3 GB and
# makes parakeet OOM), so coordinate before invoking.
set -euo pipefail

TALK_ID="${1:?talk id required}"
URL="${2:?media url required}"
INDEX_URL="${3:-}"

export PATH="$HOME/.local/bin:$PATH"
export UV_CACHE_DIR=/srv/devbox/cache/uv
export UV_PYTHON_INSTALL_DIR=/srv/devbox/research/voiceour/envs/pythons
export HF_HOME=/srv/devbox/cache/hf

R=/srv/devbox/research/voiceour
MINING="$R/mining"
DATA="$R/data/mining/$TALK_ID"
ENV_DIR="$R/envs/nemo"
TERMS="$R/data/screen48/jargon.terms.json"

cd "$ENV_DIR"
mkdir -p "$DATA"

run() { echo "=== $* ==="; uv run python "$@"; }

run "$MINING/fetch.py" --url "$URL" ${INDEX_URL:+--index-url "$INDEX_URL"} \
    --talk-id "$TALK_ID" --out-dir "$DATA/raw" --max-bytes 200000000

MEDIA=$(python3 - "$DATA/raw/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["download"]["dest"])
PY
)

run "$MINING/extract.py" --input "$MEDIA" --out-dir "$DATA/audio" --talk-id "$TALK_ID"
run "$MINING/segment.py" --wav "$DATA/audio/$TALK_ID.16k.mono.wav" --out-dir "$DATA/vad" --talk-id "$TALK_ID"

# Stage 4: GPU. Refuse to start if another process holds VRAM.
USED=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits | paste -sd+ - | bc 2>/dev/null || echo 0)
if [ "${USED:-0}" -gt 100 ]; then
  echo "ABORT: ${USED} MiB of VRAM held by another process; stage 4 needs the GPU alone." >&2
  exit 3
fi
run "$MINING/transcribe.py" --segments "$DATA/vad/segments.jsonl" --out-dir "$DATA/asr" \
    --batch-size 8 --num-workers 2 --device cuda --timestamps auto

TALK_S=$(python3 - "$DATA/audio/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["audio_s"])
PY
)

run "$MINING/mine.py" --hypotheses "$DATA/asr/hypotheses.jsonl" --terms "$TERMS" \
    --out-dir "$DATA/terms" --talk-duration-s "$TALK_S"
run "$MINING/report.py" --data-root "$DATA" --out "$DATA/report/report.md"

echo "DONE: $DATA/report/report.md"
