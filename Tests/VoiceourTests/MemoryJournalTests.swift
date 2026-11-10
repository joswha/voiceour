import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers the coordinator's memory journal: what a delivered dictation folds
/// into memory, what the switch adds and keeps, deletion and erase, the agent
/// binding mirror, the Journal's merged entries, and the shared write tail.
/// Disk access goes through a spy unless a test is about the folder itself, and
/// then it is a real store in a temporary directory the test removes.
@Suite("Memory journal", .serialized)
@MainActor
struct MemoryJournalTests {
    /// Stands in for the memory folder's disk access: answers the launch load
    /// with a fixed value, records every write and clear in the order they ran,
    /// and can park the first write or fail chosen ones.
    // `lock` protects the recorded calls and counts; the answers and gate are immutable.
    private final class MemoryDiskSpy: @unchecked Sendable {
        enum Failure: Error {
            case injected
        }

        enum Call: Equatable {
            case write(MemoryWrite)
            case clear
        }

        private let lock = NSLock()
        private let initial: MemoryLoad
        private let failingWrites: Set<Int>
        private let failsClear: Bool
        private let firstWriteGate: DispatchSemaphore?
        private var recorded: [Call] = []
        private var writeNumber = 0
        private var finished = 0

        init(
            load: MemoryLoad = MemoryLoad(),
            failingWrites: Set<Int> = [],
            failsClear: Bool = false,
            parksFirstWrite: Bool = false
        ) {
            initial = load
            self.failingWrites = failingWrites
            self.failsClear = failsClear
            firstWriteGate = parksFirstWrite ? DispatchSemaphore(value: 0) : nil
        }

        var calls: [Call] { lock.withLock { recorded } }

        var writes: [MemoryWrite] {
            calls.compactMap { call in
                guard case .write(let plan) = call else { return nil }
                return plan
            }
        }

        var clearCount: Int { calls.filter { $0 == .clear }.count }

        /// Writes that returned, failed or not.
        var finishedWrites: Int { lock.withLock { finished } }

        func releaseFirstWrite() {
            firstWriteGate?.signal()
        }

        func load(_ store: MemoryStore) -> MemoryLoad {
            initial
        }

        func write(_ store: MemoryStore, _ plan: MemoryWrite) throws {
            let number = lock.withLock { () -> Int in
                recorded.append(.write(plan))
                writeNumber += 1
                return writeNumber
            }
            if number == 1 {
                firstWriteGate?.wait()
            }
            lock.withLock { finished += 1 }
            if failingWrites.contains(number) {
                throw Failure.injected
            }
        }

        func clear(_ store: MemoryStore) throws {
            lock.withLock { recorded.append(.clear) }
            if failsClear {
                throw Failure.injected
            }
        }
    }

    /// Captures Tern's pane and resolves it to one fixed session.
    private struct FixedSessionResolver: AgentSessionResolving {
        let pane: AgentFocusCapture
        let session: ResolvedAgentSession

        func capture(target: TargetSnapshot) async -> AgentFocusCapture? {
            pane
        }

        func resolve(target: TargetSnapshot, before: AgentFocusCapture) async -> ResolvedAgentSession? {
            session
        }
    }

    /// Returns one fixed snapshot for every binding.
    private struct FixedSessionReader: AgentSessionReading {
        let snapshot: AgentSessionSnapshot?

        func read(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
            snapshot
        }
    }

