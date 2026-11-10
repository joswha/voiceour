import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers Link Earlier Dictations and Unlink from Thread: which rows a run
/// asks about, what it links and what it leaves, the counts it publishes, and
/// that turning binding off, Clear History and quit drop a run in flight.
/// The prompt logs are a fake reader; History and memory live in a temporary
/// directory and a write spy.
@Suite("Link earlier dictations", .serialized)
@MainActor
struct LinkEarlierDictationsTests {
    /// Answers every reading with one fixed run and records the queries. When
    /// parked, a reading signals `entered`, blocks until released, and then
    /// answers nothing if its task was cancelled, as the real reader does.
    // `lock` protects the recorded queries and cancellations; the answer and gate are immutable.
    private final class FakeEvidenceReader: AgentPromptEvidenceReading, @unchecked Sendable {
        private let lock = NSLock()
        private let answer: PromptEvidenceRun
        private let gate: DispatchSemaphore?
        let entered = TestGate()
        private var asked: [[PromptEvidenceQuery]] = []
        private var cancellations: [Bool] = []

        init(_ answer: PromptEvidenceRun = PromptEvidenceRun(), parks: Bool = false) {
            self.answer = answer
            gate = parks ? DispatchSemaphore(value: 0) : nil
        }

        var readings: [[PromptEvidenceQuery]] { lock.withLock { asked } }
        /// Per released reading, whether its task was cancelled by then.
        var cancelledOnRelease: [Bool] { lock.withLock { cancellations } }

        func release() {
            gate?.signal()
        }

        func evidence(for queries: [PromptEvidenceQuery]) -> PromptEvidenceRun {
            lock.withLock { asked.append(queries) }
            guard let gate else { return answer }
            entered.fire()
            gate.wait()
            let cancelled = Task.isCancelled
            lock.withLock { cancellations.append(cancelled) }
            return cancelled ? PromptEvidenceRun() : answer
        }
    }

    // `lock` protects the counts.
    private final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var historySaves = 0
        private var memoryWrites = 0

        var history: Int { lock.withLock { historySaves } }
        var memory: Int { lock.withLock { memoryWrites } }

        func recordHistory() {
            lock.withLock { historySaves += 1 }
        }

