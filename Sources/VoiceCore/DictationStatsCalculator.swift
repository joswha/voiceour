import Foundation

/// Everything Home states about the ledger, resolved once.
public struct DictationStatsSummary: Equatable, Sendable {
    public let totalSeconds: Double
    public let totalWords: Int
    public let totalSessions: Int
    public let averageWPM: Int
    public let timeSavedSeconds: Double
    public let activeDays: Int
    public let currentStreakDays: Int
    public let longestStreakDays: Int

    public init(
        totalSeconds: Double,
        totalWords: Int,
        totalSessions: Int,
        averageWPM: Int,
        timeSavedSeconds: Double,
        activeDays: Int,
        currentStreakDays: Int,
        longestStreakDays: Int
    ) {
        self.totalSeconds = totalSeconds
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.averageWPM = averageWPM
        self.timeSavedSeconds = timeSavedSeconds
        self.activeDays = activeDays
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

/// One day square in the activity grid.
public struct HeatmapCell: Equatable, Sendable {
    public let dayKey: String
    public let words: Int
    /// `0` for a day with no dictation, `1...4` for the quartile ladder.
    public let level: Int
    /// False for a cell the window contains but the calendar has not reached.
    /// Those squares are drawn as nothing at all rather than as an empty day.
    public let isInRange: Bool

    public init(dayKey: String, words: Int, level: Int, isInRange: Bool) {
        self.dayKey = dayKey
        self.words = words
        self.level = level
        self.isInRange = isInRange
    }
}

/// A month name and the column it starts over.
///
/// A named pair rather than a tuple: `HeatmapModel` is `Equatable` so views can
/// hold it as state, and Swift tuples carry `==` without conforming to
/// `Equatable`, so a tuple element would block the synthesis.
public struct HeatmapMonthLabel: Equatable, Sendable {
    public let column: Int
    public let label: String

    public init(column: Int, label: String) {
        self.column = column
        self.label = label
    }
}

/// The activity grid, resolved into exactly what the view draws.
public struct HeatmapModel: Equatable, Sendable {
    /// One column per week, oldest first, seven cells each. Row order starts at
    /// the calendar's `firstWeekday`, so a Monday-first region reads its own way
    /// round without the view knowing which region it is in.
    public let columns: [[HeatmapCell]]
    public let monthLabels: [HeatmapMonthLabel]
    /// `veryShortWeekdaySymbols` rotated to `firstWeekday`.
    public let weekdaySymbols: [String]
    /// The busiest in-range day in the window, which is what the level ladder
    /// is scaled against. Zero when the window holds no dictation.
    public let maxWords: Int

    public init(
        columns: [[HeatmapCell]],
        monthLabels: [HeatmapMonthLabel],
        weekdaySymbols: [String],
        maxWords: Int
    ) {
        self.columns = columns
        self.monthLabels = monthLabels
        self.weekdaySymbols = weekdaySymbols
        self.maxWords = maxWords
    }

    /// In-range days that carry at least one dictation.
    public var activeDaysInWindow: Int {
        columns.reduce(0) { total, column in
            total + column.reduce(0) { $0 + (($1.isInRange && $1.words > 0) ? 1 : 0) }
        }
    }
}

/// One app's row in Home's ranking.
public struct DictationAppFigure: Equatable, Sendable, Identifiable {
    public var bundleId: String
    public var name: String?
    public var sessions: Int
    public var words: Int
    /// sessions / leader's sessions, 0...1; the Home share bar's width.
    public var share: Double
    public var id: String { bundleId }

    public init(bundleId: String, name: String?, sessions: Int, words: Int, share: Double) {
        self.bundleId = bundleId
        self.name = name
        self.sessions = sessions
        self.words = words
        self.share = share
    }
}

/// Pure derivations over a ledger.
///
/// `today` and `calendar` are always explicit. Nothing here reads `Date()` or
/// `Calendar.current`: a streak that consults the wall clock cannot be tested,
/// and a committed UI fixture that consults the developer's region is not a
/// fixture.
public enum DictationStatsCalculator {
    public static func summary(
        of ledger: DictationStatsLedger,
        today: Date,
        calendar: Calendar
    ) -> DictationStatsSummary {
        let words = ledger.totalWords
        let seconds = ledger.totalSeconds
        let averageWPM: Int = {
            guard seconds > 0 else { return 0 }
            return Int((Double(words) / (seconds / 60)).rounded())
        }()
        let typedSeconds =
            Double(words) / Double(DictationStatsPolicy.assumedTypingWordsPerMinute) * 60
        return DictationStatsSummary(
            totalSeconds: seconds,
            totalWords: words,
            totalSessions: ledger.totalSessions,
            averageWPM: averageWPM,
            // Clamped at zero rather than shown negative: dictation slower than
            // the typing baseline saved no time, it did not cost the reader any.
            timeSavedSeconds: max(0, typedSeconds - seconds),
            activeDays: ledger.totalActiveDays,
            currentStreakDays: currentStreak(of: ledger, today: today, calendar: calendar),
            longestStreakDays: ledger.longestStreakDays
        )
    }

    /// Consecutive active days ending today, or ending yesterday when today has
    /// no dictation yet.
    ///
    /// Yesterday counts because a streak is a habit, and the habit is intact at
    /// 9am on a day the reader has not spoken into anything yet. It stops
    /// counting the moment a whole day passes with nothing in it.
    static func currentStreak(
        of ledger: DictationStatsLedger,
        today: Date,
        calendar: Calendar
    ) -> Int {
        let todayKey = DictationStatsLedger.dayKey(for: today, calendar: calendar)
        if ledger.days[todayKey] != nil {
            return ledger.streakLength(endingAt: todayKey)
        }
        guard let yesterdayKey = DictationStatsLedger.dayKey(offsetting: todayKey, byDays: -1) else {
            return 0
        }
        return ledger.streakLength(endingAt: yesterdayKey)
    }

    /// The `limit` apps that received the most dictations, ranked.
    ///
    /// Fully ordered rather than merely sorted: a dictionary iterates in an
    /// unspecified order, so ties break on words and then on bundle id, and two
    /// launches over one ledger rank the same apps identically.
    public static func topApps(of ledger: DictationStatsLedger, limit: Int) -> [DictationAppFigure] {
        guard limit > 0 else { return [] }
        let ranked = ledger.apps.sorted { lhs, rhs in
            if lhs.value.sessions != rhs.value.sessions { return lhs.value.sessions > rhs.value.sessions }
            if lhs.value.words != rhs.value.words { return lhs.value.words > rhs.value.words }
            return lhs.key < rhs.key
        }
        guard let leaderSessions = ranked.first?.value.sessions, leaderSessions > 0 else { return [] }
        return ranked.prefix(limit).map { entry in
            DictationAppFigure(
                bundleId: entry.key,
                name: entry.value.name,
                sessions: entry.value.sessions,
                words: entry.value.words,
                share: Double(entry.value.sessions) / Double(leaderSessions)
            )
        }
    }

    public static func heatmap(
        of ledger: DictationStatsLedger,
        today: Date,
        calendar: Calendar,
        weeks: Int
    ) -> HeatmapModel {
        let weeks = max(1, weeks)
        let todayKey = DictationStatsLedger.dayKey(for: today, calendar: calendar)
        // The window is walked in day keys, not in `Date`s: the keys are already
        // resolved local days, and stepping them through a fixed-offset calendar
        // keeps a daylight-saving boundary from folding two columns onto the
        // same seven squares.
        guard let lastColumnStartKey = weekStartKey(for: todayKey, calendar: calendar),
            let firstColumnStartKey = DictationStatsLedger.dayKey(
                offsetting: lastColumnStartKey,
                byDays: -7 * (weeks - 1)
            )
        else {
            return HeatmapModel(
                columns: [],
                monthLabels: [],
                weekdaySymbols: rotatedWeekdaySymbols(calendar),
                maxWords: 0
            )
        }

        let columnStartKeys = self.columnStartKeys(from: firstColumnStartKey, weeks: weeks)
        let raw = rawColumns(of: ledger, columnStartKeys: columnStartKeys, todayKey: todayKey)
        let maxWords = raw.reduce(0) { columnMax, column in
            max(columnMax, column.reduce(0) { max($0, $1.words) })
        }

        return HeatmapModel(
            columns: raw.map { column in
                column.map { cell in
                    HeatmapCell(
                        dayKey: cell.key,
                        words: cell.words,
                        level: level(words: cell.words, maxWords: maxWords),
                        isInRange: cell.isInRange
                    )
                }
            },
            monthLabels: monthLabels(columnStartKeys: columnStartKeys, calendar: calendar),
            weekdaySymbols: rotatedWeekdaySymbols(calendar),
            maxWords: maxWords
        )
    }

    /// A day-key level cell before the ladder is resolved: the quartile needs
    /// the window's busiest day, which is only known once every cell is read.
    private struct RawCell {
        let key: String
        let words: Int
        let isInRange: Bool
    }

    private static func columnStartKeys(from first: String, weeks: Int) -> [String] {
        var keys: [String] = []
        keys.reserveCapacity(weeks)
        var cursor = first
        for index in 0..<weeks {
            keys.append(cursor)
            guard index + 1 < weeks,
                let next = DictationStatsLedger.dayKey(offsetting: cursor, byDays: 7)
            else { break }
            cursor = next
        }
        return keys
    }

    private static func rawColumns(
        of ledger: DictationStatsLedger,
        columnStartKeys: [String],
        todayKey: String
    ) -> [[RawCell]] {
        columnStartKeys.map { columnStart in
            (0..<7).compactMap { row -> RawCell? in
                guard let key = DictationStatsLedger.dayKey(offsetting: columnStart, byDays: row) else {
                    return nil
                }
                let isInRange = key <= todayKey
                return RawCell(
                    key: key,
                    words: isInRange ? (ledger.days[key]?.words ?? 0) : 0,
                    isInRange: isInRange
                )
            }
        }
    }

    /// Quartiles of the window's busiest day. Any dictation at all reaches
    /// level 1: a day the reader used the app must not read as a day they did
    /// not, however quiet it was next to their best one.
    static func level(words: Int, maxWords: Int) -> Int {
        guard words > 0, maxWords > 0 else { return 0 }
        let quartile = Int((Double(words) / Double(maxWords) * 4).rounded(.up))
        return min(4, max(1, quartile))
    }

    /// The label for column `c` names the month column `c` starts in, and only
    /// when that differs from column `c - 1`. Column 0 is never labelled: its
    /// month began off the left edge, so naming it would date the window's
    /// first square to a month the reader cannot see the start of.
    static func monthLabels(columnStartKeys: [String], calendar: Calendar) -> [HeatmapMonthLabel] {
        let symbols = calendar.shortMonthSymbols
        var labels: [HeatmapMonthLabel] = []
        for index in columnStartKeys.indices.dropFirst() {
            guard let month = monthNumber(of: columnStartKeys[index]),
                let previousMonth = monthNumber(of: columnStartKeys[index - 1]),
                month != previousMonth,
                month >= 1,
                month <= symbols.count
            else { continue }
            labels.append(HeatmapMonthLabel(column: index, label: symbols[month - 1]))
        }
        return labels
    }

    private static func monthNumber(of dayKey: String) -> Int? {
        let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return Int(parts[1])
    }

    /// The key of the first day of the week containing `dayKey`.
    private static func weekStartKey(for dayKey: String, calendar: Calendar) -> String? {
        guard
            let date = DictationStatsLedger.date(forDayKey: dayKey, calendar: DictationStatsLedger.utcCalendar)
        else { return nil }
        // `firstWeekday` is the region's, read from the caller's calendar; the
        // arithmetic runs in UTC so the answer is a pure day offset.
        let weekday = DictationStatsLedger.utcCalendar.component(.weekday, from: date)
        let offset = -((weekday - calendar.firstWeekday + 7) % 7)
        return DictationStatsLedger.dayKey(offsetting: dayKey, byDays: offset)
    }

    static func rotatedWeekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = (calendar.firstWeekday - 1) % 7
        guard offset > 0 else { return symbols }
        return Array(symbols[offset...] + symbols[..<offset])
    }
}
