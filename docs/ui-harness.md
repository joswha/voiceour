# Offscreen UI harness

Compiled only under `-DUI_HARNESS`, the harness renders Voiceour's real SwiftUI views in process, dumps the accessibility hierarchy, lints the semantic and raster output, and compares both with committed goldens. It never puts a window on a display, never changes the frontmost app, and needs no Screen Recording or Accessibility permission.

This file is the harness's operational reference: commands, artifacts, scene and flow rules, and capture procedures. [README.md](../README.md#verification) owns which gates a change must pass, and [AGENTS.md](../AGENTS.md#offscreen-ui-harness) owns the binding harness invariants together with the measurements behind them.

## Commands

| command | purpose |
| --- | --- |
| `make ui-snap` | Render all scenes; compare AX dumps and PNG digests on macOS 27. |
| `make ui-update` | Rewrite intended scene goldens. |
| `make ui-flow` | Run all flows and compare their journals. |
| `make ui-flow-update` | Rewrite intended flow journals. |
| `make ui-list`, `make ui-flow-list` | Print the scene or flow catalog as JSON. |
| `make ui-all` | All scenes and semantic flows. |
| `make ui-mercury` | Render isolated shipping/prototype material contact sheets for the island and the collar, including the garage's looks, metals, coats, room lighting, and body kit. Not a gate. |
| `make ui-mercury-bench` | Gate 4,096 seeds of each room, 64 production rasters, 64 collar sessions, 30 seconds of motion, every look over 64 rooms on the island and on the collar, 48 option corners over 64 rooms each, and 1,200 island and collar raster plus island engine-and-layer frames at represented 120 Hz, the island's for the stock look and for Street Racer. |

Scene PNG digests and AX dumps are host-sensitive: the committed goldens come from the maintainer's Apple Silicon Mac, so hosted CI runs `make ui-snap` only as an advisory job, while flow journals are host-independent and required. Bless scene goldens from a local render, never from CI output.

`scripts/ui_harness.sh` builds a debug binary with `-DUI_HARNESS` and forwards these flags. `make ui-mercury-bench` instead builds the release configuration with the same flag and runs `.build/release/Voiceour --ui-harness --repo-root . --mode mercury-benchmark` directly, so its timings measure optimized code. It prints one `mercury-benchmark:` line for the stock look and a second for the Overcast screen, the look corpus on both layouts, and the Street Racer arm, prints each failed gate as a `mercury-benchmark: FAIL:` line, and writes the full report to `.build/ui-harness/mercury/benchmark.json`.

| flag | meaning |
| --- | --- |
| `--mode MODE` | `list`, `check`, `update`, `flow-list`, `flow-check`, `flow-update`, `mercury`, or `mercury-benchmark`; default `check`. |
| `--only a,b`, `--except a,b` | Include, then exclude, ids containing or tagged `a` or `b`. |
| `--out DIR`, `--golden DIR` | Artifact and golden directories; default `.build/ui-harness` and `fixtures/ui`. |
| `--repo-root DIR` | Root for both defaults, or set `VOICEOUR_REPO_ROOT`. |
| `--scale 1\|2` | Raster scale; default 1. |
| `--no-sheet`, `--stdout` | Skip the contact sheet; also print the NDJSON manifest to stdout. |

An unfiltered run includes the full catalog. Exit status is 0 when clean or updated, 1 for a changed, missing, or failed artifact or an error-severity lint finding, 2 for bad arguments.

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
    worlds.png                    # stock look in four seeds of each room
    looks.png                     # every look on four grounds, speaking
    metals.png                    # every metal bare and clear-coated, darkest/lightest grounds
    coats.png                     # every coat at its default, on titanium and mercury
    lighting.png                  # 10,667 / 6,504 / 4,678 K, underglow off and on
    body.png                      # body-kit corners: speaking at three crowns, listening, warming
    adaptations.png               # standard and bounded Increase Contrast
    comparison.png                # shipping and candidate, same body and room
    candidate-motion.png          # shipping/candidate temporal strips
    candidate-worlds.png          # shipping/candidate seed comparison
    room-sweep.png                # source-count/scale/bounce search
    selected-room-worlds.png      # accepted scalar/chromatic room over eight seeds
    chroma-sweep.png              # accepted room at four chroma strengths
    collar-states.png             # every shipping state on the 185×32 collar, four grounds
    collar-motion.png             # consecutive shipping speaking collar frames
    collar-looks.png              # every look on the 185×32 collar
    benchmark.json                # hard-gate room/raster/collar/look/motion/120 Hz report

