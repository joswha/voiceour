import Combine
import Foundation
import Observation
import VoiceCore
import VoiceMac

/// Publishes the microphone input level and capture-live flag, which update at
/// the metering cadence (25Hz while recording). These live on a dedicated
/// `ObservableObject` rather than directly on `DictationCoordinator` because a
/// publish there invalidates all ~12 console view bodies observing the
/// coordinator, none of which display these values: the metering tick alone
/// would force a whole-tree re-render 25 times a second during recording. It is
/// Combine-published because its sole consumer is the AppKit-side recording
/// overlay controller.
@MainActor
public final class AudioLevelMeter: ObservableObject {
    @Published public private(set) var level: Float = 0
    @Published public private(set) var live: Bool = false

    func update(level: Float) {
        self.level = level
    }

    func setLive(_ live: Bool) {
        self.live = live
    }

    func reset() {
        level = 0
        live = false
    }
}

@Observable @MainActor
public final class DictationCoordinator {
    public internal(set) var state: SessionState = .idle {
        didSet {
            stateSubject.send(state)
            // Escape belongs to the focused app at every other moment, so the
            // binder only claims it while the overlay is on screen.
            hotkey.setCancelArmed(state.isActive)
        }
    }
    public var settings: VoiceCore.Settings
    public private(set) var targetLabel: String = "No target"
    public internal(set) var lastOutcome: InsertionOutcome?
    public internal(set) var lastTranscript: String = ""
    /// The last failure's plain-language cause, for surfaces that show one line.
    public internal(set) var errorMessage: String?
    /// The same failure with its title, retry-ability and destination, for the menu
    /// row that has to offer an action rather than just a sentence.
    public internal(set) var lastFailure: UserFacingDictationFailure?
    /// Surface-local refusals for the Glossary tab — a collision, a bad word
    /// list. Never read by the menu: a glossary refusal is not a dictation
    /// failure, and one crimson headline cannot serve both. `start()` does not
    /// clear it; the next glossary action does.
    public internal(set) var glossaryNotice: String?
    public private(set) var backendHealth: ASRBackendHealth?
    public private(set) var backendHealthError: String?
    public internal(set) var recentSessions: [RecentSession] = []
    /// Lifetime dictation counts, published for the Home tab. Aggregates only:
    /// the transcripts themselves live in `recentSessions`, which is capped.
    public internal(set) var dictationStats = DictationStatsLedger()
    public internal(set) var isSystemAudioMuted: Bool = false
    /// True when the last capture asked for a mute the output device could not
    /// provide. Sticky until the next capture answers the question again.
    public internal(set) var isSystemAudioMuteUnavailable: Bool = false
    public internal(set) var pendingSuggestions: [TermSuggestion] = []
    public private(set) var isProcessingInFlight: Bool = false

    private let stateSubject = CurrentValueSubject<SessionState, Never>(.idle)
    public var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Dedicated meter for the 25Hz input-level / capture-live stream; see
    /// `AudioLevelMeter`.
    public let inputMeter = AudioLevelMeter()

    let recorder: AudioRecording
    let asr: ASRClienting
    let tracker: TargetTracking
    let inserter: TextInserting
    private let permissions: PermissionsChecking
    private let hotkey: HotkeyBinding
    private let settingsStore: SettingsStore
    let recentSessionStore: RecentSessionStore
    let recentSessionSnapshotSave: @Sendable (RecentSessionStore, [RecentSession]) throws -> Void
    let dictationStatsStore: DictationStatsStore
    let audioMuter: SystemAudioMuting
    let sessionCues: SessionCuePlaying
    let temporaryAudioRemover: @Sendable (URL) throws -> Void
    let runtime: DictationRuntime
    private let activeASRBackend: String
    /// The artifact the running sidecar was launched with, as opposed to
    /// `settings.asrModelVariant`, which is what the next launch will use. Keeping both is what
    /// lets Settings say a selection needs a restart instead of lying about what is loaded.
    private let activeVariant: ASRModelVariant
    var inputMeteringTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingTaskIdentity: UUID?
    var suggestionTask: Task<Void, Never>?
    private var backendHealthTask: Task<Void, Never>?
    /// Repoll chain that runs only while the backend is downloading or warming.
    private var backendAcquisitionPollTask: Task<Void, Never>?
    /// Guards refreshBackendHealth against duplicate sidecar probes: skip a
    /// fresh probe while one is in flight or within backendHealthTTL of the
    /// last completion. Settings probes from `onAppear` on every entry and the
    /// menu probes when it opens, so bare switches would otherwise fan out dupes.
    private var backendHealthProbeInFlight = false
    private var backendHealthLastRefresh: Date?
    private let backendHealthTTL: TimeInterval = 5
    /// Generation counters for async work a newer request supersedes. One
    /// primitive with named scopes, so every guard on the stop path compares a
    /// token against its own scope rather than a hand-compared `Int`.
    var generations = AsyncGenerationGate()
    var isPreparingForTermination = false
    /// FIFO tail for complete recent-session snapshots. Each detached element
    /// contains its own failure so one bad write cannot poison later work.
    var recentSessionPersistenceTail: Task<Bool, Never>?
    private var isCancellingRecording = false
    /// FIFO chain for muter operations; see enqueueMuteOperation.
    var muteOperationChain: Task<Void, Never>?
    /// The in-flight mute decision for the newest recording session; the stop
    /// path awaits it so session metadata records the true muted state.
    var pendingMuteResult: Task<Bool, Never>?
    /// This session's single system-audio restore, created by whichever path
    /// claims it first. Every later caller awaits *this* task rather than
    /// starting another.
    ///
    /// A bare Boolean is not enough. It would let a terminating path observe
    /// "already claimed" and return while a cancel's restore was still in
    /// flight, and `applicationShouldTerminate` calls `Darwin.exit` the moment
    /// `prepareForTermination()` returns — leaving the user's audio muted until
    /// the next launch recovered durable ownership.
    ///
    /// Also deliberately not keyed on `isSystemAudioMuted`: that is published UI
    /// state, set only after the mute task resolves, so during the window where
    /// the device is already muted but the flag has not been published a
    /// guard on it skipped the restore entirely.
    var systemAudioRestore: Task<Void, Never>?

