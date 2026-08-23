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

    @Test func staleTranscriptionResultDoesNotChangeStateAfterNewerSessionStarted() async {
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

        coordinator.start()
        #expect(recorder.startCount == 1)
        #expect(coordinator.state == .idle)

        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }
        #expect(coordinator.lastTranscript == "")
        #expect(coordinator.lastOutcome == nil)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        #expect(recorder.startCount == 2)
        #expect(coordinator.lastTranscript == "")
        #expect(coordinator.lastOutcome == nil)
    }

    @Test func cancelledSessionLateResultDoesNotResurrectState() async {
        let gate = TestGate()
        let asr = FakeASR(behavior: .gatedText(gate, "late transcript"))
        let coordinator = makeCoordinator(asr: asr)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }

        coordinator.cancel()
        await waitUntil { coordinator.state == .idle }

        gate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(coordinator.state == .idle)
        #expect(coordinator.lastOutcome == nil)
        #expect(coordinator.lastTranscript == "")
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

    @Test func firstSessionCheckpointPublishesImmediatelyAndPrecedesInsertion() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1])
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
        await waitUntil { writer.snapshotCount == 1 }

        #expect(coordinator.recentSessions.map(\.text) == ["checkpointed transcript"])
        #expect(inserter.insertionCount == 0)
        writer.release(call: 1)
        await waitUntil { writer.snapshotCount == 2 }
        await waitUntil { coordinator.lastOutcome != nil }

        #expect(inserter.insertionCount == 1)
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

    @Test func outcomeIsVisibleWhileSecondCheckpointIsPending() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [2])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("outcome checkpoint")),
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 2 }

        #expect(coordinator.lastOutcome == .pasteAttempted)
        #expect(coordinator.recentSessions.first?.outcome?.disposition == .pasteAttempted)
        #expect(coordinator.recentSessions.first?.stages?.insertMs != nil)
        #expect(coordinator.state == .readyToInsert)
        writer.release(call: 2)
        await waitUntil { coordinator.state != .readyToInsert }

        let reloaded = try? fixture.store.load()
        #expect(reloaded?.first?.outcome == coordinator.recentSessions.first?.outcome)
        #expect(reloaded?.first?.stages?.insertMs == coordinator.recentSessions.first?.stages?.insertMs)
    }

    @Test func deleteQueuedBehindPendingCheckpointCannotResurrectSession() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1, 2])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("history to delete")),
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }
        let id = coordinator.recentSessions[0].id
        var deletionCompleted = false
        let deletion = Task { @MainActor in
            let durable = await coordinator.deleteRecentSession(id: id)
            deletionCompleted = true
            return durable
        }

        await waitUntil { coordinator.recentSessions.isEmpty }
        #expect(!deletionCompleted)
        writer.release(call: 1)
        await waitUntil { writer.snapshotCount == 2 }
        #expect(!deletionCompleted)
        writer.release(call: 2)
        #expect(await deletion.value)
        #expect(deletionCompleted)
        await coordinator.prepareForTermination()

        #expect((try? fixture.store.load()) == [])
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    }

    @Test func clearQueuedBehindPendingCheckpointCannotResurrectHistory() async {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = SessionSnapshotWriterSpy(blockingCalls: [1, 2])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("history to clear")),
            recentSessionStore: fixture.store,
            recentSessionSnapshotSave: { try writer.save(store: $0, sessions: $1) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { writer.snapshotCount == 1 }
        var clearCompleted = false
        let clear = Task { @MainActor in
            let durable = await coordinator.clearRecentSessions()
            clearCompleted = true
            return durable
        }

        await waitUntil { coordinator.recentSessions.isEmpty }
        #expect(!clearCompleted)
        writer.release(call: 1)
        await waitUntil { writer.snapshotCount == 2 }
        #expect(!clearCompleted)
        writer.release(call: 2)
        #expect(await clear.value)
        #expect(clearCompleted)
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

    @Test func escapeCancelsALiveSessionAndIsArmedOnlyWhileOneRuns() async {
        let hotkey = FakeHotkey()
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("discarded by escape")),
            hotkey: hotkey
        )

        #expect(!hotkey.isCancelArmed)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        #expect(hotkey.isCancelArmed)

        hotkey.triggerCancel()
        await waitUntil { coordinator.state == .idle }
        #expect(recorder.startCount == 1)
        #expect(coordinator.lastTranscript.isEmpty)
        #expect(!hotkey.isCancelArmed)
    }

    /// The armed flag lives in the binder, so a keypress that races a session
    /// ending can still arrive at an idle coordinator. It must not flash `.cancelled`.
    @Test func escapeFromIdleIsANoOp() async {
        let hotkey = FakeHotkey()
        let coordinator = makeCoordinator(hotkey: hotkey)

        hotkey.triggerCancel()
        await drain()

        #expect(coordinator.state == .idle)
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

    @Test func systemAudioIsMutedForTheRecordingAndRestoredExactlyOnceOnEveryExitPath() async {
        var settings = VoiceCore.Settings()
        settings.muteSystemAudioDuringCapture = true

        let onSuccess = CountingAudioMuter()
        let success = makeCoordinator(
            asr: FakeASR(behavior: .text("muted utterance")),
            audioMuter: onSuccess,
            settings: settings
        )
        success.start()
        await waitUntil { success.state == .recording }
        #expect(success.isSystemAudioMuted)
        success.stopAndProcess()
        await waitUntil { !success.isProcessingInFlight }
        #expect(onSuccess.muteCount == 1)
        #expect(onSuccess.restoreCount == 1)
        #expect(!success.isSystemAudioMuted)

        let onCancel = CountingAudioMuter()
        let cancelled = makeCoordinator(
            asr: FakeASR(behavior: .text("cancelled utterance")),
            audioMuter: onCancel,
            settings: settings
        )
        cancelled.start()
        await waitUntil { cancelled.state == .recording }
        cancelled.cancel()
        await waitUntil { !cancelled.isSystemAudioMuted }
        #expect(onCancel.muteCount == 1)
        #expect(onCancel.restoreCount == 1)

        // Cancelling AFTER stopAndProcess is the case a local flag cannot cover:
        // cancel() restores on its own task while the cancelled stop pipeline
        // restores in its catch. Two owners, one session, still exactly one restore.
        let onLateCancel = CountingAudioMuter()
        let transcriptionGate = TestGate()
        let lateCancelled = makeCoordinator(
            asr: FakeASR(behavior: .gatedText(transcriptionGate, "cancelled mid-transcription")),
            audioMuter: onLateCancel,
            settings: settings
        )
        lateCancelled.start()
        await waitUntil { lateCancelled.state == .recording }
        lateCancelled.stopAndProcess()
        await waitUntil { lateCancelled.state == .transcribing }
        lateCancelled.cancel()
        transcriptionGate.fire()
        await waitUntil { !lateCancelled.isProcessingInFlight }
        await drain()
        #expect(onLateCancel.muteCount == 1)
        #expect(onLateCancel.restoreCount == 1)
        #expect(!lateCancelled.isSystemAudioMuted)

        let onError = CountingAudioMuter()
        let asrError = ASRErrorMessage(
            requestId: "req",
            code: .internalError,
            category: "backend",
            retryable: false,
            userMessageKey: "asr_error",
            detail: "boom"
        )
        let failed = makeCoordinator(
            asr: FakeASR(behavior: .throwError(asrError)),
            audioMuter: onError,
            settings: settings
        )
        failed.start()
        await waitUntil { failed.state == .recording }
        failed.stopAndProcess()
        await waitUntil { !failed.isProcessingInFlight }
        #expect(onError.muteCount == 1)
        // Exactly one, on the error path too: the stop path restores as soon as
        // capture ends, and the catch blocks only restore when that point was
        // never reached. An ASR failure used to restore twice.
        #expect(onError.restoreCount == 1)
        #expect(!failed.isSystemAudioMuted)
    }

    /// The window that a `guard isSystemAudioMuted` dedupe got wrong: the device is
    /// already muted, but `beginRecording` publishes the flag only after awaiting
    /// the mute task. A quit landing here used to skip the restore entirely, and
    /// `applicationShouldTerminate` calls `Darwin.exit` the moment
    /// `prepareForTermination()` returns — so the user's audio stayed muted until
    /// the next launch recovered durable ownership.
    @Test func terminationDuringAnInFlightMuteStillRestoresSystemAudio() async {
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

        var terminationCompleted = false
        let termination = Task { @MainActor in
            await coordinator.prepareForTermination()
            terminationCompleted = true
        }
        await drain()
        #expect(!terminationCompleted, "termination must not return while the mute is in flight")

        muteGate.fire()
        await termination.value
        #expect(terminationCompleted)

        // The invariant that matters is the device, not the published flag.
        #expect(!muter.isMuted, "quitting must never leave the user's audio muted")
        #expect(muter.muteCount == 1)
        #expect(muter.restoreCount == 1)
        #expect(!coordinator.isSystemAudioMuted)
    }

    /// And when another path claimed the restore first, termination must await that
    /// same restore rather than observing "someone else is doing it" and returning
    /// into `Darwin.exit`.
    @Test func terminationWaitsForARestoreAnotherPathAlreadyClaimed() async {
        var settings = VoiceCore.Settings()
        settings.muteSystemAudioDuringCapture = true

        let muteGate = TestGate()
        let muter = GatedAudioMuter(muteGate: muteGate)
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("cancel then quit")),
            audioMuter: muter,
            settings: settings
        )

        coordinator.start()
        await waitUntil { muter.isMuted }

        // cancel() claims the restore and blocks behind the gated mute.
        coordinator.cancel()
        await drain()
        #expect(muter.restoreCount == 0, "the claimed restore is still behind the mute")

        var terminationCompleted = false
        let termination = Task { @MainActor in
            await coordinator.prepareForTermination()
            terminationCompleted = true
        }
        await drain()
        // The assertion the test is named for: without it, termination returning
        // early would still leave the audio restored by the time the gate fired,
        // and this would pass on scheduler timing alone.
        #expect(!terminationCompleted, "termination returned before the claimed restore ran")
        #expect(muter.restoreCount == 0)

        muteGate.fire()
        await termination.value

        #expect(terminationCompleted)
        #expect(!muter.isMuted)
        #expect(muter.muteCount == 1)
        #expect(muter.restoreCount == 1)
    }

    // MARK: Vocabulary teaching and clearing

    /// Teaching a mishearing onto a shipped term makes the alias the user's, not
    /// the term. Rewriting provenance here handed the whole bundled entry to
    /// `clearLearnedVocabulary`, which deleted a default the user only ever added
    /// a surface to.
    @Test func teachingASurfaceOntoABundledTermKeepsItBundled() throws {
        let coordinator = makeVocabularyCoordinator(glossary: Settings.defaultGlossary)

        #expect(!coordinator.hasLearnedVocabulary)
        coordinator.teachCorrection(canonical: "kubectl", misheard: "cube control", scope: .global)

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
        coordinator.teachCorrection(canonical: "kubectl", misheard: "cube control", scope: .global)

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

        coordinator.teachCorrection(canonical: "kubectl", misheard: "cube uh cuddle", scope: .global)
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

        await coordinator.prepareForTermination()
        let persisted = try stats.store.load()
        #expect(persisted == coordinator.dictationStats)
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
        coordinator.teachCorrection(canonical: "Ghostty", misheard: "cube cuddle", scope: .global)

        #expect(coordinator.glossaryNotice == "That spoken form already belongs to another term.")
        #expect(coordinator.errorMessage == nil)
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

    // MARK: Helpers

    private func makeCoordinator(
        recorder: AudioRecording = FakeRecorder(),
        asr: ASRClienting = FakeASR(behavior: .text("unused")),
        tracker: TargetTracking = FakeTracker(),
        inserter: TextInserting = FakeInserter(outcome: .pasteAttempted),
        permissions: PermissionsChecking = FakePermissions(),
        activeASRBackend: String = "fake",
        audioMuter: SystemAudioMuting = NoOpSystemAudioMuter(),
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
    private var count = 0

    var insertedTarget: TargetSnapshot? {
        lock.withLock { target }
    }

    var insertionCount: Int {
        lock.withLock { count }
    }

    func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
        lock.withLock {
            self.target = target
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
    private var activeCalls = 0
    private var maxActiveCalls = 0

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

    var maximumConcurrency: Int {
        lock.withLock { maxActiveCalls }
    }

    func release(call: Int) {
        lock.withLock { gates[call] }?.signal()
    }

    func save(store: RecentSessionStore, sessions: [RecentSession]) throws {
        let call = lock.withLock { () -> Int in
            activeCalls += 1
            maxActiveCalls = max(maxActiveCalls, activeCalls)
            savedSnapshots.append(sessions)
            return savedSnapshots.count
        }
        defer {
            lock.withLock { activeCalls -= 1 }
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
