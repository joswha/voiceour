import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac
@testable import Voiceour

/// Covers DictationCoordinator behaviour through injected fakes: stale-generation
/// guards, temp-audio cleanup on every exit path, late-resolved insertion targets,
/// suggestion surfacing, hard-capped vocabulary snapshots, end-to-end telemetry,
/// and recent-session persistence/termination ordering. The coordinator is
/// @MainActor and fully DI-injected; the ASR fake can block on a gate so a test
/// can inject a cancel/restart mid-transcription.
@Suite("DictationCoordinator", .serialized)
@MainActor
struct DictationCoordinatorTests {
    // MARK: Stale-generation guards

    /// What happens to the session while its decode is still in flight. Either
    /// way the result is stale by the time it lands, and a stale result may
    /// publish nothing: not the transcript, not the outcome.
    enum StaleResultCause: String, CaseIterable, Sendable {
        /// Escape mid-transcription, and nothing else.
        case cancellation
        /// The same cancel plus the restart the user immediately asks for. The
        /// cancelled pipeline still owns the recorder, so that restart is refused
        /// outright and only a start after the result lands is honoured.
        case cancellationThenRestart
    }

    @Test(arguments: StaleResultCause.allCases)
    func aSupersededTranscriptionResultNeverPublishes(_ cause: StaleResultCause) async {
        let gate = TestGate()
        let recorder = FakeRecorder()
        let asr = FakeASR(behavior: .gatedText(gate, "stale transcript"))
        let coordinator = makeCoordinator(recorder: recorder, asr: asr)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }

        coordinator.cancel()
        await waitUntil { coordinator.state == .idle }
        #expect(coordinator.isProcessingInFlight)

