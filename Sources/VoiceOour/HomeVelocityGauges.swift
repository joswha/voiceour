import SwiftUI
import VoiceCore

// MARK: - Velocity gauges

/// The ratio the hero's figure rests on, over the two gauges it is measured
/// with: one shared scale (full track == the faster of the two rates), so
/// whichever rate is slower always reads as the shorter fill against a visible
/// axis.
///
/// Both rates are end to end. `YOU` is words over the whole cost of a
/// dictation — speech plus the wait for transcription and insertion — because
/// the typing baseline it is set against is also words over elapsed time.
/// Comparing raw speaking speed to typing would flatter the ratio by hiding
/// every second the reader spent waiting. Peak *speaking* rate is a personal
/// best rather than a comparison, and sits in RECORDS where it is named as one.
///
/// The typing rate is the only figure on Home the app cannot measure, so it is
/// the only one the reader can type over. It is a field, not a caption: an
/// assumption stated as a fact is what made the old 40 wpm baseline unfalsifiable.
///
/// The ratio leads because it is the answer to the question the gauges only
/// illustrate — am I faster than typing, and by how much. Below the baseline
/// there is no ratio to lead with ("0.8× faster than typing" is not a
/// sentence), so the honest caption takes the block's place.
struct VelocityGauges: View {
    let dictationWPM: Double?
    let typingWPM: Int
    let multiplier: Double?
    let setTypingWPM: (Int) -> Void

    private var accent = HomeAccent()
    @State private var draft: String?
    @FocusState private var isEditingTyping: Bool

    init(
        dictationWPM: Double?,
        typingWPM: Int,
        multiplier: Double?,
        setTypingWPM: @escaping (Int) -> Void
    ) {
        self.dictationWPM = dictationWPM
        self.typingWPM = typingWPM
        self.multiplier = multiplier
        self.setTypingWPM = setTypingWPM
    }

    private static let labelWidth = VoiceOourMetrics.Space.section + VoiceOourMetrics.Space.xl
    /// Wide enough for the editable rate and its unit. Both rows share it, so
    /// the two tracks stay the same length and the two values stay in one
    /// column even though one of them is a control.
    private static let valueWidth = VoiceOourMetrics.Field.short
    private static let fieldWidth = VoiceOourMetrics.Space.section + VoiceOourMetrics.Space.xl

    /// Shared gauge scale: the faster of the two rates fills the track, so a
    /// slower-than-typing measured rate (degenerate early data) still renders
    /// proportionally instead of overflowing the track.
    private var gaugeScale: Double {
        max(dictationWPM ?? 0, Double(typingWPM))
    }

    private var dictationFraction: Double {
        guard gaugeScale > 0, let dictationWPM else { return 0 }
        return dictationWPM / gaugeScale
    }

    private var typingFraction: Double {
        guard gaugeScale > 0 else { return 0 }
        return Double(typingWPM) / gaugeScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            ratio

            if let dictationWPM {
                let parts = HomeFormat.countParts(Int(dictationWPM.rounded()), unit: "wpm")
                // One element for the whole row: label, track and value are one
                // reading, and three nodes for one datum is what a screen
                // reader has to walk otherwise.
                gaugeRow(label: "YOU", fill: accent.color, fraction: dictationFraction) {
                    MetricValue(parts: parts, scale: .tile)
                        .frame(width: Self.valueWidth, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("YOU, \(parts.plain)")
            }

            // Deliberately NOT combined: the row carries a control, and folding
            // it into one static element would take the field out of the
            // accessibility tree entirely.
            gaugeRow(label: "TYPING", fill: VoiceOourPalette.Meter.rest, fraction: typingFraction) {
                typingField
            }

            CaptionText(baselineNote)
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
            CaptionText("below the \(typingWPM) wpm typing baseline so far")
        } else {
            CaptionText("Your rate appears once a dictation has been timed.")
        }
    }

    /// Whether the baseline is the population figure or the reader's own — the
    /// difference between a number they should question and one they set.
    private var baselineNote: String {
        typingWPM == DictationInsights.defaultTypingWPM
            ? "\(typingWPM) wpm is the measured average of 168,000 typists — change it to yours."
            : "Your typing speed, not the \(DictationInsights.defaultTypingWPM) wpm population average."
    }

    private var typingField: some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.xs) {
            TextField("\(DictationInsights.defaultTypingWPM)", text: typingBinding)
                .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                .frame(width: Self.fieldWidth)
                .multilineTextAlignment(.trailing)
                .focused($isEditingTyping)
                .onSubmit { draft = nil }
                .onChange(of: isEditingTyping) {
                    // Leaving the field drops the draft, so a rejected or
                    // clamped entry snaps back to the value the figures
                    // actually used instead of lingering as a number nothing
                    // on the pane reflects.
                    if !isEditingTyping { draft = nil }
                }
                .accessibilityLabel("Typing speed, words per minute")

            // The unit is a mark on the value, so it follows the dashboard's
            // metric-unit voice rather than caption prose. Hidden from the
            // accessibility tree because the field's own label already ends in
            // "words per minute"; left visible it reads as a stray "wpm".
            Text("wpm")
                .font(VoiceOourTypography.micro)
                .foregroundStyle(VoiceOourPalette.Text.mid)
                .accessibilityHidden(true)
        }
        .frame(width: Self.valueWidth, alignment: .trailing)
    }

    /// The draft is what the reader typed; the committed value is what every
    /// figure on the pane is derived from. They are applied on each keystroke
    /// rather than on return so the saving visibly answers the number being
    /// entered — the point of putting the control next to the claim.
    private var typingBinding: Binding<String> {
        Binding(
            get: { draft ?? String(typingWPM) },
            set: { text in
                draft = text
                guard let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                setTypingWPM(parsed)
            }
        )
    }

    private func gaugeRow<Trailing: View>(
        label: String,
        fill: Color,
        fraction: Double,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: VoiceOourMetrics.Space.md) {
            Text(label)
                .roleStyle(.micro)
                .frame(width: Self.labelWidth, alignment: .leading)

            MeterBar(fraction: fraction, fill: fill)

            trailing()
        }
    }
}
