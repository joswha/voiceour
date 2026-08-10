import Foundation
import Testing

@testable import VoiceCore

@Suite("DictationInsights")
struct DictationInsightsTests {
    // Fixed, wall-time-independent fixtures. UTC has no DST, so subtracting a
    // whole day always moves exactly one calendar day back — that determinism
    // is the whole point of injecting the calendar.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
    private let day: TimeInterval = 86_400

    /// Builds a body with exactly `n` whitespace-separated words.
    private func text(_ n: Int) -> String {
        n <= 0 ? "" : (1...n).map { "w\($0)" }.joined(separator: " ")
    }

    private func isClose(_ value: Double?, _ expected: Double, tol: Double = 1e-6) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < tol
    }

    private func insights(_ sessions: [RecentSession]) -> DictationInsights {
        DictationInsights(sessions: sessions, calendar: utc, now: fixedNow)
    }

    @Test func emptyStoreIsAllAbsences() {
        let result = insights([])

        #expect(result.sessionCount == 0)
        #expect(result.totalWords == 0)
        #expect(result.totalCharacters == 0)
        #expect(result.uniqueWordCount == 0)
        #expect(result.earliestDate == nil)
        #expect(!result.spansMultipleDays)

        #expect(result.timedSessionCount == 0)
        #expect(result.totalCaptureMs == 0)
        #expect(result.timeSavedMs == 0)
        #expect(!result.isTimeSavedEstimated)

        #expect(result.speakingWPM == nil)
        #expect(result.speedMultiplier == nil)
        #expect(result.peakSessionWPM == nil)

        #expect(result.hourBuckets == [Int](repeating: 0, count: 24))
        #expect(result.dayWordCounts == [Int](repeating: 0, count: 14))
        #expect(result.streakDays == 0)

        #expect(result.longestSessionWords == nil)
        #expect(result.longestSessionPreview == nil)
        #expect(result.destinations.isEmpty)
        #expect(result.attributedOutcomeCount == 0)
    }

    @Test func timeSavedMeasuredPathMatchesHandMath() {
        // 60 words: typing at 40 wpm = 90_000 ms; measured speech = 20_000 ms.
        let session = RecentSession(createdAt: fixedNow, text: text(60), stages: SessionStageTimings(captureMs: 20_000))
        let result = insights([session])

        #expect(result.timeSavedMs == 70_000)
        #expect(!result.isTimeSavedEstimated)  // fully timed store
        #expect(result.timedSessionCount == 1)
        #expect(result.totalCaptureMs == 20_000)
    }

    @Test func timeSavedClampsSlowerThanTypingToZero() {
        // 10 words typing = 15_000 ms; a lethargic 60_000 ms of speech.
        let session = RecentSession(createdAt: fixedNow, text: text(10), stages: SessionStageTimings(captureMs: 60_000))
        let result = insights([session])

        #expect(result.timeSavedMs == 0)  // max(0, 15_000 - 60_000)
    }

    @Test func timeSavedEstimatedPathUsesAssumedSpeech() {
        // Untimed: typing 15_000 ms minus assumed speech 4_000 ms = 1_100 ms/word.
        let untimed = RecentSession(createdAt: fixedNow, text: text(10))
        let mixed = insights([
            untimed,
            RecentSession(createdAt: fixedNow, text: text(10), stages: SessionStageTimings(captureMs: 5_000)),
        ])

        #expect(insights([untimed]).timeSavedMs == 11_000)
        #expect(insights([untimed]).isTimeSavedEstimated)  // no measured session
        #expect(mixed.isTimeSavedEstimated)  // one of two timed
    }

    @Test func fullyTimedStoreIsNotEstimated() {
        let session = RecentSession(createdAt: fixedNow, text: text(10), stages: SessionStageTimings(captureMs: 5_000))
        #expect(!insights([session]).isTimeSavedEstimated)
    }

    @Test func speakingWPMAndMultiplierFromTimedSessionsOnly() {
        // 30 + 20 words over 1 + 1 minute => 50 words / 2 min = 25 wpm.
        let a = RecentSession(createdAt: fixedNow, text: text(30), stages: SessionStageTimings(captureMs: 60_000))
        let b = RecentSession(createdAt: fixedNow, text: text(20), stages: SessionStageTimings(captureMs: 60_000))
        let untimed = RecentSession(createdAt: fixedNow, text: text(100))  // excluded
        let result = insights([a, b, untimed])

        #expect(result.timedSessionCount == 2)
        #expect(isClose(result.speakingWPM, 25))
        #expect(isClose(result.speedMultiplier, 25.0 / 40.0))  // 0.625
    }

    @Test func peakSessionWPMEligibility() {
        // Too few words and too short a capture: both eligibility floors.
        let tiny = RecentSession(createdAt: fixedNow, text: text(2), stages: SessionStageTimings(captureMs: 100))
        #expect(insights([tiny]).peakSessionWPM == nil)

        let eligible = RecentSession(createdAt: fixedNow, text: text(8), stages: SessionStageTimings(captureMs: 2_000))
        let expected = Double(8) / (Double(2_000) / 60_000)  // 240 wpm
        #expect(isClose(insights([tiny, eligible]).peakSessionWPM, expected))
        #expect(isClose(insights([tiny, eligible]).peakSessionWPM, 240))
    }

    @Test func streakAndDayWordCounts() {
        let sessions = [
            RecentSession(createdAt: fixedNow, text: text(5)),  // today
            RecentSession(createdAt: fixedNow - day, text: text(3)),  // yesterday
            RecentSession(createdAt: fixedNow - 2 * day, text: text(2)),  // 2 days ago
            RecentSession(createdAt: fixedNow - 4 * day, text: text(7)),  // 4 days ago (gap at 3)
        ]
        let result = insights(sessions)

        var expectedDays = [Int](repeating: 0, count: 14)
        expectedDays[13] = 5  // today
        expectedDays[12] = 3  // yesterday
        expectedDays[11] = 2  // 2 days ago
        expectedDays[9] = 7  // 4 days ago
        #expect(result.dayWordCounts == expectedDays)

        // today, -1, -2 present; -3 missing breaks the walk-back => 3.
        #expect(result.streakDays == 3)
        #expect(result.spansMultipleDays)
        #expect(result.hourBuckets[22] == 4)
    }

    @Test func streakIsZeroWhenTodayHasNoSession() {
        let sessions = [
            RecentSession(createdAt: fixedNow - day, text: text(5)),
            RecentSession(createdAt: fixedNow - 2 * day, text: text(5)),
        ]
        #expect(insights(sessions).streakDays == 0)
    }

    @Test func destinationsTruncateShareAndTieOrdering() {
        func attributed(_ bundleId: String, _ count: Int) -> [RecentSession] {
            (0..<count).map { _ in
                RecentSession(
                    createdAt: fixedNow, text: text(1),
                    outcome: RecentSessionOutcomeMetadata(
                        disposition: .pasteAttempted,
                        targetBundleId: bundleId))
            }
        }

        var sessions: [RecentSession] = []
        sessions += attributed("com.a", 5)
        sessions += attributed("com.b", 5)  // ties com.a on count -> ordered after by bundleId
        sessions += attributed("com.c", 4)
        sessions += attributed("com.d", 3)
        sessions += attributed("com.e", 2)
        sessions += attributed("com.f", 2)
        sessions += attributed("com.g", 1)
        sessions += attributed("com.h", 1)
        sessions += attributed("com.i", 1)  // dropped by top-8
        sessions += attributed("com.j", 1)  // dropped by top-8
        // Unattributed outcomes must not count toward the share denominator.
        sessions.append(
            RecentSession(
                createdAt: fixedNow, text: text(1), outcome: RecentSessionOutcomeMetadata(disposition: .copiedOnly)))
        sessions.append(
            RecentSession(
                createdAt: fixedNow, text: text(1),
                outcome: RecentSessionOutcomeMetadata(
                    disposition: .failed,
                    targetBundleId: "")))

        let result = insights(sessions)

        #expect(result.destinations.count == 8)
        #expect(
            result.destinations.map(\.bundleId) == [
                "com.a", "com.b", "com.c", "com.d", "com.e", "com.f", "com.g", "com.h",
            ])
        #expect(result.destinations[0].count == 5)
        // Denominator is the 25 attributed outcomes, not the 27 total — and it
        // is published, because the destination list itself is truncated to 8.
        #expect(isClose(result.destinations[0].share, 5.0 / 25.0))
        #expect(result.attributedOutcomeCount == 25)
    }

    @Test func uniqueWordCountIgnoresCaseAndPunctuation() {
        let session = RecentSession(createdAt: fixedNow, text: "Hello, hello world.")
        #expect(insights([session]).uniqueWordCount == 2)
    }

    @Test func longestSessionPreviewCollapsesNewlines() {
        let session = RecentSession(createdAt: fixedNow, text: "  line one\nline two\r\n  ")
        let result = insights([session])

        #expect(result.longestSessionWords == 4)
        #expect(result.longestSessionPreview == "line one line two")
    }

    @Test func longestSessionPreviewFallsBackForEmptyText() {
        let session = RecentSession(createdAt: fixedNow, text: "\n\r  ")
        let result = insights([session])

        #expect(result.longestSessionWords == 0)
        #expect(result.longestSessionPreview == "Empty transcript")
    }
}
