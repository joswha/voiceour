# Offscreen UI harness

The UI harness renders VoiceOour's SwiftUI views into a borderless window parked far offscreen, dumps the in-process accessibility tree, lints both, and diffs the result against committed goldens. It exists so a coding agent can see and check the UI without a window ever appearing on your display and without the frontmost application changing.

It replaces `scripts/console_shot.sh` for everything except the glass materials themselves — neither the legacy behind-window tint nor modern `.glassEffect` survives an offscreen capture (see [Limitations](#limitations)). `console_shot.sh` launches the real app, opens a visible 1164x820 console on your main display and screenshots it; the harness never does either.

What it gives you per scene:

- a PNG of the rendered view,
- a text dump of the accessibility tree (roles, labels, values, identifiers, window-local frames),
- machine-checkable lint findings,
- a diff against the golden when either artifact moves,
- and one contact sheet tiling every selected scene, so a single image read replaces dozens.

The harness needs no Screen Recording permission, no Accessibility permission, no Xcode, and no simulator.

It is compiled only when `UI_HARNESS` is defined. Every developer entry point defines it — `scripts/ui_harness.sh` (and therefore every `make ui-*` target) and the `make test` / CI `swift test` steps, because `UISceneCatalogTests` and `UILintTests` reference gated symbols. The one build that omits it is `scripts/bundle.sh`, whose plain `swift build -c release` is what ships, so no harness object links into the release binary. A bare `swift test` still passes; it simply compiles the two harness suites away, so prefer `make test`. If you see `cannot find 'UISceneCatalog' in scope`, you dropped the flag.

`RenderOverrides` and its two payload types (`TextRoleSample`, `TextRoleRecorder`) are deliberately **not** gated: thirteen production files read the overrides, and `DesignTokenInstrumentation` sits on the canonical `.roleStyle(_:)` path. Every field is nil in a normal build and every production read is `override ?? <the real value>`, so shipping behaviour is unchanged. It is called `RenderOverrides` rather than `UIHarnessSeams` precisely because it ships: a harness-named type read by production code invites someone to gate it alongside `UIHarness/`, which does not compile.

`nm .build/release/VoiceOour | grep -ci uiharness` is therefore `0`, and `swift build -c release` links no harness object. Be clear about what that proves: it is a check that the harness *implementation* is absent, not that the binary shrank to nothing — `RenderOverrides` still contributes about fourteen symbols of static storage under its own name, and renaming the type moved roughly 320 bytes, not the 795 KB the gating itself removed.

## Commands

```sh
make ui-snap                                   # render portable scenes; excludes tag os26
make ui-snap-os26                              # render the native macOS 26 branch scenes on macOS 26
make ui-update                                 # rewrite portable scene goldens after an intended change
make ui-update-os26                            # rewrite native scene goldens; needs a macOS 26 host
make ui-list                                   # print the scene catalog as one JSON object
make ui-flow                                   # required semantic flow gate; skip host-sensitive frame comparison
make ui-flow-os26                              # native interactive gate; drives the macOS 26 branch
make ui-flow-frames                            # run flows and compare their captured-frame goldens
make ui-flow-update                            # rewrite intended flow goldens and the coverage baseline
make ui-flow-list                              # print the flow catalog as one JSON object
make ui-coverage                               # validate coverage declarations and the baseline without hosting a window
make ui-film                                   # record the README's recording-island GIF; media, not a golden
make ui-all                                    # run ui-snap, then ui-flow-frames

scripts/ui_harness.sh --only console           # ids containing, or tags exactly matching, "console"
scripts/ui_harness.sh --only console,overlay   # comma-separated, OR-ed
scripts/ui_harness.sh --except os26             # exclude ids/tags after applying --only
scripts/ui_harness.sh --mode flow-check         # run selected flows
scripts/ui_harness.sh --mode film               # record the selected media reels frame by frame
scripts/ui_harness.sh --scale 2                 # 2x raster
scripts/ui_harness.sh --stdout --no-sheet       # NDJSON manifest on stdout, skip the scene contact sheet
scripts/ui_harness.sh --help
```

`scripts/ui_harness.sh` builds the package, then execs `.build/debug/VoiceOour --ui-harness --repo-root <repo>` with your arguments appended. You can call the binary directly if you already built it.

### CLI surface

| flag | meaning |
| --- | --- |
| `--ui-harness` | required; selects the harness instead of the app. Its absence changes nothing about a normal launch. |
| `--list`, `--update` | shorthand for the matching scene `--mode`. |
| `--flow-list`, `--flow-check`, `--flow-update`, `--coverage` | shorthand for the matching flow or coverage `--mode`. |
| `--film` | shorthand for `--mode film`. |
| `--mode list\|check\|update\|flow-list\|flow-check\|flow-update\|coverage\|film` | select the operation; default `check`. An unrecognised value exits 2 with usage. |
| `--only a,b` | substring match on scene, flow or reel id, or exact match on a tag. Empty means the entire selected catalog. |
| `--except a,b` | substring match on scene, flow or reel id, or exact match on a tag. Applied after `--only`. An unfiltered non-list run defaults to excluding `os26`; explicit filters and list modes do not add that default. |
| `--out DIR` | artifact directory. Default `<repo>/.build/ui-harness`. |
| `--golden DIR` | golden directory. Default `<repo>/fixtures/ui`. |
| `--scale 1\|2` | raster scale. Default 1. Any other value is ignored and 1 is used. Scale 2 uses its own `@2x` artifacts and goldens. |
| `--no-frames` | skip golden reconciliation for flow `.capture` frames. PNG and AX-dump artifacts are still written and linted. |
| `--no-sheet` | skip the scene `contact-sheet.png`. |
| `--stdout` | also write the selected manifest to stdout. Prose then moves to stderr so stdout stays valid JSON or NDJSON. |
| `--repo-root DIR` | resolves the default `--out` and `--golden`. Also readable from `VOICEOOUR_REPO_ROOT`; defaults to the working directory. |
| `--help`, `-h` | print usage and exit 0. |

Exit codes: `0` success; `1` a scene or flow changed, is missing a golden, failed, produced an `error`-severity finding, the coverage ledger has a regression, stale baseline entry, broken declaration or undeclared claim, or a film reel failed to record; `2` a malformed `--ui-harness` invocation.

`--no-activate` is a separate, app-level flag (see [Activation](#activation)); the harness does not need it.

### `os26` scenes and flows, and the host OS

Scenes tagged `os26` render the **native `#available(macOS 26, *)` branch** — not the system material
that branch asks for. `cacheDisplay` does not rasterise SwiftUI `.glassEffect` at all, so the glass is
absent from the capture and its area comes out fully transparent; what an `os26` PNG actually shows is
the branch's own painted content, geometry and control boundaries, alongside its accessibility tree.
See [Limitations](#limitations).

The tag still has to exist, because the alternative render is worse. `#available` resolves against the
running OS, not the package's deployment floor, so on macOS 14 or 15 every one of these scenes would
silently take the painted fallback branch — a different render, equally not the one the scene exists to
show, and one that looks entirely plausible. In `check` mode that is a confusing failure; in `--update`
it would overwrite the native goldens with fallback renders, and the corruption would only surface on
the next Tahoe machine.

The harness therefore refuses to render them below macOS 26, and does so *before* writing anything:

- If the selection also matched portable scenes, the `os26` ones are **skipped** and the rest run
  normally. This matters because `--only console` substring-matches `console.home.os26` as well as
  the portable console scenes, and that focused run is the everyday workflow — aborting it would
  break exactly the hosts that can only ever use the portable path.
- If the selection resolves to `os26` scenes **only** (`--only os26`, or a native scene id), the run
  fails with a message pointing at `--except os26`.

On a macOS 26 host neither branch fires and every scene renders. The committed portable goldens are
pinned to the painted path by `RenderOverrides.forceLegacyGlass` regardless of host, so `make ui-snap`
reproduces byte-for-byte on any machine.

Flows tagged `os26` are gated the same way, for the same reason. They release `forceLegacyGlass` so
the script drives the native branch, so below macOS 26 every one of them would re-run the painted
path a portable flow already covers while claiming native-branch coverage. `make ui-flow-os26` runs
them and `make ui-flow` excludes them; on an older host a mixed selection skips them with a count,
and a selection that resolves to `os26` flows only fails with the same `--except os26` pointer.

## Artifacts

```
.build/ui-harness/
  <scene-id>.png                         current scene render
  <scene-id>.ax.txt                      current scene accessibility dump
  <scene-id>.ax.diff                     scene dump diff, golden -> current
  manifest.jsonl                         scene manifest
  contact-sheet.png                      every selected scene tiled and captioned
  flows/
    <flow-id>.flow.txt                   current semantic journal
    <flow-id>.flow.diff                  journal diff, golden -> current
    <flow-id>.<frame>.png                named frame raster
    <flow-id>.<frame>.ax.txt             named frame accessibility dump
    <flow-id>.<frame>.ax.diff            frame dump diff, golden -> current
    manifest.jsonl                       flow and coverage manifest
  film/
    <reel-id>/frame-0000.png             one reel frame, zero-padded and gapless
    <reel-id>/reel.json                  reel id, title, frame count, delay, pixel size, scale
fixtures/ui/
  coverage-baseline.txt                 required coverage keys currently unclaimed by passing flows
  <scene-id>.png.sha256                  scene raster digest golden
  <scene-id>.ax.txt                      scene dump golden
  flows/
    <flow-id>.flow.txt                   semantic journal golden
    <flow-id>.<frame>.ax.txt             named frame dump golden
    <flow-id>.<frame>.png.sha256         named frame raster digest golden
```

`.build/` is gitignored, `fixtures/ui/` is not: the current state is disposable, the goldens are reviewed in the diff of a pull request. The per-scene PNG and dump are written on **every** run in **every** mode, so you can look at the current state whether or not it matched. A stale `.ax.diff` is deleted as soon as the dump matches its golden again — including by the `--update` that just blessed it — so the presence of the file is itself the signal.

**The pixel golden is a digest, not an image.** Committing every full-size render would add megabytes and rewrite binary images on every `--update`; the committed SHA-256 digests detect the same pixel changes while keeping reviews textual and the golden set small. The cost is that git holds no *previous* image to diff against, so when `pixel_status` is `changed` and `ax_status` is `ok` you are looking at a pure visual move with no committed before-shot. To get one, render the old tree: `git stash && make ui-snap && cp .build/ui-harness/<id>.png /tmp/before.png && git stash pop && make ui-snap`.

`--scale 2` shifts the whole per-scene family to `<scene-id>@2x.*`, on both sides. Without that a 2x run would diff 2x pixels against 1x goldens and report every scene as `changed`; the scale also pins SwiftUI's `displayScale`, which moves pixel snapping and therefore the accessibility frames, so the dump is scaled too. `manifest.jsonl` and `contact-sheet.png` keep their fixed names in every mode, and the manifest carries `scale` on every row. The committed 1x goldens are the gate; 2x goldens are optional and only exist if someone runs `--scale 2 --update`.

## Scenes

A scene is one deterministic thing the harness can render, dump and lint: an id, a title, a logical size, a forced colour scheme, tags, an optional interaction script, and a closure that builds the view. The type is `UIScene` in `Sources/VoiceOour/UIHarness/UIHarnessContracts.swift`.

The catalog is the single place scenes are declared: `UISceneCatalog` in `Sources/VoiceOour/UIHarness/UISceneCatalog.swift`, where `all()` concatenates the portable area groups and `systemGlassScenes`. Adding a scene is one edit: append to the matching group array, using a factory rather than a raw `UIScene`.

| factory | size | what it gives you |
| --- | --- | --- |
| `console(_ id, _ title, section:, fixture:, size:, tags:, steps:)` | 1164x820 dark | the real `ConsoleView` at one section, tag `console` prepended. `size` defaults to the first-launch window; the keyed Refinement scenes pass a taller measure because that pane's CONNECTION card falls past the 820 pt fold |
| `pane(_ id, _ title, colorScheme:, tags:, steps:) { view }` | 1164x820 | one pane hosted directly, tag `pane` prepended, `Space.xl` padding on an opaque literal backdrop |
| `menu(_ id, _ title, fixture:)` | 280x420 dark | the menu popover, tag `menu` |
| `systemConsole`, `systemMenu`, `systemOverlay` | matching legacy measure | tag `os26`; builds the deterministic fixture first, then releases `forceLegacyGlass` only for the hosted scene and restores it at teardown |
| `sheet(_ id, _ title, size:) { view }` | your size | component gallery, tag `atom`, same padding and backdrop as `pane` |

Console and pane scenes render at 1164x820 because that is the app's first-launch window: `UISceneCatalog.consoleSize` is `VoiceOourMetrics.Window.defaultWidth` x `Window.defaultHeight`, so a scene shows exactly the geometry a fresh install shows — rail 176, region 988, padded content region 940 — and clears `ConsoleScaffold`'s 1164x560 minimum. Change the tokens and every console scene moves with them. The exception is `UISceneCatalog.tallConsoleSize`, used by the three keyed Refinement scenes whose subject is the Status row: the window is resizable, and at 820 pt that row is below the fold.

```swift
console("console.glossary.empty", "Glossary with every term removed",
        section: .glossary, fixture: .emptyGlossary, tags: ["empty"])
```

Raw `UIScene(...)` is used only by the two portable overlay scenes, which need odd sizes and no backdrop. The id is the artifact basename, so keep it filesystem-safe and dot-separated: lowercase, `area.thing.state`. Native Liquid Glass counterparts use an `*.os26` id and the matching system factory. Nothing else needs touching — the harness discovers the scene, renders it, and reports `missing-golden` until the owner blesses new fixtures.

The scene tag vocabulary is `console`, `empty`, `steps`, `pane`, `light`, `menu`, `overlay`, `atom`, `a11y`, and `os26`; flow tags are listed separately by `make ui-flow-list`. The current scene catalog has 48 entries: 36 portable scenes and 12 macOS 26 scenes. `UISceneCatalog.registry` builds that total from 24 console, one pane, three menu, two overlay, two atom, four accessibility, and 12 system-glass descriptors. Run `make ui-list` to regenerate the live scene enumeration; its catalog output is authoritative.

### Determinism

Two mechanisms in `UIFixtures.swift` carry it:

- App state comes from `UIFixtures.coordinator(_:)` — kinds `.firstRun`, `.populated`, `.emptyGlossary`, `.recording`, `.micDenied`, `.backendReady`, `.backendUnavailable`, `.backendSwitchPending`, `.refinerConfigured`, `.refinerAppleOnDevice`, `.refinerOmp`, `.refinerCustom`, `.refinerUnauthorized`, `.refinerUnreachable`, `.completedDictation`. It builds a `DictationCoordinator` out of inert fakes and never calls `DictationCoordinator.live()`, so no Python ASR sidecar is spawned, no CGEvent tap is installed, no microphone is opened and no warm-up task runs. The reachability probes are inert too, so no scene can spawn `omp` or reach the network even if one grows a `CHECK` step.
- `UIFixtures.pinProcessSeams()`, called on every `coordinator(_:)`, pins `RenderOverrides`: the render clock (`2025-06-15T14:26:40Z`), Gregorian calendar, UTC time zone, `en_US_POSIX` locale, the permission snapshot the System and Diagnostics panes display, the two storage paths Diagnostics prints, the Apple Intelligence readiness sentence the Refinement pane appends, the recording overlay's otherwise-random comet head, and the legacy glass path. The Refinement pane's probe verdict is per fixture rather than process-wide, so `make` installs it and `pinProcessSeams()` clears it. Foundation formatters and SwiftUI environment values resolve these overrides before the machine's real values. Optional production overrides stay `nil` and production reads use `override ?? <the real value>`; `forceLegacyGlass` defaults false. `textRoleRecorder` is installed and restored only around a hosted harness scene and otherwise remains nil, so shipping behaviour is unchanged.

Beyond that, never let a scene derive anything from `Date()`, `UUID()`, `.random`, the Keychain, TCC, or `NSColor.controlAccentColor` (it resolves to the *user's* system accent and no environment key overrides it — SwiftUI's `Color.accentColor` is safe). Avoid states dominated by `.repeatForever` or `TimelineView(.animation)`: in this app that is `FrostedCometIndicator`, whose orbit phase is wall-clock driven, which is why no scene renders a processing overlay. Settling itself is a fixed pump budget, identical every run, never adaptive.

### Steps

`UIStep` is deliberately tiny, and `--list` renders each step as a short string:

| step | list form | behaviour |
| --- | --- | --- |
| `.press(target)` | `press:<target>` | accessibility press on the first node matching `target`. The default click path. |
| `.click(target)` | `click:<target>` | synthetic mouse click at the centre of the matching node's frame. The escape hatch. |
| `.type(text, into: target)` | `type:<target>:<text>` | focus the matching node and type into the field editor. |
| `.settle(ms)` | `settle:<ms>` | pump the run loop for a fixed number of milliseconds. |

`target` is resolved by `AXDump.find` in a fixed precedence: exact identifier, exact label, label substring, exact placeholder, placeholder substring — first match in document order. Placeholders matter more than they sound: SwiftUI text fields publish no label and no title at all, so `AXPlaceholderValue` is the *only* text on the element and the only way to address one.

A step that cannot find its target does not abort the scene; it records a warning in the manifest's `warnings[]` and the run continues. Two scenes are scripted today, both tagged `steps`: `console.sessions.search` types `accessibility` into `Search transcripts or timestamps`, filtering the list from ten rows to two, and `console.diagnostics.confirm` presses `CLEAR HISTORY` to reach the danger-zone confirm state. Both settle 120 ms afterwards.

## Flows

A scene answers whether one state still renders, reads and lints correctly. A `UIFlow` answers whether a real journey still works. It hosts a real app view with an inert `UIFlowFixture`, drives the real `DictationCoordinator` through an ordered script, and checks named semantic expectations at each checkpoint. Its stable id is the artifact basename; its title, tags and `covers` keys make the journey discoverable and connect it to the coverage ledger.

The current catalog has 20 flows — 18 portable and two tagged `os26` — in `UIFlowCatalog.everything()` execution order:

- Home: `home.empty-to-populated`
- Sessions: `sessions.search.no-results`, `sessions.search.clear`
- Voice: `voice.toggle-cleanup`, `voice.auto-stop-dependency`
- Glossary: `glossary.add-term`, `glossary.remove-term`
- Refinement: `refinement.enable-and-check`
- System: `system.recheck-backend`, `system.clear-history.confirm`
- Menu and dictation: `menu.copy-transcript`, `dictation.paste.delivered`, `dictation.copy-only.terminal`, `dictation.refinement-skipped.code-editor`, `dictation.cancelled`, `dictation.asr-error`
- Overlay: `overlay.recording.controls`
- Atoms: `atoms.confirm-row`
- Native macOS 26: `console.rail.navigation.os26`, `menu.primary-action.os26`

The script vocabulary is closed:

| step | meaning |
| --- | --- |
| `act` | perform one action: accessibility press, synthetic click, text entry, direct coordinator dictation action, or console navigation |
| `release` | release one named asynchronous gate |
| `wait` | pump toward a state, present element or absent element, or settle for a fixed number of run-loop turns |
| `check` | evaluate every expectation at a named checkpoint; one failure does not short-circuit the remaining checks |
| `capture` | write and lint a named raster and accessibility frame, with optional golden reconciliation |

The expectation vocabulary is also closed: `exists`, `absent`, `count`, `enabled`, `selected`, `value`, `label`, `role`, visible `text`, coordinator `state`, ordered `transitions`, a closed `model` probe, `warnings`, and `lintClean`. Count rules are `exactly`, `atLeast`, `atMost` and `between`; text rules are equality, containment, prefix, suffix, empty and non-empty. Transition checks can require an exact sequence, a contiguous run, or an ordered subsequence.

State expectations match the coordinator case, not associated payloads: `idle`, `checkingPermissions`, `recording`, `finalizingAudio`, `transcribing`, `cleaning`, `refining`, `readyToInsert`, `pasteAttempted`, `copiedOnly`, `insertFailed`, `error`, or `cancelled`. Model probes are limited to `transcript`, `outcome`, `errorMessage`, `targetLabel`, `recentSessionCount`, `glossaryTermCount`, `refinementEnabled`, `cleanupEnabled`, `activeBackend`, `processingInFlight`, `deliveredText`, `deliveryBundleID`, `deliveryDisposition`, and `deliveryCount`. The closed sets keep journal rendering exhaustive and stable.

Flow selectors return the complete match set. Identifier, label, value, placeholder and role queries are exact; `labelContains` and `valueContains` are explicit exceptions for genuinely dynamic text, not fallback matching, and `all` requires every child query to match the same node. Any action or expectation that requires one node fails on zero matches or on ambiguity. A substring that silently retargets after a UI change is the bug a flow exists to catch, so flows never use the scene stepper's first-match fuzzy precedence.

No flow wait has a wall-clock deadline. The runner pumps one run-loop turn at a time, up to a fixed budget of 3,000 turns, and reports `not observed within 3000 turns` rather than elapsed milliseconds. Loaded and idle machines therefore make the same decision. Each asynchronous boundary is a named `UIGate` — `permission`, `recorderStop`, `transcription`, `refinement`, `insertion`, or `persistence` — and the script releases it explicitly. Without those gates, the pipeline could cross an intermediate state inside one settle and make the checkpoint a race.

### Production value seams

The flow layer added two production seams. Both are value seams: the harness supplies deterministic closures at an existing boundary while shipping code follows the same control flow. Production code must not gain a harness-only branch.

- `DictationRuntime` supplies `now`, `makeUUID` and `sleep`. `DictationCoordinator` accepts an optional runtime and stores `runtimeOverride ?? .live`; `.live` still calls `Date()`, `UUID()` and `Task.sleep`.
- `GeneralPasteboard.writeOverride` and `clearOverride` are nil in every shipping build. `UIFlowContext` installs closures that record writes and return a synthetic change count. This is necessary because the menu transcript copy, Sessions transcript copy and `PropertyRow` value copy write directly to the general pasteboard rather than through the insertion adapter; pressing one in a flow must not replace or clear the user's real clipboard.

`UIScriptClock` pins `now` by default with `step: 0` and generates UUIDs in a stable sequence. Exactly one fixture, `backendRecovery()`, uses a six-second step. `DictationCoordinator.refreshBackendHealth` suppresses probes within a five-second TTL measured against `runtime.now()`, so a frozen clock would make the System pane's automatic probe swallow the later RE-CHECK. A `#if UI_HARNESS` early return inside that shipping method was tried and rejected; stepping one fixture's value source preserves production control flow.

`UIScriptClock.sleep` deliberately forwards to `Task.sleep`. Replacing it with `Task.yield()` made `RecordingSessionDriver`'s 40 ms metering loop a hot loop that never suspended, starved layout and moved a committed golden by 59 pt. A fake that never suspends is a spin lock, not a clock.

### Flow journal and artifacts

Every executed flow writes `.build/ui-harness/flows/<flow-id>.flow.txt`, even when the journal matches. The committed counterpart is `fixtures/ui/flows/<flow-id>.flow.txt`; a unified `.flow.diff` exists only while they differ. A failing flow is never blessable. Each `.capture` writes `<flow-id>.<frame>.png` and `<flow-id>.<frame>.ax.txt`; frame dump diffs and raster digests follow the same lifecycle as scene artifacts.

Capture steps are optional. `dictation.paste.delivered` deliberately captures no frames: a frame at `.recording` measured 59 pt wide on one run and 58 pt on the next because the menu's LIVE chip breathes on a wall-clock-driven `.repeatForever` animation. Its 20 semantic expectations carry the journey instead. A flow must not capture a frame in a state dominated by a perpetual animation, just as the scene catalog refuses to snapshot the processing overlay's wall-clock-driven comet.

The journal is line-oriented, LF-only, and ends in one newline:

```text
flow: <id>
title: <title>
fixture: <fixture name>
transitions: idle -> checkingPermissions -> recording
PASS 1 <checkpoint> | <expectation> | <observed>
FAIL 2 <checkpoint> | <expectation> | <observed>
      selector: <exact selector>
      candidate: <nearby addressable node>
frame: <name> nodes=<count>
warnings: <warning>
```

Expectation lines remain in script order. A failed selector adds its selector and sorted, capped candidate lines; frame lines record only the structural node count. Warning lines come last. The journal deliberately excludes dates, durations, PIDs, hostnames, absolute paths, UUIDs and frame reconciliation status, so the semantic golden is byte-identical across machines. `--no-frames` uses that host-independent journal as the required gate while still writing and linting frame artifacts; it skips only frame golden comparison because rasters and AX frame geometry can vary with host font rasterisation and display scale.

At `--scale 2`, flow frame artifacts and goldens use the same `<flow-id>.<frame>@2x.*` family as scenes; journals and the flow manifest keep their fixed names.

`flow-check` and `flow-update` write `.build/ui-harness/flows/manifest.jsonl` as sorted-key NDJSON. Nullable keys are present as `null`, never omitted, and no row carries a date, duration, PID, hostname, absolute path or UUID. Row order is one run row, then each flow with its expectations and captured frames in script order, then coverage rows sorted by key:

| `type` | contents |
| --- | --- |
| `ui_flow_run` | mode and filters; `flows` plus mutually exclusive `ok`, `failed`, `changed`, `missing_golden`, and `written` buckets; expectation/finding tallies; `coverage_declared` plus the six coverage-status buckets; `undeclared_coverage_keys` as a sorted string array |
| `ui_flow` | id, title, tags, coverage claims, status, checkpoint/expectation/transition/frame counts, warnings and error |
| `ui_expectation` | flow id, checkpoint, ordinal, pass/fail status, expected and observed text, selector and candidates |
| `ui_flow_frame` | flow/frame ids, pixel and AX status, raster digests, AX node count and lint findings |
| `ui_coverage` | key, kind, surface, title, status, disposition, claimants, limitation and declaration problem |

`--flow-list` prints one sorted-key `ui_flow_catalog` JSON object containing each flow's id, title, tags, coverage keys, checkpoint count and expectation count. It does not host a window.

## Film reels

A reel is one media clip: an id, a title, a logical size, a forced colour scheme, a per-frame
delay, and a stage — the real hosted view plus a script that mutates the real observable model
the view watches. The types are `UIFilmReel`, `UIFilmStage` and `UIFilmRecorder` in
`Sources/VoiceOour/UIHarness/UIFilmCatalog.swift`, and the catalog is `UIFilmCatalog`.

**Reels are media, and they are deliberately outside every gate.** Nothing diffs a frame,
digests it, lints it, or declares coverage for it, and no `make` gate runs `film`. That is not
an oversight: the reel's whole subject is the animation a golden may never contain. The
processing states draw `FrostedCometIndicator`, a `TimelineView(.animation)` whose orbit phase
comes from the wall clock, which is exactly why no *scene* renders a processing overlay. A reel
wants that motion, so it gives up reproducibility to get it, and pays nothing for the trade
because no committed artifact depends on the bytes.

Frames land in `.build/ui-harness/film/<reel-id>/` as `frame-0000.png`, `frame-0001.png`, …
beside a `reel.json` carrying `id`, `title`, `frame_count`, `frame_milliseconds`, pixel `width`
and `height`, and `scale`. The directory is recreated from empty on every run: a reel that got
shorter would otherwise leave the previous run's trailing frames behind, and ffmpeg's
`frame-%04d.png` pattern would splice those orphans onto the end of the GIF.

```sh
make ui-film                                    # frames, then the committed GIF
scripts/make_readme_gif.sh --width 480          # the same frames at another width
scripts/ui_harness.sh --mode film --scale 2     # frames only, no ffmpeg
```

`scripts/make_readme_gif.sh` runs the harness at `--scale 2`, reads `frame_milliseconds` out of
`reel.json` to derive the frame rate, and assembles `docs/media/<reel-id>.gif` with a two-pass
ffmpeg palette (`palettegen stats_mode=diff` then `paletteuse dither=bayer`). It needs `ffmpeg`
and `ffprobe` on `PATH` and nothing else — no jq. The committed GIF is reviewed as media: a
diff on it means someone re-recorded it, not that a gate moved.

The one reel today is `dictation-island`, 400x120 pt dark, 60 ms per frame, 99 frames — about
5.9 s. It hosts the real `RecordingOverlayView` on a flat `Ink.void` backdrop (flat, not a
gradient: a GIF holds 256 colours and a gradient bands) and drives the real
`RecordingOverlayModel` through the real `SessionState` sequence one dictation walks:

| phase | state | frames |
| --- | --- | --- |
| warm-up | `.recording`, capture not yet live | 5 |
| live speech | `.recording`, one meter sample per frame | 44 |
| finalizing | `.finalizingAudio` | 7 |
| transcribing | `.transcribing` | 12 |
| cleaning | `.cleaning` | 7 |
| refining | `.refining` | 14 |
| ready | `.readyToInsert` | 10 |

The 44 meter levels are **one synthetic utterance envelope, not recorded audio**: a committed
`[Float]` literal indexed by frame, with no `Date()` and no `.random`, shaped like a spoken
sentence — attack, syllable dips, a breath, an emphasised run, a decay. No microphone is opened
and no audio file exists.

Be honest about what the GIF shows. `cacheDisplay` drops `.blur(radius:)` and `.shadow(...)`,
and an offscreen window has no desktop for the island's glass to sample, so the pill reads
flatter in the GIF than it does on a real display: the recorded capsule is the painted fallback
surface without its shadow bleed or backdrop refraction. Every control, glyph, label and
waveform bar is the real thing at the real measure; the material around them is not.

## Coverage ledger

`UICoverageRegistry` declares every UI surface, state and journey independently of the scenes and flows that may verify it. The current registry contains 182 requirements: 109 required, 63 snapshot-only and 10 not-verifiable. The three dispositions mean:

- `required`: a passing flow must claim the key;
- `snapshotOnly(sceneID:)`: static evidence is sufficient, and the named scene must exist in `UISceneCatalog`;
- `notVerifiable(limitation)`: the offscreen path measurably cannot verify the requirement, and the reason must come from the closed `UIKnownLimitation` vocabulary.

The coverage baseline makes that ledger an enforceable ratchet without pretending every gap is already closed. `fixtures/ui/coverage-baseline.txt` contains the required keys that are currently unclaimed; it currently contains 76 keys. The gate enforces both directions:

- **Regression:** a required key is uncovered now but absent from the baseline. A surface was added without coverage or a passing claimant was lost, so the run fails.
- **Stale entry:** a baseline key is covered now. The run fails until the entry is removed, so a closed gap cannot remain as permission to uncover the key later.

Only passing flows contribute claims. A red flow covers nothing; otherwise the broken journey would bless the exact gap it exposed. Broken snapshot declarations and flow claims for undeclared keys also fail.

A filtered `--only` run cannot judge the rest of the catalog. Keys it did not evaluate are deferred, regressions are enforced only over evaluated keys, and baseline entries are never pruned. For the same reason, `--flow-update --only …` refuses to rewrite `coverage-baseline.txt`; run an unfiltered `make ui-flow-update` when a baseline change is intended.

Review every `coverage-baseline.txt` diff as coverage, not fixture churn. A removed line is a gap closed by a passing flow. An added line means coverage was dropped or a new required gap was introduced and needs explicit justification; the committed ratchet is expected to shrink, not grow.

`make ui-coverage` evaluates declarations, claims and the baseline without hosting a view. `make ui-flow` is the host-independent semantic gate, `make ui-flow-frames` adds host-sensitive frame reconciliation, and `make ui-all` runs the portable scene gate followed by the full flow-frame gate.

## Lint rules

Every rule is evaluated per scene against the accessibility tree, the capture, or both. An `error` fails the run in **both** `check` and `update` mode, and in `update` mode it also blocks the write, so a blank or placeholder render can never be blessed into a golden. A `warning` is recorded and never fails.

| rule | severity | regression it catches |
| --- | --- | --- |
| `blank-render` | error | the scene rasterised as an almost-flat fill (>=99.5% one colour): the view built but nothing painted. Blessing it would freeze the bug into a golden that then asserts nothing. |
| `unsupported-view` | error | more than 0.1% of pixels are SwiftUI's `#FFCC00` placeholder: an AppKit-backed view (`NSViewRepresentable`, `ProgressView`, `FrostedGlassBackground`) silently failed to rasterise. |
| `empty-tree` | error | fewer than 2 accessibility nodes: `setAccessibilityEnhancedUserInterface:` did not take, so nothing is addressable and every interaction step silently no-ops. |
| `text-contrast` | error | a readable `AXStaticText`'s harness-recorded foreground and its resolved paint stack fall below WCAG AA: 4.5:1 for normal text, or 3:1 at 18 pt regular / 14 pt bold. Each surface installs the same opaque or translucent colour it fills beneath its content; the recorder composites those `surfaceGround` layers in paint order, then joins an explicitly recorded text sample to an AX node only when their frames overlap by >=50% of the smaller frame. Unmeasurable or unmatched samples are unknown data and stay silent. |
| `out-of-bounds` | error | a node frame leaves the scene rect by more than 0.5 pt: content pushed outside the window is cropped away and unreachable while the screenshot merely looks tight. Nodes with an `AXScrollArea` ancestor are exempt — scrolled content below the fold is the mechanism, not a defect. |
| `clipped-child` | warning | a node frame escapes its parent's frame by more than 0.5 pt: truncation or overflow, e.g. a label wider than its container or a row taller than its list. Children of a scroll viewport are exempt for the same reason: the viewport publishes its clip rect while its children publish document positions. |
| `tiny-hit-target` | warning | an interactive node is under 484 sq pt (the 22x22 `RowIconButton` footprint in `GlassMarks.swift`, our own smallest deliberate affordance) or thinner than 8 pt on either edge: an icon shrank, or `.frame` landed on the label instead of the button. Tested by area, not per-edge, because a full-width 528x18 `GlassToggleStyle` row is twenty times easier to hit than the reference. |
| `unlabeled-control` | error | an interactive node with a real frame has no label, value, placeholder, identifier or help: unannounced to VoiceOver, and unaddressable by `AXDump.find`, so no step can exercise it. |
| `overlapping-controls` | warning | two unrelated interactive nodes intersect over more than 25% of the smaller frame: a `ZStack` ordering mistake, or an overlay missing `.allowsHitTesting(false)`. One swallows the other's clicks. Capped at 20 findings per scene. |
| `duplicate-identifier` | warning | two or more nodes share both an identifier **and** a label, so `find()` cannot tell them apart and `press("x")` can silently retarget. The label must collide too: SwiftUI auto-stamps `Image(systemName:)` names as identifiers, so eight `xmark` remove buttons on one pane are normal and each stays addressable by its own label. |
| `control-height` | warning | an interactive node's height is outside the `Control` scale (24 / 28 / 32 / 40) and row scale (32 / 40 / 44 / 64). It uses the same interactive subject set and synthesised-scroller exclusion as the other control rules. It deliberately does not check noninteractive chips or marks: their dimensions are not hit-target heights. |
| `off-grid` | warning | a bounded internal `AXScrollArea` width — an accessibility-visible column dimension such as a Sessions column — is at least 4 pt and more than 0.01 pt off the 4 pt grid. One finding is emitted per viewport, capped at 20 per scene. |

`text-contrast` is deliberately a readable-text rule, not a palette audit. `.roleStyle(_:)` records text as it applies its role; shared components that must preserve an already-spelled-out font, tracking or foreground add the probe with `.recordTextRole(_:foreground:)`. Both paths record the effective foreground, role, point size, weight class and window-local frame. Opaque content, well and console fills mask inherited `surfaceGround` layers; translucent plate, chip, keycap and button fills append to them, so both colours are resolved to opaque sRGB only after the real paint stack is known. A sample is checked only when its measurable frame overlaps a readable `AXStaticText` by at least 50% of the smaller frame. The rule does not check a token use with no measurable frame, no such AX match or no explicit sample. Canvas text takes the concrete-`Text` styling path and is not sampled because Canvas publishes one accessibility controller rather than readable child text. Decorative text-role marks such as the empty glyph are accessibility-hidden and therefore fail the AX join by design. The recorder is installed immediately before a scene is hosted, its latest mounted-view samples are handed to `UILint.evaluate`, and the prior process-wide value is restored afterwards; production leaves the seam nil and installs no geometry probe.

`off-grid` has a closed exemption list because AX geometry cannot reveal which arithmetic produced a frame. It deliberately does **not** test: (E1) roles outside `AXScrollArea`, including intrinsic text/image extents and paint-only cards or tiles that publish no AX bounds; (E2) AppKit's synthesised scroller parts; (E3) values below 4 pt; (E4) interactive widths, which hug font-derived labels; (E5) interactive heights, which `control-height` owns; (E6) missing, zero or non-finite frames; (E7) any origin, because origins accumulate intrinsic type metrics as well as token spacing; or (E8) scroll heights and outer viewport widths that fill the window remainder. E7 is load-bearing: the console viewport at y=150 and rail controls at y=97 / 133 / 169 / 205 / 241 / 277 are downstream of text metrics, not six designer-authored off-grid constants. E8 recognises the outer viewport as a frame wider than half the scene that terminates at the shell's 24 pt trailing inset. Fixed interactive heights remain enforced by `control-height`; fixed internal scroll widths remain enforced by `off-grid`. Card and tile sizes that SwiftUI does not expose as accessibility nodes remain golden-diff coverage rather than pretending the lint observed data it does not have.

All four rules whose subjects include interactive nodes skip AppKit's synthesised `NSScroller` parts (subroles `AXIncrementArrow`, `AXDecrementArrow`, `AXIncrementPage`, `AXDecrementPage`). They are 0x0-to-6pt, permanently disabled, invisible at rest, and unlabelable from SwiftUI; counting them as app controls produced 45 findings against stock `ScrollView`s and none against real UI.

A node that overflows the scene *and* whose parent is the hosting root emits both `out-of-bounds` and `clipped-child`; the two messages name different containers, so both are correct.

Findings arrive pre-sorted by severity, rule, path, frame origin and message, and the harness preserves that order. The order is part of the determinism guarantee — do not re-sort it downstream.

## Reading the manifest

`manifest.jsonl` is newline-delimited JSON with sorted keys and an explicit `type` discriminator, matching the conventions of `voiceoour-bench` and `voiceoour-capture-bench`. The first line is the run, every following line is one scene, in catalog order.
The sample below is illustrative; exact scene counts depend on the catalog and `--only` / `--except` selection.

```jsonc
// line 1
{"type":"ui_run","mode":"check","only":[],"scale":1,"scenes":18,
 "ok":16,"changed":1,"missing_golden":1,"written":0,"failed":0,
 "error_findings":0,"warning_findings":3,
 "started_at":"2026-07-26T14:20:34Z","duration_ms":2417,
 "output_dir":"/…/.build/ui-harness","golden_dir":"/…/fixtures/ui",
 "contact_sheet":"/…/.build/ui-harness/contact-sheet.png"}

// lines 2..n
{"type":"ui_scene","id":"console.home","title":"Home pane, idle",
 "tags":["console"],"width":1164,"height":820,"scale":1,
 "status":"changed","pixel_status":"changed","ax_status":"ok",
 "png_sha256":"…","golden_png_sha256":"…","ax_node_count":137,
 "duration_ms":214,
 "findings":[{"frame":{"height":18,"width":140,"x":24,"y":72},
              "message":"…","path":"AXGroup/AXScrollArea/AXButton",
              "rule":"tiny-hit-target","severity":"warning"}],
 "warnings":[],"error":null}
```

Field notes:

- `status` is the scene verdict. It is `failed` when `error` is non-null, otherwise the first non-`ok` of `pixel_status` and `ax_status`, otherwise `ok`.
- The five statuses are `ok`, `changed`, `missing-golden`, `written` and `failed`. In JSON `missing-golden` is hyphenated, matching the human summary.
- `written` appears only in `--update`, and only for goldens that actually moved. An `--update` run over an unchanged scene reports `ok` and leaves the file's mtime alone, so `--update` names exactly which goldens changed and leaves the rest clean in git.
- `golden_png_sha256` is the digest of the golden **as it was read**, so on a `changed` scene it is the old digest and `png_sha256` is the new one. Both are `null` when there is no golden or no capture.
- `error` is a per-scene failure message. A scene that throws is recorded and the run continues; one broken scene never aborts the others.
- Frame components are rounded to one decimal and negative zero is normalised, so they agree byte-for-byte with the numbers the lint messages print.
- Nullable keys are always present as `null`, never omitted.

The human summary on stdout is one line per non-`ok` scene plus a tally, all prefixed `ui-harness:` so it greps cleanly:

```
ui-harness: changed console.home pixel=changed ax=ok
ui-harness: missing-golden console.glossary.empty pixel=missing-golden ax=missing-golden
ui-harness: 18 scenes, 16 ok, 1 changed, 1 missing-golden
ui-harness: artifacts /…/.build/ui-harness
```

Error-severity findings and harness errors go to stderr with the same prefix. With `--stdout` the manifest takes stdout and every prose line moves to stderr.

`--list` prints exactly one JSON object:

```json
{"type":"ui_catalog","scenes":[{"color_scheme":"dark","height":820,"id":"console.home","steps":["settle:120"],"tags":["console"],"title":"Home pane, idle","width":1164}]}
```

## For agents

Inspect a static UI change in four commands:

```sh
scripts/ui_harness.sh --only <area>          # 1. render + check the scenes you touched
open .build/ui-harness/contact-sheet.png     # 2. inspect every selected scene, captioned by id
cat .build/ui-harness/<scene-id>.ax.diff     # 3. read the semantic change before the pixels
scripts/ui_harness.sh --update --only <area> # 4. bless the intended scene change
```

Inspect an interactive change through its flow:

```sh
make ui-flow-list
scripts/ui_harness.sh --mode flow-check --only <journey> --no-frames
cat .build/ui-harness/flows/<flow-id>.flow.diff
scripts/ui_harness.sh --mode flow-update --only <journey> --except os26
make ui-flow
make ui-coverage
```

Read the journal diff before any frame pixels. It states the named checkpoint, expectation and observed value, so a changed state transition or delivered string is reviewable without interpreting a screenshot. Use the named PNG and AX diff when the semantic journal is unchanged but a captured frame moved. A new static surface needs a scene and a coverage-registry requirement; new interactive behaviour needs a flow that claims the corresponding required key.

Never run scene or flow update mode without reading the relevant diff first. Update refuses to bless a red flow or an error-severity finding, but it can still bless a real regression outside the modeled rules. Use `--only` for the cheap iteration loop, then run the full portable `make ui-flow` and `make ui-coverage`: a filtered run cannot prove ledger completeness.

## Activation

Two guards keep the harness and the screenshot script out of your way.

The harness exits from the **first statement** of `VoiceOourApp.init()`, before the audio muter, the dictation coordinator, the recording overlay and the menu bar item exist. `UIHarnessRuntime.prepareProcess()` then pins the activation policy to `.prohibited`, which is the only policy measured to reliably not self-activate.

`ConsoleView.onAppear` normally promotes the app to `.regular` and calls `NSApp.activate`, because a user who opens the console expects a normal, Cmd-Tab-reachable window. That is exactly what would yank your screen when a scene hosts the real `ConsoleView`, so both `onAppear` and `onDisappear` are now skipped when the policy is already `.prohibited` (the harness) or when the process was launched with `--no-activate`. A normal user launch matches neither condition and behaves exactly as before.

`--no-activate` is a development flag alongside `--show-console` and `--console-section=`; `scripts/console_shot.sh` passes it to minimise its disruption. Be honest about what it buys there: the console window still has to be onscreen to be screenshotted, and the show-console notification handler in `MenuBarLabel` still calls `NSApp.activate`, so that script still takes focus briefly. What `--no-activate` removes is the promotion to `.regular` — a Dock icon and a Cmd-Tab entry appearing and disappearing — plus the second activate in `ConsoleView.onAppear`. The harness is the path with no disruption at all.

The claim is measured, not asserted. `lsappinfo front` captured immediately before and immediately after a full render/lint/diff/update cycle returns the identical ASN both times:

```
$ lsappinfo front            # before
ASN:0x0-0x28a88a6:
$ ... render, lint, diff, write goldens, compose the contact sheet ...
$ lsappinfo front            # after
ASN:0x0-0x28a88a6:
```

Re-measure it the same way if you ever change the hosting path: an ASN that moves means something ordered a window front or activated the app.

## Limitations

These are measured properties of offscreen rendering on this machine, not bugs to be worked around. Do not design a scene that depends on any of them.

A flow inherits every scene limitation and additionally cannot verify the contents of the real pasteboard, real CGEvent delivery, real TCC prompts, `NSOpenPanel`, list-row selection, key equivalents, or pointer hover. Its fixtures record the insertion effect the app requested without touching the user's clipboard or posting a real event. Claims about those real system effects require the live app, not a flow golden.

- **An `ax_status` of `ok` is not evidence that a scene is visible.** The dump is built from the view hierarchy, so a node reports correctly whether or not anything rasterised at its frame — accessibility can never gate a pixel defect. Worked example: on macOS 26 a glass nav selection sitting on the glass window ground lost a contiguous rail band from the render, while every button, label, value, and frame in the AX dump matched the correct legacy render byte for byte. The band was lost because `cacheDisplay` skipped the nested glass layer group, not because the material erased anything: the same view renders 7 of 7 rail rows in a real onscreen window. Every modern glass consumer still needs an `os26` scene, and reviewers still inspect its PNG beside the corresponding legacy PNG — for the native branch's own labels, glyphs, control boundaries, and control sizes. An `os26` PNG cannot show the material; use `scripts/console_shot.sh` when the material itself is the subject.
- **The menu harness does not reproduce `MenuBarExtra` host chrome.** `menu.*` scenes host `MenuView` in a generic borderless window. The `*.os26` variants gate the content and ensure it adds no nested custom glass, but only the real system popover supplies its outer material and dismissal behavior.
- **`cacheDisplay` does not rasterise SwiftUI `.glassEffect` at all.** The modern material is absent from the capture, not flattened: its area comes out fully transparent. Measured over the committed goldens, `overlay.island.recording.os26.png` is 0.0% opaque and 59.3% fully transparent and `console.voice.os26.png` is 37.6% fully transparent, against 100% opaque for the painted `console.home.populated.png`; every non-transparent pixel in an `os26` console golden is the app's own paint (`a=255`) or its own `GroundScrim.ink = Ink.void.opacity(0.88)` scrim (`a=224`). An `os26` scene therefore verifies the native branch's own painted content, geometry, control boundaries and accessibility tree, and never the material — `UIKnownLimitation.systemGlassMaterial` is the coverage vocabulary for the part it cannot reach. Deleting the `GlassEffectContainer` from a nested glass stack was measured to leave the PNG byte-identical, so a glass change can be invisible to this gate in both directions. `scripts/console_shot.sh` is the only way to see composited glass.
- **The transparent overlay panel additionally has no offscreen backdrop.** Over and above the missing material, `cacheDisplay` never asks WindowServer to composite a desktop behind the clear panel, so there is nothing for the island to refract even where it does paint. The `overlay.*.os26` scenes still gate the waveform and both painted control discs — including their glyphs, boundaries, sizes, and positions — but never the island's live backdrop refraction.
- **Legacy behind-window glass renders as a flat tint.** This is the `NSVisualEffectView` path only, not modern `.glassEffect`. `FrostedGlassBackground` in `Sources/VoiceOour/GlassSurfaces.swift` sets `blendingMode = .behindWindow`: the WindowServer composites it from the actual desktop behind a real onscreen window. There is no desktop behind an offscreen window, so it rasterises as a single opaque fill — measured as exactly one distinct colour over the sampled area. Placing an opaque window behind it does not help. This is also a determinism *win*: changing your wallpaper cannot perturb a golden. To see the composited effect you still need `scripts/console_shot.sh`.
- **`cacheDisplay` drops `.blur(radius:)` and `.shadow(...)`.** Those are Core Animation filters and are not composited by the capture path. A scene whose entire point is a blur or a drop shadow cannot be verified here.
- **`NSColor.controlAccentColor` is machine-dependent.** It resolves to the user's System Settings accent colour and no environment key overrides it. A golden containing the system accent will not port between machines. Use SwiftUI's `Color.accentColor`, which is machine-independent.
- **List row selection cannot be driven by a synthetic click.** `NSTableView` row selection requires the application to be active, and the harness is deliberately never active. Drive list selection through the model instead, or expose it as a separate scene with the selection already applied.
- **A plain SwiftUI `Button` leaves no `NSView` behind.** Only a zero-logic focus-ring view sits at its rect. `TextField`, `Toggle` and `List` do get real `NSView`s. Interaction steps therefore go through the accessibility layer by default, not the view hierarchy.
- **Command-key equivalents never fire.** `performKeyEquivalent:` is only consulted for the key window, and an offscreen window in an inactive app never becomes key.
- **`ConsoleView` hardcodes `.environment(\.colorScheme, .dark)`.** A light-mode scene routed through `ConsoleView` is a no-op, so every `console.*` scene is dark. Light variants have to host the pane directly, which is what the single `pane.home.light` scene does.
- **Diagnostics prints placeholder build metadata.** `Bundle.main.infoDictionary` is nil for the SwiftPM binary, so the goldens show APP VERSION `development` and BUILD `local`. Running the harness out of the built `.app` would print real values and change those goldens.
- **Every scene shares one process.** Scenes are rendered sequentially in a single app process, so a scene that mutates process-wide state (activation policy, `UserDefaults`, a singleton) can contaminate the scenes after it. Keep state inside the view.
- **`ImageRenderer` is not used and must not be.** It stubs every `NSViewRepresentable` and AppKit-backed control — including plain `ProgressView` — with an opaque `#FFCC00` rectangle. The harness renders through `NSHostingView` plus `cacheDisplay` for exactly this reason, and the `unsupported-view` lint rule exists to catch any placeholder that still slips through.
