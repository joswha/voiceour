import SwiftUI

// MARK: - 24-hour activity strip

/// Dictation activity by hour of day as a linear bar strip: one flexible
/// column per hour, midnight → 23:00, heights normalised to the busiest hour.
///
/// This replaced a polar "clock dial". The dial encoded the same 24 buckets as
/// spoke length around a ring, which failed three ways at once: angle and
/// radius are the least accurately read visual channels (a cluster at 18:00
/// pointed *left*), a 24-hour ring puts noon at the BOTTOM so no clock
/// intuition survives contact with it, and one-session hours vanished into the
/// hub dot. A strip reads by length from a shared baseline — the same encoding
/// the LAST 14 DAYS chart beside it uses, so the shelf speaks one chart
/// language and either plot teaches the other.
///
/// Every one of the twenty-four slots draws its own track and the bar fills its
/// share of one, so a quiet hour is a measured empty column instead of nothing
/// at all, and a fresh install reads as a day that was quiet rather than a
/// chart that failed to render. The axis marks 00 / 06 / 12 / 18 in the
/// user's own clock convention, and the readout line above the plot always
/// carries the headline fact, so no reading requires a hover. Lives beside the
/// other Home chart components (HomeDayChart.swift, HomeDestinations.swift).
struct HourActivityChart: View {
    var buckets: [Int]

    init(buckets: [Int]) {
        self.buckets = buckets
    }

    /// Breathing room each side of a bar inside its flexible column. Narrower
    /// than the day chart's inset because twenty-four columns share the width
    /// fourteen do there; at `xs` the bars thin toward tally marks.
    private static let columnInset = VoiceOourMetrics.Space.hair

    /// The four axis hours, each labelling the leading boundary of its quarter.
    private static let cardinals = [0, 6, 12, 18]

    private var busiestHour: Int? {
        guard let maxCount = buckets.max(), maxCount > 0 else { return nil }
        return buckets.firstIndex(of: maxCount)
    }

    var body: some View {
        ActivityBarPlot(
            bucketValues: buckets,
            columnSpacing: VoiceOourMetrics.Space.hair,
            columnInset: Self.columnInset,
            labelBuilder: bucketLabel,
            valueBuilder: bucketValue,
            readoutSummary: readoutSummary,
            readoutOrder: .labelThenValue,
            accessibilityChartLabel: "Dictation activity by hour of day",
            accessibilitySummary: accessibilitySummary,
            accessibilityIdentifierPrefix: "activity.hour",
            pinnedPreposition: "at"
        ) {
            // Each cardinal labels the leading boundary of its quarter of the
            // day, the same convention an axis tick uses. Equal-flex quarters
            // land each label under its hour to within the accumulated column
            // gaps — an axis hint, not a measuring instrument.
            HStack(spacing: 0) {
                ForEach(Self.cardinals, id: \.self) { hour in
                    Text(HomeFormat.cardinalHourLabel(hour))
                        .roleStyle(.micro)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Always a fact: the selected hour when there is one, otherwise the
    /// busiest hour with its tally, so the strip states its own headline
    /// without a hover and without reserving a blank line to say nothing.
    /// `ActivityBarPlot` owns the selected branch; this is the fallback summary.
    private var readoutSummary: String {
        guard let hour = busiestHour else { return "no activity recorded yet" }
        return "busiest around \(HomeFormat.hourLabel(hour)) · \(dictations(buckets[hour]))"
    }

    private var accessibilitySummary: String {
        guard let hour = busiestHour else { return "No activity recorded" }
        let total = buckets.reduce(0, +)
        let active = buckets.filter { $0 > 0 }.count
        return "\(dictations(total)) across \(active) of 24 hours, "
            + "busiest \(HomeFormat.hourLabel(hour)) with \(dictations(buckets[hour]))"
    }

    private func bucketLabel(_ hour: Int, _: ActivityBarPlotTextContext) -> String {
        HomeFormat.hourLabel(hour)
    }

    private func bucketValue(_ hour: Int, _: ActivityBarPlotTextContext) -> String {
        dictations(buckets[hour])
    }

    /// The unit every figure in this card carries: dictations begun in that
    /// hour — the moment the user spoke, not a paste or an engine run.
    private func dictations(_ count: Int) -> String {
        "\(HomeFormat.grouped(count)) \(count == 1 ? "dictation" : "dictations")"
    }
}