        if cause == .cancellationThenRestart {
            // The cancelled pipeline still owns the recorder, so this start is
            // refused rather than racing the old session's stop/cleanup.
            coordinator.start()
            #expect(recorder.startCount == 1)
            #expect(coordinator.state == .idle)
        }

        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }
        #expect(coordinator.state == .idle)
        #expect(coordinator.lastTranscript == "")
        #expect(coordinator.lastOutcome == nil)

        if cause == .cancellationThenRestart {
            // And the session started after the result landed is a clean one:
            // the recorder runs again and the stale text never reappears.
            coordinator.start()
            await waitUntil { coordinator.state == .recording }
            #expect(recorder.startCount == 2)
            #expect(coordinator.lastTranscript == "")
            #expect(coordinator.lastOutcome == nil)
        }
    }

    // The system-audio restore ramps the user's volume back over a 120 ms fade
    // and `SystemAudioMuter.restore()` awaits every step of it. Nothing about
    // transcription depends on that fade, and 80.1% of real recorded sessions on
    // the development machine were muted during capture, so awaiting it on the
    // stop path put a full fade in front of four out of five ASR calls -- longer
    // than the inference itself. This pins the restore as started-but-not-awaited:
    // ASR must reach .transcribing while restore() is still blocked.
    @Test func recordingStopDoesNotWaitForTheAudioFadeBeforeTranscribing() async {
        let muteGate = TestGate()
        let restoreGate = TestGate()
        let transcriptionGate = TestGate()
        let muter = GatedAudioMuter(muteGate: muteGate, restoreGate: restoreGate)
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .gatedText(transcriptionGate, "hello world")),
            audioMuter: muter
        )

        coordinator.start()
        await waitUntil { muter.isMuted }
        muteGate.fire()
        coordinator.stopAndProcess()

        // Reaching .transcribing proves the stop path called the ASR client, and
        // restore() is still parked on its gate, so it cannot have been awaited.
        await waitUntil { coordinator.state == .transcribing }
        #expect(muter.restoreEnteredCount == 1, "the restore must have been started")
        #expect(muter.restoreCount == 0, "the fade must still be in flight, not awaited")

        restoreGate.fire()
        transcriptionGate.fire()
        await waitUntil { coordinator.lastOutcome != nil }
        await waitUntil { muter.restoreCount == 1 && !muter.isMuted }
    }

    /// The backend-restart affordance in `VoicePane` and the guard in
    /// `VoiceourAppDelegate.restartApplication()` are both `!state.isActive`.
    /// They must agree, or the button offers a restart the delegate refuses.
    @Test func restartIsRefusedWhileASessionIsActiveAndAllowedAtIdle() async {
        let gate = TestGate()
        let coordinator = makeCoordinator(asr: FakeASR(behavior: .gatedText(gate, "restart boundary")))

        #expect(!coordinator.state.isActive)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        #expect(coordinator.state.isActive)

        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }
        #expect(coordinator.state.isActive)

        gate.fire()
        // Same publish-before-completion race as the checkpoint test: the outcome
        // is published while the session is still winding down, so asserting
        // `!isActive` off that barrier is a coin flip on a loaded machine.
        await waitUntil { !coordinator.isProcessingInFlight }
        #expect(!coordinator.state.isActive)
    }

    // MARK: Temp-audio cleanup

    @Test func tempAudioRemovedOnSuccessPath() async {
        let recorder = FakeRecorder()
        let inserter = FakeInserter(outcome: .pasteAttempted)
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("hello world")),
            inserter: inserter
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }

        let produced = recorder.producedURL
        #expect(produced != nil)
        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(!fileExists(produced))
    }

    @Test func tempAudioRemovalRetriesTransientFailureOnSuccessPath() async {
        let recorder = FakeRecorder()
        let remover = TransientFailingAudioRemover()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("hello world")),
            temporaryAudioRemover: { try remover.remove($0) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(remover.callCount == 2)
        #expect(!fileExists(recorder.producedURL))
    }

    @Test func tempAudioRemovedOnCancellation() async {
        let gate = TestGate()
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .gatedText(gate, "x"))
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }

        // Recorder has finalized its file; it exists until the cancel path removes it.
        #expect(fileExists(recorder.producedURL))

        coordinator.cancel()
        await waitUntil { coordinator.state == .idle }
        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(!fileExists(recorder.producedURL))
    }

    @Test func tempAudioRemovedOnErrorPath() async {
        let recorder = FakeRecorder()
        let error = ASRErrorMessage(
            requestId: "req",
            code: .internalError,
            category: "backend",
            retryable: false,
            userMessageKey: "asr_error",
            detail: "boom"
        )
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .throwError(error))
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil {
            if case .error = coordinator.state { return true }
            return false
        }

        #expect(recorder.producedURL != nil)
        #expect(!fileExists(recorder.producedURL))
        #expect(coordinator.state == .error(.internalError))
    }

    @Test func focusSwitchDuringTranscriptionUsesLatestTargetForInsertion() async {
        let originalTarget = TargetSnapshot(
            bundleId: "com.example.app-a",
            pid: 101,
            safety: .normalText
        )
        let latestTarget = TargetSnapshot(
            bundleId: "com.example.app-b",
            pid: 202,
            safety: .normalText
        )
        let gate = TestGate()
        let tracker = MutableTracker(snapshot: originalTarget)
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .gatedText(gate, "message for the latest app")),
            tracker: tracker,
            inserter: inserter
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }

        tracker.setSnapshot(latestTarget)
        gate.fire()
        await waitUntil { coordinator.lastOutcome != nil }

        #expect(inserter.insertedTarget == latestTarget)
        #expect(coordinator.lastOutcome == .pasteAttempted)
    }

    @Test func eligibleTaughtTermRepairsBeforePersistenceAndInsertion() async throws {
        let result = try await processTranscript(
            "run cubectl now",
            glossary: [
                ProtectedTerm(
                    canonical: "kubectl",
                    spokenAliases: [],
                    source: .explicitCorrection
                )
            ]
        )

        #expect(result.text == "run kubectl now")
        #expect(result.insertedText == "run kubectl now")
        #expect(result.session.text == "run kubectl now")
        #expect(result.session.rawTranscript == "run cubectl now")
    }

    @Test func taughtKubectlHeardAsFormStillCanonicalizes() async throws {
        let result = try await processTranscript(
            "run quebecal now",
            glossary: [
                ProtectedTerm(
                    canonical: "kubectl",
                    spokenAliases: ["quebecal"],
                    source: .explicitCorrection
                )
            ]
        )

        #expect(result.text == "run kubectl now")
    }

    @Test func untaughtQuebecalIsUnchanged() async throws {
        let result = try await processTranscript("run quebecal now", glossary: [])

        #expect(result.text == "run quebecal now")
    }

    @Test func riskyTaughtTermDoesNotPhoneticallyFire() async throws {
        let result = try await processTranscript(
            "the semaphorre stood beside the railway",
            glossary: [
                ProtectedTerm(
                    canonical: "semaphore",
                    spokenAliases: [],
                    source: .explicitCorrection
                )
            ]
        )

        #expect(result.text == "the semaphorre stood beside the railway")
    }

    @Test func suggestionAppearsAfterCompletionWithoutBlockingCompletion() async {
        var settings = VoiceCore.Settings()
        settings.glossary = [
            ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])
        ]
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Please run cube cuttle now.")),
            settings: settings
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.lastOutcome != nil }
        await waitUntil { !coordinator.pendingSuggestions.isEmpty }

        #expect(
            coordinator.pendingSuggestions.contains { suggestion in
                suggestion.canonical == "kubectl"
            })
    }

    @Test func parakeetSessionPersistsEndToEndTelemetry() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }

        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = FixtureRecorder(
            sourceURL: URL(fileURLWithPath: "fixtures/audio/hello_16k_mono.wav"),
            directory: fixture.directory
        )
        // Through the registry, so this measures the client the app actually
        // builds — including the model it pins the sidecar to.
        let asr = ASRBackendRegistry.builtIn.client(
            for: "parakeet",
            context: ASRBackendContext(
                sidecarExecutableURL: testProductsDirectory().appendingPathComponent("voiceour-asr")
            )
        )
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: asr,
            recentSessionStore: fixture.store
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil(timeout: .seconds(45)) {
            coordinator.lastOutcome != nil
                || {
                    if case .error = coordinator.state { return true }
                    return false
                }()
        }

        let sessions = try fixture.store.load()
        let session = try #require(sessions.first)
        let stages = try #require(session.stages)
        let endToEndMs = try #require(stages.stopReleaseToInsertionOutcomeMs)
        let hostASRMs = try #require(stages.asrMs)
        let insertMs = try #require(stages.insertMs)

        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(stages.asrBackendId == "parakeet-cpp")
        #expect((stages.asrInferenceMs ?? 0) > 0)
        #expect((stages.asrTotalMs ?? 0) >= (stages.asrInferenceMs ?? 0))
        #expect(endToEndMs >= hostASRMs + insertMs)
        #expect(!fileExists(recorder.producedURL))
        let telemetry =
            "parakeet coordinator telemetry: endToEnd=\(endToEndMs)ms "
            + "hostASR=\(hostASRMs)ms insert=\(insertMs)ms "
            + "backend=\(stages.asrBackendId ?? "nil") "
            + "load=\(stages.asrLoadMs ?? -1)ms "
            + "inference=\(stages.asrInferenceMs ?? -1)ms "
            + "total=\(stages.asrTotalMs ?? -1)ms\n"
        FileHandle.standardError.write(Data(telemetry.utf8))
    }

    // MARK: Recent-session persistence

    /// The journal writes twice per delivered dictation — the transcript before
    /// insertion, the outcome after it — and the UI is published ahead of both.
    /// Blocking each write in turn stands inside the window it opens: the
    /// publication that write is supposed to be behind is already on screen, and
    /// once it lands the durable file agrees with what the user was shown.
    @Test(arguments: [1, 2])
    func aBlockedCheckpointNeverHoldsBackItsPublication(_ blockedWrite: Int) async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [blockedWrite])
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("checkpointed transcript")),
            inserter: inserter,
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == blockedWrite }

        // Insertion, and therefore the outcome, is on the far side of write 1.
        let outcomeIsPublished = blockedWrite == 2
        #expect(coordinator.state == .readyToInsert)
        #expect(coordinator.recentSessions.map(\.text) == ["checkpointed transcript"])
        #expect(inserter.insertionCount == (outcomeIsPublished ? 1 : 0))
        #expect((coordinator.lastOutcome == .pasteAttempted) == outcomeIsPublished)
        #expect((coordinator.recentSessions.first?.outcome?.disposition == .pasteAttempted) == outcomeIsPublished)
        #expect((coordinator.recentSessions.first?.stages?.insertMs != nil) == outcomeIsPublished)

        writer.release(call: blockedWrite)
        // Strictly after the last durable write: `processStop` awaits each
        // snapshot, and `isProcessingInFlight` clears only once it returns.
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(writer.snapshotCount == 2)
        #expect(inserter.insertionCount == 1)
        #expect(coordinator.lastOutcome == .pasteAttempted)
        // Write 1 is the pre-insertion checkpoint: the ASR stage timings are
        // already known, the insertion's are not.
        #expect(writer.snapshots[0].first?.outcome == nil)
        #expect(writer.snapshots[0].first?.stages?.insertMs == nil)
        #expect(writer.snapshots[0].first?.stages?.stopReleaseToInsertionOutcomeMs == nil)
        #expect(writer.snapshots[0].first?.stages?.asrBackendId == "fake")
        #expect(writer.snapshots[0].first?.stages?.asrLoadMs == 7)
        #expect(writer.snapshots[0].first?.stages?.asrInferenceMs == 31)
        #expect(writer.snapshots[0].first?.stages?.asrTotalMs == 38)
        #expect(writer.snapshots[1].first?.outcome?.disposition == .pasteAttempted)
        #expect(writer.snapshots[1].first?.stages?.insertMs != nil)
        #expect(writer.snapshots[1].first?.stages?.stopReleaseToInsertionOutcomeMs != nil)

        let reloaded = try? fixture.store.load()
        #expect(reloaded?.first?.outcome == coordinator.recentSessions.first?.outcome)
        #expect(reloaded?.first?.stages?.insertMs == coordinator.recentSessions.first?.stages?.insertMs)
    }

    @Test func cancellationDuringFirstCheckpointNeverInserts() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("cancel before insertion")),
            inserter: inserter,
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }
        coordinator.cancel()
        writer.release(call: 1)
        await drain()

        #expect(inserter.insertionCount == 0)
        #expect((try? fixture.store.load().map(\.text)) == ["cancel before insertion"])
    }

    @Test func completedInsertionOutcomePersistsWhenSessionIsCancelledBeforeReturn() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let insertionReturnGate = TestGate()
        let inserter = GatedInserter(returned: insertionReturnGate)
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("persist the completed paste")),
            inserter: inserter,
            recentSessionStore: fixture.store
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { inserter.sideEffectCount == 1 }

        coordinator.cancel()
        insertionReturnGate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }
        #expect(coordinator.lastOutcome == nil)
        #expect(coordinator.recentSessions.first?.outcome?.disposition == .pasteAttempted)

        // A later checkpoint must retain the cancelled session's completed
        // side effect instead of rebuilding history from stale in-memory data.
        await driveUtterance(coordinator)
        await coordinator.prepareForTermination()

        let persisted = try fixture.store.load()
        #expect(persisted.count == 2)
        #expect(persisted.last?.outcome?.disposition == .pasteAttempted)
        #expect(persisted.last?.stages?.insertMs != nil)
        #expect(persisted.last?.stages?.stopReleaseToInsertionOutcomeMs != nil)
    }

    /// The two destructive history operations. Both are queued on the same FIFO
    /// tail as the session checkpoints, so a checkpoint that was already in
    /// flight cannot land after them and put the rows back.
    enum DestructiveHistoryOperation: String, CaseIterable, Sendable {
        case delete
        case clear
    }

    @Test(arguments: DestructiveHistoryOperation.allCases)
    func aDestructiveWriteBehindAPendingCheckpointCannotBeResurrected(
        _ operation: DestructiveHistoryOperation
    ) async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1, 2])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("history to erase")),
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }
        let id = coordinator.recentSessions[0].id
        var operationCompleted = false
        let destruction = Task { @MainActor in
            let durable: Bool
            switch operation {
            case .delete: durable = await coordinator.deleteRecentSession(id: id)
            case .clear: durable = await coordinator.clearRecentSessions()
            }
            operationCompleted = true
            return durable
        }

        // Published immediately, acknowledged only once the write behind both
        // blocked checkpoints has actually run.
        await waitUntil { coordinator.recentSessions.isEmpty }
        #expect(!operationCompleted)
        writer.release(call: 1)
        await waitUntil { writer.snapshotCount == 2 }
        #expect(!operationCompleted)
        writer.release(call: 2)
        #expect(await destruction.value)
        #expect(operationCompleted)
        await coordinator.prepareForTermination()

        #expect((try? fixture.store.load()) == [])
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    @Test func failedDestructiveSnapshotIsNotAcknowledgedAsDurable() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = RecentSession(text: "must remain durable")
        try fixture.store.save([session])
        let writer = SessionSnapshotWriterSpy(failingCalls: [1])
        let coordinator = makeCoordinator(
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        let isDurable = await coordinator.deleteRecentSession(id: session.id)

        #expect(!isDurable)
        #expect(coordinator.recentSessions.isEmpty)
        #expect(try fixture.store.load().map(\.text) == ["must remain durable"])
    }

    @Test func failedCheckpointDoesNotPoisonLaterSnapshotOrInsertion() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(failingCalls: [1])
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("survives persistence failure")),
            inserter: inserter,
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        // `lastOutcome != nil` is the wrong barrier here: the pipeline publishes
        // the outcome BEFORE the durable checkpoint on purpose, so this test's
        // read of the persisted store below was racing a `.utility` snapshot task
        // that a loaded machine starves — 4/8 failures under a full parallel run,
        // 10/10 in isolation. `isProcessingInFlight` clears only after
        // `processStop` returns, i.e. strictly after that write.
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(inserter.insertionCount == 1)
        #expect(coordinator.recentSessions.first?.outcome?.disposition == .pasteAttempted)
        #expect((try? fixture.store.load().first?.outcome?.disposition) == .pasteAttempted)

        let clearWasDurable = await coordinator.clearRecentSessions()
        #expect(clearWasDurable)
        await coordinator.prepareForTermination()
        #expect(writer.snapshotCount == 3)
        #expect((try? fixture.store.load()) == [])
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    @Test func terminationWaitsForPendingSessionCheckpoint() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("durable before exit")),
            inserter: inserter,
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }

        var terminationCompleted = false
        let termination = Task { @MainActor in
            await coordinator.prepareForTermination()
            terminationCompleted = true
        }
        await drain()
        #expect(!terminationCompleted)

        writer.release(call: 1)
        await termination.value
        #expect(terminationCompleted)
        #expect(inserter.insertionCount == 0)
        #expect((try? fixture.store.load().map(\.text)) == ["durable before exit"])
    }

    @Test func terminationRejectsDirectAndHotkeyStartsAfterCapturingPersistenceTail() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
        let recorder = FakeRecorder()
        let hotkey = FakeHotkey()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("termination boundary")),
            hotkey: hotkey,
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }

        var terminationCompleted = false
        let termination = Task { @MainActor in
            await coordinator.prepareForTermination()
            terminationCompleted = true
        }
        await drain()
        #expect(!terminationCompleted)

        coordinator.start()
        hotkey.trigger()
        await drain()
        #expect(recorder.startCount == 1)
        #expect(coordinator.state == .cancelled)

        writer.release(call: 1)
        await termination.value
        await drain()
        #expect(terminationCompleted)
        #expect(recorder.startCount == 1)
        #expect((try? fixture.store.load().map(\.text)) == ["termination boundary"])
    }

    /// Escape belongs to the focused app at every other moment, so the binder
    /// claims it only while a session runs. The armed flag lives in the binder
    /// though, so a keypress that raced a session ending can still arrive at an
    /// idle coordinator: that one must cancel nothing and must not flash
    /// `.cancelled`.
    @Test(arguments: [false, true])
    func escapeIsArmedOnlyWhileASessionRunsAndOnlyEndsALiveOne(_ startsASession: Bool) async {
        let hotkey = FakeHotkey()
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("discarded by escape")),
            hotkey: hotkey
        )

        #expect(!hotkey.isCancelArmed)
        if startsASession {
            coordinator.start()
            await waitUntil { coordinator.state == .recording }
        }
        #expect(hotkey.isCancelArmed == startsASession)

        hotkey.triggerCancel()
        await waitUntil { coordinator.state == .idle }
        await drain()

        #expect(coordinator.state == .idle)
        #expect(!hotkey.isCancelArmed)
        #expect(recorder.startCount == (startsASession ? 1 : 0))
        #expect(coordinator.lastTranscript.isEmpty)
    }

    // MARK: Recording session

    /// The fake backend bypasses the microphone check entirely, so this needs a
    /// non-fake `activeASRBackend` to reach the permission branch at all.
    @Test func deniedMicrophonePermissionNeverStartsTheRecorder() async {
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("never recorded")),
            permissions: DeniedMicrophonePermissions(),
            activeASRBackend: "mlx"
        )

        coordinator.start()
        await drain()

        #expect(recorder.startCount == 0)
        // The reason survives the reset, but the session returns to idle: nothing
        // was captured, so parking the coordinator in .error would leave the
        // menu-bar dot crimson long after the user granted permission.
        //
        // The reason is the user-facing sentence and it names where the remedy is,
        // because the app cannot grant this itself.
        #expect(coordinator.lastFailure == .microphoneDenied)
        #expect(coordinator.errorMessage == UserFacingDictationFailure.microphoneDenied.cause)
        #expect(coordinator.lastFailure?.destination == .systemSettings)
        await waitUntil { coordinator.state == .idle }
        #expect(coordinator.state == .idle)
    }

    @Test func inputMeterPublishesWhileRecordingAndStopsAfterFinalize() async {
        let recorder = MeteringRecorder(level: 0.6)
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("metered utterance"))
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        await waitUntil { coordinator.inputMeter.level > 0 }

        #expect(coordinator.inputMeter.live)
        #expect(coordinator.inputMeter.level > 0)

        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }

        // Metering is torn down on the stop path, so the published level resets
        // rather than freezing at the last sample.
        #expect(coordinator.inputMeter.level == 0)
        #expect(!coordinator.inputMeter.live)
    }

    /// A microphone can stream buffers on time and fill every one of them with
    /// zeros — measured on a built-in array in clamshell, 552 all-zero buffers in
    /// six seconds. Liveness never flips, `AutoStopDetector` cannot arm until it
    /// has heard speech, and nothing else ends a recording, so the session sat in
    /// WARMING until the user gave up. The deadline turns that hang into the one
    /// thing the user can act on: which microphone heard nothing, and why.
    @Test func aCaptureThatNeverGoesLiveEndsTheSessionInsteadOfHanging() async {
        let clock = VirtualClock()
        let recorder = SilentRecorder(
            reason: "MacBook Pro Microphone hears nothing while the lid is closed")
        let coordinator = makeCoordinator(recorder: recorder, runtimeOverride: clock.runtime)

        coordinator.start()
        // The whole six seconds are virtual, so the session is over before the
        // first poll here: `.recording` is never observable from this side.
        await waitUntil { coordinator.state == .error(.internalError) }

        #expect(!coordinator.inputMeter.live)
        #expect(recorder.stopCount == 1)
        #expect(coordinator.lastFailure?.title == "NO AUDIO")
        #expect(
            coordinator.errorMessage
                == "Nothing was recorded — MacBook Pro Microphone hears nothing while the lid is closed."
        )
        // The deadline is a bound, not a stopwatch. Too early and it would cut off
        // the slowest real warm-up measured — 3782 ms, a Continuity microphone;
        // one poll interval late is the loop noticing, anything beyond that means
        // something other than the deadline ended the session.
        let elapsed = clock.elapsed()
        #expect(elapsed >= DictationCoordinator.captureWarmUpDeadline)
        #expect(elapsed < DictationCoordinator.captureWarmUpDeadline + 0.1)
    }

    /// A device with no writable mute or volume — a DisplayPort monitor, in the
    /// measurement that motivated this — leaves the capture unmuted. The pane
    /// has to be able to say so instead of promising a mute that never lands.
    @Test func aRefusedMuteIsPublishedAsUnavailableAndClearedByASuccessfulOne() async {
        var settings = VoiceCore.Settings()
        settings.muteSystemAudioDuringCapture = true
        // The subject here is the muter, not the cue. With sounds on the mute
        // deliberately waits one cue length, and these sessions are decided inside
        // that window; the cue's own timing is pinned by the session-cue tests.
        settings.sessionSoundsEnabled = false

        let refused = makeCoordinator(
            asr: FakeASR(behavior: .text("unmuted utterance")),
            audioMuter: RefusingAudioMuter(),
            settings: settings
        )
        refused.start()
        await waitUntil { refused.state == .recording }
        await waitUntil { refused.isSystemAudioMuteUnavailable }
        #expect(!refused.isSystemAudioMuted)

        // Same coordinator, muting switched off: nothing was asked for, so
        // nothing was refused.
        refused.settings.muteSystemAudioDuringCapture = false
        refused.cancel()
        await waitUntil { refused.state == .idle }
        refused.start()
        await waitUntil { refused.state == .recording }
        await waitUntil { !refused.isSystemAudioMuteUnavailable }

        let granted = makeCoordinator(
            asr: FakeASR(behavior: .text("muted utterance")),
            audioMuter: CountingAudioMuter(),
            settings: settings
        )
        granted.start()
        await waitUntil { granted.state == .recording }
        #expect(granted.isSystemAudioMuted)
        #expect(!granted.isSystemAudioMuteUnavailable)
    }

    /// Every way a muted session can end. The mute is a side effect on the rest
    /// of the Mac, so restore ownership is the invariant: whichever path reaches
    /// it first performs exactly one restore, and no other path performs a second.
    enum MutedSessionExit: String, CaseIterable, Sendable {
        /// The ordinary stop: the pipeline restores the moment capture ends.
        case stop
        /// Escape while recording: this path owns both the discard and the restore.
        case cancelWhileRecording
        /// Escape after the stop, the case a local flag cannot cover: `cancel()`
        /// restores on its own task while the cancelled pipeline restores in its
        /// catch. Two owners, one session, still exactly one restore.
        case cancelDuringTranscription
        /// A wire failure: the stop path restores as soon as capture ends and the
        /// catch blocks restore only when that point was never reached, so an ASR
        /// error restores once rather than twice.
        case asrFailure
    }

    @Test(arguments: MutedSessionExit.allCases)
    func aMutedSessionIsRestoredExactlyOnceOnEveryExitPath(_ exitPath: MutedSessionExit) async {
        var settings = VoiceCore.Settings()
        settings.muteSystemAudioDuringCapture = true
        // Cue off: this pins mute/restore ownership per exit path, not the sound
        // that precedes the device fade.
        settings.sessionSoundsEnabled = false

        let transcriptionGate = TestGate()
        let behavior: FakeASR.Behavior
        switch exitPath {
        case .stop, .cancelWhileRecording:
            behavior = .text("muted utterance")
        case .cancelDuringTranscription:
            behavior = .gatedText(transcriptionGate, "cancelled mid-transcription")
        case .asrFailure:
            behavior = .throwError(
                ASRErrorMessage(
                    requestId: "req",
                    code: .internalError,
                    category: "backend",
                    retryable: false,
                    userMessageKey: "asr_error",
                    detail: "boom"
                ))
        }

        let muter = CountingAudioMuter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: behavior),
            audioMuter: muter,
            settings: settings
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        // The flag publishes only after the mute task resolves, so waiting on it
        // is what puts every row in the same place: device muted, mute landed.
        await waitUntil { coordinator.isSystemAudioMuted }

        switch exitPath {
        case .stop, .asrFailure:
            coordinator.stopAndProcess()
        case .cancelWhileRecording:
            coordinator.cancel()
        case .cancelDuringTranscription:
            coordinator.stopAndProcess()
            await waitUntil { coordinator.state == .transcribing }
            coordinator.cancel()
            transcriptionGate.fire()
        }

        await waitUntil { !coordinator.isProcessingInFlight && !coordinator.isSystemAudioMuted }
        // Settle before counting: a second owner's restore would land here.
        await drain()

        #expect(muter.muteCount == 1)
        #expect(muter.restoreCount == 1)
        #expect(!coordinator.isSystemAudioMuted)
    }

    /// Quitting from inside the window where the device is already muted but
    /// `beginRecording` has not published the flag yet — it publishes only after
    /// awaiting the mute task, which is the window a `guard isSystemAudioMuted`
    /// dedupe gets wrong. `applicationShouldTerminate` calls `Darwin.exit` the
    /// moment `prepareForTermination()` returns, so a termination that returns
    /// early leaves the user's audio muted until the next launch recovers durable
    /// ownership.
    enum ClaimedRestore: String, CaseIterable, Sendable {
        /// Termination is the first path to want this session's restore.
        case unclaimed
        /// `cancel()` claimed it first and is itself parked behind the gated mute,
        /// so termination must await *that* restore rather than observing "someone
        /// else is doing it" and returning into the exit.
        case claimedByCancel
    }

    @Test(arguments: ClaimedRestore.allCases)
    func terminationAwaitsTheRestoreItOwesFromInsideTheMuteWindow(_ claim: ClaimedRestore) async {
        var settings = VoiceCore.Settings()
        settings.muteSystemAudioDuringCapture = true

        let muteGate = TestGate()
        let muter = GatedAudioMuter(muteGate: muteGate)
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("quit mid-mute")),
            audioMuter: muter,
            settings: settings
        )

        coordinator.start()
        // Wait on the device, not on `.recording`: the state publishes before the
        // mute lands, so only this is deterministic about being inside the window.
        await waitUntil { muter.isMuted }
        #expect(!coordinator.isSystemAudioMuted, "the flag publishes only after the mute resolves")

        if claim == .claimedByCancel {
            coordinator.cancel()
            await drain()
            #expect(muter.restoreCount == 0, "the claimed restore is still behind the mute")
        }

        var terminationCompleted = false
        let termination = Task { @MainActor in
            await coordinator.prepareForTermination()
            terminationCompleted = true
        }
        await drain()
        // Without this, a termination that returned early would still find the
        // audio restored by the time the gate fired, and the row would pass on
        // scheduler timing alone.
        #expect(!terminationCompleted, "termination returned before the restore it owes ran")
        #expect(muter.restoreCount == 0)

        muteGate.fire()
        await termination.value

        #expect(terminationCompleted)
        // The invariant that matters is the device, not the published flag.
        #expect(!muter.isMuted, "quitting must never leave the user's audio muted")
        #expect(muter.muteCount == 1)
        #expect(muter.restoreCount == 1)
        #expect(!coordinator.isSystemAudioMuted)
    }

    // MARK: Vocabulary teaching and clearing

    /// Teaching a mishearing onto a shipped term makes the alias the user's, not
    /// the term. Rewriting provenance here handed the whole bundled entry to
    /// `clearLearnedVocabulary`, which deleted a default the user only ever added
    /// a surface to.
    @Test func teachingASurfaceOntoABundledTermKeepsItBundled() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)

        #expect(!coordinator.hasLearnedVocabulary)
        coordinator.commitTerm(termId: nil, canonical: "kubectl", spokenForms: ["cube control"])

        let taught = try #require(coordinator.settings.glossary.first { $0.canonical == "kubectl" })
        #expect(taught.source == .bundled)
        #expect(Glossary.userAliases(for: taught).contains("cube control"))
        // The term stayed bundled, so a `source` test would now leave the
        // Diagnostics clear disabled with learned vocabulary still on disk.
        #expect(coordinator.hasLearnedVocabulary)
    }

    /// The clear promises the shipped defaults survive and everything the user
    /// added does not. Both halves are load-bearing: filtering on `source` alone
    /// used to leave a taught mishearing welded to a bundled term forever.
    @Test func clearingLearnedVocabularyRestoresBundledSurfacesAndDropsLearnedTerms() throws {
        let coordinator = makeVocabularyCoordinator(
            glossary: Settings.defaultGlossary + [
                ProtectedTerm(canonical: "NeuroDock", spokenAliases: ["neuro dock"], source: .explicitCorrection),
                ProtectedTerm(canonical: "ProjectTerm", spokenAliases: [], source: .manualImport),
            ]
        )
        coordinator.commitTerm(termId: nil, canonical: "kubectl", spokenForms: ["cube control"])

        coordinator.clearLearnedVocabulary()

        let canonicals = coordinator.settings.glossary.map(\.canonical)
        #expect(!canonicals.contains("NeuroDock"))
        #expect(!canonicals.contains("ProjectTerm"))
        #expect(canonicals == Settings.defaultGlossary.map(\.canonical))

        let kubectl = try #require(coordinator.settings.glossary.first { $0.canonical == "kubectl" })
        #expect(!Glossary.userAliases(for: kubectl).contains("cube control"))
        #expect(kubectl.labeledAliases.isEmpty)
        // The shipped surfaces are restored, not merely stripped alongside the
        // taught one.
        #expect(kubectl.spokenAliases == ["cube cuddle", "kube cuddle"])
        #expect(!coordinator.hasLearnedVocabulary)
    }

    /// A default the user deleted from the glossary stays deleted: the clear
    /// restores surfaces on rows that survive, it does not resurrect rows.
    @Test func clearingLearnedVocabularyDoesNotResurrectARemovedDefault() {
        let coordinator = makeVocabularyCoordinator(
            glossary: Settings.defaultGlossary.filter { $0.canonical != "CGEvent" }
        )

        coordinator.clearLearnedVocabulary()

        #expect(!coordinator.settings.glossary.contains { $0.canonical == "CGEvent" })
    }

    /// An orphaned default — one an older build shipped and this build no longer
    /// does — has no shipped surface set to be restored to, so the clear reduces
    /// it to its canonical. Stripping only `labeledAliases` cleared the user's
    /// confirmations while preserving aliases from a version that no longer
    /// exists, which made a damaging shipped alias unremovable: a removed default
    /// carried `Cloud` as an alias of `Claude` and rewrote every dictated
    /// "Google Cloud" into "Google Claude".
    @Test func clearingLearnedVocabularyDropsUnshippedSurfacesOfAnOrphanedDefault() throws {
        let orphan = ProtectedTerm(
            canonical: "Claude",
            spokenAliases: ["Cloud"],
            termId: "Claude",
            source: .bundled
        )
        let coordinator = makeVocabularyCoordinator(
            glossary: Settings.defaultGlossary + [orphan]
        )
        #expect(
            CleanupEngine.clean("deploy on Google Cloud", glossary: [orphan]) == "deploy on Google Claude",
            "precondition: the orphaned alias is what corrupts the product name")

        coordinator.clearLearnedVocabulary()

        let claude = try #require(coordinator.settings.glossary.first { $0.canonical == "Claude" })
        #expect(claude.spokenAliases.isEmpty)
        #expect(claude.labeledAliases.isEmpty)
        #expect(CleanupEngine.clean("deploy on Google Cloud", glossary: [claude]) == "deploy on Google Cloud")
        // The row itself survives: the canonical may still be vocabulary the
        // user relies on, and its own surface still normalises.
        #expect(CleanupEngine.clean("ask claude about it", glossary: [claude]) == "ask Claude about it")
    }

    /// The whole feature, end to end, on the surfaces the user actually touches:
    /// teach a mishearing off a transcript, dictate it again and get the canonical;
    /// edit the glossary row and it still matches; clear the row and it stops. The
    /// two alias stores meet in every one of those hops, and the reported bug was
    /// that they disagreed.
    @Test func aTaughtSurfaceSurvivesTheGlossaryRowRoundTrip() async throws {
        let coordinator = makeVocabularyCoordinator(
            glossary: [],
            asrText: "please run cube uh cuddle on the pod"
        )

        coordinator.commitTerm(termId: nil, canonical: "kubectl", spokenForms: ["cube uh cuddle"])
        await driveUtterance(coordinator)
        #expect(coordinator.lastTranscript == "please run kubectl on the pod")

        // What the glossary row shows is what the engines match on.
        let taught = try #require(coordinator.settings.glossary.first)
        #expect(Glossary.userAliases(for: taught) == ["cube uh cuddle"])

        // Committing the row unchanged must not quietly reject the taught surface.
        coordinator.settings.glossary[0] = TermMutation.settingAliases(
            Glossary.userAliases(for: taught),
            on: taught
        )
        await driveUtterance(coordinator)
        #expect(coordinator.lastTranscript == "please run kubectl on the pod")

        // Clearing the field has to actually stop it matching, not just stop
        // showing it.
        coordinator.settings.glossary[0] = TermMutation.settingAliases(
            [],
            on: coordinator.settings.glossary[0]
        )
        await driveUtterance(coordinator)
        #expect(coordinator.lastTranscript == "please run cube cuddle on the pod")
    }

    /// A term edited from its own row arrives with the whole form set the row
    /// displayed, so the set is authoritative: dropping a form in the editor has
    /// to actually drop it. The id is the row's identity and must survive the
    /// write, or the open row would jump to a different record.
    @Test func editingATermReplacesItsSpokenFormsAndKeepsItsId() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)

        #expect(
            coordinator.commitTerm(
                termId: "kubectl",
                canonical: "kubectl",
                spokenForms: ["kube cuddle"]
            ))

        let edited = try #require(coordinator.settings.glossary.first { $0.termId == "kubectl" })
        #expect(edited.canonical == "kubectl")
        #expect(Glossary.userAliases(for: edited) == ["kube cuddle"])
    }

    /// History's teach names a canonical it may never have seen and lists no
    /// forms, so its write is additive. Treating it as a replacement would let
    /// teaching `cube control` delete the two surfaces kubectl ships with.
    @Test func teachingOntoABundledTermAddsAFormWithoutDroppingShippedOnes() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)

        #expect(
            coordinator.commitTerm(
                termId: nil,
                canonical: "kubectl",
                spokenForms: ["cube control"]
            ))

        let taught = try #require(coordinator.settings.glossary.first { $0.canonical == "kubectl" })
        let forms = Glossary.userAliases(for: taught)
        #expect(forms.contains("cube cuddle"))
        #expect(forms.contains("kube cuddle"))
        #expect(forms.contains("cube control"))
    }

    /// Correcting a term's spelling is an edit of that record, not a new term
    /// beside it: the id and every form it already held stay put.
    @Test func renamingATermKeepsItsIdAndItsForms() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)
        let original = try #require(coordinator.settings.glossary.first { $0.termId == "kubectl" })
        let displayedForms = Glossary.userAliases(for: original)

        #expect(
            coordinator.commitTerm(
                termId: "kubectl",
                canonical: "kubectl-2",
                spokenForms: displayedForms
            ))

        let renamed = try #require(coordinator.settings.glossary.first { $0.termId == "kubectl" })
        #expect(renamed.canonical == "kubectl-2")
        #expect(Glossary.userAliases(for: renamed) == displayedForms)
    }

    /// Renaming a term onto a spelling another term already holds is refused, not
    /// merged. Two rows with one canonical make canonicalization depend on term
    /// order, and the second row is unreachable in a list that names terms — the
    /// user would think the rename was lost.
    @Test func renamingATermToAnExistingCanonicalIsRefused() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)
        let before = coordinator.settings.glossary
        let event = try #require(before.first { $0.termId == "CGEvent" })

        // Case differs, the spelling does not: `kubectl` is already a term.
        #expect(
            coordinator.commitTerm(
                termId: "CGEvent",
                canonical: "KUBECTL",
                spokenForms: Glossary.userAliases(for: event)
            ) == false)

        #expect(coordinator.glossaryNotice == "“kubectl” is already a term. Open it to add a spoken form.")
        #expect(coordinator.settings.glossary == before)
    }

    /// A refused edit changes nothing and says why, so the editor can stay open
    /// on the text the user typed. A silent partial write here would leave the
    /// row showing forms the glossary never accepted.
    @Test func aRefusedTermEditReturnsFalseAndSetsTheNotice() {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)
        let before = coordinator.settings.glossary

        // "cube cuddle" already belongs to the bundled kubectl term.
        #expect(
            coordinator.commitTerm(
                termId: "CGEvent",
                canonical: "CGEvent",
                spokenForms: ["cube cuddle"]
            ) == false)

        #expect(coordinator.glossaryNotice == "That spoken form already belongs to another term.")
        #expect(coordinator.settings.glossary == before)
    }

    /// Re-importing the same word list adds nothing. Imported rows written by
    /// scoped builds carry `project:<uuid>/…` ids no fresh import can reproduce,
    /// so matching on term id alone appended a duplicate `Kubernetes` on every
    /// relaunch-and-reimport.
    @Test func reimportingAWordListMergesOntoTheImportedRowItAlreadyHas() throws {
        let legacy = ProtectedTerm(
            canonical: "Kubernetes",
            spokenAliases: [],
            protected: false,
            termId: "project:legacy/Kubernetes",
            source: .manualImport
        )
        let coordinator = makeVocabularyCoordinator(glossary: [legacy])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-wordlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("words.txt")
        try Data("Kubernetes\n".utf8).write(to: file)

        coordinator.importWordList(from: file)
        coordinator.importWordList(from: file)

        #expect(coordinator.glossaryNotice == nil)
        let live = coordinator.settings.glossary.filter {
            $0.tombstonedAt == nil && $0.canonical == "Kubernetes"
        }
        #expect(live.count == 1)
        #expect(live.first?.source == .manualImport)
    }

    @Test func clearingHistoryRemovesTheJournalFromDisk() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("erase these words")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)
        #expect(coordinator.recentSessions.count == 1)

        #expect(await coordinator.clearRecentSessions())

        #expect(coordinator.recentSessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    @Test func deletingOneTranscriptRemovesItFromTheJournal() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("remove this transcript")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)
        let session = try #require(coordinator.recentSessions.first)
        #expect(coordinator.recentSessions.count == 1)

        #expect(await coordinator.deleteRecentSession(id: session.id))

        #expect(coordinator.recentSessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    /// A stop path that throws still owns the recorder. Without this the WAV and the
    /// microphone session outlive the session that created them, and the next
    /// dictation starts over a capture nothing is reading.
    @Test func aFailedStopPathDiscardsTheRecording() async throws {
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .throwError(ASRErrorMessage(code: .inferenceFailed, requestId: nil, detail: "boom")))
        )

        await driveUtterance(coordinator)

        #expect(coordinator.state == .error(.inferenceFailed))
        #expect(recorder.discardCount == 1)
        #expect(!fileExists(recorder.producedURL))
    }

    /// Cancelling mid-finalize must not discard from two places at once: the
    /// pipeline's `recorder.stop()` could otherwise return a WAV the cancel path had
    /// already deleted. The pipeline owns the discard from `.finalizingAudio` on.
    @Test func cancellingDuringFinalizeDiscardsExactlyOnce() async throws {
        let recorder = FakeRecorder()
        let gate = TestGate()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .gatedText(gate, "never delivered"))
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state != .recording }

        coordinator.cancel()
        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }
        await drain()

        #expect(coordinator.state == .idle)
        #expect(recorder.discardCount == 1)
    }

    /// A password spoken into a password field is delivered as a concealed copy and
    /// then forgotten. Journaling it would leave it in plain text in
    /// recent-sessions.json, searchable, until 500 later dictations evicted it.
    @Test func aSecureTargetIsDeliveredButNeverJournaled() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("correct horse battery staple")),
            tracker: FakeTracker(bundleId: "com.example.PasswordField", safety: .secure),
            inserter: FakeInserter(outcome: .copiedOnly(reason: "secure_target")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)

        // Delivered.
        #expect(coordinator.lastTranscript == "correct horse battery staple")
        #expect(coordinator.lastOutcome == .copiedOnly(reason: "secure_target"))
        // Not remembered.
        #expect(coordinator.recentSessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    /// A normal target still records, so the test above is proving the safety class
    /// and not merely that journaling is broken.
    @Test func aNormalTargetIsStillJournaled() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("this one is remembered")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)

        #expect(coordinator.recentSessions.count == 1)
    }

    /// The decoder's least sure word rides into history with its score, from the
    /// RAW transcript's words — the evidence a reader needs to teach a misheard
    /// term. Fake-backend results without segments journal nothing extra.
    @Test func theLeastConfidentRawWordIsJournaledWithItsScore() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = ASRResult(
            requestId: "req",
            backendId: "parakeet",
            modelId: "parakeet",
            modelRevision: "pinned",
            transcript: ASRTranscript(
                text: "hello wrold",
                language: "en",
                segments: [
                    ASRSegment(
                        startMs: 0,
                        endMs: 900,
                        text: "hello wrold",
                        words: [
                            ASRWord(text: "hello", startMs: 0, endMs: 400, confidence: 0.99),
                            ASRWord(text: "wrold", startMs: 400, endMs: 900, confidence: 0.41),
                        ]
                    )
                ]
            ),
            timingsMs: ASRTimings(load: 7, inference: 31, total: 38)
        )
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .custom(result)),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)

        let session = try #require(coordinator.recentSessions.first)
        #expect(session.leastConfidentWord == LeastConfidentWord(text: "wrold", score: 0.41))
    }

    /// History that cannot be decoded is moved aside, never overwritten: the first
    /// snapshot after launch would otherwise replace it with an empty list.
    @Test func unreadableHistoryIsQuarantinedAndReported() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("{ this is not history".utf8).write(to: fixture.store.url)

        let coordinator = makeCoordinator(recentSessionStore: fixture.store)

        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.errorMessage?.contains("could not be read") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.contains("recent-sessions.json.corrupt-") }
        #expect(quarantined.count == 1)
    }

    /// The lifetime ledger is journaled at exactly the site the transcript is,
    /// so the two durable records cannot disagree about what happened.
    @Test func acompletedDictationIsCountedInTheLifetimeLedger() async throws {
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("one two three four five")),
            dictationStatsStore: stats.store
        )

        await driveUtterance(coordinator)

        #expect(coordinator.dictationStats.totalSessions == 1)
        #expect(coordinator.dictationStats.totalWords == 5)
        #expect(coordinator.dictationStats.totalActiveDays == 1)
        #expect(coordinator.dictationStats.days.count == 1)
        #expect(
            coordinator.dictationStats.apps["com.apple.TextEdit"]
                == DictationAppStat(
                    sessions: 1,
                    words: 5,
                    seconds: coordinator.dictationStats.totalSeconds,
                    name: "TextEdit",
                    lastDay: coordinator.dictationStats.days.keys.first
                )
        )

        await coordinator.prepareForTermination()
        let persisted = try stats.store.load()
        #expect(persisted == coordinator.dictationStats)
    }

    /// The same agreement *while* the dictation is in flight, not only once it
    /// has finished.
    ///
    /// `recentSessions` publishes before its own snapshot is awaited, so a ledger
    /// folded on the far side of that await left a real interval in which the
    /// journal held a session the ledger did not — and Home reads both.
    /// `owesFirstRunGuidance` retires on either record, so that interval rendered
    /// a retired first-run card above four zeroes with the caption that names the
    /// gesture underneath it, told to a reader who had just used the gesture.
    ///
    /// Standing inside the transcript's own durable write is what makes the
    /// interval reachable on every run rather than caught by a lucky sample: the
    /// main actor is free there, which is exactly when the console renders.
    @Test func theTwoDurableRecordsAreNeverSeparatelyObservable() async {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        let settings = scratchSettingsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        defer { try? FileManager.default.removeItem(at: settings.url.deletingLastPathComponent()) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("one two three")),
            settingsStore: settings,
            recentSessionStore: history.store,
            dictationStatsStore: stats.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }

        #expect(coordinator.recentSessions.count == 1)
        #expect(coordinator.dictationStats.totalSessions == 1)
        // The card is already gone here, on the journal row alone. The ledger has
        // to have moved with it, because Home's zeroed caption is what fills the
        // space the card leaves.
        #expect(!coordinator.owesFirstRunGuidance)

        writer.release(call: 1)
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(coordinator.recentSessions.count == 1)
        #expect(coordinator.dictationStats.totalSessions == 1)
    }

    /// Quit inside that same window. The transcript's write is already queued and
    /// the drain will land it, so the ledger's fold has to be queued with it: a
    /// termination that dropped the fold would leave the two files disagreeing for
    /// the rest of the install's life, which no later dictation could repair.
    @Test func aTerminationDuringTheTranscriptWriteStillCountsTheDictation() async throws {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        let settings = scratchSettingsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        defer { try? FileManager.default.removeItem(at: settings.url.deletingLastPathComponent()) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("one two three")),
            settingsStore: settings,
            recentSessionStore: history.store,
            dictationStatsStore: stats.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }

        let termination = Task { @MainActor in await coordinator.prepareForTermination() }
        await drain()
        writer.release(call: 1)
        await termination.value

        #expect(try history.store.load().count == 1)
        #expect(try stats.store.load().totalSessions == 1)
    }

    /// A secure target reaches neither durable record. The ledger holds only
    /// counts, but a count is still evidence that something was dictated into a
    /// password field.
    @Test func aSecureTargetIsNeverCounted() async throws {
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("correct horse battery staple")),
            tracker: FakeTracker(bundleId: "com.example.PasswordField", safety: .secure),
            inserter: FakeInserter(outcome: .copiedOnly(reason: "secure_target")),
            dictationStatsStore: stats.store
        )

        await driveUtterance(coordinator)

        #expect(coordinator.lastTranscript == "correct horse battery staple")
        #expect(coordinator.dictationStats == DictationStatsLedger())
        #expect(!FileManager.default.fileExists(atPath: stats.store.url.path))
        #expect(coordinator.dictationStats.apps.isEmpty)
    }

    /// First launch with a ledger seeds it from the transcripts already on disk,
    /// so a reader who has been dictating for months does not open Home to a zero.
    @Test func theFirstLaunchWithoutALedgerBackfillsItFromHistory() async throws {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        try history.store.save([
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                text: "one two three",
                stages: SessionStageTimings(captureMs: 4_000)
            ),
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_086_400),
                text: "four five",
                stages: SessionStageTimings(captureMs: 2_000)
            ),
            // No measured capture: contributes words with no time rather than an
            // invented speaking rate.
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_172_800),
                text: "six"
            ),
        ])

        let coordinator = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: stats.store
        )

        #expect(coordinator.dictationStats.totalSessions == 3)
        #expect(coordinator.dictationStats.totalWords == 6)
        #expect(coordinator.dictationStats.totalSeconds == 6)
        #expect(coordinator.dictationStats.totalActiveDays == 3)
        #expect(coordinator.dictationStats.longestStreakDays == 3)

        await coordinator.prepareForTermination()
        #expect(try stats.store.load() == coordinator.dictationStats)
    }

    /// A ledger already on disk is authority: relaunching must not fold the
    /// journal in a second time and double every total.
    @Test func anExistingLedgerIsNotBackfilledAgain() async throws {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        try history.store.save([
            RecentSession(text: "one two three", stages: SessionStageTimings(captureMs: 4_000))
        ])
        var seeded = DictationStatsLedger()
        seeded.record(words: 900, seconds: 400, day: "2024-01-02")
        try stats.store.save(seeded)

        let coordinator = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: stats.store
        )

        #expect(coordinator.dictationStats == seeded)
    }

    /// The apps-only seed exists for installs whose ledger predates per-app
    /// tallies: the totals in that file already counted these sessions, so only
    /// the app buckets may be folded.
    @Test func anExistingLedgerWithoutAppTalliesIsSeededFromHistoryOnce() async throws {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        try history.store.save([
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                text: "one two three",
                outcome: RecentSessionOutcomeMetadata(
                    disposition: .pasteAttempted,
                    targetSafety: .normalText,
                    targetBundleId: "com.apple.TextEdit",
                    targetAppName: "TextEdit"
                ),
                stages: SessionStageTimings(captureMs: 4_000)
            ),
            // Written before names were persisted: still attributable by bundle id.
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_086_400),
                text: "four five",
                outcome: RecentSessionOutcomeMetadata(
                    disposition: .copiedOnly,
                    reason: "target_terminal",
                    targetSafety: .terminal,
                    targetBundleId: "com.mitchellh.ghostty"
                ),
                stages: SessionStageTimings(captureMs: 2_000)
            ),
            // No target at all: counted in the totals already on disk, ranked nowhere.
            RecentSession(createdAt: Date(timeIntervalSince1970: 1_700_172_800), text: "six"),
        ])
        var seeded = DictationStatsLedger()
        seeded.record(words: 6, seconds: 6, day: "2024-01-02")
        try stats.store.save(seeded)

        let coordinator = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: stats.store
        )

        // Totals untouched: the file already counted these sessions.
        #expect(coordinator.dictationStats.totalSessions == seeded.totalSessions)
        #expect(coordinator.dictationStats.totalWords == seeded.totalWords)
        #expect(coordinator.dictationStats.days == seeded.days)
        #expect(coordinator.dictationStats.apps.count == 2)
        #expect(
            coordinator.dictationStats.apps["com.apple.TextEdit"]
                == DictationAppStat(
                    sessions: 1,
                    words: 3,
                    seconds: 4,
                    name: "TextEdit",
                    lastDay: DictationStatsLedger.dayKey(
                        for: Date(timeIntervalSince1970: 1_700_000_000),
                        calendar: coordinator.runtime.calendar()
                    )
                )
        )
        #expect(coordinator.dictationStats.apps["com.mitchellh.ghostty"]?.name == nil)
        #expect(coordinator.dictationStats.apps["com.mitchellh.ghostty"]?.words == 2)

        await coordinator.prepareForTermination()
        #expect(try stats.store.load() == coordinator.dictationStats)

        // Relaunch: apps is no longer empty, so nothing folds a second time.
        let relaunched = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: stats.store
        )
        #expect(relaunched.dictationStats == coordinator.dictationStats)
    }

    /// A quarantined ledger loads as zeroes and deliberately does not backfill
    /// totals. Seeding app buckets against those zeroes would rank destinations
    /// Home has no sessions to attribute.
    @Test func aQuarantinedLedgerIsNotSeededWithAppTallies() async throws {
        let history = temporarySessionStore()
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        try history.store.save([
            RecentSession(
                text: "one two three",
                outcome: RecentSessionOutcomeMetadata(
                    disposition: .pasteAttempted,
                    targetSafety: .normalText,
                    targetBundleId: "com.apple.TextEdit",
                    targetAppName: "TextEdit"
                ),
                stages: SessionStageTimings(captureMs: 4_000)
            )
        ])
        try FileManager.default.createDirectory(at: stats.directory, withIntermediateDirectories: true)
        try Data("{ this is not a ledger".utf8).write(to: stats.store.url)

        let coordinator = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: stats.store
        )

        #expect(coordinator.dictationStats == DictationStatsLedger())
        #expect(coordinator.dictationStats.apps.isEmpty)
    }

    /// An unreadable ledger is moved aside like the history file, not silently
    /// replaced with zeroes.
    @Test func anUnreadableLedgerIsQuarantinedAndReported() async throws {
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        try FileManager.default.createDirectory(at: stats.directory, withIntermediateDirectories: true)
        try Data("{ this is not a ledger".utf8).write(to: stats.store.url)

        let coordinator = makeCoordinator(dictationStatsStore: stats.store)

        #expect(coordinator.dictationStats == DictationStatsLedger())
        #expect(coordinator.errorMessage?.contains("could not be read") == true)
        #expect(!FileManager.default.fileExists(atPath: stats.store.url.path))
        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: stats.directory.path)
            .filter { $0.contains("dictation-activity.json.corrupt-") }
        #expect(quarantined.count == 1)
    }

    /// Clearing the stats removes the file rather than leaving a document full
    /// of zeroes behind for the next launch to read.
    @Test func clearingTheLedgerRemovesItsFile() async throws {
        let stats = temporaryStatsStore()
        defer { try? FileManager.default.removeItem(at: stats.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("one two three")),
            dictationStatsStore: stats.store
        )

        await driveUtterance(coordinator)
        #expect(FileManager.default.fileExists(atPath: stats.store.url.path))

        #expect(await coordinator.clearDictationStats())
        #expect(coordinator.dictationStats == DictationStatsLedger())
        #expect(!FileManager.default.fileExists(atPath: stats.store.url.path))
    }

    /// The retired per-app `dictation-stats.json` is still swept at launch, and
    /// the ledger this build keeps is a different file the sweep cannot reach.
    @Test func theRetiredStatsFileIsSweptWithoutTouchingTheLedger() async throws {
        let history = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        let retired = history.directory.appendingPathComponent("dictation-stats.json")
        try Data("{\"legacy\": true}".utf8).write(to: retired)
        let ledgerURL = history.directory.appendingPathComponent("dictation-activity.json")
        var seeded = DictationStatsLedger()
        seeded.record(words: 11, seconds: 6, day: "2025-02-03")
        try DictationStatsStore(url: ledgerURL).save(seeded)

        let coordinator = makeCoordinator(
            recentSessionStore: history.store,
            dictationStatsStore: DictationStatsStore(url: ledgerURL)
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))
        #expect(coordinator.dictationStats == seeded)
    }

    /// A save that cannot land is reported. `try?` made a full disk, a revoked
    /// permission and a successful write indistinguishable.
    @Test func aSettingsSaveFailureIsReported() async throws {
        // A path whose parent is a regular file: the directory create inside the
        // store's write helper cannot succeed, whatever the filesystem state.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-unwritable-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let coordinator = makeCoordinator(
            settingsStore: SettingsStore(url: blocker.appendingPathComponent("settings.json"))
        )

        coordinator.saveSettings()
        await waitUntil { coordinator.errorMessage != nil }

        #expect(coordinator.errorMessage == "Settings could not be saved.")
        // Persistence problems belong to the menu channel, never the glossary's.
        #expect(coordinator.glossaryNotice == nil)
    }

    /// A glossary refusal is a surface-local notice, not a dictation failure:
    /// it must reach the Glossary tab without lighting the menu's crimson
    /// ERROR headline.
    @Test func aGlossaryCollisionSetsTheNoticeAndLeavesTheMenuChannelAlone() {
        let coordinator = makeCoordinator(settingsStore: temporarySettingsStore())

        // "cube cuddle" already belongs to the bundled kubectl term.
        coordinator.commitTerm(termId: nil, canonical: "Ghostty", spokenForms: ["cube cuddle"])

        #expect(coordinator.glossaryNotice == "That spoken form already belongs to another term.")
        #expect(coordinator.errorMessage == nil)
    }

    // MARK: Acquisition failure reporting and inference

    /// The race this exists for. A refusal such as `insufficient_disk_space` fails in
    /// microseconds — before the first health probe can answer — so there is no "was
    /// acquiring" edge to infer from and `previous` is nil. Inference sees nothing and
    /// the app used to show a stale, false MODEL NEEDED sentence while every dictation
    /// was refused. The sidecar's own verdict is the only thing that can see this.
    @Test func acquisitionTransitionSurfacesAnErrorReportedOnTheFirstProbe() {
        let refused = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(
                code: .insufficientDiskSpace,
                detail: "needs 1342177280 bytes free for ggml-parakeet-tdt-0.6b-v3-f16.bin, volume has 402653184"
            )
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: nil, current: refused, transportError: nil
            )
                == .reported(
                    code: .insufficientDiskSpace,
                    detail:
                        "needs 1342177280 bytes free for ggml-parakeet-tdt-0.6b-v3-f16.bin, volume has 402653184"
                )
        )
    }

    /// A reported error outranks inference even where inference would have answered,
    /// and it carries the code — DOWNLOAD DAMAGED is not DOWNLOAD FAILED.
    @Test func aReportedErrorOutranksTheStoppedDownloadInference() {
        let downloading = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false, downloadFraction: 0.8
        )
        let stopped = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(
                code: .artifactMismatch, detail: "sha256 deadbeef, expected 833bffc9"
            )
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: downloading, current: stopped, transportError: nil
            ) == .reported(code: .artifactMismatch, detail: "sha256 deadbeef, expected 833bffc9")
        )
    }

    /// A retry in flight outranks the latch: it holds the *last* failure, and the
    /// attempt that is running has not failed. Otherwise the automatic re-acquisition
    /// would repaint DOWNLOAD FAILED over its own progress.
    @Test func anAcquisitionInFlightOutranksAStillLatchedError() {
        let retrying = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false, downloadFraction: 0.1,
            lastAcquisitionError: ASRAcquisitionFailure(code: .modelDownloadFailed, detail: "HTTP 429")
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: nil, current: retrying, transportError: nil
            ) == .cleared
        )
    }

    /// The sidecar clears its own latch on a successful load, so a health frame with a
    /// good cache and no reported error clears the app's copy too.
    @Test func aClearedLatchClearsThePublishedFailure() {
        let refused = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(code: .modelDownloadFailed, detail: "offline")
        )
        let recovered = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .ready,
            ready: true, modelLoaded: true, cacheOk: true
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: refused, current: recovered, transportError: nil
            ) == .cleared
        )
    }

    /// The two faults the transition rules must keep apart, with the reported field in
    /// play: a probe that never answered is `unreachable` and not a failed download, and
    /// a transport failure over a cached model is no fault at all.
    @Test func aReportedErrorNeverTurnsAnUnansweredProbeIntoADownloadFailure() {
        let cached = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .ready,
            ready: true, modelLoaded: true, cacheOk: true
        )
        let refused = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(code: .insufficientDiskSpace, detail: "no room")
        )

        // No current answer at all: the latch in `previous` is history, not this probe's
        // verdict, and the engine being absent is the fault to report.
        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: refused, current: nil, transportError: "sidecar exited"
            ) == .unreachable(detail: "sidecar exited")
        )
        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: cached, current: nil, transportError: "offline"
            ) == .none
        )
    }

    /// End to end through the probe: a sidecar that reports a refusal on the very first
    /// answer publishes a user-facing failure, and it is the disk-space sentence rather
    /// than "could not be downloaded" or a raw code. The byte budget stays a diagnostic.
    @Test func aRefusalReportedOnTheFirstProbeReachesTheAcquisitionFailure() async throws {
        let detail = "needs 1342177280 bytes free for ggml-parakeet-tdt-0.6b-v3-f16.bin, volume has 402653184"
        let asr = FakeASR(
            behavior: .text("never transcribed"),
            backendHealth: ASRBackendHealth(
                backendId: "parakeet", backendStatus: .modelMissing,
                ready: false, modelLoaded: false, cacheOk: false,
                lastAcquisitionError: ASRAcquisitionFailure(code: .insufficientDiskSpace, detail: detail)
            )
        )
        let coordinator = makeCoordinator(asr: asr, activeASRBackend: "parakeet")

        // The first probe of the process: nothing precedes it, which is exactly the state
        // the transition inference cannot read.
        #expect(coordinator.backendHealth == nil)
        coordinator.refreshBackendHealth(force: true)
        await waitUntil { coordinator.acquisitionFailure != nil }

        let failure = try #require(coordinator.acquisitionFailure)
        #expect(failure.title == "DISK FULL")
        #expect(
            failure.cause
                == "Voiceour needs more free space on this Mac before it can download the speech model.")
        #expect(failure.isRetryable == false)
        // Actionable sentence, machine numbers behind it.
        #expect(failure.detail == detail)
        #expect(!failure.cause.contains("1342177280"))
        // And the preflight refuses with that same sentence rather than demoting it to
        // "has not finished downloading yet".
        #expect(coordinator.modelReadinessRefusal?.title == "DISK FULL")
    }

    // MARK: Acquisition failure inference

    /// The wire carries no error string for a failed download; failure is the
    /// transition "was downloading/warming, now neither, cache still absent".
    @Test func acquisitionTransitionInfersFailureFromAStoppedDownload() {
        let downloading = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false, downloadFraction: 0.4
        )
        let stopped = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: downloading, current: stopped, transportError: nil
            ) == .downloadFailed(detail: nil)
        )
    }

    @Test func acquisitionTransitionClearsOnceTheCacheIsGood() {
        let downloading = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false, downloadFraction: 0.9
        )
        let cached = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .ready,
            ready: true, modelLoaded: true, cacheOk: true
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: downloading, current: cached, transportError: nil
            ) == .cleared
        )
    }

    /// A probe that never answered is a different fault from a failed download:
    /// nothing was downloading, the engine is simply not there.
    @Test func acquisitionTransitionTreatsTransportErrorWithoutACacheAsUnreachable() {
        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: nil, current: nil, transportError: "sidecar exited"
            ) == .unreachable(detail: "sidecar exited")
        )
    }

    /// An offline relaunch with a cached model is not an acquisition failure.
    @Test func acquisitionTransitionIgnoresTransportErrorWhenTheModelIsCached() {
        let cached = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .ready,
            ready: true, modelLoaded: true, cacheOk: true
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: cached, current: nil, transportError: "offline"
            ) == .none
        )
    }

    @Test func acquisitionTransitionStaysQuietAcrossIdleProbes() {
        let idle = ASRBackendHealth(
            backendId: "parakeet", backendStatus: .modelMissing,
            ready: false, modelLoaded: false, cacheOk: false
        )

        #expect(
            DictationCoordinator.acquisitionTransition(
                previous: idle, current: idle, transportError: nil
            ) == .none
        )
    }

    // MARK: Model-readiness preflight

    /// Tapping Fn while the artifact is still downloading must cost a tap, not an
    /// utterance: the session never reaches `.recording`, so nothing is spoken into a
    /// recorder whose decode is guaranteed to come back `model_not_installed`.
    @Test func aStartIsRefusedWhileTheModelIsStillDownloading() async {
        let recorder = FakeRecorder()
        let asr = FakeASR(
            behavior: .text("never transcribed"),
            backendHealth: ASRBackendHealth(
                backendId: "parakeet", backendStatus: .modelMissing,
                ready: false, modelLoaded: false, cacheOk: false, downloadFraction: 0.43
            )
        )
        let coordinator = makeCoordinator(recorder: recorder, asr: asr, activeASRBackend: "parakeet")
        coordinator.refreshBackendHealth(force: true)
        await waitUntil { coordinator.backendHealth != nil }

        coordinator.start()
        await waitUntil { coordinator.state == .idle }

        #expect(recorder.startCount == 0)
        // The percentage is what makes this a wait rather than a fault, and it is the
        // sentence every other surface already shows.
        #expect(coordinator.lastFailure?.cause == "The speech model is still downloading — 43% done.")
        #expect(coordinator.errorMessage == "The speech model is still downloading — 43% done.")
    }

    /// The other half of the contract. A cached artifact whose context is still being
    /// compiled is 2-3 s from ready and the decode already waits for it, so refusing on
    /// `warming` would break dictation for every cold launch.
    @Test func aStartProceedsWhileTheCachedModelIsMerelyWarming() async {
        let recorder = FakeRecorder()
        let asr = FakeASR(
            behavior: .text("transcribed"),
            backendHealth: ASRBackendHealth(
                backendId: "parakeet", backendStatus: .ready,
                ready: true, modelLoaded: false, cacheOk: true, warming: true
            )
        )
        let coordinator = makeCoordinator(recorder: recorder, asr: asr, activeASRBackend: "parakeet")
        coordinator.refreshBackendHealth(force: true)
        await waitUntil { coordinator.backendHealth != nil }

        coordinator.start()
        await waitUntil { coordinator.state == .recording }

        #expect(recorder.startCount == 1)
        #expect(coordinator.lastFailure == nil)
    }

    /// Health that has never resolved is not evidence of absence. Refusing on it would
    /// strand every dictation behind a probe that has not landed yet, and the sidecar
    /// remains the authority on its own readiness.
    @Test func anUnresolvedHealthProbeDoesNotRefuseAStart() async {
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("transcribed")),
            activeASRBackend: "parakeet"
        )

        #expect(coordinator.backendHealth == nil)
        coordinator.start()
        await waitUntil { coordinator.state == .recording }

        #expect(recorder.startCount == 1)
    }

    // MARK: Session cues

    @Test func theStartCuePlaysBeforeTheDeviceIsMuted() async {
        let log = AudioEventLog()
        let clock = VirtualClock()
        let coordinator = makeCoordinator(
            audioMuter: LoggingAudioMuter(log: log),
            sessionCues: LoggingCuePlayer(log: log),
            runtimeOverride: cueTimingRuntime(clock: clock, log: log)
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        await waitUntil { log.events.contains(.mute) }

        let events = log.events
        #expect(events.first == .cue(.listeningStarted))
        // The mute waited one whole cue length before touching the device, so the
        // 120 ms fade cannot duck the rise. Logged rather than read off
        // `clock.elapsed()`, which the 40 ms metering poll also advances.
        #expect(
            events.firstIndex(of: .slept(SessionCue.listeningStarted.totalNanoseconds))!
                < events.firstIndex(of: .mute)!
        )
        #expect(clock.elapsed() >= SessionCue.listeningStarted.totalSeconds)
    }

    /// The cued session's whole audio order, for each way it can end: rise, duck,
    /// restore, then the terminal cue. The muter lifts the hardware mute and only
    /// then ramps the volume back, so a cue played at the tap would swell in from
    /// zero, and the mute is not skipped just because a cue ran ahead of it. Each
    /// ending plays its own cue and never the other's: the falling cue promises a
    /// transcript, and a discarded utterance has none.
    @Test(arguments: [SessionCue.listeningEnded, .listeningCancelled])
    func theTerminalCuePlaysAfterTheRestoreRampAndNeverTheOtherEnding(_ terminal: SessionCue) async {
        let log = AudioEventLog()
        let clock = VirtualClock()
        let coordinator = makeCoordinator(
            audioMuter: LoggingAudioMuter(log: log),
            sessionCues: LoggingCuePlayer(log: log),
            runtimeOverride: clock.runtime
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        await waitUntil { log.events.contains(.mute) }
        if terminal == .listeningEnded {
            coordinator.stopAndProcess()
        } else {
            coordinator.cancel()
        }
        await waitUntil { log.events.contains(.cue(terminal)) }

        let events = log.events
        #expect(events.firstIndex(of: .cue(.listeningStarted))! < events.firstIndex(of: .mute)!)
        #expect(events.firstIndex(of: .mute)! < events.firstIndex(of: .restore)!)
        #expect(events.firstIndex(of: .restore)! < events.firstIndex(of: .cue(terminal))!)
        let otherEnding: SessionCue = terminal == .listeningEnded ? .listeningCancelled : .listeningEnded
        #expect(!events.contains(.cue(otherEnding)))
    }

    /// The accepted cost of giving the cue its own window: a session decided
    /// inside that window ducks nothing at all. Deliberate, not incidental — the
    /// alternative is fading the user's audio down for a capture that is already
    /// over, and this also proves the guard cannot mute for a dead session.
    @Test func aSessionDecidedInsideTheCueWindowNeverDucksTheAudio() async {
        let log = AudioEventLog()
        let clock = VirtualClock()
        let cueWindow = TestGate()
        let coordinator = makeCoordinator(
            audioMuter: LoggingAudioMuter(log: log),
            sessionCues: LoggingCuePlayer(log: log),
            runtimeOverride: cueTimingRuntime(clock: clock, log: log, holdingCueSleepOn: cueWindow)
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        await waitUntil { log.events.contains(.slept(SessionCue.listeningStarted.totalNanoseconds)) }
        coordinator.stopAndProcess()
        cueWindow.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        let events = log.events
        #expect(events.contains(.cue(.listeningStarted)))
        #expect(!events.contains(.mute))
        // Nothing was muted, so the end cue plays without waiting for a fade.
        #expect(events.contains(.cue(.listeningEnded)))
    }

    /// Escape is claimed only while a session is live, but `cancel()` is public and
    /// unguarded, and a cue for a cancel that cancelled nothing is a lie.
    @Test func cancellingAnIdleCoordinatorPlaysNothing() async {
        let log = AudioEventLog()
        let coordinator = makeCoordinator(sessionCues: LoggingCuePlayer(log: log))

        coordinator.cancel()
        await waitUntil { coordinator.state == .idle }
        await drain()

        #expect(log.events.isEmpty)
    }

    @Test func theSettingOffPlaysNothingAndDoesNotDeferTheMute() async {
        let log = AudioEventLog()
        var settings = VoiceCore.Settings()
        settings.sessionSoundsEnabled = false
        let clock = VirtualClock()
        let coordinator = makeCoordinator(
            audioMuter: LoggingAudioMuter(log: log),
            sessionCues: LoggingCuePlayer(log: log),
            settings: settings,
            runtimeOverride: cueTimingRuntime(clock: clock, log: log)
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        await waitUntil { log.events.contains(.mute) }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .idle }

        // No cue, and no cue-length wait in front of the mute either: with the
        // setting off the device fades out on the tap, as it did before cues.
        let events = log.events
        #expect(events.contains(.mute))
        #expect(!events.contains { if case .cue = $0 { true } else { false } })
        #expect(!events.contains(.slept(SessionCue.listeningStarted.totalNanoseconds)))
    }

    /// The clock every cue-timing test runs on: it advances virtually and records
    /// each sleep into the same ordered log as the cue and the muter, so "the mute
    /// waited a cue length" is an observed event rather than an inference from a
    /// wall clock the metering poll also moves.
    ///
    /// `holdingCueSleepOn` parks the cue-length wait — and only that wait, never
    /// the 40 ms metering poll — until the gate fires, which is how a test can
    /// stand inside the cue's window and end the session there.
    private func cueTimingRuntime(
        clock: VirtualClock,
        log: AudioEventLog,
        holdingCueSleepOn gate: TestGate? = nil
    ) -> DictationRuntime {
        let base = clock.runtime
        return DictationRuntime(
            now: base.now,
            makeUUID: base.makeUUID,
            sleep: { nanoseconds in
                log.append(.slept(nanoseconds))
                if let gate, nanoseconds == SessionCue.listeningStarted.totalNanoseconds {
                    await gate.wait()
                }
                try await base.sleep(nanoseconds)
            },
            calendar: base.calendar
        )
    }

    // MARK: First-run guidance

    /// The card's visibility rule, through the coordinator that publishes it.
    ///
    /// A genuinely fresh install owes guidance. An install with either durable
    /// record — the transcript journal or the lifetime ledger — has plainly
    /// dictated before and is owed none, which is what stops an existing install
    /// upgrading into this build from being handed onboarding it does not need.
    @Test
    func aFreshInstallIsOwedFirstRunGuidance() {
        let coordinator = makeCoordinator(settingsStore: scratchSettingsStore())
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.dictationStats.totalSessions == 0)
        #expect(coordinator.owesFirstRunGuidance)
    }

    @Test
    func anInstallWithJournalledSessionsIsOwedNoGuidance() throws {
        let session = temporarySessionStore()
        try session.store.save([
            RecentSession(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                text: "already dictated"
            )
        ])
        defer { try? FileManager.default.removeItem(at: session.directory) }

        // Settings still say nothing: this is exactly the upgrade case, where the
        // flag has never been written because this build has never run.
        let coordinator = makeCoordinator(
            settingsStore: scratchSettingsStore(),
            recentSessionStore: session.store
        )
        #expect(!coordinator.settings.hasCompletedFirstRun)
        #expect(!coordinator.recentSessions.isEmpty)
        #expect(!coordinator.owesFirstRunGuidance)
    }

    /// The ledger alone is enough. A reader whose transcripts were cleared but
    /// whose lifetime figures survive has still dictated before.
    @Test
    func anInstallWithOnlyLedgerSessionsIsOwedNoGuidance() throws {
        let stats = temporaryStatsStore()
        var ledger = DictationStatsLedger()
        ledger.record(words: 12, seconds: 6, day: "2025-06-15")
        try stats.store.save(ledger)
        defer { try? FileManager.default.removeItem(at: stats.directory) }

        let coordinator = makeCoordinator(
            settingsStore: scratchSettingsStore(),
            dictationStatsStore: stats.store
        )
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.dictationStats.totalSessions == 1)
        #expect(!coordinator.owesFirstRunGuidance)
    }

    /// Every delivery target retires the guidance, including the one that reaches
    /// neither durable record: a secure field creates no history row and folds no
    /// ledger, and a reader who dictated into a password field has still used the
    /// gesture the card exists to teach.
    @Test(arguments: [TargetSafetyClass.normalText, .secure])
    func aDeliveredDictationRetiresFirstRunGuidance(_ safety: TargetSafetyClass) async {
        let store = scratchSettingsStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("first dictation")),
            tracker: FakeTracker(safety: safety),
            settingsStore: store
        )
        #expect(coordinator.owesFirstRunGuidance)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(coordinator.settings.hasCompletedFirstRun)
        #expect(!coordinator.owesFirstRunGuidance)
        // The secure branch proves the retirement is not riding the journal: it
        // wrote no row, so the flag is the only thing that changed.
        #expect(coordinator.recentSessions.isEmpty == (safety == .secure))
    }

    /// A start that never produced a transcript completes no first run. Both
    /// halves matter: a refusal never reaches the pipeline at all, and a cancel
    /// reaches it and leaves through the cancellation path above the retirement.
    @Test
    func aRefusedStartLeavesFirstRunGuidanceOwed() async {
        let store = scratchSettingsStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(
            permissions: DeniedMicrophonePermissions(),
            activeASRBackend: "parakeet",
            settingsStore: store
        )
        coordinator.start()
        await waitUntil { coordinator.errorMessage != nil }

        #expect(!coordinator.settings.hasCompletedFirstRun)
        #expect(coordinator.owesFirstRunGuidance)
    }

    @Test
    func aCancelledDictationLeavesFirstRunGuidanceOwed() async {
        let store = scratchSettingsStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let gate = TestGate()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .gatedText(gate, "never delivered")),
            settingsStore: store
        )
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }
        coordinator.cancel()
        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(!coordinator.settings.hasCompletedFirstRun)
        #expect(coordinator.owesFirstRunGuidance)
    }

    /// Never the real `~/Library/Application Support/settings.json`: these tests
    /// drive `saveSettings()`, and the default store is the user's own file.
    private func scratchSettingsStore() -> SettingsStore {
        SettingsStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceour-first-run-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
    }

    /// The microphone choice reaches the recorder twice: the persisted selection
    /// at init, so the very first recording honors it, and every later Settings
    /// change, so no restart is needed. `selectMicrophone` also records both
    /// halves — the durable UID and the display name — in settings.
    @Test @MainActor func microphoneSelectionIsPushedToTheRecorderAtInitAndOnChange() {
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            settings: VoiceCore.Settings(
                preferredMicrophoneUID: "usb-yeti",
                preferredMicrophoneName: "Yeti Stereo Microphone"
            ),
            settingsStore: scratchSettingsStore()
        )
        #expect(recorder.pinnedDeviceUIDs == ["usb-yeti"])

        coordinator.selectMicrophone(uid: "built-in", name: "MacBook Pro Microphone")
        #expect(coordinator.settings.preferredMicrophoneUID == "built-in")
        #expect(coordinator.settings.preferredMicrophoneName == "MacBook Pro Microphone")
        #expect(recorder.pinnedDeviceUIDs == ["usb-yeti", "built-in"])

        coordinator.selectMicrophone(uid: nil, name: nil)
        #expect(coordinator.settings.preferredMicrophoneUID == nil)
        #expect(recorder.pinnedDeviceUIDs == ["usb-yeti", "built-in", nil])
    }

    // MARK: Helpers

    private func processTranscript(
        _ rawTranscript: String,
        glossary: [ProtectedTerm]
    ) async throws -> (text: String, insertedText: String?, session: RecentSession) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-repair-pipeline-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = VoiceCore.Settings()
        settings.glossary = glossary
        settings.hasCompletedFirstRun = true
        let inserter = CapturingInserter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text(rawTranscript)),
            inserter: inserter,
            settings: settings,
            settingsStore: temporarySettingsStore(),
            recentSessionStore: RecentSessionStore(
                url: directory.appendingPathComponent("recent-sessions.json")
            )
        )

        await driveUtterance(coordinator)
        let session = try #require(coordinator.recentSessions.first)
        return (coordinator.lastTranscript, inserter.insertedText, session)
    }

    private func makeCoordinator(
        recorder: AudioRecording = FakeRecorder(),
        asr: ASRClienting = FakeASR(behavior: .text("unused")),
        tracker: TargetTracking = FakeTracker(),
        inserter: TextInserting = FakeInserter(outcome: .pasteAttempted),
        permissions: PermissionsChecking = FakePermissions(),
        activeASRBackend: String = "fake",
        audioMuter: SystemAudioMuting = NoOpSystemAudioMuter(),
        sessionCues: SessionCuePlaying = NoOpSessionCuePlayer(),
        settings: VoiceCore.Settings = VoiceCore.Settings(),
        settingsStore: SettingsStore? = nil,
        hotkey: HotkeyBinding = FakeHotkey(),
        recentSessionStore: RecentSessionStore? = nil,
        dictationStatsStore: DictationStatsStore? = nil,
        recentSessionSnapshotSave: @escaping @Sendable (RecentSessionStore, [RecentSession]) throws -> Void = {
            store, sessions in
            try store.save(sessions)
        },
        temporaryAudioRemover: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        },
        runtimeOverride: DictationRuntime? = nil
    ) -> DictationCoordinator {
        DictationCoordinator(
            recorder: recorder,
            asr: asr,
            tracker: tracker,
            inserter: inserter,
            permissions: permissions,
            hotkey: hotkey,
            settings: settings,
            activeASRBackend: activeASRBackend,
            settingsStore: settingsStore ?? SettingsStore(),
            recentSessionStore: recentSessionStore
                ?? RecentSessionStore(
                    url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("voiceour-coordinator-tests-\(UUID().uuidString)")
                        .appendingPathComponent("recent-sessions.json")
                ),
            // Never the real `~/Library/Application Support` ledger: a test that
            // seeds history takes the coordinator's one-time backfill path, and
            // that path writes.
            dictationStatsStore: dictationStatsStore
                ?? DictationStatsStore(
                    url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("voiceour-coordinator-tests-\(UUID().uuidString)")
                        .appendingPathComponent("dictation-activity.json")
                ),
            recentSessionSnapshotSave: recentSessionSnapshotSave,
            audioMuter: audioMuter,
            sessionCues: sessionCues,
            temporaryAudioRemover: temporaryAudioRemover,
            runtimeOverride: runtimeOverride
        )
    }

    private func temporarySessionStore(limit: Int = 500) -> (
        directory: URL,
        store: RecentSessionStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-session-writer-tests-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"), limit: limit)
        )
    }

    private func temporaryStatsStore() -> (directory: URL, store: DictationStatsStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-stats-tests-\(UUID().uuidString)", isDirectory: true)
        return (directory, DictationStatsStore(url: directory.appendingPathComponent("dictation-activity.json")))
    }

    private func makeVocabularyCoordinator(
        glossary: [ProtectedTerm],
        asrText: String = ""
    ) -> DictationCoordinator {
        var settings = VoiceCore.Settings()
        settings.glossary = glossary
        return makeCoordinator(
            asr: FakeASR(behavior: .text(asrText)),
            settings: settings,
            settingsStore: temporarySettingsStore()
        )
    }

    /// `SettingsStore()` defaults to the real Application Support path, so any
    /// test that reaches `saveSettings()` would rewrite the developer's own
    /// glossary. Every vocabulary test takes its own throwaway file.
    private func temporarySettingsStore() -> SettingsStore {
        SettingsStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceour-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
    }

    private func driveUtterance(_ coordinator: DictationCoordinator) async {
        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { !coordinator.isProcessingInFlight }
    }

    private func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Fixed settle so a released stale task gets a chance to (wrongly) mutate
    /// state before we assert it did not.
    private func drain() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Yields the MainActor until `condition` holds or the deadline passes, so
