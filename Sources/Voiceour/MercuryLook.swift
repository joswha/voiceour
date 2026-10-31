import Foundation
import VoiceCore

/// The user's two tone knobs, as the display response's anchors read them.
///
/// Both are in `-1...1` and zero is the shipped tone. `brightness` moves the median target
/// by up to half a stop either way; `contrast` moves the highlight target. Neither can
/// touch the response's ceiling, so no tone turns the body white.
struct MercuryTone: Equatable, Sendable {
    var brightness: Double
    var contrast: Double

    static let stock = MercuryTone(brightness: 0, contrast: 0)
}

/// One island look as the renderer's physical inputs, resolved once per session.
///
/// Each member reaches exactly one stage, so a look changes no per-pixel work:
/// - `world` and `lighting` are baked into the static room;
/// - `paint` selects the reflectance table the rasterizer samples;
/// - `tone` sets the metered response's targets;
/// - `tune` is the simulation's law and drawing transform.
///
/// `stock` is the shipped island member for member, every one the shipped constant itself,
/// which is what keeps the stock island byte-identical.
struct MercuryLook: Equatable, Sendable {
    var world: MercuryWorld
    var paint: MercuryPaint
    var lighting: MercuryRoomLighting
    var tone: MercuryTone
    var tune: MercuryTune

    static let stock = MercuryLook(
        world: .default,
        paint: .stock,
        lighting: .stock,
        tone: .stock,
        tune: .stock
    )

    /// The underglow's `0...1` strength, or 0 while it is off. The median target's floor
    /// rises with it.
    var underglowStrength: Double {
        lighting.underglow?.strength ?? 0
    }
}

extension MercuryLook {
    /// The renderer's inputs for a persisted appearance, snapped first so every value is one
    /// the settings can hold.
    ///
    /// Fields an appearance keeps but does not show — the film under a coat without one, the
    /// candy dye under any other coat, the underglow's colour while it is off — do not reach
    /// the look, so equivalent appearances are one look. Each stock field maps to its shipped
    /// constant itself rather than to an expression that happens to equal it, so
    /// `MercuryLook(island: .stock) == .stock` holds bit for bit.
    init(island: IslandAppearance) {
        let island = island.snapped()
        self.init(
            world: island.room,
            paint: Self.paint(island),
            lighting: Self.lighting(island),
            tone: MercuryTone(
                brightness: Double(island.brightness) / 100,
                contrast: Double(island.contrast) / 100
            ),
            tune: Self.tune(island)
        )
    }

    private static func paint(_ island: IslandAppearance) -> MercuryPaint {
        MercuryPaint(
            metal: island.metal,
            coat: island.coat,
            filmNanometers: island.coat.film == nil ? 0 : island.film,
            candy: island.coat == .candy ? candyTransmittance(island) : MercuryPaint.stock.candy
        )
    }

    /// The dye's linear-light colour is its round-trip transmittance, held to the range the
    /// lacquer keeps it in so dyes that render alike share one paint table.
    private static func candyTransmittance(_ island: IslandAppearance) -> SIMD3<Double> {
        let range = MercuryLacquer.transmittanceRange
        let color = MercuryColor.linearRGB(
            hue: island.candyHue,
            saturation: island.candySaturation,
            brightness: island.candyBrightness
        )
        return pointwiseMin(
            pointwiseMax(color, SIMD3(repeating: range.lowerBound)),
            SIMD3(repeating: range.upperBound)
        )
    }

    private static func lighting(_ island: IslandAppearance) -> MercuryRoomLighting {
        MercuryRoomLighting(
            finish: roughness(finish: island.finish),
            whiteBalance: MercuryWhiteBalance.multipliers(
                temperature: Double(island.temperature) / 100
            ),
            underglow: island.underglow ? underglow(island) : nil
        )
    }

    /// `r = 0.03 · (25/3)^(v/100)`: log-uniform from the liquid's own 0.03 at v = 0 to the
    /// roughest prefiltered level, 0.25, at v = 100. Zero is the shipped level itself.
    private static func roughness(finish: Int) -> Float {
        guard finish != 0 else { return MercuryMetrics.environmentRoughness[0] }
        return Float(0.03 * pow(25.0 / 3.0, Double(finish) / 100))
    }

