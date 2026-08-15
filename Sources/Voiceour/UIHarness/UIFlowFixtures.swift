// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/Voiceour/RenderOverrides.swift` and is never gated.
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
                // A registered picker id, not a fixture-shaped one: the readiness
                // row names whichever backend is running, so an unknown id would
                // put "UI-FLOW" in a committed sentence.
                let coordinator = UIFixtures.make(
                    sessions: UIFixtures.history,
                    settings: UIFixtures.settings(backend: "parakeet"),
                    backend: "parakeet",
                    asrOverride: UIRecoveringASR(),
                    clockStep: UIScriptClock.backendProbeStep
                )
                return UIFlowContext(coordinator: coordinator, armedGates: [])
            }
        }

        /// The Bluetooth warm-up window: `start()` returns at once, the state machine is
        /// in `.recording`, and the capture is still handing back digital silence.
        ///
        /// Measured on AirPods Max through one identical capture path: first buffer at
        /// 143 ms, first buffer holding a NON-ZERO sample at 1422 ms, 64 of the first 197
        /// buffers all-zero, against 99 ms and zero silent buffers on the built-in
        /// microphone. This fixture is that window with the wall clock taken out of it:
        /// the capture stays not-live until the script opens `.captureLive`.
        ///
        /// Only two gates are armed. The journey never stops the recorder, transcribes,
        /// refines or delivers, and arming a boundary no script can release is
        /// indistinguishable from a script that forgot to.
        static func captureWarmup() -> UIFlowFixture {
            let gates: Set<UIGate> = [.permission, .captureLive]
            return UIFlowFixture(name: "capture-warmup", armedGates: gates) {
                makeDictationContext(
                    armedGates: gates,
                    transcription: .success(scriptedASRResult(transcript: "The warm-up journey never transcribes.")),
                    refinement: .skipped(reason: "the warm-up journey never refines"),
                    insertion: .failed(reason: "the warm-up journey never delivers"),
                    targetBundleID: "com.apple.TextEdit",
                    targetSafety: .normalText,
                    refinementEnabled: false,
                    capture: UICaptureWarmup()
                )
            }
        }

        /// A live capture whose preview decode is parked on its own gate.
        ///
        /// The recorder offers a fixed sample count at the engine's first-snapshot threshold,
        /// so the 40 ms metering poll asks for exactly one preview however many times it ticks;
        /// the script decides when that preview lands.
        static func partialPreview() -> UIFlowFixture {
            let gates: Set<UIGate> = [.permission, .partialTranscription]
            return UIFlowFixture(name: "partial-preview", armedGates: gates) {
                makeDictationContext(
                    armedGates: gates,
                    transcription: .success(
                        scriptedASRResult(transcript: "The partial journey never finishes a transcript.")
                    ),
                    refinement: .skipped(reason: "the partial journey never refines"),
                    insertion: .failed(reason: "the partial journey never delivers"),
                    targetBundleID: "com.apple.TextEdit",
                    targetSafety: .normalText,
                    refinementEnabled: false,
                    partialSamples: 24_000,
                    partialTranscript: "Partial preview text"
                )
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
            refinementEnabled: Bool,
            capture: UICaptureWarmup? = nil,
            partialSamples: Int? = nil,
            partialTranscript: String? = nil
        ) -> UIFlowContext {
            let permissionLink = UIAdapterLink(gate: .permission)
            let partialLink = UIAdapterLink(gate: .partialTranscription)
            let recorderLink = UIAdapterLink(gate: .recorderStop)
            let transcriptionLink = UIAdapterLink(gate: .transcription)
            let refinementLink = UIAdapterLink(gate: .refinement)
            let insertionLink = UIAdapterLink(gate: .insertion)
            let scratch = UIFixtures.nextScratchDirectory()
            let clock = UIScriptClock(now: UIFixtures.pinnedNow, calendar: UIFixtures.pinnedCalendar)
            var settings = UIFixtures.settings(backend: "ui-flow", glossary: [])
            settings.refinerEnabled = refinementEnabled
            settings.refinerProvider = .appleOnDevice
            RenderOverrides.permissions = HarnessPermissions(state: .granted)

            let coordinator = DictationCoordinator(
                recorder: UIGatedRecorder(
                    link: recorderLink,
                    audioURL: scratch.appendingPathComponent("capture.wav"),
                    capture: capture,
                    partialSamples: partialSamples
                ),
                asr: UIGatedASR(
                    link: transcriptionLink,
                    result: transcription,
                    partialLink: partialTranscript == nil ? nil : partialLink,
                    partialResult: partialTranscript.map { scriptedASRResult(transcript: $0) }
                ),
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
                statsSnapshotSave: { _, _ in },
                ompModelsProbe: { _, _, _, _ in .failed("ui flow fixture") },
                ompProviderStatusProbe: { _, _, _ in OmpProviderStatusSnapshot(connections: []) },
                ompModelCatalogLoad: { _, _, _ in [] },
                audioMuter: NoOpSystemAudioMuter(),
                runtimeOverride: clock.runtime
            )
            let context = UIFlowContext(coordinator: coordinator, armedGates: armedGates)
            for link in [
                permissionLink, recorderLink, transcriptionLink, partialLink, refinementLink, insertionLink,
            ] {
                link.bind(to: context)
            }
            if let capture {
                // The capture's own boundary is synchronous, so nothing can park inside
                // `captureIsLive()`. This task parks instead, for the life of the fixture,
                // and hands the flag over the instant the script opens the gate. Teardown
                // drains it, so a flow that ends inside the warm-up window leaks nothing.
                let captureLink = UIAdapterLink(gate: .captureLive)
                captureLink.bind(to: context)
                Task { @MainActor in
                    await captureLink.arrive()
                    capture.goLive()
                }
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

    struct UIGatedRecorder: AudioRecording, PartialAudioProviding {
        let link: UIAdapterLink
        let audioURL: URL
        /// Non-nil only for `UIFlowFixture.captureWarmup()`. Absent, the capture behaves
        /// like every other fixture's and is live from the first poll.
        var capture: UICaptureWarmup?
        /// Non-nil only for `UIFlowFixture.partialPreview()`. Absent, the recorder offers no
        /// partial audio at all, which is what keeps every other flow's preview engine idle.
        var partialSamples: Int?

        /// A fixed count at or above the engine's first-snapshot threshold, so exactly one
        /// preview is requested however many times the 40 ms poll ticks.
        func partialAudio() -> PartialAudioSnapshot? {
            guard let partialSamples else { return nil }
            return PartialAudioSnapshot(
                pcmURL: audioURL.deletingPathExtension().appendingPathExtension("pcm"),
                sampleCount: partialSamples
            )
        }

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

        /// Digital silence until the capture is live, which is what the AirPods Max
        /// measurement actually recorded: 64 of the first 197 buffers all zeros.
        func currentInputLevel() -> Float? { captureIsLive() ? 0.42 : 0 }

        /// Nothing to report until real audio has arrived; then the measured cold-link
        /// figure, so a flow reading this sees the number that made the bug visible.
        func lastStartLatencyMs() -> Int? {
            guard let capture else { return 18 }
            return capture.isLive ? 1_422 : nil
        }

        func captureIsLive() -> Bool { capture?.isLive ?? true }
        func discardRecording() async {}
    }

    struct UIGatedASR: ASRClienting {
        let link: UIAdapterLink
        let result: Result<ASRResult, ASRErrorMessage>
        /// Non-nil only for `UIFlowFixture.partialPreview()`. Absent, `transcribePartial`
        /// falls through to the protocol default and the engine disables itself, which is the
        /// production behaviour for every backend without a partial path.
        var partialLink: UIAdapterLink?
        var partialResult: ASRResult?

        func transcribePartial(pcmURL: URL, sampleCount: Int, timeoutMs: Int) async throws -> ASRResult {
            guard let partialLink, let partialResult else {
                throw ASRErrorMessage(
                    code: .backendUnavailable,
                    requestId: nil,
                    detail: "partial transcription unsupported"
                )
            }
            await partialLink.arrive()
            return partialResult
        }

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

    /// Capture liveness the script owns.
    ///
    /// `AudioRecording.captureIsLive()` is a synchronous poll -- `RecordingSessionDriver`
    /// reads it once when metering starts and again every 40 ms -- so the warm-up window
    /// cannot be a suspension inside the recorder the way `stop()` is. It is a flag
    /// instead, and the `.captureLive` gate decides when it flips. Lock-guarded rather
    /// than actor-isolated for the same reason `UIScriptClock` is: the port it answers is
    /// `Sendable` and nonisolated, and hopping actors to read a Bool would change the
    /// metering loop's shape.
    final class UICaptureWarmup: @unchecked Sendable {
        private let lock = NSLock()
        private var live = false

        var isLive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return live
        }

        /// One-way, exactly like the real thing: a capture that has delivered a non-zero
        /// sample never goes back to warming up within one session.
        func goLive() {
            lock.lock()
            live = true
            lock.unlock()
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
        private let pinnedCalendar: Calendar
        private let lock = NSLock()
        private var uuidCounter = 0
        private var nowCounter = 0

        init(now: Date, step: TimeInterval = 0, calendar: Calendar) {
            origin = now
            self.step = step
            pinnedCalendar = calendar
        }

        var runtime: DictationRuntime {
            DictationRuntime(
                now: { [self] in nextNow() },
                makeUUID: { [self] in nextUUID() },
                sleep: { try await Task.sleep(nanoseconds: $0) },
                // The coordinator buckets dictation statistics by this
                // calendar, so a host in another region would otherwise put a
                // fixture's sessions in different day rows and move the
                // fourteen-day chart in the golden.
                calendar: { [self] in pinnedCalendar }
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