/// dispatched `Task { @MainActor }` continuations get to run between checks.
///
/// The ceiling is deliberately far larger than any wait this suite legitimately
/// needs. It is a hang detector, not a performance assertion: every caller is
/// waiting for something a fake will definitely deliver, so a slower or busier
/// machine should take longer, never fail. At 3 s a fully loaded parallel run
/// tripped it on correct code.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(30),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    if !condition() {
        Issue.record("Timed out after \(timeout) waiting for condition")
    }
}

// MARK: - Fakes

private struct DeniedMicrophonePermissions: PermissionsChecking {
    func microphone() -> PermissionState { .denied }
    func synthPaste() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
}

/// A recorder that reports a steady non-zero input level and a live capture, so
/// the metering loop has something to publish.
private final class MeteringRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let level: Float
    private let directory: URL
    private var producedURL: URL?

    init(level: Float) {
        self.level = level
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-metering-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() throws {}

    func stop() async throws -> RecordedAudio {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2, 3]))
        lock.withLock { producedURL = url }
        return RecordedAudio(
            url: url,
            meta: ASRAudioMeta(
                path: url.path,
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 100,
                byteCount: 4
            )
        )
    }

    func discardRecording() async {
        if let url = lock.withLock({ producedURL }) { try? FileManager.default.removeItem(at: url) }
    }

    func currentInputLevel() -> Float? { level }
    func captureIsLive() -> Bool { true }
}

