import SwiftUI

// MARK: - 14-day words trend

/// A 14-day words trend that fills its card: one flexible column per calendar
/// day (oldest -> today), heights normalised to the best day.
///
/// Every one of the fourteen slots draws its own track and the bar fills its
/// share of one, so a quiet day is a measured empty column instead of nothing
/// at all. A baseline alone cannot do that job: it says where the floor is but
/// not where one day ends and the next begins, and a fortnight after a fresh
/// install most of the strip is zero — the left half then reads as a chart that
/// failed to render rather than as a fortnight that was quiet. The strip is
/// dated at both ends and the readout line above it always carries the scale,
/// so no reading requires a hover. Lives beside the other Home chart components
/// (HomeHourChart.swift, HomeDestinations.swift).
struct DayWordsChart: View {
    var dayWordCounts: [Int]

    init(dayWordCounts: [Int]) {
        self.dayWordCounts = dayWordCounts
    }

    /// Breathing room each side of a bar inside its flexible column. One gutter
    /// leaves the bar a little over two thirds of its column at the widths this
    /// card is ever given: wide enough to read as a distribution, narrow enough
    /// that fourteen bars stay fourteen days rather than one block.
    private static let columnInset = VoiceOourMetrics.Space.xs

    private static let weekdayFormatter: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
    private static let shortDateFormatter: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
    private static let accessibilityDateFormatter: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()

    var body: some View {
        ActivityBarPlot(
            bucketValues: dayWordCounts,
            columnSpacing: VoiceOourMetrics.Space.xs,
            columnInset: Self.columnInset,
            labelBuilder: bucketLabel,
            valueBuilder: bucketValue,
            readoutSummary: readoutSummary,
            readoutOrder: .valueThenLabel,
            accessibilityChartLabel: "Words dictated per day over the last 14 days",
            accessibilitySummary: accessibilitySummary,
            accessibilityIdentifierPrefix: "words.day",
            pinnedPreposition: "on"
        ) {
            HStack(spacing: VoiceOourMetrics.Space.sm) {
                Text(Self.shortDate(dayOffset: max(dayWordCounts.count - 1, 0)))
                    .roleStyle(.micro)
                Spacer(minLength: VoiceOourMetrics.Space.sm)
                Text("TODAY")
                    .roleStyle(.micro)
            }
        }
    }

    /// Always a fact: the selected day when there is one, otherwise the series
    /// scale, so the strip states how tall its tallest bar is without a hover
    /// and without reserving a blank line to say nothing. `ActivityBarPlot`
    /// owns the selected branch; this is the fallback summary.
    private var readoutSummary: String {
        let total = dayWordCounts.reduce(0, +)
        guard let maxDay = dayWordCounts.max(), maxDay > 0 else {
            return "no words in the last 14 days"
        }
        return "\(HomeFormat.grouped(total)) words · best day \(HomeFormat.grouped(maxDay))"
    }

    private var accessibilitySummary: String {
        guard let maxCount = dayWordCounts.max(), maxCount > 0,
            let index = dayWordCounts.firstIndex(of: maxCount)
        else {
            return "No words dictated"
        }
        let total = dayWordCounts.reduce(0, +)
        return "\(HomeFormat.grouped(total)) words over 14 days, "
            + "best day \(Self.dateLabel(dayOffset: 13 - index)), \(dayAccessibilityValue(index))"
    }

    private func bucketLabel(_ index: Int, _ context: ActivityBarPlotTextContext) -> String {
        switch context {
        case .readout:
            return Self.weekdayShort(dayOffset: 13 - index)
        case .accessibility:
            return Self.dateLabel(dayOffset: 13 - index)
        }
    }

    private func bucketValue(_ index: Int, _ context: ActivityBarPlotTextContext) -> String {
        let count = dayWordCounts[index]
        switch context {
        case .readout:
            return "\(HomeFormat.grouped(count)) words"
        case .accessibility:
            return dayAccessibilityValue(index)
        }
    }

    private func dayAccessibilityValue(_ index: Int) -> String {
        let count = dayWordCounts[index]
        return "\(HomeFormat.grouped(count)) \(count == 1 ? "word" : "words")"
    }

    private static func date(dayOffset: Int) -> Date {
        let calendar = RenderOverrides.calendar ?? Calendar.current
        let today = calendar.startOfDay(for: RenderOverrides.renderNow)
        return calendar.date(byAdding: .day, value: -dayOffset, to: today) ?? today
    }

    private static func weekdayShort(dayOffset: Int) -> String {
        weekdayFormatter.string(from: date(dayOffset: dayOffset))
    }

    private static func shortDate(dayOffset: Int) -> String {
        shortDateFormatter.string(from: date(dayOffset: dayOffset))
    }

    private static func dateLabel(dayOffset: Int) -> String {
        accessibilityDateFormatter.string(from: date(dayOffset: dayOffset))
    }
}
