import SwiftUI
import Synchronization
import VoiceCore

/// Every colour the console paints, resolved once for an appearance, an accent and a contrast
/// level. Pure value; equality drives SwiftUI invalidation.
///
/// Views read it from `@Environment(\.theme)`, which ``ThemeRoot`` sets at the console and menu
/// roots. Every text-bearing colour is opaque and was measured by ``ThemeGenerator`` on the
/// opaque surfaces it sits on, so no view composes a colour of its own.
struct Theme: Equatable, Sendable {
    /// A status colour and its pill fill. The wash is opaque and the text passes 4.5:1 on it.
    struct Status: Equatable, Sendable {
        let text: Color
        let wash: Color
    }

    struct Shadow: Equatable, Sendable {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    /// `.light` or `.dark`: System is resolved before a theme exists.
    let scheme: ColorScheme
    let accentChoice: ConsoleAccent
    let isIncreasedContrast: Bool

    // Grounds (opaque)
    /// Every tab's background (`Kit.Screen`), list and page columns.
    let ground: Color
    /// The sidebar column, wells (search field, text fields, transcript), recessed groups.
    let sunken: Color
    /// Cards (`Kit.Card`, `Kit.Group`) and resting row plates.
    let raised: Color
    /// Toasts, popover-like panels, menus the kit draws.
    let overlay: Color

    // Interaction (opaque, composited over raised/ground)
    /// The hover wash; also the unfocused selection.
    let hover: Color
    /// Hover at one and a half times its strength.
    let pressed: Color
    /// The focused list's selection and search-match runs: accent-tinted, opaque.
    let selection: Color
    var selectionInactive: Color { hover }

    // Lines
    /// Decorative group separators (1.25–1.6:1; Increase Contrast 3:1).
    let separator: Color
    /// Container outlines: cards, fields.
    let border: Color
    /// Outlines that alone identify a control (≥ 3:1).
    let borderStrong: Color

    // Text
    let text1: Color, text2: Color, text3: Color, textDisabled: Color

    // Accent
    /// Fills: primary buttons, switches (tint), the meter fill, the heat ladder's top.
    let accent: Color
    /// Text and glyphs on `accent` (≥ 4.5:1).
    let onAccent: Color
    let accentHover: Color, accentPressed: Color
    /// Links, selected glyphs, icon tiles' glyphs (≥ 4.5:1 on every surface).
    let accentText: Color
    /// Two-point rings and the selected row's leading bar (≥ 3:1).
    let focusRing: Color
    /// Icon-tile and accent-pill fill: opaque, `accentText` ≥ 4.5:1 on it.
    let accentWash: Color

    // Status (hues pushed ≥ 35° from the accent hue)
    let success: Status, caution: Status, critical: Status, info: Status

    // Data
    /// Five entries: empty, then four quartile steps ending at `accent`.
    let heat: [Color]
    let meterTrack: Color

    // Effects
    /// Light: a soft ink shadow. Dark and Increase Contrast: nil.
    let cardShadow: Shadow?
    /// Dark: the one-pixel top highlight on raised and overlay surfaces (text1 at 6%). Light: nil.
    let topHighlight: Color?
    let scrim: Color

    private init(
        palette p: ThemePalette, scheme: ColorScheme, accentChoice: ConsoleAccent, isIncreasedContrast: Bool
    ) {
        let color = Self.opaque
        let status = Self.status

        self.scheme = scheme
        self.accentChoice = accentChoice
        self.isIncreasedContrast = isIncreasedContrast
        ground = color(p.ground)
        sunken = color(p.sunken)
        raised = color(p.raised)
        overlay = color(p.overlay)
        hover = color(p.hover)
        pressed = color(p.pressed)
        selection = color(p.selection)
        separator = color(p.separator)
        border = color(p.border)
        borderStrong = color(p.borderStrong)
        text1 = color(p.text1)
        text2 = color(p.text2)
        text3 = color(p.text3)
        textDisabled = color(p.textDisabled)
        accent = color(p.accent)
        onAccent = color(p.onAccent)
        accentHover = color(p.accentHover)
        accentPressed = color(p.accentPressed)
        accentText = color(p.accentText)
        focusRing = color(p.focusRing)
        accentWash = color(p.accentWash)
        success = status(p.success)
        caution = status(p.caution)
        critical = status(p.critical)
        info = status(p.info)
        heat = p.heat.map(Self.opaque)
        meterTrack = color(p.meterTrack)
        cardShadow = p.cardShadow.map {
            Shadow(color: Self.translucent($0.color), radius: CGFloat($0.radius), y: CGFloat($0.y))
        }
        topHighlight = p.topHighlight.map(Self.translucent)
        scrim = Self.translucent(p.scrim)
    }

    private static func opaque(_ c: ThemeRGB) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    private static func translucent(_ t: ThemePalette.Translucent) -> Color {
        Color(.sRGB, red: t.color.r, green: t.color.g, blue: t.color.b, opacity: t.opacity)
    }

    private static func status(_ s: ThemePalette.Status) -> Status {
        Status(text: opaque(s.text), wash: opaque(s.wash))
    }

    private struct CacheKey: Hashable {
        let isDark: Bool
        let accent: ConsoleAccent
        let increasedContrast: Bool
        let systemAccent: ThemeRGB?
    }

    /// Generated themes, one per input. The generator is deterministic, so caching changes
    /// nothing but cost: a theme is derived once per input, never per frame.
    private static let cache = Mutex<[CacheKey: Theme]>([:])

    /// The only constructor views use: generator output for these inputs, memoised.
    ///
    /// `systemAccent` is read only for `.system`, which falls back to blue without it.
    static func resolve(
        scheme: ColorScheme, accent: ConsoleAccent, increasedContrast: Bool,
        systemAccent: ThemeRGB? = nil
    ) -> Theme {
        let resolvedScheme: ColorScheme = scheme == .dark ? .dark : .light
        let key = CacheKey(
            isDark: resolvedScheme == .dark,
            accent: accent,
            increasedContrast: increasedContrast,
            systemAccent: accent == .system ? systemAccent : nil
        )
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let palette = ThemeGenerator.palette(
            scheme: resolvedScheme,
            accent: accent,
            increasedContrast: increasedContrast,
            systemAccent: key.systemAccent
        )
        let theme = Theme(
            palette: palette, scheme: resolvedScheme, accentChoice: accent, isIncreasedContrast: increasedContrast)
        cache.withLock { $0[key] = theme }
        return theme
    }

    /// The theme anything outside a ``ThemeRoot`` sees: dark, green, standard contrast.
    static let fallback: Theme = resolve(scheme: .dark, accent: .green, increasedContrast: false)
}

extension EnvironmentValues {
    @Entry var theme: Theme = .fallback
}