/// A microphone that streams for as long as you like and never delivers a
/// non-zero sample: `captureIsLive()` stays false, and `stop()` refuses the
/// recording the way ``MicrophoneRecorder`` does for a capture that heard
/// nothing.
private final class SilentRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let reason: String
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    init(reason: String) {
        self.reason = reason
    }

    func start() throws {}

    func stop() async throws -> RecordedAudio {
        lock.withLock { stops += 1 }
        throw RecorderError.captureFailed(reason)
    }

    func discardRecording() async {}

    func currentInputLevel() -> Float? { 0 }
    func captureIsLive() -> Bool { false }
}

/// Time that only the metering loop advances: every `sleep` moves the clock by
/// exactly the interval asked for and returns immediately, so a six-second
/// deadline is proven in milliseconds and never depends on the host's speed.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    func elapsed() -> TimeInterval {
        lock.withLock { current.timeIntervalSince(start) }
    }

    var runtime: DictationRuntime {
        DictationRuntime(
            now: { [self] in lock.withLock { current } },
            makeUUID: { UUID() },
            sleep: { [self] nanoseconds in
                lock.withLock { current.addTimeInterval(TimeInterval(nanoseconds) / 1_000_000_000) }
                // A closure with no suspension point never yields, and the
                // metering loop would then starve the main actor it polls on.
                await Task.yield()
            }
        )
    }
}

