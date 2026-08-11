#!/bin/sh
# Capture a screenshot of the VoiceOour console window for a given section.
#
# PREFER scripts/ui_harness.sh. That renders every console section offscreen with no
# window on your display, no focus change and no Screen Recording permission, and it
# diffs against committed goldens. This script exists for the one thing an offscreen
# render cannot show: real behind-window NSVisualEffectView glass, which the WindowServer
# composites from the actual desktop behind a real onscreen window. See docs/ui-harness.md.
#
# Usage: scripts/console_shot.sh [section] [output.png]
#   section: sessions (default) | home | voice | glossary | refinement | system | diagnostics
#   output:  defaults to .build/console-<section>.png
#
# Launches the fake backend (no mic / model / network), opens the console via the
# dev-only --show-console flag, captures just that window with screencapture, then
# quits the app. This DOES disrupt you: the window has to be onscreen to be captured,
# and the show-console notification handler still calls NSApp.activate. --no-activate
# only minimises the blip, by suppressing the console's usual promotion to .regular
# (Dock icon + Cmd-Tab entry) and the second activate in ConsoleView.onAppear.
# Requires Screen Recording permission for the controlling terminal.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECTION="${1:-sessions}"
OUT="${2:-$ROOT/.build/console-$SECTION.png}"

swift build --package-path "$ROOT" >/dev/null

FINDER="$ROOT/.build/find_console_window"
SRC="$ROOT/scripts/find_console_window.swift"
if [ ! -x "$FINDER" ] || [ "$SRC" -nt "$FINDER" ]; then
    swiftc -O "$SRC" -o "$FINDER"
fi

pkill -f '.build/debug/VoiceOour' 2>/dev/null || true
sleep 0.5

VOICEOOUR_ASR_BACKEND="${VOICEOOUR_ASR_BACKEND:-fake}" \
VOICEOOUR_REPO_ROOT="$ROOT" \
VOICEOOUR_ASR_DIR="$ROOT/asr" \
    "$ROOT/.build/debug/VoiceOour" --show-console --no-activate --console-section="$SECTION" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

WIN=""
i=0
while [ "$i" -lt 40 ]; do
    WIN=$("$FINDER" 2>/dev/null || true)
    [ -n "$WIN" ] && break
    sleep 0.3
    i=$((i + 1))
done

if [ -z "$WIN" ]; then
    echo "error: console window did not appear" >&2
    exit 1
fi

sleep "${CONSOLE_SHOT_SETTLE:-0.4}"
mkdir -p "$(dirname -- "$OUT")"
screencapture -x -o -l"$WIN" "$OUT"
echo "$OUT"
