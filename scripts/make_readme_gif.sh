#!/bin/sh
# Build the README's recording-island GIF from the offscreen UI harness film mode.
#
# This records the REAL SwiftUI overlay frame by frame through the harness, so it never
# screen-records the user's display, never opens a window on it and needs no Screen
# Recording permission. The harness writes numbered PNGs; ffmpeg turns them into a GIF
# with a two-pass palette so 256 colours land where the eye is looking.
#
# Usage: scripts/make_readme_gif.sh [--reel ID] [--width PX] [--out FILE]
#   scripts/make_readme_gif.sh                      # docs/media/dictation-island.gif at 720 px
#   scripts/make_readme_gif.sh --width 480          # a narrower GIF from the same frames
#   scripts/make_readme_gif.sh --out /tmp/pill.gif  # somewhere other than docs/media
#
# Frames land in .build/ui-harness/film/<reel>/ alongside reel.json, which carries the
# frame count and the intended per-frame delay this script derives its frame rate from.
# The committed GIF is media, not a golden: nothing diffs it and no gate runs it.
# See docs/ui-harness.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

REEL=dictation-island
WIDTH=720
OUT=

usage() {
    echo "usage: scripts/make_readme_gif.sh [--reel ID] [--width PX] [--out FILE]"
}

while [ $# -gt 0 ]; do
    case $1 in
        --reel)
            REEL=$2
            shift 2
            ;;
        --reel=*)
            REEL=${1#--reel=}
            shift
            ;;
        --width)
            WIDTH=$2
            shift 2
            ;;
        --width=*)
            WIDTH=${1#--width=}
            shift
            ;;
        --out)
            OUT=$2
            shift 2
            ;;
        --out=*)
            OUT=${1#--out=}
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$OUT" ] || OUT="$ROOT/docs/media/$REEL.gif"

for tool in ffmpeg ffprobe; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "make_readme_gif.sh: $tool is not on PATH; install it with \`brew install ffmpeg\`" >&2
        exit 1
    fi
done

"$ROOT/scripts/ui_harness.sh" --mode film --only "$REEL" --scale 2

FRAMES="$ROOT/.build/ui-harness/film/$REEL"
if [ ! -f "$FRAMES/reel.json" ]; then
    echo "make_readme_gif.sh: $FRAMES/reel.json is missing; did --only $REEL match a reel?" >&2
    exit 1
fi

# Plain sed rather than jq: this script must run on a clean checkout with nothing but
# ffmpeg installed. The reel owns the playback delay, so the frame rate follows it.
MS=$(sed -n 's/.*"frame_milliseconds"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$FRAMES/reel.json")
if [ -z "$MS" ] || [ "$MS" -le 0 ]; then
    echo "make_readme_gif.sh: cannot read frame_milliseconds from $FRAMES/reel.json" >&2
    exit 1
fi
FPS=$(awk -v ms="$MS" 'BEGIN { printf "%.6f", 1000 / ms }')

mkdir -p "$(dirname -- "$OUT")"

# Two passes in one graph: palettegen with stats_mode=diff weights the colours the moving
# waveform and the comet need, and an ordered bayer dither keeps the flat backdrop from
# dissolving into the animated noise a diffusion dither would produce.
ffmpeg -y -v error -framerate "$FPS" -i "$FRAMES/frame-%04d.png" \
    -filter_complex "scale=${WIDTH}:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    -loop 0 "$OUT"

BYTES=$(wc -c < "$OUT" | tr -d ' ')
DIMS=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$OUT")
echo "make_readme_gif.sh: $OUT $DIMS $BYTES bytes at ${FPS} fps"
