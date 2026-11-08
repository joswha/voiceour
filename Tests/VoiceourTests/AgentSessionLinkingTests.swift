import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

@Suite("Agent session linking", .serialized)
@MainActor
struct AgentSessionLinkingTests {
    // Returns its prompts and counts calls; with a gate, blocks until the gate is
    // signalled. `lock` protects the call count; prompts and gate are immutable.
    private final class FakePromptReader: AgentPromptReading, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let stored: [AgentPrompt]
        private let gate: DispatchSemaphore?

        init(_ stored: [AgentPrompt], gate: DispatchSemaphore? = nil) {
            self.stored = stored
            self.gate = gate
        }

        var calls: Int { lock.withLock { callCount } }

        func prompts(sentSince since: Date) -> [AgentPrompt] {
            lock.withLock { callCount += 1 }
            gate?.wait()
            return stored.filter { $0.sentAt >= since }
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private var rows: [RecentSession] {
        [
            RecentSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!,
                createdAt: t0.addingTimeInterval(100),
                text: "Something nobody sent to any agent at all."
            ),
            RecentSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
                createdAt: t0,
                text: "Deploy the Kubernetes cluster to staging."
            ),
        ]
    }

    private var prompts: [AgentPrompt] {
        [
            AgentPrompt(
                agent: .omp,
                sessionId: "omp-1",
                workingDirectory: "/Users/v/voiceour",
                sessionTitle: "Deploys",
                sentAt: t0.addingTimeInterval(60),
                text: "ok so deploy the kubectl cluster to staging. then report back"
            )
        ]
    }

    private func makeCoordinator(
        rows: [RecentSession],
        linkingEnabled: Bool,
        reader: AgentPromptReading
    ) throws -> (coordinator: DictationCoordinator, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-agent-linking-tests-\(UUID().uuidString)")
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save(rows)
        let now = t0.addingTimeInterval(3_600)
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("unused")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(agentSessionLinkingEnabled: linkingEnabled),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            agentPrompts: reader,
            runtimeOverride: DictationRuntime(now: { now }, makeUUID: { UUID() }, sleep: { _ in })
        )
        return (coordinator, directory)
    }

    private func link(_ coordinator: DictationCoordinator, _ id: String) -> AgentSessionLink? {
        coordinator.recentSessions.first { $0.id == UUID(uuidString: id) }?.agentLink
    }

    @Test func aPassLinksTheMatchingRowAndPersistsIt() async throws {
        let (coordinator, directory) = try makeCoordinator(
            rows: rows,
            linkingEnabled: true,
            reader: FakePromptReader(prompts)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        coordinator.resolveAgentSessionLinks()
        await coordinator.agentLinkTask?.value
        _ = await coordinator.recentSessionPersistenceTail?.value

        let linked = link(coordinator, "00000000-0000-0000-0000-0000000000b1")
        #expect(linked?.match?.key == AgentSessionKey(agent: .omp, sessionId: "omp-1"))
        #expect(linked?.match?.sentText == "deploy the kubectl cluster to staging.")
        #expect(link(coordinator, "00000000-0000-0000-0000-0000000000b2") == .unmatched)
        let persisted = try coordinator.recentSessionStore.load()
        #expect(persisted.map(\.agentLink) == coordinator.recentSessions.map(\.agentLink))
    }

    @Test func linkingOffNeverReadsTheLogs() async throws {
        let reader = FakePromptReader(prompts)
        let (coordinator, directory) = try makeCoordinator(rows: rows, linkingEnabled: false, reader: reader)
        defer { try? FileManager.default.removeItem(at: directory) }

        coordinator.resolveAgentSessionLinks()
        await coordinator.agentLinkTask?.value

        #expect(coordinator.agentLinkTask == nil)
        #expect(reader.calls == 0)
        #expect(coordinator.recentSessions.allSatisfy { $0.agentLink == nil })
    }

    @Test func turningLinkingOffRemovesEveryLinkAndPersistsTheRemoval() async throws {
        var linkedRows = rows
        linkedRows[0].agentLink = .unmatched
        linkedRows[1].agentLink = .linked(
            AgentSessionMatch(
                agent: .omp,
                sessionId: "omp-1",
                workingDirectory: nil,
                sessionTitle: nil,
                sentAt: t0,
                sentText: nil
            )
        )
        let (coordinator, directory) = try makeCoordinator(
            rows: linkedRows,
            linkingEnabled: true,
            reader: FakePromptReader(prompts)
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        coordinator.setAgentSessionLinking(false)
        _ = await coordinator.recentSessionPersistenceTail?.value

        #expect(coordinator.settings.agentSessionLinkingEnabled == false)
        #expect(coordinator.recentSessions.allSatisfy { $0.agentLink == nil })
        #expect(try coordinator.recentSessionStore.load().allSatisfy { $0.agentLink == nil })
        let settings = try SettingsStore(url: directory.appendingPathComponent("settings.json")).load()
        #expect(settings.agentSessionLinkingEnabled == false)
    }

    /// A pass that lands after linking was turned off must not write links
    /// back: the user asked for none.
    @Test func aPassInFlightWhenLinkingTurnsOffWritesNothing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let reader = FakePromptReader(prompts, gate: gate)
        let (coordinator, directory) = try makeCoordinator(rows: rows, linkingEnabled: true, reader: reader)
        defer { try? FileManager.default.removeItem(at: directory) }

        coordinator.resolveAgentSessionLinks()
        let pass = try #require(coordinator.agentLinkTask)
        while reader.calls == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        coordinator.setAgentSessionLinking(false)
        gate.signal()
        await pass.value
        _ = await coordinator.recentSessionPersistenceTail?.value

        #expect(coordinator.agentLinkTask == nil)
        #expect(coordinator.recentSessions.allSatisfy { $0.agentLink == nil })
        #expect(try coordinator.recentSessionStore.load().allSatisfy { $0.agentLink == nil })
    }
}
