#!/bin/sh
# Offscreen UI harness: render, dump, lint and diff the VoiceOour UI.
#
# This never opens a window on a display and never steals focus. The app runs with
# activation policy .prohibited and draws into a borderless window parked far offscreen,
# so nothing appears on your screen and the frontmost application does not change. It
# needs no Screen Recording and no Accessibility permission, and it starts none of the
# app's real machinery: the harness exits from the first statement of VoiceOourApp.init,
# before the audio muter, the dictation coordinator or the menu bar item exist.
#
# Usage: scripts/ui_harness.sh [--list | --update | --flow-list | --flow-check | --flow-update | --coverage] [options]
#   scripts/ui_harness.sh                      # render every scene, check against fixtures/ui
#   scripts/ui_harness.sh --only console       # just the scenes tagged/named console
#   scripts/ui_harness.sh --update             # rewrite the goldens after an intended change
#   scripts/ui_harness.sh --list               # print the scene catalog as one JSON object
#   scripts/ui_harness.sh --flow-check         # run selected semantic UI journeys
#   scripts/ui_harness.sh --flow-update        # rewrite flow journals and frame goldens
#   scripts/ui_harness.sh --flow-list          # print the flow catalog as one JSON object
#   scripts/ui_harness.sh --coverage           # evaluate declared UI coverage without rendering
#
# Artifacts land in .build/ui-harness/: <scene>.png, <scene>.ax.txt, <scene>.ax.diff,
# manifest.jsonl and contact-sheet.png. Run with --help for the full option list.
# See docs/ui-harness.md.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# -DUI_HARNESS: the harness is compiled out of a plain build, so the binary would
# otherwise not recognise --ui-harness at all.
swift build --package-path "$ROOT" -Xswiftc -DUI_HARNESS >/dev/null


exec "$ROOT/.build/debug/VoiceOour" --ui-harness --repo-root "$ROOT" "$@"
