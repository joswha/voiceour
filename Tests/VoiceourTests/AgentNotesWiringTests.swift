import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers how the coordinator loads the notes agents saved under memory's
/// `agents/`: one load at a time with one rerun, nothing published once quit
/// has begun or memory was erased, and the text-only cap the Journal shows.
/// The folder is never read: an injected loader answers instead.
@Suite("Agent notes wiring", .serialized)
@MainActor
struct AgentNotesWiringTests {
    /// Stands in for `MemoryStore.loadAgentNotes()`: answers the Nth load with
    /// the Nth answer (the last one after that), counts loads, and can park the
    /// first load until the test releases it.
    // `lock` protects the counts; the answers and gate are immutable.
    private final class NotesLoaderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private let answers: [[AgentNote]]
        private let firstLoadGate: DispatchSemaphore?
        private var started = 0
        private var finished = 0

        init(answers: [[AgentNote]], parksFirstLoad: Bool = false) {
            self.answers = answers
            firstLoadGate = parksFirstLoad ? DispatchSemaphore(value: 0) : nil
        }

        var startedLoads: Int { lock.withLock { started } }

        /// Loads that returned.
        var finishedLoads: Int { lock.withLock { finished } }

        func releaseFirstLoad() {
            firstLoadGate?.signal()
        }

        func load(_ store: MemoryStore) -> [AgentNote] {
            let number = lock.withLock { () -> Int in
                started += 1
                return started
            }
            if number == 1 {
                firstLoadGate?.wait()
            }
            lock.withLock { finished += 1 }
            return answers.isEmpty ? [] : answers[min(number, answers.count) - 1]
        }
    }

    /// 2027-01-15 08:00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-agent-notes-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func note(_ name: String, day: String? = "2027-01-15", topicID: String? = nil) -> AgentNote {
        AgentNote(
            id: name,
            author: "Claude",
            title: "Recap",
            day: day,
            topicID: topicID,
            body: "What happened in \(name).",
            modifiedAt: t0
        )
    }

    /// A coordinator whose History, ledger and settings live in `directory`
    /// and whose memory disk access is inert, so only the loader is exercised.
    private func makeCoordinator(directory: URL, loader: NotesLoaderSpy) throws -> DictationCoordinator {
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save([])
        return DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("Ship the release notes today.")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            memoryLoad: { _ in MemoryLoad() },
            memoryWrite: { _, _ in },
            memoryClear: { _ in },
            memoryAgentNotesLoad: { loader.load($0) }
        )
    }

    /// Gives a landing that should not happen time to happen anyway.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Refresh

    @Test func refreshPublishesWhatTheLoaderReturns() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = [note("2027-01-15-recap.md"), note("topic-release.md", day: nil, topicID: "release")]
        let loader = NotesLoaderSpy(answers: [notes])
        let coordinator = try makeCoordinator(directory: directory, loader: loader)

        #expect(coordinator.agentNotes.isEmpty)
        coordinator.refreshAgentNotes()
        await waitUntil { coordinator.agentNotesTask == nil }

        #expect(coordinator.agentNotes == notes)
        #expect(loader.startedLoads == 1)
    }

    @Test func callsDuringALoadRerunItOnceAfterItLands() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = [note("first.md")]
        let second = [note("second.md"), note("first.md")]
        let loader = NotesLoaderSpy(answers: [first, second], parksFirstLoad: true)
        let coordinator = try makeCoordinator(directory: directory, loader: loader)

        coordinator.refreshAgentNotes()
        await waitUntil { loader.startedLoads == 1 }
        coordinator.refreshAgentNotes()
        coordinator.refreshAgentNotes()
        await settle()
        #expect(loader.startedLoads == 1)

        loader.releaseFirstLoad()
        await waitUntil { loader.finishedLoads == 2 && coordinator.agentNotesTask == nil }
        await settle()

        #expect(loader.startedLoads == 2)
        #expect(coordinator.agentNotes == second)
    }

    @Test func aLoadThatLandsAfterTerminationBeganPublishesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = NotesLoaderSpy(answers: [[note("late.md")]], parksFirstLoad: true)
        let coordinator = try makeCoordinator(directory: directory, loader: loader)

        coordinator.refreshAgentNotes()
        await waitUntil { loader.startedLoads == 1 }
        await coordinator.prepareForTermination()

        loader.releaseFirstLoad()
        await waitUntil { coordinator.agentNotesTask == nil }
        #expect(coordinator.agentNotes.isEmpty)

        // Quit has begun, so a later call starts no load at all.
        coordinator.refreshAgentNotes()
        await settle()
        #expect(loader.startedLoads == 1)
        #expect(coordinator.agentNotes.isEmpty)
    }

    // MARK: - Clear Memory

    @Test func clearMemoryEmptiesTheNotes() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = NotesLoaderSpy(answers: [[note("2027-01-15-recap.md")]])
        let coordinator = try makeCoordinator(directory: directory, loader: loader)
        coordinator.refreshAgentNotes()
        await waitUntil { !coordinator.agentNotes.isEmpty }

        #expect(await coordinator.clearMemory())

        #expect(coordinator.agentNotes.isEmpty)
    }

    @Test func aLoadInFlightWhenMemoryIsClearedPublishesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = NotesLoaderSpy(answers: [[note("erased.md")]], parksFirstLoad: true)
        let coordinator = try makeCoordinator(directory: directory, loader: loader)

        coordinator.refreshAgentNotes()
        await waitUntil { loader.startedLoads == 1 }
        #expect(await coordinator.clearMemory())

        loader.releaseFirstLoad()
        await waitUntil { loader.finishedLoads == 1 }
        await settle()

        #expect(coordinator.agentNotes.isEmpty)
        #expect(coordinator.agentNotesTask == nil)
    }

    // MARK: - Display

    @Test func aBodyAtTheLimitShowsWhole() {
        let body = String(repeating: "\u{00E9}", count: JournalAgentNoteRow.displayLimit)

        #expect(JournalAgentNoteRow.displayedBody(body) == body)
    }

    @Test func aLongerBodyIsCutAtTheLimitInCharactersAndEndsWithAnEllipsis() {
        // Two-byte characters, so a cut counted in bytes would land at half the limit.
        let kept = String(repeating: "\u{00E9}", count: JournalAgentNoteRow.displayLimit)

        let shown = JournalAgentNoteRow.displayedBody(kept + "cut")

        #expect(shown == kept + "\u{2026}")
    }
}