    // `lock` protects the current time.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) {
            current = start
        }

        var now: Date {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private struct Fixture {
        let coordinator: DictationCoordinator
        let clock: TestClock
    }

    /// 2027-01-15 08:00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    private let textEdit = FakeTracker()
    private let tern = FakeTracker(bundleId: "so.stencil.tern", appName: "Tern", safety: .normalText)
    private let pane = AgentFocusCapture(pane: "42", foregroundPid: 66_425)

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-memory-journal-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func resolved(_ sessionId: String) -> ResolvedAgentSession {
        ResolvedAgentSession(
            agent: .omp,
            sessionId: sessionId,
            sessionFile: "/Users/v/.omp/agent/sessions/-Users-v-voiceour/2026-11-09T17-51-31-000Z_\(sessionId).jsonl",
            workingDirectory: "/Users/v/voiceour",
            sessionTitle: nil,
            promptLogOffset: 963,
            resumable: false
        )
    }

    /// A coordinator whose History, ledger and settings live in `directory`.
    /// With a spy, memory disk access goes to it; without one, to the real
    /// store the coordinator derives beside History.
    private func makeFixture(
        directory: URL,
        rows: [RecentSession] = [],
        memoryEnabled: Bool = true,
        bindingEnabled: Bool = false,
        tracker: FakeTracker? = nil,
        outcome: InsertionOutcome = .pasteAttempted,
        disk: MemoryDiskSpy?,
        resolver: AgentSessionResolving = NoAgentSessionResolving(),
        reader: AgentSessionReading = NoAgentSessionReading()
    ) throws -> Fixture {
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save(rows)
        let clock = TestClock(t0)
        let calendar = self.calendar
        let load: @Sendable (MemoryStore) -> MemoryLoad
        let write: @Sendable (MemoryStore, MemoryWrite) throws -> Void
        let clear: @Sendable (MemoryStore) throws -> Void
        if let disk {
            load = { disk.load($0) }
            write = { try disk.write($0, $1) }
            clear = { try disk.clear($0) }
        } else {
            load = { $0.load() }
            write = { try $0.apply($1) }
            clear = { try $0.clear() }
        }
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("Ship the release notes today.")),
            tracker: tracker ?? textEdit,
            inserter: FakeInserter(outcome: outcome),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(agentSessionBindingEnabled: bindingEnabled, memoryEnabled: memoryEnabled),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            memoryLoad: load,
            memoryWrite: write,
            memoryClear: clear,
            agentSessions: resolver,
            agentSessionReader: reader,
            runtimeOverride: DictationRuntime(
                now: { clock.now },
                makeUUID: { UUID() },
                sleep: { _ in },
                calendar: { calendar }
            )
        )
        return Fixture(coordinator: coordinator, clock: clock)
    }

    private func deliver(_ coordinator: DictationCoordinator) async {
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }
    }

    /// Awaits every binding task, then every refresh pass, then the writes
    /// they queued.
    private func settle(_ coordinator: DictationCoordinator) async {
        while let entry = coordinator.agentBindingTasks.values.first {
            await entry.task.value
        }
        while let refresh = coordinator.agentRefreshTask {
            await refresh.value
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    private func month(_ date: Date) -> String {
        MemoryStore.monthKey(for: date, calendar: calendar)
    }

    // MARK: - Folding a delivered dictation

    @Test(arguments: [true, false])
    func aDeliveredDictationReachesMemoryOnlyWhileTheSwitchIsOn(enabled: Bool) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy()
        let fixture = try makeFixture(directory: directory, memoryEnabled: enabled, disk: disk)

        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)

        let row = try #require(fixture.coordinator.recentSessions.first)
        #expect(fixture.coordinator.lastOutcome == .pasteAttempted)
        if enabled {
            let entry = try #require(fixture.coordinator.memoryEntries.first)
            #expect(fixture.coordinator.memoryEntries.count == 1)
            #expect(entry.id == row.id)
            #expect(entry.kind == .dictation)
            #expect(entry.text == "Ship the release notes today.")
            #expect(entry.appBundleId == "com.apple.TextEdit")
            #expect(entry.appName == "TextEdit")
            // FakeRecorder reports 100 ms of audio.
            #expect(entry.captureSeconds == 0.1)
            #expect(disk.writes.count == 1)
            #expect(disk.writes.first?.months[month(t0)] == [entry])
        } else {
            #expect(fixture.coordinator.memoryEntries.isEmpty)
            #expect(disk.calls.isEmpty)
        }
    }

    @Test func aSecureTargetReachesNoRecord() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy()
        let fixture = try makeFixture(
            directory: directory,
            tracker: FakeTracker(bundleId: "com.apple.TextEdit", appName: "TextEdit", safety: .secure),
            outcome: .copiedOnly(reason: "secure_target"),
            disk: disk
        )

        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.recentSessions.isEmpty)
        #expect(fixture.coordinator.memoryEntries.isEmpty)
        #expect(disk.calls.isEmpty)
    }

    @Test func aFailedMemoryWriteIsReportedWithoutCostingDeliveryOrLaterWrites() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy(failingWrites: [1])
        let fixture = try makeFixture(directory: directory, disk: disk)

        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)
        await waitUntil { fixture.coordinator.errorMessage != nil }

        #expect(fixture.coordinator.errorMessage == "Memory could not be saved.")
        #expect(fixture.coordinator.lastOutcome == .pasteAttempted)
        #expect(try fixture.coordinator.recentSessionStore.load().map(\.text) == ["Ship the release notes today."])
        let first = try #require(fixture.coordinator.memoryEntries.first)

        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)

        #expect(disk.writes.count == 2)
        // The later write still runs, and rewrites the month whole, so the
        // entry the failed write lost reaches disk with it.
        let written = try #require(disk.writes.last?.months[month(t0)])
        #expect(written.count == 2)
        #expect(written.first == first)
        #expect(fixture.coordinator.errorMessage == nil)
    }

    // MARK: - Launch

    @Test func launchShowsWhatTheFolderHoldsWithTheSwitchOff() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let topics = [MemoryTopic(id: "release", name: "Release", summary: "Shipping the app.", createdAt: t0)]
        let entries = [
            MemoryEntry(id: id(1), createdAt: t0, text: "Tag the build.", appBundleId: "com.apple.TextEdit"),
            MemoryEntry(id: id(2), createdAt: t0.addingTimeInterval(60), kind: .note, text: "Ask about notarizing."),
        ]
        try MemoryStore(root: directory.appendingPathComponent("memory", isDirectory: true))
            .apply(MemoryPlanner.rebuild(entries: entries, topics: topics, calendar: calendar))

        let fixture = try makeFixture(directory: directory, memoryEnabled: false, disk: nil)

        #expect(fixture.coordinator.memoryEntries == entries)
        #expect(fixture.coordinator.memoryTopics == topics)
        #expect(fixture.coordinator.memoryExistsOnDisk)
        #expect(fixture.coordinator.errorMessage == nil)
    }

    @Test func launchWithNoFolderCreatesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try makeFixture(directory: directory, disk: nil)
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.memoryEntries.isEmpty)
        #expect(fixture.coordinator.memoryTopics.isEmpty)
        #expect(!fixture.coordinator.memoryExistsOnDisk)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory").path))
    }

    @Test func anUnreadableMemoryFileIsSetAsideAndReported() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entriesDirectory = directory.appendingPathComponent("memory/entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entriesDirectory, withIntermediateDirectories: true)
        let unreadable = entriesDirectory.appendingPathComponent("2027-01.json")
        try Data("not a month".utf8).write(to: unreadable)

        let fixture = try makeFixture(directory: directory, disk: nil)

        #expect(fixture.coordinator.memoryEntries.isEmpty)
        let message = try #require(fixture.coordinator.errorMessage)
        #expect(message.hasPrefix("Memory could not be read — kept as 2027-01.json.corrupt-"))
        #expect(!FileManager.default.fileExists(atPath: unreadable.path))
    }

    // MARK: - The switch

    @Test func turningMemoryOnKeepsExactlyTheHistoryRowsItLacks() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = MemoryEntry(id: id(1), createdAt: t0.addingTimeInterval(-120), text: "Kept as it was said.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [kept]))
        let rows = [
            RecentSession(id: id(2), createdAt: t0.addingTimeInterval(-60), text: "Only History has this."),
            RecentSession(id: id(1), createdAt: t0.addingTimeInterval(-120), text: "History's copy."),
        ]
        let fixture = try makeFixture(directory: directory, rows: rows, memoryEnabled: false, disk: disk)

        fixture.coordinator.setMemoryEnabled(true)
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.settings.memoryEnabled)
        #expect(fixture.coordinator.memoryEntries == [kept, MemoryEntry(rows[0])])
        #expect(disk.writes.count == 1)
        #expect(disk.writes.first?.months[month(t0)] == [kept, MemoryEntry(rows[0])])
        let saved = try SettingsStore(url: directory.appendingPathComponent("settings.json")).load()
        #expect(saved.memoryEnabled)
    }

    @Test func turningMemoryOffKeepsWhatItHoldsAndWritesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = MemoryEntry(id: id(1), createdAt: t0.addingTimeInterval(-120), text: "Kept as it was said.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [kept]))
        let fixture = try makeFixture(directory: directory, disk: disk)
        let revision = fixture.coordinator.memoryRevision

        fixture.coordinator.setMemoryEnabled(false)
        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)

        #expect(!fixture.coordinator.settings.memoryEnabled)
        #expect(fixture.coordinator.recentSessions.count == 1)
        #expect(fixture.coordinator.memoryEntries == [kept])
        #expect(fixture.coordinator.memoryRevision == revision)
        #expect(disk.calls.isEmpty)
    }

    // MARK: - Deletion and erase

    /// Deleting the only entry of its day removes the day page; deleting one
    /// of two rewrites it.
    @Test(arguments: [true, false])
    func deletingARowRemovesItsMemoryEntryAndItsDayPage(sharesItsDay: Bool) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = RecentSession(id: id(1), createdAt: t0, text: "Delete this one.")
        let other = MemoryEntry(
            id: id(2),
            createdAt: t0.addingTimeInterval(sharesItsDay ? 60 : 86_400),
            text: "Keep this one."
        )
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [MemoryEntry(row), other]))
        let fixture = try makeFixture(directory: directory, rows: [row], disk: disk)

        #expect(await fixture.coordinator.deleteRecentSession(id: row.id))

        #expect(fixture.coordinator.recentSessions.isEmpty)
        #expect(fixture.coordinator.memoryEntries == [other])
        let plan = try #require(disk.writes.last)
        #expect(disk.writes.count == 1)
        #expect(plan.months[month(t0)] == [other])
        let dayPage = MemoryPages.dayPath(t0, calendar: calendar)
        #expect(plan.removedPages.contains(dayPage) == !sharesItsDay)
        #expect(plan.pages.map(\.path).contains(dayPage) == sharesItsDay)
    }

    @Test func deletingAnIdOnlyMemoryHoldsDeletesIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = MemoryEntry(id: id(1), createdAt: t0, kind: .note, text: "Call the notary.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [note]))
        let fixture = try makeFixture(directory: directory, disk: disk)

        #expect(await fixture.coordinator.deleteRecentSession(id: note.id))

        #expect(fixture.coordinator.memoryEntries.isEmpty)
        #expect(disk.writes.count == 1)
        #expect(disk.writes.first?.months[month(t0)] == [])
        #expect(disk.writes.first?.removedPages.contains(MemoryPages.notesPath(month: month(t0))) == true)
    }

    @Test func clearingHistoryLeavesMemory() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = RecentSession(id: id(1), createdAt: t0, text: "Kept in memory.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [MemoryEntry(row)]))
        let fixture = try makeFixture(directory: directory, rows: [row], disk: disk)

        #expect(await fixture.coordinator.clearRecentSessions())

        #expect(fixture.coordinator.recentSessions.isEmpty)
        #expect(fixture.coordinator.memoryEntries == [MemoryEntry(row)])
        #expect(disk.calls.isEmpty)
    }

    @Test func clearMemoryRunsOnceAfterTheWritesQueuedBeforeIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy(parksFirstWrite: true)
        let fixture = try makeFixture(directory: directory, disk: disk)
        let entry = MemoryEntry(id: id(1), createdAt: t0, text: "Written first.")

        fixture.coordinator.commitMemory(entries: [entry])
        await waitUntil { disk.writes.count == 1 }
        let clearing = Task { @MainActor in await fixture.coordinator.clearMemory() }
        await waitUntil { fixture.coordinator.memoryEntries.isEmpty }
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(disk.clearCount == 0)

        disk.releaseFirstWrite()

        #expect(await clearing.value)
        #expect(disk.calls.count == 2)
        #expect(disk.calls.last == .clear)
        #expect(disk.clearCount == 1)
        #expect(fixture.coordinator.memoryTopics.isEmpty)
    }

    @Test func aFailedClearIsReported() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = MemoryEntry(id: id(1), createdAt: t0, text: "Still on disk.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [entry]), failsClear: true)
        let fixture = try makeFixture(directory: directory, disk: disk)

        #expect(await fixture.coordinator.clearMemory() == false)

        #expect(disk.clearCount == 1)
        #expect(fixture.coordinator.errorMessage == "Memory could not be erased.")
    }

    // MARK: - Agent session binding mirror

    @Test func anAttachedBindingSetsTheEntrysThread() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy()
        let fixture = try makeFixture(
            directory: directory,
            bindingEnabled: true,
            tracker: tern,
            disk: disk,
            resolver: FixedSessionResolver(pane: pane, session: resolved("01a1c16f"))
        )

        await deliver(fixture.coordinator)
        await settle(fixture.coordinator)

        let binding = try #require(fixture.coordinator.recentSessions.first?.agentSession)
        let entry = try #require(fixture.coordinator.memoryEntries.first)
        #expect(entry.thread == JournalThreadRef(binding))
        #expect(entry.thread?.sessionId == "01a1c16f")
        // The fold, then the mirror.
        #expect(disk.writes.count == 2)
        #expect(disk.writes.last?.months[month(t0)] == [entry])
    }

    @Test func aRefreshThatMarksTheRowNotSentUpdatesTheEntry() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var binding = AgentSessionBinding(resolved("01a1c16e"), boundAt: t0)
        binding.sessionTitle = "Deploys"
        binding.resumable = true
        let row = RecentSession(id: id(1), createdAt: t0, text: "Deploy the cluster.", agentSession: binding)
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [MemoryEntry(row)]))
        let fixture = try makeFixture(
            directory: directory,
            rows: [row],
            bindingEnabled: true,
            disk: disk,
            reader: FixedSessionReader(
                snapshot: AgentSessionSnapshot(title: "Deploys", sessionFileExists: true, prompts: [])
            )
        )
        #expect(fixture.coordinator.memoryEntries.first?.thread?.sent == nil)
        fixture.clock.now = t0.addingTimeInterval(AgentPromptSendMatcher.sendWindow + 1)

        fixture.coordinator.refreshAgentSessions()
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.recentSessions.first?.agentSession?.send == .notSent)
        #expect(fixture.coordinator.memoryEntries.first?.thread?.sent == false)
        #expect(disk.writes.count == 1)
    }

    @Test func turningBindingOffClearsEveryThread() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentSessionBinding(resolved("01a1c16f"), boundAt: t0)
        let row = RecentSession(id: id(1), createdAt: t0, text: "Deploy the cluster.", agentSession: binding)
        let note = MemoryEntry(
            id: id(2),
            createdAt: t0.addingTimeInterval(60),
            kind: .note,
            text: "Check the staging logs.",
            thread: JournalThreadRef(agent: .claudeCode, sessionId: "5d1e")
        )
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [MemoryEntry(row), note]))
        let fixture = try makeFixture(directory: directory, rows: [row], bindingEnabled: true, disk: disk)

        fixture.coordinator.setAgentSessionBinding(false)
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        #expect(fixture.coordinator.memoryEntries.count == 2)
        #expect(fixture.coordinator.memoryEntries.allSatisfy { $0.thread == nil })
        #expect(disk.writes.count == 1)
    }

    // MARK: - Journal entries

    @Test func journalEntriesHoldEachIdOnceOldestFirst() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = MemoryEntry(id: id(1), createdAt: t0.addingTimeInterval(-30), text: "Memory's copy.")
        let note = MemoryEntry(id: id(2), createdAt: t0, kind: .note, text: "A note.")
        let disk = MemoryDiskSpy(load: MemoryLoad(entries: [shared, note]))
        let rows = [
            // Same instant as the note: memory's entry comes first.
            RecentSession(id: id(4), createdAt: t0, text: "Made with the note."),
            RecentSession(id: id(3), createdAt: t0.addingTimeInterval(-10), text: "Only History has this."),
            RecentSession(id: id(1), createdAt: t0.addingTimeInterval(-30), text: "History's copy."),
        ]
        let fixture = try makeFixture(directory: directory, rows: rows, memoryEnabled: false, disk: disk)

        let entries = fixture.coordinator.journalEntries

        #expect(entries.map(\.id) == [id(1), id(3), id(2), id(4)])
        #expect(entries.map(\.text) == ["Memory's copy.", "Only History has this.", "A note.", "Made with the note."])
        #expect(entries.map(\.kind) == [.dictation, .dictation, .note, .dictation])
    }

    // MARK: - Termination

    @Test func terminationAwaitsAMemoryWriteQueuedBeforeIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryDiskSpy(parksFirstWrite: true)
        let fixture = try makeFixture(directory: directory, disk: disk)

        fixture.coordinator.commitMemory(entries: [MemoryEntry(id: id(1), createdAt: t0, text: "Must land.")])
        await waitUntil { disk.writes.count == 1 }
        var terminated = false
        let termination = Task { @MainActor in
            await fixture.coordinator.prepareForTermination()
            terminated = true
        }
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!terminated)
        #expect(disk.finishedWrites == 0)

        disk.releaseFirstWrite()
        await termination.value

        #expect(terminated)
        #expect(disk.finishedWrites == 1)
    }
}
