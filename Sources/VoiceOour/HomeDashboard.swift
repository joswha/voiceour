import SwiftUI
import VoiceCore

// MARK: - Dashboard

struct HomeDashboard: View {
    let insights: DictationInsights
    let capture: String?
    /// The reader's assumed typing speed. Passed down rather than read from
    /// settings here so every shelf stays a function of its inputs and the
    /// harness can render one at any baseline.
    let typingWPM: Int
    let setTypingWPM: (Int) -> Void

    /// The Home dashboard uses the shared centered data-grid measure rather than
    /// either of the left-flush form/table measures.
    private static let gridWidth = VoiceOourMetrics.Content.grid

    var body: some View {
        ScrollView {
            VStack(spacing: VoiceOourMetrics.Space.lg) {
                HomeHeroShelf(
                    insights: insights,
                    capture: capture,
                    typingWPM: typingWPM,
                    setTypingWPM: setTypingWPM
                )
                HomeAllTimeShelf(insights: insights)
                HomeChartsShelf(insights: insights)
                HomeRecordsShelf(insights: insights)
            }
            .frame(maxWidth: Self.gridWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, VoiceOourMetrics.Space.section)
        }
        .environment(\.homeCaptureIsLive, capture != nil)
    }

}