fixtures/ui/
  <scene>.png.sha256
  <scene>.ax.txt
  flows/<flow>.flow.txt
```

The full PNG is for inspection; the committed raster golden is its SHA-256 digest, keeping binary churn out of history.

The collar sheets lay the body on the collar around `.fixtureNotch`'s 185×32 pt camera housing, with the island sheets' seed and room, so each collar row differs from its island row by the layout alone. They composite the housing and the bezel above the screen's top edge in black, as a display has them; the body itself draws nothing inside the housing.

Read the generated `.ax.diff` or `.flow.diff` before any update; update mode writes only changed payloads. A scene with an error-severity lint finding cannot be blessed, and neither can a failing flow.

`manifest.jsonl` starts with one `ui_run` row — mode, filter, scale, scene count, `ok`/`changed`/`missing_golden`/`written`/`failed` tallies, error and warning finding counts, timing, directories, and contact-sheet path — followed by one `ui_scene` row per rendered scene. A scene row carries its overall `status`, `pixel_status` and `ax_status` (`ok`, `changed`, `missing-golden`, `written`, or `failed`), `png_sha256` beside `golden_png_sha256`, `ax_node_count`, lint `findings` (`rule`, `severity`, `message`), warnings, and any error. `flows/manifest.jsonl` starts with a `ui_flow_run` row carrying flow and expectation tallies, then one `ui_flow` row per flow and one `ui_expectation` row per checked expectation with its expected and observed text. `make ui-list` and `make ui-flow-list` print one `ui_catalog` or `ui_flow_catalog` JSON object.

On macOS 27 the native `console.home.populated.png` capture is 99.936% opaque and 0.047% fully transparent, measured from its alpha channel. The native ground passes error-severity lint; base scenes retain Reduce Transparency off, and the dedicated accessibility scenes exercise it on.

Native accessibility titles may be attributed strings. The walker prefers a control's explicit title over its glyph/selected-text label. Dynamic state marks remain nonselectable because macOS 27's grouped-form text-selection wrapper retains its initial accessibility value; selectable History evidence supplies one plain-text accessibility representation to avoid duplicate narration.

### Committed documentation captures

`docs/media/` holds the full PNGs that public documentation displays. They are never hand-edited and never a gate.

| file | source |
| --- | --- |
| `docs/media/home-sample.png` | onscreen `scripts/console_shot.sh`, sample data, 800×1185 pt |
| `docs/media/history-sample.png` | `console.sessions.selection` |
| `docs/media/glossary-sample.png` | `console.glossary.populated` |

The two harness captures are copied straight from `.build/ui-harness/*.png` after `scripts/ui_harness.sh --only console.sessions.selection,console.glossary.populated`.

`home-sample.png` cannot come from the harness, because it is the one documentation capture that shows the console *window*. `cacheDisplay` cannot capture composited desktop glass, and the offscreen window has no title bar. It is photographed onscreen instead, which — unlike the harness — puts a real window on the display and needs Screen Recording permission for the controlling terminal, plus Accessibility trust for the resize:

```sh
CONSOLE_SHOT_SAMPLE_DATA=1 CONSOLE_SHOT_ACTIVATE=1 \
  CONSOLE_SHOT_SIZE=800x1185 CONSOLE_SHOT_SETTLE=1.5 \
  scripts/console_shot.sh home docs/media/home-sample.png
```

The first three variables are load-bearing; `CONSOLE_SHOT_SETTLE` only lengthens the pre-capture settle from its 0.6 s default. `CONSOLE_SHOT_SAMPLE_DATA=1` points the app at a scratch support directory seeded from `fixtures/media/console-sample`; without it the capture publishes the maintainer's own transcripts and the apps they dictate into. `CONSOLE_SHOT_ACTIVATE=1` lets the window become key, so the traffic lights and tab labels photograph at full strength instead of their inactive greys. `CONSOLE_SHOT_SIZE` overrides the default 800×980 window, which clips the activity grid.

The seeded directory is not the fixture copied verbatim. `scripts/seed_console_data.swift` rebases every day key, every app's `lastDay` and every transcript stamp by one offset, so the newest day lands today: the ledger prunes day buckets past 400 days, and a fixture frozen at its authored dates would eventually photograph an empty grid and a zero streak. `console.home.full-page` remains the harness golden for the same page's layout — the offscreen render is what gates a layout change; this capture only illustrates it.

Because the window is real, the Top-apps rows resolve icons through LaunchServices and show whichever of the sample bundle ids are installed on the capturing Mac. That is a property of an onscreen capture, not a seam: `RenderOverrides.installedApps` pins those only for the offscreen goldens.

`docs/media/app-icon.png` is `sips`-exported from `Resources/AppIcon.icns` at 256×256.

## Scenes

A scene is an id, size, tags, and a closure building the real view. `make ui-list` is the authoritative inventory: the console tabs and their empty, first-run, search, filtered, teach, permission and confirmation states; Settings ▸ Island and its showroom; the menu popover; the recording panel, island and collar, and the island in every look; accessibility adaptations. Every scene follows the shipping macOS 27 path.

Home's first-run card needs no seam of its own. Whether it is owed is computed from three real inputs a fixture already owns — the persisted `has_completed_first_run` flag, the seeded transcript journal, and the seeded lifetime ledger — so the `firstRunDownloading`, `firstRunReady`, `firstRunAcquisitionFailed` and `erasedFigures` fixtures reach their states the way a real install does. Adding a `RenderOverrides` field for it would be a branch that exists only to make a golden pass.

`menu.sidecar-error` drives the actual coordinator through a wrapped sidecar model failure before capturing the menu. It locks the specific cause and recovery controls, rather than assigning an error state directly.

`overlay.notch.recording`, `.listening`, `.warmup`, `.processing`, `.copied`, `.lurch`, `.error`, `.reduced-motion` and `.fullscreen` render the collar around `.fixtureNotch`'s 185×32 pt camera housing on its 33 pt menu-bar band, and `overlay.notch.wide` the speaking collar around `.fixtureWideNotch`'s 220×38 pt housing on its 39 pt band. `.fullscreen` is the speaking collar with the model's pose context saying the frontmost window fills the display, so its film runs along both ears into the empty band. Each is the canvas alone, as the island scenes are: 314×59 and 349×65 pt, the collar's whole panel. The showroom's own per-pose models, `IslandShowroomPose.model()`, supply the island and collar scenes' states, except `.lurch` and `.error`, which build their own outcomes, and the model carries the layout `UIFixtures.collarLayout(on:)` resolves through `RecordingOverlayLayout.forDisplay(_:)`, the resolution the panel makes; it traps on a display that would fall back to the island.

`UIFixtures.pinProcessSeams()` pins `RenderOverrides.overlayDisplay` to `.fixtureNotchless`, beside the mercury pins, so anything that resolves the overlay's display reads the island's notchless display instead of the rendering Mac's screen. The collar scenes set their layout on the model rather than through that seam.

`overlay.island.overcast`, the `overlay.island.look.<look>` scenes, one for every look other than Stock, and `overlay.notch.look.street-racer`, the speaking collar in Street Racer, pass their appearance straight to `RecordingOverlayView`; every other overlay scene renders the stock appearance. No seam is involved. Street Racer changes every input a look reaches, so the collar scene locks a look's paint, room lighting, response, and body kit on the collar's layout, where the body kit keeps the housing's length.

Settings ▸ Island has its own scenes. `console.settings.island.tuning` opens every fold at stock; `console.settings.island.look` shows a non-stock look's readouts and the rows its choices enable; `console.settings.island.custom` shows the CUSTOM mark — Arctic Platinum with its Finish moved — beside a persisted free placement, with Dock Island enabled above the free caption; `console.settings.island.outcome` holds the showroom at an outcome pose, where Play Again appears but is never pressed, because its 1.2 s hold runs on the wall clock. `a11y.island.increase-contrast` locks the disabled Brightness and Contrast rows with their caption, and `a11y.island.reduce-motion` the disabled Shimmer row with its caption; each also captures the showroom under its adaptation. The readout-focused Settings scenes — `console.settings.denied`, `console.settings.downloading`, and `a11y.differentiate-without-color` — and `console.settings.island.custom` render the whole Settings page, because the Island section puts Readiness below the 820 pt first-launch measure; `console.settings.granted` keeps that measure. Scenes that open folds are taller, sized to their open rows, and `console.settings.island.outcome` is sized to the showroom it locks.

Two seams keep the garage deterministic. `RenderOverrides.islandPlacementDefaults` points every placement read and write — Settings ▸ Island's Dock Island row, the overlay controller, and the flows' probe alike — at the harness suite `com.voiceour.ui-harness.placement`, which every seam pin resets to docked, so a free placement is always one a fixture put there and no golden encodes where the rendering Mac's user last left the island. `RenderOverrides.islandShowroomPose` pins the showroom's opening pose; it stays nil, which opens on Speaking, except in the scope of the one scene that shows an outcome pose. The pinned mercury seed also starts the showroom's room sequence and seeds Surprise Me, so its draws are part of the flow journals.

Scene rules:

1. Build coordinators through `UIFixtures`, never `DictationCoordinator.live()`.
2. Derive no artifact value from the current time, randomness, the system accent, local permission grants, home paths, or the developer's locale or time zone.
3. Pin those values through the existing main-actor [`RenderOverrides`](../Sources/Voiceour/RenderOverrides.swift) seams. Every seam defaults to nil or false, and at those defaults production must behave as if the type did not exist. A set seam substitutes an input or selects a path production already reaches — `override ?? realValue` for a value, `if let` for a wholesale replacement — never a branch that exists only to make a golden pass.
4. Avoid perpetual animation. Fixed run-loop pumping makes an animating scene time-dependent.
5. Extend the closest existing scene instead of starting a second fixture convention.

## Semantic flows

A flow hosts a real menu, overlay, or console view with an inert fixture, then drives real controls and `DictationCoordinator` transitions through a deterministic script. Checkpoints assert named semantics into a host-independent `.flow.txt` journal, which is the durable contract; flows own no raster or AX golden. `make ui-flow-list` is the authoritative inventory.

Failure journeys inject the same `SidecarASRClientError.protocolError` wrapper the real client throws. `dictation.asr-error` checks the engine-specific cause and zero delivery/history; `dictation.asr-recovery` presses the real Try Again control and completes a later utterance; `overlay.asr-error` checks the actionable failure announcement without a delivery confirmation. Process-level malformed JSON/schema/UTF-8 rejection and respawn are exercised separately through `ASRSidecarStub`, including a client-to-coordinator integration path.

`island.*` flows drive Settings ▸ Island through its real controls: the look, coat and room radios, the fold labels and the Material fold's Restore Stock, the underglow switch, Surprise Me, Another Room, and Dock Island. One slider moves: `island.tune-to-custom` steps Finish once through the accessibility increment, which SwiftUI brackets with editing begin and end, so the step exercises the release commit every Garage slider shares. Checkpoints read the committed look, its canonical description, whether a draft is still pending, and whether the persisted placement is docked or free, so a journal verifies the committed settings rather than only a redrawn view: `island.position-dock` presses Dock Island on a free placement and checks that the placement is docked, the button disabled, and the caption the docked one. The Metal and Pose pop-up menus are pinned by fixtures instead, because an unordered offscreen window cannot open an `NSMenu`. Undo has no flow: ⌘Z is a key equivalent that AppKit offers only to the key window, so `IslandGarageEditorTests` drive the undo steps against a standalone `UndoManager`.

## Load-bearing constraints

This is the mechanism summary; [AGENTS.md](../AGENTS.md#offscreen-ui-harness) records the measured invariants behind it — park origin, pump counts, activation-policy and AX-node measurements.

- `UIHarnessRuntime.prepareProcess()` sets activation policy `.prohibited` before hosting any view, and reasserts it around hosting.
- `OffscreenWindow` parks far offscreen, and its `constrainFrameRect(_:to:)` returns the requested rect without calling `super`; otherwise AppKit pulls it onscreen.
- Settling is a fixed count of run-loop pumps, never an adaptive wait for stability.
- Enhanced accessibility must be enabled before the dump, or `NSHostingView` exposes a near-empty tree.
- Capture uses `cacheDisplay(in:to:)` into an owned interleaved RGBA8 `NSBitmapImageRep` with `.deviceRGB`, alpha kept; alpha disables subpixel font smoothing and its raster drift.
- `cacheDisplay` drops system glass, Core Animation blur and shadow. Verify the console/menu glass onscreen with `CONSOLE_SHOT_COMPOSITED=1 scripts/console_shot.sh <tab>`. The recording island is an ordinary `CGImage` and is captured completely offscreen; its scene goldens and `make ui-mercury` artifacts are the material proof.
- The harness pins `RenderOverrides.mercurySeed` and `RenderOverrides.mercuryStep` for the whole process, so every `NSViewRepresentable` mercury surface — the island, the collar and the Settings showroom — writes one exact `CGImage` immediately and never starts its live display link. The harness therefore remains off-display while exercising the same engine, room and rasterizer as production.
