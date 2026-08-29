# Offscreen UI harness

Compiled only under `-DUI_HARNESS`, the harness renders Voiceour's real SwiftUI views in process, dumps the accessibility hierarchy, lints the semantic and raster output, and compares both with committed goldens. It never puts a window on a display, never changes the frontmost app, and needs no Screen Recording or Accessibility permission.

## Commands

| command | purpose |
| --- | --- |
| `make ui-snap`, `make ui-snap-os26` | Render scenes; compare AX dumps and PNG digests. The `os26` leg needs a macOS 26 host. |
| `make ui-update`, `make ui-update-os26` | Rewrite intended scene goldens. |
| `make ui-flow`, `make ui-flow-os26` | Run flows and compare their journals. |
| `make ui-flow-update` | Rewrite intended portable flow journals. |
| `make ui-list`, `make ui-flow-list` | Print the scene or flow catalog as JSON. |
| `make ui-all` | Portable scenes and flows, then the supported `os26` legs. |
| `make ui-mercury` | Render isolated shipping/prototype material contact sheets. Not a gate. |
| `make ui-mercury-bench` | Run the selected chrome material through 4,096 room seeds, 64 production rasters and 30 seconds of motion. |

`scripts/ui_harness.sh` builds with `-DUI_HARNESS` and forwards these flags:

| flag | meaning |
| --- | --- |
| `--mode MODE` | `list`, `check`, `update`, `flow-list`, `flow-check`, `flow-update`, `mercury`, or `mercury-benchmark`; default `check`. |
| `--only a,b`, `--except a,b` | Include, then exclude, ids containing or tagged `a` or `b`. |
| `--out DIR`, `--golden DIR` | Artifact and golden directories; default `.build/ui-harness` and `fixtures/ui`. |
| `--repo-root DIR` | Root for both defaults, or set `VOICEOUR_REPO_ROOT`. |
| `--scale 1\|2` | Raster scale; default 1. |
| `--no-sheet`, `--stdout` | Skip the contact sheet; emit the NDJSON manifest to stdout. |

An unfiltered run excludes `os26`. Exit status is 0 when clean or updated, 1 for a changed, missing, or failed artifact or an error-severity lint finding, 2 for bad arguments.

## Artifacts and goldens

```text
.build/ui-harness/
  <scene>.png
  <scene>.ax.txt
  <scene>.ax.diff                 # present only while AX differs
  manifest.jsonl
  contact-sheet.png
  flows/
    <flow>.flow.txt
    <flow>.flow.diff              # present only while the journal differs
    manifest.jsonl
  mercury/                        # isolated material tools; no goldens
    states.png                    # every shipping state on four grounds
    motion.png                    # consecutive shipping speaking frames
    outcome-motion.png            # lurch/collapse impulse transition frames
    worlds.png                    # four rooms of each generated world
    adaptations.png               # standard and bounded Increase Contrast
    comparison.png                # shipping and candidate, same body and room
    candidate-motion.png          # shipping/candidate temporal strips
    candidate-worlds.png          # shipping/candidate seed comparison
    room-sweep.png                # source-count/scale/bounce search
    selected-room-worlds.png      # accepted scalar/chromatic room over eight seeds
    chroma-sweep.png              # accepted room at four chroma strengths
    benchmark.json                # hard-gate distribution/raster/motion report

fixtures/ui/
  <scene>.png.sha256
  <scene>.ax.txt
  flows/<flow>.flow.txt
```

The full PNG is for inspection; the committed raster golden is its SHA-256 digest, keeping binary churn out of history.

Read the generated `.ax.diff` or `.flow.diff` before any update; update mode writes only changed payloads. A scene with an error-severity lint finding cannot be blessed, and neither can a failing flow.

### Committed documentation captures

`docs/media/` holds the full PNGs that public documentation displays. They are never hand-edited and never a gate.

| file | source |
| --- | --- |
| `docs/media/dictation-island-still.png` | portable `overlay.island.recording` at 2×, centered pixel-for-pixel on a transparent 720×216 canvas |
| `docs/media/home-sample.png` | onscreen `scripts/console_shot.sh`, sample data, 800×1185 pt |
| `docs/media/history-sample.png` | `console.sessions.selection` |
| `docs/media/glossary-sample.png` | `console.glossary.populated` |

The two harness captures are copied straight from `.build/ui-harness/*.png` after `scripts/ui_harness.sh --only console.sessions.selection,console.glossary.populated`.

`home-sample.png` cannot come from the harness, because it is the one documentation capture that shows the console *window*. `cacheDisplay` renders neither glass path, so the offscreen tab bar comes out as a white block and there is no title bar at all — an image that reads as a broken app. It is photographed onscreen instead:

