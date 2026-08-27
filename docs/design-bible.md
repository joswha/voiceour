# Voiceour design bible

The console window follows macOS. The app's own visual language applies to the menu popover, the recording overlay, and Home's stats islands.

## Native window contract

- Use native controls: `TabView`, `Form(.grouped)`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, searchable lists, and context menus.
- No custom window or navigation chrome, control skins, or forced dark appearance. The window inherits appearance, accent color, focus behavior, control metrics, VoiceOver semantics, and accessibility settings from macOS.
- The window ground is a system material: `NSGlassEffectView(style: .regular)` on macOS 26, behind-window `NSVisualEffectView(material: .underWindowBackground)` below it, `windowBackgroundColor` under Reduce Transparency. It may clear `NSWindow.isOpaque` and `backgroundColor`, nothing else, and it may not tint, rim, or shadow.
- Destructive actions use native confirmation dialogs with a visible title and destructive role.
- App-owned styling stays narrow: monospaced text for code-like values, `ConsoleStateMark`, `ConsoleCaption`, and `ConsoleRow`.
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

The panel is 260×80 pt; only the centered 180×34 pt capsule is visible. The transparent remainder is 40 pt each side, 16 pt above and 30 pt below — bleed for Liquid Glass's own adaptive shadow, which draws outside the capsule and would clip at the window edge. Place the visible pill 44 pt below the display's visible top edge with a 16 pt screen margin. Both discs are a 22 pt circle in a 28 pt hit target.

The island has three grounds, and none of them draws an app shadow:

- macOS 26 uses `.glassEffect(.regular, in: .capsule)`. The material's own adaptive shadow is the elevation.
- macOS 14/15 uses behind-window frost plus the app's tint and two rims.
- Reduce Transparency, on every OS, replaces either with opaque `Ink.void`.

On the painted and opaque grounds the frost, tint and two rims already give the silhouette its separation. The `NSPanel` stays clear, non-opaque, and shadowless; the visible surface owns its own shape.

On system glass, the material is adaptive and can render light over a light desktop. Neutral text and glyphs therefore use `.primary`/`.secondary` so SwiftUI's vibrancy keeps them legible; an explicit sRGB literal defeats that treatment. Hues that carry meaning use `VoiceourPalette.OnGlass`, whose four mid-tones are each measured to clear 4.5:1 against both white and black. `Signal`'s pastels stay correct on the two near-black grounds and are used there unchanged.

The meter is eleven 4 pt bars 4 pt apart, resting at 8 pt and rising to 20 pt (12 pt under Reduce Motion). Opacity floors at 0.78, and at 0.92 under Increase Contrast. There is no bloom and no glow. Voice activity is hysteretic: two samples at or above 0.10 start speaking, seven at or below 0.05 stop it, so "open" and "hearing you" are two stable states rather than a twitch.

The working mark is three 3 pt dots handing emphasis right to left over 0.72 s, static under Reduce Motion.

Only an unclean delivery gets a moment: `copiedOnly`, `insertFailed` and `error` hold 1.2 s with a symbol and a word, click-through, both controls withdrawn. A clean paste and a cancel dismiss at once.

## Motion

- Respect Reduce Motion at every animation boundary, and use the shared quick, standard, and deliberate timing vocabulary.
- The menu animates report and state changes so resizing does not jump under the pointer.
- The overlay waveform and working mark are the only continuous visual signals. Under Reduce Motion the waveform's maximum travel drops to 12 pt and the working mark is static.
- Native console controls keep system motion and focus behavior.
- Resting settings do not animate. A static state stays understandable with all motion disabled.

## Accessibility

- Every interactive element carries a stable, human label.
- State is never color-only. Chips and marks carry words, and Differentiate Without Color adds symbols.
- Explanatory captions are siblings, not folded into a control's accessibility label.
- Where a gesture is the only way to reach a behavior, the same element publishes a named accessibility action, and a completed gesture posts an announcement.

Scene coverage lives in [ui-harness.md](ui-harness.md).