private final class CountingAudioMuter: SystemAudioMuting, @unchecked Sendable {
    private let lock = NSLock()
    private var mutes = 0
    private var restores = 0

    var muteCount: Int { lock.withLock { mutes } }
    var restoreCount: Int { lock.withLock { restores } }

    func mute() async -> Bool {
        lock.withLock { mutes += 1 }
        return true
    }

    func restore() async {
        lock.withLock { restores += 1 }
    }
}

/// One ordered log shared by the cue player and the muter, because the property
/// under test is the *order* of a sound against a 120 ms device fade.
private enum AudioEvent: Equatable {
    case cue(SessionCue)
    case mute
    case restore
    /// A sleep the coordinator asked the runtime for, so the mute's cue-length
    /// wait is ordered against the sound instead of inferred from a wall clock.
    case slept(UInt64)
}

private final class AudioEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AudioEvent] = []

    var events: [AudioEvent] { lock.withLock { entries } }

    func append(_ event: AudioEvent) {
        lock.withLock { entries.append(event) }
    }
}

private final class LoggingCuePlayer: SessionCuePlaying, @unchecked Sendable {
    private let log: AudioEventLog

    init(log: AudioEventLog) {
        self.log = log
    }

    func play(_ cue: SessionCue) async {
        log.append(.cue(cue))
    }
}

