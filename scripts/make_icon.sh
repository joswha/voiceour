#!/bin/sh
# Regenerates Resources/AppIcon.icns from an emoji (default 👽).
# Usage: scripts/make_icon.sh [emoji]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EMOJI=${1:-👽}
WORK=$(mktemp -d)
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/render_emoji_icon.swift" "$EMOJI" "$ICONSET"
iconutil -c icns -o "$ROOT/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$WORK"
printf '%s\n' "$ROOT/Resources/AppIcon.icns"
