import Dispatch
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac
@testable import VoiceOour

/// Covers DictationCoordinator behaviour through injected fakes: stale-generation
/// guards, temp-audio cleanup on every exit path, refiner prewarm, late-resolved
/// insertion targets, suggestion surfacing, hard-capped vocabulary snapshots,
/// gated MLX end-to-end telemetry, and recent-session persistence/termination
/// ordering. The coordinator is @MainActor and fully DI-injected; the ASR fake
/// can block on a gate so a test can inject a cancel/restart mid-transcription.
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

    @Test func recordingStopPrewarmsWithoutBlockingTranscription() async {
        let warmUpGate = TestGate()
        let transcriptionGate = TestGate()
        let refiner = BlockingWarmUpRefiner(gate: warmUpGate)
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .gatedText(transcriptionGate, "hello world")),
            refiner: refiner,
            settings: settings
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil {
            coordinator.state == .transcribing && refiner.warmUpCount > 0
        }

        #expect(coordinator.state == .transcribing)
        #expect(refiner.warmUpCount > 0)

        warmUpGate.fire()
        transcriptionGate.fire()
        await waitUntil { coordinator.lastOutcome != nil }
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

    @Test func disabledRefinerIsNotPrewarmed() async {
        let refiner = BlockingWarmUpRefiner(gate: TestGate())
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("hello world")),
            refiner: refiner
        )

        await driveUtterance(coordinator)

        #expect(refiner.warmUpCount == 0)
    }

    /// The backend-restart affordance in `VoicePane` and the guard in
    /// `VoiceOourAppDelegate.restartApplication()` are both `!state.isActive`.
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

    @Test func runtimeRefinerBindingTracksEnableProviderModelAndTimeout() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = false
        settings.refinerProvider = .omp
        settings.refinerModel = "model-a"
        settings.refinerTimeoutMs = 1_500
        let factory = RefinerFactorySpy()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Please send the draft, no wait, send the updated note.")),
            refinerFactory: { factory.make(settings: $0) },
            settings: settings
        )

        coordinator.settings.refinerEnabled = true
        await driveUtterance(coordinator)
        #expect(factory.settingsSnapshots.last?.refinerModel == "model-a")

        coordinator.settings.cleanupEnabled.toggle()
        await driveUtterance(coordinator)
        #expect(factory.refiners.first?.refinementCount == 2)

        coordinator.settings.refinerModel = "model-b"
        coordinator.settings.refinerTimeoutMs = 2_500
        await driveUtterance(coordinator)
        #expect(factory.settingsSnapshots.map(\.refinerModel) == ["model-a", "model-b"])
        #expect(factory.settingsSnapshots.last?.refinerTimeoutMs == 2_500)

        var onDevice = coordinator.settings
        onDevice.refinerProvider = .appleOnDevice
        coordinator.settings = onDevice
        await driveUtterance(coordinator)

        #expect(factory.settingsSnapshots.map(\.refinerProvider) == [.omp, .omp, .appleOnDevice])
        // The provider switch rebinds even though `refinerModel` never changed:
        // the identity carries the *resolved* model, and Apple has only one.
        // The stored OMP selector rides along untouched so switching back
        // restores it.
        #expect(factory.settingsSnapshots.last?.refinerModel == "model-b")
        #expect(factory.settingsSnapshots.last.map { RefinerResolved.model($0) } == "on-device")
        #expect(factory.refiners.map(\.refinementCount) == [2, 1, 1])
    }

    @Test func staleReachabilityResultDoesNotOverwriteNewerConfiguration() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = "old-model"
        let oldProbeGate = TestGate()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            ompModelsProbe: { _, _, model, _ in
                guard model == "old-model" else { return .ok(models: 7) }
                await oldProbeGate.wait()
                return .failed("stale failure")
            }
        )

        let staleCheck = Task { await coordinator.checkRefinerReachability() }
        await waitUntil { coordinator.refinerReachability == .checking }

        coordinator.settings.refinerModel = "current-model"
        let currentCommitted = await coordinator.checkRefinerReachability()
        #expect(currentCommitted)
        #expect(coordinator.refinerReachability == .ok(models: 7))

        oldProbeGate.fire()
        let staleCommitted = await staleCheck.value
        #expect(!staleCommitted)
        #expect(coordinator.refinerReachability == .ok(models: 7))
    }

    @Test func ompOnboardingTracksTerminalAndSelectsSubscriptionModel() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = "anthropic/claude-haiku-4-5"
        let startGate = TestGate()
        let finishGate = TestGate()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceoour-onboarding-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let session = OmpOnboardingSession(
            subscription: .chatGPT,
            directoryURL: scratch,
            scriptURL: scratch.appendingPathComponent("login.command"),
            resultURL: scratch.appendingPathComponent("result"),
            executableURL: URL(fileURLWithPath: "/tmp/fake-omp"),
            argumentPrefix: [],
            profileDirectory: nil
        )
        let models = [
            OmpAvailableModel(
                provider: "anthropic",
                selector: "anthropic/claude-haiku-4-5",
                name: "Claude Haiku 4.5"
            ),
            OmpAvailableModel(
                provider: "openai-codex",
                selector: "openai-codex/gpt-5.5",
                name: "GPT-5.5"
            ),
        ]
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            settingsStore: SettingsStore(url: scratch.appendingPathComponent("settings.json")),
            ompOnboardingStart: { subscription in
                #expect(subscription == .chatGPT)
                await startGate.wait()
                return session
            },
            ompOnboardingFinish: { received in
                #expect(received == session)
                await finishGate.wait()
                return .signedIn(models: models, catalogWarning: nil)
            }
        )

        let onboarding = Task { await coordinator.startOmpOnboarding(.chatGPT) }
        await waitUntil { coordinator.ompOnboardingState == .opening(.chatGPT) }
        startGate.fire()
        await waitUntil { coordinator.ompOnboardingState == .terminalOpen(.chatGPT) }
        finishGate.fire()

        #expect(await onboarding.value)
        #expect(coordinator.settings.refinerModel == "openai-codex/gpt-5.5")
        #expect(coordinator.refinerReachability == .ok(models: 2))
        #expect(
            coordinator.ompOnboardingState
                == .signedIn(
                    .chatGPT,
                    model: "openai-codex/gpt-5.5",
                    detail: "ChatGPT sign-in completed in Oh My Pi. Model set to openai-codex/gpt-5.5."
                ))
        #expect(coordinator.ompProviderStatusState == .loaded)
    }

    @Test func ompOnboardingLaunchFailureIsUserVisible() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            ompOnboardingStart: { _ in
                throw OmpOnboardingError.cannotOpenTerminal
            }
        )

        let started = await coordinator.startOmpOnboarding(.gemini)
        #expect(!started)
        #expect(
            coordinator.ompOnboardingState
                == .failed(
                    .gemini,
                    "Could not open the temporary Oh My Pi sign-in in Terminal."
                ))
        #expect(coordinator.refinerReachability == .unknown)
    }

    @Test func ompProviderStatusRefreshPublishesCheckingAndCounts() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let probeGate = TestGate()
        let snapshot = OmpProviderStatusSnapshot(connections: [
            OmpProviderConnection(
                providerID: "anthropic",
                displayName: "Anthropic",
                activeAccounts: 2,
                reportingAccounts: 1,
                disabledAccounts: 0
            )
        ])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            ompProviderStatusProbe: { _, _, timeoutMs in
                #expect(timeoutMs == 1_234)
                await probeGate.wait()
                return snapshot
            }
        )

        let refresh = Task { await coordinator.refreshOmpProviderStatuses(timeoutMs: 1_234) }
        await waitUntil { coordinator.ompProviderStatusState == .checking }
        probeGate.fire()

        #expect(await refresh.value)
        #expect(coordinator.ompProviderStatusState == .loaded)
        #expect(coordinator.ompProviderConnections == snapshot.connections)
    }

    /// The Model picker's options are OMP's, not a list this app maintains, so
    /// the coordinator has to publish whatever the load returned — in the one
    /// order the picker relies on, provider then selector.
    @Test func ompModelCatalogRefreshPublishesLoadingThenLoadedModels() async {
        let loadGate = TestGate()
        let loaded = [
            OmpAvailableModel(provider: "openai", selector: "openai/gpt-5.1-codex", name: "GPT-5.1 Codex"),
            OmpAvailableModel(provider: "anthropic", selector: "anthropic/claude-opus-4", name: "Claude Opus 4"),
            OmpAvailableModel(provider: "anthropic", selector: "anthropic/claude-haiku-4-5", name: "Claude Haiku 4.5"),
        ]
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            ompModelCatalogLoad: { _, _, timeoutMs in
                #expect(timeoutMs == 1_234)
                await loadGate.wait()
                return loaded
            }
        )

        #expect(coordinator.ompModelCatalogState == .idle)
        let refresh = Task { await coordinator.refreshOmpModelCatalog(timeoutMs: 1_234) }
        await waitUntil { coordinator.ompModelCatalogState == .loading }
        loadGate.fire()

        #expect(await refresh.value)
        #expect(coordinator.ompModelCatalogState == .loaded)
        #expect(
            coordinator.ompModels.map(\.selector) == [
                "anthropic/claude-haiku-4-5",
                "anthropic/claude-opus-4",
                "openai/gpt-5.1-codex",
            ])
    }

    /// A catalog that could not be read has to say so on the row. Silently
    /// leaving the picker empty reads as "OMP has no models", which sends the
    /// user looking for the wrong problem.
    @Test func ompModelCatalogRefreshPublishesTheFailureReason() async {
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            ompModelCatalogLoad: { _, _, _ in throw OmpModelCatalogTestError.unreadable }
        )

        #expect(!(await coordinator.refreshOmpModelCatalog()))
        #expect(coordinator.ompModelCatalogState == .failed(OmpModelCatalogTestError.unreadable.errorDescription!))
        #expect(coordinator.ompModels.isEmpty)
    }

    /// REFRESH is a button, so two loads can overlap. The one that started first
    /// may finish last, and its answer describes a catalog request the user has
    /// already replaced.
    @Test func supersededModelCatalogLoadDoesNotOverwriteTheNewerOne() async {
        let staleGate = TestGate()
        let staleModel = OmpAvailableModel(provider: "stale", selector: "stale/model", name: "Stale")
        let freshModel = OmpAvailableModel(provider: "fresh", selector: "fresh/model", name: "Fresh")
        let loadCount = LoadCounter()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            ompModelCatalogLoad: { _, _, _ in
                guard loadCount.next() == 1 else { return [freshModel] }
                await staleGate.wait()
                return [staleModel]
            }
        )

        let staleLoad = Task { await coordinator.refreshOmpModelCatalog() }
        await waitUntil { coordinator.ompModelCatalogState == .loading }

        #expect(await coordinator.refreshOmpModelCatalog())
        #expect(coordinator.ompModels == [freshModel])

        staleGate.fire()
        #expect(!(await staleLoad.value))
        #expect(coordinator.ompModels == [freshModel])
        #expect(coordinator.ompModelCatalogState == .loaded)
    }

    /// The picker writes the selector straight into settings, and its
    /// `Provider default` row writes an empty string rather than spelling the
    /// default out — so the stored file never pins a default that later moves.
    @Test func selectRefinerModelPersistsTheSelectorAndEmptyRestoresTheDefault() throws {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let store = temporarySettingsStore()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            settingsStore: store
        )

        coordinator.selectRefinerModel("openai/gpt-5.1-codex")
        #expect(coordinator.settings.refinerModel == "openai/gpt-5.1-codex")
        #expect(RefinerResolved.model(coordinator.settings) == "openai/gpt-5.1-codex")
        #expect(try store.load().refinerModel == "openai/gpt-5.1-codex")

        coordinator.selectRefinerModel("")
        #expect(coordinator.settings.refinerModel == "")
        #expect(RefinerResolved.model(coordinator.settings) == "anthropic/claude-haiku-4-5")
        #expect(try store.load().refinerModel == "")
    }

    @Test func inFlightBackendKeepsItsTraceAndCannotDemoteNewerConfiguration() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = "old-model"
        let refinementGate = TestGate()
        let oldRefiner = BlockingOutcomeRefiner(
            gate: refinementGate,
            outcome: .fellBack("ignored backend fallback", reason: "omp exited: status 3")
        )
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Please send the draft, no wait, send the updated note.")),
            refinerFactory: { _ in oldRefiner },
            settings: settings,
            ompModelsProbe: { _, _, _, _ in .ok(models: 3) }
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .refining && oldRefiner.refinementCount == 1 }

        coordinator.settings.refinerModel = "new-model"
        let currentReachabilityCommitted = await coordinator.checkRefinerReachability()
        #expect(currentReachabilityCommitted)
        #expect(coordinator.refinerReachability == .ok(models: 3))

        refinementGate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(coordinator.recentSessions.first?.refinement?.provider == "omp:old-model")
        #expect(coordinator.recentSessions.first?.refinement?.reason == "omp exited: status 3")
        #expect(coordinator.refinerReachability == .ok(models: 3))
    }

    /// A refine that proves OMP cannot run at all answers the question CHECK
    /// answers, so it replaces the cached green verdict rather than leaving the
    /// user to discover it by pressing a button.
    @Test func currentDurableOmpFailureDemotesReachability() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = "anthropic/claude-haiku-4-5"
        let refiner = CapturingRefiner(
            outcome: .fellBack("ignored backend fallback", reason: "launch failed: no such file")
        )
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Please send the draft, no wait, send the updated note.")),
            refiner: refiner,
            settings: settings,
            ompModelsProbe: { _, _, _, _ in .ok(models: 2) }
        )

        let reachabilityCommitted = await coordinator.checkRefinerReachability()
        #expect(reachabilityCommitted)
        #expect(coordinator.refinerReachability == .ok(models: 2))
        await driveUtterance(coordinator)

        #expect(coordinator.refinerReachability == .failed("launch failed: no such file"))
        #expect(coordinator.recentSessions.first?.refinement?.reason == "launch failed: no such file")
    }

    /// The mirror image, and the reason the promotion is prefix-matched rather
    /// than "any fallback". A timeout on a long utterance, a superseded request
    /// and a guard rejection all describe that utterance, not the refiner, and
    /// must leave a verdict the user actually measured alone.
    @Test(arguments: ["omp timed out", "superseded", "cancelled", "empty_output", "guard_rejected"])
    func transientRefineFailureLeavesTheMeasuredVerdictAlone(reason: String) async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = "anthropic/claude-haiku-4-5"
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Please send the draft, no wait, send the updated note.")),
            refiner: CapturingRefiner(outcome: .fellBack("ignored backend fallback", reason: reason)),
            settings: settings,
            ompModelsProbe: { _, _, _, _ in .ok(models: 2) }
        )

        #expect(await coordinator.checkRefinerReachability())
        await driveUtterance(coordinator)

        #expect(coordinator.refinerReachability == .ok(models: 2))
        #expect(coordinator.recentSessions.first?.refinement?.reason == reason)
    }

    /// The probe asks OMP about the model the next refine would actually use,
    /// which is the resolved one: an unset selector means the provider default,
    /// not "no model".
    @Test func ompReachabilityProbeAsksAboutTheResolvedModel() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.refinerModel = ""
        let capture = ProbeModelCapture()
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            settings: settings,
            ompModelsProbe: { _, _, model, _ in
                capture.record(model: model)
                return .ok(models: 4)
            }
        )

        #expect(await coordinator.checkRefinerReachability())

        coordinator.settings.refinerModel = "openai/gpt-5.1-codex"
        #expect(await coordinator.checkRefinerReachability())

        #expect(capture.models == ["anthropic/claude-haiku-4-5", "openai/gpt-5.1-codex"])
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

    @Test func tempAudioRemovedBeforeRefinementCompletes() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let recorder = FakeRecorder()
        let refinementGate = TestGate()
        let refiner = BlockingRefinementRefiner(gate: refinementGate)
        let coordinator = makeCoordinator(
            recorder: recorder,
            asr: FakeASR(behavior: .text("Please send the draft, no wait, send the updated note.")),
            refiner: refiner,
            settings: settings
        )
        defer { refinementGate.fire() }

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil {
            coordinator.state == .refining && refiner.refinementCount == 1
        }

        #expect(recorder.producedURL != nil)
        #expect(!fileExists(recorder.producedURL))

        refinementGate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }
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

    @Test func stopPathUsesOneHardCappedVocabularySnapshot() async {
        var terms = [
            ProtectedTerm(
                canonical: "NeuroDock",
                spokenAliases: ["neuro dock"],
                protected: true,
                termId: "retained-neurodock",
                source: .bundled
            )
        ]
        // Confirmed aliases on the first ten reserved terms push the derived
        // phrase list past 100, so the surviving cap is observable rather than
        // an accident of the snapshot already being 100 terms long.
        terms.append(
            contentsOf: (1..<150).map { index in
                ProtectedTerm(
                    canonical: "ReservedVocabularyTerm\(index)",
                    spokenAliases: [],
                    protected: true,
                    termId: "term-\(index)",
                    source: .bundled,
                    labeledAliases: index <= 10
                        ? [AliasLabel(surface: "reserved alias \(index)", confirmedAt: Date())]
                        : []
                )
            })
        var settings = VoiceCore.Settings()
        settings.glossary = terms
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.automaticTermCorrectionEnabled = true
        // The ASR bias list is only compiled when this is on, so without it the
        // cap this test is named for cannot be observed at all.
        settings.decoderBiasEnabled = true

        let raw = "Please use neuro dock, no wait, use neuro dock tomorrow."
        let expectedVocabulary = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            capturedBundleId: "com.apple.TextEdit",
            activeProjectId: nil
        )
        let expectedDeterministic = CleanupEngine.clean(raw, glossary: expectedVocabulary.terms)
        let asrResult = ASRResult(
            requestId: "vocabulary-snapshot",
            backendId: "fake",
            modelId: "fake",
            modelRevision: "dev",
            transcript: ASRTranscript(
                text: raw,
                language: "en",
                segments: nil,
                confidence: 0.99,
                confidenceMode: .greedyEntropy
            ),
            timingsMs: ASRTimings(load: 0, inference: 0, total: 0),
            hypotheses: [
                ASRHypothesis(rank: 0, text: expectedDeterministic, score: 1.0, rawScore: 1.0)
            ],
            decoder: ASRDecoderInfo(mode: "greedy", biasEnabled: false)
        )
        let refiner = CapturingRefiner(output: "Refined output without the protected term.")
        let asr = FakeASR(behavior: .custom(asrResult))
        let coordinator = makeCoordinator(asr: asr, refiner: refiner, settings: settings)

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.lastOutcome != nil }

        // Every surface the one snapshot could legitimately contribute to the
        // decoder-bias list: canonical plus the surfaces the user authored or
        // confirmed. A term's typed aliases bias the decoder for the same reason
        // its confirmed mishearings do, so both stores feed this through the one
        // `Glossary.userAliases` accessor the rest of the app reads.
        let snapshotSurfaces = Set(
            expectedVocabulary.terms.flatMap { term in
                [term.renderedCanonical] + Glossary.userAliases(for: term)
            }.map { $0.lowercased() }
        )
        let biasTexts = asr.receivedBiasPhrases.map(\.text)

        #expect(expectedVocabulary.terms.count == 100)
        #expect(snapshotSurfaces.count > 100, "the phrase list must exceed the cap for it to be observable")
        // One snapshot means one cap, and the ASR bias list and the refiner's
        // terms are both drawn from it rather than from two separate compiles.
        #expect(biasTexts.count == 100)
        #expect(Set(biasTexts.map { $0.lowercased() }).isSubset(of: snapshotSurfaces))
        #expect(refiner.termIDs == expectedVocabulary.terms.map(\.termId))
        #expect(refiner.raw == expectedDeterministic)
        #expect(coordinator.lastTranscript == expectedDeterministic)
        #expect(coordinator.recentSessions.first?.refinement?.kind == .fellBack)
        #expect(coordinator.recentSessions.first?.refinement?.reason == "guard_rejected")
    }

    @Test func compiledOutVocabularyDoesNotRouteCleanTranscriptToRefiner() async {
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.glossary = [
            ProtectedTerm(
                canonical: "NVIDIA Parakeet",
                spokenAliases: [],
                scope: .bundleID("com.apple.mail")
            )
        ]
        let refiner = CapturingRefiner(echoing: ())
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("Use Parakeet for this recording.")),
            refiner: refiner,
            settings: settings
        )

        await driveUtterance(coordinator)

        #expect(refiner.refinementCount == 0)
        #expect(coordinator.recentSessions.first?.refinement?.reason == "clean_transcript")
    }

    @Test func cloudInputExcludesLocalTermsWhileFullGuardStillProtectsThem() async {
        let localTerm = ProtectedTerm(
            canonical: "ACME-ULTRA-SECRET",
            spokenAliases: [],
            termId: "local-project-term",
            scope: .bundleID("com.apple.TextEdit"),
            cloudEligible: false,
            labeledAliases: [
                AliasLabel(surface: "project falcon", confirmedAt: Date(timeIntervalSince1970: 1))
            ]
        )
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.glossary = [localTerm]
        let refiner = GuardingCapturingRefiner(candidate: "Use the project today.")
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("um um use project falcon today")),
            refiner: refiner,
            settings: settings
        )

        await driveUtterance(coordinator)

        #expect(refiner.raw?.contains("project falcon") == true)
        #expect(refiner.raw?.contains("ACME-ULTRA-SECRET") == false)
        #expect(refiner.termIDs.contains(localTerm.termId))
        #expect(refiner.serializedPrompt?.contains("ACME-ULTRA-SECRET") == false)
        #expect(coordinator.recentSessions.first?.refinement?.reason == "guard_rejected")
        #expect(coordinator.lastTranscript.contains("ACME-ULTRA-SECRET"))
    }

    @Test func cloudAutomaticCorrectionReachesProviderBeforeFullTermLock() async {
        let cloudTerm = ProtectedTerm(
            canonical: "NeuroDock",
            spokenAliases: ["neuro dock"],
            termId: "cloud-neurodock",
            cloudEligible: true
        )
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        settings.automaticTermCorrectionEnabled = true
        settings.glossary = [cloudTerm]
        let raw = "Please use neuro doc, no wait, use neuro doc tomorrow."
        let result = ASRResult(
            requestId: "cloud-automatic-correction",
            backendId: "fake",
            modelId: "fake",
            modelRevision: "dev",
            transcript: ASRTranscript(
                text: raw,
                language: "en",
                segments: nil,
                confidence: 0.99,
                confidenceMode: .greedyEntropy
            ),
            timingsMs: ASRTimings(load: 0, inference: 0, total: 0),
            hypotheses: [
                ASRHypothesis(rank: 0, text: raw, score: 1.0, rawScore: 1.0)
            ],
            decoder: ASRDecoderInfo(mode: "greedy", biasEnabled: false)
        )
        let refiner = CapturingRefiner(echoing: ())
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .custom(result)),
            refiner: refiner,
            settings: settings
        )

        await driveUtterance(coordinator)

        #expect(refiner.raw?.contains("NeuroDock") == true)
        #expect(refiner.raw?.contains("neuro doc") == false)
        #expect(coordinator.lastTranscript.contains("NeuroDock"))
        #expect(coordinator.recentSessions.first?.refinement?.kind == .refined)
    }

    @Test func backendFallbackUsesCurrentFullVocabularyText() async {
        let currentTerm = ProtectedTerm(
            canonical: "NeuroDock",
            spokenAliases: ["neuro dock"],
            termId: "current-term"
        )
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let refiner = CapturingRefiner(
            outcome: .fellBack("launch-time stale text", reason: "timed_out")
        )
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("um um use neuro dock today")),
            refiner: refiner,
            settings: settings
        )
        coordinator.settings.glossary = [currentTerm]

        await driveUtterance(coordinator)

        let activeTerms = VocabularyCompiler.compile(
            persistent: [currentTerm],
            ephemeral: [],
            capturedBundleId: "com.apple.TextEdit",
            activeProjectId: nil
        ).terms
        let expected = CleanupEngine.clean("um um use neuro dock today", glossary: activeTerms)
        #expect(coordinator.lastTranscript == expected)
        #expect(coordinator.lastTranscript != "launch-time stale text")
        #expect(coordinator.recentSessions.first?.refinement?.kind == .fellBack)
    }

    @Test func refinementCapturesStyleAndSafetyFromTheRecordingTarget() async {
        let captureTarget = TargetSnapshot(
            bundleId: "com.apple.mail",
            pid: 10,
            safety: .normalText
        )
        let laterTarget = TargetSnapshot(
            bundleId: "com.hnc.Discord",
            pid: 11,
            safety: .unknownRisky
        )
        let transcriptionGate = TestGate()
        let tracker = MutableTracker(snapshot: captureTarget)
        let refiner = CapturingRefiner(echoing: ())
        var settings = VoiceCore.Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = .omp
        let coordinator = makeCoordinator(
            asr: FakeASR(
                behavior: .gatedText(
                    transcriptionGate,
                    "Please send the draft, no wait, send the updated note."
                )
            ),
            tracker: tracker,
            refiner: refiner,
            settings: settings
        )

        coordinator.start()
        await waitUntil { coordinator.state == .recording }
        coordinator.stopAndProcess()
        await waitUntil { coordinator.state == .transcribing }
        tracker.setSnapshot(laterTarget)
        transcriptionGate.fire()
        await waitUntil { !coordinator.isProcessingInFlight }

        #expect(refiner.safety == .normalText)
        #expect(refiner.style == .formal)
    }

    @Test func mlxSessionPersistsEndToEndTelemetry() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOOUR_MLX_INTEGRATION"] != nil else { return }

        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = FixtureRecorder(
            sourceURL: URL(fileURLWithPath: "fixtures/audio/hello_16k_mono.wav"),
            directory: fixture.directory
        )
        // Through the registry, so this measures the client the app actually
        // builds — including the model it pins the sidecar to.
        let asr = ASRBackendRegistry.builtIn.client(
            for: "mlx",
            context: ASRBackendContext(asrDirectory: URL(fileURLWithPath: "asr"), speechLocale: "en_US")
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
        #expect(stages.asrBackendId == "parakeet-mlx")
        #expect((stages.asrInferenceMs ?? 0) > 0)
        #expect((stages.asrTotalMs ?? 0) >= (stages.asrInferenceMs ?? 0))
        #expect(endToEndMs >= hostASRMs + insertMs)
        #expect(!fileExists(recorder.producedURL))
        print(
            "mlx coordinator telemetry: endToEnd=\(endToEndMs)ms "
                + "hostASR=\(hostASRMs)ms insert=\(insertMs)ms "
                + "backend=\(stages.asrBackendId ?? "nil") "
                + "load=\(stages.asrLoadMs ?? -1)ms "
                + "inference=\(stages.asrInferenceMs ?? -1)ms "
                + "total=\(stages.asrTotalMs ?? -1)ms"
        )
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
            asr: FakeASR(behavior: .text("unused")),
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
        let coordinator = makeCoordinator(asr: FakeASR(behavior: .text("unused")), hotkey: hotkey)

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
        #expect(coordinator.errorMessage == "Microphone permission denied.")
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
        let store = temporarySettingsStore()
        var settings = VoiceCore.Settings()
        settings.glossary = Settings.defaultGlossary
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("")),
            settings: settings,
            settingsStore: store
        )

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
        let store = temporarySettingsStore()
        var settings = VoiceCore.Settings()
        settings.glossary =
            Settings.defaultGlossary + [
                ProtectedTerm(canonical: "NeuroDock", spokenAliases: ["neuro dock"], source: .explicitCorrection),
                ProtectedTerm(canonical: "ProjectTerm", spokenAliases: [], source: .manualImport),
            ]
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("")),
            settings: settings,
            settingsStore: store
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

    /// A default the user deleted from the ledger stays deleted: the clear
    /// restores surfaces on rows that survive, it does not resurrect rows.
    @Test func clearingLearnedVocabularyDoesNotResurrectARemovedDefault() {
        let store = temporarySettingsStore()
        var settings = VoiceCore.Settings()
        settings.glossary = Settings.defaultGlossary.filter { $0.canonical != "CGEvent" }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("")),
            settings: settings,
            settingsStore: store
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
        let store = temporarySettingsStore()
        var settings = VoiceCore.Settings()
        let orphan = ProtectedTerm(
            canonical: "Claude",
            spokenAliases: ["Cloud"],
            termId: "Claude",
            source: .bundled
        )
        settings.glossary = Settings.defaultGlossary + [orphan]
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("")),
            settings: settings,
            settingsStore: store
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
        let store = temporarySettingsStore()
        var settings = VoiceCore.Settings()
        settings.glossary = []
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("please run cube uh cuddle on the pod")),
            settings: settings,
            settingsStore: store
        )

        coordinator.teachCorrection(canonical: "kubectl", misheard: "cube uh cuddle", scope: .global)
        await driveUtterance(coordinator)
        #expect(coordinator.lastTranscript == "please run kubectl on the pod")

        // What the ledger row shows is what the engines match on.
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

    // MARK: Lifetime statistics

    @Test func aCompletedDictationIsFoldedOnceAcrossBothJournalWrites() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("counted once not twice")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)

        // One dictation writes the journal twice — the append, then the outcome
        // amendment — and both fold. Counting by session id is what keeps that
        // from reading as two dictations, or the amendment from being skipped.
        let session = try #require(coordinator.recentSessions.first)
        #expect(coordinator.statsLedger.dictations == 1)
        #expect(coordinator.statsLedger.words == session.wordCount)
        #expect(coordinator.statsLedger.characters == session.text.count)
        #expect(coordinator.statsLedger.measuredDictations == 1)
        #expect(coordinator.statsLedger.spokenMs == 100)
        #expect(coordinator.statsLedger.apps == ["com.apple.TextEdit": 1])
        #expect(coordinator.statsLedger.attributedOutcomes == 1)
    }

    @Test func insightsCarryTheDestinationAppAsSoonAsTheOutcomeLands() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("attribute this to the front app")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)

        // No further mutation below: the destination app exists only on the
        // second journal write, so a digest invalidated by session ids alone
        // never saw it and TOP APPS sat one dictation behind forever.
        #expect(coordinator.insights.attributedOutcomeCount == 1)
        let destination = try #require(coordinator.insights.destinations.first)
        #expect(destination.bundleId == "com.apple.TextEdit")
        #expect(destination.count == 1)
        #expect(destination.share == 1)
        #expect(coordinator.insights.dictationCount == 1)
        #expect(coordinator.insights.measuredDictationCount == 1)
        #expect(coordinator.insights.spokenMs == 100)
    }

    @Test func lifetimeTotalsOutliveTheTranscriptsTheyWereCountedFrom() async throws {
        let fixture = temporarySessionStore(limit: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("one more than the corpus keeps")),
            recentSessionStore: fixture.store
        )

        for _ in 0..<3 {
            await driveUtterance(coordinator)
        }

        // The corpus is a ring, the tally is not. Reading lifetime figures off
        // the ring froze the dictation count at the cap and walked "since"
        // forward as the oldest transcripts were evicted.
        #expect(coordinator.recentSessions.count == 2)
        #expect(coordinator.statsLedger.dictations == 3)
        #expect(coordinator.statsLedger.apps["com.apple.TextEdit"] == 3)
        let kept = try #require(coordinator.recentSessions.first)
        #expect(coordinator.statsLedger.words == kept.wordCount * 3)
        let oldestKept = try #require(coordinator.recentSessions.last)
        let startedAt = try #require(coordinator.statsLedger.startedAt)
        #expect(startedAt < oldestKept.createdAt)
        #expect(coordinator.insights.dictationCount == 3)
        #expect(coordinator.insights.keptTranscriptCount == 2)
    }

    @Test func aFirstLaunchSeedsTheLedgerFromTheRetainedCorpusAndPersistsTheSeed() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let older = RecentSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "seed the tally from what is still on disk"
        )
        let newer = RecentSession(
            createdAt: Date(timeIntervalSince1970: 1_700_003_600),
            text: "and count this one too"
        )
        try fixture.store.save([older, newer])
        let statsURL = fixture.directory.appendingPathComponent(DictationStatsStore.fileName)
        #expect(!FileManager.default.fileExists(atPath: statsURL.path))

        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            recentSessionStore: fixture.store
        )

        // Derived from the injected transcript store, so a test can never leave
        // the tally pointed at the developer's own Application Support file.
        #expect(coordinator.statsStore.url.path == statsURL.path)
        #expect(coordinator.statsLedger.dictations == 2)
        #expect(coordinator.statsLedger.words == older.wordCount + newer.wordCount)
        #expect(coordinator.statsLedger.startedAt == older.createdAt)
        #expect(coordinator.insights.dictationCount == 2)

        let seedWrite = try #require(coordinator.recentSessionPersistenceTail)
        #expect(await seedWrite.value)
        #expect(FileManager.default.fileExists(atPath: statsURL.path))
        #expect(try DictationStatsStore(url: statsURL).load().dictations == 2)
    }

    @Test func aStatsFileOneDictationBehindReconcilesWithoutRecountingTheRest() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let counted = RecentSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "folded before the process died",
            outcome: RecentSessionOutcomeMetadata(disposition: .pasteAttempted, targetBundleId: "com.apple.Notes"),
            stages: SessionStageTimings(captureMs: 4_000)
        )
        let lost = RecentSession(
            createdAt: Date(timeIntervalSince1970: 1_700_003_600),
            text: "written after the tally was last saved",
            outcome: RecentSessionOutcomeMetadata(disposition: .pasteAttempted, targetBundleId: "com.apple.Terminal"),
            stages: SessionStageTimings(captureMs: 6_000)
        )
        try fixture.store.save([counted, lost])
        var behind = DictationStatsLedger()
        behind.ingest([counted], calendar: .current)
        try DictationStatsStore(besideRecentSessionsAt: fixture.store.url).save(behind)

        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            recentSessionStore: fixture.store
        )

        // The two durable files can disagree only across a crash between their
        // writes. Launch folds the difference and nothing else.
        #expect(coordinator.statsLedger.dictations == 2)
        #expect(coordinator.statsLedger.words == counted.wordCount + lost.wordCount)
        #expect(coordinator.statsLedger.spokenMs == 10_000)
        #expect(coordinator.statsLedger.attributedOutcomes == 2)
        #expect(coordinator.statsLedger.apps == ["com.apple.Notes": 1, "com.apple.Terminal": 1])
        #expect(coordinator.statsLedger.startedAt == counted.createdAt)
    }

    @Test func clearingHistoryClearsTheTallyOnDiskAsWell() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("erase the counts with the words")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)
        #expect(coordinator.statsLedger.dictations == 1)

        #expect(await coordinator.clearRecentSessions())

        // A lifetime word count, a per-app breakdown and a quoted personal best
        // are still a record of what the user just asked to erase.
        #expect(coordinator.statsLedger == DictationStatsLedger())
        #expect(coordinator.insights == .empty)
        // Neither durable file survives: an empty ledger removes its file
        // rather than leaving a husk of zeroes where the history was.
        let statsStore = DictationStatsStore(besideRecentSessionsAt: fixture.store.url)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        #expect(!FileManager.default.fileExists(atPath: statsStore.url.path))
        #expect(try statsStore.load() == DictationStatsLedger())
    }

    @Test func deletingOneTranscriptKeepsItsCountButDropsItsQuote() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("the record line comes from this transcript")),
            recentSessionStore: fixture.store
        )

        await driveUtterance(coordinator)
        let session = try #require(coordinator.recentSessions.first)
        #expect(coordinator.statsLedger.records.longestPreview == session.text)

        #expect(await coordinator.deleteRecentSession(id: session.id))

        // A dictation that happened still happened; only the text that quoted
        // the deleted transcript goes with it.
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.statsLedger.dictations == 1)
        #expect(coordinator.statsLedger.words == session.wordCount)
        #expect(coordinator.statsLedger.records.longestWords == session.wordCount)
        #expect(coordinator.statsLedger.records.longestPreview == nil)
        #expect(coordinator.insights.dictationCount == 1)
        #expect(coordinator.insights.keptTranscriptCount == 0)
        #expect(coordinator.insights.longestSessionPreview == nil)

        // Deleting the last transcript empties that file but not the tally,
        // which is the asymmetry "clear history" does not have.
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        let persisted = try DictationStatsStore(besideRecentSessionsAt: fixture.store.url).load()
        #expect(persisted.dictations == 1)
        #expect(persisted.records.longestPreview == nil)
    }

    @Test func aFailedStatsWriteDeniesDurabilityEvenAfterTheTranscriptsAreGone() async throws {
        let fixture = temporarySessionStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.store.save([RecentSession(text: "history to erase")])
        let coordinator = makeCoordinator(
            asr: FakeASR(behavior: .text("unused")),
            recentSessionStore: fixture.store,
            statsSnapshotSave: { _, _ in throw StatsWriteFailure.injected }
        )

        let isDurable = await coordinator.clearRecentSessions()

        // The transcript write succeeded; the acknowledgement is still false,
        // because "durable" has to mean both files took the change.
        #expect(!isDurable)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        #expect(coordinator.recentSessions.isEmpty)
        #expect(coordinator.statsLedger == DictationStatsLedger())
    }

    // MARK: Helpers

    private func makeCoordinator(
        recorder: AudioRecording = FakeRecorder(),
        asr: ASRClienting,
        tracker: TargetTracking = FakeTracker(),
        inserter: TextInserting = FakeInserter(outcome: .pasteAttempted),
        refiner: TranscriptRefining = FakeRefiner(),
        permissions: PermissionsChecking = FakePermissions(),
        activeASRBackend: String = "fake",
        audioMuter: SystemAudioMuting = NoOpSystemAudioMuter(),
        refinerFactory: DictationCoordinator.RefinerFactory? = nil,
        settings: VoiceCore.Settings = VoiceCore.Settings(),
        settingsStore: SettingsStore? = nil,
        hotkey: HotkeyBinding = FakeHotkey(),
        ompModelsProbe: @escaping DictationCoordinator.OmpModelsProbeFunction = {
            executableURL,
            argumentPrefix,
            model,
            timeoutMs in
            await OmpModelsProbe.check(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                model: model,
                timeoutMs: timeoutMs
            )
        },
        ompProviderStatusProbe: @escaping DictationCoordinator.OmpProviderStatusProbeFunction = {
            _,
            _,
            _ in
            OmpProviderStatusSnapshot(connections: [])
        },
        ompModelCatalogLoad: @escaping DictationCoordinator.OmpModelCatalogLoadFunction = { _, _, _ in
            // Never the real loader: it spawns `omp models --json`, which reads
            // the developer's own OMP profile and reaches the network.
            []
        },
        ompOnboardingStart: @escaping DictationCoordinator.OmpOnboardingStartFunction = { _ in
            throw CancellationError()
        },
        ompOnboardingFinish: @escaping DictationCoordinator.OmpOnboardingFinishFunction = { _ in
            .cancelled
        },
        recentSessionStore: RecentSessionStore? = nil,
        recentSessionSnapshotSave: @escaping @Sendable (RecentSessionStore, [RecentSession]) throws -> Void = {
            store, sessions in
            try store.save(sessions)
        },
        statsSnapshotSave: @escaping @Sendable (DictationStatsStore, DictationStatsLedger) throws -> Void = {
            store, ledger in
            try store.save(ledger)
        },
        temporaryAudioRemover: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) -> DictationCoordinator {
        DictationCoordinator(
            recorder: recorder,
            asr: asr,
            tracker: tracker,
            inserter: inserter,
            permissions: permissions,
            hotkey: hotkey,
            refiner: refiner,
            refinerFactory: refinerFactory,
            settings: settings,
            activeASRBackend: activeASRBackend,
            settingsStore: settingsStore ?? SettingsStore(),
            recentSessionStore: recentSessionStore
                ?? RecentSessionStore(
                    url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("voiceoour-coordinator-tests-\(UUID().uuidString)")
                        .appendingPathComponent("recent-sessions.json")
                ),
            recentSessionSnapshotSave: recentSessionSnapshotSave,
            statsSnapshotSave: statsSnapshotSave,
            ompModelsProbe: ompModelsProbe,
            ompProviderStatusProbe: ompProviderStatusProbe,
            ompModelCatalogLoad: ompModelCatalogLoad,
            ompOnboardingStart: ompOnboardingStart,
            ompOnboardingFinish: ompOnboardingFinish,
            audioMuter: audioMuter,
            temporaryAudioRemover: temporaryAudioRemover
        )
    }

    private func temporarySessionStore(limit: Int = 500) -> (
        directory: URL,
        store: RecentSessionStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceoour-session-writer-tests-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            RecentSessionStore(url: directory.appendingPathComponent("recent-sessions.json"), limit: limit)
        )
    }

    /// `SettingsStore()` defaults to the real Application Support path, so any
    /// test that reaches `saveSettings()` would rewrite the developer's own
    /// glossary. Every vocabulary test takes its own throwaway file.
    private func temporarySettingsStore() -> SettingsStore {
        SettingsStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceoour-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("voiceoour-metering-\(UUID().uuidString)", isDirectory: true)
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

private final class CapturingRefiner: TranscriptRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let outcomeProvider: @Sendable (String) -> RefineOutcome
    private var capturedRaw: String?
    private var capturedTermIDs: [String] = []
    private var capturedSafety: TargetSafetyClass?
    private var capturedStyle: RefinementStyle?
    private var refinements = 0

    init(output: String) {
        outcomeProvider = { _ in .refined(output) }
    }

    init(outcome: RefineOutcome) {
        outcomeProvider = { _ in outcome }
    }

    init(echoing: Void) {
        outcomeProvider = { .refined($0) }
    }

    var raw: String? {
        lock.withLock { capturedRaw }
    }

    var termIDs: [String] {
        lock.withLock { capturedTermIDs }
    }

    var safety: TargetSafetyClass? {
        lock.withLock { capturedSafety }
    }

    var style: RefinementStyle? {
        lock.withLock { capturedStyle }
    }

    var refinementCount: Int {
        lock.withLock { refinements }
    }

    func refine(
        _ raw: String,
        glossary: [ProtectedTerm],
        safety: TargetSafetyClass,
        style: RefinementStyle
    ) async -> RefineOutcome {
        lock.withLock {
            capturedRaw = raw
            capturedTermIDs = glossary.map(\.termId)
            capturedSafety = safety
            capturedStyle = style
            refinements += 1
        }
        return outcomeProvider(raw)
    }
}

