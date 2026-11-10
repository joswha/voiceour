import Foundation
import SwiftUI
import VoiceCore

/// An sRGB colour, components 0...1, opaque unless stated.
struct ThemeRGB: Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
}

/// A colour in OKLCH: perceptual lightness 0...1, chroma, hue in degrees.
struct OKLCH: Equatable, Hashable, Sendable {
    var l: Double
    var c: Double
    var h: Double
}

/// Every colour the generator derives, as plain sRGB values.
///
/// `Theme` wraps this in SwiftUI colours; tests read it directly, because a ratio has to be
/// measured on the numbers the screen receives, not on a `Color` that might resolve differently.
struct ThemePalette: Equatable, Sendable {
    /// A status colour and its opaque pill fill; the text passes on the fill.
    struct Status: Equatable, Sendable {
        var text: ThemeRGB
        var wash: ThemeRGB
        /// The hue the generator settled on after moving it away from the accent.
        var hue: Double
    }

    /// The one kind of colour allowed to stay translucent: effects nothing reads text on.
    struct Translucent: Equatable, Sendable {
        var color: ThemeRGB
        var opacity: Double
    }

    struct Shadow: Equatable, Sendable {
        var color: Translucent
        var radius: Double
        var y: Double
    }

    var isDark: Bool
    var ground: ThemeRGB
    var sunken: ThemeRGB
    var raised: ThemeRGB
    var overlay: ThemeRGB
    var hover: ThemeRGB
    var pressed: ThemeRGB
    var selection: ThemeRGB
    var separator: ThemeRGB
    var border: ThemeRGB
    var borderStrong: ThemeRGB
    var text1: ThemeRGB
    var text2: ThemeRGB
    var text3: ThemeRGB
    var textDisabled: ThemeRGB
    var accent: ThemeRGB
    var onAccent: ThemeRGB
    var accentHover: ThemeRGB
    var accentPressed: ThemeRGB
    var accentText: ThemeRGB
    var focusRing: ThemeRGB
    var accentWash: ThemeRGB
    var success: Status
    var caution: Status
    var critical: Status
    var info: Status
    var heat: [ThemeRGB]
    var meterTrack: ThemeRGB
    var cardShadow: Shadow?
    var topHighlight: Translucent?
    var scrim: Translucent

    /// The opaque surfaces text is set on, which every text role is solved against.
    var textSurfaces: [ThemeRGB] { [ground, sunken, raised, overlay, hover, pressed, selection] }

    /// Every opaque colour, for gamut checks.
    var allOpaque: [ThemeRGB] {
        [
            ground, sunken, raised, overlay, hover, pressed, selection, separator, border, borderStrong,
            text1, text2, text3, textDisabled, accent, onAccent, accentHover, accentPressed, accentText,
            focusRing, accentWash, meterTrack,
        ]
            + [success, caution, critical, info].flatMap { [$0.text, $0.wash] }
            + heat
    }
}

/// Pure colour math: one base, one accent and a contrast level in, every console colour out,
/// each text-bearing pair measured on the opaque colours actually painted.
///
/// Deterministic by construction (fixed step sizes, fixed iteration counts, no randomness), so
/// the same inputs give the same palette on every Mac and every run.
enum ThemeGenerator {
    // MARK: Inputs

    /// The fixed ground each appearance starts from, and how far its contrast ladder spreads.
    private struct Base {
        let color: OKLCH
        let contrast: Double
    }

    /// The dark ground: near-black with a cool cast.
    private static let darkBase = Base(color: OKLCH(l: 0.150, c: 0.014, h: 258), contrast: 0.45)
    /// The light ground: cool near-white.
    private static let lightBase = Base(color: OKLCH(l: 0.985, c: 0.006, h: 250), contrast: 0.50)
    /// What Increase Contrast adds to the contrast level.
    private static let increasedContrastBoost = 0.30