    /// Full-brightness HSB at unit luminance, so `strength` alone sets the light's power
    /// and every hue at one strength is equally bright.
    private static func underglow(_ island: IslandAppearance) -> MercuryUnderglow {
        MercuryUnderglow(
            color: MercuryColor.luminanceNormalized(
                MercuryColor.linearRGB(
                    hue: island.underglowHue,
                    saturation: island.underglowSaturation,
                    brightness: 100
                )
            ),
            strength: Double(island.underglowStrength) / 100
        )
    }

    /// Percent multipliers divide by 100; the end taper runs from the gauged `gEnd` at 0 to
    /// 0.30 at 100; the crown is its aspect in percent. Clamped like every tune the
    /// simulation runs, which leaves a snapped value where it is.
    private static func tune(_ island: IslandAppearance) -> MercuryTune {
        MercuryTune(
            size: Double(island.size) / 100,
            build: Double(island.build) / 100,
            endTaper: island.taper == IslandGrids.taper.stock
                ? MercuryMetrics.gEnd
                : MercuryMetrics.gEnd - 0.0016 * Double(island.taper),
            crownAspect: island.crown == IslandGrids.crown.stock
                ? MercuryMetrics.crownAspect
                : Double(island.crown) / 100,
            tempo: Double(island.tempo) / 100,
            viscosity: Double(island.viscosity) / 100,
            shimmer: Double(island.shimmer) / 100,
            reactivity: Double(island.reactivity) / 100,
            slither: Double(island.slither) / 100,
            morph: Double(island.morph) / 100,
            drama: Double(island.drama) / 100
        ).clamped()
    }
}

/// The two targets a look's display response is solved to, before Increase Contrast.
///
/// `m = clamp(0.32 · (A / A_Hg)^0.5 · 2^(b/2), 0.28 + 0.07 s, 0.41)` and
/// `h = 0.87 + 0.025 c`, with `A` the paint's normal-incidence albedo, `A_Hg` liquid
/// mercury's, `b` and `c` the tone and `s` the underglow strength.
///
/// - The square root is "albedo memory": metering every metal to one median would leave
///   silver, aluminum and chrome differing only at the limb, and metering them at
///   mercury's exposure would push chrome below the bench's median gate. Half the
///   difference keeps their order inside it.
/// - The floor and the ceiling keep every tone inside the bench's 0.18–0.55 median gate in
///   every room. A room's response is metered on settled listening and speaking bodies,
///   while the speaking body a reader watches moves under live speech, so each body's
///   displayed median lands between 0.66 and 1.28 times the target across the look corpus's
///   rooms at the steepest contrast. At a 0.25 floor the darkest, most contrasted corner
///   showed a 0.164 speaking median, and at a 0.42 ceiling the brightest a 0.552 one. The
///   floor rises with the underglow: with the glow on, the darkest tones would otherwise
///   crush the body's unlit part past the bench's crushed-black gate.
///
/// Increase Contrast is the rasterizer's existing remap onto (0.30, 0.90) from the same
/// metered scene anchors, so it overrides all of this.
enum MercuryToneAnchors {
    private static let medianFloor = 0.28
    private static let medianFloorPerUnderglow = 0.07
    private static let medianCeiling = 0.41
    private static let highlightPerContrast = 0.025

    /// Stock — the stock paint's albedo, stock tone, no underglow — returns the shipped
    /// constants themselves. `tone` and `underglowStrength` are held to their ranges, so
    /// the highlight stays below the response's ceiling.
    static func targets(
        albedo: Double,
        tone: MercuryTone,
        underglowStrength: Double
    ) -> (median: Double, highlight: Double) {
        let stockAlbedo = MercuryPaintLookup.stock.albedo
        guard albedo != stockAlbedo || tone != .stock || underglowStrength != 0 else {
            return (MercuryMetrics.targetDisplayLuminance, MercuryMetrics.targetHighlightLuminance)
        }
        let brightness = Swift.min(Swift.max(tone.brightness, -1), 1)
        let contrast = Swift.min(Swift.max(tone.contrast, -1), 1)
        let strength = Swift.min(Swift.max(underglowStrength, 0), 1)
        let raw =
            MercuryMetrics.targetDisplayLuminance
            * (albedo / stockAlbedo).squareRoot()
            * exp2(0.5 * brightness)
        let lowest = medianFloor + medianFloorPerUnderglow * strength
        return (
            median: Swift.min(Swift.max(raw, lowest), medianCeiling),
            highlight: MercuryMetrics.targetHighlightLuminance + highlightPerContrast * contrast
        )
    }
}
