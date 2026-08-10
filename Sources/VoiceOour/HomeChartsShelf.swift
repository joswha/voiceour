import SwiftUI
import VoiceCore

struct HomeChartsShelf: View {
    let insights: DictationInsights

    // MARK: Shelf 3 — WHEN YOU DICTATE, LAST 14 DAYS, TOP APPS

    /// 4 / 4 / 4 columns — one interior cut at 4 and 8. The hour strip plots
    /// twenty-four buckets and the day strip fourteen; at four columns each
    /// bar stays a bar (≈6pt and ≈9pt) instead of thinning to tally marks,
    /// and the hour readout still fits with its tally at two-digit hours.
    /// The ranked app list keeps four: at three columns its meter track was
    /// short enough that every share under a seventh clamped to the minimum
    /// fill, which turns a ranked bar chart into a column of identical stubs.
    var body: some View {
        BentoRow {
            ContentCard(eyebrow: "WHEN YOU DICTATE") {
                if insights.sessionCount < 3 {
                    CaptionText("Not enough dictations yet to chart your rhythm.")
                } else {
                    HourActivityChart(buckets: insights.hourBuckets)
                }
            }
            .bentoSpan(4)

            ContentCard(eyebrow: "LAST 14 DAYS") {
                DayWordsChart(dayWordCounts: insights.dayWordCounts)
            }
            .bentoSpan(4)

            ContentCard(eyebrow: "TOP APPS") {
                if insights.destinations.isEmpty {
                    CaptionText("No app recorded yet.")
                } else {
                    DestinationRows(
                        destinations: insights.destinations,
                        attributedTotal: insights.attributedOutcomeCount
                    )
                }
            }
            .bentoSpan(4)
        }
    }
}
