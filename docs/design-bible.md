# VoiceOour Design Bible

> **Status: internal design reference.** A contributor-facing reference for UI work,
> reconciled against the code as of 2026-08-03. Not a product spec; where this
> document and the code disagree, the code wins.

Target: **SwiftUI macOS 14.0+**
Dependencies: **none**
Private APIs: **forbidden**

Owner boundary:

- `VoiceOour`: SwiftUI UI, design tokens, glass primitives, coordinator-facing UI state.
- `VoiceCore`: pure Foundation models/settings/stores. No AppKit, no CoreAudio, no visual code.
- `VoiceMac`: AppKit/CoreAudio side effects only: window seams where required, pasteboard/system services, system-audio mute implementation.

This document is the source of truth for the VoiceOour console, recording overlay, menu bar popover, and audio-mute UX. **Every value below is verified against the code that ships today** (last reconciled 2026-08-03, the property-ledger pass: §7.1, §12.3, §12.7–§12.9, §14, §16, §17, §18). Aspirational items that were specified but never shipped are tracked in §29 rather than presented as current behavior — a bible that quietly drifts from the codebase is worse than no bible.

---

## 1. Product Shape

VoiceOour is a local-first dictation instrument. The main window is not a macOS preferences sheet. It is a transparent-black console: glass, hairlines, tracked mono labels, stillness, one live cyan signal.

The recording overlay pill is the reference object. The console is the same object unfolded.

Hard rules:

