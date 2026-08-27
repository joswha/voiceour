# Recording island redesign — design

Date: 2026-08-27. Status: approved, implementing.

## The problem

The island showed a soft rectangular grey halo around the capsule, and its contents
read as washed out. Two independent causes, both on the macOS 26 path.

### The halo

`RecordingOverlayView.island` applied `.glassEffect(.regular, in: .capsule)` and then
wrapped the result in `islandShadow(_:)`, which stacked two SwiftUI drop shadows:
`Shadow.overlayOuter` (black 0.26, radius 18, y 6) and `Shadow.overlayInner`
(black 0.18, radius 4, y 1).

`.shadow` cannot recover the capsule's alpha from a glass effect, so Core Animation cast
both shadows from the view's **rectangular** layer bounds. At the island's 180x34 measure
that is a 216x76 blur — the smudge that was reported. The tokens are pure black because
they were authored for the legacy near-black painted pill, so over a light desktop they
read as dirty haze rather than elevation.

Two further facts make this a straightforward deletion rather than a trade:

- Liquid Glass already casts its own **adaptive** shadow. WWDC25 session 219: shadow
  opacity rises over text and falls over solid light backgrounds, and larger or morphing
  glass casts a deeper one. The comment at `RecordingOverlayView.swift:89` claiming "the
  system glass brings none of its own" was simply wrong.
- Nothing required the two-layer shadow. The source cited `Bible §6.4`, `§21.3 rule 2`,
  `spec §7.1`, `§1.5`, `§5.16` and `§21.3 ¶4`. `docs/design-bible.md` is flat and
  un-numbered and none of those clauses exist anywhere in the repository. Those citations
  are removed by this change.

Apple documents no shape-conformant custom-shadow recipe for glass, and `.shadow` over
`.glassEffect` is undocumented composition. The correct treatment is therefore no app
shadow at all on the glass path.

### The wash-out

The island's foreground palette was authored for a near-black pill and is applied
unchanged on top of macOS 26's adaptive glass:

| token | value | on the painted pill | on light adaptive glass |
| --- | --- | --- | --- |
| `Text.high` | sRGB(.89,.91,.95) | near-white on near-black | near-white on near-white |
| `Signal.cyan` | sRGB(.62,.86,1) | pastel on near-black | pastel on near-white |
| `Signal.mint` | sRGB(.66,.96,.82) | pastel on near-black | pastel on near-white |

The comment at `RecordingOverlayView.swift:270-272` records a contrast measurement taken
"against the pill's own glass" — that is, against the dark painted ground. It was never
re-measured against the material the flagship path actually renders.

### The signal

The island exists to say "I am listening to your voice", and it said it with eleven bars
resting at their 4pt minimum in a 34pt capsule — a row of near-invisible dots, in a
pastel that fails on a light ground. The single most important thing this surface does was
its least legible element.

## Decisions

Three were the user's to make and were made explicitly:

1. **Scale and character:** keep the 180x34 island and the 260x80 panel. All personality
   moves into the signal. Rejected: a 280x52 tinted surface (heavy geometry churn across
   placement, mouse routing, harness literals and placement tests; whole-surface phase
   tint fights "one signal colour dominates a view"), and a three-droplet
   `GlassEffectContainer` morph (unverifiable offscreen, and macOS 14/15 cannot reproduce
   glass merging, so the fallback would be a different design).
2. **Outcome feedback:** report only when delivery was *not* clean. A normal paste stays
   silent because the text arriving in the target app is already the confirmation.
3. **Working indicator:** replace the random-emoji comet with a deterministic mark drawn
   from the meter's own vocabulary.

## The design

### Surface

One ground per path, chosen once and passed down as `RecordingOverlaySurface`:

| case | ground | when |
| --- | --- | --- |
| `.systemGlass` | `.glassEffect(.regular, in: .capsule)`, untinted | macOS 26, not forced legacy, not Reduce Transparency |
| `.painted` | behind-window frost + `glassTint` + specular rim + definition rim | macOS 14/15, or `RenderOverrides.forceLegacyGlass` |
| `.opaque` | `Ink.void` + `a11y.lineEdge` | Reduce Transparency, on every OS |