    /// The accent each named choice asks for. The generator moves lightness only when a ratio fails.
    static func request(for accent: ConsoleAccent, systemAccent: ThemeRGB?) -> OKLCH {
        switch accent {
        case .system: systemAccent.map(oklch(from:)) ?? request(for: .blue, systemAccent: nil)
        case .green: OKLCH(l: 0.86, c: 0.19, h: 147)
        case .blue: OKLCH(l: 0.62, c: 0.19, h: 258)
        case .purple: OKLCH(l: 0.62, c: 0.20, h: 300)
        case .pink: OKLCH(l: 0.68, c: 0.20, h: 350)
        case .red: OKLCH(l: 0.63, c: 0.21, h: 25)
        case .orange: OKLCH(l: 0.74, c: 0.17, h: 55)
        case .yellow: OKLCH(l: 0.87, c: 0.17, h: 95)
        case .graphite: OKLCH(l: 0.70, c: 0.012, h: 258)
        }
    }

    private enum StatusKind: CaseIterable {
        case success, caution, critical, info

        var hue: Double {
            switch self {
            case .success: 152
            case .caution: 78
            case .critical: 27
            case .info: 228
            }
        }

        var chroma: Double {
            switch self {
            case .success, .caution: 0.15
            case .critical: 0.17
            case .info: 0.13
            }
        }
    }

    /// How far a status hue must sit from the accent's, so "selected" never reads as "succeeded".
    private static let statusHueGap = 35.0
    /// Below this chroma an accent has no hue worth avoiding (graphite).
    private static let achromaticChroma = 0.04

    // MARK: Palette

