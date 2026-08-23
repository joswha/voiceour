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
    //      TCC database and the app's `~/Library/Application Support` files
    //      behind defaulted overrides.
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
            /// A live recording session on the dev backend: `state == .recording`.
            case recording
            /// Real backend with the microphone denied: `state == .error`.
            case micDenied
            /// Real backend, healthy sidecar, every permission granted.
            case backendReady
            /// Real backend whose health probe fails, permissions denied.
            case backendUnavailable
            /// Real backend part-way through acquiring its 1.26 GB artifact.
            case backendDownloading
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
                    permissions: .denied,
                    muteUnavailable: true
                )
            case .backendDownloading:
                return make(
                    sessions: history,
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: downloadingBackendHealth
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
            RenderOverrides.dictationStatsPath = Ledger.dictationStatsPath
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
        }

        // MARK: Pinned storage paths

        enum Ledger {
            static let settingsPath = "/Users/harness/Library/Application Support/Voiceour/settings.json"
            static let recentSessionsPath =
                "/Users/harness/Library/Application Support/Voiceour/recent-sessions.json"
            static let dictationStatsPath =
                "/Users/harness/Library/Application Support/Voiceour/dictation-activity.json"
        }

        // MARK: Composition

        /// The canonical picker id: what `Settings.asrBackend` stores and what
        /// the registry resolves a descriptor from. Not `parakeet-cpp`, which is
        /// the id the sidecar reports for itself.
        private static let realBackend = "parakeet"

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
            backendId: "parakeet-cpp",
            backendStatus: .ready,
            ready: true,
            modelLoaded: true,
            cacheOk: true
        )

        /// Mid-acquisition: no cache yet, so `ready` is false and the fraction is what the
        /// System pane reads.
        private static let downloadingBackendHealth = ASRBackendHealth(
            backendId: "parakeet-cpp",
            backendStatus: .modelMissing,
            ready: false,
            modelLoaded: false,
            cacheOk: false,
            downloadFraction: 0.42,
            warming: nil
        )

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

        static func make(
            sessions: [RecentSession],
            settings fixtureSettings: VoiceCore.Settings? = nil,
            backend: String = "fake",
            health: ASRBackendHealth? = UIFixtures.devBackendHealth,
            permissions: PermissionState = .granted,
            /// The last capture asked for a mute the output device could not
            /// provide. Pinned rather than driven: reaching the real verdict
            /// needs a CoreAudio device, which a golden may never depend on.
            muteUnavailable: Bool = false,
            insertion: InsertionOutcome = .pasteAttempted,
            asrOverride: ASRClienting? = nil,
            // Zero keeps `now` frozen, which is what every scene golden depends on. Only a
            // flow that has to defeat the backend-probe TTL asks for a step.
            clockStep: TimeInterval = 0,
            resolveBackendHealth: Bool = true,
            /// Nil means "match the journal": a fixture with dictations gets the
            /// fixed lifetime ledger below, one without gets an empty file-less
            /// ledger. Either way the file's presence is decided here, so no
            /// fixture ever takes the coordinator's one-time backfill path by
            /// accident and folds the nine seeded transcripts into its totals.
            stats: DictationStatsLedger? = nil,
            recentSessionSnapshotSave: @escaping @Sendable (RecentSessionStore, [RecentSession]) throws -> Void = {
                _, _ in
            }
        ) -> DictationCoordinator {
            RenderOverrides.permissions = HarnessPermissions(state: permissions)
            let scratch = nextScratchDirectory()
            let asrClient: ASRClienting =
                asrOverride ?? HarnessASR(transcript: pinnedTranscript, backendHealth: health)
            let clock = UIScriptClock(now: pinnedNow, step: clockStep, calendar: pinnedCalendar)
            let coordinator = DictationCoordinator(
                recorder: HarnessRecorder(audioURL: scratch.appendingPathComponent("capture.wav")),
                asr: asrClient,
                tracker: HarnessTracker(),
                inserter: HarnessInserter(outcome: insertion),
                permissions: HarnessPermissions(state: permissions),
                hotkey: HarnessHotkey(),
                settings: fixtureSettings ?? settings(backend: backend),
                activeASRBackend: backend,
                settingsStore: SettingsStore(url: scratch.appendingPathComponent("settings.json")),
                recentSessionStore: seededStore(sessions, in: scratch),
                dictationStatsStore: seededStatsStore(
                    stats ?? (sessions.isEmpty ? DictationStatsLedger() : statsLedger),
                    in: scratch
                ),
                recentSessionSnapshotSave: recentSessionSnapshotSave,
                audioMuter: NoOpSystemAudioMuter(),
                runtimeOverride: clock.runtime
            )

            // Scene fixtures resolve health before rendering so a result cannot
            // land mid-capture. A flow that scripts the System tab opts out and
            // gates that tab's own probe instead.
            if resolveBackendHealth {
                coordinator.refreshBackendHealth(timeoutMs: 500)
                settle { coordinator.backendHealth != nil || coordinator.backendHealthError != nil }
            }
            coordinator.isSystemAudioMuteUnavailable = muteUnavailable
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
        /// `~/Library/Application Support/Voiceour` data.
        private static let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "voiceour-ui-harness-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

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

        /// The stats ledger is loaded through its store the same way, so a
        /// populated fixture writes the fixed lifetime tally below and lets the
        /// coordinator read it back. An empty ledger writes no file at all,
        /// which is also what makes the empty Home scene exercise the
        /// no-file-and-no-journal path rather than the backfill.
        private static func seededStatsStore(
            _ ledger: DictationStatsLedger,
            in scratch: URL
        ) -> DictationStatsStore {
            let store = DictationStatsStore(url: scratch.appendingPathComponent("dictation-activity.json"))
            try? store.save(ledger)
            return store
        }

        /// The fixed lifetime tally every populated fixture renders.
        ///
        /// Stated literally rather than folded through `record(_:_:_:)`: a
        /// fixture is data, and deriving it would make a committed golden move
        /// whenever the fold's ordering rules were touched. The figures are
        /// mutually consistent — the day buckets sum to the totals, and 23
        /// distinct days carry one six-day run — and `DictationStatsTests`
        /// proves separately that `record` computes those same aggregates.
        ///
        /// Chosen to exercise every readout at once: today and yesterday are
        /// empty, so the current streak is 0 while the longest is 6; the
        /// window's busiest day is a clear outlier, so all four heat levels
        /// appear; and 2025-06-15 is a Sunday, so the last heatmap column holds
        /// six days the calendar has not reached yet.
        static let statsLedger: DictationStatsLedger = {
            // (days before `pinnedNow`, sessions, words, seconds)
            let rows: [(Int, Int, Int, Double)] = [
                (2, 12, 1_800, 840), (3, 9, 1_458, 684), (4, 5, 870, 410),
                (6, 14, 4_351, 1_232), (7, 7, 1_386, 658), (9, 3, 630, 210),
                (12, 11, 2_442, 836), (13, 16, 2_400, 2_130), (14, 6, 972, 528),
                (15, 10, 1_740, 940), (16, 4, 744, 280), (17, 13, 2_574, 988),
                (20, 8, 1_680, 656), (21, 5, 1_110, 440), (22, 9, 1_350, 846),
                (23, 12, 1_944, 840), (26, 7, 1_218, 532), (27, 6, 1_116, 492),
                (31, 10, 1_980, 880), (38, 8, 1_680, 752), (39, 5, 1_110, 350),
                (45, 4, 600, 304), (52, 6, 972, 492),
            ]
            var days: [String: DictationDayStat] = [:]
            for (offset, sessions, words, seconds) in rows {
                let key = DictationStatsLedger.dayKey(
                    for: pinnedNow.addingTimeInterval(-Double(offset) * 86_400),
                    calendar: pinnedCalendar
                )
                days[key] = DictationDayStat(sessions: sessions, words: words, seconds: seconds)
            }
            return DictationStatsLedger(
                totalSessions: 190,
                totalWords: 36_127,
                totalSeconds: 16_320,
                totalActiveDays: 23,
                longestStreakDays: 6,
                days: days
            )
        }()

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

        /// Nine sessions ending at `pinnedNow`, chosen to exercise the Sessions
        /// list and search across multiple days, same-day entries, varied paste
        /// destinations, a copy-only outcome and a failed outcome.
        static let history: [RecentSession] = [
            session(
                index: 1,
                minutesAgo: 12,
                text: "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay.",
                bundleId: "com.apple.dt.Xcode",
                captureMs: 6_800,
                asrMs: 410,
                // Exactly one seeded session carries the field so
                // console.sessions.selection renders the LEAST SURE row.
                leastConfidentWord: LeastConfidentWord(text: "cacheDisplay", score: 0.43)
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
                asrMs: 380
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
            leastConfidentWord: LeastConfidentWord? = nil
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
                stages: SessionStageTimings(
                    captureMs: captureMs,
                    asrMs: asrMs,
                    insertMs: 24,
                    startLatencyMs: 18,
                    asrPath: "parakeet"
                ),
                leastConfidentWord: leastConfidentWord
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