private final class LoggingAudioMuter: SystemAudioMuting, @unchecked Sendable {
    private let log: AudioEventLog

    init(log: AudioEventLog) {
        self.log = log
    }

    func mute() async -> Bool {
        log.append(.mute)
        return true
    }

    func restore() async {
        log.append(.restore)
    }
}

/// A muter standing in for an output device with no writable mute or volume.
private final class RefusingAudioMuter: SystemAudioMuting, @unchecked Sendable {
    func mute() async -> Bool { false }
    func restore() async {}
}

/// A muter whose `mute` blocks until a gate fires, so a test can occupy the window
/// where the device is muted but `isSystemAudioMuted` has not been published yet.
/// `isMuted` tracks the device, which is the invariant that actually matters: the
/// user's audio must not stay muted after the app exits.
private final class GatedAudioMuter: SystemAudioMuting, @unchecked Sendable {
    private let lock = NSLock()
    private let muteGate: TestGate
    /// When set, `restore()` blocks on it, which is what makes "the stop path did
    /// not wait for the volume fade" an observable property rather than a comment.
    private let restoreGate: TestGate?
    private var mutes = 0
    private var restores = 0
    private var restoresEntered = 0
    private var muted = false

    init(muteGate: TestGate, restoreGate: TestGate? = nil) {
        self.muteGate = muteGate
        self.restoreGate = restoreGate
    }

