import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

@Suite("Agent session binding", .serialized)
@MainActor
struct AgentSessionLinkingTests {
    /// Answers every capture and resolve with its configured values and counts
    /// the calls. With a release gate, `resolve` signals `resolveEntered` and
    /// parks until the gate fires, then records whether its task was cancelled.
    // `lock` protects the call counts and records; the answers and gates are immutable.
    private final class FakeSessionResolver: AgentSessionResolving, @unchecked Sendable {
        private let lock = NSLock()
        private let captureAnswer: AgentFocusCapture?
        private let resolveAnswer: ResolvedAgentSession?
        private let release: TestGate?
        let resolveEntered = TestGate()
        private var captures = 0
        private var befores: [AgentFocusCapture] = []
        private var cancellations: [Bool] = []

        init(capture: AgentFocusCapture?, resolve: ResolvedAgentSession?, release: TestGate? = nil) {
            captureAnswer = capture
            resolveAnswer = resolve
            self.release = release
        }

        var captureCalls: Int { lock.withLock { captures } }
        var resolveCalls: Int { lock.withLock { befores.count } }
        var resolvedBefore: [AgentFocusCapture] { lock.withLock { befores } }
        /// Per released resolve, whether its task was cancelled by then.
        var cancelledOnRelease: [Bool] { lock.withLock { cancellations } }

        func capture(target: TargetSnapshot) async -> AgentFocusCapture? {
            lock.withLock { captures += 1 }
            return captureAnswer
        }

        func resolve(target: TargetSnapshot, before: AgentFocusCapture) async -> ResolvedAgentSession? {
            lock.withLock { befores.append(before) }
            if let release {
                resolveEntered.fire()
                await release.wait()
                let cancelled = Task.isCancelled
                lock.withLock { cancellations.append(cancelled) }
            }
            return resolveAnswer
        }
    }

    /// Returns the configured snapshot for every binding and counts reads.
    // `lock` protects the read count; the snapshot is immutable.
    private final class FakeSessionReader: AgentSessionReading, @unchecked Sendable {
        private let lock = NSLock()
        private let snapshot: AgentSessionSnapshot?
        private var reads = 0

        init(_ snapshot: AgentSessionSnapshot?) {
            self.snapshot = snapshot
        }

        var readCalls: Int { lock.withLock { reads } }

        func read(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
            lock.withLock { reads += 1 }
            return snapshot
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

    // `lock` protects the count.
    private final class SaveCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var saves = 0

        var count: Int { lock.withLock { saves } }

        func record() {
            lock.withLock { saves += 1 }
        }
    }

    private struct Harness {
        let coordinator: DictationCoordinator
        let directory: URL
        let clock: TestClock
        let saves: SaveCounter
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let pane = AgentFocusCapture(pane: "42", foregroundPid: 66_425)
    private let ternTracker = FakeTracker(bundleId: "so.stencil.tern", appName: "Tern", safety: .normalText)

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

    private func makeHarness(
        rows: [RecentSession] = [],
        bindingEnabled: Bool = true,
        tracker: FakeTracker? = nil,
        outcome: InsertionOutcome = .pasteAttempted,
        resolver: FakeSessionResolver? = nil,
        reader: FakeSessionReader = FakeSessionReader(nil)
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-agent-binding-tests-\(UUID().uuidString)")
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save(rows)
        let clock = TestClock(t0)
        let saves = SaveCounter()
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("Deploy the cluster to staging.")),
            tracker: tracker ?? ternTracker,
            inserter: FakeInserter(outcome: outcome),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(agentSessionBindingEnabled: bindingEnabled),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            recentSessionSnapshotSave: { store, sessions in
                saves.record()
                try store.save(sessions)
            },
            agentSessions: resolver ?? FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f")),
            agentSessionReader: reader,
            runtimeOverride: DictationRuntime(now: { clock.now }, makeUUID: { UUID() }, sleep: { _ in })
        )
        return Harness(coordinator: coordinator, directory: directory, clock: clock, saves: saves)
    }

