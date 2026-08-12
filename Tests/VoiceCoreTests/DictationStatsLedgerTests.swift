import Foundation
import Testing

@testable import VoiceCore

/// The ledger is the counting half of the statistics split: it must fold every
/// session exactly once, keep counting after the transcript store evicts the
/// text it was derived from, and survive a relaunch without re-counting the
/// corpus it already folded.
@Suite("DictationStatsLedger")
struct DictationStatsLedgerTests {
    private func attributed(_ bundleId: String) -> RecentSessionOutcomeMetadata {
        RecentSessionOutcomeMetadata(disposition: .pasteAttempted, targetBundleId: bundleId)
    }

    private func temporaryStatsFile() -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent(DictationStatsStore.fileName))
    }

    // MARK: Folding

    @Test func ingestCountsTheSameCorpusOnlyOnce() {
        let corpus = [
            RecentSession(createdAt: fixedNow - 2 * day, text: text(4)),
            RecentSession(createdAt: fixedNow - day, text: text(6)),
            RecentSession(createdAt: fixedNow, text: text(5)),
        ]
        var ledger = DictationStatsLedger()
        ledger.ingest(corpus, calendar: utc)
        let once = ledger

        ledger.ingest(corpus, calendar: utc)

        #expect(ledger == once)
        #expect(ledger.dictations == 3)
        #expect(ledger.words == 15)
        #expect(ledger.days.count == 3)
    }

    /// The journal writes a session at transcription and amends it after
    /// insertion. Without the settle flag the destination app and the
    /// post-speech wait would never land; with a naive flag they would land on
    /// every subsequent fold.
    @Test func outcomeSettlesExactlyOnceAcrossRepeatedIngests() {
        let id = UUID()
        let pending = RecentSession(
            id: id, createdAt: fixedNow, text: text(10),
            stages: SessionStageTimings(captureMs: 10_000, startLatencyMs: 200))
        var ledger = DictationStatsLedger()
        ledger.ingest([pending], calendar: utc)

        #expect(ledger.apps.isEmpty)
        #expect(ledger.attributedOutcomes == 0)
        #expect(ledger.waitMs == 200)  // start latency is known before insertion

        let settled = RecentSession(
            id: id, createdAt: fixedNow, text: text(10),
            outcome: attributed("com.apple.TextEdit"),
            stages: SessionStageTimings(
                captureMs: 10_000, startLatencyMs: 200, stopReleaseToInsertionOutcomeMs: 1_500))
        ledger.ingest([settled], calendar: utc)

        #expect(ledger.dictations == 1)
        #expect(ledger.apps == ["com.apple.TextEdit": 1])
        #expect(ledger.attributedOutcomes == 1)
        #expect(ledger.waitMs == 1_700)

        let afterSettle = ledger
        ledger.ingest([settled], calendar: utc)
        #expect(ledger == afterSettle)
    }

    @Test func waitPrefersTheEndToEndMeasurementOverItsParts() {
        let stages = SessionStageTimings(
            captureMs: 10_000, asrMs: 1_000, insertMs: 2_000, startLatencyMs: 100,
            stopReleaseToInsertionOutcomeMs: 5_000)
        var endToEnd = DictationStatsLedger()
        endToEnd.ingest(
            [RecentSession(createdAt: fixedNow, text: text(10), outcome: attributed("com.a"), stages: stages)],
            calendar: utc)
        // 100 latency + the 5_000 span, never the 3_000 of parts it contains.
        #expect(endToEnd.waitMs == 5_100)

        var parts = DictationStatsLedger()
        parts.ingest(
            [
                RecentSession(
                    createdAt: fixedNow, text: text(10), outcome: attributed("com.a"),
                    stages: SessionStageTimings(captureMs: 10_000, asrMs: 1_000, insertMs: 2_000, startLatencyMs: 100))
            ],
            calendar: utc)
        #expect(parts.waitMs == 3_100)
    }

    @Test func untimedSessionsCountButDoNotMeasure() {
        var ledger = DictationStatsLedger()
        ledger.ingest(
            [
                RecentSession(createdAt: fixedNow - day, text: text(12), outcome: attributed("com.a")),
                // A zero capture is an absent measurement, not a zero-length one.
                RecentSession(
                    createdAt: fixedNow, text: text(8), outcome: attributed("com.b"),
                    stages: SessionStageTimings(captureMs: 0, asrMs: 500, insertMs: 500, startLatencyMs: 100)),
            ],
            calendar: utc)

        #expect(ledger.dictations == 2)
        #expect(ledger.words == 20)
        #expect(ledger.attributedOutcomes == 2)
        #expect(ledger.measuredDictations == 0)
        #expect(ledger.measuredWords == 0)
        #expect(ledger.spokenMs == 0)
        #expect(ledger.waitMs == 0)
    }

    // MARK: Records

    @Test func longestRecordKeepsWordsIdAndATruncatedPreview() throws {
        let long = RecentSession(createdAt: fixedNow - day, text: text(200))
        let short = RecentSession(createdAt: fixedNow, text: text(3))
        var ledger = DictationStatsLedger()
        ledger.ingest([short, long], calendar: utc)

        #expect(ledger.records.longestWords == 200)
        #expect(ledger.records.longestSessionID == long.id)
        let preview = try #require(ledger.records.longestPreview)
        #expect(preview.count == DictationStatsLedger.previewLimit)
        #expect(long.text.hasPrefix(preview))
    }

    /// A deleted transcript takes its quote with it; the dictation it counted
    /// still happened, and the ledger has no corpus to name a successor from.
    @Test func forgetDropsOnlyTheRecordHoldersPreview() {
        let record = RecentSession(createdAt: fixedNow - day, text: text(40))
        let other = RecentSession(createdAt: fixedNow, text: text(3))
        var ledger = DictationStatsLedger()
        ledger.ingest([record, other], calendar: utc)

        ledger.forget(sessionID: other.id)
        #expect(ledger.records.longestPreview != nil)

        ledger.forget(sessionID: record.id)
        #expect(ledger.records.longestPreview == nil)
        #expect(ledger.records.longestWords == 40)
        #expect(ledger.records.longestSessionID == record.id)
        #expect(ledger.dictations == 2)
    }

    @Test func fastestSpokenWPMRequiresEnoughWordsAndEnoughMicrophoneTime() {
        let tooFewWords = RecentSession(
            createdAt: fixedNow - 2 * day, text: text(7), stages: SessionStageTimings(captureMs: 60_000))
        let tooShort = RecentSession(
            createdAt: fixedNow - day, text: text(8), stages: SessionStageTimings(captureMs: 1_999))
        var ledger = DictationStatsLedger()
        ledger.ingest([tooFewWords, tooShort], calendar: utc)

        #expect(ledger.measuredDictations == 2)  // measured, just not a record
        #expect(ledger.records.fastestSpokenWPM == nil)
        #expect(ledger.records.fastestSessionID == nil)

        let eligible = RecentSession(createdAt: fixedNow, text: text(8), stages: SessionStageTimings(captureMs: 2_000))
        ledger.ingest([tooFewWords, tooShort, eligible], calendar: utc)

        #expect(isClose(ledger.records.fastestSpokenWPM, 240))  // 8 words in 2 s
        #expect(ledger.records.fastestSessionID == eligible.id)
    }

    // MARK: Day rows

    @Test func dayRowsMergePerCalendarDayAndStaySortedOldestFirst() {
        var ledger = DictationStatsLedger()
        ledger.ingest(
            [
                RecentSession(createdAt: fixedNow, text: text(5)),
                RecentSession(createdAt: fixedNow - 3_600, text: text(4)),  // same UTC day
            ],
            calendar: utc)

        #expect(ledger.days.count == 1)
        #expect(ledger.days[0].dictations == 2)
        #expect(ledger.days[0].words == 9)

        // Reconciliation can hand back a session older than anything folded.
        ledger.ingest([RecentSession(createdAt: fixedNow - 2 * day, text: text(3))], calendar: utc)

        #expect(
            ledger.days.map(\.startOfDay) == [
                utc.startOfDay(for: fixedNow - 2 * day), utc.startOfDay(for: fixedNow),
            ])
        #expect(ledger.days[0].words == 3)
    }

    @Test func dayRowsTrimToDayMemoryWithoutLosingLifetimeCounts() {
        let total = DictationStatsLedger.dayMemory + 10
        let sessions = (0..<total).map { index in
            RecentSession(createdAt: fixedNow - Double(total - 1 - index) * day, text: text(1))
        }
        var ledger = DictationStatsLedger()
        ledger.ingest(sessions, calendar: utc)

        #expect(ledger.days.count == DictationStatsLedger.dayMemory)
        #expect(
            ledger.days.first?.startOfDay
                == utc.startOfDay(for: fixedNow - Double(DictationStatsLedger.dayMemory - 1) * day))
        #expect(ledger.days.last?.startOfDay == utc.startOfDay(for: fixedNow))
        // The rows aged out; the tally they contributed to did not.
        #expect(ledger.dictations == total)
        #expect(ledger.words == total)
        #expect(ledger.startedAt == sessions[0].createdAt)
    }

    // MARK: Persistence

    /// `ingest` decides what is new by asking whether an id is in the `counted`
    /// ring. A ring shorter than the retained corpus would re-count sessions on
    /// every launch, so the relationship is a hard invariant, not a tuning knob.
    @Test func persistedLedgerRefusesToRecountTheRetainedCorpus() throws {
        let sessionStore = RecentSessionStore()  // the shipping retention cap
        #expect(sessionStore.limit <= DictationStatsLedger.ingestMemory)

        let fixture = temporaryStatsFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let corpus = sessionStore.normalized(
            (0..<sessionStore.limit).map { index in
                RecentSession(
                    createdAt: fixedNow - Double(sessionStore.limit - index) * 60,
                    text: text(3),
                    outcome: index.isMultiple(of: 5) ? attributed("com.a") : nil,
                    stages: SessionStageTimings(captureMs: 4_000, startLatencyMs: 50))
            })
        var ledger = DictationStatsLedger()
        ledger.ingest(corpus, calendar: utc)

        let statsStore = DictationStatsStore(url: fixture.url)
        try statsStore.save(ledger)
        var reloaded = try statsStore.load()
        #expect(reloaded == ledger)

        // A relaunch seeds from whatever transcripts are still on disk.
        reloaded.ingest(corpus, calendar: utc)
        #expect(reloaded == ledger)
        #expect(reloaded.dictations == sessionStore.limit)
    }

    @Test func statsFileSitsBesideTheTranscriptsItCounts() {
        let sessions = URL(fileURLWithPath: "/tmp/fixture-\(UUID().uuidString)/recent-sessions.json")
        let stats = DictationStatsStore(besideRecentSessionsAt: sessions)

        #expect(stats.url.deletingLastPathComponent() == sessions.deletingLastPathComponent())
        #expect(stats.url.lastPathComponent == DictationStatsStore.fileName)
    }

    @Test func storeLoadsAnEmptyLedgerForAMissingFile() throws {
        let fixture = temporaryStatsFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(try DictationStatsStore(url: fixture.url).load() == DictationStatsLedger())
    }

    /// A file this build cannot read is discarded rather than fatal: the caller
    /// re-ingests the retained corpus, so the worst case is a restarted tally.
    @Test func storeDiscardsALedgerWrittenByAnUnknownVersion() throws {
        let fixture = temporaryStatsFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "dictations": 41, "words": 9000}"#.utf8).write(to: fixture.url)

        #expect(try DictationStatsStore(url: fixture.url).load() == DictationStatsLedger())
    }

    @Test func resetClearsEveryCounter() {
        var ledger = DictationStatsLedger()
        ledger.ingest(
            [
                RecentSession(
                    createdAt: fixedNow, text: text(9), outcome: attributed("com.a"),
                    stages: SessionStageTimings(captureMs: 9_000, startLatencyMs: 100))
            ],
            calendar: utc)
        #expect(!ledger.isEmpty)

        ledger.reset()

        #expect(ledger == DictationStatsLedger())
        #expect(ledger.isEmpty)
        #expect(ledger.startedAt == nil)
        #expect(ledger.apps.isEmpty)
        #expect(ledger.records.longestPreview == nil)
    }

    // MARK: Decoding

    @Test func ledgerDecodesAFileMissingNewerKeysAndCarryingAnUnknownOne() throws {
        let legacyJSON = """
            {
              "version": 1,
              "started_at": 721692800,
              "dictations": 12,
              "words": 340,
              "retired_metric": "gone",
              "days": [{"startOfDay": 721692800, "dictations": 12, "words": 340}]
            }
            """

        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: Data(legacyJSON.utf8))

        #expect(ledger.dictations == 12)
        #expect(ledger.words == 340)
        #expect(ledger.startedAt == Date(timeIntervalSinceReferenceDate: 721_692_800))
        #expect(ledger.days.count == 1)
        #expect(ledger.characters == 0)
        #expect(ledger.measuredDictations == 0)
        #expect(ledger.measuredWords == 0)
        #expect(ledger.spokenMs == 0)
        #expect(ledger.waitMs == 0)
        #expect(ledger.attributedOutcomes == 0)
        #expect(ledger.hours == [Int](repeating: 0, count: 24))
        #expect(ledger.apps.isEmpty)
        #expect(ledger.records == DictationStatsLedger.Records())
        #expect(ledger.counted.isEmpty)
    }

    /// The hour histogram is indexed positionally, so a stored array of the
    /// wrong width would make every read a bounds gamble.
    @Test func ledgerRejectsAStoredHourHistogramOfTheWrongWidth() throws {
        let json = #"{"version": 1, "dictations": 3, "hours": [1, 2, 3]}"#
        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: Data(json.utf8))

        #expect(ledger.hours == [Int](repeating: 0, count: 24))
        #expect(ledger.dictations == 3)
    }
}