Rules that hold on every path:

- **No app-drawn shadow anywhere.** `islandShadow(_:)` is deleted, along with all four
  `.shadow` calls in `capsuleSurface`. On `.systemGlass` the system's adaptive shadow is
  the elevation. On `.painted` and `.opaque` the frost, tint and two rims already give the
  silhouette its separation; a black blur was never what made those paths readable.
- **The panel stays 260x80.** Its transparent margin was bleed for the app's outer
  shadow; it is now bleed for the *system's*, which needs room outside the capsule or it
  clips at the window edge. Keeping it also means this change touches no placement
  conversion, no mouse-routing rect, no harness scene literal and no placement test.
- **The glass sits behind the whole row.** Previously `.glassEffect` was applied to the
  centre slot only and the two control discs were `.overlay` siblings composited above
  it, so the glyphs were not content *on* the material and did not receive its automatic
  vibrancy treatment. The effect now applies to the assembled 180x34 row.
- No `.tint`, no rim, no `.interactive()` on the glass. `.interactive()` was already
  measured inert here: every press outside the two control rects is taken by
  `RecordingOverlayHostingView.mouseDown` for `window.performDrag` without calling
  `super`, so SwiftUI never sees it.

### Foreground policy

This is the part that fixes the wash-out, and it differs by ground because the grounds
differ in luminance.

- On `.painted` and `.opaque` the ground is always near-black, so the existing
  light-on-dark palette is correct and unchanged.
- On `.systemGlass` the ground is adaptive and may be light or dark. Text and neutral
  glyphs therefore use the system semantic colours `.primary` and `.secondary`, which is
  what lets SwiftUI's documented vibrancy keep them legible; an explicit sRGB literal is
  precisely what defeats that treatment.
- Where a hue must survive because it carries meaning, it uses a mid-tone drawn from a new
  `VoiceourPalette.OnGlass` namespace instead of the pastel `Signal` value. Each is
  measured to clear 3:1 against **both** white and black, so one value works whichever way
  the material adapts:

  | token | sRGB | vs white | vs black |
  | --- | --- | --- | --- |
  | `OnGlass.cyan` | (0.03, 0.49, 0.71) | 4.56:1 | 4.61:1 |
  | `OnGlass.mint` | (0.05, 0.53, 0.36) | 4.52:1 | 4.64:1 |
  | `OnGlass.amber` | (0.66, 0.40, 0.02) | 4.59:1 | 4.57:1 |
  | `OnGlass.crimson` | (0.90, 0.12, 0.20) | 4.58:1 | 4.59:1 |

### The signal

The meter is the island's whole message, so it gets the redesign's attention.

- Eleven bars, 4pt wide, 4pt apart, 84pt total — the footprint is unchanged.
- **Bars rest at 8pt, not 4pt.** An even row at 8pt is a visible, deliberate mark: it
  says the microphone is open and the capture path is live. Height is
  `8 + pow(clamp(level), 0.6) * (max - 8)`, so 8...20pt, and 8...12pt under Reduce Motion.
- Opacity floor rises from 0.45 to 0.78, and to 0.92 under Increase Contrast.
- **Deleted:** the `.plusLighter` bloom, its 1.2pt blur, the `.drawingGroup()` that existed
  only to flatten those two passes, and the recency ramp. All three were decoration
  compensating for a mark that was too faint; a legible mark does not need a glow.
- **Voice-activity hysteresis.** The raw level made the resting row twitch on a room's
  noise floor. `listening` becomes `speaking` after 2 consecutive samples >= 0.10 (80ms at
  25Hz) and returns after 7 consecutive samples <= 0.05 (280ms). Levels between the two
  thresholds hold the current state. This gives "open" and "hearing you" a stable
  boundary instead of a jitter.

### Working indicator

`FrostedCometIndicator` is replaced by `RecordingWorkMark`, in the same 28x28 trailing
slot, still hidden from accessibility because the centre readout already names the work.

