import SwiftUI
import VoiceCore

// MARK: - Velocity gauges

/// The ratio the hero's figure rests on, over the two gauges it is measured
/// with: one shared scale (full track == the faster of the measured speaking
/// rate and the 40 wpm typing baseline), so whichever rate is slower always
/// reads as the shorter fill against a visible axis.
///
/// The ratio leads because it is the answer to the question the gauges only
/// illustrate — am I faster than typing, and by how much. Below the baseline
/// there is no ratio to lead with ("0.8× faster than typing" is not a
/// sentence), so the honest caption takes the block's place. Peak speed is a
/// personal best, not a rate comparison, and now sits in RECORDS.
struct VelocityGauges: View {
    let speakingWPM: Double
    let multiplier: Double?

    private var accent = HomeAccent()

    init(speakingWPM: Double, multiplier: Double?) {
        self.speakingWPM = speakingWPM
        self.multiplier = multiplier
    }

    private static let labelWidth = VoiceOourMetrics.Space.section + VoiceOourMetrics.Space.xl
    private static let valueWidth = VoiceOourMetrics.Space.section + VoiceOourMetrics.Space.xl

    /// Shared gauge scale: the faster of the two rates fills the track, so a
    /// slower-than-typing measured rate (degenerate early data) still renders
    /// proportionally instead of overflowing the track.
    private var gaugeScale: Double {
        max(speakingWPM, DictationInsights.typingBaselineWPM)
    }

    private var speakingFraction: Double {
        guard gaugeScale > 0 else { return 0 }
        return speakingWPM / gaugeScale
    }

    private var typingFraction: Double {
        guard gaugeScale > 0 else { return 0 }
        return DictationInsights.typingBaselineWPM / gaugeScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            ratio

            gaugeRow(
                label: "YOU",
                fill: accent.color,
                fraction: speakingFraction,
                wpm: Int(speakingWPM.rounded())
            )
            gaugeRow(
                label: "TYPING",
                fill: VoiceOourPalette.Meter.rest,
                fraction: typingFraction,
                wpm: Int(DictationInsights.typingBaselineWPM.rounded())
            )
        }
    }

    @ViewBuilder
    private var ratio: some View {
        if let multiplier, multiplier >= 1 {
            let parts = HomeFormat.multiplierParts(multiplier)
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                MetricValue(parts: parts, scale: .metric)

                Text("faster than typing")
                    .roleStyle(.label)
                    .foregroundStyle(VoiceOourPalette.Text.mid)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(parts.plain) faster than typing")
        } else if multiplier != nil {
            CaptionText("below the 40 wpm typing baseline so far")
        }
    }

    private func gaugeRow(
        label: String,
        fill: Color,
        fraction: Double,
        wpm: Int
    ) -> some View {
        let parts = HomeFormat.countParts(wpm, unit: "wpm")
        return HStack(spacing: VoiceOourMetrics.Space.md) {
            Text(label)
                .roleStyle(.micro)
                .frame(width: Self.labelWidth, alignment: .leading)

            MeterBar(fraction: fraction, fill: fill)

            MetricValue(parts: parts, scale: .tile)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(parts.plain)")
    }
}
