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

    // Deterministic, fully offline app state for the offscreen UI harness.
    //
    // Every value a harness scene renders has to be the same on the next run, on a
    // colleague's Mac, and next Tuesday — otherwise the committed golden churns for
    // reasons that have nothing to do with the UI. Two mechanisms get us there:
    //
    //   1. `UIFixtures` builds a `DictationCoordinator` out of inert fakes and
    //      hardcoded data. It NEVER calls `DictationCoordinator.live()`, which
    //      spawns the Python ASR sidecar, installs a CGEvent tap, opens the
    //      microphone and kicks off warm-up tasks.
    //   2. `RenderOverrides` pins the handful of values a few production views read
    //      straight off this Mac — the wall clock, calendar, locale, time zone, the
    //      TCC database, login Keychain, `~/Library/Application Support` — behind
    //      defaulted overrides.
    //
    // See docs/ui-harness.md.

    // MARK: - Inert adapters

    /// Recorder that never opens CoreAudio and never writes a temp WAV. `stop()`
    /// hands back a path that deliberately does not exist: the dictation pipeline
    /// only ever `try?`-removes it.
    private struct HarnessRecorder: AudioRecording {
        let audioURL: URL

        func start() throws {}

        func stop() async throws -> RecordedAudio {
            RecordedAudio(
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

    /// ASR client with no sidecar, no subprocess and no socket. A nil
    /// `backendHealth` models an unreachable backend.
    private struct HarnessASR: ASRClienting {
        let transcript: String
        let backendHealth: ASRBackendHealth?

        func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            ASRResult(
                requestId: "ui-harness",
                backendId: backendHealth?.backendId ?? "ui-harness",
                modelId: "ui-harness-fixture",
                modelRevision: "pinned",
                transcript: ASRTranscript(text: transcript, language: "en", segments: nil),
                timingsMs: ASRTimings(load: 0, inference: 0, total: 0)
            )
        }

        func health(timeoutMs: Int) async throws -> ASRBackendHealth {
            guard let backendHealth else {
                throw ASRErrorMessage(
                    requestId: "ui-harness",
                    code: .backendUnavailable,
                    category: "backend",
                    retryable: true,
                    userMessageKey: "backend_unavailable",
                    detail: "Sidecar did not answer the health probe."
                )
            }
            return backendHealth
        }

        func warmUp() async {}
        func lastTranscriptionPath() -> String? { nil }
    }

    /// Fixed paste target. Never touches `NSWorkspace` or the accessibility API.
    struct HarnessTracker: TargetTracking {
        let target: TargetSnapshot

        init(
            bundleID: String = "com.apple.dt.Xcode",
            safety: TargetSafetyClass = .codeEditor
        ) {
            target = TargetSnapshot(bundleId: bundleID, pid: 4_242, safety: safety)
        }

        func snapshot() -> TargetSnapshot { target }

        func stillMatches(_ snap: TargetSnapshot) -> Bool { true }
    }

    /// Reports an insertion outcome without ever writing to the pasteboard or
    /// posting a synthetic key event.
    private struct HarnessInserter: TextInserting {
        let outcome: InsertionOutcome

        func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome { outcome }
    }

    /// Pinned permission answers. Reads no TCC state and can never raise a prompt.
    struct HarnessPermissions: PermissionsChecking {
        let state: PermissionState

        func microphone() -> PermissionState { state }
        func requestMicrophone() async -> Bool { state == .granted }
        func synthPaste() -> PermissionState { state }
        func requestSynthPaste() async -> Bool { state == .granted }
        func accessibility() -> PermissionState { state }
    }

    /// Accepts the toggle and cancel handlers and drops them: no CGEvent tap, no
    /// global monitor.
    struct HarnessHotkey: HotkeyBinding {
        func onToggle(_ handler: @escaping @Sendable () -> Void) {}
        func onCancel(_ handler: @escaping @Sendable () -> Void) {}
        func setCancelArmed(_ isArmed: Bool) {}
    }

    /// Always declines to refine, so no network request and no `omp` subprocess.
    private struct HarnessRefiner: TranscriptRefining {
        func refine(
            _ raw: String,
            glossary: [ProtectedTerm],
            safety: TargetSafetyClass,
            style: RefinementStyle
        ) async -> RefineOutcome {
            .skipped(reason: "ui harness fixture")
        }

        func warmUp() async {}
    }

    // MARK: - Fixtures

    @MainActor
    enum UIFixtures {
        /// The app state a scene wants. Each case is a complete, settled
        /// `DictationCoordinator`; nothing is left to arrive asynchronously after
        /// the harness starts pumping.
        enum Kind {
            /// Nothing dictated yet: no sessions, bundled glossary, dev backend.
            case firstRun
            /// A fixed nine-session history on the dev backend.
            case populated
            /// Populated history, but every glossary term removed.
            case emptyGlossary
            /// Populated history with a live capture in progress.
            case recording
            /// Real backend with the microphone denied: `state == .error`.
            case micDenied
            /// Real backend, healthy sidecar, every permission granted.
            case backendReady
            /// Real backend whose health probe fails, permissions denied.
            case backendUnavailable
            /// Refinement switched on and fully configured, key in the Keychain.
            case refinerConfigured
            /// Apple's on-device model: no endpoint, no key and no model field.
            case refinerAppleOnDevice
            /// The brokered Oh My Pi provider: sign-in prose and a provider/model id.
            case refinerOmp
            /// OMP selected after the temporary Terminal sign-in could not start.
            case refinerOmpLoginFailed
            /// A user-supplied OpenAI-compatible endpoint keyed from the
            /// environment, with its probe still in flight.
            case refinerCustom
            /// A key the endpoint rejected, so CREDENTIALS sits beside a BAD KEY.
            case refinerUnauthorized
            /// A configured cloud endpoint that never answered the probe.
            case refinerUnreachable
            /// The saved backend differs from the one running, so the warning mark
            /// is the one-click restart action.
            case backendSwitchPending
            /// One dictation driven end to end: `lastTranscript` and `lastOutcome`
            /// are populated and exactly one session was recorded.
            case completedDictation
        }

        /// Every fixture timestamp derives from this instant, and `RenderOverrides`
        /// pins the render clock to it. 2025-06-15T14:26:40Z.
        static let pinnedNow = Date(timeIntervalSince1970: 1_750_000_000)
        static let pinnedLocale = Locale(identifier: "en_US_POSIX")
        static let pinnedTimeZone = TimeZone(secondsFromGMT: 0)!
        static let pinnedCalendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = pinnedLocale
            calendar.timeZone = pinnedTimeZone
            return calendar
        }()

        /// The transcript the end-to-end fixture dictates.
        static let pinnedTranscript = "The offscreen harness renders every console pane without stealing focus."

        static func coordinator(_ kind: Kind) -> DictationCoordinator {
            pinProcessSeams()
            switch kind {
            case .firstRun:
                return make(sessions: [], permissions: .notDetermined)
            case .populated:
                return make(sessions: history)
            case .emptyGlossary:
                return make(sessions: history, settings: settings(glossary: []))
            case .recording:
                return makeRecording()
            case .micDenied:
                return makeMicDenied()
            case .backendReady:
                return make(
                    sessions: history,
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: realBackendHealth
                )
            case .backendUnavailable:
                return make(
                    sessions: history,
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: nil,
                    permissions: .denied
                )
            case .refinerConfigured:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .openAI, model: "gpt-4.1-nano"),
                    keySource: .keychain
                )
            case .refinerAppleOnDevice:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .appleOnDevice),
                    reachability: .ok(models: 1)
                )
            case .refinerOmp:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .omp),
                    reachability: .ok(models: 14),
                    ompProviderConnections: ompProviderConnections,
                    ompProviderStatusState: .loaded
                )
            case .refinerOmpLoginFailed:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .omp),
                    reachability: .unknown,
                    ompOnboardingState: .failed(
                        .gemini,
                        "Oh My Pi is unavailable. Install or update `omp`, then try again."
                    ),
                    ompProviderConnections: ompProviderConnections,
                    ompProviderStatusState: .loaded
                )
            case .refinerCustom:
                return make(
                    sessions: history,
                    settings: refinerSettings(
                        provider: .custom,
                        model: "qwen3-30b-a3b-instruct",
                        baseURL: "https://llm.internal.example/v1"
                    ),
                    keySource: .environment,
                    reachability: .checking
                )
            case .refinerUnauthorized:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .openAI, model: "gpt-4.1-nano"),
                    keySource: .keychain,
                    reachability: .unauthorized
                )
            case .refinerUnreachable:
                return make(
                    sessions: history,
                    settings: refinerSettings(provider: .openRouter),
                    keySource: .environment,
                    reachability: .failed("The request timed out after 3000 ms.")
                )
            case .backendSwitchPending:
                return make(
                    sessions: history,
                    settings: settings(backend: "mlx"),
                    backend: "fake"
                )
            case .completedDictation:
                return makeCompletedDictation()
            }
        }

        // MARK: Process-wide pins

        /// Applied once, before any fixture is built. Idempotent.
        static func pinProcessSeams() {
            RenderOverrides.now = pinnedNow
            RenderOverrides.calendar = pinnedCalendar
            RenderOverrides.locale = pinnedLocale
            RenderOverrides.timeZone = pinnedTimeZone
            RenderOverrides.settingsPath = Ledger.settingsPath
            RenderOverrides.recentSessionsPath = Ledger.recentSessionsPath
            // Accessibility settings are machine state too. Base scenes explicitly
            // pin the standard presentation; dedicated a11y scenes opt one in.
            RenderOverrides.reduceTransparency = false
            RenderOverrides.reduceMotion = false
            RenderOverrides.differentiateWithoutColor = false
            RenderOverrides.increasedContrast = false
            // `#available` follows the runtime OS. Committed goldens intentionally
            // exercise the painted path even when the harness runs on macOS 26.
            RenderOverrides.forceLegacyGlass = true
            // Fixed glyph AND fixed hue/saturation: `CometEmoji.random()` also
            // rasterises the glyph to sample its colour, which the harness skips
            // entirely by supplying the sampled values directly.
            RenderOverrides.cometHead = CometEmoji(glyph: "☄️", hue: 0.08, saturation: 0.85)
            // Apple Intelligence availability is this Mac's: OS version, hardware,
            // and whether the user ever switched it on. Pinning the ready wording
            // keeps the Refinement pane's on-device row identical on every host.
            RenderOverrides.foundationModelsDetail = Ledger.foundationModelsDetail
            // Probe verdicts belong to a fixture, not the process: `make` installs
            // one, and clearing here stops a refinement scene's verdict leaking
            // into whatever renders next.
            RenderOverrides.refinerReachability = nil
            RenderOverrides.ompOnboardingState = nil
            RenderOverrides.ompProviderConnections = nil
            RenderOverrides.ompProviderStatusState = nil
        }

        // MARK: Property-ledger sample data

        /// Every value `atom.properties` renders.
        ///
        /// `PropertyKit`'s rows are pure-value views, so that scene's reproducibility
        /// is entirely a property of the data handed to them: a real bundle version, a
        /// real `~/Library` path or a live health report would churn its golden on
        /// every machine and on every rebuild. The two storage paths are the same
        /// constants `pinProcessSeams()` installs above, so the sheet renders the
        /// panes' own values instead of a second spelling of them.
        enum Ledger {
            static let settingsPath = "/Users/harness/Library/Application Support/VoiceOour/settings.json"
            static let recentSessionsPath = "/Users/harness/Library/Application Support/VoiceOour/recent-sessions.json"

            /// Never `Bundle.main.infoDictionary`: the harness runs from a bare
            /// executable whose short version and build number are not the app's.
            static let version = "1.4.0 (build 812)"

            /// Illustrative, not derived from `history`: the sheet renders row
            /// shapes, not this fixture's session list.
            static let savedSessions = "9"
            static let savedSessionsSize = "2.4 MB"

            static let endpoint = "https://api.openai.com/v1"
            static let model = "gpt-4.1-nano"
            static let timeout = "3000"

            /// The advisory prose the conditional caption states carry, and the
            /// payload the copy accessory hands to the pasteboard.
            static let healthFailure = "The last probe could not reach the sidecar socket: connection refused."
            static let healthReport = "backend=mlx-parakeet status=backendUnavailable cache=ok model=not loaded"
            static let microphonePrompt = "macOS may ask for microphone access when the first real recording starts."
            /// The readiness sentence the Refinement pane appends to its on-device
            /// row. Matches `FoundationModelsAvailability.summary().detail` on a Mac
            /// where the model is ready, which is the state the harness pins.
            static let foundationModelsDetail = "Apple Intelligence model ready"

            /// The Refinement on-device row's shape: no value, no rail, prose only.
            static let onDeviceProse =
                "Apple Intelligence runs the model in process — no endpoint and no API key to configure. \(foundationModelsDetail)."
            static let historyFailure =
                "Transcript history could not be erased from disk — it will come back on relaunch."
        }

        // MARK: Composition

        private static let realBackend = "mlx-parakeet"

        // `nonisolated` because it is a default argument of `make`, and default
        // argument expressions are evaluated outside the enum's main-actor context.
        nonisolated private static let devBackendHealth = ASRBackendHealth(
            backendId: "fake",
            backendStatus: .ready,
            ready: true,
            modelLoaded: true,
            cacheOk: true
        )

        private static let realBackendHealth = ASRBackendHealth(
            backendId: realBackend,
            backendStatus: .ready,
            ready: true,
            modelLoaded: true,
            cacheOk: true
        )

        private static let ompProviderConnections = [
            OmpProviderConnection(
                providerID: "openai-codex",
                displayName: "ChatGPT Plus/Pro",
                activeAccounts: 2,
                reportingAccounts: 2,
                disabledAccounts: 0
            ),
            OmpProviderConnection(
                providerID: "anthropic",
                displayName: "Anthropic",
                activeAccounts: 1,
                reportingAccounts: 1,
                disabledAccounts: 0
            ),
            OmpProviderConnection(
                providerID: "google-gemini-cli",
                displayName: "Google Cloud Code Assist",
                activeAccounts: 0,
                reportingAccounts: 0,
                disabledAccounts: 1
            ),
            OmpProviderConnection(
                providerID: "cursor",
                displayName: "Cursor",
                activeAccounts: 1,
                reportingAccounts: 0,
                disabledAccounts: 0
            ),
        ]

        static func settings(
            backend: String = "fake",
            glossary: [ProtectedTerm] = VoiceCore.Settings.defaultGlossary
        ) -> VoiceCore.Settings {
            VoiceCore.Settings(
                asrBackend: backend,
                glossary: glossary,
                // Silence would otherwise let the metering task stop a `.recording`
                // fixture out from under the renderer.
                autoStopEnabled: false
            )
        }

        /// Refinement switched on for one provider. Everything else stays at the
        /// shared fixture default, so one provider scene differs from the next only
        /// where the pane's own branching differs.
        private static func refinerSettings(
            provider: RefinerProvider,
            model: String = "",
            baseURL: String = ""
        ) -> VoiceCore.Settings {
            var configured = settings()
            configured.refinerEnabled = true
            configured.refinerProvider = provider
            configured.refinerModel = model
            configured.refinerBaseURL = baseURL
            return configured
        }

        static func make(
            sessions: [RecentSession],
            settings fixtureSettings: VoiceCore.Settings? = nil,
            backend: String = "fake",
            health: ASRBackendHealth? = UIFixtures.devBackendHealth,
            permissions: PermissionState = .granted,
            keySource: RefinerKeySource = .none,
            reachability: RefinerReachability? = nil,
            ompOnboardingState: OmpOnboardingState? = nil,
            ompProviderConnections: [OmpProviderConnection]? = nil,
            ompProviderStatusState: OmpProviderStatusState? = nil,
            insertion: InsertionOutcome = .pasteAttempted,
            asrOverride: ASRClienting? = nil,
            cloudReachabilityProbe: @escaping DictationCoordinator.CloudReachabilityProbeFunction = {
                _, _, _, _ in .failed("ui harness fixture")
            },
            // Zero keeps `now` frozen, which is what every scene golden depends on. Only a
            // flow that has to defeat the backend-probe TTL asks for a step.
            clockStep: TimeInterval = 0
        ) -> DictationCoordinator {
            RenderOverrides.permissions = HarnessPermissions(state: permissions)
            RenderOverrides.refinerReachability = reachability
            RenderOverrides.ompOnboardingState = ompOnboardingState
            RenderOverrides.ompProviderConnections = ompProviderConnections
            RenderOverrides.ompProviderStatusState = ompProviderStatusState
            let scratch = nextScratchDirectory()
            let asrClient: ASRClienting =
                asrOverride ?? HarnessASR(transcript: pinnedTranscript, backendHealth: health)
            let clock = UIScriptClock(now: pinnedNow, step: clockStep)
            let coordinator = DictationCoordinator(
                recorder: HarnessRecorder(audioURL: scratch.appendingPathComponent("capture.wav")),
                asr: asrClient,
                tracker: HarnessTracker(),
                inserter: HarnessInserter(outcome: insertion),
                permissions: HarnessPermissions(state: permissions),
                hotkey: HarnessHotkey(),
                refiner: HarnessRefiner(),
                settings: fixtureSettings ?? settings(backend: backend),
                activeASRBackend: backend,
                settingsStore: SettingsStore(url: scratch.appendingPathComponent("settings.json")),
                recentSessionStore: seededStore(sessions, in: scratch),
                recentSessionSnapshotSave: { _, _ in },
                keySourceProvider: { _ in keySource },
                refinerAPIKeyProvider: { _ in nil },
                // No scene presses CHECK, and these make sure none ever could: the
                // real probes spawn `omp` and reach the network.
                ompModelsProbe: { _, _, _, _ in .failed("ui harness fixture") },
                ompProviderStatusProbe: { _, _, _ in
                    OmpProviderStatusSnapshot(connections: [])
                },
                cloudReachabilityProbe: cloudReachabilityProbe,
                audioMuter: NoOpSystemAudioMuter(),
                runtimeOverride: clock.runtime
            )

            // Resolve backend health here rather than leaving it to the System /
            // Diagnostics `onAppear` probe: an answer that lands mid-capture would
            // make those two scenes race the renderer. Settling now also puts the
            // coordinator's 5s de-dupe TTL in front of the pane's own probe.
            coordinator.refreshBackendHealth(timeoutMs: 500)
            settle { coordinator.backendHealth != nil || coordinator.backendHealthError != nil }
            return coordinator
        }

        private static func makeRecording() -> DictationCoordinator {
            let coordinator = make(sessions: history)
            coordinator.start()
            settle { coordinator.state == .recording }
            return coordinator
        }

        private static func makeMicDenied() -> DictationCoordinator {
            // A non-dev backend consults the microphone permission synchronously,
            // so a denied answer lands the coordinator in `.error` with no task hop.
            let coordinator = make(
                sessions: history,
                settings: settings(backend: realBackend),
                backend: realBackend,
                health: realBackendHealth,
                permissions: .denied
            )
            coordinator.start()
            settle { coordinator.errorMessage != nil }
            return coordinator
        }

        private static func makeCompletedDictation() -> DictationCoordinator {
            // Empty glossary keeps the post-dictation suggestion scan (which runs
            // detached and commits back on the main actor) trivial, so the fixture
            // cannot settle into one state and then mutate into another.
            let coordinator = make(sessions: [], settings: settings(glossary: []))
            coordinator.start()
            settle { coordinator.state == .recording }
            coordinator.stopAndProcess()
            settle { coordinator.state == .idle && !coordinator.lastTranscript.isEmpty }
            return coordinator
        }

        // MARK: Throwaway storage

        /// Per-process scratch root. Fixtures point `SettingsStore` and
        /// `RecentSessionStore` here so nothing can read or write the user's real
        /// `~/Library/Application Support/VoiceOour` data.
        private static let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "voiceoour-ui-harness-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

        private static var scratchCounter = 0

        static func nextScratchDirectory() -> URL {
            scratchCounter += 1
            return scratchRoot.appendingPathComponent("fixture-\(scratchCounter)", isDirectory: true)
        }

        /// `DictationCoordinator` loads its history through the store and exposes no
        /// in-memory seam for it, so a populated fixture writes its fixed list to
        /// the throwaway file above and lets the coordinator read it back.
        private static func seededStore(_ sessions: [RecentSession], in scratch: URL) -> RecentSessionStore {
            let store = RecentSessionStore(url: scratch.appendingPathComponent("recent-sessions.json"))
            if !sessions.isEmpty {
                try? store.save(sessions)
            }
            return store
        }

        // MARK: Settling

        /// Turns the main run loop until `condition` holds or 3,000 fixed pumps
        /// have run. A bounded turn count gives every machine the same verdict.
        private static func settle(until condition: () -> Bool) {
            for _ in 0..<3_000 {
                if condition() { return }
                UIHarnessRuntime.pump(iterations: 1)
            }
        }

        // MARK: Fixed history

        /// Nine sessions ending at `pinnedNow`, chosen to light up every branch the
        /// Home and Sessions panes have: several days in a row (streak), a couple
        /// of same-day sessions (today tallies), five distinct paste destinations,
        /// a copy-only outcome, a failed outcome, and one refined transcript.
        static let history: [RecentSession] = [
            session(
                index: 1,
                minutesAgo: 12,
                text: "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay.",
                bundleId: "com.apple.dt.Xcode",
                captureMs: 6_800,
                asrMs: 410
            ),
            session(
                index: 2,
                minutesAgo: 95,
                text: "Accessibility children stay empty until enhanced user interface is switched on.",
                bundleId: "com.apple.dt.Xcode",
                captureMs: 7_400,
                asrMs: 455
            ),
            session(
                index: 3,
                minutesAgo: 260,
                text: "Ship the contact sheet next to the manifest so a reviewer sees every pane at once.",
                bundleId: "com.tinyspeck.slackmacgap",
                disposition: .copiedOnly,
                reason: "target is a secure field",
                captureMs: 8_100,
                asrMs: 512
            ),
            session(
                index: 4,
                minutesAgo: 1_500,
                text: "Golden files must never encode the developer's display profile.",
                bundleId: "com.microsoft.VSCode",
                captureMs: 5_600,
                asrMs: 380,
                refinement: RefinementTrace(
                    kind: .refined, provider: "openAI:gpt-4.1-nano", reason: nil, latencyMs: 640)
            ),
            session(
                index: 5,
                minutesAgo: 1_720,
                text: "Pump the run loop a fixed number of iterations, never until it looks settled.",
                bundleId: "com.microsoft.VSCode",
                captureMs: 6_200,
                asrMs: 402
            ),
            session(
                index: 6,
                minutesAgo: 2_950,
                text: "Post the mouse up before sending the mouse down or AppKit's tracking loop wedges.",
                bundleId: "com.apple.Terminal",
                captureMs: 7_900,
                asrMs: 468
            ),
            session(
                index: 7,
                minutesAgo: 4_400,
                text: "Behind window vibrancy has no desktop to sample offscreen, so it renders flat.",
                bundleId: "com.apple.Safari",
                disposition: .failed,
                reason: "no insertion target",
                captureMs: 4_300,
                asrMs: 295
            ),
            session(
                index: 8,
                minutesAgo: 7_300,
                text: "Every accessibility accessor needs its own responds-to guard.",
                bundleId: "com.apple.dt.Xcode",
                captureMs: 5_100,
                asrMs: 342
            ),
            session(
                index: 9,
                minutesAgo: 11_600,
                text: "An activation policy of prohibited is the only setting that never steals focus.",
                bundleId: "com.apple.Terminal",
                captureMs: 6_050,
                asrMs: 388
            ),
        ]

        private static func session(
            index: Int,
            minutesAgo: Int,
            text: String,
            bundleId: String,
            disposition: RecentSessionInsertionDisposition = .pasteAttempted,
            reason: String? = nil,
            captureMs: Int,
            asrMs: Int,
            refinement: RefinementTrace? = nil
        ) -> RecentSession {
            RecentSession(
                id: fixedIdentifier(index),
                createdAt: pinnedNow.addingTimeInterval(-Double(minutesAgo) * 60),
                text: text,
                mutedDuringCapture: index.isMultiple(of: 3),
                outcome: RecentSessionOutcomeMetadata(
                    disposition: disposition,
                    reason: reason,
                    targetSafety: bundleId == "com.apple.Terminal" ? .terminal : .normalText,
                    targetBundleId: bundleId
                ),
                rawTranscript: text,
                refinement: refinement ?? RefinementTrace(kind: .skipped, reason: "refiner disabled"),
                stages: SessionStageTimings(
                    captureMs: captureMs,
                    asrMs: asrMs,
                    insertMs: 24,
                    startLatencyMs: 18,
                    asrPath: "mlx"
                )
            )
        }

        /// Stable RFC-4122-shaped identifier. The harness must never call `UUID()`:
        /// a fresh identifier per run changes SwiftUI's `ForEach` identity and, for
        /// the Sessions pane, which row starts out selected.
        private static func fixedIdentifier(_ index: Int) -> UUID {
            UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012x", index))")
                ?? UUID(uuid: (0, 0, 0x40, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))
        }
    }

#endif