    static func palette(
        scheme: ColorScheme,
        accent accentChoice: ConsoleAccent,
        increasedContrast: Bool,
        systemAccent: ThemeRGB? = nil
    ) -> ThemePalette {
        let isDark = scheme == .dark
        let base = isDark ? darkBase : lightBase
        let k = base.contrast + (increasedContrast ? increasedContrastBoost : 0)
        let dir: Double = isDark ? 1 : -1
        let l0 = base.color.l
        let c0 = base.color.c
        let h0 = base.color.h
        let delta = isDark ? lerp(0.030, 0.050, k) : lerp(0.018, 0.030, k)
        func surface(_ l: Double) -> ThemeRGB { srgb(OKLCH(l: l, c: c0, h: h0)) }

        // Surfaces: dark elevates with lighter fills and sinks the sidebar; light lifts cards
        // to white and greys the sidebar, the way Mail does.
        let ground = surface(l0)
        let sunken = surface(isDark ? l0 - 0.5 * delta : l0 - 1.2 * delta)
        let raised = surface(l0 + delta)
        let overlay = surface(isDark ? l0 + 2 * delta : l0 + 1.5 * delta)
        let hover = surface(isDark ? l0 + 1.6 * delta : l0 - 1.8 * delta)
        let pressed = surface(isDark ? l0 + 2.4 * delta : l0 - 2.7 * delta)
        let containers = [ground, sunken, raised, overlay]

        // Accent fill and the ink on it.
        var requested = request(for: accentChoice, systemAccent: systemAccent)
        let onTarget = increasedContrast ? 7.0 : 4.5
        let ink = srgb(OKLCH(l: 0.17, c: 0.012, h: h0))
        let white = ThemeRGB(r: 1, g: 1, b: 1)
        var fill = solveFill(requested, onTarget: onTarget, white: white, ink: ink, against: containers)
        if !isDark, isYellowFamily(requested.h), fill.l < 0.55 {
            requested.h -= 12
            fill = solveFill(requested, onTarget: onTarget, white: white, ink: ink, against: containers)
        }
        let accentHue = requested.h

        // Selection: the accent over `raised`, as strong as the range allows while the darkest
        // (or lightest) possible text still clears text1's floor on it.
        let text1Floor = increasedContrast ? 15.1 : 11.1
        let textEnd = isDark ? white : ThemeRGB(r: 0, g: 0, b: 0)
        let selectionMax = isDark ? 0.26 : 0.17
        var selection = raised
        for step in 0...Int((selectionMax / 0.005).rounded()) {
            let alpha = selectionMax - Double(step) * 0.005
            let candidate = composite(fill.rgb, over: raised, alpha: alpha)
            if contrast(textEnd, candidate) >= text1Floor {
                selection = candidate
                break
            }
        }

        let textBackgrounds = [ground, sunken, raised, overlay, hover, pressed, selection]
        let text1 = solve(
            OKLCH(l: l0, c: 0.6 * c0, h: h0), against: textBackgrounds,
            target: increasedContrast ? 15.1 : lerp(11, 15, k), direction: dir)
        let text2 = solve(
            OKLCH(l: l0, c: 1.2 * c0, h: h0), against: textBackgrounds,
            target: lerp(5.6, 7.5, k), direction: dir)
        let text3 = solve(
            OKLCH(l: l0, c: 1.4 * c0, h: h0), against: textBackgrounds,
            target: increasedContrast ? 5.6 : 4.6, direction: dir)
        let textDisabled = solve(
            OKLCH(l: l0, c: 1.4 * c0, h: h0), against: containers,
            target: lerp(2.3, 3.0, k), direction: dir)

        // Lines. Increase Contrast moves each line up a rung: separators draw at border
        // strength, borders at the strength that alone identifies a control.
        let separator = solve(
            OKLCH(l: l0, c: c0, h: h0), against: containers,
            target: increasedContrast ? 3.05 : lerp(1.25, 1.6, k), direction: dir)
        let border = solve(
            OKLCH(l: l0, c: c0, h: h0), against: containers,
            target: increasedContrast ? 3.05 : lerp(1.7, 3.0, k), direction: dir)
        let borderStrong = solve(
            OKLCH(l: l0, c: c0, h: h0), against: containers + [hover],
            target: increasedContrast ? 4.55 : 3.05, direction: dir)
        let meterTrack = solve(
            OKLCH(l: l0, c: c0, h: h0), against: [ground, sunken, raised],
            target: increasedContrast ? 3.05 : lerp(1.5, 2.0, k), direction: dir)

        // Accent roles.
        let accentWash = composite(fill.rgb, over: raised, alpha: isDark ? 0.16 : 0.10)
        let accentText = solve(
            OKLCH(l: fill.l, c: requested.c, h: accentHue), against: textBackgrounds + [accentWash],
            target: increasedContrast ? 7.0 : 4.6, direction: dir)
        let focusRing = solve(
            OKLCH(l: fill.l, c: requested.c, h: accentHue), against: textBackgrounds,
            target: increasedContrast ? 4.5 : 3.2, direction: dir)
        // Hover and pressed step away from the ink on the fill, so its contrast only grows.
        let stateStep: Double = fill.on == white ? -0.04 : 0.04
        let accentHover = srgb(OKLCH(l: clampUnit(fill.l + stateStep), c: requested.c, h: accentHue))
        let accentPressed = srgb(OKLCH(l: clampUnit(fill.l + 2 * stateStep), c: requested.c, h: accentHue))

        // Status pairs: the wash is fixed from the starting colour, then the text is solved on
        // every surface and on its own wash.
        let statusTarget = increasedContrast ? 7.0 : 4.6
        let statusStart = isDark ? 0.76 : 0.52
        let washAlpha = isDark ? 0.16 : 0.10
        func status(_ kind: StatusKind) -> ThemePalette.Status {
            let hue = statusHue(kind, accentHue: accentHue, accentChroma: requested.c)
            let reference = srgb(OKLCH(l: statusStart, c: kind.chroma, h: hue))
            let wash = composite(reference, over: raised, alpha: washAlpha)
            let text = solve(
                OKLCH(l: statusStart, c: kind.chroma, h: hue), against: textBackgrounds + [wash],
                target: statusTarget, direction: dir)
            return ThemePalette.Status(text: text, wash: wash, hue: hue)
        }

        // Heat: the empty cell is the hover wash; four quartile steps climb from `raised` to
        // the accent in lightness and chroma at the accent's hue.
        let raisedLCH = oklch(from: raised)
        let fillLCH = oklch(from: fill.rgb)
        var heat = [hover]
        for step in 1...3 {
            let t = Double(step) * 0.25
            heat.append(
                srgb(
                    OKLCH(
                        l: lerp(raisedLCH.l, fillLCH.l, t),
                        c: lerp(raisedLCH.c, fillLCH.c, t),
                        h: accentHue)))
        }
        heat.append(fill.rgb)

        let shadow: ThemePalette.Shadow? =
            isDark || increasedContrast
            ? nil
            : ThemePalette.Shadow(
                color: ThemePalette.Translucent(color: srgb(OKLCH(l: 0.25, c: 0.02, h: h0)), opacity: 0.12),
                radius: 8,
                y: 2)
        let topHighlight: ThemePalette.Translucent? =
            isDark && !increasedContrast ? ThemePalette.Translucent(color: text1, opacity: 0.06) : nil

        return ThemePalette(
            isDark: isDark,
            ground: ground,
            sunken: sunken,
            raised: raised,
            overlay: overlay,
            hover: hover,
            pressed: pressed,
            selection: selection,
            separator: separator,
            border: border,
            borderStrong: borderStrong,
            text1: text1,
            text2: text2,
            text3: text3,
            textDisabled: textDisabled,
            accent: fill.rgb,
            onAccent: fill.on,
            accentHover: accentHover,
            accentPressed: accentPressed,
            accentText: accentText,
            focusRing: focusRing,
            accentWash: accentWash,
            success: status(.success),
            caution: status(.caution),
            critical: status(.critical),
            info: status(.info),
            heat: heat,
            meterTrack: meterTrack,
            cardShadow: shadow,
            topHighlight: topHighlight,
            scrim: ThemePalette.Translucent(color: ThemeRGB(r: 0, g: 0, b: 0), opacity: isDark ? 0.40 : 0.25)
        )
    }

