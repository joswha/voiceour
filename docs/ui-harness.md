# Offscreen UI harness

The harness renders Voiceour's real SwiftUI views in process, dumps the accessibility hierarchy, lints both semantic and raster output, and compares them with committed goldens. It gives agents a reviewable UI signal without showing a window, changing the frontmost app, or requiring Screen Recording or Accessibility permission.

The harness is compiled only with `-DUI_HARNESS`. Normal and release builds do not link its catalogs, runner, fixtures, or reports. `RenderOverrides` remains production-compiled because the real views read those optional values; every value is nil or false in a normal launch.

## Commands

| command | purpose |
| --- | --- |
| `make ui-snap` | Render portable scenes, excluding `os26`, and compare accessibility dumps plus PNG digests. |
| `make ui-snap-os26` | Render scenes tagged `os26` on a macOS 26 host. |
| `make ui-update` | Rewrite intended portable scene goldens. |
| `make ui-update-os26` | Rewrite intended `os26` scene goldens. |
| `make ui-list` | Print the scene catalog as JSON. |
| `make ui-flow` | Run portable semantic journeys and compare their journals. |
| `make ui-flow-os26` | Run native-branch journeys on macOS 26. |
| `make ui-flow-update` | Rewrite intended portable flow journals. |
| `make ui-flow-list` | Print the flow catalog as JSON. |
| `make ui-all` | Run portable scenes and flows, then the two `os26` legs when the host supports them. |
| `scripts/ui_harness.sh --only console` | Check a filtered scene or flow area while iterating. |

The wrapper builds the app with `-DUI_HARNESS` and forwards arguments to `Voiceour --ui-harness`.

### CLI

```text
Voiceour --ui-harness [--list | --update | --flow-list | --flow-check | --flow-update] [options]
```

| option | meaning |
| --- | --- |
| `--mode MODE` | `list`, `check`, `update`, `flow-list`, `flow-check`, or `flow-update`; default `check`. |
| `--list`, `--update` | Short forms for scene list and scene update. |
| `--flow-list`, `--flow-check`, `--flow-update` | Short forms for flow modes. |
| `--only a,b` | Include ids containing, or entries tagged, `a` or `b`. |
| `--except a,b` | Exclude matching ids/tags after inclusion filtering. |
| `--out DIR` | Artifact directory; default `.build/ui-harness`. |
| `--golden DIR` | Golden directory; default `fixtures/ui`. |
| `--repo-root DIR` | Root used to resolve the two defaults; `VOICEOUR_REPO_ROOT` is the environment equivalent. |
| `--scale 1|2` | Raster scale; default 1. |
| `--no-sheet` | Skip the scene contact sheet. |
| `--stdout` | Also emit the NDJSON manifest to stdout; prose moves to stderr. |

An unfiltered check/update excludes `os26` automatically. Explicit filters opt out of that default, but unsupported native scenes are skipped when other runnable matches remain.

Exit status is 0 for a clean check or a successful update, 1 for a changed/missing/failed artifact or error-severity lint result, and 2 for invalid harness arguments. A broken scene or flow is recorded and the remaining entries still run.

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
    <flow>.flow.diff              # present only while journal differs
    manifest.jsonl

fixtures/ui/
  <scene>.png.sha256
  <scene>.ax.txt
  flows/<flow>.flow.txt
