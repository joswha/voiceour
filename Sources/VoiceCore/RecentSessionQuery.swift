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

/// Searching and day-grouping recent sessions.
///
/// Extracted from the console's history surface so the logic is reachable without
/// a SwiftUI view: as private members of a `View` none of it could be tested, and
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
}
