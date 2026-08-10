import SwiftUI
import VoiceCore

struct HomeHeroShelf: View {
    let insights: DictationInsights
    let capture: String?

    // MARK: Shelf 1 — TIME SAVED, carrying the velocity gauges

    /// One full-width card in two equal halves. Left: what was saved and the
    /// arithmetic behind it. Right: the ratio that arithmetic rests on and the
    /// two gauges it is measured with. The rule lands on the card's midline
    /// because both halves now carry a claim — a figure with its sentence
    /// against a ratio with its evidence — so neither column is a caption of
    /// the other and neither needs to be sized to the other's content.
    ///
    /// `.top`, not `.bottom`: the 64pt hero and the 32pt ratio are the pane's
    /// first two reads and they start on one edge, while the two halves run to
    /// different depths below it. "VELOCITY" is not repeated as a second label
    /// either — `YOU` / `TYPING` / `wpm` already say it.
    var body: some View {
        ContentCard(eyebrow: heroEyebrow) {
            HStack(alignment: .top, spacing: VoiceOourMetrics.Space.xl) {
                heroReadout
                HairlineDivider(axis: .vertical)
                velocity
            }
        }
    }

    /// The span the figure covers, folded into the label the figure sits under.
    /// As its own caption line it was a third dangling qualifier below the
    /// readout; as part of the eyebrow it is read *before* the numeral, which is
    /// when a reader needs to know what window the numeral covers.
    private var heroEyebrow: String {
        guard insights.spansMultipleDays, let earliest = insights.earliestDate else {
            return "TIME SAVED"
        }
        return "TIME SAVED · SINCE \(HomeFormat.since.string(from: earliest).uppercased())"
    }

    private var heroReadout: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.md) {
                MetricValue(parts: HomeFormat.durationParts(insights.timeSavedMs), scale: .hero)

                if let capture {
                    StatusChip(label: capture, mode: .live)
                }
            }

            if insights.totalWords > 0 {
                Text(counterfactual)
                    .roleStyle(.body)
                    .foregroundStyle(VoiceOourPalette.Text.mid)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CaptionText("No words captured yet.")
            }

            if insights.isTimeSavedEstimated {
                let estimated = insights.sessionCount - insights.timedSessionCount
                CaptionText(
                    "speech time estimated for \(estimated) of \(insights.sessionCount) "
                        + "dictations — precise timing starts with your next dictation",
                    color: VoiceOourPalette.Text.mid
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The headline in the reader's own terms: the words that were said, the
    /// typing rate they are measured against, and how long typing them would
    /// have taken. One sentence, at the body face — the figure above it is the
    /// answer, this is the working.
    ///
    /// Derived from the words and the baseline alone. `totalCaptureMs +
    /// timeSavedMs` would reach the same figure only when every session was
    /// timed, and would quietly fold *estimated* capture time into a sentence
    /// that presents itself as arithmetic.
    private var counterfactual: String {
        let words = insights.totalWords
        let count = HomeFormat.grouped(words)
        let subject = words == 1 ? "that \(count) word" : "those \(count) words"
        let typedMs = Int((Double(words) / DictationInsights.typingBaselineWPM * 60_000).rounded())
        return "Typing \(subject) at \(Int(DictationInsights.typingBaselineWPM.rounded())) wpm "
            + "would have taken \(HomeFormat.duration(typedMs))."
    }

    @ViewBuilder
    private var velocity: some View {
        if let speaking = insights.speakingWPM {
            VelocityGauges(speakingWPM: speaking, multiplier: insights.speedMultiplier)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CaptionText(
                "Speaking rate appears after your next dictation — "
                    + "capture timing is new in this build."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