    var muteCount: Int { lock.withLock { mutes } }
    var restoreCount: Int { lock.withLock { restores } }
    var restoreEnteredCount: Int { lock.withLock { restoresEntered } }
    var isMuted: Bool { lock.withLock { muted } }

    func mute() async -> Bool {
        // The device is muted first, then the caller is released -- exactly the
        // ordering that makes the publication window observable.
        lock.withLock {
            mutes += 1
            muted = true
        }
        await muteGate.wait()
        return true
    }

    func restore() async {
        lock.withLock { restoresEntered += 1 }
        await restoreGate?.wait()
        lock.withLock {
            restores += 1
            muted = false
        }
    }
}

private final class FixtureRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let sourceURL: URL
    private let directory: URL
    private var recordedURL: URL?

    init(sourceURL: URL, directory: URL) {
        self.sourceURL = sourceURL
        self.directory = directory
    }

    var producedURL: URL? {
        lock.withLock { recordedURL }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func stop() async throws -> RecordedAudio {
        let destination = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        lock.withLock { recordedURL = destination }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return RecordedAudio(
            url: destination,
            meta: ASRAudioMeta(
                path: destination.path,
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 3_242,
                byteCount: byteCount
            )
        )
    }

    func discardRecording() async {
        if let producedURL {
            try? FileManager.default.removeItem(at: producedURL)
        }
    }

    func currentInputLevel() -> Float? { nil }
    func captureIsLive() -> Bool { true }
}

