import SwiftUI
import VoiceCore

// MARK: - Dashboard

struct HomeDashboard: View {
    let insights: DictationInsights
    let capture: String?

    /// The Home dashboard uses the shared centered data-grid measure rather than
    /// either of the left-flush form/table measures.
    private static let gridWidth = VoiceOourMetrics.Content.grid

    var body: some View {
        ScrollView {
            VStack(spacing: VoiceOourMetrics.Space.lg) {
                HomeHeroShelf(insights: insights, capture: capture)
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
