import Foundation

/// One day's sessions, newest first.
public struct RecentSessionDayGroup: Identifiable, Equatable, Sendable {
    public let day: Date
    public let sessions: [RecentSession]

    public var id: Date { day }

    public init(day: Date, sessions: [RecentSession]) {
        self.day = day
        self.sessions = sessions
    }
}

/// Period totals for the Sessions ledger, counted from `DictationStatsLedger`
/// rather than from the retained transcripts.
///
/// The transcript store keeps a fixed number of sessions, so a heavy month
/// overflows it and a corpus-derived "this month" silently undercounts the
/// moment it does. The ledger's daily rows outlive eviction, so these figures
/// stay true however much was dictated.
public struct RecentSessionTotals: Equatable, Sendable {
    public var wordsToday: Int
    public var sessionsToday: Int
    public var wordsThisMonth: Int
    public var sessionsThisMonth: Int

    public init(
        wordsToday: Int = 0,
        sessionsToday: Int = 0,
        wordsThisMonth: Int = 0,
        sessionsThisMonth: Int = 0
    ) {
        self.wordsToday = wordsToday
        self.sessionsToday = sessionsToday
        self.wordsThisMonth = wordsThisMonth
        self.sessionsThisMonth = sessionsThisMonth
    }
}

/// Searching, day-grouping and totalling recent sessions.
///
/// Extracted from `SessionsPane` so the logic is reachable without a SwiftUI
/// view: as private members of a `View` none of it could be tested, and the
/// time-zone and month boundaries are exactly where a date bug hides.
///
/// Every entry point takes its `Calendar`, `TimeZone`-bearing formatters and
/// `now` explicitly. Nothing here reads the current date or locale implicitly,
/// which is what makes a boundary case expressible in a test.
public enum RecentSessionQuery {
    /// Sessions newest first, filtered by `query` against transcript text and the
    /// two rendered timestamp forms the list shows.
    ///
    /// Matching the rendered strings rather than the `Date` is deliberate: the
    /// user searches for what they can see, so "14:32" and "Sunday" both work.
    /// `query` is expected pre-trimmed; an empty query matches everything.
    public static func matches(
        in sessions: [RecentSession],
        query: String,
        timestamp: (Date) -> String,
        dayHeader: (Date) -> String
    ) -> [RecentSession] {
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { session in
            session.text.localizedCaseInsensitiveContains(query)
                || timestamp(session.createdAt).localizedCaseInsensitiveContains(query)
                || dayHeader(session.createdAt).localizedCaseInsensitiveContains(query)
        }
    }

    /// Groups sessions by `calendar`'s start of day, newest day first and newest
    /// session first within each day.
    ///
    /// The calendar carries the time zone, so two sessions that are the same
    /// wall-clock day for the user group together even when their UTC dates
    /// differ.
    public static func dayGroups(
        of sessions: [RecentSession],
        calendar: Calendar
    ) -> [RecentSessionDayGroup] {
        Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.createdAt) }
            .map { RecentSessionDayGroup(day: $0.key, sessions: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    /// Today's and this month's word and dictation counts.
    ///
    /// "This month" is the same calendar month *and* year as `now`, so last
    /// January does not count toward this January.
    public static func totals(
        of ledger: DictationStatsLedger,
        calendar: Calendar,
        now: Date
    ) -> RecentSessionTotals {
        var totals = RecentSessionTotals()
        let today = calendar.startOfDay(for: now)
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        for day in ledger.days {
            if day.startOfDay == today {
                totals.wordsToday += day.words
                totals.sessionsToday += day.dictations
            }
            if calendar.component(.month, from: day.startOfDay) == currentMonth,
                calendar.component(.year, from: day.startOfDay) == currentYear
            {
                totals.wordsThisMonth += day.words
                totals.sessionsThisMonth += day.dictations
            }
        }
        return totals
    }
}
