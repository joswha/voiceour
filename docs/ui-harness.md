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

`scripts/ui_harness.sh` builds with `-DUI_HARNESS` and forwards these flags:

| flag | meaning |
| --- | --- |
| `--mode MODE` | `list`, `check`, `update`, `flow-list`, `flow-check`, or `flow-update`; default `check`. All but `check` also work as bare flags (`--update`). |
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

fixtures/ui/
  <scene>.png.sha256
  <scene>.ax.txt
  flows/<flow>.flow.txt
```

The full PNG is for inspection; the committed raster golden is its SHA-256 digest, keeping binary churn out of history.

Read the generated `.ax.diff` or `.flow.diff` before any update; update mode writes only changed payloads. A scene with an error-severity lint finding cannot be blessed, and neither can a failing flow.

### Committed documentation captures

`docs/media/` holds the full PNGs that public documentation displays: deterministic harness derivatives, never hand-edited and never a gate.

| file | source scene |
| --- | --- |
| `docs/media/dictation-island-still.png` | portable `overlay.island.recording` at 2×, centered pixel-for-pixel on a transparent 720×216 canvas |
| `docs/media/home-sample.png` | `console.home.readme` |
| `docs/media/history-sample.png` | `console.sessions.selection` |
| `docs/media/glossary-sample.png` | `console.glossary.populated` |

Regenerate the three console captures with `scripts/ui_harness.sh --only console.home.readme,console.sessions.selection,console.glossary.populated`, then copy their `.build/ui-harness/*.png` files over the `docs/media` counterparts. Build the island still with:

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

A scene is an id, size, tags, and a closure building the real view. `make ui-list` is the authoritative inventory: the console tabs and their empty, search, filtered, permission and confirmation states; the menu popover; the recording panel and island; accessibility adaptations; `os26` branches.

Scene rules:

1. Build coordinators through `UIFixtures`, never `DictationCoordinator.live()`.
2. Derive no artifact value from the current time, randomness, the system accent, local permission grants, home paths, or the developer's locale or time zone.
3. Pin those values through the existing `RenderOverrides` seams; read that type for the full set. A production read stays `override ?? realValue`, never a harness-only branch in shipping code.
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
- Neither glass path survives `cacheDisplay`, which also drops Core Animation blur and shadow. Verify glass onscreen with `CONSOLE_SHOT_COMPOSITED=1 scripts/console_shot.sh <tab>`.
