import Foundation
import Testing

@testable import VoiceCore

@Suite("DictationInsights")
struct DictationInsightsTests {
    private func ledger(_ sessions: [RecentSession]) -> DictationStatsLedger {
        var ledger = DictationStatsLedger()
        ledger.ingest(sessions, calendar: utc)
        return ledger
    }

    /// The common case: every counted session is also still retained.
    private func insights(_ sessions: [RecentSession]) -> DictationInsights {
        DictationInsights(ledger: ledger(sessions), keptSessions: sessions, calendar: utc, now: fixedNow)
    }

    // MARK: Absence

    @Test func emptyLedgerAndEmptyCorpusAreAllAbsences() {
        let result = insights([])

        #expect(result.dictationCount == 0)
        #expect(result.totalWords == 0)
        #expect(result.totalCharacters == 0)
        #expect(result.startedAt == nil)
        #expect(!result.spansMultipleDays)

        #expect(result.measuredDictationCount == 0)
        #expect(result.measuredWords == 0)
        #expect(result.spokenMs == 0)
        #expect(result.waitMs == 0)
        #expect(result.elapsedMs == 0)
        #expect(result.typedMs(typingWPM: DictationInsights.defaultTypingWPM) == 0)
        #expect(result.timeSavedMs(typingWPM: DictationInsights.defaultTypingWPM) == 0)
        // Nothing counted means nothing left unmeasured to disclose.
        #expect(result.isFullyMeasured)

        #expect(result.dictationWPM == nil)
        #expect(result.spokenWPM == nil)
        #expect(result.speedMultiplier(typingWPM: DictationInsights.defaultTypingWPM) == nil)
        #expect(result.peakSpokenWPM == nil)

        #expect(result.hourBuckets == [Int](repeating: 0, count: 24))
        #expect(result.dayWordCounts == [Int](repeating: 0, count: DictationInsights.dayWindow))
        #expect(result.streakDays == 0)

        #expect(result.longestSessionWords == nil)
        #expect(result.longestSessionPreview == nil)
        #expect(result.destinations.isEmpty)
        #expect(result.attributedOutcomeCount == 0)

        #expect(result.keptTranscriptCount == 0)
        #expect(result.uniqueWordCount == 0)

        #expect(result == .empty)
    }

    // MARK: Lifetime vs retention

    /// The defect the whole ledger exists for: with lifetime figures derived
    /// from the retained transcripts, a corpus at its cap makes the dictation
    /// count freeze at exactly the cap and the word total plateau.
    @Test func lifetimeFiguresSurviveTranscriptEviction() {
        let store = RecentSessionStore()  // the shipping retention cap
        let total = store.limit + 100
        var tally = DictationStatsLedger()
        var corpus: [RecentSession] = []
        var oldest: Date?

        // History arrives in batches and the corpus is re-capped between them,
        // exactly as it is at runtime: the ledger only ever sees what survived.
        for batch in stride(from: 0, to: total, by: 100) {
            let arrivals = (batch..<Swift.min(batch + 100, total)).map { index in
                RecentSession(createdAt: fixedNow - Double(total - index) * 60, text: text(3))
            }
            oldest = oldest ?? arrivals.first?.createdAt
            corpus = store.normalized(corpus + arrivals)
            tally.ingest(corpus, calendar: utc)
        }

        let result = DictationInsights(ledger: tally, keptSessions: corpus, calendar: utc, now: fixedNow)

        #expect(result.dictationCount == total)
        #expect(result.totalWords == total * 3)
        #expect(result.totalCharacters == total * text(3).count)
        #expect(result.startedAt == oldest)
        // Only the vocabulary window shrank to the retention cap.
        #expect(result.keptTranscriptCount == store.limit)
        #expect(corpus.count == store.limit)
    }

    @Test func startedAtDoesNotAdvanceWhenTheOldestTranscriptIsEvicted() {
        let store = RecentSessionStore(limit: 2)
        let oldest = RecentSession(createdAt: fixedNow - 3 * day, text: text(2))
        var tally = DictationStatsLedger()

        var corpus = store.normalized([oldest, RecentSession(createdAt: fixedNow - 2 * day, text: text(2))])
        tally.ingest(corpus, calendar: utc)
        let seeded = DictationInsights(ledger: tally, keptSessions: corpus, calendar: utc, now: fixedNow)
        #expect(seeded.startedAt == oldest.createdAt)

        corpus = store.normalized(corpus + [RecentSession(createdAt: fixedNow - day, text: text(2))])
        tally.ingest(corpus, calendar: utc)
        #expect(!corpus.contains { $0.id == oldest.id })

        let result = DictationInsights(ledger: tally, keptSessions: corpus, calendar: utc, now: fixedNow)
        #expect(result.startedAt == oldest.createdAt)
        #expect(result.dictationCount == 3)
    }

    // MARK: Time economy

    @Test func timeEconomyCountsMeasuredSessionsOnly() {
        let timed = RecentSession(createdAt: fixedNow, text: text(52), stages: SessionStageTimings(captureMs: 20_000))
        let untimed = RecentSession(createdAt: fixedNow, text: text(200))
        let result = insights([timed, untimed])

        #expect(result.dictationCount == 2)
        #expect(result.totalWords == 252)
        #expect(result.measuredDictationCount == 1)
        #expect(result.measuredWords == 52)
        #expect(result.spokenMs == 20_000)
        #expect(result.waitMs == 0)
        #expect(!result.isFullyMeasured)

        // 52 words at 52 wpm is one minute; the untimed 200 words buy nothing.
        #expect(result.typedMs(typingWPM: 52) == 60_000)
        #expect(result.timeSavedMs(typingWPM: 52) == 40_000)
    }

