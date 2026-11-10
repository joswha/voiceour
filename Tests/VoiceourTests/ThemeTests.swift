import SwiftUI
import Testing
import VoiceCore

@testable import Voiceour

/// Every generated theme must keep the ratios the console's legibility rests on, on the opaque
/// colours actually painted, for every accent, both appearances and Increase Contrast.
@Suite("Theme generator")
struct ThemeTests {
    private static let schemes: [ColorScheme] = [.dark, .light]

    private func ratio(_ color: ThemeRGB, on backgrounds: [ThemeRGB]) -> Double {
        ThemeGenerator.minContrast(color, backgrounds)
    }

    /// The surfaces text is set on, as the spec lists them.
    private func textSurfaces(_ p: ThemePalette) -> [ThemeRGB] {
        [p.ground, p.sunken, p.raised, p.overlay, p.hover, p.selection]
    }

    private func expectRatios(_ p: ThemePalette, increasedContrast: Bool, _ context: String) {
        let surfaces = textSurfaces(p)
        #expect(ratio(p.text1, on: surfaces) >= (increasedContrast ? 15 : 11), "text1 \(context)")
        #expect(ratio(p.text2, on: surfaces) >= 5.6, "text2 \(context)")
        #expect(ratio(p.text3, on: surfaces) >= 4.5, "text3 \(context)")
        #expect(ratio(p.text1, on: [p.pressed]) >= (increasedContrast ? 15 : 11), "text1 on pressed \(context)")
        #expect(ratio(p.accentText, on: surfaces + [p.accentWash]) >= 4.5, "accentText \(context)")
        #expect(ThemeGenerator.contrast(p.onAccent, p.accent) >= 4.5, "onAccent \(context)")
        #expect(ThemeGenerator.contrast(p.onAccent, p.accentHover) >= 4.5, "onAccent on hover \(context)")
        #expect(ThemeGenerator.contrast(p.onAccent, p.accentPressed) >= 4.5, "onAccent on pressed \(context)")
        #expect(ratio(p.accent, on: [p.ground, p.sunken, p.raised, p.overlay]) >= 3, "accent fill \(context)")
        #expect(ratio(p.focusRing, on: surfaces) >= 3, "focusRing \(context)")
        #expect(ratio(p.borderStrong, on: [p.ground, p.sunken, p.raised, p.overlay]) >= 3, "borderStrong \(context)")
        for (name, status) in [
            ("success", p.success), ("caution", p.caution), ("critical", p.critical), ("info", p.info),
        ] {
            #expect(ratio(status.text, on: [p.ground, p.raised, status.wash]) >= 4.5, "\(name) \(context)")
        }
        if increasedContrast {
            #expect(ratio(p.separator, on: [p.ground, p.raised]) >= 3, "separator \(context)")
            #expect(p.cardShadow == nil, "shadow \(context)")
            #expect(p.topHighlight == nil, "highlight \(context)")
        }
    }

    private func expectInGamut(_ p: ThemePalette, _ context: String) {
        for color in p.allOpaque {
            for component in [color.r, color.g, color.b] {
                #expect(component.isFinite && component >= 0 && component <= 1, "gamut \(context): \(color)")
            }
        }
        #expect(p.heat.count == 5, "heat count \(context)")
        #expect(p.heat.first == p.hover, "heat empty \(context)")
        #expect(p.heat.last == p.accent, "heat top \(context)")
    }

    @Test(arguments: ConsoleAccent.allCases, [false, true])
    func everyRatioHolds(accent: ConsoleAccent, increasedContrast: Bool) {
        for scheme in Self.schemes {
            let p = ThemeGenerator.palette(scheme: scheme, accent: accent, increasedContrast: increasedContrast)
            let context = "\(accent) \(scheme) IC=\(increasedContrast)"
            expectRatios(p, increasedContrast: increasedContrast, context)
            expectInGamut(p, context)
            #expect(p.isDark == (scheme == .dark), "scheme \(context)")
        }
    }

    /// Accents a Mac can report that no named choice covers, including the gamut's corners.
    @Test(arguments: [
        ThemeRGB(r: 1, g: 1, b: 0), ThemeRGB(r: 0, g: 0, b: 0), ThemeRGB(r: 1, g: 1, b: 1),
        ThemeRGB(r: 0, g: 0, b: 1), ThemeRGB(r: 0, g: 1, b: 1), ThemeRGB(r: 1, g: 0, b: 0),
        ThemeRGB(r: 0.97, g: 0.31, b: 0.62), ThemeRGB(r: 0, g: 0.48, b: 1), ThemeRGB(r: 0.9, g: 0.8, b: 0.1),
    ])
    func everyRatioHoldsForAnySystemAccent(systemAccent: ThemeRGB) {
        for scheme in Self.schemes {
            for increasedContrast in [false, true] {
                let p = ThemeGenerator.palette(
                    scheme: scheme, accent: .system, increasedContrast: increasedContrast, systemAccent: systemAccent)
                let context = "system \(systemAccent) \(scheme) IC=\(increasedContrast)"
                expectRatios(p, increasedContrast: increasedContrast, context)
                expectInGamut(p, context)
            }
        }
    }

