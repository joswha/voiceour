import Combine
import Foundation
import Observation
import VoiceCore
import VoiceMac

/// Publishes the microphone input level and capture-live flag, which update at
/// the metering cadence (25Hz while recording). These live on a dedicated
/// `ObservableObject` rather than directly on `DictationCoordinator` because,
/// on the monolithic coordinator, every publish invalidated all ~12 console
/// view bodies observing the coordinator (none of which display these values)
/// — the metering tick alone forced a whole-tree re-render 25 times a second
/// during recording. It remains Combine-published because its sole consumer is
/// the AppKit-side recording overlay controller.
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

public enum OmpOnboardingState: Equatable, Sendable {
    case idle
    case opening(OmpSubscription)
    case terminalOpen(OmpSubscription)
    case signedIn(OmpSubscription, model: String?, detail: String)
    case cancelled(OmpSubscription)
    case failed(OmpSubscription, String)

    public var isInFlight: Bool {
        switch self {
        case .opening, .terminalOpen:
            true
        case .idle, .signedIn, .cancelled, .failed:
            false
        }
    }
}

public enum OmpProviderStatusState: Equatable, Sendable {
    case idle
    case checking
    case loaded
    case failed(String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// Progress of the `omp models` catalog the Refinement pane's Model picker
/// offers. The list is inherited from OMP rather than hard-coded, so the pane
/// has to be able to say that it is still asking, and why it could not.
public enum OmpModelCatalogState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

@Observable @MainActor
public final class DictationCoordinator {
    public typealias RefinerFactory = (VoiceCore.Settings) -> TranscriptRefining
    public typealias OmpModelsProbeFunction = (
        URL,
        [String],
        String,
        Int
    ) async -> RefinerReachability
    public typealias OmpModelCatalogLoadFunction = (
        URL,
        [String],
        Int
    ) async throws -> [OmpAvailableModel]
    public typealias OmpOnboardingStartFunction = (
        OmpSubscription
    ) async throws -> OmpOnboardingSession
    public typealias OmpOnboardingFinishFunction = (
        OmpOnboardingSession
    ) async -> OmpOnboardingOutcome
    public typealias OmpProviderStatusProbeFunction = (
        URL,
        [String],
        Int
    ) async throws -> OmpProviderStatusSnapshot

    public internal(set) var state: SessionState = .idle {
        didSet {
            stateSubject.send(state)
            // Escape belongs to the focused app at every other moment, so the
            // binder only claims it while the overlay is on screen.
            hotkey.setCancelArmed(state.isActive)
        }
    }
    public var settings: VoiceCore.Settings {
        didSet {
            guard RefinerIdentity(settings: oldValue) != RefinerIdentity(settings: settings) else {
                return
            }
            generations.invalidate(.refinerConfiguration)
            refinerReachability = .unknown
        }
    }
    public private(set) var targetLabel: String = "No target"
    public internal(set) var lastOutcome: InsertionOutcome?
    public internal(set) var lastTranscript: String = ""
    public internal(set) var errorMessage: String?
    public private(set) var backendHealth: ASRBackendHealth?
    public private(set) var backendHealthError: String?
    public internal(set) var recentSessions: [RecentSession] = []
    /// Lifetime dictation counters. Survives transcript eviction, which is the
    /// only reason Home's all-time figures keep moving once the retained
    /// corpus reaches its cap.
    public internal(set) var statsLedger: DictationStatsLedger = DictationStatsLedger()
    /// The digest every Home readout renders, recomputed by the journal
    /// whenever the ledger or the retained corpus changes.
    ///
    /// Owned here rather than cached in the view: the view's only sound
    /// invalidation key was the session id list, which cannot see the in-place
    /// amendment that attaches a destination app and the post-speech timing to
    /// the session just recorded. Home was permanently one dictation stale.
    public internal(set) var insights: DictationInsights = .empty
    public internal(set) var isSystemAudioMuted: Bool = false
    /// True when the last capture asked for a mute the output device could not
    /// provide. Sticky until the next capture answers the question again.
    public internal(set) var isSystemAudioMuteUnavailable: Bool = false
    public internal(set) var refinerReachability: RefinerReachability = .unknown
    public internal(set) var ompOnboardingState: OmpOnboardingState = .idle
    public internal(set) var ompProviderConnections: [OmpProviderConnection] = []
    public internal(set) var ompProviderStatusState: OmpProviderStatusState = .idle
    public internal(set) var ompModels: [OmpAvailableModel] = []
    public internal(set) var ompModelCatalogState: OmpModelCatalogState = .idle
    public internal(set) var pendingSuggestions: [TermSuggestion] = []
    public private(set) var activeProjectId: String?
    public private(set) var activeProjectName: String?
    public private(set) var isProcessingInFlight: Bool = false

    private let stateSubject = CurrentValueSubject<SessionState, Never>(.idle)
    public var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Dedicated meter for the 25Hz input-level / capture-live stream; see
    /// `AudioLevelMeter`.
    public let inputMeter = AudioLevelMeter()

    public var refinerReadiness: RefinerReadiness {
        RefinerReadiness.evaluate(settings: settings)
    }

    let recorder: AudioRecording
    let asr: ASRClienting
    let tracker: TargetTracking
    let inserter: TextInserting
    private let permissions: PermissionsChecking
    private let hotkey: HotkeyBinding
    var refiner: TranscriptRefining
    let refinerFactory: RefinerFactory?
    var boundRefinerIdentity: RefinerIdentity?
    private let settingsStore: SettingsStore
    let recentSessionStore: RecentSessionStore
    let statsStore: DictationStatsStore
    let statsSnapshotSave: @Sendable (DictationStatsStore, DictationStatsLedger) throws -> Void
    let recentSessionSnapshotSave: @Sendable (RecentSessionStore, [RecentSession]) throws -> Void
    let audioMuter: SystemAudioMuting
    let temporaryAudioRemover: @Sendable (URL) throws -> Void
    let runtime: DictationRuntime
    let ompModelsProbe: OmpModelsProbeFunction
    let ompProviderStatusProbe: OmpProviderStatusProbeFunction
    let ompModelCatalogLoad: OmpModelCatalogLoadFunction
    let ompOnboardingStart: OmpOnboardingStartFunction
    let ompOnboardingFinish: OmpOnboardingFinishFunction
    private let activeASRBackend: String
    var target: TargetSnapshot?
    var inputMeteringTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingTaskIdentity: UUID?
    var suggestionTask: Task<Void, Never>?
    private var backendHealthTask: Task<Void, Never>?
    /// Guards refreshBackendHealth against duplicate sidecar probes: skip a
    /// fresh probe while one is in flight or within backendHealthTTL of the
    /// last completion. System and Diagnostics both probe from onAppear on
    /// every tab entry, so bare switches would otherwise fan out dupes.
    private var backendHealthProbeInFlight = false
    private var backendHealthLastRefresh: Date?
    private let backendHealthTTL: TimeInterval = 5
    /// Generation counters for async work a newer request supersedes. One
    /// primitive with named scopes replaced five bare `Int` fields compared by
    /// hand across roughly twenty-three guard blocks.
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
        refiner: TranscriptRefining,
        refinerFactory: RefinerFactory? = nil,
        settings: VoiceCore.Settings = VoiceCore.Settings(),
        activeASRBackend: String? = nil,
        settingsStore: SettingsStore = SettingsStore(),
        recentSessionStore: RecentSessionStore = RecentSessionStore(),
        recentSessionSnapshotSave: @escaping @Sendable (RecentSessionStore, [RecentSession]) throws -> Void = {
            store, sessions in
            try store.save(sessions)
        },
        statsStore: DictationStatsStore? = nil,
        statsSnapshotSave: @escaping @Sendable (DictationStatsStore, DictationStatsLedger) throws -> Void = {
            store, ledger in
            try store.save(ledger)
        },
        ompModelsProbe: @escaping OmpModelsProbeFunction = { executableURL, argumentPrefix, model, timeoutMs in
            await OmpModelsProbe.check(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                model: model,
                timeoutMs: timeoutMs
            )
        },
        ompProviderStatusProbe: @escaping OmpProviderStatusProbeFunction = { executableURL, argumentPrefix, timeoutMs in
            try await OmpProviderStatusProbe.load(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                timeoutMs: timeoutMs
            )
        },
        // The Model picker's options come from OMP itself rather than from a
        // list this app maintains, so the catalog load is a seam: tests and the
        // offscreen harness must never spawn `omp models`.
        ompModelCatalogLoad: @escaping OmpModelCatalogLoadFunction = { executableURL, argumentPrefix, timeoutMs in
            try await OmpModelCatalog.load(
                executableURL: executableURL,
                argumentPrefix: argumentPrefix,
                timeoutMs: timeoutMs
            )
        },
        ompOnboardingStart: @escaping OmpOnboardingStartFunction = { subscription in
            let environment = ProcessInfo.processInfo.environment
            let omp = OmpExecutable.resolve(explicitPath: environment["VOICEOUR_OMP_BIN"])
            return try await OmpOnboarding.begin(
                subscription: subscription,
                executableURL: omp.url,
                argumentPrefix: omp.prefix,
                environment: environment
            )
        },
        ompOnboardingFinish: @escaping OmpOnboardingFinishFunction = { session in
            await OmpOnboarding.finish(session)
        },
        audioMuter: SystemAudioMuting = NoOpSystemAudioMuter(),
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
        self.refiner = refiner
        self.refinerFactory = refinerFactory
        self.boundRefinerIdentity = refinerFactory == nil ? RefinerIdentity(settings: settings) : nil
        self.ompModelsProbe = ompModelsProbe
        self.ompProviderStatusProbe = ompProviderStatusProbe
        self.ompOnboardingStart = ompOnboardingStart
        self.ompOnboardingFinish = ompOnboardingFinish
        self.ompModelCatalogLoad = ompModelCatalogLoad
        self.settings = settings
        self.activeASRBackend = activeASRBackend ?? settings.asrBackend
        self.settingsStore = settingsStore
        self.recentSessionStore = recentSessionStore
        // Defaulted from the transcript store's own location so a test or
        // harness fixture that redirects transcripts can never leave the stats
        // file pointed at the user's real Application Support directory.
        self.statsStore = statsStore ?? DictationStatsStore(besideRecentSessionsAt: recentSessionStore.url)
        self.recentSessionSnapshotSave = recentSessionSnapshotSave
        self.statsSnapshotSave = statsSnapshotSave
        self.audioMuter = audioMuter
        self.temporaryAudioRemover = temporaryAudioRemover
        self.runtime = runtimeOverride ?? .live
        self.recentSessions = (try? recentSessionStore.load()) ?? []
        self.statsLedger = (try? self.statsStore.load()) ?? DictationStatsLedger()
        // Folds anything the ledger has not seen: a first run after this file
        // existed seeds the whole retained corpus, a later launch folds only
        // what a crash lost between the two writes, and a steady state folds
        // nothing. `ingest` is idempotent by session id, so one call covers
        // all three.
        let seeded = statsLedger
        self.statsLedger.ingest(self.recentSessions, calendar: self.runtime.calendar())
        self.insights = DictationInsights(
            ledger: self.statsLedger,
            keptSessions: self.recentSessions,
            calendar: self.runtime.calendar(),
            now: self.runtime.now()
        )
        if seeded != self.statsLedger {
            enqueueStatsSnapshot(self.statsLedger)
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
        refreshTarget()
    }

    public var activeBackend: String { activeASRBackend }

    public func refreshBackendHealth(timeoutMs: Int = 3_000) {
        // Collapse duplicate probes: onAppear fires this on every System /
        // Diagnostics tab entry. Skip while a probe is in flight, or if the
        // last completion (success or failure) landed within the TTL.
        if backendHealthProbeInFlight { return }
        if let last = backendHealthLastRefresh,
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
                    self?.backendHealth = health
                    self?.backendHealthError = nil
                    self?.backendHealthLastRefresh = self?.runtime.now()
                    self?.backendHealthProbeInFlight = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.backendHealth = nil
                    self?.backendHealthError = String(describing: error)
                    self?.backendHealthLastRefresh = self?.runtime.now()
                    self?.backendHealthProbeInFlight = false
                }
            }
        }
    }

    public static func live() -> DictationCoordinator {
        Task.detached(priority: .utility) {
            RecordingScavenger.sweep(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("voiceour")
            )
        }

        let store = SettingsStore()
        var settings = (try? store.load()) ?? VoiceCore.Settings()
        let launchOptions = VoiceCore.LaunchOptions(arguments: CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment

        let registry = ASRBackendRegistry.builtIn
        let backend =
            launchOptions.asrBackend
            ?? VoiceCore.LaunchOptions.validBackend(env["VOICEOUR_ASR_BACKEND"], validBackendIDs: registry.backendIDs)
            ?? VoiceCore.LaunchOptions.validBackend(settings.asrBackend, validBackendIDs: registry.backendIDs)
            ?? registry.defaultDescriptor.id
        settings.asrBackend = backend

        let permissions = SystemPermissions()
        let tracker = WorkspaceTargetTracker()
        let components = registry.liveComponents(
            for: backend,
            context: ASRBackendContext(
                sidecarExecutableURL: ASRBackendContext.siblingSidecarURL(),
                speechLocale: settings.speechLocale
            )
        )
        let recorder = components.recorder
        let asr = components.client
        let inserter = PasteboardInserter(permissions: permissions, tracker: tracker)
        let refinerFactory: RefinerFactory = { settings in
            let refinerRegistry = RefinerProviderRegistry.live(
                environment: env,
                deterministicFallback: { $0 }
            )
            return refinerRegistry.make(settings: settings)
        }
        let audioMuter: SystemAudioMuting =
            components.usesSystemAudioMuter
            ? SystemAudioMuter()
            : NoOpSystemAudioMuter()
        Task { await asr.warmUp() }

        let coordinator = DictationCoordinator(
            recorder: recorder,
            asr: asr,
            tracker: tracker,
            inserter: inserter,
            permissions: permissions,
            hotkey: KeyboardShortcutsBinder(),
            refiner: UnsupportedRefiner(reason: "not_bound"),
            refinerFactory: refinerFactory,
            settings: settings,
            activeASRBackend: backend,
            settingsStore: store,
            audioMuter: audioMuter
        )
        return coordinator
    }

    public func toggle() {
        switch state {
        case .idle, .pasteAttempted, .copiedOnly, .insertFailed, .error, .cancelled:
            start()
        case .recording:
            stopAndProcess()
        case .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
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
        backendHealthProbeInFlight = false
        stopInputMetering()
        state = .cancelled
        clearCapturedTargetAndRefreshLabel()
    }

    public func cancel() {
        // .finalizingAudio means processStop may not have reached recorder.stop()
        // yet; cancelling without a discard would leave the microphone capture
        // running forever. discardRecording is idempotent for every recorder.
        let shouldDiscardRecording = state == .recording || state == .finalizingAudio
        cancelActiveWork()

        if shouldDiscardRecording {
            isCancellingRecording = true
            let recorder = recorder
            Task { @MainActor in
                await recorder.discardRecording()
                await self.restoreSystemAudioIfNeeded()
                self.isCancellingRecording = false
                self.resetToIdleWhenInactive()
            }
        } else {
            Task { @MainActor in
                await self.restoreSystemAudioIfNeeded()
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

    public func saveSettings() {
        try? settingsStore.save(settings)
    }

    /// Explicitly teaches a canonical term (Teach UI). Sanitizes the surfaces,
    /// upserts the term at `scope`, and, when a non-empty `misheard` is given,
    /// records it as a confirmed alias so future dictation canonicalizes it.
    /// Suggestion-only phase: never edits existing text.
    ///
    /// An existing term keeps the provenance it already had. Teaching a surface
    /// onto a shipped term makes the *alias* the user's, not the term, and
    /// rewriting `source` here used to hand the whole shipped entry to
    /// `clearLearnedVocabulary`, which then deleted a bundled default the user
    /// had only ever added a mishearing to.
    public func teachCorrection(canonical: String, misheard: String?, scope: VocabularyScope) {
        guard let cleanCanonical = VocabularySanitizer.sanitize(canonical) else { return }
        let cleanMisheard: String? = {
            guard let misheard, !misheard.isEmpty else { return nil }
            return VocabularySanitizer.sanitize(misheard)
        }()
        let key = cleanCanonical.lowercased()
        if let index = settings.glossary.firstIndex(where: {
            $0.canonical.lowercased() == key && $0.scope == scope
        }) {
            var term = settings.glossary[index]
            term.tombstonedAt = nil
            if let cleanMisheard {
                term = TermMutation.confirmingAlias(cleanMisheard, on: term)
            }
            settings.glossary[index] = term
        } else {
            var term = ProtectedTerm(
                canonical: cleanCanonical,
                spokenAliases: [],
                termId: makeUniqueTermId(preferred: cleanCanonical),
                source: .explicitCorrection,
                scope: scope
            )
            if let cleanMisheard {
                term = TermMutation.confirmingAlias(cleanMisheard, on: term)
            }
            settings.glossary.append(term)
        }
        saveSettings()
    }

    /// Accepts a pending suggestion: confirms the misheard surface as an alias
    /// of its term so future dictation canonicalizes it, then drops it from the
    /// pending list. Never mutates the already-inserted target text.
    public func acceptSuggestion(id: String) {
        guard let suggestion = pendingSuggestions.first(where: { $0.id == id }) else { return }
        if let index = settings.glossary.firstIndex(where: { $0.termId == suggestion.termId }) {
            settings.glossary[index] = TermMutation.confirmingAlias(
                suggestion.misheard,
                on: settings.glossary[index]
            )
            saveSettings()
        }
        pendingSuggestions.removeAll { $0.id == id }
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
                    // alone. Stripping only `labeledAliases` here cleared the
                    // user's own confirmations while preserving stale aliases
                    // from a version that no longer exists — exactly backwards,
                    // and it made a damaging alias unremovable by the button
                    // whose whole job is removing it. A removed default shipped
                    // `Cloud` as an alias of `Claude`, which rewrote every
                    // "Google Cloud" this user dictated into "Google Claude".
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

    /// Imports a user-selected project word list, resolving (or creating) the
    /// active project, and merges the sanitized terms into the glossary,
    /// deduplicating by term id. Surfaces failures on `errorMessage`.
    public func importProjectLexicon(from url: URL) {
        let projectId = activeProjectId ?? "project-\(UUID().uuidString)"
        let resolvedName = activeProjectName ?? Self.projectName(for: url)
        do {
            let lexicon = try ProjectLexiconImporter.importLexicon(from: url, projectId: projectId)
            mergeGlossaryTerms(
                lexicon.terms.map { term in
                    var namespaced = term
                    namespaced.termId = "project:\(projectId)/\(term.canonical)"
                    return namespaced
                })
            activeProjectId = projectId
            activeProjectName = resolvedName
            errorMessage = nil
            saveSettings()
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshTarget() {
        updateTargetLabel(for: tracker.snapshot())
    }

    func updateTargetLabel(for snapshot: TargetSnapshot) {
        let app = snapshot.bundleId ?? "Unknown app"
        switch snapshot.safety {
        case .normalText:
            targetLabel = "Will paste into \(app)"
        default:
            targetLabel = "Will copy for \(app) (\(snapshot.safety.rawValue))"
        }
    }

    func clearCapturedTargetAndRefreshLabel() {
        target = nil
        refreshTarget()
    }

    /// Merges terms into the glossary, replacing any existing term with the same
    /// `termId` and appending the rest, so re-imports stay idempotent.
    private func mergeGlossaryTerms(_ terms: [ProtectedTerm]) {
        var indexByTermId: [String: Int] = [:]
        for (index, term) in settings.glossary.enumerated() {
            indexByTermId[term.termId] = index
        }
        for term in terms {
            if let index = indexByTermId[term.termId] {
                settings.glossary[index] = term
            } else {
                indexByTermId[term.termId] = settings.glossary.count
                settings.glossary.append(term)
            }
        }
    }

    /// Returns `preferred` when free, otherwise a `#N`-suffixed variant, so a new
    /// term never collides with an existing term id (e.g. same canonical, other scope).
    private func makeUniqueTermId(preferred: String) -> String {
        let existing = Set(settings.glossary.map(\.termId))
        guard existing.contains(preferred) else { return preferred }
        var suffix = 2
        while existing.contains("\(preferred)#\(suffix)") { suffix += 1 }
        return "\(preferred)#\(suffix)"
    }

    /// Derives a human-friendly project name from an imported lexicon URL,
    /// preferring the containing directory name.
    private static func projectName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, parent != "/", parent != "." {
            return parent
        }
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "Imported Project" : base
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
