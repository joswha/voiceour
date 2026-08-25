#!/bin/sh
# Capture a screenshot of the Voiceour console window for a given section.
#
# PREFER scripts/ui_harness.sh. That renders every console section offscreen with no
# window on your display, no focus change and no Screen Recording permission, and it
# diffs against committed goldens. This script exists to capture the real onscreen
# window — native chrome, system appearance, and optionally the composited glass
# ground — the things `cacheDisplay` cannot show, for docs and appearance review.
# The offscreen harness remains the gate. See docs/ui-harness.md.
#
# Usage: scripts/console_shot.sh [tab] [output.png]
#   tab:    home | glossary | history | settings (default)
#   output: defaults to .build/console-<tab>.png
#
# Two capture modes, because the two jobs want opposite things:
#
#   default (window id, `screencapture -l`)
#       Captures the window's own backing store. Nothing behind the window is in
#       the image, which is what a committed doc illustration needs — but a
#       behind-window material has nothing to sample there either, so
#       `ConsoleGlassGround` rasterises as a flat fill (measured: near-black
#       inactive, mid-grey active). Layout, controls and plates are real.
#
#   CONSOLE_SHOT_COMPOSITED=1 (screen rect, `screencapture -R`)
#       Captures the rectangle the window occupies, so the glass shows the real
#       blurred backdrop. The window must be frontmost and unobstructed, and
#       whatever is behind it lands in the image — never commit one of these
#       without looking at what it caught.
#
# Launches the fake backend (no mic / model / network), opens the console via the
# dev-only --show-console flag, captures, then quits the app. This DOES disrupt you:
# the window has to be onscreen. The default mode passes --no-activate to shrink the
# focus blip; composited mode cannot, because it needs the window in front.
# Requires Screen Recording permission for the controlling terminal.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECTION="${1:-settings}"
OUT="${2:-$ROOT/.build/console-$SECTION.png}"
COMPOSITED="${CONSOLE_SHOT_COMPOSITED:-0}"

swift build --package-path "$ROOT" >/dev/null

FINDER="$ROOT/.build/find_console_window"
SRC="$ROOT/scripts/find_console_window.swift"
if [ ! -x "$FINDER" ] || [ "$SRC" -nt "$FINDER" ]; then
    swiftc -O "$SRC" -o "$FINDER"
fi

pkill -f '.build/debug/Voiceour' 2>/dev/null || true
sleep 0.5

if [ "$COMPOSITED" = "1" ]; then
    set -- --show-console --console-section="$SECTION"
else
    set -- --show-console --no-activate --console-section="$SECTION"
fi

VOICEOUR_ASR_BACKEND="${VOICEOUR_ASR_BACKEND:-fake}" \
VOICEOUR_REPO_ROOT="$ROOT" \
    "$ROOT/.build/debug/Voiceour" "$@" >/dev/null 2>&1 &
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

sleep "${CONSOLE_SHOT_SETTLE:-0.6}"
mkdir -p "$(dirname -- "$OUT")"
if [ "$COMPOSITED" = "1" ]; then
    # Re-read the rectangle after the settle: the window can still be placing
    # itself when it first appears in the window list, and a stale rectangle
    # captures the desktop next to it.
    screencapture -x -R"$("$FINDER" --rect)" "$OUT"
else
    screencapture -x -o -l"$WIN" "$OUT"
fi
echo "$OUT"
