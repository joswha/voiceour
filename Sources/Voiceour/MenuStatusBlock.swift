import SwiftUI

struct MenuStatusBlock: View {
    let statusLabel: String
    let statusTone: Kit.Mark.Tone
    let isSystemAudioMuted: Bool
    let headline: (text: String, color: Color?, progress: Double?)?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.Mark(statusLabel, tone: statusTone, size: .regular)

                if isSystemAudioMuted {
                    // Compact, and in the header row rather than a lone pill
                    // floating in the prose column: one component, one
                    // structural level.
                    Kit.Mark("SYSTEM AUDIO MUTED", size: .compact)
                        .accessibilityLabel("System audio muted")
                }

                Spacer(minLength: VoiceourMetrics.Space.sm)

                // The header's second slot carries the one fact that makes the
                // product usable, not the app's own name — the user reached this
                // popover by clicking this app's icon.
                KeyCap("Fn")
                    .accessibilityLabel("Capture hotkey")
                    .accessibilityValue("Fn or Globe")
            }

            if let headline {
                CaptionText(headline.text, color: headline.color)
                if let progress = headline.progress {
                    MeterBar(fraction: progress, style: .download)
                        .accessibilityIdentifier("menu.acquisition.progress")
                }
            }
        }
    }
}