    // MARK: Solvers

    private struct Fill {
        let rgb: ThemeRGB
        let l: Double
        let on: ThemeRGB
    }

    /// The lightness nearest the request at which white or ink reads on the fill and the fill
    /// stands out from every container. The request itself wins whenever it passes.
    private static func solveFill(
        _ requested: OKLCH, onTarget: Double, white: ThemeRGB, ink: ThemeRGB, against containers: [ThemeRGB]
    ) -> Fill {
        for step in 0...500 {
            let offsets = step == 0 ? [0.0] : [Double(step) * 0.002, -Double(step) * 0.002]
            for offset in offsets {
                let l = requested.l + offset
                guard l >= 0, l <= 1 else { continue }
                let rgb = srgb(OKLCH(l: l, c: requested.c, h: requested.h))
                guard minContrast(rgb, containers) >= 3 else { continue }
                for on in [white, ink] where contrast(rgb, on) >= onTarget {
                    return Fill(rgb: rgb, l: l, on: on)
                }
            }
        }
        // Unreachable for these bases (a white or black fill always passes); kept total.
        let rgb = srgb(requested)
        return Fill(rgb: rgb, l: requested.l, on: contrast(rgb, white) >= contrast(rgb, ink) ? white : ink)
    }

    /// The brief's monotone search: step lightness away from the ground until the colour clears
    /// `target` on every background, mapping chroma into gamut at each step. The endpoint is
    /// white or black, so it always ends.
    static func solve(_ start: OKLCH, against backgrounds: [ThemeRGB], target: Double, direction: Double)
        -> ThemeRGB
    {
        for step in 0...500 {
            let l = start.l + Double(step) * 0.002 * direction
            guard l > 0, l < 1 else { break }
            let candidate = srgb(OKLCH(l: l, c: start.c, h: start.h))
            if minContrast(candidate, backgrounds) >= target { return candidate }
        }
        return direction > 0 ? ThemeRGB(r: 1, g: 1, b: 1) : ThemeRGB(r: 0, g: 0, b: 0)
    }

    /// A status hue moved at least 35° from the accent's, toward the side it already sits on
    /// unless that lands beside another status hue.
    private static func statusHue(_ kind: StatusKind, accentHue: Double, accentChroma: Double) -> Double {
        guard accentChroma >= achromaticChroma else { return kind.hue }
        let offset = signedHueDifference(kind.hue, accentHue)
        guard abs(offset) < statusHueGap else { return kind.hue }
        let others = StatusKind.allCases.filter { $0 != kind }.map(\.hue)
        func clearance(_ hue: Double) -> Double {
            others.map { abs(signedHueDifference(hue, $0)) }.min() ?? 180
        }
        let sameSide = normalizedHue(accentHue + (offset >= 0 ? statusHueGap : -statusHueGap))
        let otherSide = normalizedHue(accentHue + (offset >= 0 ? -statusHueGap : statusHueGap))
        if clearance(sameSide) >= statusHueGap { return sameSide }
        if clearance(otherSide) >= statusHueGap { return otherSide }
        return clearance(sameSide) >= clearance(otherSide) ? sameSide : otherSide
    }