    /// Clamping each session and summing would keep every fast dictation's
    /// saving while throwing away every slow one's cost.
    @Test func timeSavedClampsAtTheAggregateNotPerSession() {
        let fast = RecentSession(createdAt: fixedNow, text: text(104), stages: SessionStageTimings(captureMs: 20_000))
        let slow = RecentSession(createdAt: fixedNow, text: text(26), stages: SessionStageTimings(captureMs: 120_000))
        let result = insights([fast, slow])

        // 130 words type in 150_000 ms; the pair actually cost 140_000 ms.
        #expect(result.elapsedMs == 140_000)
        #expect(result.typedMs(typingWPM: 52) == 150_000)
        #expect(result.timeSavedMs(typingWPM: 52) == 10_000)
        // Per-session clamping would have reported the fast session's saving alone.
        #expect(result.timeSavedMs(typingWPM: 52) != 100_000)

        // Slower than typing overall is a zero, never a negative.
        #expect(insights([slow]).timeSavedMs(typingWPM: 52) == 0)
    }

    @Test func typedTimeAndMultiplierFollowTheTypingBaseline() {
        let session = RecentSession(createdAt: fixedNow, text: text(52), stages: SessionStageTimings(captureMs: 60_000))
        let result = insights([session])

        #expect(result.typedMs(typingWPM: 52) == 60_000)
        #expect(result.typedMs(typingWPM: 100) == 31_200)
        #expect(isClose(result.speedMultiplier(typingWPM: 52), 1))
        #expect(isClose(result.speedMultiplier(typingWPM: 100), 0.52))
        // A faster assumed typist leaves less to save.
        #expect(result.timeSavedMs(typingWPM: 100) == 0)

        #expect(DictationInsights.clamp(0) == DictationInsights.typingWPMRange.lowerBound)
        #expect(DictationInsights.clamp(1_000) == DictationInsights.typingWPMRange.upperBound)
        #expect(DictationInsights.clamp(52) == 52)
        #expect(result.typedMs(typingWPM: 0) == result.typedMs(typingWPM: DictationInsights.typingWPMRange.lowerBound))
        #expect(
            result.speedMultiplier(typingWPM: 1_000)
                == result.speedMultiplier(typingWPM: DictationInsights.typingWPMRange.upperBound))
    }

    @Test func dictationRateTrailsSpeakingRateByExactlyTheWait() {
        let session = RecentSession(
            createdAt: fixedNow,
            text: text(52),
            outcome: RecentSessionOutcomeMetadata(disposition: .pasteAttempted, targetBundleId: "com.a"),
            stages: SessionStageTimings(captureMs: 30_000, startLatencyMs: 0, stopReleaseToInsertionOutcomeMs: 30_000)
        )
        let result = insights([session])

        #expect(result.spokenMs == 30_000)
        #expect(result.waitMs == 30_000)
        #expect(result.elapsedMs == 60_000)
        #expect(isClose(result.spokenWPM, 104))  // speech alone
        #expect(isClose(result.dictationWPM, 52))  // hotkey to text on screen

        let unmeasured = insights([RecentSession(createdAt: fixedNow, text: text(52))])
        #expect(unmeasured.spokenWPM == nil)
        #expect(unmeasured.dictationWPM == nil)
    }

    // MARK: Rhythm

    @Test func dayWindowAndStreakComeFromTheLedgerDayRows() {
        let sessions = [
            RecentSession(createdAt: fixedNow, text: text(5)),  // today
            RecentSession(createdAt: fixedNow - day, text: text(3)),  // yesterday
            RecentSession(createdAt: fixedNow - 2 * day, text: text(2)),  // 2 days ago
            RecentSession(createdAt: fixedNow - 4 * day, text: text(7)),  // 4 days ago (gap at 3)
        ]
        let result = insights(sessions)

        var expectedDays = [Int](repeating: 0, count: DictationInsights.dayWindow)
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

    // MARK: Destinations

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
        #expect(result.destinations.reduce(0) { $0 + $1.count } == 23)  // the two singletons fell off
    }

    // MARK: Kept transcripts

    @Test func uniqueWordCountIgnoresCaseAndPunctuationAndCoversKeptTranscriptsOnly() {
        let kept = RecentSession(createdAt: fixedNow, text: "Hello, hello world.")
        let evicted = RecentSession(createdAt: fixedNow - day, text: "alpha beta gamma delta")
        let result = DictationInsights(
            ledger: ledger([kept, evicted]), keptSessions: [kept], calendar: utc, now: fixedNow)

        #expect(result.uniqueWordCount == 2)  // "hello" once, "world"
        #expect(result.keptTranscriptCount == 1)
        #expect(result.dictationCount == 2)  // the evicted transcript still counts
    }

    @Test func longestSessionPreviewCollapsesNewlines() {
        let session = RecentSession(createdAt: fixedNow, text: "  line one\nline two\r\n  ")
        let result = insights([session])

        #expect(result.longestSessionWords == 4)
        #expect(result.longestSessionPreview == "line one line two")
    }

    @Test func longestSessionPreviewIsAbsentForAnEmptyTranscript() {
        let session = RecentSession(createdAt: fixedNow, text: "\n\r  ")
        let result = insights([session])

        #expect(result.longestSessionWords == 0)
        #expect(result.longestSessionPreview == nil)
    }
}
