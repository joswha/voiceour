import SwiftUI
import VoiceCore
import VoiceMac

struct MenuReportBlock: View {
    let text: String
    @Binding var isCopied: Bool
    let summary: InsertionOutcomeSummary?
    private var a11y = A11y()

    init(text: String, isCopied: Binding<Bool>, summary: InsertionOutcomeSummary?) {
        self.text = text
        self._isCopied = isCopied
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            if !text.isEmpty {
                MenuTranscriptPreview(
                    text: text,
                    isCopied: isCopied,
                    copy: copyTranscript
                )
            }

            if let summary {
                CaptionText(summary.detail, color: detailColor(for: summary.severity))
            }
        }
    }

    private func detailColor(for severity: StatusSeverity) -> Color {
        switch severity {
        case .crit: VoiceourPalette.Signal.crimson
        case .warn: VoiceourPalette.Signal.amber
        case .ok, .neutral: a11y.textMid
        }
    }

    private func copyTranscript() {
        GeneralPasteboard.copy(text)
        isCopied = true
    }
}
