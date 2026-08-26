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
# Three environment knobs shape what is photographed:
#
#   CONSOLE_SHOT_SAMPLE_DATA=1
#       Runs the app against a scratch support directory seeded from
#       fixtures/media/console-sample, so the capture shows sample analytics and
#       sample transcripts. REQUIRED for anything committed under docs/media:
#       without it the app reads ~/Library/Application Support/Voiceour and the
#       image publishes your own dictation history and the apps you dictate into.
#
#   CONSOLE_SHOT_SIZE=WxH
#       Resizes the console window before the capture, in points. It opens at its
#       default 800x980, which is shorter than Home's full page; 800x1185 shows the
#       activity grid and its legend. Needs Accessibility trust for the controlling
#       terminal — a refusal leaves the default size rather than failing the run.
#
#   CONSOLE_SHOT_ACTIVATE=1
#       Lets the window become key, so the capture shows the chrome a reader
#       actually sees: coloured traffic lights and full-strength tab labels. An
#       unactivated window photographs its inactive appearance — dimmed lights and
#       greyed labels — which reads as a broken screenshot in documentation. It
#       costs a real focus change, so it is opt-in rather than the default.
#
# Launches the fake backend (no mic / model / network), opens the console via the
# dev-only --show-console flag, captures, then quits the app. This DOES disrupt you:
# the window has to be onscreen. The default mode passes --no-activate to shrink the
# focus blip; composited mode never does, because it needs the window in front.
# Requires Screen Recording permission for the controlling terminal.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECTION="${1:-settings}"
OUT="${2:-$ROOT/.build/console-$SECTION.png}"
COMPOSITED="${CONSOLE_SHOT_COMPOSITED:-0}"
SAMPLE_DATA="${CONSOLE_SHOT_SAMPLE_DATA:-0}"

swift build --package-path "$ROOT" >/dev/null

# Both helpers are single-file Swift compiled on demand and cached in .build.
build_helper() {
    _bin="$ROOT/.build/$1"
    _src="$ROOT/scripts/$1.swift"
    if [ ! -x "$_bin" ] || [ "$_src" -nt "$_bin" ]; then
        swiftc -O "$_src" -o "$_bin"
    fi
}

build_helper find_console_window
FINDER="$ROOT/.build/find_console_window"

# The support directory is the app's own; only an explicit opt-in redirects it, so
# a capture cannot silently substitute sample data for the developer's real state.
if [ "$SAMPLE_DATA" = "1" ]; then
    build_helper seed_console_data
    SUPPORT_DIR="$ROOT/.build/console-shot-support"
    rm -rf "$SUPPORT_DIR"
    mkdir -p "$SUPPORT_DIR"
    "$ROOT/.build/seed_console_data" "$ROOT/fixtures/media/console-sample" "$SUPPORT_DIR" >/dev/null
    VOICEOUR_SUPPORT_DIR="$SUPPORT_DIR"
    export VOICEOUR_SUPPORT_DIR
fi

pkill -f '.build/debug/Voiceour' 2>/dev/null || true
sleep 0.5

# Composited mode has no choice: it photographs the screen, so the window must be
# in front. Window-id mode does, and it stays out of the way unless asked.
if [ "$COMPOSITED" = "1" ] || [ "${CONSOLE_SHOT_ACTIVATE:-0}" = "1" ]; then
    set -- --show-console --console-section="$SECTION"
else
    set -- --show-console --no-activate --console-section="$SECTION"
fi

VOICEOUR_ASR_BACKEND="${VOICEOUR_ASR_BACKEND:-fake}" \
VOICEOUR_REPO_ROOT="$ROOT" \
    "$ROOT/.build/debug/Voiceour" "$@" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

# Scoped to this launch: a running menu-bar Voiceour owns a console window too,
# and it is usually the larger of the two.
WIN=""
i=0
while [ "$i" -lt 40 ]; do
    WIN=$("$FINDER" --pid "$APP_PID" 2>/dev/null || true)
    [ -n "$WIN" ] && break
    sleep 0.3
    i=$((i + 1))
done

if [ -z "$WIN" ]; then
    echo "error: console window did not appear" >&2
    exit 1
fi

if [ -n "${CONSOLE_SHOT_SIZE:-}" ]; then
    WIDTH="${CONSOLE_SHOT_SIZE%x*}"
    HEIGHT="${CONSOLE_SHOT_SIZE#*x}"
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to set size of window 1 to {$WIDTH, $HEIGHT}" >/dev/null 2>&1 \
        || echo "warning: could not resize the window; is the terminal trusted for Accessibility?" >&2
fi

sleep "${CONSOLE_SHOT_SETTLE:-0.6}"
mkdir -p "$(dirname -- "$OUT")"
if [ "$COMPOSITED" = "1" ]; then
    # Re-read the rectangle after the settle: the window can still be placing
    # itself when it first appears in the window list, and a stale rectangle
    # captures the desktop next to it.
    screencapture -x -R"$("$FINDER" --pid "$APP_PID" --rect)" "$OUT"
else
    screencapture -x -o -l"$WIN" "$OUT"
fi
echo "$OUT"