private final class GuardingCapturingRefiner: TranscriptRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let candidate: String
    private var capturedRaw: String?
    private var capturedTermIDs: [String] = []
    private var capturedSerializedPrompt: String?

    init(candidate: String) {
        self.candidate = candidate
    }

    var raw: String? {
        lock.withLock { capturedRaw }
    }

    var termIDs: [String] {
        lock.withLock { capturedTermIDs }
    }

    var serializedPrompt: String? {
        lock.withLock { capturedSerializedPrompt }
    }

    func refine(
        _ raw: String,
        glossary: [ProtectedTerm],
        safety: TargetSafetyClass,
        style: RefinementStyle
    ) async -> RefineOutcome {
        let prompt = RefinerPolicy.llmUserMessage(
            raw: raw,
            glossary: RefinerPolicy.cloudEligible(glossary),
            style: style
        )
        lock.withLock {
            capturedRaw = raw
            capturedTermIDs = glossary.map(\.termId)
            capturedSerializedPrompt = prompt
        }
        return RefinerPolicy.guardedOutcome(
            original: raw,
            candidate: candidate,
            glossary: glossary,
            fallback: raw
        )
    }
}

private final class BlockingWarmUpRefiner: TranscriptRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: TestGate
    private var warmUps = 0

    init(gate: TestGate) {
        self.gate = gate
    }

    var warmUpCount: Int {
        lock.withLock { warmUps }
    }

    func warmUp() async {
        lock.withLock { warmUps += 1 }
        await gate.wait()
    }

    func refine(
        _ raw: String,
        glossary: [ProtectedTerm],
        safety: TargetSafetyClass,
        style: RefinementStyle
    ) async -> RefineOutcome {
        .skipped(reason: "test")
    }
}