    public init(
        recorder: AudioRecording,
        asr: ASRClienting,
        tracker: TargetTracking,
        inserter: TextInserting,
        permissions: PermissionsChecking,
        hotkey: HotkeyBinding,
        settings: VoiceCore.Settings = VoiceCore.Settings(),
        activeASRBackend: String? = nil,
        activeModelVariant: ASRModelVariant? = nil,
        settingsStore: SettingsStore = SettingsStore(),
        recentSessionStore: RecentSessionStore = RecentSessionStore(),
        dictationStatsStore: DictationStatsStore = DictationStatsStore(),
        recentSessionSnapshotSave: @escaping @Sendable (RecentSessionStore, [RecentSession]) throws -> Void = {
            store, sessions in
            try store.save(sessions)
        },
        audioMuter: SystemAudioMuting = NoOpSystemAudioMuter(),
        sessionCues: SessionCuePlaying = NoOpSessionCuePlayer(),
        temporaryAudioRemover: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        },
        runtimeOverride: DictationRuntime? = nil
    ) {
        self.recorder = recorder
        self.asr = asr
        self.tracker = tracker
        self.inserter = inserter
        self.permissions = permissions
        self.hotkey = hotkey
        self.settings = settings
        self.activeASRBackend = activeASRBackend ?? settings.asrBackend
        self.activeVariant = activeModelVariant ?? settings.asrModelVariant
        self.settingsStore = settingsStore
        self.recentSessionStore = recentSessionStore
        self.recentSessionSnapshotSave = recentSessionSnapshotSave
        self.dictationStatsStore = dictationStatsStore
        self.audioMuter = audioMuter
        self.sessionCues = sessionCues
        self.temporaryAudioRemover = temporaryAudioRemover
        self.runtime = runtimeOverride ?? .live
        // Two durable files, both moved aside rather than overwritten when they
        // cannot be read: the next snapshot would otherwise replace them with
        // empty state and destroy whatever was still recoverable. `errorMessage`
        // is set below, after the hotkey wiring, because the property is only
        // meaningful once the coordinator exists.
        var loadFailure: String?
        do {
            self.recentSessions = try recentSessionStore.load()
        } catch {
            self.recentSessions = []
            let moved = quarantineUnreadableVoiceourState(at: recentSessionStore.url)
            loadFailure =
                moved.map { "Dictation history could not be read — kept as \($0.lastPathComponent)." }
                ?? "Dictation history could not be read and could not be set aside."
        }
        let statsFileExisted = FileManager.default.fileExists(atPath: dictationStatsStore.url.path)
        do {
            self.dictationStats = try dictationStatsStore.load()
        } catch {
            self.dictationStats = DictationStatsLedger()
            let moved = quarantineUnreadableVoiceourState(at: dictationStatsStore.url)
            // Never overwrite a history quarantine already reported above: two
            // corrupt files is one launch, one line, and the transcripts are the
            // loss worth naming.
            loadFailure =
                loadFailure
                ?? moved.map { "Dictation stats could not be read — kept as \($0.lastPathComponent)." }
                ?? "Dictation stats could not be read and could not be set aside."
        }
        // One-time migration: durable state of two deleted subsystems. Left on
        // disk, the retired `dictation-stats.json` is a per-day, per-app record
        // of every dictation — with transcript quotes in it — that no surface can
        // show or clear, and `omp-rpc/` is a credential-adjacent home directory
        // for a refiner subprocess this build never spawns. The lifetime ledger
        // this build keeps is a different, smaller file (see
        // `DictationStatsStore`), so this sweep stays. Removal is best-effort and
        // silent: neither is load-bearing, and a failure must not cost a launch.
        let supportDirectory = recentSessionStore.url.deletingLastPathComponent()
        for retired in ["dictation-stats.json", "omp-rpc"] {
            try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent(retired))
        }
        self.hotkey.onToggle { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        self.hotkey.onCancel { [weak self] in
            Task { @MainActor in
                // The armed flag is a cached mirror of `state`; re-check it here so a
                // session that ended between the keypress and this hop is not "cancelled"
                // from idle, which would flash a spurious Cancelled state.
                guard let self, self.state.isActive else { return }
                self.cancel()
            }
        }
        self.errorMessage = loadFailure
        // First launch with a ledger: seed it from the transcripts still on
        // disk, so a reader who has been dictating for months does not open Home
        // to a zero. The journal is capped at 500 rows, so this recovers a
        // partial history and every dictation after it is counted exactly once.
        if !statsFileExisted {
            backfillDictationStats()
        } else if dictationStats.totalSessions > 0 && dictationStats.apps.isEmpty {
            // A ledger written before per-app tallies existed. Seed just the app
            // buckets from the transcripts still on disk; the totals in the file
            // already counted these sessions. `totalSessions > 0` keeps the
            // quarantine path above — which deliberately does not backfill
            // totals — from ranking apps against zeroed tiles.
            backfillAppStats()
        }
        refreshTarget()
    }

    public var activeBackend: String { activeASRBackend }
    public var activeModelVariant: ASRModelVariant { activeVariant }

    /// Fraction of the pinned model this backend has downloaded, or nil when no
    /// acquisition is in flight. Read by the menu as well as the console: a 1.26 GB
    /// download that is only visible on one settings tab looks like a hung app.
    public var modelDownloadFraction: Double? {
        backendHealth?.downloadFraction
    }

    /// True while the backend is loading the model and compiling pipelines.
    public var isBackendWarming: Bool {
        backendHealth?.warming == true
    }

    /// Why the backend cannot serve dictation, in the user's terms, or nil when it
    /// can. Fed by the health probe and by `warmUp()`, whose failure has nowhere
    /// else to surface: a download that cannot start would otherwise leave the app
    /// looking idle while every dictation failed with a raw code.
    public internal(set) var acquisitionFailure: UserFacingDictationFailure?

    /// Starts the model acquisition the first dictation would otherwise wait for,
    /// and keeps the readout moving while it runs.
    public func warmUpBackend() {
        let asr = asr
        Task { [weak self] in
            await asr.warmUp()
            await MainActor.run {
                guard let self else { return }
                // `warmUp` cannot throw through the port, so its outcome is read from
                // the health probe that follows it.
                self.refreshBackendHealth(force: true)
            }
        }
    }

    enum AcquisitionChange: Equatable {
        case none
        /// Acquisition was running and stopped without producing a cache.
        case downloadFailed(detail: String?)
        /// The sidecar did not answer at all and no cached model exists.
        case unreachable(detail: String?)
        case cleared
    }

    /// Pure so the rules are testable without a sidecar. The wire carries no error
    /// string for a failed download: `ParakeetSidecarBackend.warmUp` resets
    /// `downloadFraction` and `warming` in a `defer`, so a failed download is the
    /// transition "was acquiring, now neither, cache still absent". A probe that
    /// never answered is a different fault — nothing was downloading, the engine
    /// is simply not there — and must not read as a failed download.
    static func acquisitionTransition(
        previous: ASRBackendHealth?,
        current: ASRBackendHealth?,
        transportError: String?
    ) -> AcquisitionChange {
        if let current {
            if current.cacheOk || current.downloadFraction != nil || current.warming == true {
                return .cleared
            }
            let wasAcquiring = previous?.downloadFraction != nil || previous?.warming == true
            if wasAcquiring && !current.cacheOk { return .downloadFailed(detail: nil) }
            return .none
        }
        // Transport failure: only a fault when the model is not already on disk.
        if let transportError, previous?.cacheOk != true {
            return .unreachable(detail: transportError)
        }
        return .none
    }

    /// One mapping from transition to published failure, shared by both probe
    /// completions. `.unreachable` reuses the wire's `backend_unavailable` row so
    /// Settings, the menu and the diagnostics report all say ENGINE OFFLINE with
    /// one vocabulary rather than blaming a download that never ran.
    private func applyAcquisitionTransition(_ change: AcquisitionChange) {
        switch change {
        case .downloadFailed(let detail):
            acquisitionFailure = .acquisitionFailed(detail: detail)
        case .unreachable(let detail):
            acquisitionFailure = UserFacingDictationFailure(code: .backendUnavailable, detail: detail)
        case .cleared:
            acquisitionFailure = nil
        case .none:
            break
        }
    }

    public func refreshBackendHealth(timeoutMs: Int = 3_000, force: Bool = false) {
        // Collapse duplicate probes: `onAppear` fires this on every entry to the
        // Settings tab, and the menu fires it when it opens. Skip while a probe is
        // in flight, or if the last completion (success or failure) landed within
        // the TTL. `force` is the acquisition repoll, whose whole job is to beat it.
        if backendHealthProbeInFlight { return }
        if !force, let last = backendHealthLastRefresh,
            runtime.now().timeIntervalSince(last) < backendHealthTTL
        {
            return
        }
        backendHealthProbeInFlight = true
        backendHealthTask?.cancel()
        backendHealthError = nil
        let asr = asr
        backendHealthTask = Task { [weak self] in
            do {
                let health = try await asr.health(timeoutMs: timeoutMs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    let previous = self?.backendHealth
                    self?.backendHealth = health
                    self?.backendHealthError = nil
                    self?.backendHealthLastRefresh = self?.runtime.now()
                    self?.backendHealthProbeInFlight = false
                    self?.applyAcquisitionTransition(
                        Self.acquisitionTransition(previous: previous, current: health, transportError: nil)
                    )
                    self?.scheduleAcquisitionRepollIfNeeded(health)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    let previous = self?.backendHealth
                    self?.backendHealth = nil
                    self?.backendHealthError = String(describing: error)
                    self?.backendHealthLastRefresh = self?.runtime.now()
                    self?.backendHealthProbeInFlight = false
                    self?.applyAcquisitionTransition(
                        Self.acquisitionTransition(
                            previous: previous, current: nil, transportError: String(describing: error)
                        )
                    )
                    self?.backendAcquisitionPollTask?.cancel()
                    self?.backendAcquisitionPollTask = nil
                }
            }
        }
    }

    /// Keeps the readiness readout moving while the backend downloads or warms.
    ///
    /// A percentage that only advances when the user re-enters the Settings tab is not progress
    /// reporting. The chain stops on its own the moment neither condition holds, so a resting
    /// backend costs nothing.
    private func scheduleAcquisitionRepollIfNeeded(_ health: ASRBackendHealth) {
        guard health.downloadFraction != nil || health.warming == true else {
            backendAcquisitionPollTask?.cancel()
            backendAcquisitionPollTask = nil
            return
        }
        guard backendAcquisitionPollTask == nil else { return }
        let runtime = runtime
        backendAcquisitionPollTask = Task { [weak self] in
            // The injectable runtime sleep, never a raw Task.sleep: the flow harness pins it.
            try? await runtime.sleep(2_000_000_000)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.backendAcquisitionPollTask = nil
                self.refreshBackendHealth(force: true)
            }
        }
    }

    public static func live() -> DictationCoordinator {
        Task.detached(priority: .utility) {
            RecordingScavenger.sweep(directory: CaptureTemporaryFile.directory)
        }

        let store = SettingsStore()
        // A settings file that cannot be decoded is moved aside rather than
        // silently replaced: it holds the user's glossary, and the first
        // `saveSettings()` after this would overwrite it with defaults.
        var settingsFailure: String?
        var settings: VoiceCore.Settings
        do {
            settings = try store.load()
        } catch {
            settings = VoiceCore.Settings()
            let moved = quarantineUnreadableVoiceourState(at: store.url)
            settingsFailure =
                moved.map {
                    "Settings could not be read — reset to defaults, old file kept as \($0.lastPathComponent)."
                }
                ?? "Settings could not be read — reset to defaults."
        }
        let launchOptions = VoiceCore.LaunchOptions(arguments: CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment

        let registry = ASRBackendRegistry.builtIn
        let backend =
            launchOptions.asrBackend
            ?? VoiceCore.LaunchOptions.validBackend(env["VOICEOUR_ASR_BACKEND"], validBackendIDs: registry.backendIDs)
            ?? VoiceCore.LaunchOptions.persistedBackend(
                settings.asrBackend,
                validBackendIDs: registry.backendIDs,
                allowsDevBackend: LaunchOptions.showsDebugPanes
            )
            ?? registry.defaultDescriptor.id
        settings.asrBackend = backend

        let permissions = SystemPermissions()
        let tracker = WorkspaceTargetTracker()
        // The environment override exists for the same reason the backend has one: a benchmark
        // or a harness run must be able to pin the artifact without editing the user's settings.
        let modelVariant = ASRModelVariant.resolved(
            env[ASRModelVariant.environmentKey] ?? settings.asrModelVariant.rawValue
        )
        let components = registry.liveComponents(
            for: backend,
            context: ASRBackendContext(
                sidecarExecutableURL: ASRBackendContext.siblingSidecarURL(),
                modelVariant: modelVariant
            )
        )
        let recorder = components.recorder
        let asr = components.client
        let inserter = PasteboardInserter(permissions: permissions, tracker: tracker)
        let audioMuter: SystemAudioMuting =
            components.usesSystemAudioMuter
            ? SystemAudioMuter()
            : NoOpSystemAudioMuter()
        let sessionCues = SessionCuePlayer()
        let coordinator = DictationCoordinator(
            recorder: recorder,
            asr: asr,
            tracker: tracker,
            inserter: inserter,
            permissions: permissions,
            hotkey: KeyboardShortcutsBinder(),
            settings: settings,
            activeASRBackend: backend,
            activeModelVariant: modelVariant,
            settingsStore: store,
            audioMuter: audioMuter,
            sessionCues: sessionCues
        )
        if let settingsFailure {
            coordinator.errorMessage = settingsFailure
        }
        // Acquisition starts at launch and reports through the coordinator, so the
        // menu can show a first run's download instead of failing every dictation
        // with a raw `model_not_installed` while it runs.
        coordinator.warmUpBackend()
        // Same reason, for sound: the process's first audio start costs an order of
        // magnitude more than every later one, and the start cue has 140 ms before
        // the muter ducks the device. Paid here rather than on the first dictation.
        Task { await sessionCues.warmUp() }
        return coordinator
    }

    public func toggle() {
        switch state {
        case .idle, .pasteAttempted, .copiedOnly, .insertFailed, .error, .cancelled:
            start()
        case .recording:
            stopAndProcess()
        case .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            return
        default:
            cancel()
        }
    }

    public func start() {
        guard !isPreparingForTermination else { return }
        guard !isCancellingRecording else { return }
        // A live recording or in-flight processing owns the recorder; starting
        // over it would race the old session's stop/cleanup (the old task's
        // generation checks only cover its own pipeline, not the recorder).
        guard state != .recording, !isProcessingInFlight else { return }
        let generation = generations.begin(.recordingStart)
        errorMessage = nil
        lastFailure = nil
        lastOutcome = nil
        lastTranscript = ""
        inputMeter.setLive(false)
        stopInputMetering()
        state = .checkingPermissions

        guard activeASRBackend != "fake" else {
            beginRecording(generation: generation)
            return
        }

        switch permissions.microphone() {
        case .granted:
            beginRecording(generation: generation)
        case .denied:
            failMicrophonePermissionDenied()
        case .notDetermined:
            Task { @MainActor in
                let granted = await self.permissions.requestMicrophone()
                guard self.generations.isCurrent(generation), self.state == .checkingPermissions else { return }
                if granted {
                    self.beginRecording(generation: generation)
                } else {
                    self.failMicrophonePermissionDenied()
                }
            }
        }
    }

    public func stopAndProcess() {
        guard state == .recording, !isProcessingInFlight else { return }
        let stopReleaseStarted = runtime.now()
        stopInputMetering()
        state = .finalizingAudio
        let generation = generations.begin(.processing)
        let identity = runtime.makeUUID()
        processingTaskIdentity = identity
        isProcessingInFlight = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processStop(generation: generation, stopReleaseStarted: stopReleaseStarted)
            guard self.processingTaskIdentity == identity else { return }
            self.processingTask = nil
            self.processingTaskIdentity = nil
            self.isProcessingInFlight = false
        }
        processingTask = task
    }

    @MainActor
    private func cancelActiveWork() {
        generations.invalidate(.processing)
        generations.invalidate(.recordingStart)
        processingTask?.cancel()
        suggestionTask?.cancel()
        suggestionTask = nil
        backendHealthTask?.cancel()
        backendHealthTask = nil
        backendAcquisitionPollTask?.cancel()
        backendAcquisitionPollTask = nil
        backendHealthProbeInFlight = false
        stopInputMetering()
        state = .cancelled
        refreshTarget()
    }

    public func cancel() {
        // Exactly one owner of the discard per session. While recording, this path
        // owns the recorder: no processing task exists yet. From .finalizingAudio
        // onward the pipeline owns it — `cancelActiveWork` cancels the processing
        // task, and the pipeline's cancellation/catch path discards. Both
        // discarding raced each other: the pipeline's `recorder.stop()` could
        // return the WAV that this path had already deleted.
        let ownsRecorder = state == .recording
        // Captured before `cancelActiveWork` publishes `.cancelled`: only a
        // session that was actually in flight was discarded, and Escape reaching
        // an idle coordinator must not announce a cancel that cancelled nothing.
        let discardedASession = state.isActive
        cancelActiveWork()

        if ownsRecorder {
            isCancellingRecording = true
            let recorder = recorder
            Task { @MainActor in
                await recorder.discardRecording()
                await self.restoreSystemAudioIfNeeded()
                self.isCancellingRecording = false
                // After the restore, never at the tap: the muter lifts the hardware
                // mute and only then ramps the volume back, so a cue played here
                // is heard at the user's own volume rather than swelling in.
                if discardedASession {
                    self.playListeningCancelledCue()
                }
                self.resetToIdleWhenInactive()
            }
        } else {
            Task { @MainActor in
                await self.restoreSystemAudioIfNeeded()
                if discardedASession {
                    self.playListeningCancelledCue()
                }
                self.resetToIdleWhenInactive()
            }
        }
    }

    public func prepareForTermination() async {
        isPreparingForTermination = true
        let shouldDiscardRecording = state == .recording || state == .finalizingAudio
        cancelActiveWork()
        let persistenceDrain = recentSessionPersistenceTail

        if shouldDiscardRecording {
            isCancellingRecording = true
            await recorder.discardRecording()
            isCancellingRecording = false
        }

        await restoreSystemAudioIfNeeded()
        _ = await persistenceDrain?.value
    }

    /// Persists settings on the journal's FIFO rather than on the main actor.
    ///
    /// Every caller is a UI edit — a toggle, a slider, a taught term — and a
    /// synchronous write would put an atomic file replacement plus two `chmod`s on
    /// the keystroke path. Queued behind the same tail as history so the two
    /// durable files cannot be written out of order relative to each other, and a
    /// failure is reported instead of discarded: `try?` would make a full disk or a
    /// revoked permission look exactly like a successful save.
    public func saveSettings() {
        let store = settingsStore
        let snapshot = settings
        let previous = recentSessionPersistenceTail
        let next = Task.detached(priority: .utility) { () -> Bool in
            _ = await previous?.value
            do {
                try store.save(snapshot)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        Task { @MainActor [weak self] in
            guard await next.value == false, let self else { return }
            self.errorMessage = "Settings could not be saved."
        }
    }

    /// The one write for a term the user authored or edited by hand. The Glossary
    /// row's editor and History's Teach both land here, so a term created by
    /// either is the same record.
    ///
    /// `termId` is the caller's claim about what it showed. A non-nil id means the
    /// caller listed the whole set of spoken forms, so `spokenForms` IS the set and
    /// a form the user deleted in the editor is gone. A nil id means the caller
    /// listed nothing — History's teach names a canonical it may never have seen —
    /// so the forms are added to whatever term already holds that spelling, never
    /// substituted for its own. That distinction is the whole reason
    /// the additive branch confirms each form instead of setting the list:
    /// teaching `cube control` onto bundled `kubectl` must not delete the two
    /// surfaces kubectl ships with.
    ///
    /// An existing term keeps the provenance it already had. Teaching a surface
    /// onto a shipped term makes the *alias* the user's, not the term, and
    /// rewriting `source` here would hand the whole shipped entry to
    /// `clearLearnedVocabulary`, which would then delete a bundled default the
    /// user had only ever added a mishearing to.
    ///
    /// Suggestion-only phase: never edits text that was already inserted.
    ///
    /// One live term per spelling, ledger-wide: a rename that lands on a spelling
    /// another term already holds is refused rather than merged, because two rows
    /// with one canonical make canonicalization depend on term order and the
    /// second row is unreachable in a list that names terms by their spelling.
    ///
    /// - Returns: `false` when the canonical sanitizes to nothing, when the new
    ///   spelling already belongs to another term, or when `commitGlossary`
    ///   refuses the proposal. Nothing is written in any of the three cases. The
    ///   two refusals name themselves in `glossaryNotice`; an unusable canonical
    ///   is the caller's own empty field and sets no notice.
    @discardableResult
    public func commitTerm(
        termId: String?,
        canonical: String,
        spokenForms: [String]
    ) -> Bool {
        guard let cleanCanonical = VocabularySanitizer.sanitize(canonical) else { return false }
        let cleanForms = spokenForms.compactMap { VocabularySanitizer.sanitize($0) }
        let key = cleanCanonical.lowercased()
        var proposed = settings.glossary
        if let termId, let index = proposed.firstIndex(where: { $0.termId == termId }) {
            if let clash = proposed.first(where: {
                $0.termId != termId && $0.tombstonedAt == nil
                    && $0.canonical.lowercased() == key
            }) {
                glossaryNotice = "“\(clash.canonical)” is already a term. Open it to add a spoken form."
                return false
            }
            var term = proposed[index]
            term.canonical = cleanCanonical
            term.tombstonedAt = nil
            proposed[index] = TermMutation.settingAliases(cleanForms, on: term)
        } else if let index = proposed.firstIndex(where: { $0.canonical.lowercased() == key }) {
            var term = proposed[index]
            term.tombstonedAt = nil
            for form in cleanForms {
                term = TermMutation.confirmingAlias(form, on: term)
            }
            proposed[index] = term
        } else {
            var term = ProtectedTerm(
                canonical: cleanCanonical,
                spokenAliases: [],
                termId: makeUniqueTermId(preferred: cleanCanonical),
                source: .explicitCorrection
            )
            for form in cleanForms {
                term = TermMutation.confirmingAlias(form, on: term)
            }
            proposed.append(term)
        }
        return commitGlossary(proposed)
    }

    /// Accepts a pending suggestion: confirms the misheard surface as an alias
    /// of its term so future dictation canonicalizes it, then drops it from the
    /// pending list. Never mutates the already-inserted target text.
    public func acceptSuggestion(id: String) {
        guard let suggestion = pendingSuggestions.first(where: { $0.id == id }) else { return }
        if let index = settings.glossary.firstIndex(where: { $0.termId == suggestion.termId }) {
            var proposed = settings.glossary
            proposed[index] = TermMutation.confirmingAlias(suggestion.misheard, on: proposed[index])
            guard commitGlossary(proposed) else { return }
        }
        pendingSuggestions.removeAll { $0.id == id }
    }

    /// Commits a proposed glossary, or refuses it and says why.
    ///
    /// An alias that also names another term's canonical or alias makes
    /// canonicalization depend on term order: the same dictation would resolve
    /// differently after a reorder. The vocabulary is small and user-authored, so
    /// the whole proposal is validated rather than the one edited row — a teach can
    /// collide with a term the user forgot they had.
    @discardableResult
    func commitGlossary(_ proposed: [ProtectedTerm]) -> Bool {
        guard VocabularySanitizer.aliasesAreUnambiguous(in: proposed) else {
            glossaryNotice = "That spoken form already belongs to another term."
            return false
        }
        settings.glossary = proposed
        saveSettings()
        return true
    }

    /// Rejects a pending suggestion: records a rejected label for the surface on
    /// its term (so it is not proposed again) and drops it from the pending list.
    public func rejectSuggestion(id: String) {
        guard let suggestion = pendingSuggestions.first(where: { $0.id == id }) else { return }
        if let index = settings.glossary.firstIndex(where: { $0.termId == suggestion.termId }) {
            settings.glossary[index] = TermMutation.rejectingAlias(
                suggestion.misheard,
                on: settings.glossary[index]
            )
            saveSettings()
        }
        pendingSuggestions.removeAll { $0.id == id }
    }

    /// True when `clearLearnedVocabulary()` would change something.
    ///
    /// Derived from the clear rather than restated as a `source` predicate: a
    /// surface taught onto a bundled default leaves that term's provenance
    /// alone, so any hand-written test for "is there learned vocabulary" drifts
    /// out of agreement with the button it enables.
    public var hasLearnedVocabulary: Bool {
        glossaryWithoutLearnedVocabulary() != settings.glossary
    }

    /// Removes every user-learned term (explicit corrections, manual imports,
    /// app profiles) and restores the bundled defaults that survive to their
    /// shipped surfaces, then clears any pending suggestions.
    public func clearLearnedVocabulary() {
        settings.glossary = glossaryWithoutLearnedVocabulary()
        suggestionTask?.cancel()
        pendingSuggestions = []
        saveSettings()
    }

    /// The glossary with everything the user added taken back out.
    ///
    /// Filtering on `source` alone is not enough: teach and accept-suggestion
    /// write an alias onto whatever term already holds the canonical without
    /// changing its provenance, so a mishearing taught onto a bundled default
    /// would outlive the clear it was supposed to be caught by. A default the
    /// user deleted from the ledger stays deleted — this restores surfaces, it
    /// does not resurrect rows.
    private func glossaryWithoutLearnedVocabulary() -> [ProtectedTerm] {
        let shipped = Dictionary(
            Settings.defaultGlossary.map { ($0.termId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return settings.glossary.compactMap { term in
            switch term.source {
            case .explicitCorrection, .manualImport, .appProfile:
                return nil
            case .bundled:
                guard let restored = shipped[term.termId] else {
                    // An orphaned default: shipped by an older build and since
                    // removed from `defaultGlossary`. There is no shipped surface
                    // set to restore it to, so it falls back to its canonical
                    // alone. Stripping only `labeledAliases` would clear the
                    // user's own confirmations while preserving stale aliases
                    // from a version that no longer exists — exactly backwards,
                    // and would make a damaging alias unremovable by the button
                    // whose whole job is removing it: a removed default shipped
                    // `Cloud` as an alias of `Claude`, which rewrote every
                    // "Google Cloud" the user dictated into "Google Claude".
                    // The row survives because the canonical may still be a term
                    // the user relies on; only the unshipped surfaces go.
                    var stripped = term
                    stripped.labeledAliases = []
                    stripped.spokenAliases = []
                    return stripped
                }
                return restored
            }
        }
    }

    /// Imports a user-selected word list and merges the sanitized terms into the
    /// glossary. Surfaces failures on `glossaryNotice`.
    public func importWordList(from url: URL) {
        do {
            let imported = try WordListImporter.importWordList(from: url)
            let merged = glossaryMerging(
                imported.map { term in
                    var namespaced = term
                    namespaced.termId = "wordlist:\(term.canonical)"
                    return namespaced
                })
            // Validated post-merge, because the importer sees only the file: an
            // imported canonical can collide with an alias the user taught earlier,
            // and accepting that pair would make canonicalization order-dependent.
            guard VocabularySanitizer.aliasesAreUnambiguous(in: merged) else {
                glossaryNotice = "That word list collides with a spoken form already in the glossary."
                return
            }
            settings.glossary = merged
            glossaryNotice = nil
            saveSettings()
        } catch let error as LocalizedError {
            glossaryNotice = error.errorDescription ?? String(describing: error)
        } catch {
            glossaryNotice = error.localizedDescription
        }
    }

    public func refreshTarget() {
        updateTargetLabel(for: tracker.snapshot())
    }

    func updateTargetLabel(for snapshot: TargetSnapshot) {
        let app = AppDisplayName.label(bundleId: snapshot.bundleId, name: snapshot.appName)
        switch snapshot.safety {
        case .normalText:
            targetLabel = "Will paste into \(app)"
        default:
            targetLabel = "Will copy for \(app) (\(snapshot.safety.rawValue))"
        }
    }

    /// The glossary with `terms` merged in, replacing an existing row when its
    /// `termId` matches or when it is an imported row whose canonical matches
    /// case-insensitively, and appending the rest. Both rules are needed for a
    /// re-import to stay idempotent: ledgers written by earlier builds hold
    /// imported rows under `project:<uuid>/…` ids that no fresh import can
    /// reproduce, so id matching alone would append a duplicate on every re-import.
    ///
    /// Returns the proposal rather than assigning it: the caller validates first.
    private func glossaryMerging(_ terms: [ProtectedTerm]) -> [ProtectedTerm] {
        var merged = settings.glossary
        var indexByTermId: [String: Int] = [:]
        var importedIndexByCanonical: [String: Int] = [:]
        for (index, term) in merged.enumerated() {
            indexByTermId[term.termId] = index
            if term.source == .manualImport {
                importedIndexByCanonical[term.canonical.lowercased()] = index
            }
        }
        for term in terms {
            if let index = indexByTermId[term.termId] ?? importedIndexByCanonical[term.canonical.lowercased()] {
                merged[index] = term
            } else {
                indexByTermId[term.termId] = merged.count
                importedIndexByCanonical[term.canonical.lowercased()] = merged.count
                merged.append(term)
            }
        }
        return merged
    }

    /// Returns `preferred` when free, otherwise a `#N`-suffixed variant, so a new
    /// term never collides with an existing term id.
    private func makeUniqueTermId(preferred: String) -> String {
        let existing = Set(settings.glossary.map(\.termId))
        guard existing.contains(preferred) else { return preferred }
        var suffix = 2
        while existing.contains("\(preferred)#\(suffix)") { suffix += 1 }
        return "\(preferred)#\(suffix)"
    }

    func ensureCurrentProcessing(_ generation: AsyncGenerationGate.Token) throws {
        try Task.checkCancellation()
        if !generations.isCurrent(generation) {
            throw CancellationError()
        }
    }

    func resetToIdleWhenInactive(generation: AsyncGenerationGate.Token? = nil) {
        Task { @MainActor in
            if let generation, !self.generations.isCurrent(generation) { return }
            if !self.state.isActive { self.state = .idle }
        }
    }

}
