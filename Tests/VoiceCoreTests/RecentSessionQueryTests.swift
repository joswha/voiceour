import Foundation
import Testing

@testable import VoiceCore

/// The Sessions pane's search, day grouping and ledger totals used to be private
/// members of a SwiftUI `View`, so none of it could be tested — and time-zone and
/// month boundaries are exactly where a date bug hides. These are the cases that
/// were unreachable before the logic moved here.
@Suite("Recent session query")
struct RecentSessionQueryTests {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func session(_ text: String, at iso: String) -> RecentSession {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return RecentSession(createdAt: formatter.date(from: iso)!, text: text)
    }

    private func timestamp(_ calendar: Calendar) -> (Date) -> String {
        { date in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
    }

    private func dayHeader(_ calendar: Calendar) -> (Date) -> String {
        { date in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE · MMM d · yyyy"
            return formatter.string(from: date)
        }
    }

    // MARK: Search

    @Test func emptyQueryReturnsEverythingNewestFirst() {
        let utc = calendar("UTC")
        let sessions = [
            session("older", at: "2026-03-01T09:00:00Z"),
            session("newer", at: "2026-03-01T17:00:00Z"),
        ]

        let matches = RecentSessionQuery.matches(
            in: sessions,
            query: "",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )

        #expect(matches.map(\.text) == ["newer", "older"])
    }

    @Test func queryMatchesTranscriptTextCaseInsensitively() {
        let utc = calendar("UTC")
        let sessions = [
            session("Ship the NSPasteboard fix", at: "2026-03-01T09:00:00Z"),
            session("unrelated note", at: "2026-03-01T10:00:00Z"),
        ]

        let matches = RecentSessionQuery.matches(
            in: sessions,
            query: "nspasteboard",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )

        #expect(matches.map(\.text) == ["Ship the NSPasteboard fix"])
    }

    /// The user searches for what they can see, so the rendered timestamp and the
    /// rendered day name both have to match — not the underlying Date.
    @Test func queryMatchesRenderedTimestampAndDayName() {
        let utc = calendar("UTC")
        let sessions = [
            session("morning", at: "2026-03-01T09:15:00Z"),
            session("evening", at: "2026-03-02T21:45:00Z"),
        ]

        let byTime = RecentSessionQuery.matches(
            in: sessions,
            query: "21:45",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(byTime.map(\.text) == ["evening"])

        // 2026-03-01 is a Sunday, 2026-03-02 a Monday.
        let byDay = RecentSessionQuery.matches(
            in: sessions,
            query: "Sunday",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(byDay.map(\.text) == ["morning"])
    }

    // MARK: Day grouping

    /// Two sessions six hours apart in UTC are the same local day in Los Angeles
    /// and different local days in UTC. The calendar's time zone decides, which is
    /// the whole reason it is a parameter.
    @Test func sameDayGroupingFollowsTheCalendarTimeZone() {
        let sessions = [
            session("late evening local", at: "2026-03-02T04:00:00Z"),
            session("morning local", at: "2026-03-02T18:00:00Z"),
        ]

        let losAngeles = RecentSessionQuery.dayGroups(of: sessions, calendar: calendar("America/Los_Angeles"))
        #expect(losAngeles.count == 2)

        let sessionsInOneLocalDay = [
            session("first", at: "2026-03-02T17:00:00Z"),
            session("second", at: "2026-03-02T23:00:00Z"),
        ]
        let oneGroup = RecentSessionQuery.dayGroups(
            of: sessionsInOneLocalDay,
            calendar: calendar("America/Los_Angeles")
        )
        #expect(oneGroup.count == 1)
        #expect(oneGroup.first?.sessions.map(\.text) == ["second", "first"])
    }

    @Test func dayGroupsAreNewestDayFirst() {
        let utc = calendar("UTC")
        let groups = RecentSessionQuery.dayGroups(
            of: [
                session("oldest", at: "2026-02-27T09:00:00Z"),
                session("newest", at: "2026-03-02T09:00:00Z"),
                session("middle", at: "2026-03-01T09:00:00Z"),
            ],
            calendar: utc
        )

        #expect(groups.flatMap { $0.sessions.map(\.text) } == ["newest", "middle", "oldest"])
        #expect(groups.map(\.day) == groups.map(\.day).sorted(by: >))
    }

    // MARK: Totals

    @Test func totalsCountOnlyTodayAndOnlyTheCurrentMonth() {
        let utc = calendar("UTC")
        let now = ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z")!
        let totals = RecentSessionQuery.totals(
            of: [
                session("three words today", at: "2026-03-15T08:00:00Z"),
                session("two today", at: "2026-03-15T22:00:00Z"),
                session("earlier this month", at: "2026-03-02T08:00:00Z"),
                session("last month entirely", at: "2026-02-27T08:00:00Z"),
            ],
            calendar: utc,
            now: now
        )

        #expect(totals.sessionsToday == 2)
        #expect(totals.wordsToday == 5)
        #expect(totals.sessionsThisMonth == 3)
        #expect(totals.wordsThisMonth == 8)
    }

    /// A month boundary is not just the month number: the same March a year
    /// earlier must not count toward this March.
    @Test func totalsRequireTheSameMonthAndTheSameYear() {
        let utc = calendar("UTC")
        let now = ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z")!
        let totals = RecentSessionQuery.totals(
            of: [
                session("this march", at: "2026-03-04T08:00:00Z"),
                session("last march", at: "2025-03-04T08:00:00Z"),
            ],
            calendar: utc,
            now: now
        )

        #expect(totals.sessionsThisMonth == 1)
        #expect(totals.wordsThisMonth == 2)
        #expect(totals.sessionsToday == 0)
    }

    @Test func emptyHistoryTotalsAreAllZero() {
        let totals = RecentSessionQuery.totals(of: [], calendar: calendar("UTC"), now: Date())

        #expect(totals == RecentSessionTotals())
    }
}
