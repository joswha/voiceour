// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation
    import VoiceCore
    import VoiceMac

    /// A fixture builder plus the asynchronous boundaries its script may release.
    struct UIFlowFixture {
        let name: String
        let armedGates: Set<UIGate>
        private let build: @MainActor () -> UIFlowContext

        private init(
            name: String,
            armedGates: Set<UIGate>,
            build: @escaping @MainActor () -> UIFlowContext
        ) {
            self.name = name
            self.armedGates = armedGates
            self.build = build
        }

        @MainActor
        func makeContext() -> UIFlowContext {
            // Flow and scene fixtures share one pinning path so the same pane cannot
            // resolve a different clock, locale, permission snapshot, or glass path.
            UIFixtures.pinProcessSeams()
            return build()
        }

        /// - Parameters:
        ///   - refinementEnabled: also decides whether `.refinement` is armed. A disabled
        ///     refiner never reaches that gate, and arming a gate the pipeline never crosses
        ///     is dead configuration that reads like coverage.
        ///   - reaches: narrows the armed set for a journey that stops early. A cancel flow
        ///     crosses `.permission` and nothing else; arming the rest would leave four gates
        ///     that no script can release, which is indistinguishable from a script that
        ///     forgot to release them.
        static func dictation(
            transcript: String,
            refined: String,
            outcome: InsertionOutcome,
            targetBundleID: String,
            targetSafety: TargetSafetyClass,
            refinementEnabled: Bool = true,
            reaches: Set<UIGate>? = nil
        ) -> UIFlowFixture {
            var wholePath: Set<UIGate> = [.permission, .recorderStop, .transcription, .insertion]
            if refinementEnabled { wholePath.insert(.refinement) }
            let gates = reaches ?? wholePath
            return UIFlowFixture(name: "dictation", armedGates: gates) {
                makeDictationContext(
                    armedGates: gates,
                    transcription: .success(scriptedASRResult(transcript: transcript)),
                    refinement: .refined(refined),
                    insertion: outcome,
                    targetBundleID: targetBundleID,
                    targetSafety: targetSafety,
                    refinementEnabled: refinementEnabled
                )
            }
        }

        static func dictationError(code: ASRErrorCode) -> UIFlowFixture {
            let gates: Set<UIGate> = [.permission, .recorderStop, .transcription]
            return UIFlowFixture(name: "dictation-error-\(code.rawValue)", armedGates: gates) {
                makeDictationContext(
                    armedGates: gates,
                    transcription: .failure(scriptedASRError(code: code)),
                    refinement: .skipped(reason: "transcription failed"),
                    insertion: .failed(reason: "transcription failed"),
                    targetBundleID: "com.apple.TextEdit",
                    targetSafety: .normalText,
                    refinementEnabled: false
                )
            }
        }

        static func `static`(
            _ kind: UIFixtures.Kind,
            armedGates: Set<UIGate> = []
        ) -> UIFlowFixture {
            UIFlowFixture(name: "static", armedGates: armedGates) {
                UIFlowContext(coordinator: UIFixtures.coordinator(kind), armedGates: armedGates)
            }
        }

        /// Backend health starts unavailable and the scripted ASR answers `ready` only after
        /// both automatic probes have seeded and preserved that unavailable state. The first
        /// failure is consumed by `UIFixtures.make`'s settled bootstrap probe; the System
        /// pane's automatic on-appear probe consumes the second; explicit RE-CHECK recovers.
        ///
        /// This is the one fixture with a stepped clock. The six-second step carries each
        /// later call past the coordinator's five-second de-duplication TTL, so neither the
        /// pane's probe nor the explicit RE-CHECK is swallowed by the bootstrap result.
        static func backendRecovery() -> UIFlowFixture {
            UIFlowFixture(name: "backend-recovery", armedGates: []) {
                let coordinator = UIFixtures.make(
                    sessions: UIFixtures.history,
                    settings: UIFixtures.settings(backend: "ui-flow"),
                    backend: "ui-flow",
                    asrOverride: UIRecoveringASR(),
                    clockStep: UIScriptClock.backendProbeStep
                )
                return UIFlowContext(coordinator: coordinator, armedGates: [])
            }
        }

        /// Refinement switched off over an OMP configuration that is otherwise
        /// complete, so the script can turn it on and press CHECK.
        ///
        /// The verdict parks on `.refinement`; see `modelCatalog()` below for why
        /// that gate. Without it the probe answers inside the press and CHECKING is
        /// a state no checkpoint can ever see.
        static func refinerCheck() -> UIFlowFixture {
            UIFlowFixture(name: "refiner-check", armedGates: [.refinement]) {
                let probeLink = UIAdapterLink(gate: .refinement)
                var settings = UIFixtures.settings()
                settings.refinerEnabled = false
                settings.refinerProvider = .omp
                settings.refinerModel = UIFixtures.selectedModel
                let coordinator = UIFixtures.make(
                    sessions: UIFixtures.history,
                    settings: settings,
                    ompModelsProbe: { _, _, _, _ in
                        await probeLink.arrive()
                        return .ok(models: 3)
                    }
                )
                let context = UIFlowContext(coordinator: coordinator, armedGates: [.refinement])
                probeLink.bind(to: context)
                return context
            }
        }

        /// An OMP configuration whose model is still the provider default and whose
        /// catalog has not been asked for yet, so the pane's own entry task loads it
        /// and the script drives the rest: filter, then pick.
        ///
        /// This is the one fixture that passes `ompModelCatalogState: nil`. Every
        /// other one installs a value so `RefinementPane`'s `.task(id: provider)`
        /// skips the load entirely; here the load IS the subject, so the override
        /// stays absent and the injected loader parks on `.refinement` instead. The
        /// gate vocabulary is closed and names the boundaries of one dictation, but
        /// this is the same subsystem's asynchronous boundary and the flow never
        /// dictates, so there is nothing for it to collide with. Holding it is also
        /// the only way `.loading` is a checkpoint rather than a state the run loop
        /// skips past between two pumps.
        static func modelCatalog() -> UIFlowFixture {
            UIFlowFixture(name: "model-catalog", armedGates: [.refinement]) {
                let catalogLink = UIAdapterLink(gate: .refinement)
                // Read on the main actor and captured by value: the load closure runs
                // off it, and `UIFixtures` is main-actor isolated.
                let catalog = UIFixtures.ompModels
                var settings = UIFixtures.settings()
                settings.refinerEnabled = true
                settings.refinerProvider = .omp
                settings.refinerModel = ""
                let coordinator = UIFixtures.make(
                    sessions: UIFixtures.history,
                    settings: settings,
                    ompModelCatalogState: nil,
                    ompModelCatalogLoad: { _, _, _ in
                        await catalogLink.arrive()
                        return catalog
                    }
                )
                let context = UIFlowContext(coordinator: coordinator, armedGates: [.refinement])
                catalogLink.bind(to: context)
                return context
            }
        }

        private static func scriptedASRResult(transcript: String) -> ASRResult {
            ASRResult(
                requestId: "ui-flow",
                backendId: "ui-flow",
                modelId: "ui-flow-fixture",
                modelRevision: "pinned",
                transcript: ASRTranscript(text: transcript, language: "en", segments: nil),
                timingsMs: ASRTimings(load: 0, inference: 0, total: 0)
            )
        }

        private static func scriptedASRError(code: ASRErrorCode) -> ASRErrorMessage {
            ASRErrorMessage(
                requestId: "ui-flow",
                code: code,
                category: "scripted",
                retryable: false,
                userMessageKey: code.rawValue,
                detail: "Scripted \(code.rawValue) transcription failure."
            )
        }

        @MainActor
        private static func makeDictationContext(
            armedGates: Set<UIGate>,
            transcription: Result<ASRResult, ASRErrorMessage>,
            refinement: RefineOutcome,
            insertion: InsertionOutcome,
            targetBundleID: String,
            targetSafety: TargetSafetyClass,
            refinementEnabled: Bool
        ) -> UIFlowContext {
            let permissionLink = UIAdapterLink(gate: .permission)
            let recorderLink = UIAdapterLink(gate: .recorderStop)
            let transcriptionLink = UIAdapterLink(gate: .transcription)
            let refinementLink = UIAdapterLink(gate: .refinement)
            let insertionLink = UIAdapterLink(gate: .insertion)
            let scratch = UIFixtures.nextScratchDirectory()
            let clock = UIScriptClock(now: UIFixtures.pinnedNow)
            var settings = UIFixtures.settings(backend: "ui-flow", glossary: [])
            settings.refinerEnabled = refinementEnabled
            settings.refinerProvider = .appleOnDevice
            RenderOverrides.permissions = HarnessPermissions(state: .granted)

            let coordinator = DictationCoordinator(
                recorder: UIGatedRecorder(
                    link: recorderLink,
                    audioURL: scratch.appendingPathComponent("capture.wav")
                ),
                asr: UIGatedASR(link: transcriptionLink, result: transcription),
                tracker: HarnessTracker(bundleID: targetBundleID, safety: targetSafety),
                inserter: UIGatedInserter(link: insertionLink, outcome: insertion),
                permissions: UIGatedPermissions(link: permissionLink),
                hotkey: HarnessHotkey(),
                refiner: UIGatedRefiner(link: refinementLink, outcome: refinement),
                settings: settings,
                activeASRBackend: "ui-flow",
                settingsStore: SettingsStore(url: scratch.appendingPathComponent("settings.json")),
                recentSessionStore: RecentSessionStore(
                    url: scratch.appendingPathComponent("recent-sessions.json")
                ),
                recentSessionSnapshotSave: { _, _ in },
                ompModelsProbe: { _, _, _, _ in .failed("ui flow fixture") },
                ompProviderStatusProbe: { _, _, _ in OmpProviderStatusSnapshot(connections: []) },
                ompModelCatalogLoad: { _, _, _ in [] },
                audioMuter: NoOpSystemAudioMuter(),
                runtimeOverride: clock.runtime
            )
            let context = UIFlowContext(coordinator: coordinator, armedGates: armedGates)
            for link in [permissionLink, recorderLink, transcriptionLink, refinementLink, insertionLink] {
                link.bind(to: context)
            }
            return context
        }
    }

    /// The indirection lets adapters be installed before their coordinator exists,
    /// then binds them to the context-owned gate boxes and effect recorder exactly once.
    @MainActor
    final class UIAdapterLink {
        private let gateName: UIGate
        private var gate: UIGateBox?
        private var effects: UIEffectRecorder?

        init(gate: UIGate) {
            gateName = gate
        }

        func bind(to context: UIFlowContext) {
            gate = context.box(gateName)
            effects = context.effects
        }

        func arrive() async {
            await gate?.arrive()
        }

        func recordTranscriptionRequest() {
            effects?.recordTranscriptionRequest()
        }

        func record(refinerPrompt: String) {
            effects?.record(refinerPrompt: refinerPrompt)
        }

        func record(delivery: UIEffectRecorder.Delivery) {
            effects?.record(delivery: delivery)
        }
    }

    /// Bootstrap and on-appear health probes fail to preserve the unavailable row; every
    /// explicit RE-CHECK afterward returns the same ready snapshot.
    private actor UIRecoveringASR: ASRClienting {
        private var healthRequests = 0

        func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            ASRResult(
                requestId: "ui-flow",
                backendId: "ui-flow",
                modelId: "ui-flow-fixture",
                modelRevision: "pinned",
                transcript: ASRTranscript(text: "UI flow transcript.", language: "en", segments: nil),
                timingsMs: ASRTimings(load: 0, inference: 0, total: 0)
            )
        }

        func health(timeoutMs: Int) async throws -> ASRBackendHealth {
            healthRequests += 1
            guard healthRequests > 2 else {
                throw ASRErrorMessage(
                    requestId: "ui-flow-health",
                    code: .backendUnavailable,
                    category: "backend",
                    retryable: true,
                    userMessageKey: "backend_unavailable",
                    detail: "Scripted backend unavailable."
                )
            }
            return ASRBackendHealth(
                backendId: "ui-flow",
                backendStatus: .ready,
                ready: true,
                modelLoaded: true,
                cacheOk: true
            )
        }

        func warmUp() async {}
        nonisolated func lastTranscriptionPath() -> String? { "ui-flow" }
    }

    struct UIGatedPermissions: PermissionsChecking {
        let link: UIAdapterLink

        func microphone() -> PermissionState { .notDetermined }

        func requestMicrophone() async -> Bool {
            await link.arrive()
            return true
        }

        func synthPaste() -> PermissionState { .granted }
        func requestSynthPaste() async -> Bool { true }
        func accessibility() -> PermissionState { .granted }
    }

    struct UIGatedRecorder: AudioRecording {
        let link: UIAdapterLink
        let audioURL: URL

        func start() throws {}

        func stop() async throws -> RecordedAudio {
            await link.arrive()
            return RecordedAudio(
                url: audioURL,
                meta: ASRAudioMeta(
                    path: audioURL.path,
                    format: "wav",
                    sampleRateHz: 16_000,
                    channels: 1,
                    durationMs: 4_200,
                    byteCount: 134_444
                )
            )
        }

        func currentInputLevel() -> Float? { 0.42 }
        func lastStartLatencyMs() -> Int? { 18 }
        func captureIsLive() -> Bool { true }
        func discardRecording() async {}
    }

    struct UIGatedASR: ASRClienting {
        let link: UIAdapterLink
        let result: Result<ASRResult, ASRErrorMessage>

        func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            await link.arrive()
            await link.recordTranscriptionRequest()
            return try result.get()
        }

        func health(timeoutMs: Int) async throws -> ASRBackendHealth {
            ASRBackendHealth(
                backendId: "ui-flow",
                backendStatus: .ready,
                ready: true,
                modelLoaded: true,
                cacheOk: true
            )
        }

        func warmUp() async {}
        func lastTranscriptionPath() -> String? { "ui-flow" }
    }

    struct UIGatedRefiner: TranscriptRefining {
        let link: UIAdapterLink
        let outcome: RefineOutcome

        func refine(
            _ raw: String,
            glossary: [ProtectedTerm],
            safety: TargetSafetyClass,
            style: RefinementStyle
        ) async -> RefineOutcome {
            await link.arrive()
            await link.record(refinerPrompt: raw)
            return outcome
        }

        func warmUp() async {}
    }

    struct UIGatedInserter: TextInserting {
        let link: UIAdapterLink
        let outcome: InsertionOutcome

        func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
            await link.arrive()
            await link.record(
                delivery: UIEffectRecorder.Delivery(
                    text: text,
                    bundleID: target.bundleId ?? "",
                    disposition: UIEffectRecorder.disposition(of: outcome)
                )
            )
            return outcome
        }
    }

    /// Per-fixture identity and time.
    ///
    /// `makeUUID` is a stable sequence in call order, so a completed dictation writes a
    /// recent session whose id is the same on every run instead of a fresh random one.
    ///
    /// `now` is PINNED by default -- `step` zero -- because almost everything a fixture feeds
    /// the UI is either a date the view formats or a duration the view prints, and both have
    /// to be identical on every machine.
    ///
    /// A non-zero `step` is the deliberate exception, and only one fixture asks for it.
    /// `DictationCoordinator.refreshBackendHealth` de-duplicates probes inside a five-second
    /// TTL measured against `runtime.now()`, so under a frozen clock the System pane's
    /// automatic on-appear probe swallows every later RE-CHECK and a recovery journey cannot
    /// be scripted at all. The first attempt at this bought the behaviour with a
    /// `#if UI_HARNESS` early-return inside that shipping method, which is the worse trade: a
    /// production method whose control flow only makes sense to a test rots the moment
    /// someone edits it. Stepping one fixture's clock leaves production untouched and stays
    /// reproducible, because the Nth read of `now` is the same instant on every run.
    ///
    /// Keep the step just past the TTL rather than absurdly large. Any duration the UI prints
    /// is the difference between two adjacent reads, so the step IS the rendered latency; six
    /// seconds reads as a slow probe, an hour reads as corruption.
    ///
    /// `sleep` deliberately forwards to the real `Task.sleep`. Collapsing it to
    /// `Task.yield()` converts `RecordingSessionDriver`'s 40 ms metering loop into a hot loop
    /// that hops to the main actor without ever suspending; that starved layout in every
    /// scene rendered after `console.home.recording` and moved a committed golden by 59 pt.
    /// Sleeping is not a determinism problem -- no artifact records elapsed time.
    final class UIScriptClock: @unchecked Sendable {
        static let backendProbeStep: TimeInterval = 6

        private let origin: Date
        private let step: TimeInterval
        private let lock = NSLock()
        private var uuidCounter = 0
        private var nowCounter = 0

        init(now: Date, step: TimeInterval = 0) {
            origin = now
            self.step = step
        }

        var runtime: DictationRuntime {
            DictationRuntime(
                now: { [self] in nextNow() },
                makeUUID: { [self] in nextUUID() },
                sleep: { try await Task.sleep(nanoseconds: $0) }
            )
        }

        private func nextNow() -> Date {
            guard step != 0 else { return origin }
            lock.lock()
            let index = nowCounter
            nowCounter += 1
            lock.unlock()
            return origin.addingTimeInterval(Double(index) * step)
        }

        private func nextUUID() -> UUID {
            lock.lock()
            uuidCounter += 1
            let index = uuidCounter
            lock.unlock()
            let value = "00000000-0000-0000-0000-\(String(format: "%012d", index))"
            return UUID(uuidString: value)!
        }
    }

#endif
