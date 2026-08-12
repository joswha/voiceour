import SwiftUI
import VoiceCore

struct HomeAllTimeShelf: View {
    let insights: DictationInsights

    // MARK: Shelf 2 — ALL TIME

    /// The running tally as ONE card. Four separate cards drew four rims and
    /// four kerned eyebrows around four bare numerals, which put a routine
    /// tally in the same visual register as the headline above it. One card with
    /// four ruled quarters prints the same four figures as four phrases a person
    /// can read straight out.
    ///
    /// "All time" is now literally true. These four come from the lifetime
    /// ledger, so they keep climbing after the transcript store starts dropping
    /// its oldest sessions; read off the retained corpus they used to freeze at
    /// the retention cap and then drift sideways as words were evicted.
    var body: some View {
        ContentCard(eyebrow: "ALL TIME") {
            HomeMetricRow(cells: allTimeCells, scale: .metric, labels: false)
        }
    }

    /// Every value carries the unit that names it, so these cells need no
    /// labels: "675 keystrokes spared" says in one register what "KEYSTROKES
    /// SPARED" over "675" said in two. A zero streak keeps the demoted colour —
    /// the figure is honest, but it is not yet an achievement.
    private var allTimeCells: [MetricCell] {
        [
            MetricCell(
                id: "WORDS",
                parts: HomeFormat.countParts(
                    insights.totalWords,
                    unit: insights.totalWords == 1 ? "word" : "words"
                )
            ),
            MetricCell(
                id: "KEYSTROKES",
                parts: HomeFormat.countParts(
                    insights.totalCharacters,
                    unit: insights.totalCharacters == 1 ? "keystroke spared" : "keystrokes spared"
                )
            ),
            MetricCell(
                id: "DICTATIONS",
                parts: HomeFormat.countParts(
                    insights.dictationCount,
                    unit: insights.dictationCount == 1 ? "dictation" : "dictations"
                )
            ),
            MetricCell(
                id: "STREAK",
                parts: HomeFormat.countParts(
                    insights.streakDays,
                    unit: insights.streakDays == 1 ? "day in a row" : "days in a row"
                ),
                color: insights.streakDays > 0 ? nil : VoiceOourPalette.Text.mid
            ),
        ]
    }
}