        func recordMemory() {
            lock.withLock { memoryWrites += 1 }
        }
    }

    private struct Fixture {
        let coordinator: DictationCoordinator
        let directory: URL
        let writes: WriteCounter
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    private let longText = "Deploy the cluster to staging before lunch."
    private let otherText = "Write the release notes for the Granite update."

    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func row(
        _ index: Int,
        text: String,
        agentSession: AgentSessionBinding? = nil,
        unlinked: AgentLinkMiss? = nil
    ) -> RecentSession {
        RecentSession(
            id: id(index),
            // A higher index is older, so seeded rows keep their order in History.
            createdAt: t0.addingTimeInterval(-60 * TimeInterval(index)),
            text: text,
            agentSession: agentSession,
            unlinked: unlinked
        )
    }

    private func paneBinding(_ sessionId: String) -> AgentSessionBinding {
        AgentSessionBinding(
            agent: .omp,
            sessionId: sessionId,
            workingDirectory: "/Users/v/voiceour",
            boundAt: t0,
            send: .sent(sentAt: t0, text: nil)
        )
    }

    private func match(_ sessionId: String, sentAt: Date, sessionFile: String? = nil) -> PromptEvidenceMatch {
        PromptEvidenceMatch(
            agent: .claudeCode,
            sessionId: sessionId,
            sentAt: sentAt,
            sessionFile: sessionFile,
            workingDirectory: "/Users/v/voiceour",
            title: "Deploys"
        )
    }

    private func makeFixture(
        rows: [RecentSession],
        memory: [MemoryEntry] = [],
        bindingEnabled: Bool = true,
        reader: FakeEvidenceReader
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-link-earlier-tests-\(UUID().uuidString)", isDirectory: true)
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save(rows)
        let writes = WriteCounter()
        let calendar = self.calendar
        let now = t0
        let load = MemoryLoad(entries: memory)
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("Unused.")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(agentSessionBindingEnabled: bindingEnabled, memoryEnabled: true),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            memoryLoad: { _ in load },
            memoryWrite: { _, _ in writes.recordMemory() },
            memoryClear: { _ in },
            memoryPagesFormat: { _ in MemoryPages.formatStamp(calendar: calendar) },
            recentSessionSnapshotSave: { store, sessions in
                writes.recordHistory()
                try store.save(sessions)
            },
            promptEvidence: reader,
            runtimeOverride: DictationRuntime(
                now: { now },
                makeUUID: { UUID() },
                sleep: { _ in },
                calendar: { calendar }
            )
        )
        return Fixture(coordinator: coordinator, directory: directory, writes: writes)
    }

    /// Awaits the run in flight, then every write it queued.
    private func settle(_ coordinator: DictationCoordinator) async {
        while let run = coordinator.linkEarlierTask {
            await run.task.value
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    // MARK: - A run

    /// One reading asks about every unbound row long enough to name a
    /// session, and links only a row exactly one session held: a row already
    /// bound, one the person unlinked, one too short, one several sessions
    /// held and one no session held are left as they were.
    @Test func aRunLinksOnlyTheRowsExactlyOneSessionHeld() async throws {
        let sessionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-link-earlier-session-\(UUID().uuidString).jsonl")
        try Data().write(to: sessionFile)
        defer { try? FileManager.default.removeItem(at: sessionFile) }
        let matched = row(1, text: longText)
        let missed = row(2, text: otherText, unlinked: .focusMoved)
        let bound = row(3, text: longText, agentSession: paneBinding("01a1c16e"))
        let removed = row(4, text: longText, unlinked: .removedByYou)
        let short = row(5, text: "Deploy the cluster to staging.")
        let notFound = row(6, text: "Book the train to Lyon for Thursday morning.")
        let ambiguous = row(7, text: "Rename the island settings section to Appearance.")
        let rows = [matched, missed, bound, removed, short, notFound, ambiguous]
        let sentAt = matched.createdAt.addingTimeInterval(4)
        // The fake also claims the rows the run must not touch, so only the
        // run's own gates keep them unlinked.
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(
                matches: [
                    matched.id: match("c1", sentAt: sentAt, sessionFile: sessionFile.path),
                    missed.id: match("c2", sentAt: missed.createdAt, sessionFile: "/nonexistent/c2.jsonl"),
                    bound.id: match("c3", sentAt: bound.createdAt),
                    removed.id: match("c4", sentAt: removed.createdAt),
                    ambiguous.id: match("c5", sentAt: ambiguous.createdAt),
                ],
                ambiguous: [ambiguous.id]
            )
        )
        let fixture = try makeFixture(rows: rows, reader: reader)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator
        let before = coordinator.recentSessions
        let savesBefore = fixture.writes.history

        coordinator.linkEarlierDictations()
        #expect(coordinator.linkEarlierRun?.isRunning == true)
        await settle(coordinator)

        #expect(reader.readings.count == 1)
        #expect(
            reader.readings.first
                == [before[0], before[1], before[5], before[6]].map {
                    PromptEvidenceQuery(id: $0.id, text: $0.text, at: $0.createdAt)
                }
        )
        let expected = AgentSessionBinding(
            agent: .claudeCode,
            sessionId: "c1",
            sessionFile: sessionFile.path,
            workingDirectory: "/Users/v/voiceour",
            sessionTitle: "Deploys",
            boundAt: before[0].createdAt,
            resumable: true,
            send: .sent(sentAt: sentAt, text: nil),
            evidence: .words
        )
        let sessions = coordinator.recentSessions
        #expect(sessions[0].agentSession == expected)
        #expect(sessions[1].agentSession?.sessionId == "c2")
        #expect(sessions[1].agentSession?.resumable == false)
        #expect(sessions[1].unlinked == nil)
        #expect(Array(sessions[2...]) == Array(before[2...]))
        #expect(try coordinator.recentSessionStore.load() == sessions)
        #expect(fixture.writes.history == savesBefore + 1)

        #expect(
            coordinator.linkEarlierRun == LinkEarlierRun(isRunning: false, linked: 2, notFound: 1, ambiguous: 1)
        )
        #expect(
            coordinator.linkEarlierRun?.summary
                == "Linked 2 earlier dictations. 1 was not found in any local agent's prompts. "
                + "1 matched several sessions and was left unlinked."
        )
    }

    @Test func theSummaryAddsASentenceOnlyForACountAboveZero() {
        #expect(
            LinkEarlierRun(isRunning: false, linked: 0, notFound: 3, ambiguous: 0).summary
                == "Linked 0 earlier dictations. 3 were not found in any local agent's prompts."
        )
        #expect(
            LinkEarlierRun(isRunning: false, linked: 1, notFound: 0, ambiguous: 2).summary
                == "Linked 1 earlier dictation. 2 matched several sessions and were left unlinked."
        )
        #expect(
            LinkEarlierRun(isRunning: false).summary
                == "Every earlier dictation is already linked, was unlinked by you, or has fewer than 6 words."
        )
    }

    /// The memory entry of a linked row carries the thread and its evidence,
    /// in one commit for the whole run.
    @Test func aRunMirrorsItsLinksIntoMemoryInOneCommit() async throws {
        let first = row(1, text: longText)
        let second = row(2, text: otherText)
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(matches: [
                first.id: match("c1", sentAt: first.createdAt),
                second.id: match("c2", sentAt: second.createdAt),
            ])
        )
        let fixture = try makeFixture(
            rows: [first, second],
            memory: [MemoryEntry(first), MemoryEntry(second)],
            reader: reader
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator

        coordinator.linkEarlierDictations()
        await settle(coordinator)

        #expect(coordinator.memoryEntries.map(\.thread?.evidence) == [.words, .words])
        #expect(coordinator.memoryEntries.map(\.thread?.sessionId) == ["c2", "c1"])
        #expect(coordinator.memoryEntries.allSatisfy { $0.thread?.sent == true })
        #expect(fixture.writes.memory == 1)
    }

    @Test func aRunIsRefusedWhileBindingIsOff() async throws {
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(matches: [id(1): match("c1", sentAt: t0)])
        )
        let fixture = try makeFixture(rows: [row(1, text: longText)], bindingEnabled: false, reader: reader)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.coordinator.linkEarlierDictations()
        await settle(fixture.coordinator)

        #expect(reader.readings.isEmpty)
        #expect(fixture.coordinator.linkEarlierRun == nil)
        #expect(fixture.coordinator.recentSessions.first?.agentSession == nil)
    }

    @Test func aSecondPressWhileARunReadsStartsNothing() async throws {
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(matches: [id(1): match("c1", sentAt: t0)]),
            parks: true
        )
        let fixture = try makeFixture(rows: [row(1, text: longText)], reader: reader)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator

        coordinator.linkEarlierDictations()
        await reader.entered.wait()
        coordinator.linkEarlierDictations()
        reader.release()
        await settle(coordinator)

        #expect(reader.readings.count == 1)
        #expect(coordinator.linkEarlierRun?.linked == 1)
    }

    enum Interruption: String, CaseIterable, Sendable {
        case bindingOff
        case clearHistory
        case quit
    }

    /// Each interruption cancels the reading and drops whatever it found:
    /// no row is linked and nothing more is written.
    @Test(arguments: Interruption.allCases)
    func anInterruptionDropsTheRunInFlight(_ interruption: Interruption) async throws {
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(matches: [id(1): match("c1", sentAt: t0)]),
            parks: true
        )
        let fixture = try makeFixture(rows: [row(1, text: longText)], reader: reader)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator

        coordinator.linkEarlierDictations()
        await reader.entered.wait()
        let inFlight = try #require(coordinator.linkEarlierTask?.task)
        switch interruption {
        case .bindingOff: coordinator.setAgentSessionBinding(false)
        case .clearHistory: #expect(await coordinator.clearRecentSessions())
        case .quit: await coordinator.prepareForTermination()
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
        let savesAfterInterruption = fixture.writes.history
        #expect(coordinator.linkEarlierTask == nil)
        reader.release()
        await inFlight.value
        await settle(coordinator)

        #expect(reader.cancelledOnRelease == [true])
        #expect(coordinator.linkEarlierRun == nil)
        #expect(coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        #expect(try coordinator.recentSessionStore.load().allSatisfy { $0.agentSession == nil })
        #expect(fixture.writes.history == savesAfterInterruption)
    }

    // MARK: - Unlink

    /// Unlinking keeps the row unlinked for good: memory loses the thread
    /// with it, and a later run does not even ask about the row.
    @Test func anUnlinkedRowStaysUnlinkedAcrossALaterRun() async throws {
        let bound = row(1, text: longText, agentSession: paneBinding("01a1c16e"))
        let reader = FakeEvidenceReader(
            PromptEvidenceRun(matches: [bound.id: match("c1", sentAt: bound.createdAt)])
        )
        let fixture = try makeFixture(rows: [bound], memory: [MemoryEntry(bound)], reader: reader)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator
        #expect(coordinator.memoryEntries.first?.thread != nil)

        coordinator.unlinkThread(rowID: bound.id)
        _ = await coordinator.recentSessionPersistenceTail?.value

        #expect(coordinator.recentSessions.first?.agentSession == nil)
        #expect(coordinator.recentSessions.first?.unlinked == .removedByYou)
        #expect(try coordinator.recentSessionStore.load().first?.unlinked == .removedByYou)
        #expect(coordinator.memoryEntries.first?.thread == nil)
        #expect(coordinator.memoryEntries.first?.unlinked == .removedByYou)

        coordinator.linkEarlierDictations()
        await settle(coordinator)
        coordinator.refreshAgentSessions()
        while let refresh = coordinator.agentRefreshTask {
            await refresh.value
        }

        #expect(reader.readings.isEmpty)
        #expect(coordinator.linkEarlierRun == LinkEarlierRun(isRunning: false))
        #expect(coordinator.recentSessions.first?.agentSession == nil)
        #expect(coordinator.recentSessions.first?.unlinked == .removedByYou)
    }
}