1. Delete `TabView` from the main window.
2. Delete SwiftUI `Form` from settings surfaces.
3. Do not use opaque system backgrounds inside the console.
4. Do not use default macOS blue buttons.
5. Do not add scanlines, neon gradients, fake terminal noise, glow spam, or decorative icon chrome.
6. One accent at a time. Cyan means live / selected / focused / primary. It is rare.
7. Motion is restrained. The live dot is the only perpetual motion in the console. (The recording overlay's comet indicator is a documented exception — see §21.)
8. All UI must be implementable on macOS 14 with public SDK APIs only.
9. **Every pane sits on one shared grid.** A field, toggle, or picker never claims the full window width just because nothing stops it — see §12, the Manifest Grid.

---

## 2. Information Architecture

The main scene:

```swift
Window("VoiceOour", id: "main") {
    ConsoleView(coordinator: coordinator, initialSection: LaunchOptions.consoleSection)
}
.defaultSize(
    width: VoiceOourMetrics.Window.defaultWidth,
    height: VoiceOourMetrics.Window.defaultHeight
)
```

`VoiceOourApp.swift` also hosts a `MenuBarExtra` (§22) and owns the `RecordingOverlayController` (§21) — the console is one of three coordinated surfaces, not the whole app.

Opening the console promotes the app from `.accessory` — the idle menu-bar-only activation policy set once in `VoiceOourApp.init()` — to `.regular` for as long as the window stays open (`ConsoleView.swift`'s `.onAppear`/`.onDisappear`), then returns to `.accessory` when it closes. This keeps the real console reachable through Cmd+Tab and the Dock after focus moves to another app. `.accessory` remains correct for the `MenuBarExtra` popover (§22) and recording overlay (§21); only the console toggles activation policy.

Rail sections (`ConsoleSection`, `Sources/VoiceOour/ConsoleSection.swift`):

```swift
enum ConsoleSection: String, CaseIterable, Identifiable {
    case home
    case sessions
    case voice
    case glossary
    case refinement
    case system
    case diagnostics
}
```

Default landing: `home`. All seven ship; there is no reduced/phased subset, but Diagnostics is omitted from the rail unless the app launches with `--debug` or Diagnostics is already selected. `home` gets the same "pinned above a divider" rail treatment `sessions` used to have alone (§10.2); `LaunchOptions.consoleSection` (`LaunchOptions.swift`) and `ConsoleView`'s own `initialSection` default both fall back to `.home`. Rail labels are the plain-English case names (`Home`, `Sessions`, `Voice`, `Glossary`, `Refinement`, `System`, `Diagnostics`) — not the all-caps mono treatment used in eyebrows and chips.

Do not reintroduce tabs.

---

## 3. API / Platform Constraints

Deployment floor is `.macOS(.v14)`. Public macOS 26 Liquid Glass APIs are allowed only behind `if #available(macOS 26, *)` in a `@ViewBuilder`, with a complete legacy path and deterministic force-legacy harness branch.

Allowed:

- SwiftUI and public AppKit APIs.
- `NSVisualEffectView` on the legacy functional-glass path.
- Public Liquid Glass APIs on the guarded modern path.
- Public `NSWindow` configuration and CoreAudio HAL in `VoiceMac`.
- SF Symbols, SF Pro, and SF Mono.

Forbidden:

- private blur APIs or undocumented AppKit selectors;
- third-party UI libraries;
- `Form` or `TabView` for console navigation;
- default system blue as the app's primary grammar;
- arbitrary colors, font sizes, radii, spacing, or control metrics in view files;
- claiming that modern lensing, adaptive refraction, or morphing is reproduced on macOS 14/15.

The canonical vocabulary lives in:

```text
Sources/VoiceOour/DesignTokens.swift
Sources/VoiceOour/GlassKit.swift
Sources/VoiceOour/SettingsBindings.swift
Sources/VoiceOour/SettingsPaneScroll.swift
Sources/VoiceOour/ContentCard.swift
Sources/VoiceOour/SettingsSectionBlock.swift
Sources/VoiceOour/SettingsRow.swift
Sources/VoiceOour/CaptionText.swift
Sources/VoiceOour/SegmentControl.swift
```

`SettingsBindings.swift`, `SettingsPaneScroll.swift`, `ContentCard.swift`, `SettingsSectionBlock.swift`, `SettingsRow.swift`, `CaptionText.swift`, and `SegmentControl.swift` hold the persisted settings binding and the shared layout and surface primitives rather than raw tokens. View files compose these sources instead of creating a second convention.

---
## 4. Color Tokens

Verified against `Sources/VoiceOour/DesignTokens.swift`. All named text colors are opaque sRGB values; alpha belongs to materials and state fills, not to the text ladder.

### 4.1 Grounds and material colors

```swift
Ink.void    = sRGB(0.020, 0.030, 0.050, 1.00)  // opaque fallback ground
Ink.pane    = sRGB(0.060, 0.070, 0.090, 0.62)  // root glass tint stop only
Ink.rimDark = sRGB(0.000, 0.000, 0.000, 0.34)  // glass definition rim
Ink.surface = sRGB(0.055, 0.065, 0.085, 1.00)  // content surface
Ink.well    = sRGB(0.030, 0.036, 0.048, 1.00)  // recessed reading region
```

`Ink.surface` is the quiet, opaque plane under settings sections, ledger cards, Home cells, tables, and Sessions regions. `Ink.well` is the darker opaque plane under transcript and detail wells. Neither is glass.

The legacy glass tint remains a vertical gradient: white at 0.05 opacity at the top, `Ink.pane` at the 38% stop, and black at 0.28 opacity at the bottom. Its specular rim is white at 0.55 → 0.16 → 0.06 → 0.22 opacity, composited with `.plusLighter`.

### 4.2 Plates, lines, and meters

Plates are painted interaction regions, never independent glass:

```swift
Plate.rest    = white opacity 0.05
Plate.hover   = white opacity 0.09
Plate.pressed = white opacity 0.14
```

Line tokens have one job each:

```swift
Line.rule         = white opacity 0.13  // decorative rules and disabled rims
Line.edge         = white opacity 0.18  // content-surface definition
Line.control      = white opacity 0.35  // interactive boundary at rest
Line.controlHover = white opacity 0.48  // hover, press, and in-flight boundary
Line.focus        = Signal.cyan         // keyboard-focus boundary
```

`Line.rule` and `Line.edge` define structure; they are not interactive boundaries. Every enabled painted control has at least `Line.control` at rest. `Meter.rest` is white at 0.35 opacity and `Meter.accent` is `Signal.cyan`; chart rails, baselines, ordinary bars, and empty-day marks use the former.

### 4.3 Text and marks

```swift
Text.high       = sRGB(0.89, 0.91, 0.95, 1.00)
Text.mid        = sRGB(0.64, 0.71, 0.80, 1.00)
Text.low        = sRGB(0.51, 0.56, 0.64, 1.00)
Text.mono       = sRGB(0.64, 0.75, 0.86, 1.00)
Text.monoStrong = sRGB(0.84, 0.92, 0.98, 1.00)
Mark.faint      = sRGB(0.38, 0.42, 0.48, 1.00)
```

`Text.low` is the lowest legal text foreground and is also the disabled foreground. `Mark.faint` is not a text color: it is reserved for decorative empty-state glyphs, tick rules, the idle rail mark, and the disabled toggle knob. It never carries a label or caption.

At standard contrast, the weakest legal text pairing is `Text.low` over `Plate.hover` on `Ink.surface`, at 4.62:1. A plate fill above `Plate.rest` therefore uses `Text.high`; `Text.low` never sits on `Plate.pressed`. Under Increase Contrast the shared `A11y` resolver raises low → mid and mid → high.

### 4.4 Signal

One signal color per view:

```swift
Signal.cyan     = sRGB(0.62, 0.86, 1.00, 1.00)  // live, selected, focused, accent
Signal.cyanDeep = sRGB(0.32, 0.60, 0.92, 1.00)  // pressed accent fill
Signal.mint     = sRGB(0.66, 0.96, 0.82, 1.00)  // safe completion / ready / granted
Signal.amber    = sRGB(0.98, 0.78, 0.42, 1.00)  // permission / recovery / warning
Signal.crimson  = sRGB(0.98, 0.44, 0.44, 1.00)  // destructive / hard error
Signal.wash     = Signal.cyan opacity 0.45       // reduced decorative accent
```

Rules:

- Cyan is state, not decoration. `Signal.wash` is the only reduced cyan value used as a decorative accent.
- Mint is safe completion, saved, success, or granted acknowledgement.
- Amber is a permission gate, advisory, or recovery state.
- Crimson is destructive action or hard error.
- Color is never the sole state channel. With Differentiate Without Color enabled, selections gain bars or checkmarks, status marks gain symbols, live/idle marks become filled/hollow, and focus retains its outer halo. §20 and §25 record the complete behavior.

### 4.5 Audio-mute color

Audio mute uses the cyan/amber family; there is no separate mute palette. Muting is a system side effect, not an error, and never renders in crimson.

---
## 5. Material and Glass

### 5.1 Liquid Glass adoption

VoiceOour keeps its `.macOS(.v14)` deployment floor and has one dual-path architecture:

- On macOS 26, functional glass uses public SwiftUI Liquid Glass APIs behind `if #available(macOS 26.0, *)`: `.glassEffect` at the window ground and the recording-overlay island, the standard popover's own system chrome, and scroll-edge effects. The nav selection, segmented selection, overlay control discs, and menu primary action are painted on this path too. A second glass material on glass measurably erased the selected control's own content (see §5.3), so anything that sits on glass remains paint.
- On macOS 14 and 15, the same call sites use the public AppKit/painted implementation: `NSVisualEffectView` at the window or overlay ground, the shared tint and rims, and painted plates for controls. Controls that sit on glass are painted on macOS 26 as well.

`RenderOverrides.forceLegacyGlass` forces the legacy branch in committed harness scenes. This seam exists because `#available` follows the **runtime OS**, not the package deployment floor: a harness running on macOS 26 would otherwise silently render the modern path and make goldens depend on the host. Production leaves the seam false.

Both paths share geometry, tokens, content surfaces, and accessibility semantics. They differ only where the system can provide real lensing, morphing, or scroll-edge material.

### 5.2 Layer discipline

Only **ground** and **functional glass** are glass. Content surfaces, plates, wells, marks, and scrims are paint.

```text
ground  ─┬─ functional glass ─── plate | well | mark
         └─ content surface  ─── plate | well ─── mark
```

A glass element never sits on a second independently composited glass material. Each shipped functional surface owns its material independently; the console has no coordinating glass container or shared namespace, and controls above its ground are paint. This is a rendering-safety rule, not only a hierarchy preference: on macOS 26, a glass nav selection on the glass window ground erased the contiguous rail band above it, while its accessibility tree remained byte-identical to the correct painted render. Pixel inspection of an `os26` harness scene is therefore mandatory for every glass-path change; AX output alone cannot gate this defect class. A content surface never contains another content surface. A bounded nested reading region is a well; an interactive region is a plate. A segment group is the one two-level plate case: the group has a clear fill and owns only its boundary, while its segments derive their radius inside it.

### 5.3 Ground and functional glass

The console ground is functional glass. On the legacy path `GlassSurface` paints:

1. `FrostedGlassBackground` using `.hudWindow`, `.behindWindow`, and dark vibrancy.
2. `glassTint`.
3. The `specularRim` at `Stroke.specular`.
4. An inset `Ink.rimDark` definition rim.

The console window forces `NSAppearance(named: .vibrantDark)` and SwiftUI forces the dark color scheme. The legacy console root and recording overlay are the entire `NSVisualEffectView` budget; no content card creates another instance.

On the modern path the root uses system regular glass. Functional glass is otherwise restricted to the named scroll-edge treatments, the recording-overlay island, and the menu-bar popover's host material. The rail selection, overlay control discs, and menu primary action are painted overlays because each sits on glass; segmented selection is painted inside its content surface. Nothing else is glass.

The former interior-glass exception is resolved. Settings sections, ledger cards, Home dashboard cells, the Glossary table, and Sessions' TOTALS / SESSIONS / SESSION regions are `ContentCard` surfaces: opaque `Ink.surface`, one `Line.edge` rim, `Radius.card`, and no tint, specular rim, shadow, vibrancy, or offscreen compositing group.

### 5.4 Content surfaces, plates, wells, marks, and scrims

`ContentCard` is a quiet plane. Its default accessibility behavior leaves children independently addressable. A static read-only leaf may opt into a combined summary; a card containing a button, toggle, field, selectable text, or chart data does not combine its subtree. `interactive: true` belongs only to a card that is itself an affordance — a read-only ledger card does not claim the hover wash for facts nobody can press.

`PlateSurface` paints interaction states with a continuous rounded rectangle. Kinds are `.row`, `.hover`, `.selected`, `.input`, `.well`, and `.group`. A well always fills `Ink.well`; a group fills clear; other kinds resolve through the shared state ladder in §19. Painted bordered surfaces use `RoundedRectangle(...).strokeBorder(...)` on both OS paths.

Marks include `StatusChip`, `KeyCap`, status symbols, chart bars, rules, dots, and the static in-flight glyph. A mark increases no material depth and contains nothing.

The only scrims are the non-interactive titlebar taper and legacy scroll-edge fades. They always use `.allowsHitTesting(false)`.

### 5.5 Reduce Transparency

Reduce Transparency is automatic for system Liquid Glass and explicit on the legacy painted path. Legacy `GlassSurface` replaces frost, tint, and specular rim with opaque `Ink.frost` while retaining the definition rim. The legacy recording overlay and legacy menu popover use opaque `Ink.void` with `Line.edge`; that darker ground is correct for surfaces that host no content card, while the console needs the lighter frost ground to preserve separation from `Ink.surface`. Content surfaces, plates, wells, and marks need no branch because they are already paint over opaque grounds.

---
## 6. Shape, Stroke, Shadow

### 6.1 Concentric radii

```swift
Radius.window = 16
Radius.card   = 20
Radius.row    = 8
Radius.chip   = 6
Radius.keycap = 4

Radius.nested(outer, inset: padding) = max(outer - padding, 0)
```

The derivation closes exactly:

```text
20 card − 12 content padding = 8 row/well
 8 group −  4 segment inset  = 4 segment/keycap
```

A full-bleed child whose corners enter its parent's corner region derives its radius with `Radius.nested`. A free-standing field, chip, or button floating inside padding keeps its class radius. No nested shape invents an unrelated literal.

Painted descendant fills and borders use a continuous `RoundedRectangle`; bordered surfaces use `strokeBorder`, and inset corners derive their radius with `Radius.nested`. The modern root glass effect supplies its rounded-rectangle shape directly. The recording-overlay island and toggle track remain semantic capsules.

### 6.2 Stroke widths

```swift
Stroke.specular = 0.75
Stroke.hairline = 0.5
```

`Stroke.hairline(contrast)` resolves to 0.5pt standard / 1.0pt increased. `Stroke.selected(contrast)` resolves to 1.5pt standard / 2.0pt increased. `HairlineDivider` also clamps its thickness to at least one device pixel with `max(1 / displayScale, Stroke.hairline(contrast))`.

Focus and selection use the selected width. Focus is visually distinct: `Line.focus` plus a 2pt outer cyan halo at 0.25 opacity. Selection uses a cyan rim without that halo.

### 6.3 Control and row scale

```swift
Control.compactMark = 20  // StatusChip.compact only; a mark, not a control
Control.mini        = 24
Control.small       = 28
Control.medium      = 32
Control.large       = 40

Row.nav      = 32
Row.table    = 40
Row.settings = 44
Row.list     = 64
```

`Control.medium` is the default for buttons, fields, segments, nav rows, and real row-icon hit frames. Mini/Small/Medium controls use rounded rectangles in dense macOS layouts. `Control.large` is reserved for the single capsule primary action. Toggle geometry is 42×24 for the track, a 20pt knob with 18pt travel, and a 44×28 hit frame.

Every `Row.*` value is total pitch. Dividers are overlays and consume no layout height. Pixel alignment is a property of the complete row, overlay-divider, and display-scale calculation; the invariant is `origin × displayScale` integral.

### 6.4 Shadow

Only the recording-overlay island casts a shadow:

```swift
Shadow.overlayOuter = (black opacity 0.26, radius 18, y 6)
Shadow.overlayInner = (black opacity 0.18, radius 4,  y 1)
```

No content surface, plate, well, control, rail item, or console scaffold gets a shadow. If an interior component needs a shadow to read, repair its spacing, fill, or boundary instead.

---
## 7. Spacing and Measures

The spacing scale is a 4pt grid with a 2pt optical mark adjustment:

```swift
Space.hair     = 2
Space.xs       = 4
Space.sm       = 8
Space.md       = 12
Space.lg       = 16
Space.xl       = 24
Space.xxl      = 32
Space.section  = 40
Space.titlebar = 32
```

Ownership is fixed:

- `hair`: optical adjustment inside marks only.
- `xs`: intra-component gaps and the segment inset.
- `sm`: label/control gaps, row vertical padding, rail and popover inset.
- `md`: content-surface padding, grid gutter, control-to-caption gap.
- `lg`: gap between surfaces or blocks; nav icon slot.
- `xl`: pane horizontal padding, settings label/content gutter, header-to-first-surface gap.
- `xxl`: reserved step; no current owner.
- `section`: pane-region gap and final scroll inset.
- `titlebar`: native titlebar reservation only.

Control padding tokens remain:

```swift
Button.horizontal = 12
Chip.horizontal = 10
TextField.horizontal = 12
```

### 7.1 Content measures

```swift
Content.form  = 760   // Voice, Refinement, System, Diagnostics
Content.table = 940   // Glossary
Content.grid  = 1360  // Home, clamped to its region
```

A capped measure is **centered** in the pane region, not flushed to its leading edge: header and body each cap to the measure and then center that cap, so the two declare one left *and* one right edge at any window width (§11, §12.1). Sessions has no cap: its master-detail region is the measure and its header stays full width. Every other pane's header and content use the same measure. Do not add an intermediate width to hide a layout defect.

System and Diagnostics are read as sentences, not scanned as a matrix, so the property-ledger pass moved them from `Content.table` to `Content.form`; `ConsoleSection.headerMeasure` returns `.form` for them too, and their headers keep declaring the same left and right edge as their content. `Content.table` is the Glossary's alone, and `Window.minWidth` still keys off it (§7.2) because the Glossary is now the widest pane.

### 7.2 Columns, fields, and window

```swift
Column.rail              = 176
Column.settingsLabel     = 176
Column.glossaryCanonical = 176
Column.glossaryAliases   = 320
Column.glossaryPolicy    = 64
Column.glossaryScopeMin  = 140
Column.rowAction         = Control.medium  // 32

Field.short  = 120
Field.medium = 280

Window.minWidth      = Column.rail + 2 * Space.xl + Content.table  // 1164
Window.minHeight     = 560
Window.defaultWidth  = Window.minWidth  // 1164
Window.defaultHeight = 820
```

`Window.defaultWidth` **is** `Window.minWidth`, so the console opens at its tightest legal, geometrically fitted width. At 1164 the rail takes `Column.rail` 176 and leaves a region of **988**; the two `Space.xl` pane insets leave a padded content region of exactly **940**, so `Content.table` fits the Glossary edge to edge and `Content.form` 760 sits with **90pt symmetric gutters**. Widening the window grows both gutters evenly instead of opening one dead band beside a leading-flush column. `Window.defaultHeight` is 820 — a first-launch height, well above the 560 floor.

A purpose-sized field uses `Field.short` or `Field.medium`; free-form URLs, model identifiers, and keys remain flexible within their row slot. In the Glossary, SCOPE is the one flexible column and the 32pt action column stays fixed at the trailing edge.

---
## 8. Typography

Only SF Pro and SF Mono system fonts are used. `TextRole` is the canonical type vocabulary: it resolves font, tracking, and default foreground together so tracked labels cannot silently ship without their tracking.

| role | size | weight / design | tracking | default foreground |
|---|---:|---|---:|---|
| `heroMetric` | 64 | thin mono | 0 | `Text.high` |
| `metric` | 32 | light mono | 0 | `Text.high` |
| `tileValue` | 20 | medium mono | 0 | `Text.monoStrong` |
| `title` | 17 | semibold default | 0 | `Text.high` |
| `label` | 13 | medium default | 0 | `Text.high` |
| `body` | 13 | regular default | 0 | `Text.high` |
| `bodyMono` | 13 | regular mono | 0 | `Text.mono` |
| `caption` | 12 | regular default | 0 | `Text.low` |
| `eyebrow` | 11 | semibold mono | 1.4 | `Text.low` |
| `micro` | 10 | medium mono | 0.8 | `Text.low` |
| `emptyGlyph` | 48 | thin default | 0 | `Mark.faint` |

Use `.roleStyle(_:)` for SwiftUI views. Canvas labels use the matching `Text.roleStyle(_:)` overload so they stay on the same tokens.

Rules:

- Mono is for data, identifiers, timings, paths, and status, not prose.
- Eyebrows are uppercase tracked mono. Micro labels are uppercase unless a mixed-case datum requires tracking 0.
- `heroMetric` is the Home saved-time numeral role and carries exactly one figure on that pane; `metric` is the Sessions/Home numeric-strip role.
- `tileValue` is the Home RECORDS strip's face. A ledger pane never promotes a fact to it; prominence there is a `StatusChip` mode, not a bigger numeral.
- `emptyGlyph` is decorative and accessibility-hidden.
- A caption defaults to `Text.low`; its optional color override is reserved for semantic error or advisory foregrounds.

---
## 9. Window Shell

### 9.1 NSWindow configuration

`WindowChromeConfigurator` idempotently applies:

```swift
window.styleMask.insert(.fullSizeContentView)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = .clear
window.isOpaque = false
window.isMovableByWindowBackground = true
window.appearance = NSAppearance(named: .vibrantDark)
window.minSize = NSSize(width: Window.minWidth, height: Window.minHeight)
```

Default size is **1164×820** (`Window.defaultWidth` × `Window.defaultHeight`). Minimum is **1164×560**: `Column.rail` 176 + two `Space.xl` pane insets (48) + `Content.table` 940. Default width and minimum width are the same number by construction (§7.2) — the widest measure fits the region exactly at first launch. The rail separator is an overlay and consumes no width.

Do not hide or re-host the traffic lights. A titled window owns an opaque AppKit titlebar container. Dynamically dropping `.titled` after appearance was tried and reproducibly crashes in AppKit layout; it is not an ordering bug to retry. The scaffold reserves `Space.titlebar` and uses the non-interactive dark taper to make that native strip deliberate.

### 9.2 Root layout and render paths

`ConsoleScaffold` is `HStack { LeftRail; ConsoleContent }`. The rail's trailing `HairlineDivider` is an overlay, so content starts on the integral x origin instead of after a laid-out half-point divider.

The scaffold reserves the titlebar, applies the selected root material, overlays the titlebar taper, expands outside the safe area, and finally enforces `Window.minWidth` / `Window.minHeight`. Modifier order is load-bearing: safe-area expansion stays outside the glass surface.

`ConsoleScaffold` owns one root `GlassSurface`. On macOS 26, unless `RenderOverrides.forceLegacyGlass` is true, that modifier applies system regular glass; on macOS 14/15 and in committed harness scenes it applies the legacy material stack. No coordinating container or shared namespace participates. Neither path applies `backgroundExtensionEffect()`. The scaffold itself casts no shadow.

---
## 10. Left Rail and Status Cluster

### 10.1 Rail footer

The rail footer has two sibling accessibility groups:

1. Identity/status: the state mark, `VOICEOOUR`, `IDLE` / `WORKING` / `LIVE` / `ERROR`, and optional `AUDIO MUTED`, combined under one spoken label.
2. Capture hotkey: `KeyCap("Fn")`, the caption word `or`, and `KeyCap("Globe")`, labeled `"Capture hotkey"` with value `"Fn or Globe"`.

The status mark carries state by shape as well as color: idle is a hollow 6pt ring, working/live are filled 6pt dots, and error is `exclamationmark.triangle.fill`. Cyan is reserved for live; working uses `Text.mid`, error crimson, idle `Mark.faint`. Live pulses between scale 1.0 and 1.08 over 1.6s; Reduce Motion leaves it static.

### 10.2 Left rail

Width is `Column.rail` **176pt**. Navigation is inset by `Space.sm`, uses `Space.xs` between items, pins Home above one rule, and leaves the remaining six sections below it. A flexible spacer pushes the ruled footer to the bottom.

The rail is a region of the window ground, not another surface. Its only boundary is the trailing `Line.rule` divider overlay.

#### `RailItem`

Each item is `Row.nav` 32pt high. The 13pt icon occupies `Icon.navSlot` 16; the label uses the 13pt `label` role.

```text
rest:      no plate; icon Text.low, label Text.mid
hover:     Plate.hover + Line.controlHover
pressed:   Plate.pressed + Line.controlHover, scale 0.985
focused:   Line.focus at selected width + halo
selected:  Plate.hover + cyan rim on every supported OS path
```

Selection publishes `.isSelected`. Under Differentiate Without Color it also adds a 3×16pt leading bar and raises the label to semibold. The native focus ring stays suppressed; the app-owned focus rim and halo are the only focus grammar.

---
## 11. Console Pane Header

Every pane begins with `SectionHeader`, a baseline-aligned title field:

```text
eyebrow  — eyebrow role
title    — title role + heading trait
subtitle — caption role, Text.mid
trailing metadata — StatusChip
```

Top padding is `Space.titlebar` 32. Bottom padding is `Space.xl` 24 and is the sole owner of the header-to-content gap.

Header and body declare the same left and right edges: each caps to the pane measure and then centers that cap in the region. Voice, Refinement, System, and Diagnostics cap to `Content.form`; Glossary caps to `Content.table`; Home and Sessions use the full region, where centering an uncapped frame is the identity. The trailing metadata is state-aware — counts remain neutral, refiner/system/backend health may use ok/warn — rather than an untyped micro string.

No underline or independent hero band belongs under the header. Spacing, type, and the content measure carry the hierarchy.

---
## 12. The Manifest Grid

The Manifest Grid is the canonical layout for settings and ledger panes. Its shared primitives live in `SettingsBindings.swift`, `SettingsPaneScroll.swift`, `ContentCard.swift`, `SettingsSectionBlock.swift`, `SettingsRow.swift`, `CaptionText.swift`, `SegmentControl.swift`, and `PropertyKit.swift`; their chrome comes from `GlassKit.swift`.

### 12.1 `SettingsPaneScroll`

```swift
SettingsPaneScroll(maxContentWidth: Content.form) { ... }
SettingsPaneScroll(maxContentWidth: Content.table) { ... }
```

The scroll shell caps one **centered** content column — `.frame(maxWidth: measure, alignment: .leading)` then `.frame(maxWidth: .infinity, alignment: .center)`, the same two-frame idiom `SectionHeader` uses (§11) — and stacks its surfaces at `Space.lg`. Voice, Refinement, System, and Diagnostics use `Content.form` 760. Glossary uses `Content.table` 940. Home uses its centered `Content.grid` measure; Sessions is an uncapped master-detail workspace.

Centering is the rule, not a preference: at the 1164 default window the padded content region is 940, so the Glossary table is an exact fit and the form measure carries 90pt gutters on both sides. Growing the window grows those two gutters evenly, where a leading-flush column would instead open one widening dead band at the trailing edge. Capping a body without centering it, or centering a body under a flushed header, breaks the shared-edge contract in §11.

The pane header owns the `Space.xl` gap above the first surface. The scroll shell owns only its `Space.section` bottom inset.

### 12.2 `ContentCard` and `SettingsSectionBlock`

`ContentCard` is an opaque content surface: `Ink.surface`, `Radius.card` 20, `Space.md` 12 padding, a `Line.edge` rim, and no glass stack or shadow. `interactive: true` adds a reduce-motion-gated `Plate.hover` wash and `Line.controlHover` rim, and belongs only to a card that is genuinely an affordance. Default accessibility leaves children contained; a caller may supply a combined summary only for a static read-only leaf.

`SettingsSectionBlock(eyebrow:)` wraps its rows in `ContentCard`. The eyebrow is the card eyebrow. Rows stack at zero spacing; the container draws `HairlineDivider` overlays **between** row bounds. The final row has no trailing rule against empty card padding.

### 12.3 `SettingsRow`

```swift
SettingsRow(label: "Saved ASR backend") { control }

SettingsRow(label: "Mute during capture", status: ("MUTE ON", .neutral)) {
    control
} footer: {
    CaptionText(explanation)
}
```

Every row is a `label | content` grid:

- label column: `Column.settingsLabel` 176.
- label/content gutter: `Space.xl` 24.
- vertical padding: `Space.sm` 8.
- minimum total pitch: `Row.settings` 44.
- a 28pt toggle produces 44pt exactly; a 32pt control grows the row to 48pt.

The card's 12pt padding leaves **536pt** for the content slot in a 760pt form: `760 − 12 − 176 − 24 − 12`.

Two declarative slots replace the stacks call sites used to hand-roll:

- `status:` puts one `StatusChip(.compact)` trailing on the control line.
- `footer:` renders under the control band at the **value-column origin** (§12.7), `Space.xs` below it. A footer holds `CaptionText` and static marks only, never a control; concurrent notes stack as several `CaptionText`s at `Space.xs`. `caption:` / `captionColor:` are the single-caption convenience over the same slot.

A caption hung after a trailing chip wraps against the chip instead of the column, which is why the footer slot exists and why call sites no longer build `VStack { control; caption }` compositions themselves. Overloads keep every existing two-argument caller compiling.

The six-provider Refinement picker did **not** fit this measure. Its intrinsic group was 649pt, expanded the card by about 121pt, and put the final segment about 101pt past the 760pt cap. `SegmentGroup(rows: 2)` now lays it out as two rows of three: 323pt and 314pt before the group's 8pt horizontal padding, both within the 528pt inner group width. Do not flatten it back to one row or describe the overflow as margin.

### 12.4 `CaptionText`

`CaptionText` is the width-safe secondary-text primitive: caption typography, `Text.low` by default, vertical growth enabled, and leading alignment across the available row slot. Its optional color override is for semantic error/advisory foregrounds; ordinary hints keep the default.

It reads `@Environment(\.isEnabled)` through `A11y`. Inside a disabled row or `DependentGroup` (§12.9) it resolves to the low tone and the semantic override is dropped, because a crimson advisory under a dead control reads as a live error. Enabled rendering is unchanged.

### 12.5 Segmented controls

`SegmentGroup(rows:)` owns the clear group plate, `Line.control` boundary, 8pt radius, 4pt inset, 4pt inter-segment spacing, and its local container shape. `SegmentOption` is 32pt high and derives its 4pt radius from the group.

Every segmented choice uses `SegmentOption`; it carries the selected accessibility trait and fixed-width label. Under Differentiate Without Color, the selected segment gains a leading checkmark. The group has an explicit accessibility label. Hand-rolled conditional button-kind pickers are prohibited.

### 12.6 Compact repeated-row primitives

- `RowIconButton` has a 24pt visual body inside a real 32pt hit frame. It is for a singular repeated row action, not a replacement for labeled choices.
- `StatusChip(.compact)` is the one 20pt mark outside the control scale. Its label remains fixed-size and never truncates. Regular chips are 24pt.

Repeated controls require instance-scoped accessibility labels and identifiers. Badge rows show the exceptional state, not an unconditional badge repeated on every row.

### 12.7 `PropertyKit` and the ledger row

`PropertyKit.swift` holds the read-mostly half of the grid: the rows System, Diagnostics, and Refinement use to state a fact. Its rows publish the same row-bounds anchors and `settingsContentLead` as `SettingsRow`, so one card may mix both kinds and `SettingsSectionBlock`'s overlay rules still land between row bounds.

```swift
PropertyRow(_ label: String, value: String? = nil, valueStyle: PropertyValueStyle = .body,
            caption: String? = nil, captionColor: Color? = nil,
            accessories: [PropertyAccessory] = [], accessibilityValue: String? = nil)

enum PropertyAccessory {
    case metadata(String)                              // micro, Text.low, monospaced digits
    case status(String, StatusChip.Mode)               // StatusChip(.compact)
    case copy(payload:label:identifier:)               // RowIconButton
    case action(title:kind:label:identifier:isEnabled:isInFlight:perform:)
}
```

Geometry, all from tokens:

- label column `Column.settingsLabel` 176, `label` role, at the same tone `SettingsRow` uses. One label column, one tone.
- the **value-column origin is 200pt**, published as `PropertyGrid.valueOrigin` (`Column.settingsLabel` 176 + `Space.xl` 24). Value, caption, and footer text all start there. The Glossary's 188pt seam is table grammar (§15.1, §29.3), not this measure.
- line 1 is a `Control.medium` 32pt minimum band with `Space.xs` above and below, so a caption-less row is `Row.table` 40 exactly. A caption adds `Space.xs` plus its own height and the row grows naturally; `Row.settings` 44 is the floor.
- the line-1 value is single-line. `value` is optional: a status-only row is label plus rail on line 1, with its caption on line 2.
- accessories render in declaration order as a trailing rail at `Space.sm` gaps, closing on the card's trailing content edge. Chip first, remediation second — what is wrong, then what to do about it.
- text-bearing occupants align on `firstTextBaseline`: label, value, `metadata`, and `status`, because a chip has a real text baseline. Icon and button accessories center in the 32pt band; a control is never baseline-hung.

The rules the row enforces so call sites cannot re-litigate them:

- **Machine values** (`valueStyle: .mono`) are `bodyMono` in `Text.mono`, single-line, middle-truncated, with the full string in `.help`. They are deliberately **not** selectable: selectable text cannot live inside a combined accessibility subtree, and the copy accessory is the honest affordance for a path, model id, endpoint, or command.
- **Copy** is `RowIconButton` with the call site's own label and identifier — press feedback and a pasteboard write, no acknowledgement state of its own. A copy action appears only when there is a payload to copy.
- **Captions** carry the state's existing detail sentence verbatim, healthy states included. Quietness comes from the type scale and the chip, not from deleting the explanation. A caption starts at the value origin and never indents behind a chip. A prose-only row — no value, no accessories — renders its caption **in the value slot on line one**, sharing the label's first baseline; dropping it to a second line would strand the label beside an empty band.
- **Disabled** is resolved by the primitives, not the call site: `PropertyRow` reads `@Environment(\.isEnabled)` and drops label, value, and metadata to the `A11y` low tone; `StatusChip` and `CaptionText` do the same in their own files (§19.2, §12.4).
- **Accessibility**: with no interactive accessory the row is one combined leaf whose value joins value, status label, caption, and metadata unless `accessibilityValue` overrides it. Any `action` or `copy` accessory keeps the row's texts and controls as direct siblings of the pane — the flat treatment Glossary and Sessions rows already use. A `.contain` wrapper is prohibited here: SwiftUI reports the contained group's frame as the text band rather than the padded row, so the 32pt control "escapes" a 17pt parent and trips the harness clipped-child rule on visually correct geometry.

The `atom.properties` harness scene renders the whole vocabulary — body and mono values, caption-less and caption-bearing pitch, every accessory kind, `SettingsRow` with status and footer, `ConfirmActionRow` in each of its four states, and a disabled `DependentGroup`.

### 12.8 `ConfirmActionRow`

One row owns every typed destructive confirmation:

```swift
ConfirmActionRow(label:subject:scope:token: "CLEAR",
                 actionTitle:inFlightTitle:failureLabel:failureText:identifier:
                 isAvailable:isConfirming:perform: () async -> Bool)
```

- Collapsed: the scope sentence at the value origin in the caption role, single-line, and one `.danger` action on the trailing rail.
- Armed: a `Field.medium` 280 field prompting `Type CLEAR`, then confirm `.danger` and cancel `.ghost` at `Space.sm` gaps. Confirm stays disabled until the field's trimmed text equals the token — surrounding whitespace is a typo, not a different answer — and shows `inFlightTitle` while the write runs; cancel is disabled in flight.
- Collapsed and armed are the same single `Control.medium` band, so opening the confirmation does not resize the row and shove its neighbour, and the action keeps one title across both.
- Failed: a crimson caption and a compact failure chip on a line **below** the control band, never on it, so the armed row still fits the 536pt content slot at every width the console allows.
- The field takes focus from its own appearance, editing clears the failure, Return submits through the one guarded confirmation function, and Escape cancels unless a write is in flight (§25.6).
- The row owns the confirmation text, the in-flight flag, and the failure flag. The pane owns `isConfirming`, because arming has to scroll the danger anchor into view.
- `identifier` is the call site's stem: `.arm`, `.confirm`, `.cancel`, and `.confirmation` hang off it, and the accessibility labels are built from `subject`. Those strings are a contract — harness steps drive the flow by them.

### 12.9 `DependentGroup`

`DependentGroup(isEnabled:label:)` wraps the sections that depend on a switch. It is surface-free: no card, no plate, no blanket opacity dim on top of disabled control states. It applies `.disabled` and one contained accessibility region announcing active or inactive; the tone change is the primitives' job (§12.7). Its children are ordinary `SettingsSectionBlock`s, so the group never becomes a second nesting level in the grid, and it changes immediately under Reduce Motion.

---
## 13. Sessions

### 13.1 Layout

Sessions is an uncapped master-detail workspace. A full-width `ContentCard(eyebrow: "TOTALS")` sits above an `HStack`: the SESSIONS list is 320–440pt wide and the SESSION detail has a 360pt minimum before filling the remainder. The list alone owns a bottom scroll-edge treatment: system soft edge on macOS 26, painted `Ink.surface` fade on the legacy path.

### 13.2 Totals and list

TOTALS distributes four metrics evenly across its full card width. Full-height vertical `HairlineDivider`s sit between columns; no custom divider computes a stroke from spacing tokens.

The list search field uses `GlassTextFieldStyle(font: VoiceOourTypography.bodyMono)`. Each session row is `Row.list` **64pt** total pitch with timestamp and compact outcome marks above a one-line preview. Selection uses `.isSelected`; Differentiate Without Color adds the leading selection bar.

### 13.3 Detail and wells

The SESSION `ContentCard` owns the title, guarded delete flow, transcript, refinement metadata, and Fix/Teach flows. Nested bounded regions are 8pt-radius wells derived from the 20pt card at 12pt padding:

- transcript: opaque `Ink.well`, between `Row.list * 2` (128pt) and `Space.section * 8` (320pt), then scrolls.
- pending suggestions: well containing labeled KEEP / ACCEPT / REJECT actions.
- Fix/Teach editor: well containing fields, a labeled segment group, and ghost/accent actions.

The transcript copy surface is a focusable container rather than a `Button`; text selection, context menu, scrolling, and copy remain independently operable. ACCEPT and TEACH are `.accent`; destructive actions remain `.danger`.

### 13.4 Empty states

Whole-pane and no-selection empty states share the `emptyGlyph` role, title role, and bounded caption treatment. Decorative glyphs are accessibility-hidden.

---
## 13a. Home Dashboard

Home is a read-only dictation instrument panel over `DictationInsights`. It uses a centered twelve-column `Content.grid` measure clamped to the region. Every cell is an opaque `ContentCard`; the dashboard has no interior glass.

One numeral ladder orders the pane. `heroMetric` 64 carries exactly one figure, the saved time; `metric` 32 carries the speed ratio and the four ALL TIME quarters; `tileValue` 20 carries the RECORDS values. Everything else is `body`, `label`, `caption`, `micro`, or `eyebrow`. A shelf states at most one plain-language sentence; a second 64pt numeral, or a shelf that turns into prose, is a hierarchy defect.

Four shelves share one `Space.md` gutter grid:

1. **TIME SAVED** spans all twelve columns. Its eyebrow absorbs the coverage window — `TIME SAVED · SINCE JUN 7, 2025` once the data spans more than one day — so no standalone "since" caption trails the numerals. The interior is two equal flex halves split on the card midline by a vertical `HairlineDivider`; neither half is a fixed readout width. The left half composes the duration in `heroMetric` with `micro` unit labels, the LISTENING `StatusChip` while recording, and one sentence in `body` at `Text.mid` stating the counterfactual: what typing those same words at the baseline rate would have cost. The right half states the comparison — the ratio in `metric` with the `×` closed up on the numeral face (a unit-tier `×` beside a 32pt numeral reads as an exponent), a `label` line naming what it beats, then the YOU and TYPING `MeterBar` gauges on one shared scale.
2. **ALL TIME** is one full-width card in the Sessions TOTALS grammar (§13.2): equal flex quarters, full-height `HairlineDivider`s between them, and independently addressable accessibility children. Each `metric` value carries its own unit — words, keystrokes spared, dictations, days in a row — and that unit IS the quarter's label; a second `micro` label over a self-describing value would state every dimension twice. Those quarters are flex divisions of one card, not spans on the twelve-column grid.
3. **WHEN YOU DICTATE / LAST 14 DAYS / TOP APPS** span 4 / 4 / 4 columns — one shelf, two interior cuts, at columns 4 and 8. The hour chart is a **linear 24-column strip** — midnight → 23:00, four cardinal boundary labels in the user's own clock convention — not a polar dial: angle and radius are the least accurately read visual channels, a 24-hour ring puts noon at the bottom of the circle, and single-dictation hours vanished into the dial's hub. Its resting readout carries the headline fact with its tally ("busiest around 1 PM · 5 dictations"). Both time charts share one encoding — length from a shared baseline, one track per bucket — so the shelf speaks one chart language. The apps card keeps four columns so its rank `MeterBar` has a track long enough to draw a small share at true length instead of clamping to the minimum fill; each row states a raw count, and share drives bar length only. The ranking is capped at five rows plus an OTHER remainder row whenever the attributed total exceeds the visible sum, so the bars and printed counts always account for the whole.
4. **RECORDS** is one full-width card in the same strip grammar: up to three cells — longest dictation, fastest spoken, different words — each a `micro` label over its `tileValue` (a bare `181 wpm` names no record), each omitted when its record is absent. When the longest dictation has a stored preview, a single `caption` line at `Text.low` quotes the user's own words below the cells, held to one line with the full text in its tooltip and reachable to VoiceOver. With no cells and no preview the shelf does not render.

Home answers human questions in human units, and the arithmetic behind each claim is the honest one. The counterfactual sentence is derived from the word count at `typingBaselineWPM`, never by adding capture time to saved time, and it gives way to a quiet caption when nothing has been captured yet. The estimated-saving advisory outranks the one-sentence budget: it renders whenever the figure is an estimate. An app's share is stated against the total actually attributed to apps, not against the session count, and those counts are never called pastes — they include copied-only and failed outcomes. Transcription latency is engine trivia and belongs to Diagnostics (§18); no median, p95, or fastest-transcription figure appears on Home. Home says dictations, not sessions.

Every ordinary chart rail, baseline, bar, and empty mark uses `Meter.rest`. The resting accent budget is the YOU gauge fill alone. Chart accents are interaction marks — the hovered, keyboard-selected, or pinned hour and day — not resting decoration, and ranking is not a current datum, so no app row takes the accent at rest either. While recording, every Home accent demotes to `Signal.wash`. The hour strip and day chart expose deterministic accessibility children plus one keyboard controller. Reduce Motion draws final reveal states immediately and keeps hover/pin changes instantaneous.

Absence is honest. Missing dashboard data becomes a quiet caption inside the cell; only records with no honest placeholder are omitted. A first-run Home state uses `emptyGlyph`, title, caption, and the capture hotkey without inventing zero statistics.

---
## 14. Voice Pane

Voice has two `Content.form` sections:

- **BACKEND**: three-option ASR `SegmentGroup` (`FAKE`, `PARAKEET MLX`, `APPLE SPEECH`), running/saved status, and a 120pt monospaced locale field.
- **CAPTURE**: `Fn or Globe` trigger, auto-stop toggle with a 120pt silence field, and transcript-cleanup toggle.

The silence field is disabled when auto-stop is off, so visual and semantic state agree. Free-text drafts commit on submit or focus loss; every successful setting write persists through `settingBinding`.

Every explanatory line in the pane lives in the row's `footer:` slot (§12.3), so hints, the BCP-47 warning, and the backend readout all start at the value-column origin. The backend footer is the one that carries two static marks rather than prose — the deferral chip beside the `bodyMono` line naming the model actually loaded — and it stays a single baseline. The pane's information architecture is unchanged.

---
## 15. Glossary Pane

Glossary uses `Content.table` 940. Its inner ledger width is 916 after `ContentCard` padding.

### 15.1 Table grid

```text
CANONICAL 176 | DETECTED AS 320 | POLICY 64 when varied | SCOPE flexible ≥140 | ACTION 32
```

SCOPE is the single flexible column: its frame is always present, while the header appears only when at least one term has non-global scope and each chip paints only for its own non-global term. With POLICY present SCOPE resolves to 276pt; when every row has the same policy, POLICY is suppressed and SCOPE resolves to 352pt. The fixed 32pt action column lands at the same trailing x in the header, every term row, and the composer.

Every ledger band uses `Row.table` 40 total pitch and closes with an overlay rule. Header, value, and composer occupants share one inset per column. Protected and policy marks render only when they distinguish rows; SCOPE chips render only for non-global terms. Provenance (LEARNED / IMPORTED / BUNDLED) is not rendered.

`DETECTED AS` values edit inline: borderless at rest, hover fill on pointer, and `Line.focus` at selected width while focused. Per-row removal is a 32pt-hit-frame `RowIconButton` with instance-scoped label and identifier.

### 15.2 Composer

The final band is an inline composer on the same grid. Canonical and detected-as fields occupy their data columns; `ADD TERM` is a 32pt `.accent` action in the fixed trailing action column. It is the affirmative action of the row, not a floating primary action.

---
## 16. Refinement Pane

Refinement is optional and off by default, and the pane says so structurally: the opt-in section is always live, and everything it governs sits inside one `DependentGroup` (§12.9). Measure is `Content.form` 760.

| section | rows |
|---|---|
| `ON-DEVICE REFINER` / `NETWORK REFINER` — the eyebrow follows the provider | **Opt in**: toggle, readiness chip, and two stacked footer captions — the destination advisory and the next-launch note |
| PROVIDER | **Provider** (`SegmentGroup(rows: 2)`), then whichever the provider needs: **On-device** or **Sign-in** as a prose-only row, **Base URL**, **Endpoint**, **Model** |
| CREDENTIALS — only when the provider takes a key | **API key**: secure field, SAVE, GET API KEY, the key-source chip, and up to two footer captions; **Clear key** when the Keychain owns it |
| REQUEST | **Timeout**: `Field.short` 120, milliseconds |
| CONNECTION | **Status**: the CHECK action, the reachability chip, and two footer captions — the probe result and the permanent explanation |

The dependent group wraps PROVIDER through CONNECTION. The opt-in section stays outside it, because the control that turns the feature on cannot be disabled by the feature being off.

Readiness reads OFF / NEEDS BASE URL / NEEDS MODEL / NEEDS KEY / READY; key source reads NO KEY / KEY SAVED / KEY VIA ENV; reachability reads NOT CHECKED / CHECKING… / AVAILABLE / REACHABLE · N MODELS / BAD KEY / UNREACHABLE. Every one of them is a `StatusChip(.compact)` in a row's status slot, and every explanatory sentence is a footer caption at the value origin. The pane hand-rolls no chip-then-caption stack at all; where two notes are true at once — a Keychain error beside the environment-variable guidance, a probe result above the permanent explanation — they stack as two captions in one footer. When the group is disabled, chips and captions recede on their own (§12.7).

The prose-only rows are valueless `PropertyRow`s so that the on-device explanation and the sign-in copy share the label tone of the controls above them. **Endpoint** is a `PropertyRow` with a `.mono` value: a resolved URL is a machine string to read and copy, not a field to edit. **Clear key** is a `ConfirmActionRow` (§12.8) on `refinement.key`, present only for a Keychain-owned key, because that is the only key this app can delete.

The provider picker has six options and uses `SegmentGroup(rows: 2)`: GOOGLE GEMINI / OPENAI / OPENROUTER, then OH MY PI / APPLE ON-DEVICE / CUSTOM. This wrap is required by the 536pt row content slot (§12.3).

Changing the provider resets key entry. The reachability fingerprint is captured before the probe and its result is shown only while it still matches the live configuration — an answer about a configuration the user has since changed is discarded, not displayed.

---
## 17. System Pane

System is the capability ledger: every OS grant this app asks for is reported exactly once, with its remediation on the same row. It uses `Content.form` 760 and five sections.

| section | rows |
|---|---|
| READINESS | **Backend**: DEV READY / READY / CHECKING… / CHECK NEEDED / MODEL NEEDED, with RE-CHECK where a fresh probe is the answer; **Microphone**: NOT REQUIRED / GRANTED / WILL PROMPT / DENIED, with OPEN SYSTEM SETTINGS… when denied |
| CAPTURE | **Fn/Globe capture**: ACTIVE TAP / PASSIVE FALLBACK; **Insertion**: PASTE READY / COPY-ONLY RISK; each offers the matching Accessibility deep link while it is degraded |
| AUDIO | **Mute during capture**: toggle with MUTED NOW / MUTE ON / MUTE OFF; **Mute scope**: the two-option `SegmentGroup`, present only while muting is on |
| PRIVACY | **Data handling**: a valueless row carrying the local-data note as a permanent caption |
| DANGER | **Clear history**; **Clear vocabulary** |

The readiness and capture rows are valueless `PropertyRow`s: the status word is the chip, the existing explanation is the caption, and the remediation is an `.action` accessory on the same rail. A capability therefore says what it is, why, and what to do about it within one 32pt band and one caption, instead of a card that strands its remediation on the floor below the readout.

Deep-link actions keep instance-specific accessibility labels — "Open Microphone privacy settings", "Open Accessibility privacy settings for key capture", "Open Accessibility privacy settings for paste" — because three buttons all titled OPEN SYSTEM SETTINGS… are indistinguishable to VoiceOver.

The pane refreshes backend health and permissions on appear and again when the app reactivates, so a grant made in System Settings lands without a manual re-check; that refresh animates unless Reduce Motion is on, because up to three readouts and their remediation buttons change at once.

Both DANGER rows are `ConfirmActionRow`s (§12.8) on `system.history` and `system.vocabulary`. A row is available only when it has something to erase: saved sessions, or vocabulary that did not come from the bundle. Arming scrolls the danger anchor to center, so the field a user is about to type into is never below the fold.

---
## 18. Diagnostics Pane

Diagnostics is a read-only ledger of runtime facts on `Content.form` 760, in four sections. It states each fact exactly once. Capabilities are not repeated here — System owns them with their remediation (§17) — and no row restates a component of another row. It is a debug pane, hidden from the rail unless the app launches with `--debug` or Diagnostics is already selected.

| section | rows |
|---|---|
| APPLICATION | **Version**: the short version with its build in one value; **Saved sessions**: the count |
| BACKEND | **Backend**: the saved backend, or `SAVED → ACTIVE` with a DRIFT chip when they disagree; **Status**; **Model**: the model id, mono, with copy; **Health probe**: ALL CLEAR / NOT PROBED / ERROR, the detail as caption, and the report copy action only when a report exists |
| STORAGE | **Settings** and **Recent sessions**: mono paths, each with copy |
| SELF-TEST | **Self-test**: the command, mono, with copy and its one-line explanation |

The Status row is the pane's one composed value: the chip is the backend status — READY, MODEL MISSING, BACKEND UNAVAILABLE, or UNKNOWN — and the value is the evidence behind it, a cache part (`cache OK` / `cache missing` / `cache unknown`) joined to a model part (`model loaded` / `model not loaded` / `model unknown`). All nine combinations render. A missing health reading is `unknown`, never a silent absence.

The pane probes backend health on appear and otherwise changes nothing.

---
## 19. Controls

### 19.1 Shared state ladder

Every interactive primitive resolves the same seven states. Precedence is:

```text
inFlight > disabled > selected > focused > pressed > hover > rest
```

| state | fill | rim | foreground | motion |
|---|---|---|---|---|
| rest | `Plate.rest` | `Line.control`, hairline | role default | none |
| hover | `Plate.hover` | `Line.controlHover`, hairline | `Text.high` | `quick` |
| pressed | `Plate.pressed` | `Line.controlHover`, hairline | `Text.high` | `quick`, scale 0.985 |
| focused | current interaction fill | `Line.focus`, selected width + 2pt halo | `Text.high` | `quick` |
| selected | `Plate.hover` | cyan at 0.72, selected width | `Text.high` | `quick` |
| disabled | clear | `Line.rule`, hairline | `Text.low` | none |
| in-flight | enabled rest fill | `Line.controlHover`, hairline | enabled foreground | none |

Focus is not hover: focus owns the cyan selected-width boundary and outer halo. Selection uses the cyan boundary without the halo. Under Differentiate Without Color, hovered boundaries also rise to selected width.

### 19.2 `StatusChip`

```swift
StatusChip(label:mode: .neutral | .ok | .warn | .crit | .live,
           size: .regular | .compact)
```

Regular height is 24pt; compact is the declared 20pt mark exception. Radius is 6pt. Neutral uses `Plate.rest` and `Text.mid`; Increase Contrast raises those to `Plate.hover` and `Text.high`. Signal modes use their full-opacity foreground and fill at 0.08, rising to 0.18 under Increase Contrast. `StatusChip` draws no rim or boundary.

`StatusChip` reads contrast through `A11y`; it never relied on a parent to do so. Differentiate Without Color adds `checkmark`, `exclamationmark.triangle.fill`, `xmark.octagon.fill`, or `circle.fill` for ok, warn, crit, or live. The chip is a non-interactive fill-and-foreground mark.

`StatusChip` also reads `@Environment(\.isEnabled)`. Inside a disabled row or `DependentGroup` (§12.9) the foreground drops to the `A11y` low tone and the fill recedes to the same neutral plate every neutral chip uses — `Plate.rest`, or `Plate.hover` under Increase Contrast — while the label and the Differentiate Without Color symbol stay. The shape survives, the color dies: the mode is still true, the block it grades is simply not in effect, so deleting the mark would lie and leaving it at full signal would make a switched-off section the brightest thing on the pane. Enabled rendering is unchanged, the chip still owns no rim, and call sites never dim a chip by hand.

### 19.3 `GlassButtonStyle`

`GlassButtonStyle.Kind` is `.ghost | .accent | .danger`. All three are painted 32pt rounded rectangles on both paths. Their radius is fixed at `Radius.nested(Radius.card, inset: Space.md)` = 8pt.

```text
ghost:
  rest      Plate.rest / Line.control
  hover     Plate.hover / Line.controlHover
  pressed   Plate.pressed / Line.controlHover

accent:
  rest      cyan 0.06 / cyan 0.42
  hover     Plate.hover / cyan 0.70
  pressed   cyanDeep 0.16 / cyan 0.90

danger:
  rest      crimson 0.04 / crimson 0.60 / crimson foreground
  hover     crimson 0.08 / crimson 0.72 / Text.high
  pressed   crimson 0.08 / crimson 0.72 / Text.high
```

Disabled buttons use clear fill, `Line.rule`, and `Text.low`. Focus uses `Line.focus`, selected width, and the halo. An in-flight button keeps its enabled foreground, prepends the static `circle.dotted` mark, publishes `"In progress"`, disables semantic activation, and guards the action against duplicate entry.

### 19.4 `PrimaryActionButtonStyle`

The pane's single floating primary action is a 40pt capsule. The shipping call site is Menu `Start Dictation`; in-content affirmative actions use `.accent` instead.

The action uses the painted cyan capsule on every OS path: rest fill 0.08 and rim 0.42, hover fill 0.14 and rim 0.62, pressed `Signal.cyanDeep` fill 0.22 and cyan rim 0.62. It must not adopt the system prominent glass style because its only call site is already inside the glass menu popover. It uses the same disabled, focus, pressed-scale, Reduce Motion, Increase Contrast, and Differentiate Without Color behavior as the shared ladder.

### 19.5 `GlassTextFieldStyle`

Fields are 32pt high with 12pt horizontal inset and an 8pt derived radius. Rest is an opaque `Ink.well` recess with `Line.control`; hover is `Plate.hover` with `Line.controlHover`; focus is `Plate.rest` with `Line.focus`, selected width, and the halo; disabled retains the opaque `Ink.well` recess with `Line.rule` and `Text.low`.

The style applies `.textFieldStyle(.plain)` before drawing its plate, suppresses the native focus ring, and accepts a font parameter so machine strings can use `bodyMono`. Every governing off-state disables the field semantically as well as visually.

### 19.6 `GlassToggleStyle`

The toggle remains an `AXCheckBox` / `AXToggle` through its accessibility representation while a real button body supplies keyboard activation. The visual track is 42×24 with a 20pt knob, 18pt travel, and a 44×28 hit frame.

Off uses `Plate.rest` with `Line.control`. On uses cyan at 0.22 with a cyan rim at 0.55; hover raises the on rim to 0.75 and the off rim to `Line.controlHover`. Press scales the knob to 0.94. Disabled is clear with `Line.rule`, a `Mark.faint` knob, and `Text.low` label. Differentiate Without Color adds a checkmark inside the on track.

### 19.7 `SegmentOption`

See §12.5. Segments follow the shared rest/hover/pressed/focused/selected/disabled ladder. Selected segments use `Plate.hover` with the cyan selected rim on every supported OS path. Disabled groups suppress the cyan selection accent.

### 19.8 `KeyCap`

`KeyCap` is a static 24pt-minimum mark at `Radius.keycap` 4. It uses `micro` mono text, `Plate.hover`, `Line.control`, and contrast-aware hairline width. Hotkey labels in the app are `Fn` and `Globe`.

### 19.9 `RowIconButton`

The icon has a 24pt visual plate and 13pt glyph inside a real 32×32 hit frame. Rest and disabled have no plate; hover uses `Plate.hover` with `Line.control`; press uses `Plate.pressed` with `Line.controlHover`; focus uses `Line.focus` plus the halo. The call site supplies an accessibility label and instance-scoped identifier.

`RowIconButton` reads Increase Contrast and Differentiate Without Color through `A11y`: line widths resolve from contrast, and a hovered boundary rises to selected width when color cannot be the only cue.

### 19.10 `RecordingOverlayButton`

The overlay control is the documented exception in §21.3 paragraph 4: a 22pt visual disc in a 28pt hit frame, with permanent rest fill and stroke because it floats over arbitrary desktop content. Hover, press, focus, disabled, Increase Contrast, and Reduce Motion layer on top of that permanent rest chrome; it is not a row-icon ghost.

---
## 20. Color Independence and Cross-Cutting State

Color is never the only channel required to understand state.

| state or signal | ordinary cue | Differentiate Without Color cue |
|---|---|---|
| selected rail item | painted `Plate.hover` / cyan rim | 3×16pt leading bar and semibold label |
| selected segment | painted `Plate.hover` / cyan rim | leading checkmark |
| selected session row | cyan rim | leading bar |
| keyboard focus | cyan rim | 2pt outer halo, present in every mode |
| status chip mode | signal tint | per-mode leading glyph |
| disabled chip or caption | tone recedes to `Plate.rest` / low text | mode glyph retained |
| rail idle/live | faint/cyan mark | hollow idle ring / filled live dot |
| menu-bar state | alien emoji; cyan active or crimson error dot | unchanged visual; state-specific VoiceOver label |
| chart accent | cyan mark | cap rule and value label |
| toggle on | cyan track | checkmark in track |

Signal text still names the state wherever text exists (`GRANTED`, `DENIED`, `LIVE`, `ERROR`); the shape channel is supplementary, not a replacement for a useful label.

`StatusChip` and `RowIconButton` both read `colorSchemeContrast` through the shared `A11y` resolver. Chips escalate fill and foreground; row icon buttons escalate their control boundary and selected/focus widths. `HairlineDivider`, `KeyCap`, `GlassSurface`, `PlateSurface`, `ContentCard`, button styles, toggle, text field, charts, menu chrome, and the recording overlay use the same contrast resolver rather than assuming a parent surface handled it.

The recording-overlay comet remains the intentional product exception to the one-palette rule (§21.4); its state is also exposed by text and accessibility labels, so its sampled hue is decorative rather than the sole signal.

---
## 21. Recording Overlay

This section reflects the complete implementation in `Sources/VoiceOour/RecordingOverlay.swift`.

### 21.1 Architecture

The overlay is a borderless, non-activating `NSPanel` at `.screenSaver` level with a clear, shadowless panel background. Its custom `NSHostingView` uses the same geometry function as SwiftUI to give each 22pt control disc a real 28pt hit frame; the rest of the island drags the panel and the area outside the island passes through. `RecordingOverlayController` owns the panel and `RecordingOverlayModel` derives presentation from `SessionState` and live input level.

The panel window is 260×80; its visible island is a 180×34 capsule.

### 21.2 What ships per state

Seven of `SessionState`'s thirteen cases are active: checking permissions, recording, finalizing audio, transcribing, cleaning, refining, and ready to insert. Idle and the five terminal outcome/error/cancel cases order the panel out; those outcomes surface in the menu and rail instead.

Recording gets the live waveform. The other six active states share the comet plus an in-capsule uppercase state label and matching VoiceOver description. Reduce Motion freezes comet travel at its resting phase but retains the lower-frequency breathing signal; it does not remove the in-progress affordance.

### 21.3 Rules

1. Do not redesign this surface's glass/waveform/comet vocabulary independently of a specific, scoped need — it is intentionally allowed richer motion than the console (§1 rule 7).
2. Overlay pill keeps its `Capsule` shape and its existing two-layer shadow, `VoiceOourMetrics.Shadow.overlayOuter`/`.overlayInner` (`black.opacity(0.26)`/`0.18).
3. **Never render audio-mute glyphs, labels, badges, or controls inside the recorder pill.** When recording and `isSystemAudioMuted == true`, the overlay still shows only the waveform. Mute state belongs in `MenuBarExtra`, System, Diagnostics, and session metadata — not here. This exclusion is deliberate and was verified as correctly honored in the current implementation, not a gap.
4. Control glyphs (`RecordingOverlayButton`, 22x22) are intentionally heavier-weight than `RowIconButton` — permanent fill+stroke at rest rather than hover-only — because the discs sit on the island's glass and the pill floats over arbitrary desktop content with no window chrome to lean on for legibility. They remain painted on macOS 26; applying another glass material would be glass-on-glass. Do not "fix" this into `RowIconButton`'s ghost style; document the divergence, don't collapse it.


### 21.4 Glass Recipe (Divergent, By Necessity)

On macOS 26 the island uses system `.glassEffect(.regular, in: .capsule)`. On macOS 14/15 and under `forceLegacyGlass`, it reproduces the shared four-layer legacy recipe for a capsule: `FrostedGlassBackground`, `glassTint`, `specularRim`, and `Ink.rimDark`. The legacy branch reads Increase Contrast for its strokes and Reduce Transparency replaces material/tint/specular layers with opaque `Ink.void` and `Line.edge`.

The legacy duplication is warranted because `GlassSurface` is rounded-rectangle-specific; all values still come from shared tokens.

### 21.5 The Comet: an intentional, documented exception to §4.4

`FrostedCometIndicator` drives a randomly-selected emoji (one of ~40) whose trail color is sampled from the glyph's own pixels each session — genuinely outside the "one signal color" rule, and the code comments make clear this is deliberate ("Deliberately playful… best-effort, by design"), not an oversight. **Decision for a future pass, not resolved by this document:** keep it as a documented Easter-egg exception (this section is that documentation), or fold it into the restrained-cyan rule and lose the personality. Until a decision is made, do not "fix" this into a cyan-only indicator without discussing it — it may be load-bearing for the product's personality, not a bug.

---
## 22. MenuBarExtra

`MenuView` is a fixed **280pt** popover organized by whitespace into status, optional report, and actions.

`MenuBarLabel` always renders the alien emoji. Active states add a cyan dot, a critical state adds a crimson dot, and idle adds no dot; the state-specific VoiceOver label names idle, recording, working, or error. There is no state-specific symbol branch.

### 22.1 Material paths

On macOS 26 the standard `MenuBarExtra` host owns its system material; the content adds no custom glass background. Every child control is paint over that material, including the primary action: `PrimaryActionButtonStyle` uses the same full-width cyan capsule on every OS path rather than a prominent glass control, because a second glass material inside the glass popover can erase the capsule and change its intrinsic control height. On the legacy/harness path `PopoverChromeConfigurator` touches only `backgroundColor`, `isOpaque`, and `appearance`, then one `Radius.window` shape paints opaque `Ink.void` with a contrast-aware `Line.edge`. It never reuses the console window configurator.

### 22.2 Content

- Status row: state-derived `StatusChip`, optional compact `SYSTEM AUDIO MUTED`, and the capture `KeyCap`.
- Report: optional transcript-copy well and terminal outcome detail.
- Actions: one full-width `PrimaryActionButtonStyle`, then one bordered command group containing the remaining 32pt sentence-case rows.
- Saved-session count in `micro`.

The primary action opens the console when an error gate needs remediation; otherwise it starts or stops dictation. The transcript copy control belongs to the transcript well and disappears with it. The popover remains `.menuBarExtraStyle(.window)` and auto-dismisses when focus leaves, as a menu-bar window should.

---
## 23. Audio-Mute UX

Verified against `Sources/VoiceCore/Models.swift` — defaults are `muteSystemAudioDuringCapture: Bool = true`, `muteScope: MuteScope = .builtInOutputOnly`.

Mute is a system side effect; UI must whisper clearly and never overclaim.

- Mechanism lives in `VoiceMac` (`SystemAudioMuter`), using public CoreAudio HAL (`kAudioDevicePropertyMute`, `AudioObjectSetPropertyData`, property listener blocks) — no private CoreAudio APIs. `VoiceCore` stays pure Foundation.
- `DictationCoordinator` owns orchestration: apply before recording starts (if enabled), restore on every terminal path (stop success, cancel, ASR failure, mic-permission failure, app termination, unexpected error).
- Observable UI state: `public private(set) var isSystemAudioMuted: Bool` on the `@Observable` `DictationCoordinator` — the rail-footer status cluster (§10.1), System pane, Diagnostics, `MenuView`, and session history all read this directly. It is deliberately **not** mirrored into the recording overlay's model (§21.5 rule 3).
- Crash safety: ownership is persisted to a flag file (`~/Library/Application Support/VoiceOour/mute-owned.flag`, never `UserDefaults`) before muting, verified and cleared on next launch before UI mounts.
- User override: if the user changes mute/volume externally while VoiceOour owns it, drop ownership immediately, clear `isSystemAudioMuted`, do not reassert — the user wins.
- Default scope `.builtInOutputOnly`: built-in transport mutes; unknown transport treated as leaky (mute); Bluetooth/USB/DisplayPort skipped unless `.allOutputs` is selected.
- If a CoreAudio write fails: don't persist ownership, don't show recorder-pill mute UI, show only the System pane hint "Unavailable on the current output device."

VoiceOver strings in use: "System audio muted" (live), "Recorded with system audio muted" (historical session).

---

## 24. Motion

```swift
VoiceOourMotion.quick      = .easeInOut(duration: 0.14)
VoiceOourMotion.standard   = .easeInOut(duration: 0.18)
VoiceOourMotion.deliberate = .easeInOut(duration: 0.22)
VoiceOourMotion.meter      = .easeOut(duration: 0.12)
```

`quick` is hover/press/focus feedback and rail/segment/shared-control selection. `standard` is toggle and deliberate state, content, or provider transition. `deliberate` is reveal/confirmation/overlay transition. `meter` is the normal audio-level and waveform tier.

Springs, bounce, and elastic motion are forbidden. The rail live-dot pulse and recording-overlay comet are the deliberate perpetual animations; Reduce Motion makes the dot static and freezes comet travel while retaining its lower-frequency breathing signal. The recording waveform also remains animated: it switches from `meter` to a damped `deliberate` animation with reduced travel. Other state-change animations resolve instantly.

---
## 25. Accessibility

### 25.1 One resolver and deterministic seams

`A11y` resolves four read-only SwiftUI environments:

```swift
accessibilityReduceTransparency
accessibilityReduceMotion
accessibilityDifferentiateWithoutColor
colorSchemeContrast
```

The offscreen harness cannot set those get-only environment keys. App-owned optional overrides in `RenderOverrides` therefore resolve as `override ?? environment`; every override is nil in production. The same seam drives the four `a11y.*` scenes without private API.

### 25.2 Reduce Transparency

- Modern root, recording-overlay island and menu-popover host materials use the system's own
  Liquid Glass adaptation. The rail selection, segmented selection, overlay control discs and
  menu primary action are painted on every path (§5.3), so they adapt through the tokens below
  rather than through the system material.
- Legacy console ground: frost, tint, and specular rim become one opaque fill, and that fill is
  `Ink.frost` sRGB(0.190, 0.200, 0.220), **not** `Ink.void`. The substitute has to be *lighter*
  than `Ink.surface`, because the vibrancy it replaces rasterises lighter than the cards floating
  on it. Painting `Ink.void` there instead left ground-to-card at 1.06:1 and rail-to-ground at
  1.00:1 — the adaptation made the console harder to read than not adapting at all. `Ink.frost`
  restores a 1.50:1 step. The dark definition rim remains.
- Legacy recording overlay: the material/specular stack becomes one opaque `Ink.void` capsule with `Line.edge`. `Ink.void` is right here and wrong for the console ground above, because the island hosts no content surface — there is no ground-to-card step to preserve, only a silhouette against the desktop, and the rim carries that.
- Legacy menu popover is already opaque `Ink.void` with `Line.edge`.
- Content surfaces, plates, wells, and marks do not change because they are already opaque paint.

### 25.3 Increase Contrast

`A11y` applies these escalations:

```text
Text.low       → Text.mid
Text.mid       → Text.high
Mark.faint     → Text.low
Line.rule      white 0.13 → 0.24
Line.edge      white 0.18 → 0.30
Line.control   white 0.35 → 0.55
Ink.surface    → Ink.void
Meter.rest     white 0.35 → 0.55
hairline       0.5pt → 1.0pt
selected       1.5pt → 2.0pt
chip signal fill 0.08 → 0.18; neutral fill `Plate.rest` → `Plate.hover`
```

The resolver is read by every shared boundary owner, including `HairlineDivider`, `KeyCap`, `RowIconButton`, button styles, toggle, text field, content cards, charts, menu chrome, and overlay controls. Fill-only `StatusChip` reads the same resolver without claiming boundary ownership.

### 25.4 Reduce Motion

Reduce Motion removes decorative transition animation, never state or affordance. Hover, press, focus, selection, toggle, confirm, and copy-acknowledgement states swap immediately. Home chart reveals draw their final state immediately and chart hover/pin updates remain operable. The rail live dot becomes static. The recording waveform is the deliberate exception: it keeps a damped `deliberate` animation with reduced travel. The processing comet freezes its travel while retaining lower-frequency breathing rather than disappearing. The in-flight mark is already static.

### 25.5 Differentiate Without Color

The complete non-color grammar is in §20. It is implemented by the components that own the signal: rail/session selection bars, segment/toggle checkmarks, status and severity symbols, hollow/filled live marks, the menu-bar state label exposed to VoiceOver, chart cap/value marks, and the focus halo. Call sites do not reproduce these cues. Disabled state subtracts color, not shape: a chip inside a disabled row or `DependentGroup` recedes to `Plate.rest` and the low tone but keeps its mode symbol, so a warning that is currently unreachable still reads as a warning.

### 25.6 Keyboard and VoiceOver

- Custom toggles preserve `AXCheckBox`, `AXToggle`, value, label, and disabled state while supporting Space/Return.
- Selection uses `.isSelected`, not a string value.
- Repeated controls have instance-scoped labels and identifiers.
- Section labels expose the heading trait; decorative marks are hidden.
- The rail capture hotkey is a sibling accessibility group with value `"Fn or Globe"`.
- Home charts expose deterministic per-datum accessibility children and one focusable keyboard controller each.
- The transcript copy surface is a focusable container, not a `Button`, preserving text selection, scrolling, context menu, and copy behavior.
- Typed confirmation fields take focus from their own appearance, submit through the guarded confirmation function, and support guarded Escape cancellation.

---
## 26. Implementation Files

The UI is split by pane; there is no monolithic settings file.

```text
DesignTokens.swift      palette, text roles, metrics, state resolver, motion
GlassKit.swift           accessibility resolver; glass, plate, mark, and control primitives
SettingsBindings.swift   persisted settings bindings
SettingsPaneScroll.swift centred settings pane shell
ContentCard.swift        shared content surface
SettingsSectionBlock.swift settings row groups
SettingsRow.swift        settings rows and divider geometry
CaptionText.swift        secondary settings descriptions
SegmentControl.swift     segmented settings controls
PropertyKit.swift        property rows, accessory rail, confirm row, dependent group
ConsoleView.swift        window host and activation policy
ConsoleSection.swift     navigation section model
ConsoleScaffold.swift    shell, pane composition, modern/legacy root application
ConsoleLeftRail.swift    navigation rail and status footer
ConsoleSectionHeader.swift pane header and metadata
HomePane.swift           derived-state snapshot and populated/empty routing
BentoRow.swift           twelve-column dashboard layout
HomeChartEnvironment.swift chart geometry and live-capture accent
HomeDashboard.swift      dashboard shelves
HomeFormat.swift         dashboard metric formatting
HomeMetricRow.swift      all-time and records metric strips
HomeVelocityGauges.swift speaking/typing comparison
MeterBar.swift           horizontal meter
MetricValue.swift        typed metric readout
HomeEmptyState.swift     first-run dashboard state
HomeHourChart.swift      linear 24-hour dictation chart
HomeDayChart.swift       fourteen-day chart
HomeDestinations.swift   TOP APPS rank rows
VoicePane.swift          backend and capture settings
GlossaryPane.swift       pane state, mutations, import and export
GlossaryHeaderRow.swift  ledger column headers
GlossaryAddRow.swift     inline term composer
GlossaryLedgerGrid.swift ledger layout
GlossaryTermRow.swift    protected-term rows
GlossaryModelDisplayAdapters.swift scope labels
RefinementPane.swift     opt-in/dependent-group orchestration
RefinementOptInSection.swift local/cloud boundary and opt-in
RefinementProviderSection.swift provider selection
RefinementCredentialsSection.swift provider credentials
RefinementRequestSection.swift request settings
RefinementConnectionSection.swift provider connection state
SystemPane.swift         capability ledger: readiness, capture, audio, privacy, guarded erase flows
DiagnosticsPane.swift    runtime-fact ledger
SessionsPane.swift       master/detail state, filtering, grouping
SessionFormatting.swift  session metadata labels and date formatters
SessionListViews.swift   search, day groups, rows, empty list
RecentSessionMetricStrip.swift totals strip
RecentSessionDetailPane.swift selected-session detail and actions
SessionTranscriptCard.swift transcript, metadata, actions
SelectableTranscriptText.swift selectable transcript bridge
SessionFixTeach.swift    Fix/Teach and pending suggestions
EmptyState.swift         shared empty-state primitive
MenuView.swift           menu-bar popover state and block composition
PopoverChromeConfigurator.swift legacy popover host configuration
RecordingOverlay.swift   overlay panel, model, material, controls, waveform, comet
UIHarness/               deterministic fixtures, scene catalog, render/runtime seams
```

View files compose the vocabulary of `DesignTokens`, `GlassKit`, the settings primitives above, and `PropertyKit` instead of inventing parallel colors, geometry, or control states.

---
## 27. Persistence and Save UX

Settings settle on change: every settings control writes through `settingBinding`, which sets the value on `coordinator.settings` and calls `coordinator.saveSettings()` synchronously in the same closure. No manual "Save Settings" button anywhere, no modal on success. A failed write is currently silent: `saveSettings()` is `try? settingsStore.save(settings)` and no pane reports the failure, the property ledger included (§29.4).

---

## 28. Review Checklist

Reject a change if it:

- adds `TabView`, SwiftUI `Form`, a third-party UI dependency, or private API;
- uses an API above the macOS 14 floor without an explicit availability path;
- adds raw colors, fonts, radii, spacing, control heights, or row pitches in a view file;
- applies glass to a content surface or creates independently composited glass on glass;
- gives a nested full-bleed shape a fixed radius instead of `Radius.nested`;
- applies a shadow, tint gradient, specular rim, or offscreen compositing group to content;
- adds a second accent color or uses cyan decoratively;
- uses color as the sole required state signal;
- collapses focus into hover or suppresses focus without the app-owned rim and halo;
- ships a control without pressed, disabled, keyboard, or accessibility behavior appropriate to it;
- sizes a hit target with `.contentShape` instead of a real frame;
- lets a purpose-sized field/picker escape its bounded row slot;
- draws a row divider as a layout sibling or leaves a trailing rule after the final row;
- hand-rolls a segmented picker instead of `SegmentGroup` + `SegmentOption`;
- hand-rolls a chip-and-caption stack inside a row instead of the `SettingsRow` status/footer slots or a `PropertyRow` accessory rail, or puts a control in a footer;
- promotes a ledger fact to a display face, or restates one fact in a second row;
- repeats default badges instead of showing exceptional state;
- uses a labeled full button for one singular action repeated down a dense table;
- converts transcript copy into a `Button` that competes with selectable text;
- adds an unguarded destructive or in-flight activation path;
- changes overlay-button rest chrome into the row-icon ghost treatment (§21.3 paragraph 4);
- adds a modern render path without a deterministic force-legacy harness branch;
- lowers `Window.minWidth` below the `Column.rail + 2 * Space.xl + Content.table` requirement;
- adds decorative perpetual motion beyond the rail live dot and overlay comet;
- changes audio-mute ownership or default semantics without an explicit product decision.

---
## 29. Known Drift — Next Redesign Targets

Only unresolved product or maintainability decisions belong here. Accessibility, contrast, content-layer glass, radius, control-state, provider-wrap, popover-material, and retired-token findings fixed by the current implementation are not backlog items.

### 29.1 Recording Overlay

| Severity | Finding |
|---|---|
| Low | The comet's random per-session sampled color is the intentional exception in §21.4. Keeping the Easter egg or folding it into restrained cyan requires a product decision, not a mechanical cleanup. |
| Low | The legacy capsule reproduces the root glass layers because `GlassSurface` is rounded-rectangle-specific. The duplication is maintainability debt, not a visual defect. |

### 29.2 Sessions detail actions

| Severity | Finding |
|---|---|
| Low | `PendingSuggestionRow` uses `.danger` for REJECT even though “stop suggesting” is softer than irreversible data loss. Changing that grammar requires a product decision. |

### 29.3 Two ledger grammars

| Severity | Finding |
|---|---|
| Low | The Glossary's table seam is `Column.glossaryCanonical` 176 + `Space.md` 12 = 188, while every other ledger row starts its value column at 176 + `Space.xl` 24 = 200. Each is right for its own density and the property-ledger pass deliberately left the table alone, but two value origins in one app is a grammar decision nobody has made yet. |

### 29.4 Silent settings-save failure

| Severity | Finding |
|---|---|
| Medium | `DictationCoordinator.saveSettings()` swallows its error, so a failed write leaves the UI showing the new value and the disk holding the old one with no chip, caption, or log. The Diagnostics ledger now has an obvious home for it — a BACKEND-style row with a warn chip — but publishing a save-failure state on the coordinator is a behavior change, not a layout one, so the property-ledger pass deliberately left it out. |

Delete a row in the same change that resolves it.

---
## 30. Final Visual Test

Before shipping a redesign pass, test these states:

1. Light wallpaper, transparency on.
2. Pure white wallpaper, transparency on.
3. Reduce Transparency on.
4. Reduce Motion on.
5. Increase Contrast on.
6. Non-Retina external display.
7. Keyboard-only navigation.
8. VoiceOver on a session row and a mute status.
9. Recording with mute off / on (built-in speakers) / on (unsupported output).
10. Crash-recovery flag path.
11. Fake backend smoke path (`scripts/run_dev.sh --self-test`).
12. MLX and Apple backend loading/error/ready states.
13. Legacy sessions without outcome/mute metadata.
14. Window resized to the 1164pt minimum with Glossary open.
15. The complete offscreen harness on both legacy and eligible modern paths, including the four `a11y.*` scenes.

If the user closes the console and remembers only this, the design is correct:

```text
VOICEOOUR
thin tracked type on black glass,
one cyan heartbeat,
everything else quiet,
every row on the same rule.
```