```sh
CONSOLE_SHOT_SAMPLE_DATA=1 CONSOLE_SHOT_ACTIVATE=1 \
  CONSOLE_SHOT_SIZE=800x1185 CONSOLE_SHOT_SETTLE=1.5 \
  scripts/console_shot.sh home docs/media/home-sample.png
```

All three variables are load-bearing. `CONSOLE_SHOT_SAMPLE_DATA=1` points the app at a scratch support directory seeded from `fixtures/media/console-sample`; without it the capture publishes the maintainer's own transcripts and the apps they dictate into. `CONSOLE_SHOT_ACTIVATE=1` lets the window become key, so the traffic lights and tab labels photograph at full strength instead of their inactive greys. `CONSOLE_SHOT_SIZE` overrides the default 800×980 window, which clips the activity grid.

The seeded directory is not the fixture copied verbatim. `scripts/seed_console_data.swift` rebases every day key, every app's `lastDay` and every transcript stamp by one offset, so the newest day lands today: the ledger prunes day buckets past 400 days, and a fixture frozen at its authored dates would eventually photograph an empty grid and a zero streak. `console.home.full-page` remains the harness golden for the same page's layout — the offscreen render is what gates a layout change; this capture only illustrates it.

Because the window is real, the Top-apps rows resolve icons through LaunchServices and show whichever of the sample bundle ids are installed on the capturing Mac. That is a property of an onscreen capture, not a seam: `RenderOverrides.installedApps` pins those only for the offscreen goldens.

Build the island still with:

```sh
scripts/ui_harness.sh --update --only overlay.island.recording --except os26 \
  --scale 2 --out .build/ui-harness/docs --golden .build/ui-harness/docs-golden
ffmpeg -y -loglevel error \
  -i .build/ui-harness/docs/overlay.island.recording@2x.png \
  -vf 'pad=720:216:(ow-iw)/2:(oh-ih)/2:color=black@0,format=rgba' \
  -frames:v 1 docs/media/dictation-island-still.png
```

`docs/media/app-icon.png` is `sips`-exported from `Resources/AppIcon.icns` at 256×256.

## Scenes

A scene is an id, size, tags, and a closure building the real view. `make ui-list` is the authoritative inventory: the console tabs and their empty, first-run, search, filtered, teach, permission and confirmation states; the menu popover; the recording panel and island; accessibility adaptations; `os26` branches.

Home's first-run card needs no seam of its own. Whether it is owed is computed from three real inputs a fixture already owns — the persisted `has_completed_first_run` flag, the seeded transcript journal, and the seeded lifetime ledger — so the `firstRunDownloading`, `firstRunReady`, `firstRunAcquisitionFailed` and `erasedFigures` fixtures reach their states the way a real install does. Adding a `RenderOverrides` field for it would be a branch that exists only to make a golden pass.

Scene rules:

1. Build coordinators through `UIFixtures`, never `DictationCoordinator.live()`.
2. Derive no artifact value from the current time, randomness, the system accent, local permission grants, home paths, or the developer's locale or time zone.
3. Pin those values through the existing `RenderOverrides` seams; read that type for the full set. Every seam defaults to nil or false, and at those defaults production must behave as if the type did not exist. A set seam substitutes an input or selects a path production already reaches — `override ?? realValue` for a value, `if let` for a wholesale replacement, a boolean branch for `forceLegacyGlass`'s painted pre-macOS-26 path — never a branch that exists only to make a golden pass.
4. Avoid perpetual animation. Fixed run-loop pumping makes an animating scene time-dependent.
5. Extend the closest existing scene instead of starting a second fixture convention.

## Semantic flows

A flow hosts a real menu, overlay, or console view with an inert fixture, then drives real controls and `DictationCoordinator` transitions through a deterministic script. Checkpoints assert named semantics into a host-independent `.flow.txt` journal, which is the durable contract; flows own no raster or AX golden. `make ui-flow-list` is the authoritative inventory.

## Load-bearing constraints

- `UIHarnessRuntime.prepareProcess()` sets activation policy `.prohibited` before hosting any view, and reasserts it around hosting.
- `OffscreenWindow` parks far offscreen, and its `constrainFrameRect(_:to:)` returns the requested rect without calling `super`; otherwise AppKit pulls it onscreen.
- Settling is a fixed count of run-loop pumps, never an adaptive wait for stability.
- Enhanced accessibility must be enabled before the dump, or `NSHostingView` exposes a near-empty tree.
- Capture uses `cacheDisplay(in:to:)` into an owned interleaved RGBA8 `NSBitmapImageRep` with `.deviceRGB`, alpha kept; alpha disables subpixel font smoothing and its raster drift.
- `cacheDisplay` drops system glass, Core Animation blur and shadow. Verify the console/menu glass onscreen with `CONSOLE_SHOT_COMPOSITED=1 scripts/console_shot.sh <tab>`. The recording island is an ordinary `CGImage` and is captured completely offscreen; its scene goldens and `make ui-mercury` artifacts are the material proof.