    private func deliver(_ coordinator: DictationCoordinator) async {
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }
    }

    /// Awaits every binding task, then every refresh pass they started, then
    /// the writes they queued.
    private func settle(_ coordinator: DictationCoordinator) async {
        while let entry = coordinator.agentBindingTasks.values.first {
            await entry.task.value
        }
        while let refresh = coordinator.agentRefreshTask {
            await refresh.value
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    private func boundRow(
        _ index: Int,
        text: String = "Deploy the cluster to staging.",
        binding: AgentSessionBinding
    ) -> RecentSession {
        RecentSession(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            // A higher index is older, so seeded rows keep their order in History.
            createdAt: t0.addingTimeInterval(-TimeInterval(index)),
            text: text,
            agentSession: binding
        )
    }

    // MARK: - Binding at delivery

    @Test func aPasteIntoTernBindsTheRowAndPersistsTheBinding() async throws {
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"))
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await settle(harness.coordinator)

        let row = try #require(harness.coordinator.recentSessions.first)
        #expect(row.agentSession == AgentSessionBinding(resolved("01a1c16f"), boundAt: t0))
        #expect(resolver.captureCalls == 1)
        #expect(resolver.resolvedBefore == [pane])
        #expect(harness.coordinator.agentBindingTasks.isEmpty)
        let persisted = try harness.coordinator.recentSessionStore.load()
        #expect(persisted.map(\.agentSession) == [row.agentSession])
    }

    enum UnboundDelivery: String, CaseIterable, Sendable {
        case copiedOnly
        case failed
        case secureTarget
        case otherApp
        case bindingOff
    }

    /// Only an attempted paste into Tern's normal-text input with binding on
    /// resolves anything; every other delivery stays unbound.
    @Test(arguments: UnboundDelivery.allCases)
    func aDeliveryOutsideTheGatesNeverResolves(_ delivery: UnboundDelivery) async throws {
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"))
        let harness =
            switch delivery {
            case .copiedOnly:
                try makeHarness(outcome: .copiedOnly(reason: "missing_synth_paste_permission"), resolver: resolver)
            case .failed:
                try makeHarness(outcome: .failed(reason: "pasteboard_write_failed"), resolver: resolver)
            case .secureTarget:
                try makeHarness(
                    tracker: FakeTracker(bundleId: "so.stencil.tern", appName: "Tern", safety: .secure),
                    outcome: .copiedOnly(reason: "secure_target"),
                    resolver: resolver
                )
            case .otherApp:
                try makeHarness(tracker: FakeTracker(), resolver: resolver)
            case .bindingOff:
                try makeHarness(bindingEnabled: false, resolver: resolver)
            }
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await settle(harness.coordinator)

        #expect(resolver.resolveCalls == 0)
        #expect(harness.coordinator.agentBindingTasks.isEmpty)
        #expect(harness.coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        switch delivery {
        case .secureTarget, .otherApp, .bindingOff:
            #expect(resolver.captureCalls == 0)
        case .copiedOnly, .failed:
            break
        }
    }

    /// No pane before the paste, or no exact session after it, binds nothing.
    @Test(arguments: [true, false])
    func anInexactAnswerLeavesTheRowUnbound(captureFound: Bool) async throws {
        let resolver = FakeSessionResolver(capture: captureFound ? pane : nil, resolve: nil)
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await settle(harness.coordinator)

        #expect(resolver.resolveCalls == (captureFound ? 1 : 0))
        #expect(harness.coordinator.agentBindingTasks.isEmpty)
        #expect(harness.coordinator.recentSessions.count == 1)
        #expect(harness.coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        #expect(try harness.coordinator.recentSessionStore.load().allSatisfy { $0.agentSession == nil })
    }

    /// A second delivery while the first is still binding must not discard
    /// the first's binding.
    @Test func twoQuickDeliveriesKeepBothBindings() async throws {
        let release = TestGate()
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await resolver.resolveEntered.wait()
        await deliver(harness.coordinator)
        #expect(harness.coordinator.agentBindingTasks.count == 2)
        release.fire()
        await settle(harness.coordinator)

        #expect(harness.coordinator.recentSessions.count == 2)
        #expect(harness.coordinator.recentSessions.allSatisfy { $0.agentSession?.sessionId == "01a1c16f" })
        #expect(try harness.coordinator.recentSessionStore.load().allSatisfy { $0.agentSession != nil })
    }

    // MARK: - Discarding bindings

    @Test func turningBindingOffDeletesEveryBindingAndCancelsTheOneInFlight() async throws {
        let release = TestGate()
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let harness = try makeHarness(
            rows: [boundRow(1, binding: AgentSessionBinding(resolved("01a1c16e"), boundAt: t0))],
            resolver: resolver
        )
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await resolver.resolveEntered.wait()
        let inFlight = try #require(harness.coordinator.agentBindingTasks.values.first?.task)
        harness.coordinator.setAgentSessionBinding(false)
        #expect(harness.coordinator.agentBindingTasks.isEmpty)
        release.fire()
        await inFlight.value
        await settle(harness.coordinator)

        #expect(resolver.cancelledOnRelease == [true])
        #expect(harness.coordinator.settings.agentSessionBindingEnabled == false)
        #expect(harness.coordinator.recentSessions.count == 2)
        #expect(harness.coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        #expect(try harness.coordinator.recentSessionStore.load().allSatisfy { $0.agentSession == nil })
        let settings = try SettingsStore(url: harness.directory.appendingPathComponent("settings.json")).load()
        #expect(settings.agentSessionBindingEnabled == false)
    }

    @Test func clearingHistoryCancelsTheBindingAndNothingIsWrittenAfter() async throws {
        let release = TestGate()
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await resolver.resolveEntered.wait()
        let inFlight = try #require(harness.coordinator.agentBindingTasks.values.first?.task)
        #expect(await harness.coordinator.clearRecentSessions())
        let savesAfterClear = harness.saves.count
        release.fire()
        await inFlight.value
        await settle(harness.coordinator)

        #expect(resolver.cancelledOnRelease == [true])
        #expect(harness.coordinator.recentSessions.isEmpty)
        #expect(harness.saves.count == savesAfterClear)
        #expect(try harness.coordinator.recentSessionStore.load().isEmpty)
    }

    @Test func terminationPreventsTheBindingWrite() async throws {
        let release = TestGate()
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await resolver.resolveEntered.wait()
        let inFlight = try #require(harness.coordinator.agentBindingTasks.values.first?.task)
        await harness.coordinator.prepareForTermination()
        let savesAtTermination = harness.saves.count
        release.fire()
        await inFlight.value
        _ = await harness.coordinator.recentSessionPersistenceTail?.value

        #expect(resolver.cancelledOnRelease == [true])
        #expect(harness.coordinator.agentRefreshTask == nil)
        #expect(harness.saves.count == savesAtTermination)
        #expect(harness.coordinator.recentSessions.allSatisfy { $0.agentSession == nil })
        #expect(try harness.coordinator.recentSessionStore.load().allSatisfy { $0.agentSession == nil })
    }

    @Test func deletingARowCancelsItsBinding() async throws {
        let release = TestGate()
        let resolver = FakeSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let harness = try makeHarness(resolver: resolver)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await deliver(harness.coordinator)
        await resolver.resolveEntered.wait()
        let id = try #require(harness.coordinator.recentSessions.first?.id)
        let inFlight = try #require(harness.coordinator.agentBindingTasks[id]?.task)
        #expect(await harness.coordinator.deleteRecentSession(id: id))

        #expect(inFlight.isCancelled)
        #expect(harness.coordinator.agentBindingTasks[id] == nil)
        let savesAfterDelete = harness.saves.count
        release.fire()
        await inFlight.value
        await settle(harness.coordinator)

        #expect(resolver.cancelledOnRelease == [true])
        #expect(harness.coordinator.recentSessions.isEmpty)
        #expect(harness.saves.count == savesAfterDelete)
    }

    // MARK: - Refresh

    @Test func refreshMarksTheRowSentFromTheSessionsPrompts() async throws {
        let reader = FakeSessionReader(
            AgentSessionSnapshot(
                title: "Deploys",
                sessionFileExists: true,
                prompts: [AgentSessionPrompt(sentAt: t0.addingTimeInterval(1), text: "Deploy the cluster to staging.")]
            )
        )
        let harness = try makeHarness(
            rows: [boundRow(1, binding: AgentSessionBinding(resolved("01a1c16f"), boundAt: t0))],
            reader: reader
        )
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.clock.now = t0.addingTimeInterval(60)

        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)

        let binding = try #require(harness.coordinator.recentSessions.first?.agentSession)
        #expect(binding.send == .sent(sentAt: t0.addingTimeInterval(1), text: nil))
        #expect(binding.sessionTitle == "Deploys")
        #expect(binding.resumable)
        #expect(try harness.coordinator.recentSessionStore.load().map(\.agentSession) == [binding])
    }

    @Test func refreshMarksTheRowNotSentOnlyOnceTheSendWindowHasPassed() async throws {
        let reader = FakeSessionReader(AgentSessionSnapshot(title: "Deploys", sessionFileExists: true, prompts: []))
        var binding = AgentSessionBinding(resolved("01a1c16e"), boundAt: t0)
        binding.sessionTitle = "Deploys"
        binding.resumable = true
        let harness = try makeHarness(rows: [boundRow(1, binding: binding)], reader: reader)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.clock.now = t0.addingTimeInterval(AgentPromptSendMatcher.sendWindow - 1)
        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)
        #expect(harness.coordinator.recentSessions.first?.agentSession?.send == nil)

        harness.clock.now = t0.addingTimeInterval(AgentPromptSendMatcher.sendWindow + 1)
        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)

        #expect(harness.coordinator.recentSessions.first?.agentSession?.send == .notSent)
        #expect(try harness.coordinator.recentSessionStore.load().first?.agentSession?.send == .notSent)
    }

    /// A session the reader cannot open says nothing about the send, so the
    /// row stays pending past the send window and nothing is written.
    @Test func refreshLeavesAnUnreadableSessionPending() async throws {
        let reader = FakeSessionReader(nil)
        let binding = AgentSessionBinding(resolved("01a1c16f"), boundAt: t0)
        let harness = try makeHarness(rows: [boundRow(1, binding: binding)], reader: reader)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.clock.now = t0.addingTimeInterval(AgentPromptSendMatcher.sendWindow + 1)
        _ = await harness.coordinator.recentSessionPersistenceTail?.value
        let savesBefore = harness.saves.count

        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)

        #expect(reader.readCalls == 1)
        #expect(harness.coordinator.recentSessions.first?.agentSession == binding)
        #expect(harness.coordinator.recentSessions.first?.agentSession?.send == nil)
        #expect(harness.saves.count == savesBefore)
        #expect(try harness.coordinator.recentSessionStore.load().first?.agentSession?.send == nil)
    }

    @Test func refreshFillsAMissingTitleAndResumability() async throws {
        let reader = FakeSessionReader(AgentSessionSnapshot(title: "Deploys", sessionFileExists: true, prompts: []))
        let harness = try makeHarness(
            rows: [boundRow(1, binding: AgentSessionBinding(resolved("01a1c16f"), boundAt: t0))],
            reader: reader
        )
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.clock.now = t0.addingTimeInterval(60)

        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)

        let binding = try #require(harness.coordinator.recentSessions.first?.agentSession)
        #expect(binding.sessionTitle == "Deploys")
        #expect(binding.resumable)
        #expect(binding.send == nil)
        #expect(try harness.coordinator.recentSessionStore.load().map(\.agentSession) == [binding])
    }

    @Test func refreshWritesNothingWhenNothingChanged() async throws {
        let reader = FakeSessionReader(AgentSessionSnapshot(title: "Deploys", sessionFileExists: true, prompts: []))
        var pending = AgentSessionBinding(resolved("01a1c16f"), boundAt: t0)
        pending.sessionTitle = "Deploys"
        pending.resumable = true
        var settled = AgentSessionBinding(resolved("01a1c16e"), boundAt: t0)
        settled.sessionTitle = "Smoke tests"
        settled.resumable = true
        settled.send = .notSent
        let harness = try makeHarness(
            rows: [boundRow(1, binding: pending), boundRow(2, binding: settled)],
            reader: reader
        )
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.clock.now = t0.addingTimeInterval(60)
        _ = await harness.coordinator.recentSessionPersistenceTail?.value
        let savesBefore = harness.saves.count

        harness.coordinator.refreshAgentSessions()
        await settle(harness.coordinator)

        // Only the pending row is read; the settled one has nothing left to learn.
        #expect(reader.readCalls == 1)
        #expect(harness.saves.count == savesBefore)
        #expect(harness.coordinator.recentSessions.map(\.agentSession) == [pending, settled])
    }
}
