import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers `prepareAgentSkill()`, the write behind Copy Install Command: it may
/// create the memory folder, it runs behind every write already queued, and it
/// refuses once termination has begun. Memory is a real store in a temporary
/// directory the test removes.
@Suite("Agent skill install", .serialized)
@MainActor
struct AgentSkillInstallTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-agent-skill-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A coordinator whose History, ledger and settings live in `directory`,
    /// with memory in `memory`, a folder whose name holds a space.
    private func makeCoordinator(directory: URL, memory: MemoryStore) throws -> DictationCoordinator {
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
            memoryStore: memory
        )
    }

    private func makeMemory(in directory: URL) -> MemoryStore {
        MemoryStore(root: directory.appendingPathComponent("Voiceour memory", isDirectory: true))
    }

    @Test func aPressCreatesTheFolderAndTheSkill() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = makeMemory(in: directory)
        let coordinator = try makeCoordinator(directory: directory, memory: memory)
        #expect(!FileManager.default.fileExists(atPath: memory.root.path))

        #expect(await coordinator.prepareAgentSkill())

        #expect(try Data(contentsOf: memory.agentSkillURL) == Data(MemoryPages.agentSkill(root: memory.root).utf8))
        #expect(coordinator.errorMessage == nil)
    }

    /// A press right after Clear Memory writes into the emptied folder rather
    /// than being erased by the clear queued ahead of it.
    @Test func aPressLandsBehindAQueuedClear() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = makeMemory(in: directory)
        let entry = MemoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), text: "Kept.")
        try memory.apply(MemoryWrite(months: ["2027-01": [entry]]))
        let coordinator = try makeCoordinator(directory: directory, memory: memory)
        #expect(coordinator.memoryEntries.count == 1)

        let clearing = Task { @MainActor in await coordinator.clearMemory() }
        await waitUntil { coordinator.memoryEntries.isEmpty }
        let prepared = await coordinator.prepareAgentSkill()

        #expect(await clearing.value)
        #expect(prepared)
        #expect(FileManager.default.fileExists(atPath: memory.agentSkillURL.path))
        #expect(!FileManager.default.fileExists(atPath: memory.entriesDirectory.path))
    }

    @Test func aPressWhileTerminatingWritesNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = makeMemory(in: directory)
        let coordinator = try makeCoordinator(directory: directory, memory: memory)
        await coordinator.prepareForTermination()

        #expect(await coordinator.prepareAgentSkill() == false)

        #expect(!FileManager.default.fileExists(atPath: memory.root.path))
    }
}
