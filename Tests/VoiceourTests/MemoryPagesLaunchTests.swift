import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers the pages rebuild a launch queues when the memory folder's
/// `pages-format` stamp names another format or zone: when it runs, what it
/// writes and sweeps, where it sits on the persistence tail, and what a
/// failure leaves behind. Every test uses a real store in a temporary
/// directory the test removes; a spy in front of `apply` records the writes.
@Suite("Memory pages launch rebuild", .serialized)
@MainActor
struct MemoryPagesLaunchTests {
    /// Records, in the order they ran, every memory write and History
    /// snapshot, then hands each to the real store. Can park the first memory
    /// write until the test releases it.
    // `lock` protects the recorded events and plans; the gate is immutable.
    private final class DiskLog: @unchecked Sendable {
        enum Event: Equatable {
            /// A memory write carrying a stamp: only a pages rebuild sets one.
            case rebuild
            /// A memory write without a stamp: a commit's diff.
            case diff
            case history
        }

        private let lock = NSLock()
        private let firstWriteGate: DispatchSemaphore?
        private var recorded: [Event] = []
        private var plans: [MemoryWrite] = []

        init(parksFirstMemoryWrite: Bool = false) {
            firstWriteGate = parksFirstMemoryWrite ? DispatchSemaphore(value: 0) : nil
        }

        var events: [Event] { lock.withLock { recorded } }
        var writes: [MemoryWrite] { lock.withLock { plans } }

        func releaseFirstWrite() {
            firstWriteGate?.signal()
        }

        func memoryWrite(_ store: MemoryStore, _ plan: MemoryWrite) throws {
            let first = lock.withLock { () -> Bool in
                recorded.append(plan.pagesFormat == nil ? .diff : .rebuild)
                plans.append(plan)
                return plans.count == 1
            }
            if first {
                firstWriteGate?.wait()
            }
            try store.apply(plan)
        }

        func historySave(_ store: RecentSessionStore, _ sessions: [RecentSession]) throws {
            lock.withLock { recorded.append(.history) }
            try store.save(sessions)
        }
    }

    /// 2027-01-15 08:00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    /// What a folder written by the first page format holds, or any stamp
    /// this build does not write.
    private let oldStamp = "1"

    private var currentStamp: String {
        MemoryPages.formatStamp(calendar: calendar)
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-memory-pages-launch-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func memoryStore(in directory: URL) -> MemoryStore {
        MemoryStore(root: directory.appendingPathComponent("memory", isDirectory: true))
    }

    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private var keptEntries: [MemoryEntry] {
        [
            MemoryEntry(id: id(1), createdAt: t0.addingTimeInterval(-86_400), text: "Draft the launch plan."),
            MemoryEntry(id: id(2), createdAt: t0.addingTimeInterval(-3_600), kind: .note, text: "Call the notary."),
        ]
    }

    private var keptTopics: [MemoryTopic] {
        [MemoryTopic(id: "launch", name: "Launch", summary: "Shipping the release.", createdAt: t0)]
    }

    /// Writes a folder the way an earlier build left it: every record and
    /// page, and `stamp` in `pages-format` when given.
    private func seedFolder(in directory: URL, stamp: String?) throws -> MemoryStore {
        let store = memoryStore(in: directory)
        try store.apply(MemoryPlanner.rebuild(entries: keptEntries, topics: keptTopics, calendar: calendar))
        if let stamp {
            try Data("\(stamp)\n".utf8).write(to: store.pagesFormatURL)
        }
        return store
    }

    /// A coordinator whose History, ledger, settings and memory live in
    /// `directory`, with the default stamp reader, so launch sees what the
    /// folder's `pages-format` says.
    private func launch(directory: URL, memoryEnabled: Bool = false, log: DiskLog) -> DictationCoordinator {
        let calendar = self.calendar
        let now = t0
        return DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("Ship the release notes today.")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(memoryEnabled: memoryEnabled),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json")),
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            memoryWrite: { try log.memoryWrite($0, $1) },
            recentSessionSnapshotSave: { try log.historySave($0, $1) },
            runtimeOverride: DictationRuntime(
                now: { now },
                makeUUID: { UUID() },
                sleep: { _ in },
                calendar: { calendar }
            )
        )
    }

