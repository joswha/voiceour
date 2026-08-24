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

/// One app that appears as a delivery target in history, and how many rows it
/// received.
public struct RecentSessionAppFacet: Equatable, Sendable, Identifiable {
    public var bundleId: String
    /// The newest row's name for this app, when any row carries one.
    public var name: String?
    public var count: Int

    public var id: String { bundleId }

    public init(bundleId: String, name: String?, count: Int) {
        self.bundleId = bundleId
        self.name = name
        self.count = count
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
    /// Sessions newest first, filtered to `appBundleId`'s delivery target when
    /// one is given, then by `query` against transcript text and the two
    /// rendered timestamp forms the list shows.
    ///
    /// Matching the rendered strings rather than the `Date` is deliberate: the
    /// user searches for what they can see, so "14:32" and "Sunday" both work.
    /// `query` is expected pre-trimmed; an empty query and a nil filter match
    /// everything.
    public static func matches(
        in sessions: [RecentSession],
        query: String,
        appBundleId: String?,
        timestamp: (Date) -> String,
        dayHeader: (Date) -> String
    ) -> [RecentSession] {
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
        guard query.isEmpty == false || appBundleId != nil else { return sorted }
        return sorted.filter { session in
            guard appBundleId == nil || session.outcome?.targetBundleId == appBundleId else {
                return false
            }
            guard !query.isEmpty else { return true }
            return session.text.localizedCaseInsensitiveContains(query)
                || timestamp(session.createdAt).localizedCaseInsensitiveContains(query)
                || dayHeader(session.createdAt).localizedCaseInsensitiveContains(query)
        }
    }

    /// The apps history can be filtered by, most-used first.
    ///
    /// Rows with no delivery target contribute nothing: there is no app to
    /// filter them by. The name is the newest row's, so an app that was renamed
    /// is offered under the name the reader last saw. Ordering is total — count,
    /// then display label, then bundle id — so the menu does not reshuffle
    /// between reloads.
    public static func appFacets(in sessions: [RecentSession]) -> [RecentSessionAppFacet] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for session in sessions.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let bundleId = session.outcome?.targetBundleId else { continue }
            counts[bundleId, default: 0] += 1
            if names[bundleId] == nil, let name = session.outcome?.targetAppName {
                names[bundleId] = name
            }
        }
        return
            counts
            .map { RecentSessionAppFacet(bundleId: $0.key, name: names[$0.key], count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let lhsLabel = AppDisplayName.label(bundleId: lhs.bundleId, name: lhs.name)
                let rhsLabel = AppDisplayName.label(bundleId: rhs.bundleId, name: rhs.name)
                let comparison = lhsLabel.localizedCaseInsensitiveCompare(rhsLabel)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.bundleId < rhs.bundleId
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
