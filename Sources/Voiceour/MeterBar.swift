import SwiftUI

/// A determinate horizontal meter: a capsule track with a capsule fill.
///
/// One drawn bar with two consumers — model acquisition on Home's island, the Settings readiness
/// page and the menu popover, and Home's share-of-busiest-app magnitude. `Style` picks the palette,
/// the measure and what the bar says, exactly as `Kit.Mark.Tone` picks a mark's hue and
/// `ConsoleReadout.Severity` picks a readout's rung.
///
/// Determinate only, and deliberately: the offscreen harness has no effective animation-disable
/// seam, so a perpetual indeterminate fill cannot be captured reproducibly. A wait with no fraction
/// stays a word.
///
/// Magnitude is encoded by length, so neither Differentiate Without Color nor Increase Contrast
/// needs a branch on the fill: removing the hue removes nothing the bar is saying. The painted
/// track alone strengthens, through `A11y.meterRest`.
struct MeterBar: View {
    enum Style {
        /// Model acquisition. Amber, the app's waiting hue, matching the menu headline and the
        /// menu-bar dot; it announces its own percentage because the sentence beside it no longer
        /// carries the number.
        case download
        /// Home's share of the busiest app. Alien bloom, uncapped width, and silent.
        case share
    }

    let fraction: Double
    let style: Style
    private var a11y = A11y()

    init(fraction: Double, style: Style) {
        self.fraction = fraction
        self.style = style
    }

    /// Clamped once, here, because this is the only place the value is read. NaN and −∞ read as
    /// zero rather than trapping (`Int(Double.nan * 100)` is a crash); +∞ saturates at full.
    static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return fraction > 0 ? 1 : 0 }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        let value = Self.clamped(fraction)

        return ZStack(alignment: .leading) {
            Capsule().fill(track)
            GeometryReader { proxy in
                Capsule()
                    .fill(fill)
                    .frame(width: proxy.size.width * value)
            }
        }
        .frame(height: VoiceourMetrics.Meter.barHeight)
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .animation(a11y.reduceMotion ? nil : VoiceourMotion.meter, value: value)
        // The share bar is hidden rather than labelled: `Kit.MeterRow` combines its children and
        // states its own counts, so a second voice would repeat them.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model download")
        .accessibilityValue("\(Int(value * 100))%")
        .accessibilityHidden(isSilent)
    }

    private var track: Color {
        return switch style {
        case .download: a11y.meterRest
        case .share: VoiceourPalette.Plate.rest
        }
    }

    private var fill: Color {
        return switch style {
        case .download: VoiceourPalette.Signal.amber
        case .share: VoiceourPalette.Alien.bloom
        }
    }

    private var maximumWidth: CGFloat {
        return switch style {
        case .download: VoiceourMetrics.Meter.barWidth
        case .share: .infinity
        }
    }

    private var isSilent: Bool {
        if case .share = style { return true }
        return false
    }
}
