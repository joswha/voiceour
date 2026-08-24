import Foundation
import Testing

@testable import VoiceCore

/// The Sessions pane's search and day grouping used to be private members of a
/// SwiftUI `View`, so neither could be tested — and time-zone boundaries are
/// exactly where a date bug hides. These are the cases that were unreachable
/// before the logic moved here.
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

    private func session(
        _ text: String,
        at iso: String,
        bundleId: String?,
        appName: String? = nil
    ) -> RecentSession {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return RecentSession(
            createdAt: formatter.date(from: iso)!,
            text: text,
            outcome: RecentSessionOutcomeMetadata(
                disposition: .pasteAttempted,
                targetSafety: .normalText,
                targetBundleId: bundleId,
                targetAppName: appName
            )
        )
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
            appBundleId: nil,
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
            appBundleId: nil,
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
            appBundleId: nil,
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(byTime.map(\.text) == ["evening"])

        // 2026-03-01 is a Sunday, 2026-03-02 a Monday.
        let byDay = RecentSessionQuery.matches(
            in: sessions,
            query: "Sunday",
            appBundleId: nil,
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(byDay.map(\.text) == ["morning"])
    }

    // MARK: App filter

    @Test func anAppFilterAloneNarrowsToThatBundleId() {
        let utc = calendar("UTC")
        let sessions = [
            session("into ghostty", at: "2026-03-01T09:00:00Z", bundleId: "com.mitchellh.ghostty"),
            session("into textedit", at: "2026-03-01T10:00:00Z", bundleId: "com.apple.TextEdit"),
            session("into ghostty again", at: "2026-03-01T11:00:00Z", bundleId: "com.mitchellh.ghostty"),
        ]

        let matches = RecentSessionQuery.matches(
            in: sessions,
            query: "",
            appBundleId: "com.mitchellh.ghostty",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )

        #expect(matches.map(\.text) == ["into ghostty again", "into ghostty"])
    }

    /// Two lenses, not two lists: a filtered search shows the rows that satisfy
    /// both.
    @Test func theAppFilterAndTheQueryAreAnded() {
        let utc = calendar("UTC")
        let sessions = [
            session("ship the fix", at: "2026-03-01T09:00:00Z", bundleId: "com.apple.dt.Xcode"),
            session("ship the fix", at: "2026-03-01T10:00:00Z", bundleId: "com.apple.Terminal"),
            session("unrelated note", at: "2026-03-01T11:00:00Z", bundleId: "com.apple.dt.Xcode"),
        ]

        let matches = RecentSessionQuery.matches(
            in: sessions,
            query: "ship",
            appBundleId: "com.apple.dt.Xcode",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )

        #expect(matches.count == 1)
        #expect(matches.first?.outcome?.targetBundleId == "com.apple.dt.Xcode")
    }

    /// A row with no delivery target — written before bundle ids were persisted,
    /// or delivered nowhere — belongs to no app, so no app filter can show it.
    @Test func rowsWithoutATargetSurviveOnlyTheUnfilteredList() {
        let utc = calendar("UTC")
        let sessions = [
            session("no target", at: "2026-03-01T09:00:00Z", bundleId: nil),
            session("has a target", at: "2026-03-01T10:00:00Z", bundleId: "com.apple.TextEdit"),
        ]

        let unfiltered = RecentSessionQuery.matches(
            in: sessions,
            query: "",
            appBundleId: nil,
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(unfiltered.count == 2)

        let filtered = RecentSessionQuery.matches(
            in: sessions,
            query: "",
            appBundleId: "com.apple.TextEdit",
            timestamp: timestamp(utc),
            dayHeader: dayHeader(utc)
        )
        #expect(filtered.map(\.text) == ["has a target"])
    }

    // MARK: App facets

    @Test func facetsCountRowsPerAppAndRankByCount() {
        let sessions = [
            session("a", at: "2026-03-01T09:00:00Z", bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
            session("b", at: "2026-03-01T10:00:00Z", bundleId: "com.apple.dt.Xcode", appName: "Xcode"),
            session("c", at: "2026-03-01T11:00:00Z", bundleId: "com.apple.Terminal", appName: "Terminal"),
            session("d", at: "2026-03-01T12:00:00Z", bundleId: nil),
        ]

        let facets = RecentSessionQuery.appFacets(in: sessions)

        #expect(facets.count == 2)
        #expect(facets.map(\.bundleId) == ["com.apple.dt.Xcode", "com.apple.Terminal"])
        #expect(facets.map(\.count) == [2, 1])
        #expect(facets.map(\.id) == facets.map(\.bundleId))
    }

    /// Equal counts order by the label a reader sees, not by bundle id, so the
    /// menu reads alphabetically where it cannot rank.
    @Test func equalCountsOrderByDisplayLabel() {
        let sessions = [
            session("a", at: "2026-03-01T09:00:00Z", bundleId: "com.zzz.alpha", appName: "Alpha"),
            session("b", at: "2026-03-01T10:00:00Z", bundleId: "com.aaa.beta", appName: "Beta"),
        ]

        #expect(RecentSessionQuery.appFacets(in: sessions).map(\.name) == ["Alpha", "Beta"])
    }

    /// An app that was renamed is offered under the name the reader last saw.
    @Test func theNewestRowsNameWinsForAFacet() {
        let sessions = [
            session("old", at: "2026-03-01T09:00:00Z", bundleId: "com.example.editor", appName: "Editor"),
            session("new", at: "2026-03-01T11:00:00Z", bundleId: "com.example.editor", appName: "Editor Pro"),
            session("older", at: "2026-03-01T08:00:00Z", bundleId: "com.example.editor", appName: "Ed"),
        ]

        let facets = RecentSessionQuery.appFacets(in: sessions)

        #expect(facets.map(\.name) == ["Editor Pro"])
        #expect(facets.map(\.count) == [3])
    }

    /// A facet whose rows never carried a name keeps a nil name: the fallback is
    /// the display layer's, so the facet stays a record of what was persisted.
    @Test func aFacetWithoutAnyNameStaysNilAndFallsBackAtDisplay() {
        let sessions = [
            session("a", at: "2026-03-01T09:00:00Z", bundleId: "com.mitchellh.ghostty")
        ]

        let facet = RecentSessionQuery.appFacets(in: sessions).first

        #expect(facet?.name == nil)
        #expect(AppDisplayName.label(bundleId: facet?.bundleId, name: facet?.name) == "Ghostty")
    }

    @Test func historyWithNoTargetsOffersNoFacets() {
        let sessions = [session("a", at: "2026-03-01T09:00:00Z", bundleId: nil)]

        #expect(RecentSessionQuery.appFacets(in: sessions).isEmpty)
        #expect(RecentSessionQuery.appFacets(in: []).isEmpty)
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

}
