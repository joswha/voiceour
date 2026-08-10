import SwiftUI

struct MenuStatusBlock: View {
    let statusLabel: String
    let statusMode: StatusChip.Mode
    let isSystemAudioMuted: Bool
    let headline: (text: String, color: Color?)?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            HStack(spacing: VoiceOourMetrics.Space.sm) {
                StatusChip(label: statusLabel, mode: statusMode)

                if isSystemAudioMuted {
                    // Compact, and in the header row rather than a lone pill
                    // floating in the prose column: one component, one
                    // structural level.
                    StatusChip(label: "SYSTEM AUDIO MUTED", mode: .neutral, size: .compact)
                        .accessibilityLabel("System audio muted")
                }

                Spacer(minLength: VoiceOourMetrics.Space.sm)

                // The header's second slot carries the one fact that makes the
                // product usable, not the app's own name — the user reached this
                // popover by clicking this app's icon.
                KeyCap("Fn")
                    .accessibilityLabel("Capture hotkey")
                    .accessibilityValue("Fn or Globe")
            }

            if let headline {
                CaptionText(headline.text, color: headline.color)
            }
        }
    }
}
