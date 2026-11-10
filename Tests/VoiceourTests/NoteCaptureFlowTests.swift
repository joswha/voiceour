import Combine
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers a note from the stop path to memory: a session started as a note,
/// the spoken "note to self" prefix and where it is ignored, what a note
/// leaves untouched, the session link a note gets in Tern, and the intent's
/// lifetime. Memory is a real store beside History in a temporary directory
/// the test removes.
@Suite("Note capture flow", .serialized)
@MainActor
struct NoteCaptureFlowTests {
    /// Records every insertion it is asked for and answers with one outcome.
    /// The inserter is the only pasteboard writer, so no insertion means no
    /// pasteboard write.
    // `lock` protects the recorded texts; the outcome is immutable.
    private final class CountingInserter: TextInserting, @unchecked Sendable {
        private let lock = NSLock()
        private let outcome: InsertionOutcome
        private var recorded: [String] = []

        init(outcome: InsertionOutcome) {
            self.outcome = outcome
        }

        var insertedTexts: [String] { lock.withLock { recorded } }

        func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
            lock.withLock { recorded.append(text) }
            return outcome
        }
    }

    /// Answers every capture and resolve with its configured values. With a
    /// release gate, `resolve` signals `resolveEntered` and parks until the
    /// gate fires, then records whether its task was cancelled.
    // `lock` protects the call counts and records; the answers and gates are immutable.
    private final class NoteSessionResolver: AgentSessionResolving, @unchecked Sendable {
        private let lock = NSLock()
        private let captureAnswer: AgentFocusCapture?
        private let resolveAnswer: ResolvedAgentSession?
        private let release: TestGate?
        let resolveEntered = TestGate()
        private var captures = 0
        private var resolves = 0
        private var cancellations: [Bool] = []

        init(capture: AgentFocusCapture?, resolve: ResolvedAgentSession?, release: TestGate? = nil) {
            captureAnswer = capture
            resolveAnswer = resolve
            self.release = release
        }

        var captureCalls: Int { lock.withLock { captures } }
        var resolveCalls: Int { lock.withLock { resolves } }
        var cancelledOnRelease: [Bool] { lock.withLock { cancellations } }

        func capture(target: TargetSnapshot) async -> AgentFocusCapture? {
            lock.withLock { captures += 1 }
            return captureAnswer
        }

        func resolve(target: TargetSnapshot, before: AgentFocusCapture) async -> ResolvedAgentSession? {
            lock.withLock { resolves += 1 }
            if let release {
                resolveEntered.fire()
                await release.wait()
                let cancelled = Task.isCancelled
                lock.withLock { cancellations.append(cancelled) }
            }
            return resolveAnswer
        }
    }

    /// Every state the coordinator published, in order.
    // `lock` protects the recorded states.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SessionState] = []

        var states: [SessionState] { lock.withLock { recorded } }

        func append(_ state: SessionState) {
            lock.withLock { recorded.append(state) }
        }
    }

    private struct Fixture {
        let coordinator: DictationCoordinator
        let inserter: CountingInserter
        let log: StateLog
        let subscription: AnyCancellable
        let directory: URL
    }

    /// 2027-01-15 08:00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    private let pane = AgentFocusCapture(pane: "42", foregroundPid: 66_425)
    private let tern = FakeTracker(bundleId: "so.stencil.tern", appName: "Tern", safety: .normalText)

    private func resolved(_ sessionId: String) -> ResolvedAgentSession {
        ResolvedAgentSession(
            agent: .omp,
            sessionId: sessionId,
            sessionFile: "/Users/v/.omp/agent/sessions/-Users-v-voiceour/2026-11-09T17-51-31-000Z_\(sessionId).jsonl",
            workingDirectory: "/Users/v/voiceour",
            sessionTitle: "Release prep",
            promptLogOffset: 963,
            resumable: true
        )
    }

    /// A coordinator whose History, ledger, settings and memory live in a
    /// fresh temporary directory. Memory is off: a note is saved anyway.
    private func makeFixture(
        transcript: String,
        tracker: FakeTracker = FakeTracker(),
        outcome: InsertionOutcome = .pasteAttempted,
        bindingEnabled: Bool = false,
        resolver: AgentSessionResolving = NoAgentSessionResolving()
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-note-flow-tests-\(UUID().uuidString)", isDirectory: true)
        let store = RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"))
        try store.save([])
        let inserter = CountingInserter(outcome: outcome)
        let t0 = self.t0
        let calendar = self.calendar
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text(transcript)),
            tracker: tracker,
            inserter: inserter,
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(agentSessionBindingEnabled: bindingEnabled, memoryEnabled: false),
            activeASRBackend: "fake",
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            recentSessionStore: store,
            dictationStatsStore: DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")),
            agentSessions: resolver,
            runtimeOverride: DictationRuntime(
                now: { t0 },
                makeUUID: { UUID() },
                sleep: { _ in },
                calendar: { calendar }
            )
        )
        let log = StateLog()
        let subscription = coordinator.statePublisher.sink { log.append($0) }
        return Fixture(
            coordinator: coordinator,
            inserter: inserter,
            log: log,
            subscription: subscription,
            directory: directory
        )
    }

    /// Records one utterance started with `intent` and waits until the
    /// coordinator is idle again.
    private func dictate(_ coordinator: DictationCoordinator, intent: CaptureIntent) async {
        switch intent {
        case .deliver: coordinator.start()
        case .note: coordinator.startNote()
        }
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight && coordinator.state == .idle }
    }

    /// Awaits every link and binding task, then the writes they queued.
    private func settle(_ coordinator: DictationCoordinator) async {
        while let entry = coordinator.agentBindingTasks.values.first {
            await entry.task.value
        }
        _ = await coordinator.recentSessionPersistenceTail?.value
    }

    private func finish(_ fixture: Fixture) {
        fixture.subscription.cancel()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    // MARK: - A session started as a note

    @Test func aNoteSessionSavesOneNoteAndDeliversNothing() async throws {
        let fixture = try makeFixture(transcript: "Buy oat milk and call the dentist tomorrow.")
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .note)
        await settle(coordinator)

        let note = try #require(coordinator.memoryEntries.first)
        #expect(coordinator.memoryEntries.count == 1)
        #expect(note.kind == .note)
        #expect(note.text == "Buy oat milk and call the dentist tomorrow.")
        // FakeRecorder reports 100 ms of audio.
        #expect(note.captureSeconds == 0.1)
        #expect(note.createdAt == t0)
        #expect(note.appBundleId == nil)
        #expect(note.thread == nil)
        #expect(coordinator.lastSavedNoteID == note.id)
        #expect(coordinator.lastOutcome == nil)
        #expect(coordinator.lastTranscript == "Buy oat milk and call the dentist tomorrow.")
        #expect(coordinator.captureIntent == .deliver)
        #expect(coordinator.settings.hasCompletedFirstRun)

        #expect(fixture.inserter.insertedTexts.isEmpty)
        #expect(coordinator.recentSessions.isEmpty)
        #expect(try coordinator.recentSessionStore.load().isEmpty)
        #expect(coordinator.dictationStats.totalSessions == 0)

        #expect(Array(fixture.log.states.suffix(3)) == [.cleaning, .noteSaved, .idle])
        #expect(!fixture.log.states.contains(.readyToInsert))

        // Saved with memory switched off, and on disk.
        #expect(coordinator.settings.memoryEnabled == false)
        #expect(coordinator.memoryStore.load().entries == [note])
    }

    /// A note started as one is saved whatever has focus, a secure field
    /// included: the user asked for a note, not a delivery.
    @Test func aNoteSessionSavesIntoASecureTargetToo() async throws {
        let fixture = try makeFixture(
            transcript: "Rotate the staging certificates.",
            tracker: FakeTracker(safety: .secure),
            outcome: .copiedOnly(reason: "secure_target")
        )
        defer { finish(fixture) }

        await dictate(fixture.coordinator, intent: .note)
        await settle(fixture.coordinator)

        #expect(fixture.coordinator.memoryEntries.map(\.text) == ["Rotate the staging certificates."])
        #expect(fixture.inserter.insertedTexts.isEmpty)
        #expect(fixture.coordinator.recentSessions.isEmpty)
    }

    @Test func theNextStartClearsTheSavedNoteAndDeliversNormally() async throws {
        let fixture = try makeFixture(transcript: "Buy oat milk and call the dentist tomorrow.")
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .note)
        #expect(coordinator.lastSavedNoteID != nil)

        coordinator.start()
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(coordinator.captureIntent == .deliver)
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight && coordinator.state == .idle }
        await settle(coordinator)

        #expect(fixture.inserter.insertedTexts == ["Buy oat milk and call the dentist tomorrow."])
        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(coordinator.recentSessions.map(\.text) == ["Buy oat milk and call the dentist tomorrow."])
        #expect(coordinator.dictationStats.totalSessions == 1)
        // Memory is off, so only the note is kept.
        #expect(coordinator.memoryEntries.map(\.kind) == [.note])
    }

    @Test func aNoteSessionWithAnEmptyTranscriptEndsCancelled() async throws {
        let fixture = try makeFixture(transcript: "   ")
        defer { finish(fixture) }

        await dictate(fixture.coordinator, intent: .note)
        await settle(fixture.coordinator)

        #expect(fixture.log.states.contains(.cancelled))
        #expect(!fixture.log.states.contains(.noteSaved))
        #expect(fixture.coordinator.memoryEntries.isEmpty)
        #expect(fixture.coordinator.lastSavedNoteID == nil)
        #expect(fixture.coordinator.captureIntent == .deliver)
        #expect(fixture.inserter.insertedTexts.isEmpty)
    }

    @Test func cancellingANoteRecordingSavesNothingAndResetsTheIntent() async throws {
        let fixture = try makeFixture(transcript: "Buy oat milk.")
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        coordinator.startNote()
        await waitUntil { coordinator.state == .recording }
        #expect(coordinator.captureIntent == .note)
        coordinator.cancel()
        #expect(coordinator.captureIntent == .deliver)
        await waitUntil { coordinator.state == .idle }
        await settle(coordinator)

        #expect(coordinator.memoryEntries.isEmpty)
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(fixture.inserter.insertedTexts.isEmpty)
        #expect(!fixture.log.states.contains(.noteSaved))
    }

    // MARK: - The spoken prefix

    @Test func aSpokenPrefixTurnsADictationIntoANote() async throws {
        let fixture = try makeFixture(transcript: "Note to self, buy oat milk and call the dentist tomorrow.")
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .deliver)
        await settle(coordinator)

        let note = try #require(coordinator.memoryEntries.first)
        #expect(coordinator.memoryEntries.count == 1)
        #expect(note.kind == .note)
        #expect(note.text == "Buy oat milk and call the dentist tomorrow.")
        #expect(coordinator.lastSavedNoteID == note.id)
        #expect(coordinator.lastTranscript == "Buy oat milk and call the dentist tomorrow.")
        #expect(fixture.inserter.insertedTexts.isEmpty)
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.dictationStats.totalSessions == 0)
        #expect(Array(fixture.log.states.suffix(2)) == [.noteSaved, .idle])
    }

    /// A secure field's dictation takes the secure path, the prefix's words
    /// included, and reaches no record.
    @Test func theSpokenPrefixIsIgnoredInASecureTarget() async throws {
        let fixture = try makeFixture(
            transcript: "Note to self, buy oat milk and call the dentist tomorrow.",
            tracker: FakeTracker(safety: .secure),
            outcome: .copiedOnly(reason: "secure_target")
        )
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .deliver)
        await settle(coordinator)

        let inserted = try #require(fixture.inserter.insertedTexts.first)
        #expect(fixture.inserter.insertedTexts.count == 1)
        #expect(inserted.hasPrefix("Note to self"))
        #expect(coordinator.memoryEntries.isEmpty)
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(coordinator.recentSessions.isEmpty)
        #expect(!fixture.log.states.contains(.noteSaved))
    }

    @Test func aFrenchDictationThatStartsWithThePrefixIsDelivered() async throws {
        let transcript = "Note to self, il faut acheter du pain et des œufs pour le dîner de ce soir."
        let fixture = try makeFixture(transcript: transcript)
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .deliver)
        await settle(coordinator)

        let inserted = try #require(fixture.inserter.insertedTexts.first)
        #expect(fixture.inserter.insertedTexts.count == 1)
        #expect(inserted.hasPrefix("Note to self"))
        #expect(coordinator.recentSessions.map(\.text) == [inserted])
        #expect(coordinator.memoryEntries.isEmpty)
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(coordinator.lastOutcome == .pasteAttempted)
    }

    /// The prefix with nothing after it is no note: the dictation is
    /// delivered as said.
    @Test func thePrefixAloneIsDeliveredAsOrdinaryText() async throws {
        let fixture = try makeFixture(transcript: "Note to self.")
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .deliver)
        await settle(coordinator)

        let inserted = try #require(fixture.inserter.insertedTexts.first)
        #expect(fixture.inserter.insertedTexts.count == 1)
        #expect(inserted.hasPrefix("Note to self"))
        #expect(coordinator.recentSessions.count == 1)
        #expect(coordinator.memoryEntries.isEmpty)
        #expect(coordinator.lastSavedNoteID == nil)
        #expect(!fixture.log.states.contains(.noteSaved))
    }

    // MARK: - Linking a note to the focused agent session

    @Test func aNoteTakenInTernIsLinkedToTheResolvedSession() async throws {
        let resolver = NoteSessionResolver(capture: pane, resolve: resolved("01a1c16f"))
        let fixture = try makeFixture(
            transcript: "Check the flaky upload test before merging.",
            tracker: tern,
            bindingEnabled: true,
            resolver: resolver
        )
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .note)
        await settle(coordinator)

        let note = try #require(coordinator.memoryEntries.first)
        let thread = try #require(note.thread)
        #expect(thread == JournalThreadRef(resolved("01a1c16f")))
        #expect(thread.sessionId == "01a1c16f")
        #expect(thread.title == "Release prep")
        #expect(thread.resumable)
        #expect(thread.sent == nil)
        #expect(resolver.captureCalls == 1)
        #expect(resolver.resolveCalls == 1)
        #expect(coordinator.agentBindingTasks.isEmpty)
        #expect(fixture.inserter.insertedTexts.isEmpty)
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.memoryStore.load().entries.first?.thread == thread)
    }

    enum UnlinkedNote: String, CaseIterable, Sendable {
        case noPane
        case noSession
        case bindingOff
    }

    /// No pane before the save, no exact session after it, or binding off:
    /// the note is saved and stays unlinked.
    @Test(arguments: UnlinkedNote.allCases)
    func aNoteWithoutAnExactSessionStaysUnlinked(_ reason: UnlinkedNote) async throws {
        let resolver =
            switch reason {
            case .noPane: NoteSessionResolver(capture: nil, resolve: resolved("01a1c16f"))
            case .noSession: NoteSessionResolver(capture: pane, resolve: nil)
            case .bindingOff: NoteSessionResolver(capture: pane, resolve: resolved("01a1c16f"))
            }
        let fixture = try makeFixture(
            transcript: "Check the flaky upload test before merging.",
            tracker: tern,
            bindingEnabled: reason != .bindingOff,
            resolver: resolver
        )
        defer { finish(fixture) }

        await dictate(fixture.coordinator, intent: .note)
        await settle(fixture.coordinator)

        let note = try #require(fixture.coordinator.memoryEntries.first)
        #expect(note.kind == .note)
        #expect(note.thread == nil)
        #expect(fixture.coordinator.agentBindingTasks.isEmpty)
        switch reason {
        case .noPane:
            #expect(resolver.resolveCalls == 0)
        case .noSession:
            #expect(resolver.resolveCalls == 1)
        case .bindingOff:
            #expect(resolver.captureCalls == 0)
            #expect(resolver.resolveCalls == 0)
        }
    }

    @Test func turningBindingOffWhileTheLinkIsInFlightLeavesTheNoteUnlinked() async throws {
        let release = TestGate()
        let resolver = NoteSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let fixture = try makeFixture(
            transcript: "Check the flaky upload test before merging.",
            tracker: tern,
            bindingEnabled: true,
            resolver: resolver
        )
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .note)
        await resolver.resolveEntered.wait()
        let noteID = try #require(coordinator.lastSavedNoteID)
        let inFlight = try #require(coordinator.agentBindingTasks[noteID]?.task)
        coordinator.setAgentSessionBinding(false)
        #expect(coordinator.agentBindingTasks.isEmpty)
        release.fire()
        await inFlight.value
        await settle(coordinator)

        #expect(resolver.cancelledOnRelease == [true])
        #expect(coordinator.memoryEntries.map(\.id) == [noteID])
        #expect(coordinator.memoryEntries.first?.thread == nil)
        #expect(coordinator.memoryStore.load().entries.first?.thread == nil)
    }

    @Test func clearingMemoryCancelsTheLinkInFlight() async throws {
        let release = TestGate()
        let resolver = NoteSessionResolver(capture: pane, resolve: resolved("01a1c16f"), release: release)
        let fixture = try makeFixture(
            transcript: "Check the flaky upload test before merging.",
            tracker: tern,
            bindingEnabled: true,
            resolver: resolver
        )
        defer { finish(fixture) }
        let coordinator = fixture.coordinator

        await dictate(coordinator, intent: .note)
        await resolver.resolveEntered.wait()
        let noteID = try #require(coordinator.lastSavedNoteID)
        let inFlight = try #require(coordinator.agentBindingTasks[noteID]?.task)
        #expect(await coordinator.clearMemory())
        #expect(coordinator.agentBindingTasks.isEmpty)
        release.fire()
        await inFlight.value
        await settle(coordinator)

        #expect(resolver.cancelledOnRelease == [true])
        #expect(coordinator.memoryEntries.isEmpty)
        #expect(!coordinator.memoryExistsOnDisk)
    }
}