    private func settle(_ coordinator: DictationCoordinator) async {
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    private func pageExists(_ path: String, in store: MemoryStore) -> Bool {
        FileManager.default.fileExists(atPath: store.root.appendingPathComponent(path).path)
    }

    // MARK: - When it runs

    @Test func anOldStampRebuildsThePagesOnceAndTheNextLaunchWritesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try seedFolder(in: directory, stamp: oldStamp)
        for folder in ["agents", "threads"] {
            try FileManager.default.createDirectory(
                at: store.root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("A page of the old layout.\n".utf8).write(to: store.root.appendingPathComponent("threads/old.md"))
        try Data("An agent's note.\n".utf8).write(to: store.root.appendingPathComponent("agents/recap.md"))
        let month = store.monthURL(MemoryStore.monthKey(for: t0, calendar: calendar))
        let monthBytes = try Data(contentsOf: month)
        let topicsBytes = try Data(contentsOf: store.topicsURL)

        let log = DiskLog()
        let first = launch(directory: directory, log: log)
        await settle(first)

        let expected = MemoryPlanner.rebuildPages(
            entries: keptEntries,
            topics: keptTopics,
            calendar: calendar,
            sweep: true
        )
        #expect(log.writes == [expected])
        #expect(first.errorMessage == nil)
        #expect(store.pagesFormat() == currentStamp)
        // Only pages: the records keep their bytes, and the sweep keeps what
        // agents wrote while removing the page this format no longer names.
        #expect(try Data(contentsOf: month) == monthBytes)
        #expect(try Data(contentsOf: store.topicsURL) == topicsBytes)
        #expect(!pageExists("threads/old.md", in: store))
        #expect(pageExists("agents/recap.md", in: store))
        for page in expected.pages {
            #expect(try String(contentsOf: store.root.appendingPathComponent(page.path), encoding: .utf8) == page.text)
        }

        let secondLog = DiskLog()
        let second = launch(directory: directory, log: secondLog)
        await settle(second)

        #expect(secondLog.writes.isEmpty)
        #expect(second.memoryEntries == keptEntries)
    }

    @Test func aFolderWithNoStampRebuilds() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try seedFolder(in: directory, stamp: nil)

        let log = DiskLog()
        let coordinator = launch(directory: directory, log: log)
        await settle(coordinator)

        #expect(log.events == [.rebuild])
        #expect(store.pagesFormat() == currentStamp)
    }

    @Test func anAbsentFolderIsNeverCreated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let log = DiskLog()
        let coordinator = launch(directory: directory, log: log)
        await settle(coordinator)

        #expect(log.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: memoryStore(in: directory).root.path))
    }

    @Test func aFolderThatHoldsNothingGetsNoPagesAndNoStamp() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = memoryStore(in: directory)
        try FileManager.default.createDirectory(at: store.entriesDirectory, withIntermediateDirectories: true)

        let log = DiskLog()
        let coordinator = launch(directory: directory, log: log)
        await settle(coordinator)

        #expect(log.writes.isEmpty)
        #expect(!pageExists(MemoryPages.indexPath, in: store))
        #expect(store.pagesFormat() == nil)
    }

    // MARK: - What it keeps

    @Test func anUnreadableLoadRebuildsWithoutSweeping() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try seedFolder(in: directory, stamp: oldStamp)
        // A month this build cannot read: its pages are all that is left of
        // its entries until the user repairs the set-aside file.
        try Data("not a month".utf8).write(to: store.monthURL("2026-12"))
        let orphan = "days/2026-12-03.md"
        try Data("A day of the unreadable month.\n".utf8).write(to: store.root.appendingPathComponent(orphan))

        let log = DiskLog()
        let coordinator = launch(directory: directory, log: log)
        await settle(coordinator)

        let write = try #require(log.writes.first)
        #expect(log.writes.count == 1)
        #expect(write.sweepDerived == false)
        #expect(write.pagesFormat == currentStamp)
        #expect(pageExists(orphan, in: store))
        #expect(store.pagesFormat() == currentStamp)
        let message = try #require(coordinator.errorMessage)
        #expect(message.hasPrefix("Memory could not be read"))
    }

    @Test func aFailedRebuildReportsAndLeavesTheOldStampForTheNextLaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try seedFolder(in: directory, stamp: oldStamp)
        // A file where the day pages' folder belongs: every day page write fails.
        let days = store.root.appendingPathComponent("days", isDirectory: true)
        try FileManager.default.removeItem(at: days)
        try Data("in the way".utf8).write(to: store.root.appendingPathComponent("days"))

        let log = DiskLog()
        let coordinator = launch(directory: directory, log: log)
        await settle(coordinator)
        await waitUntil { coordinator.errorMessage != nil }

        #expect(log.events == [.rebuild])
        #expect(coordinator.errorMessage == "Memory could not be saved.")
        #expect(store.pagesFormat() == oldStamp)

        try FileManager.default.removeItem(at: store.root.appendingPathComponent("days"))
        let retryLog = DiskLog()
        let retry = launch(directory: directory, log: retryLog)
        await settle(retry)

        #expect(retryLog.events == [.rebuild])
        #expect(store.pagesFormat() == currentStamp)
    }

    // MARK: - Where it sits on the tail

    @Test func theRebuildIsTheTailsFirstWriteWhenADictationFollowsLaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try seedFolder(in: directory, stamp: oldStamp)

        let log = DiskLog(parksFirstMemoryWrite: true)
        let coordinator = launch(directory: directory, memoryEnabled: true, log: log)
        // The rebuild is parked while the dictation is journaled and its memory
        // committed, so anything queued ahead of it would already have run.
        // The pipeline itself waits on its History snapshot, which sits behind
        // the rebuild, so the dictation finishes only after the release.
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.memoryEntries.count == keptEntries.count + 1 && !log.events.isEmpty }
        #expect(log.events == [.rebuild])

        log.releaseFirstWrite()
        await waitUntil { !coordinator.isProcessingInFlight }
        await settle(coordinator)

        let events = log.events
        #expect(events.first == .rebuild)
        #expect(events.filter { $0 == .rebuild }.count == 1)
        let history = try #require(events.firstIndex(of: .history))
        let diff = try #require(events.firstIndex(of: .diff))
        #expect(history < diff)
        // The rebuild renders the state launch loaded; the dictation reaches
        // disk through its own diff, behind it.
        #expect(
            log.writes.first
                == MemoryPlanner.rebuildPages(entries: keptEntries, topics: keptTopics, calendar: calendar, sweep: true)
        )
        #expect(store.load().entries == coordinator.memoryEntries)
        #expect(store.pagesFormat() == currentStamp)
    }
}
