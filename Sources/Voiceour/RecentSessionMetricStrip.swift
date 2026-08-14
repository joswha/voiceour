import SwiftUI
import VoiceCore

struct RecentSessionMetricStrip: View {
    var stats: RecentSessionTotals

    /// One 24pt gutter per boundary; the rule is centred in it, so the four
    /// columns divide the card's full measure instead of huddling on the left.
    private static let gutter = VoiceourMetrics.Space.xl

    private var metrics: [RecentSessionMetricEntry] {
        [
            RecentSessionMetricEntry(label: "WORDS TODAY", value: stats.wordsToday),
            RecentSessionMetricEntry(label: "SESSIONS TODAY", value: stats.sessionsToday),
            RecentSessionMetricEntry(label: "WORDS THIS MONTH", value: stats.wordsThisMonth),
            RecentSessionMetricEntry(label: "SESSIONS THIS MONTH", value: stats.sessionsThisMonth),
        ]
    }

    var body: some View {
        ContentCard(eyebrow: "TOTALS") {
            HStack(alignment: .top, spacing: Self.gutter) {
                ForEach(metrics) { metric in
                    RecentSessionMetric(value: metric.value, label: metric.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // The rules are an overlay on the resolved strip, so they run the
            // height of a column — label and numeral — and stop inside the
            // card's content box rather than crossing its padding or its rim.
            .overlay {
                MetricStripRules(columnCount: metrics.count, gutter: Self.gutter)
            }
        }
        // ContentCard stretches to any offered height (bento rows rely on that);
        // in this full-height pane the totals strip must hug its content so the
        // sessions/detail row below keeps the remaining space.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecentSessionMetricEntry: Identifiable {
    var label: String
    var value: Int
    var id: String { label }
}

/// One column of the strip, in the ledger grammar Home's shelf already speaks:
/// the uppercase mono label names the figure before you read it, the numeral is
/// the payload, and the two read as one accessibility element instead of a bare
/// number trailed by a caption.
private struct RecentSessionMetric: View {
    var value: Int
    var label: String

    private var readout: String {
        HomeFormat.grouped(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            Text(label)
                .roleStyle(.eyebrow)
            Text(readout)
                .roleStyle(.metric)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(readout)
    }
}