private final class TransientFailingAudioRemover: @unchecked Sendable {
    enum RemovalError: Error {
        case injected
    }

    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func remove(_ url: URL) throws {
        let shouldFail = lock.withLock {
            calls += 1
            return calls == 1
        }
        if shouldFail {
            throw RemovalError.injected
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class MutableTracker: TargetTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var currentSnapshot: TargetSnapshot

    init(snapshot: TargetSnapshot) {
        currentSnapshot = snapshot
    }

    func setSnapshot(_ snapshot: TargetSnapshot) {
        lock.withLock {
            currentSnapshot = snapshot
        }
    }

    func snapshot() -> TargetSnapshot {
        lock.withLock { currentSnapshot }
    }

    func stillMatches(_ snap: TargetSnapshot) -> Bool {
        lock.withLock { currentSnapshot == snap }
    }
}

private final class CapturingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var target: TargetSnapshot?
    private var inserted: String?
    private var count = 0

    var insertedTarget: TargetSnapshot? {
        lock.withLock { target }
    }

    var insertedText: String? {
        lock.withLock { inserted }
    }

    var insertionCount: Int {
        lock.withLock { count }
    }

    func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
        lock.withLock {
            self.target = target
            inserted = text
            count += 1
        }
        return .pasteAttempted
    }
}

private final class GatedInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private let returned: TestGate
    private var sideEffects = 0

    init(returned: TestGate) {
        self.returned = returned
    }

    var sideEffectCount: Int {
        lock.withLock { sideEffects }
    }

    func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
        lock.withLock { sideEffects += 1 }
        await returned.wait()
        return .pasteAttempted
    }
}

private final class SessionSnapshotWriterSpy: @unchecked Sendable {
    enum SaveError: Error {
        case injected
    }

    private let lock = NSLock()
    private let blockingCalls: Set<Int>
    private let failingCalls: Set<Int>
    private var gates: [Int: DispatchSemaphore] = [:]
    private var savedSnapshots: [[RecentSession]] = []

    init(blockingCalls: Set<Int> = [], failingCalls: Set<Int> = []) {
        self.blockingCalls = blockingCalls
        self.failingCalls = failingCalls
        for call in blockingCalls {
            gates[call] = DispatchSemaphore(value: 0)
        }
    }

    var snapshotCount: Int {
        lock.withLock { savedSnapshots.count }
    }

    var snapshots: [[RecentSession]] {
        lock.withLock { savedSnapshots }
    }

    func release(call: Int) {
        lock.withLock { gates[call] }?.signal()
    }

    func save(store: RecentSessionStore, sessions: [RecentSession]) throws {
        let call = lock.withLock { () -> Int in
            savedSnapshots.append(sessions)
            return savedSnapshots.count
        }

        if blockingCalls.contains(call) {
            lock.withLock { gates[call] }?.wait()
        }
        if failingCalls.contains(call) {
            throw SaveError.injected
        }
        try store.save(sessions)
    }
}
