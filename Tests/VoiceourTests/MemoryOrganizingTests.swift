import Foundation
import Synchronization
import Testing

@testable import VoiceCore
@testable import Voiceour

/// 2027-01-15 08:00:00 UTC.
private let organizingStart = Date(timeIntervalSince1970: 1_800_000_000)

/// The label every answering organizer in this file returns.
private let ideaLabel = EntryLabel(
    kind: .idea,
    kindConfidence: 0.9,
    topicID: "release",
    topicConfidence: 0.8,
    keep: 2,
    model: OrganizerPolicy.model,
    labeledAt: organizingStart
)

private let releaseTopic = MemoryTopic(
    id: "release", name: "Release", summary: "Shipping the app.", createdAt: organizingStart)
private let gardenTopic = MemoryTopic(
    id: "garden-plans", name: "Garden plans", summary: "Beds and seeds.", createdAt: organizingStart)

/// Stands in for the sorting model: records every request, counts how many
/// are in flight at once, and can hold every answer until released.
private final class OrganizerSpy: EntryOrganizing {
    struct Call: Equatable, Sendable {
        let text: String
        let topics: [MemoryTopic]
    }

    private struct State {
        var calls: [Call] = []
        var holding: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
        var inFlight = 0
        var peak = 0
    }

    private let state: Mutex<State>
    private let answer: @Sendable (String) -> EntryLabel?

    init(holding: Bool = false, answer: @escaping @Sendable (String) -> EntryLabel? = { _ in ideaLabel }) {
        state = Mutex(State(holding: holding))
        self.answer = answer
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// The most requests that were inside `label` at the same moment.
    var peakInFlight: Int { state.withLock { $0.peak } }

    /// Lets every held request answer, and every later one answer at once.
    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holding = false
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func label(text: String, topics: [MemoryTopic]) async -> EntryLabel? {
        state.withLock { state in
            state.calls.append(Call(text: text, topics: topics))
            state.inFlight += 1
            state.peak = max(state.peak, state.inFlight)
        }
        await withCheckedContinuation { continuation in
            let waits = state.withLock { state -> Bool in
                guard state.holding else { return false }
                state.waiters.append(continuation)
                return true
            }
            if !waits {
                continuation.resume()
            }
        }
        state.withLock { $0.inFlight -= 1 }
        return answer(text)
    }
}

/// Stands in for the memory folder: answers the launch load with a fixed
/// value and records every write plan.
private final class MemoryWriteSpy: Sendable {
    private let recorded = Mutex<[MemoryWrite]>([])

    var writes: [MemoryWrite] { recorded.withLock { $0 } }

    func write(_ plan: MemoryWrite) {
        recorded.withLock { $0.append(plan) }
    }
}

/// Covers the coordinator's side of the sorting model: when a new entry is
/// labelled and when a label is discarded, Sort Entries, the topic edits and
/// the TypeSafe key. The organizer is always a spy, so nothing reaches the
/// network, and every file lives in a temporary directory the test removes.
@Suite("Memory organizing", .serialized)
@MainActor
struct MemoryOrganizingTests {
    enum Gate: CaseIterable, Sendable {
        case switchOff
        case noKey
    }

    enum Interruption: CaseIterable, Sendable {
        case switchOff
        case clearMemory
        case deletion
    }

    private let dictated = "Ship the release notes today."
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-memory-organizing-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    /// Entry `index`, made `index` minutes after the start, so a higher index is newer.
    private func entry(_ index: Int, userTopicID: String? = nil) -> MemoryEntry {
        MemoryEntry(
            id: id(index),
            createdAt: organizingStart.addingTimeInterval(Double(index) * 60),
            text: "Entry \(index).",
            userTopicID: userTopicID
        )
    }