    /// Yellow hues lose their identity as they darken; light mode leans them toward orange.
    private static func isYellowFamily(_ hue: Double) -> Bool {
        (85...105).contains(normalizedHue(hue))
    }

    // MARK: Colour math

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private static func clampUnit(_ x: Double) -> Double { min(max(x, 0), 1) }

    private static func normalizedHue(_ h: Double) -> Double {
        let r = h.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    private static func signedHueDifference(_ a: Double, _ b: Double) -> Double {
        let d = normalizedHue(a - b)
        return d > 180 ? d - 360 : d
    }

    private static func decode(_ c: Double) -> Double {
        let v = clampUnit(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ x: Double) -> Double {
        let v = clampUnit(x)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// WCAG 2.x relative luminance, with the same transfer function the harness lint uses.
    static func luminance(_ c: ThemeRGB) -> Double {
        0.2126 * decode(c.r) + 0.7152 * decode(c.g) + 0.0722 * decode(c.b)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func minContrast(_ c: ThemeRGB, _ backgrounds: [ThemeRGB]) -> Double {
        backgrounds.map { contrast(c, $0) }.min() ?? 21
    }

    /// Source-over in display sRGB, which is what Core Animation blends; the result is opaque.
    static func composite(_ top: ThemeRGB, over bottom: ThemeRGB, alpha: Double) -> ThemeRGB {
        ThemeRGB(
            r: alpha * top.r + (1 - alpha) * bottom.r,
            g: alpha * top.g + (1 - alpha) * bottom.g,
            b: alpha * top.b + (1 - alpha) * bottom.b)
    }

    private static func linear(_ c: OKLCH) -> (r: Double, g: Double, b: Double) {
        let hr = c.h * .pi / 180
        let a = c.c * cos(hr)
        let b = c.c * sin(hr)
        // The cone responses' cube roots (Ottosson's l_, m_, s_), then the responses.
        let lRoot = c.l + 0.3963377774 * a + 0.2158037573 * b
        let mRoot = c.l - 0.1055613458 * a - 0.0638541728 * b
        let sRoot = c.l - 0.0894841775 * a - 1.2914855480 * b
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func inGamut(_ c: OKLCH) -> Bool {
        let tolerance = 1e-6
        let lin = linear(c)
        return [lin.r, lin.g, lin.b].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
    }

    /// OKLCH to sRGB, mapped into gamut by reducing chroma at constant lightness and hue
    /// (clipping channels would shift both).
    static func srgb(_ color: OKLCH) -> ThemeRGB {
        let l = clampUnit(color.l)
        if l >= 1 { return ThemeRGB(r: 1, g: 1, b: 1) }
        if l <= 0 { return ThemeRGB(r: 0, g: 0, b: 0) }
        var mapped = OKLCH(l: l, c: max(color.c, 0), h: color.h)
        if !inGamut(mapped) {
            var low = 0.0
            var high = mapped.c
            for _ in 0..<30 {
                let mid = (low + high) / 2
                if inGamut(OKLCH(l: l, c: mid, h: color.h)) { low = mid } else { high = mid }
            }
            mapped.c = low
        }
        let lin = linear(mapped)
        return ThemeRGB(r: encode(lin.r), g: encode(lin.g), b: encode(lin.b))
    }

    static func oklch(from rgb: ThemeRGB) -> OKLCH {
        let r = decode(rgb.r)
        let g = decode(rgb.g)
        let b = decode(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return OKLCH(l: lightness, c: (a * a + bb * bb).squareRoot(), h: normalizedHue(atan2(bb, a) * 180 / .pi))
    }
}
