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

    import AppKit
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
        var transcriptionError: SidecarASRClientError? = nil

        func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            if let transcriptionError { throw transcriptionError }
            return ASRResult(
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
    }

    /// Fixed paste target. Never touches `NSWorkspace` or the accessibility API.
    struct HarnessTracker: TargetTracking {
        let target: TargetSnapshot

        init(
            bundleID: String = "com.apple.dt.Xcode",
            appName: String? = "Xcode",
            safety: TargetSafetyClass = .codeEditor
        ) {
            target = TargetSnapshot(bundleId: bundleID, appName: appName, pid: 4_242, safety: safety)
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

    /// Link Earlier Dictations' reader in every harness coordinator. It opens no file: its
    /// answer is a pure function of the queries and a fixed table keyed by fixture row id,
    /// so no scene or flow can read `~/.omp` or `~/.claude`. A queried row the table lacks
    /// is left out of the answer, which the run counts as not found; nothing is ambiguous.
    struct HarnessPromptEvidence: AgentPromptEvidenceReading {
        let table: [UUID: PromptEvidenceMatch]

        func evidence(for queries: [PromptEvidenceQuery]) -> PromptEvidenceRun {
            var matches: [UUID: PromptEvidenceMatch] = [:]
            for query in queries {
                if let match = table[query.id] {
                    matches[query.id] = match
                }
            }
            return PromptEvidenceRun(matches: matches)
        }
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
            /// A fresh install on the real backend, part-way through acquiring its
            /// 0.51 GB artifact, with no permission answered yet. What a reader
            /// actually meets on the launch that installed the app.
            case firstRunDownloading
            /// A fresh install on the real backend with the model already on disk
            /// and warm, microphone unanswered and Accessibility untrusted — the
            /// state a second launch reaches before the first dictation.
            case firstRunReady
            /// A fresh install whose acquisition failed and said why. The sidecar's
            /// own verdict, which outranks every inferred readout.
            case firstRunAcquisitionFailed
            /// An install that has completed a dictation and has nothing left to
            /// show: history and lifetime figures erased. Zeroed like `firstRun`,
            /// but owed no guidance, so Home keeps its caption instead of the card.
            case erasedFigures
            /// A fixed ten-session history on the dev backend.
            case populated
            /// The populated History with memory switched on and a memory folder that
            /// reaches further back: the ten History rows plus twelve older dictations
            /// History no longer holds and three notes, so the Journal shows days, thread
            /// entries and notes only memory can supply. The folder also holds three topics,
            /// and about half its entries carry the sorting model's labels or a topic the
            /// user filed them under by hand, so Topics and Rewind's Highlights have
            /// something to show.
            case remembered
            /// Populated history, but every glossary term removed.
            case emptyGlossary
            /// Populated history with a glossary that is not all bundled: one
            /// taught term and one imported term, so the row treatment only a
            /// non-default ledger can show — both origin filter facets —
            /// actually renders.
            case mixedGlossary
            /// A live recording session on the dev backend: `state == .recording`.
            case recording
            /// Real backend with the microphone denied: `state == .error`.
            case micDenied
            /// A real stop pipeline receiving a wrapped sidecar model failure.
            case sidecarFailure
            /// Real backend, healthy sidecar, every permission granted.
            case backendReady
            /// Real backend whose health probe fails, permissions denied.
            case backendUnavailable
            /// Real backend part-way through acquiring its 0.51 GB artifact.
            case backendDownloading
            /// One dictation driven end to end: `lastTranscript` and `lastOutcome`
            /// are populated and exactly one session was recorded.
            case completedDictation
            /// `backendReady` wearing the Arctic Platinum look: a pearl film, an underglow,
            /// the Overcast room and non-stock tone at once, so one golden locks every row a
            /// stock island leaves hidden or disabled.
            case islandLook
            /// Arctic Platinum tuned one finish step off its look, on an island the user tore
            /// off and left free: the CUSTOM mark, a look list with nothing selected and a live
            /// Dock Island, none of which a stock install can show.
            case islandCustom
            /// A dictation just pasted into Tern, with agent-session binding on and its History
            /// row bound to the fixture's omp session: the menu's report names the thread.
            /// The row and the published outcome are stated, never resolved: the resolver stays
            /// `NoAgentSessionResolving` and no dictation runs.
            case pastedLinked
            /// The same paste, its row carrying the link's miss (`.focusMoved`) instead of a
            /// binding: the menu's report says why it is not linked.
            case pastedUnlinked
            /// The populated History with the menu's request to show the fixture's omp thread
            /// still pending, as a press on the report's thread line leaves it before the
            /// console has read it.
            case threadRequested
            /// The populated History with agent-session linking on, so Settings offers Link
            /// Earlier Dictations. Its rows are data: the resolver stays `NoAgentSessionResolving`,
            /// and a run reads `UIFixtures.promptEvidence`, which holds one match.
            case linkingOn
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
            case .firstRunDownloading:
                return make(
                    sessions: [],
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: downloadingBackendHealth,
                    permissions: .notDetermined
                )
            case .firstRunReady:
                return make(
                    sessions: [],
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: realBackendHealth,
                    permissions: .notDetermined
                )
            case .firstRunAcquisitionFailed:
                return make(
                    sessions: [],
                    settings: settings(backend: realBackend),
                    backend: realBackend,
                    health: failedAcquisitionHealth,
                    permissions: .notDetermined
                )
            case .erasedFigures:
                return make(
                    sessions: [],
                    settings: settings(hasCompletedFirstRun: true),
                    permissions: .notDetermined
                )
            case .populated:
                return make(sessions: history)
            case .remembered:
                return make(
                    sessions: history,
                    settings: settings(memoryEnabled: true),
                    memory: rememberedMemory,
                    topics: rememberedTopics,
                    agentNotes: rememberedAgentNotes
                )
            case .emptyGlossary:
                return make(sessions: history, settings: settings(glossary: []))
            case .mixedGlossary:
                return make(
                    sessions: history,
                    settings: settings(glossary: VoiceCore.Settings.defaultGlossary + [taughtTerm, importedTerm])
                )
            case .recording:
                return makeRecording()
            case .micDenied:
                return makeMicDenied()
            case .sidecarFailure:
                return makeSidecarFailure()
            case .backendReady:
                return makeBackendReady(island: .stock)
            case .islandLook:
                return makeBackendReady(island: IslandLook.arcticPlatinum.appearance)
            case .islandCustom:
                var island = IslandLook.arcticPlatinum.appearance
                island.finish = 25
                let coordinator = makeBackendReady(island: island)
                // Into the harness suite `pinProcessSeams()` just docked, never the Mac's own.
                RecordingOverlayPlacement.free(u: 0.25, v: 0.75).save(to: placementDefaults)
                return coordinator
            case .backendUnavailable:
                return make(
                    sessions: history,
                    settings: settings(
                        backend: realBackend,
                        preferredMicrophoneUID: "harness-unplugged-wave3",
                        preferredMicrophoneName: "Elgato Wave:3"
                    ),
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
            case .pastedLinked:
                return makePastedToTern(linked: true)
            case .pastedUnlinked:
                return makePastedToTern(linked: false)
            case .threadRequested:
                let coordinator = make(sessions: history)
                coordinator.pendingJournalThread = agentSession
                return coordinator
            case .linkingOn:
                return make(sessions: history, settings: settings(agentSessionBindingEnabled: true))
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
            RenderOverrides.memoryPath = Ledger.memoryPath
            // Accessibility settings are machine state too. Base scenes explicitly
            // pin the standard presentation; dedicated a11y scenes opt one in.
            RenderOverrides.reduceTransparency = false
            RenderOverrides.reduceMotion = false
            RenderOverrides.differentiateWithoutColor = false
            RenderOverrides.increasedContrast = false
            // Which apps this Mac has installed is machine state, and an app
            // icon is the most machine-dependent pixel a golden could hold.
            RenderOverrides.installedApps = pinnedInstalledApps
            // Which microphones this Mac has is machine state too. Two pins so
            // the picker's Automatic default has real alternatives to not name.
            RenderOverrides.availableMicrophones = pinnedMicrophones
            // Production follows a view-bound display link. Pinning the seed and exact
            // substep makes the representable write one deterministic frame without
            // starting that link: 600 substeps is five seconds at the fixed 120 Hz step.
            // The room is not pinned: it belongs to the island appearance under test.
            RenderOverrides.mercurySeed = MercuryMetrics.defaultSeed
            RenderOverrides.mercuryStep = 600
            // The overlay's display is machine state too: resolved from the rendering Mac's own
            // screen, its layout would be the collar on a notched MacBook and the island on a
            // desktop display. The notchless fixture is the island's display; collar scenes set
            // their layout from `collarLayout(on:)` instead.
            RenderOverrides.overlayDisplay = .fixtureNotchless
            // Where this Mac's user last left the island is machine state too, and Settings
            // reads it for Dock Island. The harness suite is docked on every pin, so a free
            // placement is always one a fixture put there.
            RenderOverrides.islandPlacementDefaults = placementDefaults
            RecordingOverlayPlacement.docked.save(to: placementDefaults)
            // The showroom opens on its production pose, Speaking. The one scene that
            // shows another pins it in a scope of its own.
            RenderOverrides.islandShowroomPose = nil
        }

        /// The harness's own defaults suite for the island's placement, so no scene or flow
        /// reads or writes the rendering Mac's `UserDefaults.standard`. The initializer
        /// refuses only the app's bundle identifier and the global domain, never this name.
        private static let placementDefaults = UserDefaults(
            suiteName: "com.voiceour.ui-harness.placement"
        )!

        // MARK: Overlay displays

        /// The collar the camera housing of `display` wears, laid out by
        /// `RecordingOverlayLayout.forDisplay(_:)`, the resolution the panel makes, so a collar
        /// scene, sheet or corpus shows exactly the housing its display fixture describes
        /// rather than a restatement of its numbers.
        ///
        /// Traps rather than falling back: `forDisplay` answers the island for a display that
        /// cannot wear a collar, and a collar golden or gate that silently drew the island
        /// would pass while asserting nothing about the collar.
        static func collarLayout(on display: OverlayDisplay) -> RecordingOverlayLayout {
            let layout = RecordingOverlayLayout.forDisplay(display)
            precondition(layout.kind == .collar, "overlay display \(display.id) wears no collar")
            return layout
        }

        // MARK: Pinned storage paths

        enum Ledger {
            static let settingsPath = "/Users/harness/Library/Application Support/Voiceour/settings.json"
            static let recentSessionsPath =
                "/Users/harness/Library/Application Support/Voiceour/recent-sessions.json"
            static let dictationStatsPath =
                "/Users/harness/Library/Application Support/Voiceour/dictation-activity.json"
            static let memoryPath = "/Users/harness/Library/Application Support/Voiceour/memory"
        }

        // MARK: Pinned installed apps

        /// Two pins, chosen to lock every state an app label or badge can be in.
        /// Xcode carries the same name the fixtures persist, so its rows prove the
        /// icon path alone. VSCode's pinned name is deliberately "Code" against a
        /// persisted "Visual Studio Code", so its rows prove installed-name-wins.
        /// cmux, ChatGPT, Claude, Brave Browser, Safari and Ghostty are
        /// deliberately absent even though the rendering Mac may well have
        /// them, so their Home rows lock the monogram and persisted-name
        /// fallback; the Slack and Terminal history rows take the same path.
        static let pinnedInstalledApps: [String: InstalledApp] = [
            "com.apple.dt.Xcode": InstalledApp(
                name: "Xcode",
                icon: pinnedAppIcon(NSColor(srgbRed: 0.20, green: 0.48, blue: 0.97, alpha: 1))
            ),
            "com.microsoft.VSCode": InstalledApp(
                name: "Code",
                icon: pinnedAppIcon(NSColor(srgbRed: 0.13, green: 0.65, blue: 0.95, alpha: 1))
            ),
        ]

        /// The input devices the Settings microphone picker offers. The Yeti is
        /// what `backendReady` selects, proving the connected-selection caption;
        /// `backendUnavailable` selects a UID deliberately absent from this list,
        /// proving the NOT CONNECTED presentation.
        static let pinnedMicrophones: [CoreAudioInputDevice.AvailableMicrophone] = [
            CoreAudioInputDevice.AvailableMicrophone(
                uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
            CoreAudioInputDevice.AvailableMicrophone(
                uid: "harness-usb-yeti", name: "Yeti Stereo Microphone"),
        ]

        /// A deterministic stand-in for a real app icon: one flat rounded-rect
        /// fill from a pure drawing handler, so every rasterisation of it is
        /// byte-identical. A real `NSWorkspace` icon is a multi-representation
        /// image whose pixels belong to whichever app version this Mac installed.
        private static func pinnedAppIcon(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7.2, yRadius: 7.2).fill()
                return true
            }
        }

        // MARK: Composition

        /// Granite's canonical picker id: what `Settings.asrBackend` stores and what the
        /// registry resolves a descriptor from. Not `granite-ctc`, which is the id the
        /// sidecar reports for itself. The fixture injects nothing else: the coordinator
        /// derives Granite's artifact (name, size, identifier) from the active backend,
        /// exactly as a live launch does.
        private static let realBackend = "granite"
        private static let realWireBackend = "granite-ctc"

        // `nonisolated` because it is a default argument of `make`, and default
        // argument expressions are evaluated outside the enum's main-actor context.
        nonisolated private static let devBackendHealth = ASRBackendHealth(
            backendId: "fake",
            backendStatus: .ready,
            ready: true,
            modelLoaded: true,
            cacheOk: true
        )

        private static let realBackendHealth = readyHealth(backendId: realWireBackend)

        /// Mid-acquisition: no cache yet, so `ready` is false and the fraction is what the
        /// System pane reads.
        private static let downloadingBackendHealth = downloadingHealth(backendId: realWireBackend)

        /// A model-backed sidecar with its artifact cached and loaded, reporting as `backendId`.
        private static func readyHealth(backendId: String) -> ASRBackendHealth {
            ASRBackendHealth(
                backendId: backendId,
                backendStatus: .ready,
                ready: true,
                modelLoaded: true,
                cacheOk: true
            )
        }

        /// A model-backed sidecar part-way through acquiring its artifact, reporting as `backendId`.
        private static func downloadingHealth(backendId: String) -> ASRBackendHealth {
            ASRBackendHealth(
                backendId: backendId,
                backendStatus: .modelMissing,
                ready: false,
                modelLoaded: false,
                cacheOk: false,
                downloadFraction: 0.42,
                warming: nil
            )
        }

        /// Acquisition stopped and the sidecar named why. `lastAcquisitionError` is
        /// its own verdict, which the coordinator publishes on the very first probe
        /// and which outranks every inferred readout — the one branch a failure that
        /// refuses in microseconds can be observed through.
        private static let failedAcquisitionHealth = ASRBackendHealth(
            backendId: realWireBackend,
            backendStatus: .modelMissing,
            ready: false,
            modelLoaded: false,
            cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(
                code: .insufficientDiskSpace,
                detail: "needs 0.77 GB, 384 MB free"
            )
        )

        /// The two terms `mixedGlossary` adds. Their ids are fixed rather than
        /// generated: a term id is an accessibility identifier in committed
        /// goldens, and a UUID would rewrite them on every run.
        private static let taughtTerm = ProtectedTerm(
            canonical: "NeuroDock",
            spokenAliases: ["neuro dock"],
            termId: "term-neurodock",
            source: .explicitCorrection
        )
        private static let importedTerm = ProtectedTerm(
            canonical: "VoiceourBench",
            spokenAliases: [],
            protected: false,
            termId: "term-voiceourbench",
            source: .manualImport
        )

        static func settings(
            backend: String = "fake",
            glossary: [ProtectedTerm] = VoiceCore.Settings.defaultGlossary,
            preferredMicrophoneUID: String? = nil,
            preferredMicrophoneName: String? = nil,
            /// Whether this install has already completed a dictation. False on
            /// every fixture but one, because that is what a fresh install holds;
            /// the guidance card is still absent wherever a fixture has sessions.
            hasCompletedFirstRun: Bool = false,
            /// The committed island look. Stock everywhere but the Garage fixtures, which
            /// is also what every overlay golden renders.
            island: IslandAppearance = .stock,
            /// Whether new dictations fold into memory. Off everywhere but the fixture
            /// that holds memory, because off is what a fresh install holds.
            memoryEnabled: Bool = false,
            /// Whether a paste into Tern links to its agent session. Off everywhere but the
            /// menu fixtures that show the report's link line and `linkingOn`, because off is
            /// what a fresh install holds; the resolver stays `NoAgentSessionResolving` either way.
            agentSessionBindingEnabled: Bool = false
        ) -> VoiceCore.Settings {
            VoiceCore.Settings(
                asrBackend: backend,
                glossary: glossary,
                // Silence would otherwise let the metering task stop a `.recording`
                // fixture out from under the renderer.
                autoStopEnabled: false,
                preferredMicrophoneUID: preferredMicrophoneUID,
                preferredMicrophoneName: preferredMicrophoneName,
                hasCompletedFirstRun: hasCompletedFirstRun,
                island: island,
                agentSessionBindingEnabled: agentSessionBindingEnabled,
                memoryEnabled: memoryEnabled
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
            /// accident and folds the ten seeded transcripts into its totals.
            stats: DictationStatsLedger? = nil,
            /// What the memory folder holds, oldest first. Handed to the coordinator by
            /// its load closure rather than written to the scratch folder, so a scene
            /// never depends on a scratch-file write; empty is a folder never made.
            memory: [MemoryEntry] = [],
            /// The topics the memory folder's `topics.json` holds, stated the same way.
            topics: [MemoryTopic] = [],
            /// The notes the memory folder's `agents/` holds, newest modification first,
            /// stated the same way: no harness coordinator reads an `agents/` folder.
            agentNotes: [AgentNote] = []
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
                memoryLoad: { _ in MemoryLoad(entries: memory, topics: topics) },
                // Inert for the reason the History snapshot save is: a scripted turn of
                // the memory switch or a Clear Memory must not depend on a scratch-file
                // write or removal completing.
                memoryWrite: { _, _ in },
                memoryClear: { _ in },
                // The stated folder is already in the current format: a scene shows
                // memory, it never rebuilds its pages.
                memoryPagesFormat: { [stamp = MemoryPages.formatStamp(calendar: pinnedCalendar)] _ in stamp },
                // An Install Command press writes the skill into the memory folder; a
                // scene or a scripted press must write nothing there, so it lands nowhere.
                memorySkillWrite: { _ in },
                memoryAgentNotesLoad: { _ in agentNotes },
                // The default organizer stays: `NoEntryOrganizing` labels nothing and
                // reaches no network. The key source is explicit for the same reason the
                // stores are: a nil source reads this process's environment, and a golden
                // must not change with whether the developer's shell exports a key.
                typeSafeKeys: typeSafeKeys(in: scratch),
                // Fixtures keep the persistence tail inert: a scripted dictation
                // must not depend on a scratch-file write completing.
                recentSessionSnapshotSave: { _, _ in },
                audioMuter: NoOpSystemAudioMuter(),
                // Link Earlier Dictations answers from the fixture table and reads no agent's files.
                promptEvidence: promptEvidence,
                runtimeOverride: clock.runtime
            )

            // Scene fixtures resolve health before rendering so a result cannot
            // land mid-capture. A flow that scripts the Settings tab opts out and
            // gates that tab's own probe instead.
            if resolveBackendHealth {
                coordinator.refreshBackendHealth(timeoutMs: 500)
                settle { coordinator.backendHealth != nil || coordinator.backendHealthError != nil }
            }
            coordinator.isSystemAudioMuteUnavailable = muteUnavailable
            return coordinator
        }

        /// Real backend, healthy sidecar, every permission granted and the Yeti selected:
        /// the Settings page of a working install, wearing `island`. One builder, so the
        /// Garage fixtures differ from `backendReady` in their look and nothing else.
        private static func makeBackendReady(island: IslandAppearance) -> DictationCoordinator {
            make(
                sessions: history,
                settings: settings(
                    backend: realBackend,
                    preferredMicrophoneUID: "harness-usb-yeti",
                    preferredMicrophoneName: "Yeti Stereo Microphone",
                    island: island
                ),
                backend: realBackend,
                health: realBackendHealth
            )
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

        private static func makeSidecarFailure() -> DictationCoordinator {
            let coordinator = make(
                sessions: [],
                settings: settings(glossary: []),
                asrOverride: HarnessASR(
                    transcript: "",
                    backendHealth: devBackendHealth,
                    transcriptionError: .protocolError(
                        ASRErrorMessage(
                            code: .manifestMismatch, requestId: "ui-scene", detail: "Fixture model mismatch.")
                    )
                )
            )
            coordinator.start()
            settle { coordinator.state == .recording }
            coordinator.stopAndProcess()
            settle { coordinator.state == .error(.manifestMismatch) && !coordinator.isProcessingInFlight }
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

        /// The menu right after a paste into Tern, its outcome and History row stated rather
        /// than dictated: the link a resolver would have reported is fixture data on the row,
        /// and the published outcome is set the way the pipeline's `outcomeIsCurrent` block
        /// sets it. Driving a real dictation here would need a resolver that answers, which no
        /// harness coordinator may hold.
        private static func makePastedToTern(linked: Bool) -> DictationCoordinator {
            let row = session(
                index: 26,
                minutesAgo: 1,
                text: "Rerun the flow catalog and tell me which journals changed.",
                bundleId: DictationCoordinator.agentSessionHostBundleId,
                appName: ternAppName,
                captureMs: 4_600,
                asrMs: 352,
                agentSession: linked
                    ? binding(
                        .omp,
                        sessionId: agentSession.sessionId,
                        sessionFile: ompSessionFile,
                        title: agentSessionTitle,
                        minutesAgo: 1,
                        sentText: nil
                    ) : nil,
                unlinked: linked ? nil : AgentLinkMiss.focusMoved
            )
            let coordinator = make(sessions: [row], settings: settings(agentSessionBindingEnabled: true))
            coordinator.lastTranscript = row.text
            coordinator.lastOutcome = .pasteAttempted
            coordinator.lastDeliveredRowID = row.id
            coordinator.lastDeliveredApp = ternAppName
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

        /// The TypeSafe key source every harness coordinator receives: no environment
        /// at all, and a key file inside the fixture's own scratch folder, which starts
        /// absent. So a scene shows the no-key state on every Mac, and a flow that saves
        /// a key writes it where nothing outlives the process's temporary directory.
        static func typeSafeKeys(in scratch: URL) -> TypeSafeKeySource {
            TypeSafeKeySource(environment: [:], keyFile: scratch.appendingPathComponent("typesafe.key"))
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
        /// Chosen to exercise every readout at once: today and yesterday are
        /// empty, so the current streak is 0 while the longest is 6; the
        /// window's busiest day is a clear outlier, so all four heat levels
        /// appear; and 2025-06-15 is a Sunday, so the last heatmap column holds
        /// six days the calendar has not reached yet. The six app buckets sum to
        /// the same totals as the day buckets, and the sixth-ranked app is there
        /// to prove Home shows exactly five.
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
                days[dayKey(daysBeforePinnedNow: offset)] = DictationDayStat(
                    sessions: sessions,
                    words: words,
                    seconds: seconds
                )
            }
            // (bundle id, name, sessions, words, seconds, days before `pinnedNow`)
            let appRows: [(String, String, Int, Int, Double, Int)] = [
                ("com.cmuxterm.app", "cmux", 64, 12_400, 5_600, 2),
                ("com.openai.codex", "ChatGPT", 38, 6_900, 3_000, 3),
                ("com.anthropic.claudefordesktop", "Claude", 31, 5_850, 2_600, 4),
                ("com.brave.Browser", "Brave Browser", 22, 4_100, 1_900, 6),
                ("com.apple.Safari", "Safari", 18, 3_377, 1_500, 7),
                // Sixth by sessions: renders nowhere on Home.
                ("com.mitchellh.ghostty", "Ghostty", 17, 3_500, 1_720, 9),
            ]
            var apps: [String: DictationAppStat] = [:]
            for (bundleId, name, sessions, words, seconds, offset) in appRows {
                apps[bundleId] = DictationAppStat(
                    sessions: sessions,
                    words: words,
                    seconds: seconds,
                    name: name,
                    lastDay: dayKey(daysBeforePinnedNow: offset)
                )
            }
            return DictationStatsLedger(
                totalSessions: 190,
                totalWords: 36_127,
                totalSeconds: 16_320,
                totalActiveDays: 23,
                longestStreakDays: 6,
                days: days,
                apps: apps
            )
        }()

        private static func dayKey(daysBeforePinnedNow offset: Int) -> String {
            DictationStatsLedger.dayKey(
                for: pinnedNow.addingTimeInterval(-Double(offset) * 86_400),
                calendar: pinnedCalendar
            )
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

        /// Ten sessions ending at `pinnedNow`, chosen to exercise the Sessions
        /// list and search across multiple days, same-day entries, varied paste
        /// destinations, a copy-only outcome, a failed outcome, a Tern paste
        /// whose agent-session link missed and a row linked by its words.
        static let history: [RecentSession] = [
            session(
                index: 1,
                minutesAgo: 12,
                text: "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay.",
                bundleId: "com.apple.dt.Xcode",
                appName: "Xcode",
                captureMs: 6_800,
                asrMs: 410,
                // Exactly one seeded session carries either field: this is the row
                // console.sessions.selection opens, so it is the one that renders the
                // LEAST SURE row and the folded RAW row.
                rawTranscript:
                    "uh wire the offscreen renderer to NSHostingView and uh capture with cache display",
                leastConfidentWord: LeastConfidentWord(text: "cacheDisplay", score: 0.43)
            ),
            session(
                index: 2,
                minutesAgo: 95,
                text: "Accessibility children stay empty until enhanced user interface is switched on.",
                bundleId: "com.apple.dt.Xcode",
                appName: "Xcode",
                captureMs: 7_400,
                asrMs: 455
            ),
            session(
                index: 3,
                minutesAgo: 260,
                text: "Ship the contact sheet next to the manifest so a reviewer sees every pane at once.",
                bundleId: "com.tinyspeck.slackmacgap",
                appName: "Slack",
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
                appName: "Visual Studio Code",
                captureMs: 5_600,
                asrMs: 380
            ),
            // The one row linked by its words, as Link Earlier Dictations links one: found
            // later in Claude Code's own prompt log, not seen in a focused pane. No scene
            // other than console.sessions.evidence opens it, so only that one shows its line.
            session(
                index: 5,
                minutesAgo: 1_720,
                text: evidenceRowText,
                bundleId: "com.microsoft.VSCode",
                appName: "Visual Studio Code",
                captureMs: 6_200,
                asrMs: 402,
                agentSession: binding(
                    .claudeCode,
                    sessionId: "5f0c2e8a-1d3b-4c6e-9a7f-2b8d4e6f1a3c",
                    sessionFile: "/Users/harness/.claude/projects/-Users-harness-voiceour/"
                        + "5f0c2e8a-1d3b-4c6e-9a7f-2b8d4e6f1a3c.jsonl",
                    title: nil,
                    minutesAgo: 1_720,
                    sentText: nil,
                    evidence: .words
                )
            ),
            // A paste into Tern whose link missed: no binding, and the closed reason the
            // resolver gave, so the row's Details say why it is not linked. On row 6's day
            // and just older than it, so it adds no History day for Rewind to walk and never
            // pushes row 6, which the agent-link flow presses, out of the window. It is also
            // the one row `promptEvidence` finds, so Link Earlier Dictations links it.
            session(
                index: unlinkedRowIndex,
                minutesAgo: unlinkedRowMinutesAgo,
                text: unlinkedRowText,
                bundleId: DictationCoordinator.agentSessionHostBundleId,
                appName: ternAppName,
                captureMs: 5_300,
                asrMs: 371,
                unlinked: .focusMoved
            ),
            session(
                index: 6,
                minutesAgo: 2_950,
                text: "Post the mouse up before sending the mouse down or AppKit's tracking loop wedges.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureMs: 7_900,
                asrMs: 468,
                // The one row whose prompt was edited before it was sent: the comma.
                agentSession: binding(
                    .omp,
                    sessionId: agentSession.sessionId,
                    sessionFile: ompSessionFile,
                    title: agentSessionTitle,
                    minutesAgo: 2_950,
                    sentText: "Post the mouse up before sending the mouse down, or AppKit's tracking loop wedges."
                )
            ),
            session(
                index: 7,
                minutesAgo: 4_400,
                text: "Behind window vibrancy has no desktop to sample offscreen, so it renders flat.",
                bundleId: "com.apple.Safari",
                appName: "Safari",
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
                appName: "Xcode",
                captureMs: 5_100,
                asrMs: 342
            ),
            session(
                index: 9,
                minutesAgo: 11_600,
                text: "An activation policy of prohibited is the only setting that never steals focus.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureMs: 6_050,
                asrMs: 388,
                agentSession: binding(
                    .omp,
                    sessionId: agentSession.sessionId,
                    sessionFile: ompSessionFile,
                    title: agentSessionTitle,
                    minutesAgo: 11_600,
                    sentText: nil
                )
            ),
        ]

        /// The omp session two Terminal rows are bound to. Rows 1 and 4, which
        /// scenes and flows open, stay unbound, so their goldens do not carry it.
        static let agentSession = AgentSessionKey(agent: .omp, sessionId: "0190f6c2-5a1e-7c3d-9b2a-4e8f1d2c3b4a")

        /// The title `agentSession` carries on every row and entry bound to it.
        nonisolated static let agentSessionTitle = "Harness offscreen capture"

        /// The name Tern's rows carry, and the app the menu fixtures' paste went to.
        nonisolated static let ternAppName = "Tern"

        /// The text of the Tern row whose link missed: the only handle a scene step has on
        /// its closed row, so no other row or entry says it. It says neither "offscreen" nor
        /// "accessibility", so the Rewind and History searches keep their counts.
        nonisolated static let unlinkedRowText = "Split the timeout from the quiet period so a retry reads as honest."

        /// The Tern row whose link missed, as `history` places it, so the evidence table
        /// below names the same row and the same delivery time.
        private static let unlinkedRowIndex = 25
        private static let unlinkedRowMinutesAgo = 3_000

        /// The text of the row linked by its words: the only handle `console.sessions.evidence`
        /// has on its closed row, which no other row or entry says.
        nonisolated static let evidenceRowText =
            "Pump the run loop a fixed number of iterations, never until it looks settled."

        /// The prompt logs a harness Link Earlier Dictations run reads, as a table: the Tern
        /// row whose link missed was found in the fixture's omp session 40 s after it was
        /// delivered. Every other row is absent, so a run on `history` links one and counts
        /// the rest as not found. No `sessionFile`, so the landing's existence check touches
        /// no path.
        static var promptEvidence: HarnessPromptEvidence {
            let deliveredAt = pinnedNow.addingTimeInterval(-Double(unlinkedRowMinutesAgo) * 60)
            return HarnessPromptEvidence(table: [
                fixedIdentifier(unlinkedRowIndex): PromptEvidenceMatch(
                    agent: agentSession.agent,
                    sessionId: agentSession.sessionId,
                    sentAt: deliveredAt.addingTimeInterval(40),
                    sessionFile: nil,
                    workingDirectory: "/Users/harness/voiceour",
                    title: agentSessionTitle
                )
            ])
        }

        private static let ompSessionFile =
            "/Users/harness/.omp/agent/sessions/-Users-harness-voiceour/"
            + "2025-06-07T13-40-12-512Z_0190f6c2-5a1e-7c3d-9b2a-4e8f1d2c3b4a.jsonl"

        /// A binding made when its row was recorded, to a resumable session that
        /// sent the dictation 40 s later.
        private static func binding(
            _ agent: CodingAgent,
            sessionId: String,
            sessionFile: String,
            title: String?,
            minutesAgo: Int,
            sentText: String?,
            evidence: AgentLinkEvidence = .pane
        ) -> AgentSessionBinding {
            let boundAt = pinnedNow.addingTimeInterval(-Double(minutesAgo) * 60)
            return AgentSessionBinding(
                agent: agent,
                sessionId: sessionId,
                sessionFile: sessionFile,
                workingDirectory: "/Users/harness/voiceour",
                sessionTitle: title,
                boundAt: boundAt,
                promptLogOffset: 0,
                resumable: true,
                send: .sent(sentAt: boundAt.addingTimeInterval(40), text: sentText),
                evidence: evidence
            )
        }

        private static func session(
            index: Int,
            minutesAgo: Int,
            text: String,
            bundleId: String,
            appName: String,
            disposition: RecentSessionInsertionDisposition = .pasteAttempted,
            reason: String? = nil,
            captureMs: Int,
            asrMs: Int,
            /// Nil means cleanup changed nothing, which is the case that draws no RAW row.
            rawTranscript: String? = nil,
            leastConfidentWord: LeastConfidentWord? = nil,
            agentSession: AgentSessionBinding? = nil,
            unlinked: AgentLinkMiss? = nil
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
                    targetBundleId: bundleId,
                    targetAppName: appName
                ),
                rawTranscript: rawTranscript ?? text,
                stages: SessionStageTimings(
                    captureMs: captureMs,
                    asrMs: asrMs,
                    insertMs: 24,
                    startLatencyMs: 18
                ),
                leastConfidentWord: leastConfidentWord,
                agentSession: agentSession,
                unlinked: unlinked
            )
        }

        // MARK: Fixed memory

        /// What the `remembered` fixture's memory folder holds, oldest first: twelve
        /// dictations and three notes older than every History row, then the ten History
        /// rows under their History ids, as turning the memory switch on would have kept them.
        static let rememberedMemory: [MemoryEntry] =
            (olderMemory + rememberedNotes).sorted { $0.createdAt < $1.createdAt }
            + history.reversed().map { MemoryEntry($0) }

        /// The day `console.sessions.rewind.memory` opens Rewind on: 2025-05-28, older
        /// than every History row, holding a morning run in the omp session, a Slack
        /// dictation, a note, the same session again that afternoon as a continued block,
        /// and a second note that evening as a continued Notes block.
        static let rememberedDay = startOfDay(daysBeforePinnedNow: 18)

        /// A word exactly one remembered note holds, in its text and nowhere in the omp
        /// session's title or project, so a Notes search on it leaves one row.
        static let rememberedNoteQuery = "cable"

        /// The three notes' texts, newest first, the order the Notes lens lists them in.
        static let rememberedNoteTexts: [String] =
            rememberedNotes
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.text)

        /// The day `console.sessions.rewind.highlights` opens Rewind on: 2025-05-20, where
        /// four entries carry a confident highlight kind (an idea, a decision, a to-do and
        /// a note's question), so the day leads with Highlights. No other day holds a
        /// highlight kind at or above `JournalQuery.highlightConfidence`, so the other
        /// Rewind goldens keep their shape.
        static let labelledDay = startOfDay(daysBeforePinnedNow: 26)

        /// The three topics the `remembered` folder's `topics.json` holds, in the order
        /// they were made. Their ids are the slugs `TopicCatalog` gives their names.
        static let rememberedTopics: [MemoryTopic] = [memoryFolderTopic, harnessTopic, planningTopic]

        /// The topic with the most entries, so it leads the Topics list and is the row
        /// `console.sessions.topics.open` presses. Seven entries count under it: five by a
        /// confident label, one the user filed by hand over a label that named another
        /// topic, and one note the model labelled.
        static let memoryFolderTopic = MemoryTopic(
            id: "memory-folder",
            name: "Memory folder",
            summary: "How memory is kept on disk and read back.",
            createdAt: startOfDay(daysBeforePinnedNow: 27)
        )

        /// Three entries, each by a confident label.
        static let harnessTopic = MemoryTopic(
            id: "offscreen-harness",
            name: "Offscreen harness",
            summary: "Rendering and checking the app without a window on screen.",
            createdAt: startOfDay(daysBeforePinnedNow: 27)
        )

        /// Two entries: one by a confident label, and a note the user filed by hand.
        static let planningTopic = MemoryTopic(
            id: "planning",
            name: "Planning",
            summary: "Meetings, schedules and what comes next.",
            createdAt: startOfDay(daysBeforePinnedNow: 19)
        )

        /// The texts that count under `memoryFolderTopic`, oldest first, by the rule the
        /// Topics lens applies, so a flow checks the open page against the fixture itself.
        static let memoryFolderTexts: [String] = {
            let known = Set(rememberedTopics.map(\.id))
            return
                rememberedMemory
                .filter { $0.effectiveTopicID(known: known) == memoryFolderTopic.id }
                .map(\.text)
        }()

        /// What the `remembered` folder's `agents/` holds, newest modification first, as
        /// `MemoryStore.loadAgentNotes()` would hand it over: the omp session's outcome,
        /// then the synthesis of `memoryFolderTopic`, saved the morning after the recap of
        /// `rememberedDay`. So `console.sessions.rewind.memory` and
        /// `console.sessions.topics.open` each show one note under "From your agents", and
        /// the omp thread's page one under "From the session", without a step. No body
        /// repeats an entry's text, so a flow that finds an entry by its text never finds a
        /// note as well.
        static let rememberedAgentNotes: [AgentNote] = [
            agentSessionOutcome, memoryFolderSynthesis, rememberedDayRecap,
        ]

        /// The day of the omp thread's newest entry, History row 6 on 2025-06-13: the day
        /// the outcome prompt names, so the note the fixture's agent saved names it too.
        static let agentSessionLastDay = startOfDay(daysBeforePinnedNow: 2)

        /// The omp agent's account of what came of the work in `agentSession`, saved as
        /// the outcome prompt asks: under the thread's file stem, keyed to it by `session`,
        /// dated the thread's newest day. Saved that evening, after the thread's last entry,
        /// so it is the newest note in the folder.
        static let agentSessionOutcome = AgentNote(
            id: "\(MemoryPages.threadFileStem(agentSession)).md",
            author: "omp",
            title: "What came of the harness work",
            day: DictationStatsLedger.dayKey(for: agentSessionLastDay, calendar: pinnedCalendar),
            session: MemoryPages.threadFileStem(agentSession),
            body: "The capture run finishes now; the event order was the cause. "
                + "Still open: whether a thread page should name its pane. "
                + "Needed from you: the release this fix ships in.",
            modifiedAt: agentSessionLastDay.addingTimeInterval(18 * 3_600 + 40 * 60)
        )

        /// An agent's recap of `rememberedDay`, saved that evening after the day's last note.
        static let rememberedDayRecap = AgentNote(
            id: "2025-05-28-recap.md",
            author: "omp",
            title: "Wednesday recap",
            day: DictationStatsLedger.dayKey(for: rememberedDay, calendar: pinnedCalendar),
            body: "The morning settled how memory stores what was said. "
                + "The planning call moved so the memory review can come first.",
            modifiedAt: rememberedDay.addingTimeInterval(21 * 3_600 + 5 * 60)
        )

        /// An agent's synthesis of `memoryFolderTopic`, the topic
        /// `console.sessions.topics.open` presses open.
        static let memoryFolderSynthesis = AgentNote(
            id: "memory-folder-synthesis.md",
            author: "omp",
            title: "Where the memory folder stands",
            topicID: memoryFolderTopic.id,
            body: "Month files hold what was said, and every page is rebuilt from them. "
                + "Still open: how a page should credit what an agent wrote.",
            modifiedAt: startOfDay(daysBeforePinnedNow: 17).addingTimeInterval(9 * 3_600 + 30 * 60)
        )

        /// Twelve dictations History no longer holds, over three days in two calendar
        /// months, so Rewind steps past History's oldest day and a month boundary, and
        /// the omp thread holds entries older than any History row. Some went into the
        /// fixture's omp session, one of them never sent; the rest went to apps.
        ///
        /// Eleven carry a label. Two sit just under a threshold: entry 13's topic at 0.42,
        /// which the user's own filing overrides anyway, and entry 14's decision at 0.55,
        /// so 2025-05-28 shows no highlight and its row no mark.
        private static let olderMemory: [MemoryEntry] = [
            // 2025-05-20, a Tuesday.
            remembered(
                index: 10,
                daysAgo: 26,
                at: (13, 10, 4),
                text: "Sketch a journal that remembers more than the last thirty days.",
                bundleId: "com.microsoft.VSCode",
                appName: "Visual Studio Code",
                captureSeconds: 4.8,
                label: jevLabel(.idea, 0.82, topic: memoryFolderTopic.id, 0.72)
            ),
            remembered(
                index: 11,
                daysAgo: 26,
                at: (13, 22, 37),
                text: "One JSON file per month keeps a year of dictation easy to read.",
                bundleId: "com.microsoft.VSCode",
                appName: "Visual Studio Code",
                captureSeconds: 5.4,
                label: jevLabel(.decision, 0.91, topic: memoryFolderTopic.id, 0.88)
            ),
            remembered(
                index: 12,
                daysAgo: 26,
                at: (17, 45, 12),
                text: "Compare how other dictation apps store transcripts on disk.",
                bundleId: "com.apple.Safari",
                appName: "Safari",
                captureSeconds: 4.1,
                // The model answered "none" for the topic, and was sure of it.
                label: jevLabel(.todo, 0.77, topic: nil, 0.8)
            ),
            remembered(
                index: 13,
                daysAgo: 26,
                at: (18, 2, 50),
                text: "Start an agent session to draft the memory folder layout.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 4.4,
                thread: ompThread(sent: false),
                label: jevLabel(.instruction, 0.7, topic: harnessTopic.id, 0.42),
                userTopicID: memoryFolderTopic.id
            ),
            // 2025-05-28, a Wednesday.
            remembered(
                index: 14,
                daysAgo: 18,
                at: (9, 15, 21),
                text: "Memory keeps every dictation verbatim; a model only labels what I said.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 5.9,
                thread: ompThread(sent: true),
                label: jevLabel(.decision, 0.55, topic: memoryFolderTopic.id, 0.86)
            ),
            remembered(
                index: 15,
                daysAgo: 18,
                at: (9, 40, 8),
                text: "The month file is the source of truth and every page is derived from it.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 6.3,
                thread: ompThread(sent: true),
                label: jevLabel(.observation, 0.8, topic: memoryFolderTopic.id, 0.81)
            ),
            remembered(
                index: 16,
                daysAgo: 18,
                at: (11, 5, 46),
                text: "Moving the planning call to Thursday so the memory review can land first.",
                bundleId: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                captureSeconds: 5.7,
                label: jevLabel(.observation, 0.7, topic: planningTopic.id, 0.83)
            ),
            remembered(
                index: 17,
                daysAgo: 18,
                at: (16, 30, 19),
                text: "Clear History must leave the memory folder exactly as it was.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 4.9,
                thread: ompThread(sent: true),
                label: jevLabel(.instruction, 0.74, topic: memoryFolderTopic.id, 0.69)
            ),
            // 2025-06-03, a Tuesday: the newest day older than every History row.
            remembered(
                index: 18,
                daysAgo: 12,
                at: (10, 2, 33),
                text: "Pin the memory folder path in Diagnostics the same way the other storage paths are pinned.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 6.6,
                thread: ompThread(sent: true),
                label: jevLabel(.instruction, 0.8, topic: harnessTopic.id, 0.78)
            ),
            remembered(
                index: 19,
                daysAgo: 12,
                at: (10, 9, 58),
                text: "A scene must never wait on a scratch file write to finish.",
                bundleId: "com.apple.Terminal",
                appName: "Terminal",
                captureSeconds: 4.7,
                thread: ompThread(sent: true),
                label: jevLabel(.observation, 0.71, topic: harnessTopic.id, 0.93)
            ),
            remembered(
                index: 20,
                daysAgo: 12,
                at: (15, 20, 14),
                text: "Rewind groups a day into runs of one subject, split by a half hour pause.",
                bundleId: "com.apple.dt.Xcode",
                appName: "Xcode",
                captureSeconds: 5.8
            ),
            remembered(
                index: 21,
                daysAgo: 12,
                at: (15, 31, 40),
                text: "Keep the older days in the fixture, not in the golden.",
                bundleId: "com.apple.dt.Xcode",
                appName: "Xcode",
                captureSeconds: 4.2,
                label: jevLabel(.instruction, 0.62, topic: harnessTopic.id, 0.65)
            ),
        ]

        /// Three notes on two days: one taken in the fixture's omp session on 2025-05-20,
        /// and two with no session on 2025-05-28, an afternoon apart, so the Notes lens has
        /// two day groups and Rewind's memory day has a Notes block and its continuation.
        /// A note has no send check, so the omp note's `sent` stays nil. The omp note is
        /// the labelled day's question; the first 2025-05-28 note is filed by hand.
        private static let rememberedNotes: [MemoryEntry] = [
            rememberedNote(
                index: 22,
                daysAgo: 26,
                at: (18, 20, 5),
                text: "Ask whether month files should sort their keys before every write.",
                captureSeconds: 3.9,
                thread: ompThread(sent: nil),
                label: jevLabel(.question, 0.84, topic: memoryFolderTopic.id, 0.9)
            ),
            rememberedNote(
                index: 23,
                daysAgo: 18,
                at: (12, 48, 30),
                text: "Buy a spare charging cable before the Thursday planning call.",
                captureSeconds: 3.2,
                userTopicID: planningTopic.id
            ),
            rememberedNote(
                index: 24,
                daysAgo: 18,
                at: (19, 12, 44),
                text: "Read a long thread page aloud once to hear how it sounds.",
                captureSeconds: 3.6
            ),
        ]

        /// The fixture's omp session as a memory entry records it, under the title and
        /// directory its History rows carry, so the thread reads as one session.
        private static func ompThread(sent: Bool?) -> JournalThreadRef {
            JournalThreadRef(
                agent: agentSession.agent,
                sessionId: agentSession.sessionId,
                title: agentSessionTitle,
                workingDirectory: "/Users/harness/voiceour",
                resumable: true,
                sent: sent
            )
        }

        /// A label as the sorting model answers one: a kind and a topic, each with its
        /// confidence, stamped with the shipping model id and the pinned instant. A nil
        /// topic is the model's "none".
        private static func jevLabel(
            _ kind: UtteranceKind,
            _ kindConfidence: Double,
            topic: String?,
            _ topicConfidence: Double
        ) -> EntryLabel {
            EntryLabel(
                kind: kind,
                kindConfidence: kindConfidence,
                topicID: topic,
                topicConfidence: topicConfidence,
                model: OrganizerPolicy.model,
                labeledAt: pinnedNow
            )
        }

        private static func remembered(
            index: Int,
            daysAgo: Int,
            at time: (hour: Int, minute: Int, second: Int),
            text: String,
            bundleId: String,
            appName: String,
            captureSeconds: Double,
            thread: JournalThreadRef? = nil,
            label: EntryLabel? = nil,
            userTopicID: String? = nil
        ) -> MemoryEntry {
            MemoryEntry(
                id: fixedIdentifier(index),
                createdAt: startOfDay(daysBeforePinnedNow: daysAgo)
                    .addingTimeInterval(Double(time.hour * 3_600 + time.minute * 60 + time.second)),
                text: text,
                appBundleId: bundleId,
                appName: appName,
                thread: thread,
                captureSeconds: captureSeconds,
                userTopicID: userTopicID,
                label: label
            )
        }

        /// A note as memory keeps it: delivered nowhere, so it names no app.
        private static func rememberedNote(
            index: Int,
            daysAgo: Int,
            at time: (hour: Int, minute: Int, second: Int),
            text: String,
            captureSeconds: Double,
            thread: JournalThreadRef? = nil,
            label: EntryLabel? = nil,
            userTopicID: String? = nil
        ) -> MemoryEntry {
            MemoryEntry(
                id: fixedIdentifier(index),
                createdAt: startOfDay(daysBeforePinnedNow: daysAgo)
                    .addingTimeInterval(Double(time.hour * 3_600 + time.minute * 60 + time.second)),
                kind: .note,
                text: text,
                thread: thread,
                captureSeconds: captureSeconds,
                userTopicID: userTopicID,
                label: label
            )
        }

        /// Midnight `offset` days before the pinned day, in the pinned calendar. Whole
        /// days of seconds are exact here because the pinned time zone is UTC, which
        /// has no daylight-saving shift for a day to lose or gain an hour to.
        private static func startOfDay(daysBeforePinnedNow offset: Int) -> Date {
            pinnedCalendar.startOfDay(for: pinnedNow).addingTimeInterval(-Double(offset) * 86_400)
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