Three 3pt dots hand emphasis right -> centre -> left over 0.72s, so the motion reads as
speech being drawn into the island. Under Reduce Motion the three dots are static and
equally bright.

Deleted with it: the 40-glyph emoji pool, `dominantHueSaturation` and its 28x28
`NSBitmapImageRep` allocation and pixel scan, the `AppKit` import, the 96-quad Canvas
ribbon, the head glow and bloom, the wall-clock orbit, `RecordingOverlayModel.cometHead`,
`RenderOverrides.cometHead` and its pinned harness fixture.

### Outcome

`RecordingOverlayController.bind` called `model.update(state)` and then `model.reset()`
for any non-active state before hiding, so `error`, `insertFailed` and `copiedOnly` all
faded out as a blank capsule. A failed dictation was pixel-identical to a successful one.

Only unclean deliveries now get a moment:

| state | symbol | word | dwell |
| --- | --- | --- | --- |
| `copiedOnly` | `doc.on.doc` | `COPIED` | 1.2s |
| `insertFailed` | `exclamationmark.triangle` | `COPIED` | 1.2s |
| `error` | `exclamationmark.triangle` | `FAILED` | 1.2s |
| `pasteAttempted` | — | — | none, dismiss at once |
| `cancelled` | — | — | none, dismiss at once |

`pasteAttempted` stays silent because the transcript appearing in the target app is the
confirmation, and it is the overwhelmingly common path — an island that lingered after
every utterance would be in the way. `cancelled` stays silent because the user just asked
for it.

Both controls are removed during the dwell and the panel is click-through, so the moment
cannot swallow a click meant for the app underneath. The controller latches the terminal
state, schedules a cancellable dismissal, and calls `model.reset()` only after
`orderOut`; a new session cancels that task and bumps the visibility token, so a stale
dismissal cannot hide a newer dictation. `insertFailed` announces that the paste failed
and the transcript is on the clipboard, never a raw insertion token. An `error` uses the
coordinator's published `UserFacingDictationFailure` sentence — the same cause the menu
shows — and falls back to the code's user-facing row only when the sidecar stated nothing
more precise. The stable AX value and the app-level announcement consume that one outcome
presentation, so they cannot disagree.

## Accessibility

- One stable `Dictation status` static-text node keeps carrying the readout, with values
  for warm-up, listening, speaking, each processing phase and each outcome.
- Bars, the work mark and outcome symbols stay AX-hidden; the status node speaks.
- Reduce Motion: phase changes are immediate, bar travel caps at 12pt, the work mark
  freezes. The outcome dwell survives, because it is reading time and not motion.
- Increase Contrast: raises the bar floor to 0.92 and keeps the existing 1pt edges.
- Differentiate Without Color: every outcome pairs a distinct symbol with a distinct word,
  so hue is never the only carrier.
- Reduce Transparency outranks both glass paths on every OS.

## Verification

The offscreen harness cannot rasterise `.glassEffect` or `.shadow` — `cacheDisplay` drops
both — so no golden can prove either the halo's absence or the material's appearance.
Goldens still cover what they can: the AX tree, layout, and the app-drawn signal.

- `make build`, `make format-check`, `make check-docs`, `make test`.
- `make ui-snap` and `make ui-snap-os26`; review `.ax.diff` before blessing.
- `make ui-flow` as a regression check; the two overlay journals are semantic and should
  not move.
- On-screen proof in the signed app on macOS 26 over a white backdrop, a dark backdrop and
  dense text, plus the Reduce Transparency, Reduce Motion and Increase Contrast paths.
  This is the only evidence that counts for the material itself.

## Evidence gap

Apple does not document `glassEffect` rendering in a non-key panel while the owning app is
inactive, which is exactly this panel's situation, and glass is documented to recede when a
window loses focus. This design contains that risk rather than decorating around it: if
`.regular` proves too recessive in the real inactive panel, the answer is to re-measure on
screen, not to pile tint and shadow back on.
