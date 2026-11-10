import SwiftUI

/// The popover's first block: what the app is doing, the capture hotkey, and the
/// one line under them that says what happens next or why it cannot.
struct MenuStatusBlock: View {
    /// The line under the header row: a failure, the model's own progress, or the
    /// future-tense target promise.
    struct Headline: Equatable {
        enum Tone: Equatable {
            /// The target promise: a fact, in the caption voice.
            case plain
            /// A wait (the model is still arriving).
            case caution
            /// A fault the reader has to act on.
            case critical
        }

        let text: String
        let tone: Tone
        /// The download's fraction, when the wait has one to report.
        let progress: Double?
    }

    let statusLabel: String
    let statusTone: Kit.Pill.Tone
    let isSystemAudioMuted: Bool
    let headline: Headline?

    @Environment(\.theme) private var theme

    init(statusLabel: String, statusTone: Kit.Pill.Tone, isSystemAudioMuted: Bool, headline: Headline?) {
        self.statusLabel = statusLabel
        self.statusTone = statusTone
        self.isSystemAudioMuted = isSystemAudioMuted
        self.headline = headline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            header

            if let headline {
                Text(headline.text)
                    .roleStyle(.meta)
                    .foregroundStyle(color(for: headline.tone))
                    // A 300-character cause wraps in full: it is the one sentence
                    // that says what went wrong, so it is never cut.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let progress = headline.progress {
                    Kit.Meter(fraction: progress, style: .download)
                        .accessibilityIdentifier("menu.acquisition.progress")
                }
            }
        }
    }

    /// Pills never truncate their word, so the row folds instead of overflowing the
    /// 256 pt column: first the mute pill moves under the status pill, then, for a
    /// status word too long to share a line with the hotkey, the hotkey moves down
    /// beside the mute pill.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                statusPill
                mutePill
                Spacer(minLength: VoiceourMetrics.Space.sm)
                hotkey
            }
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    statusPill
                    Spacer(minLength: VoiceourMetrics.Space.sm)
                    hotkey
                }
                mutePill
            }
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                statusPill
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    mutePill
                    Spacer(minLength: VoiceourMetrics.Space.sm)
                    hotkey
                }
            }
        }
    }

    private var statusPill: some View {
        Kit.Pill(statusLabel, tone: statusTone, size: .regular)
    }

    /// Small and neutral, in the header rather than a lone pill in the prose
    /// below: it qualifies the state, it is not a second state.
    @ViewBuilder
    private var mutePill: some View {
        if isSystemAudioMuted {
            Kit.Pill("System audio muted", tone: .neutral, size: .small)
                .accessibilityLabel("System audio muted")
        }
    }

    /// The header's second slot carries the one fact that makes the product
    /// usable, not the app's own name — the user reached this popover by clicking
    /// this app's icon.
    private var hotkey: some View {
        Kit.KeyCap("Fn")
            .accessibilityLabel("Capture hotkey")
            .accessibilityValue("Fn or Globe")
    }

    private func color(for tone: Headline.Tone) -> Color {
        switch tone {
        case .plain: theme.text2
        case .caution: theme.caution.text
        case .critical: theme.critical.text
        }
    }
}