    @Test func generationIsDeterministic() {
        for accent in ConsoleAccent.allCases {
            for scheme in Self.schemes {
                for increasedContrast in [false, true] {
                    let first = ThemeGenerator.palette(
                        scheme: scheme, accent: accent, increasedContrast: increasedContrast)
                    let second = ThemeGenerator.palette(
                        scheme: scheme, accent: accent, increasedContrast: increasedContrast)
                    #expect(first == second)
                    #expect(
                        Theme.resolve(scheme: scheme, accent: accent, increasedContrast: increasedContrast)
                            == Theme.resolve(scheme: scheme, accent: accent, increasedContrast: increasedContrast))
                }
            }
        }
        #expect(Theme.fallback == Theme.resolve(scheme: .dark, accent: .green, increasedContrast: false))
        #expect(Theme.fallback.scheme == .dark)
        #expect(Theme.fallback.accentChoice == .green)
        #expect(!Theme.fallback.isIncreasedContrast)
    }

    /// The System accent is the named path fed a measured colour: given the sRGB a named accent
    /// resolves to, it lands on that accent's palette.
    @Test(arguments: ConsoleAccent.allCases.filter { $0 != .system })
    func aSystemAccentBehavesLikeTheNamedOne(named: ConsoleAccent) {
        let systemAccent = ThemeGenerator.srgb(ThemeGenerator.request(for: named, systemAccent: nil))
        for scheme in Self.schemes {
            for increasedContrast in [false, true] {
                let expected = ThemeGenerator.palette(
                    scheme: scheme, accent: named, increasedContrast: increasedContrast)
                let actual = ThemeGenerator.palette(
                    scheme: scheme, accent: .system, increasedContrast: increasedContrast, systemAccent: systemAccent)
                let pairs = zip(expected.allOpaque, actual.allOpaque)
                let drift = pairs.map { max(abs($0.r - $1.r), abs($0.g - $1.g), abs($0.b - $1.b)) }.max() ?? 0
                #expect(drift < 0.004, "\(named) \(scheme) IC=\(increasedContrast): drift \(drift)")
                #expect(expected.onAccent == actual.onAccent, "\(named) \(scheme) IC=\(increasedContrast)")
            }
        }
    }

    @Test func aSystemAccentWithoutAColourFallsBackToBlue() {
        for scheme in Self.schemes {
            #expect(
                ThemeGenerator.palette(scheme: scheme, accent: .system, increasedContrast: false)
                    == ThemeGenerator.palette(scheme: scheme, accent: .blue, increasedContrast: false))
        }
    }

    @Test func aNamedAccentIgnoresTheSystemColour() {
        let pink = ThemeRGB(r: 0.97, g: 0.31, b: 0.62)
        #expect(
            Theme.resolve(scheme: .dark, accent: .green, increasedContrast: false, systemAccent: pink)
                == Theme.resolve(scheme: .dark, accent: .green, increasedContrast: false))
    }

    @Test func statusHuesStayClearOfTheAccent() {
        let green = ThemeGenerator.palette(scheme: .dark, accent: .green, increasedContrast: false)
        #expect(green.success.hue == 182)
        for accent in ConsoleAccent.allCases where accent != .graphite && accent != .system {
            let p = ThemeGenerator.palette(scheme: .light, accent: accent, increasedContrast: false)
            let accentHue = ThemeGenerator.request(for: accent, systemAccent: nil).h
            for status in [p.success, p.caution, p.critical, p.info] {
                let raw = abs((status.hue - accentHue).truncatingRemainder(dividingBy: 360))
                let gap = min(raw, 360 - raw)
                #expect(gap >= 35 - 1e-9, "\(accent) status hue \(status.hue)")
            }
        }
    }

    @Test func theBasesMatchTheirAppearance() {
        let dark = ThemeGenerator.palette(scheme: .dark, accent: .green, increasedContrast: false)
        let light = ThemeGenerator.palette(scheme: .light, accent: .green, increasedContrast: false)
        #expect(ThemeGenerator.luminance(dark.ground) < 0.01)
        #expect(ThemeGenerator.luminance(light.ground) > 0.9)
        // Dark elevation is lighter surfaces with a highlight; light is near-white cards with a shadow.
        #expect(ThemeGenerator.luminance(dark.raised) > ThemeGenerator.luminance(dark.ground))
        #expect(ThemeGenerator.luminance(dark.sunken) < ThemeGenerator.luminance(dark.ground))
        #expect(ThemeGenerator.luminance(light.sunken) < ThemeGenerator.luminance(light.ground))
        #expect(dark.cardShadow == nil && dark.topHighlight != nil)
        #expect(light.cardShadow != nil && light.topHighlight == nil)
    }

    @Test func colourMathRoundTrips() {
        for rgb in [
            ThemeRGB(r: 0.2, g: 0.5, b: 0.8), ThemeRGB(r: 0.9, g: 0.1, b: 0.3), ThemeRGB(r: 0.5, g: 0.5, b: 0.5),
        ] {
            let back = ThemeGenerator.srgb(ThemeGenerator.oklch(from: rgb))
            #expect(abs(back.r - rgb.r) < 1e-6 && abs(back.g - rgb.g) < 1e-6 && abs(back.b - rgb.b) < 1e-6)
        }
        #expect(abs(ThemeGenerator.contrast(ThemeRGB(r: 1, g: 1, b: 1), ThemeRGB(r: 0, g: 0, b: 0)) - 21) < 1e-9)
    }
}