```

The full PNG is an inspection artifact; the committed raster golden is its SHA-256 digest. This keeps binary churn out of history while detecting the same pixel change. At 2x the basename gains `@2x`, including the AX dump because display scale changes pixel snapping and geometry.

Update mode writes only payloads that changed and reports them as `written`; identical files remain untouched. A scene with an error-severity lint finding cannot be blessed. Read `.ax.diff` or `.flow.diff` before any update.

`manifest.jsonl` uses sorted-key NDJSON with one run row followed by catalog-order result rows. Scene statuses are `ok`, `changed`, `missing-golden`, `written`, and `failed`. Nullable fields are explicit `null`. The flow manifest records the same run/result shape around checkpoints and expectations.

### Committed documentation captures

`fixtures/ui/` holds digests; `docs/media/` holds the few full PNGs that public documentation displays. They are deterministic harness derivatives, never hand-edited and never a gate:

| file | source scene |
| --- | --- |
| `docs/media/dictation-island-still.png` | portable `overlay.island.recording` at 2×, centered pixel-for-pixel on a transparent 720×216 canvas |
| `docs/media/home-sample.png` | `console.home.readme` |
| `docs/media/history-sample.png` | `console.sessions.selection` |
| `docs/media/glossary-sample.png` | `console.glossary.populated` |

Regenerate the three console captures with `scripts/ui_harness.sh --only console.home.readme,console.sessions.selection,console.glossary.populated`, then copy their `.build/ui-harness/*.png` files over the `docs/media` counterparts. Build the island still from current code with:

```sh
scripts/ui_harness.sh --update --only overlay.island.recording --except os26 \
  --scale 2 --out .build/ui-harness/docs --golden .build/ui-harness/docs-golden
ffmpeg -y -loglevel error \
  -i .build/ui-harness/docs/overlay.island.recording@2x.png \
  -vf 'pad=720:216:(ow-iw)/2:(oh-ih)/2:color=black@0,format=rgba' \
  -frames:v 1 docs/media/dictation-island-still.png
```

`docs/media/app-icon.png` is `sips`-exported from `Resources/AppIcon.icns` at 256×256.

## Scene inventory

`UISceneCatalog` is organized around current product surfaces:

- the five native console tabs: Home, General, Glossary, History, and System, including empty, search, app-filtered, permission, acquisition, and confirmation states;
- the menu popover at rest, after an error, and with a transcript;
- the recording panel and island while recording or waiting for real microphone signal;
- accessibility adaptations for Reduce Transparency, Increase Contrast, and Differentiate Without Color;
- representative `os26` menu and overlay branches;
- one `docs`-tagged scene, `console.home.readme`: the same populated Home fixture at a 1,080-point measure, tall enough to hold the figures, five app rows, streaks, activity grid and legend in one unscrolled capture for public documentation.

Use `make ui-list` as the authoritative inventory. A scene is a deterministic id, title, size, color scheme, tags, optional accessibility adaptation, optional interaction steps, and a closure building the real view.

Scene rules:

1. Construct coordinators through `UIFixtures`, never `DictationCoordinator.live()`.
2. Derive no artifact value from the current date, random ids, random choices, the system accent, local privacy grants, home-directory paths, or the developer's locale/time zone.
3. Pin those values through existing `RenderOverrides` seams. A production read must stay `override ?? realValue`; never add a harness-only branch to shipping control flow.
4. Avoid perpetual animation in scenes. Fixed run-loop pumping makes an active animation intentionally time-dependent.
5. Add or update the closest existing scene for a new observable static state; do not create a second fixture convention.

`RenderOverrides` currently pins time, calendar/locale/time zone, permission answers, storage paths, the overlay comet, accessibility adaptations, the seeded transcript selection (`transcriptSelectionSurface`), History's opening selection (`historyStartsDeselected`, which renders the tab as a reader who closed the transcript sees it) and History's opening app filter (`historyInitialAppFilter`, which renders the tab narrowed to one destination), the installed-app catalog (`installedApps`), the portable glass branch, and text-role recording. Every field is inert in production.

`installedApps` replaces the catalog wholesale rather than augmenting it: a non-nil dictionary is the whole set of apps the render believes are installed, and an absent key means "not installed", which falls back to the letter monogram on Home and to the persisted snapshot name everywhere. Production reads it as nil, which is the live `InstalledAppCatalog` LaunchServices lookup. `UIFixtures.pinnedInstalledApps` pins exactly two apps, each locking a different state: Xcode carries the name the fixtures already persist, so its rows prove the icon path alone, while VSCode's pinned name is deliberately `Code` against a persisted `Visual Studio Code`, so its rows prove that the installed name wins. Home's app buckets — cmux, ChatGPT, Claude, Brave Browser, Safari and Ghostty — and the Slack and Terminal history rows are all deliberately absent from the pin even though the rendering Mac probably has some of them, so their rows lock the fallback. The pinned icons are flat rounded-rect fills drawn by a pure handler; a real `NSWorkspace` icon is a multi-representation image whose pixels belong to whichever app version this Mac installed.

## Semantic flows

A `UIFlow` hosts a real menu, overlay, or native console view with an inert fixture, then drives real controls and `DictationCoordinator` transitions through a deterministic script. Checkpoints assert named semantics and write a host-independent `.flow.txt` journal. The journal is the durable contract; flows do not own raster or AX goldens.

The core journeys are:

- successful normal-text delivery;
- terminal copy-only delivery;
- cancellation;
- an ASR failure;
- menu transcript copying;
- recording controls and microphone warmup;
- settings, System recovery actions, and Home's lifetime figures across the five tabs;
- Glossary: adding a term through the draft plate, opening a term in place and teaching it another spoken form, and pressing Remove Term without confirming it;
- History's search filter and its clearing, and the selected transcript opening inside its own day group with the line that names its gestures;
- History's raw fold: the open transcript's RAW row shut with its raw text absent from the tree, an accessibility press unfolding exactly that text, and a second press shutting it again.

History's two gestures have no flow of their own, and this is measured rather than an omission. Copying is a plain click on the transcript, and `NSTextView` refuses first mouse in an app that is not active, so a synthetic click reached nothing and the pasteboard seam recorded no write. Teaching is ⌘T or the text view's own context menu, and `-performKeyEquivalent:` is offered only to the key window, which the offscreen window can never become. `sessions.detail.in-place` therefore asserts exactly one transcript well plus the instruction line that states both gestures, the `console.sessions.selection` and `console.sessions.deselected` scenes lock the open and closed states of the tab, and the gestures themselves are verified in the real app.

History's app filter has no flow either, for the same measured reason: engaging it opens an `NSMenu` popup, and a window that can never order front cannot show one. `console.sessions.filtered` pins the filtered state instead — the engaged control, the `N of M sessions match` caption, the surviving rows and the open transcript naming its target — and the menu itself and the row's `Show Only <App>` command are verified in the real app. The Glossary's origin filter is the same control and is pinned the same way by `console.glossary.mixed`, which offers both facets.

`glossary.remove-term` stops at the confirmation rather than completing the removal: a `confirmationDialog` cannot be driven by a window that never becomes key, exactly as History's delete confirmation cannot. Stopping there still asserts the property that matters — one press of Remove Term deletes nothing — and the confirmed removal is verified in the real app.

Asynchronous boundaries are explicit named gates released by the script. Waits are bounded run-loop pump counts, never wall-clock deadlines. Artifact strings may not contain live dates, durations, UUIDs, process ids, or machine paths. Production seams are value seams supplied at existing boundaries; shipping behavior must follow the same path.

Read the journal diff first. It names checkpoint, expectation, observed value, selector, and pass/fail without asking a reviewer to infer behavior from pixels. A red flow cannot be blessed.

## Measured offscreen invariants

Every item below is load-bearing and measured:

- `UIHarnessRuntime.prepareProcess()` sets activation policy to `.prohibited` before hosting. It activated in **0/24** runs, versus **20/30** under `.accessory`; refusing key status alone was insufficient.
- The return value of `setActivationPolicy(.prohibited)` is false even when the policy is applied. It is intentionally ignored.
- `NSApplication.shared` must exist and `finishLaunching()` must run before a CoreGraphics window API, or the process aborts at `CGS_REQUIRE_INIT`.
- The borderless `OffscreenWindow` is parked at **(-30,000, -30,000)**. Its `constrainFrameRect(_:to:)` must return the requested rect without calling `super`: a probe at (-12,000, -12,000) was moved to (320, 480), visible for 2.4 seconds.
- The window cannot become key or main. It swallows all ordering except `.out`, including `orderFrontRegardless()`. `cacheDisplay` produced byte-identical output without ordering a window.
- `ConsoleWindowView.managesActivationPolicy` checks both the development suppression flag and the current `.prohibited` policy. The runtime reasserts `.prohibited` before and after hosting so console appearance/disappearance cannot promote the harness to `.regular` or demote it to `.accessory`.
- Enhanced accessibility is required: `NSHostingView` exposed **1 node before** `setAccessibilityEnhancedUserInterface:` and **23 after** in the probe.
- Settle is a fixed **150 iterations × 1 ms** before and after scene interaction; teardown is 30 iterations. A 1280×860 hierarchy completed layout in that budget. Pumping 200 ms while a perpetual animation ran produced **6/6 unique hashes**, so adaptive “until stable” settling is forbidden.
- Every pump runs one `RunLoop.run` slice and drains up to 64 posted events. Sleep or run-loop pumping alone did not deliver queued AppKit events.
- Capture uses `NSHostingView.cacheDisplay(in:to:)` into an owned interleaved RGBA8 `NSBitmapImageRep` with `.deviceRGB`. `bitmapImageRepForCachingDisplay` embedded a 3,149-byte display ICC profile plus cICP data; the hand-built bitmap carries no monitor profile.
- `ImageRenderer` is not a substitute: it rendered AppKit-backed controls and representables as opaque `#FFCC00` placeholders.
- Alpha is deliberate. It disables subpixel font smoothing, the largest measured source of raster drift.

## Why the harness cannot show glass

There are two distinct measured failures:

1. Legacy behind-window `NSVisualEffectView` has no desktop behind the offscreen window to sample, so it rasterizes as a flat opaque fill. This also prevents wallpaper-dependent goldens.
2. SwiftUI `.glassEffect` is not rasterized by `cacheDisplay` at all; its area is absent/transparent rather than flattened. A measured native island capture was 0.0% opaque and 59.3% fully transparent.

An `os26` scene therefore verifies app-owned paint, geometry, controls, and accessibility on the native branch, not system material. The console's ground follows the same rule from the other side: portable console scenes pin `forceLegacyGlass`, so they render `ConsoleGlassGround`'s opaque `windowBackgroundColor` branch and never construct the AppKit material; the `console.tab.navigation.os26` flow releases the pin and does construct `NSGlassEffectView` offscreen, where it asserts semantics rather than pixels. For a real WindowServer-composited material check run `CONSOLE_SHOT_COMPOSITED=1 scripts/console_shot.sh <tab>`, which captures the window's screen rectangle; the script's default window-id capture returns the window's own backing store, in which a behind-window material is a flat fill with no trace of what it samples.

`cacheDisplay` also drops Core Animation blur and shadow filters. Do not “fix” these limitations by weakening determinism or ordering the harness window.

## Lint rules

Error findings fail both check and update modes; warnings are reported but do not fail.

| rule | severity | contract |
| --- | --- | --- |
| `blank-render` | error | Reject an almost-flat raster that painted no meaningful UI. |
| `unsupported-view` | error | Reject meaningful `#FFCC00` placeholder area from an AppKit-backed render failure. |
| `empty-tree` | error | Require at least two accessibility nodes. |
| `text-contrast` | error | Check recorded readable text against its resolved paint stack at WCAG AA thresholds. |
| `out-of-bounds` | error | Reject reachable nodes outside the scene, excluding scroll-document content. |
| `unlabeled-control` | error | Require an addressable label/value/placeholder/id/help for interactive nodes. |
| `clipped-child` | warning | Report child geometry escaping its parent outside normal scrolling. |
| `tiny-hit-target` | warning | Report controls below the project's measured minimum hit area. |
| `overlapping-controls` | warning | Report substantial overlap between unrelated controls. |
| `duplicate-identifier` | warning | Report an identifier-and-label collision that makes interaction ambiguous. |
| `control-height` | warning | Report interactive heights outside the control and row scales. |
| `off-grid` | warning | Report bounded internal scroll-column dimensions off the 4 pt grid. |

AppKit's synthesized scroller parts are excluded from interactive-control rules: the measured stock scroll views produced 45 false findings from invisible, disabled, unlabelable parts. Findings remain sorted by severity, rule, path, frame origin, and message for deterministic output.

## Review workflow

```sh
scripts/ui_harness.sh --only <area>
open .build/ui-harness/contact-sheet.png
cat .build/ui-harness/<scene>.ax.diff
scripts/ui_harness.sh --update --only <area>

scripts/ui_harness.sh --mode flow-check --only <journey>
cat .build/ui-harness/flows/<flow>.flow.diff
scripts/ui_harness.sh --mode flow-update --only <journey> --except os26
make ui-flow
```

Never update before reading the relevant diff. After a filtered iteration, run the full applicable scene or flow command; filtering proves only the selected entries.
