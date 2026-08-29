# Voiceour design bible

The console window follows macOS. The app's own visual language applies to the menu popover, the recording overlay, and Home's stats islands.

## Native window contract

- Use native controls: `TabView`, `Form(.grouped)`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, searchable lists, and context menus.
- No custom window or navigation chrome, control skins, or forced dark appearance. The window inherits appearance, accent color, focus behavior, control metrics, VoiceOver semantics, and accessibility settings from macOS.
- The window ground is a system material: `NSGlassEffectView(style: .regular)` on macOS 26, behind-window `NSVisualEffectView(material: .underWindowBackground)` below it, `windowBackgroundColor` under Reduce Transparency. It may clear `NSWindow.isOpaque` and `backgroundColor`, nothing else, and it may not tint, rim, or shadow.
- Destructive actions use native confirmation dialogs with a visible title and destructive role.
- App-owned styling stays narrow: monospaced text for code-like values, `ConsoleStateMark`, `ConsoleCaption`, `ConsoleRow`, and `MeterBar`. On a native plate `MeterBar` paints in system semantic colours — the same split `ConsoleStateMark` (system colours) and `StatusChip` (app palette) already make.
- At idle the app is `.accessory`. While the console is visible it promotes to `.regular`, then returns to `.accessory` when the window closes. `ConsoleWindowView.managesActivationPolicy` stays false when launch passes `--no-activate` or the process is `.prohibited`.

## Visual vocabulary

One graphite ground and a small semantic signal family.

| role | value |
| --- | --- |
| `Ink.void` | sRGB (0.02, 0.03, 0.05), opaque |
| `Text.high` | sRGB (0.89, 0.91, 0.95) |
| `Text.mid` | sRGB (0.64, 0.71, 0.80) |
| `Text.low` | sRGB (0.51, 0.56, 0.64) |
| cyan | active, live, focus |
| mint | successful outcome |
| amber | degraded or waiting |
| crimson | failure or destructive action |
| `Alien.bloom` + heat ladder | Home only: dictation volume and the page's one accent |

One signal color dominates a view. `Alien` appears only on Home, as fill, glyph tint, and glow, never as text color. Its four heat steps are quartiles of the window's busiest day, and Differentiate Without Color replaces the hue ladder with a size ladder at one hue.

`OnGlass` (`cyan`, `mint`, `amber`, `crimson`) is the same four roles on macOS 26 system glass only: mid-tones measured to clear 4.5:1 against both white and black. It does not apply on the painted or opaque grounds.

Type uses the tokenized 10–17 pt ladder in `DesignTokens.swift` plus the 20/32/64 pt metric ladder for figures. Spacing uses the 4 pt vocabulary (`xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24, `xxl` 32). Control heights are 24, 28, 32, and 40 pt.

## Menu popover

280 pt wide, with three whitespace-separated blocks:

1. Status — state chip, mute state when relevant, Fn keycap, and one headline.
2. Report — failure, last transcript, or delivery outcome; absent when there is nothing to report.
3. Actions — one primary dictation action followed by one grouped command list.

## Recording overlay

The panel is a clear, borderless 260×80 pt window; only one procedural mercury body is
visible inside the centered 180×34 pt envelope. Place that envelope 44 pt below the
display's visible top edge with a 16 pt screen margin. The transparent remainder is
window bleed, not another surface.

There is no capsule, glass material, app shadow, control disc, waveform, working mark,
painted word, symbol, authored highlight, rim or tint. A CPU rasterizer draws a generated
polished-mercury material into one `CGImage` on every supported macOS version:

- `MercurySimulation` emits the top and bottom contact lines. Listening, speaking,
  processing and the three unclean outcomes are distinct size/shape poses.
- `MercuryField` is the sole silhouette. Pixels, drag hit-testing and the open-hand cursor
  all ask that same signed field, so invisible panel area cannot swallow a click.
- A fixed-aspect half-elliptic crown lifts that field into a surface. Its total gradient
  includes the changing local radius, so a crest changes the reflection as well as the
  outline; the broad mirror-flat plateau is unrepresentable.
- Every session draws one static generated room: bounded, stratified area sources over a
  neutral bounce, with low-saturation luminance-neutral source colour. The room never
  rotates or changes intensity. All visible motion belongs to the body.
- Exact liquid-mercury conductor Fresnel colours the reflected room. A two-anchor bounded
  response maps the room's median to 0.32 and its p98 highlight to 0.87 in linear light;
  no finite radiance can reach the 0.94 ceiling, so sustained speech cannot turn the body
  plain white.

Autonomous mode noise keeps the visible body alive while listening. The eleven audio
levels drive a right-to-left crest train during speech. Physics stays at 120 Hz; the
engine presents a cached raster at 30 Hz. Reduce Motion removes autonomous noise but
keeps voice and pose motion because those carry information. The body is already opaque
and its room is already static, so Reduce Transparency requires no overlay-specific
branch and changes no pixels. Increase Contrast re-solves the same bounded scene anchors
and never clips against the ceiling.

Idle draws and publishes nothing. Active states expose one fixed-frame accessibility
element labelled `Dictation status`; Finish and Cancel survive as named actions on it.
Unclean outcomes hold for 1.2 seconds and use three deterministic silhouette gestures
(`gathered`, `lurch`, `collapse`), click-through, with no glyph, word or hue carrying the
state. A clean paste and a cancel dismiss at once.

## Motion

- Respect Reduce Motion at every animation boundary, and use the shared quick, standard, and deliberate timing vocabulary.
- The menu animates report and state changes so resizing does not jump under the pointer.
- The overlay's room is static. Autonomous and voice-driven surface modes are its only continuous visual motion; Reduce Motion removes the autonomous part while preserving the information-bearing voice and pose response.
- Native console controls keep system motion and focus behavior.
- Resting settings do not animate. A static state stays understandable with all motion disabled.

## Accessibility

- Every interactive element carries a stable, human label.
- State is never color-only. Chips and marks carry words, and Differentiate Without Color adds symbols.
- Explanatory captions are siblings, not folded into a control's accessibility label.
- Where a gesture is the only way to reach a behavior, the same element publishes a named accessibility action, and a completed gesture posts an announcement.

Scene coverage lives in [ui-harness.md](ui-harness.md).