private final class BlockingRefinementRefiner: TranscriptRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: TestGate
    private var refinements = 0

    init(gate: TestGate) {
        self.gate = gate
    }

    var refinementCount: Int {
        lock.withLock { refinements }
    }

    func refine(
        _ raw: String,
        glossary: [ProtectedTerm],
        safety: TargetSafetyClass,
        style: RefinementStyle
    ) async -> RefineOutcome {
        lock.withLock { refinements += 1 }
        await gate.wait()
        return .refined(raw)
    }
}

private final class BlockingOutcomeRefiner: TranscriptRefining, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: TestGate
    private let outcome: RefineOutcome
    private var refinements = 0

    init(gate: TestGate, outcome: RefineOutcome) {
        self.gate = gate
        self.outcome = outcome
    }

    var refinementCount: Int {
        lock.withLock { refinements }
    }

    func refine(
        _ raw: String,
        glossary: [ProtectedTerm],
        safety: TargetSafetyClass,
        style: RefinementStyle
    ) async -> RefineOutcome {
        lock.withLock { refinements += 1 }
        await gate.wait()
        return outcome
    }
}

private final class RefinerFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSettings: [VoiceCore.Settings] = []
    private var createdRefiners: [CapturingRefiner] = []

    var settingsSnapshots: [VoiceCore.Settings] {
        lock.withLock { capturedSettings }
    }

    var refiners: [CapturingRefiner] {
        lock.withLock { createdRefiners }
    }

    func make(settings: VoiceCore.Settings) -> TranscriptRefining {
        let refiner = CapturingRefiner(echoing: ())
        lock.withLock {
            capturedSettings.append(settings)
            createdRefiners.append(refiner)
        }
        return refiner
    }
}

private final class ProbeModelCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedModels: [String] = []

    var models: [String] {
        lock.withLock { capturedModels }
    }

    func record(model: String) {
        lock.withLock { capturedModels.append(model) }
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

/// Stands in for a stats file that cannot be written, so a test can prove the
/// durability acknowledgement is the conjunction of both journal writes.
private enum StatsWriteFailure: Error {
    case injected
}

/// The catalog load reports its reason through `LocalizedError`, so the double
/// has to as well or the published `.failed` string would be an opaque
/// `NSError` description rather than the sentence the row shows.
private enum OmpModelCatalogTestError: LocalizedError {
    case unreadable

    var errorDescription: String? { "omp models returned nothing readable" }
}

/// Counts calls so one injected loader can answer differently per invocation.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