    /// A coordinator whose History, settings and key file live in `directory`,
    /// whose memory disk access goes to `disk`, and whose sorting model is
    /// `organizer`. `key` nil leaves the environment without a key.
    private func makeCoordinator(
        directory: URL,
        rows: [RecentSession] = [],
        load: MemoryLoad = MemoryLoad(),
        organizerEnabled: Bool = true,
        key: String? = "test-key-123",
        keyFile: URL? = nil,
        tracker: FakeTracker = FakeTracker(),
        outcome: InsertionOutcome = .pasteAttempted,
        disk: MemoryWriteSpy,
        organizer: OrganizerSpy
    ) throws -> DictationCoordinator {
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save(rows)
        var environment: [String: String] = [:]
        if let key {
            environment[TypeSafeKeySource.variable] = key
        }
        let calendar = self.calendar
        return DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text(dictated)),
            tracker: tracker,
            inserter: FakeInserter(outcome: outcome),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(memoryEnabled: true, organizerEnabled: organizerEnabled),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            memoryLoad: { _ in load },
            memoryWrite: { _, plan in disk.write(plan) },
            memoryClear: { _ in },
            organizer: organizer,
            typeSafeKeys: TypeSafeKeySource(
                environment: environment,
                keyFile: keyFile ?? directory.appendingPathComponent("typesafe.key")
            ),
            runtimeOverride: DictationRuntime(
                now: { organizingStart },
                makeUUID: { UUID() },
                sleep: { _ in },
                calendar: { calendar }
            )
        )
    }

    private func deliver(_ coordinator: DictationCoordinator) async {
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }
    }

    /// Awaits every labelling task, then the Sort Entries run, then the
    /// writes they queued. Call only while the organizer answers.
    private func settle(_ coordinator: DictationCoordinator) async {
        while let entry = coordinator.organizerTasks.values.first {
            await entry.task.value
        }
        while let run = coordinator.organizerRunTask {
            await run.task.value
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    // MARK: - Labelling new entries

    @Test func aDeliveredDictationIsLabelledAfterItsCommit() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy()
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(topics: [releaseTopic]), disk: disk, organizer: organizer)

        await deliver(coordinator)
        await waitUntil { organizer.calls.count == 1 }
        await settle(coordinator)

        #expect(organizer.calls == [OrganizerSpy.Call(text: dictated, topics: [releaseTopic])])
        let entry = try #require(coordinator.memoryEntries.first)
        #expect(coordinator.memoryEntries.count == 1)
        #expect(entry.text == dictated)
        #expect(entry.label == ideaLabel)
        let month = MemoryStore.monthKey(for: organizingStart, calendar: calendar)
        #expect(disk.writes.count == 2)
        #expect(disk.writes.first?.months[month]?.map(\.label) == [nil])
        #expect(disk.writes.last?.months[month]?.map(\.label) == [ideaLabel])
    }

    @Test func aSavedNoteIsLabelledWithTheCurrentTopics() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy()
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(topics: [releaseTopic]), disk: disk, organizer: organizer)
        try coordinator.addTopic(name: "Garden plans", summary: "Beds and seeds.")

        let noteID = try #require(coordinator.recordNote(text: "Order the seeds.", captureSeconds: 2))
        await waitUntil { organizer.calls.count == 1 }
        await settle(coordinator)

        #expect(organizer.calls == [OrganizerSpy.Call(text: "Order the seeds.", topics: [releaseTopic, gardenTopic])])
        #expect(coordinator.memoryEntries.first(where: { $0.id == noteID })?.label == ideaLabel)
    }

    @Test(arguments: Gate.allCases)
    func theOrganizerIsNeverCalledWithoutTheSwitchAndAKey(_ gate: Gate) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy()
        let coordinator = try makeCoordinator(
            directory: directory,
            organizerEnabled: gate != .switchOff,
            key: gate == .noKey ? nil : "test-key-123",
            disk: disk,
            organizer: organizer
        )

        await deliver(coordinator)
        await settle(coordinator)
        coordinator.sortEntries()

        #expect(coordinator.memoryEntries.count == 1)
        #expect(coordinator.memoryEntries.first?.label == nil)
        #expect(coordinator.organizerRun == nil)
        #expect(coordinator.organizerRunTask?.identity == nil)
        #expect(organizer.calls.isEmpty)
    }

    @Test func aSecureTargetDictationNeverReachesTheOrganizer() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy()
        let coordinator = try makeCoordinator(
            directory: directory,
            tracker: FakeTracker(bundleId: "com.apple.TextEdit", appName: "TextEdit", safety: .secure),
            outcome: .copiedOnly(reason: "secure_target"),
            disk: disk,
            organizer: organizer
        )

        await deliver(coordinator)
        await settle(coordinator)

        #expect(coordinator.memoryEntries.isEmpty)
        #expect(coordinator.organizerTasks.isEmpty)
        #expect(organizer.calls.isEmpty)
    }

    @Test func deliveryCompletesWhileTheOrganizerIsStillBlocked() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy(holding: true)
        defer { organizer.release() }
        let coordinator = try makeCoordinator(directory: directory, disk: disk, organizer: organizer)

        await deliver(coordinator)
        await waitUntil { organizer.calls.count == 1 }

        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(coordinator.recentSessions.map(\.text) == [dictated])
        #expect(coordinator.memoryEntries.map(\.label) == [nil])
        #expect(coordinator.organizerTasks.count == 1)

        organizer.release()
        await settle(coordinator)

        #expect(coordinator.memoryEntries.map(\.label) == [ideaLabel])
    }

    @Test(arguments: Interruption.allCases)
    func aLabelThatReturnsAfterAnInterruptionIsDiscarded(_ interruption: Interruption) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy(holding: true)
        defer { organizer.release() }
        let coordinator = try makeCoordinator(directory: directory, disk: disk, organizer: organizer)

        await deliver(coordinator)
        await waitUntil { organizer.calls.count == 1 }
        let pending = try #require(coordinator.organizerTasks.values.first?.task)
        let entryID = try #require(coordinator.memoryEntries.first?.id)
        switch interruption {
        case .switchOff:
            coordinator.setOrganizerEnabled(false)
        case .clearMemory:
            #expect(await coordinator.clearMemory())
        case .deletion:
            #expect(await coordinator.deleteRecentSession(id: entryID))
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
        let writesBeforeLanding = disk.writes.count

        organizer.release()
        await pending.value
        _ = await coordinator.recentSessionPersistenceTail?.value

        #expect(disk.writes.count == writesBeforeLanding)
        #expect(coordinator.memoryEntries.allSatisfy { $0.label == nil })
        #expect(coordinator.memoryEntries.map(\.id) == (interruption == .switchOff ? [entryID] : []))
        #expect(coordinator.organizerTasks.isEmpty)
    }

    // MARK: - Sort Entries

    @Test func sortEntriesLabelsTheNewest500EntriesWithoutAUserTopicIn25Commits() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 503 entries, one filed by the user: 502 candidates, so the two
        // oldest unfiled entries fall outside the run.
        let entries = (1...503).map { index in
            entry(index, userTopicID: index == 502 ? releaseTopic.id : nil)
        }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy()
        let coordinator = try makeCoordinator(
            directory: directory,
            load: MemoryLoad(entries: entries, topics: [releaseTopic]),
            disk: disk,
            organizer: organizer
        )

        coordinator.sortEntries()
        await waitUntil { coordinator.organizerRun?.isFinished == true }
        await settle(coordinator)

        let expected = Set((3...501).map { "Entry \($0)." } + ["Entry 503."])
        #expect(organizer.calls.count == 500)
        #expect(Set(organizer.calls.map(\.text)) == expected)
        #expect(organizer.calls.allSatisfy { $0.topics == [releaseTopic] })
        #expect(coordinator.organizerRun == OrganizerRun(done: 500, total: 500, failed: 0, isFinished: true))
        let unlabelled = coordinator.memoryEntries.filter { $0.label == nil }.map(\.text)
        #expect(unlabelled == ["Entry 1.", "Entry 2.", "Entry 502."])
        #expect(disk.writes.count == 25)
    }

    @Test func sortEntriesReportsFailuresAndCommitsTheRemainderWhenItEnds() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = (1...45).map { entry($0) }
        let failing: Set<String> = ["Entry 10.", "Entry 20.", "Entry 30.", "Entry 40."]
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy { text in failing.contains(text) ? nil : ideaLabel }
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(entries: entries), disk: disk, organizer: organizer)

        coordinator.sortEntries()
        await waitUntil { coordinator.organizerRun?.isFinished == true }
        await settle(coordinator)

        #expect(coordinator.organizerRun == OrganizerRun(done: 45, total: 45, failed: 4, isFinished: true))
        let unlabelled = Set(coordinator.memoryEntries.filter { $0.label == nil }.map(\.text))
        #expect(unlabelled == failing)
        // 41 labels: one commit at 20, one at 40, and one for the last label when the run ends.
        #expect(disk.writes.count == 3)
    }

    @Test func sortEntriesKeepsFourRequestsInFlightAndIgnoresASecondPress() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = (1...10).map { entry($0) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy(holding: true)
        defer { organizer.release() }
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(entries: entries), disk: disk, organizer: organizer)

        coordinator.sortEntries()
        await waitUntil { organizer.calls.count == 4 }
        // Gives a run that ignored the limit the chance to start a fifth request.
        try await Task.sleep(for: .milliseconds(50))

        #expect(organizer.calls.count == 4)
        #expect(coordinator.organizerRun == OrganizerRun(done: 0, total: 10, failed: 0, isFinished: false))
        let identity = try #require(coordinator.organizerRunTask?.identity)

        coordinator.sortEntries()

        #expect(coordinator.organizerRunTask?.identity == identity)
        #expect(coordinator.organizerRun == OrganizerRun(done: 0, total: 10, failed: 0, isFinished: false))

        organizer.release()
        await waitUntil { coordinator.organizerRun?.isFinished == true }
        await settle(coordinator)

        #expect(coordinator.organizerRun == OrganizerRun(done: 10, total: 10, failed: 0, isFinished: true))
        #expect(organizer.calls.count == 10)
        #expect(organizer.peakInFlight == 4)
        #expect(coordinator.memoryEntries.allSatisfy { $0.label == ideaLabel })
    }

    @Test func cancellingSortEntriesStopsTheRun() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = (1...10).map { entry($0) }
        let disk = MemoryWriteSpy()
        let organizer = OrganizerSpy(holding: true)
        defer { organizer.release() }
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(entries: entries), disk: disk, organizer: organizer)

        coordinator.sortEntries()
        await waitUntil { organizer.calls.count == 4 }
        let run = try #require(coordinator.organizerRunTask?.task)

        coordinator.cancelSortEntries()

        #expect(coordinator.organizerRunTask?.identity == nil)
        #expect(coordinator.organizerRun == OrganizerRun(done: 0, total: 10, failed: 0, isFinished: true))

        organizer.release()
        await run.value
        await settle(coordinator)

        #expect(organizer.calls.count == 4)
        #expect(coordinator.organizerRun == OrganizerRun(done: 0, total: 10, failed: 0, isFinished: true))
        #expect(coordinator.memoryEntries.allSatisfy { $0.label == nil })
        #expect(disk.writes.isEmpty)
    }

    // MARK: - Topics

    @Test func removingATopicUnfilesTheEntriesTheUserFiledUnderIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [entry(1, userTopicID: releaseTopic.id), entry(2, userTopicID: gardenTopic.id), entry(3)]
        let disk = MemoryWriteSpy()
        let coordinator = try makeCoordinator(
            directory: directory,
            load: MemoryLoad(entries: entries, topics: [releaseTopic, gardenTopic]),
            disk: disk,
            organizer: OrganizerSpy()
        )

        coordinator.removeTopic(id: releaseTopic.id)
        await settle(coordinator)

        #expect(coordinator.memoryTopics == [gardenTopic])
        #expect(coordinator.memoryEntries.map(\.userTopicID) == [nil, gardenTopic.id, nil])
        #expect(disk.writes.count == 1)
        #expect(disk.writes.first?.topics == [gardenTopic])
    }

    @Test func filingAHistoryOnlyRowKeepsItInMemoryAndANilTopicRemovesIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = RecentSession(id: id(7), createdAt: organizingStart, text: "Only History has this.")
        let disk = MemoryWriteSpy()
        let coordinator = try makeCoordinator(
            directory: directory,
            rows: [row],
            load: MemoryLoad(topics: [releaseTopic]),
            disk: disk,
            organizer: OrganizerSpy()
        )
        let loaded = try #require(coordinator.recentSessions.first)

        coordinator.fileEntry(id: row.id, underTopic: releaseTopic.id)

        var filed = MemoryEntry(loaded)
        filed.userTopicID = releaseTopic.id
        #expect(coordinator.memoryEntries == [filed])
        #expect(coordinator.recentSessions.map(\.id) == [row.id])

        coordinator.fileEntry(id: row.id, underTopic: nil)

        var removed = MemoryEntry(loaded)
        removed.userRemovedTopic = true
        #expect(coordinator.memoryEntries == [removed])

        coordinator.fileEntry(id: row.id, underTopic: "no-such-topic")
        await settle(coordinator)

        #expect(coordinator.memoryEntries == [removed])
        #expect(disk.writes.count == 2)
    }

    @Test func addingADuplicateTopicRethrowsTheRefusalAndChangesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = MemoryWriteSpy()
        let coordinator = try makeCoordinator(
            directory: directory, load: MemoryLoad(topics: [releaseTopic]), disk: disk, organizer: OrganizerSpy())
        let revision = coordinator.memoryRevision

        #expect(throws: TopicCatalog.Refusal.duplicate("Release")) {
            try coordinator.addTopic(name: "  release ", summary: "Again.")
        }
        await settle(coordinator)

        #expect(coordinator.memoryTopics == [releaseTopic])
        #expect(coordinator.memoryRevision == revision)
        #expect(disk.writes.isEmpty)
    }

    // MARK: - The key

    @Test func savingAKeyWritesTheKeyFileAndABlankKeyRemovesIt() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try makeCoordinator(
            directory: directory, key: nil, disk: MemoryWriteSpy(), organizer: OrganizerSpy())
        let keyFile = directory.appendingPathComponent("typesafe.key")
        let revision = coordinator.typeSafeKeyRevision
        #expect(coordinator.typeSafeKeyOrigin == nil)

        #expect(coordinator.saveTypeSafeKey("  test-key-123\n"))

        #expect(try String(contentsOf: keyFile, encoding: .utf8) == "test-key-123")
        #expect(coordinator.typeSafeKeyOrigin == .keyFile)
        #expect(coordinator.typeSafeKeyRevision == revision + 1)

        #expect(coordinator.saveTypeSafeKey("   "))

        #expect(!FileManager.default.fileExists(atPath: keyFile.path))
        #expect(coordinator.typeSafeKeyOrigin == nil)
        #expect(coordinator.typeSafeKeyRevision == revision + 2)
        #expect(coordinator.errorMessage == nil)
    }

    @Test func aKeyThatCannotBeWrittenIsReported() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the key file's folder should be.
        let blocker = directory.appendingPathComponent("blocker")
        let coordinator = try makeCoordinator(
            directory: directory,
            key: nil,
            keyFile: blocker.appendingPathComponent("typesafe.key"),
            disk: MemoryWriteSpy(),
            organizer: OrganizerSpy()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: blocker)

        #expect(!coordinator.saveTypeSafeKey("test-key-123"))

        #expect(coordinator.errorMessage == "The TypeSafe key could not be saved.")
        #expect(coordinator.typeSafeKeyOrigin == nil)
    }
}
