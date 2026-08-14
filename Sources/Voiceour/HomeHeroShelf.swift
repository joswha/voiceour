import SwiftUI
import VoiceCore

struct HomeHeroShelf: View {
    let insights: DictationInsights
    let capture: String?
    let typingWPM: Int
    let setTypingWPM: (Int) -> Void

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
    ///
    /// Every figure in this card is measured. Sessions recorded before capture
    /// timing existed contribute nothing to it — not an assumed speaking rate
    /// — and the coverage line says how many those are until the last of them
    /// ages out of the tally.
    var body: some View {
        ContentCard(eyebrow: heroEyebrow) {
            HStack(alignment: .top, spacing: VoiceourMetrics.Space.xl) {
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
    ///
    /// The date is the ledger's, not the oldest kept transcript's, so it stays
    /// put instead of walking forward as old sessions are evicted.
    private var heroEyebrow: String {
        guard insights.spansMultipleDays, let started = insights.startedAt else {
            return "TIME SAVED"
        }
        return "TIME SAVED · SINCE \(HomeFormat.since.string(from: started).uppercased())"
    }

    @ViewBuilder
    private var heroReadout: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
                if insights.measuredWords > 0 {
                    MetricValue(
                        parts: HomeFormat.durationParts(insights.timeSavedMs(typingWPM: typingWPM)),
                        scale: .hero
                    )
                }

                if let capture {
                    StatusChip(label: capture, mode: .live)
                }
            }

            if insights.measuredWords > 0 {
                Text(counterfactual)
                    .roleStyle(.body)
                    .foregroundStyle(VoiceourPalette.Text.mid)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // No fabricated zero: nothing here has been timed, so there is
                // no saving to state yet.
                CaptionText("Nothing timed yet — your next dictation starts the clock.")
            }

            if !insights.isFullyMeasured {
                CaptionText(coverage, color: VoiceourPalette.Text.mid)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The headline in the reader's own terms: the words that were said, what
    /// they actually cost, and what typing them would have cost instead. One
    /// sentence at the body face — the figure above it is the answer, this is
    /// the working, and the subtraction between the two durations is the whole
    /// claim.
    ///
    /// "Took" is the elapsed wall clock, not the microphone time: transcription
    /// and insertion are time the reader waited too, and a saving that ignored
    /// them would be measuring only the flattering half.
    private var counterfactual: String {
        let words = insights.measuredWords
        let count = HomeFormat.grouped(words)
        let subject = words == 1 ? "that \(count) word" : "those \(count) words"
        return "Dictating \(subject) took \(HomeFormat.duration(insights.elapsedMs)). "
            + "Typing them at \(typingWPM) wpm would have taken "
            + "\(HomeFormat.duration(insights.typedMs(typingWPM: typingWPM)))."
    }

    /// What the figure leaves out, stated in the same units as the figure's
    /// own denominator. Disappears on its own once every counted dictation
    /// carries timing.
    private var coverage: String {
        let untimed = insights.dictationCount - insights.measuredDictationCount
        let subject = untimed == 1 ? "1 dictation predates" : "\(HomeFormat.grouped(untimed)) dictations predate"
        return "\(subject) capture timing and sit outside this figure."
    }

    @ViewBuilder
    private var velocity: some View {
        VelocityGauges(
            dictationWPM: insights.dictationWPM,
            typingWPM: typingWPM,
            multiplier: insights.speedMultiplier(typingWPM: typingWPM),
            setTypingWPM: setTypingWPM
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
