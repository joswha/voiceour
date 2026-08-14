import SwiftUI

/// The rail's one live signal, resolved once so the mark, the word and the tint
/// can never disagree. ERROR used to announce itself by swapping four dim grey
/// letters for five at 2.15:1, with no second channel at all.
enum RailStatus {
    case idle
    case working
    case live
    case error
}

struct RailStatusMark: View {
    let status: RailStatus
    private var a11y = A11y()

    init(status: RailStatus) {
        self.status = status
    }

    /// Gutter mark for the identity line, in the same 16pt slot every nav glyph uses.
    /// Shape carries the state, not colour alone (§7.4): idle is a hollow ring, a
    /// working or live rail is a filled dot, and an error swaps the dot for the
    /// warning glyph the rest of the app already uses.
    @ViewBuilder
    var body: some View {
        switch status {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: VoiceourMetrics.Icon.mark))
                .foregroundStyle(VoiceourPalette.Signal.crimson)
        case .idle:
            Circle()
                .strokeBorder(
                    a11y.markFaint,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast) * 2
                )
                .frame(width: VoiceourMetrics.Dot.live, height: VoiceourMetrics.Dot.live)
        case .working, .live:
            Circle()
                .fill(status == .live ? VoiceourPalette.Signal.cyan : a11y.textMid)
                .frame(width: VoiceourMetrics.Dot.live, height: VoiceourMetrics.Dot.live)
        }
    }
}
