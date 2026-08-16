# Voiceour design bible

> **Scope:** current product UI. The native console window deliberately follows macOS. The bespoke visual language applies only to the menu popover and recording overlay.

## 1. Product shape

Voiceour has three user-visible surfaces:

1. a menu-bar item and popover for status, last outcome, recovery, start/stop, console, and quit;
2. a compact recording island that follows the active target and stays present through processing;
3. a native macOS window for settings, vocabulary, history, readiness, privacy, and destructive actions.

The first two surfaces are momentary and identity-bearing, so they keep Voiceour's dark glass treatment. The window is long-lived, form-heavy, and keyboard/VoiceOver intensive, so it uses standard macOS navigation and controls rather than imitating them.

## 2. Information architecture

The scene remains:

```swift
Window("Voiceour", id: "main") {
    ConsoleWindowView(coordinator: coordinator)
}
```

`ConsoleWindowView` is a `TabView` containing four grouped forms in this order:

| tab | contents |
| --- | --- |
| **General** | Fn/Globe gesture, stop-after-silence and dwell, deterministic cleanup, mute-during-capture, and a debug-only ASR picker. |
| **Glossary** | project lexicon import, canonical terms and aliases, add/edit/remove, and learned suggestions. |
| **History** | search, day-grouped transcript list, selected transcript detail, copy/delete, and Fix/Teach. |
| **System** | backend/model readiness, microphone and Accessibility capabilities, remediation links, diagnostics copy, clear history, and clear learned vocabulary. |

`ConsoleTab` is the shared identity for selection and the development deep link `--console-section=<general|glossary|history|system>`. An explicit flag wins for that launch; otherwise the last-used tab, stored under `console.last-tab`; otherwise General.

The menu item opens the same `Window("Voiceour", id: "main")`; no second settings scene exists.

## 3. Native window contract

The window uses native `TabView`, `Form(.grouped)`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, searchable list behavior, context menus, and confirmation dialogs.

Do not add custom window chrome, navigation chrome, control skins, cards around every section, or a forced dark appearance. The window must inherit the user's appearance, accent color, keyboard focus behavior, control metrics, VoiceOver semantics, Reduce Motion, Reduce Transparency, and Full Keyboard Access behavior from macOS.

App-owned styling in the window is narrow:

- monospaced text where a value is genuinely code-like;
- semantic state words through `ConsoleStateMark`;
- explanatory sentences through `ConsoleCaption`;
- restrained row spacing through `ConsoleRow`;
- selected transcript fill and transcript detail grouping where native Form alone does not express master/detail state.

These helpers shape content, not chrome. A new window control should begin as a stock macOS control. A custom treatment needs an interaction or semantic requirement that the native control cannot satisfy.

Destructive actions use native confirmation dialogs with a visible title and explicit destructive role. They do not invent an inline two-step control.

### Activation

At idle the menu-bar app uses `.accessory`. While the console is visible it promotes to `.regular` so the user can return through Cmd-Tab, then returns to `.accessory` when the window closes.

`ConsoleWindowView.managesActivationPolicy` must remain false when launch passes `--no-activate` or the process is `.prohibited`. This is required by the screenshot tool and offscreen harness.

## 4. Bespoke visual vocabulary

The surviving bespoke surfaces use one quiet graphite ground and a small semantic signal family:

| role | value |
| --- | --- |
| `Ink.void` | sRGB (0.02, 0.03, 0.05), opaque |
| `Text.high` | sRGB (0.89, 0.91, 0.95) |
| `Text.mid` | sRGB (0.64, 0.71, 0.80) |
| `Text.low` | sRGB (0.51, 0.56, 0.64) |
| cyan | active/live/focus |
| mint | successful outcome |
| amber | degraded or waiting |
| crimson | failure or destructive action |

One signal color should dominate a view. Cyan means live work, not generic decoration. Amber means the app can proceed only after waiting or with a degraded capability. Crimson names an actual failure or destructive choice. Muted system audio is not an error and stays in the cyan/amber family.

Text roles for these surfaces remain the tokenized 10–17 pt ladder in `DesignTokens.swift`, with monospaced eyebrow/micro labels used sparingly. Do not apply tracked uppercase microcopy to the native window merely to make it resemble the popover.

Spacing uses the 4 pt vocabulary (`xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24, `xxl` 32). Control heights are 24, 28, 32, and 40 pt. The recording island's 22 pt visual disc inside a 28 pt hit frame is a deliberate exception, not a new grid unit.

## 5. Menu popover

The popover is 280 pt wide and contains three whitespace-separated blocks:

1. **Status** — state chip, mute state when relevant, Fn keycap, and one current headline.
2. **Report** — failure, last transcript, or delivery outcome; absent when there is nothing to report.
3. **Actions** — one primary dictation action followed by one grouped command list.

The headline has strict precedence: user-facing failure, model acquisition/warmup, then current target. Never display a future target promise beside a failure or completed outcome.

The model's first-run download belongs in the menu because a 1.26 GB wait visible only in System looks like a hung application. Show `Downloading model — N%`, warmup, or the mapped acquisition failure. Recovery uses the failure taxonomy's retry/settings destination.

The last transcript is readable and copyable. Report success and copy-only honestly; do not render raw wire codes. The Fn keycap is a reminder, not an interactive control.

On macOS 26 the standard popover owns system material. On earlier systems and forced-portable harness scenes, the app paints one opaque rounded graphite ground and edge; it must not stack another rounded shell inside AppKit's popover.

## 6. Recording overlay

The panel is 260×80 pt, but only the centered 180×34 pt capsule is visible. The transparent remainder protects an outer shadow from clipping. Place the visible pill 44 pt below the display's visible top edge with a 16 pt screen margin.

The island has three regions:

- **Cancel** at leading edge: quiet rest treatment, explicit “Cancel recording” label.
- **State** in the center: microphone warming, live waveform, or uppercase processing state.
- **Finish / processing mark** at trailing edge: finish while recording; comet while finishing, transcribing, or cleaning.

There is no in-progress transcript line. The stop action always leads to one final decode.

Both discs have a 28 pt hit target and 22 pt visual circle. Finish is visually stronger than cancel because it is the affirmative action. The view and `RecordingOverlayHostingView` must both derive hit regions from `RecordingOverlayMetrics.controlRects`; matching pixels do not prove matching clicks.

The waveform uses 4 pt bars and gaps, 4–20 pt height, a perceptual level exponent of 0.6, and recency opacity. Under Reduce Motion, maximum travel drops to 12 pt rather than removing signal feedback. Microphone warmup is text, not a fake flat waveform.

During processing, the comet replaces the finish control. Reduce Motion lowers its temporal rate and may remove orbiting movement, but the state label remains the primary non-color signal.

The island follows app, display, and Space changes during a session. Manual drag position is stored relative to a display and clamped by the visible pill, never by the transparent shadow box.

### Overlay material

On macOS 26, the island uses `.glassEffect(.regular, in: .capsule)`. The older path uses the behind-window frosted adapter plus the app's tint/rim treatment. Reduce Transparency replaces either with an opaque, high-contrast ground.

The `NSPanel` must remain clear, non-opaque, and shadowless; the visible surface owns its own shape and shadow. Changing those panel properties breaks behind-window material sampling.

## 7. Motion and state

Motion explains state or continuity; it does not decorate resting settings.

- Respect Reduce Motion at every animation boundary.
- Use the shared quick/standard/deliberate timing vocabulary.
- The menu animates report/state changes so resizing does not jump under the pointer.
- The overlay waveform and comet are the only continuous visual signals.
- Native console controls keep system motion and focus behavior.

A static state must remain understandable with all motion disabled.

## 8. Accessibility

- Every interactive element needs a stable, human label and enough help to explain a nonstandard outcome.
- State is never color-only. Chips/marks carry words; Differentiate Without Color adds symbols.
- Explanatory captions are siblings, not folded into a control's accessibility label.
- Selectable transcript text remains selectable and copyable without collapsing child controls into one accessibility element.
- Reduce Transparency, Increase Contrast, Differentiate Without Color, and Reduce Motion must be represented in harness scenes where they alter app-owned drawing.
- Unknown permission is not failure. Accessibility denial is degraded copy-only behavior, not a crimson fatal state. Microphone denial is fatal because no audio can enter the pipeline.

## 9. Harness and visual review

The offscreen harness is authoritative for app-owned paint, geometry, accessibility, lint, and semantic journeys. Portable scenes force the painted path through `RenderOverrides.forceLegacyGlass`; native `os26` scenes release it.

It cannot prove system material. Behind-window `NSVisualEffectView` becomes a flat fill without a desktop sample, while SwiftUI `.glassEffect` is absent from `cacheDisplay`. Use `scripts/console_shot.sh` or a live app for composited-material review, and use [`ui-harness.md`](ui-harness.md) for the measured activation and raster constraints.

Review rules:

1. Prefer an existing token or native control over a new abstraction.
2. Keep the native window native; do not apply the popover palette to it.
3. Add/update a static scene for a new visible state and a semantic flow for a new interaction journey.
4. Read AX/journal diffs before blessing intended changes.
5. Verify bespoke material live when material itself changed.
