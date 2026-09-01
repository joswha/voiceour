import Foundation
import VoiceCore

protocol ParakeetRuntimeContext: AnyObject {
    func transcribe(samples: [Float], isCancelled: @escaping () -> Bool) throws -> [ParakeetSegmentRaw]
    func transcribeForWarmUp(
        samples: [Float],
        isCancelled: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw]
    func primeCoreMLTiers(log: (String) -> Void)
}

extension ParakeetRuntimeContext {
    func transcribeForWarmUp(
        samples: [Float],
        isCancelled: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        try transcribe(samples: samples, isCancelled: isCancelled)
    }

    func primeCoreMLTiers(log: (String) -> Void) {}
}

extension ParakeetContext: ParakeetRuntimeContext {}

enum ParakeetAssistError: Error, CustomStringConvertible {
    case emptyModelPath
    case modelMissing(String)
    case invalidMaximumDuration(String)

    var description: String {
        switch self {
        case .emptyModelPath:
            return "VOICEOUR_ASSIST_MODEL is set but empty"
        case .modelMissing(let path):
            return "VOICEOUR_ASSIST_MODEL artifact missing: \(path)"
        case .invalidMaximumDuration(let value):
            return "VOICEOUR_ASSIST_MAX_S must be a positive finite number of seconds, got: \(value)"
        }
    }
}

/// The real backend: parakeet.cpp over the pinned GGUF checkpoint.
///
/// State shared by the reader thread (`health`), decode queue (`transcribe`) and preload thread
/// (`warmUp`) lives behind `stateLock`. Context construction is serialized by `loadLock`, and
/// every `parakeet_full` is serialized by `decodeLock`.
public final class ParakeetSidecarBackend: SidecarBackend, ShutdownAwareSidecarPreloading, @unchecked Sendable {
    public let backendId = "parakeet-cpp"

    private let cache: ParakeetModelCache
    private let log: (String) -> Void

    private let contextFactory: (String) throws -> any ParakeetRuntimeContext
    /// Whether warm-up additionally loads every configured CoreML tier. See `CoreMLWarmMode`.
    private let coreMLWarm: CoreMLWarmMode
    private let stateLock = NSLock()
    /// Held for the whole duration of a model load so exactly one context is ever constructed.
    ///
    /// This cannot be `stateLock`: a first load compiles the embedded Metal shader library and
    /// takes seconds, and `health()` must stay answerable throughout. It cannot be omitted
    /// either — two contexts in one process share ggml's Metal device, so releasing the loser of
    /// a construction race runs `parakeet_free`, tears the device down under the survivor, and
    /// every later encode fails with "command buffer failed with status 1".
    private let loadLock = NSLock()
    /// Held for the duration of one primary-context `parakeet_full`.
    /// See `decode(_:samples:isCancelled:)`.
    private let decodeLock = NSLock()
    /// Held for the duration of one assist-context `parakeet_full`. A separate lock on
    /// purpose: `parakeet_full` is unsafe for the SAME context, not across contexts —
    /// parakeet.cpp keeps all decode state per-context (its one mutable global is the
    /// write-once log callback), the persistent CPU pool is a per-context parameter, and
    /// the primary's ≤15 s path runs ANE + CPU while the assist runs its own Metal
    /// backend, so the two decodes are substrate-disjoint and may overlap.
    private let assistDecodeLock = NSLock()
    private var context: (any ParakeetRuntimeContext)?
    /// Optional second-opinion models: decoded in order on the assist thread when
    /// audio is at or under that model's matching sample cap, their raw transcripts
    /// returned as `assistTexts` for the client-side text stage to arbitrate.
    /// Empty disables the feature.
    private let assistModelPaths: [String]
    private let assistMaxSampleCounts: [Int]
    private var assistContexts: [any ParakeetRuntimeContext] = []
    private let assistContextFactory: (String) throws -> any ParakeetRuntimeContext
    private var loadMs = 0
    private var loadFailed = false
    /// 0...1 while `warmUp` is acquiring the artifact; nil at every other moment.
    private var downloadFraction: Double?
    /// True from `warmUp` entry until it returns, the download included.
    private var warmingInProgress = false
    /// Why the last acquisition did not finish, or nil when none has failed since the last
    /// success. Reported on `health` so the app learns the truth instead of inferring it from a
    /// transition; cleared where `loadFailed` is cleared, because the same event settles both.
    private var lastAcquisitionError: ASRAcquisitionFailure?
    /// When the last decode finished, or the model was loaded. Drives the idle unload.
    private var lastDecodeEndedAt = DispatchTime.now()
    private var idleTimer: DispatchSourceTimer?
    /// Whether this process has already spent its one automatic re-acquisition.
    /// See `reacquireOnce()`; guarded by `stateLock`.
    private var reacquisitionSpent = false
    /// The shutdown latch the server hands to `warmUp`, kept so acquisition started later —
    /// the one automatic re-acquisition — bails out of model work on EOF exactly as the preload
    /// thread does. Nil only in a process that never preloaded.
    private var shutdownProbe: (() -> Bool)?

    /// Idle time after which the loaded model is released, or 0 to keep it forever.
    ///
    /// 30 minutes by default: the model is 1.26 GB of wired-down weights, and a dictation app
    /// spends most of a working day doing nothing. A reload costs ~314 ms plus one warm decode,
    /// which is paid by the next dictation and not by the one that already ended.
    private let idleUnloadMs: Int
    private let idleQueue = DispatchQueue(label: "voiceour.asr.idle")
    /// How often the idle check runs. Coarse on purpose: the deadline it guards is in minutes.
    private static let idleTickSeconds = 60.0

    public convenience init(
        cache: ParakeetModelCache,
        log: @escaping (String) -> Void,
        idleUnloadMs: Int = 1_800_000
    ) {
        self.init(
            cache: cache,
            log: log,
            idleUnloadMs: idleUnloadMs,
            contextFactory: {
                try ParakeetContext(modelPath: $0, weightArenaPath: cache.weightArenaURL.path)
            }
        )
    }

    /// Resolves and validates every optional CoreML encoder path at process startup. Model loading
    /// stays lazy so each fixed-shape tier pays its CoreML setup cost only when first routed.
    public convenience init(
        cache: ParakeetModelCache,
        environment: [String: String],
        log: @escaping (String) -> Void,
        idleUnloadMs: Int = 1_800_000
    ) throws {
        let tailBackend = try ParakeetTailBackend.resolve(environment: environment)
        let tailQuant = try ParakeetTailQuant.resolve(environment: environment)
        let cpuPool = try ParakeetCPUPool.resolve(environment: environment)
        if tailQuant.isQ8 && !tailBackend.usesCPU {
            throw ParakeetTailQuantError.requiresCPUTail
        }
        let coreMLWarm = try CoreMLWarmMode.resolve(environment: environment)
        let weightArenaPath =
            cache.weightArenaURL.path
            + (tailBackend.usesCPU ? ".tail-cpu" : "")
            + (tailQuant.isQ8 ? ".tail-q8" : "")
        let configurations = try CoreMLEncoderConfigurationSet.resolve(environment: environment)
        let coreMLEncoders = try CoreMLEncoderSet(configurations: configurations, log: log)

        var assistModelPaths: [String] = []
        var assistMaxSampleCounts: [Int] = []
        var assistMaximumSeconds: [Double] = []
        var defaultAssistMaximumSeconds = 15.0
        if let rawMax = environment["VOICEOUR_ASSIST_MAX_S"] {
            guard let parsed = Double(rawMax), parsed.isFinite, parsed > 0 else {
                throw ParakeetAssistError.invalidMaximumDuration(rawMax)
            }
            defaultAssistMaximumSeconds = parsed
        }
        let assistKeys: [(model: String, maximum: String?)] = [
            ("VOICEOUR_ASSIST_MODEL", nil),
            ("VOICEOUR_ASSIST_MODEL_2", nil),
            ("VOICEOUR_ASSIST_MODEL_3", "VOICEOUR_ASSIST_MODEL_3_MAX_S"),
            ("VOICEOUR_ASSIST_MODEL_4", "VOICEOUR_ASSIST_MODEL_4_MAX_S"),
        ]
        for key in assistKeys {
            guard let assistPath = environment[key.model] else { continue }
            guard !assistPath.isEmpty else {
                throw ParakeetAssistError.emptyModelPath
            }
            guard FileManager.default.fileExists(atPath: assistPath) else {
                throw ParakeetAssistError.modelMissing(assistPath)
            }
            var maxSeconds = defaultAssistMaximumSeconds
            if let maximumKey = key.maximum, let rawMax = environment[maximumKey] {
                guard let parsed = Double(rawMax), parsed.isFinite, parsed > 0 else {
                    throw ParakeetAssistError.invalidMaximumDuration(rawMax)
                }
                maxSeconds = parsed
            }
            assistModelPaths.append(assistPath)
            assistMaxSampleCounts.append(Int(maxSeconds * 16_000))
            assistMaximumSeconds.append(maxSeconds)
        }
        if !assistModelPaths.isEmpty {
            let maxima = assistMaximumSeconds.map { String($0) }.joined(separator: ",")
            log(
                "VOICEOUR_ASSIST_MODEL mode=chain models=\(assistModelPaths.joined(separator: ",")) max_s=\(maxima)"
            )
        }

        if !coreMLEncoders.isEmpty {
            self.init(
                cache: cache,
                log: log,
                idleUnloadMs: idleUnloadMs,
                coreMLWarm: coreMLWarm,
                assistModelPaths: assistModelPaths,
                assistMaxSampleCounts: assistMaxSampleCounts,
                contextFactory: {
                    try ParakeetContext(
                        modelPath: $0,
                        weightArenaPath: weightArenaPath,
                        tailBackendCPU: tailBackend.usesCPU,
                        tailQuantQ8: tailQuant.isQ8,
                        persistentCPUPool: cpuPool.isPersistent,
                        coreMLEncoders: coreMLEncoders
                    )
                }
            )
            let configuredTiers = [
                configurations.tiny == nil ? nil : "tiny",
                configurations.short == nil ? nil : "short",
                configurations.standard == nil ? nil : "standard",
            ].compactMap({ $0 }).joined(separator: ",")
            log(
                "VOICEOUR_COREML_ENCODER mode=hybrid loading=lazy configured_tiers=\(configuredTiers)"
            )
            if let standard = configurations.standard {
                log(
                    "VOICEOUR_COREML_ENCODER mode=hybrid compute_units=CPU_AND_NE model=\(standard.modelURL.path) max_s=\(standard.maximumDurationSeconds)"
                )
            }
            if let short = configurations.short {
                log(
                    "VOICEOUR_COREML_ENCODER_SHORT mode=hybrid compute_units=CPU_AND_NE model=\(short.modelURL.path) max_s=\(short.maximumDurationSeconds)"
                )
            }
            if let tiny = configurations.tiny {
                log(
                    "VOICEOUR_COREML_ENCODER_TINY mode=hybrid compute_units=CPU_AND_NE model=\(tiny.modelURL.path) max_s=\(tiny.maximumDurationSeconds)"
                )
            }
            if coreMLWarm.warmsAllTiers {
                log("VOICEOUR_COREML_WARM mode=tiers")
            }
        } else {
            self.init(
                cache: cache,
                log: log,
                idleUnloadMs: idleUnloadMs,
                assistModelPaths: assistModelPaths,
                assistMaxSampleCounts: assistMaxSampleCounts,
                contextFactory: {
                    try ParakeetContext(
                        modelPath: $0,
                        weightArenaPath: weightArenaPath,
                        tailBackendCPU: tailBackend.usesCPU,
                        tailQuantQ8: tailQuant.isQ8,
                        persistentCPUPool: cpuPool.isPersistent
                    )
                }
            )
            log("VOICEOUR_COREML_ENCODER mode=native")
        }
        if tailBackend == .cpu {
            log("VOICEOUR_TAIL_BACKEND mode=cpu")
        }
        if tailQuant.isQ8 {
            log("VOICEOUR_TAIL_QUANT mode=q8_0")
        }
        if cpuPool.isPersistent {
            log("VOICEOUR_CPU_POOL mode=persistent")
        }
    }

    init(
        cache: ParakeetModelCache,
        log: @escaping (String) -> Void,
        idleUnloadMs: Int,
        coreMLWarm: CoreMLWarmMode = .default,
        assistModelPaths: [String] = [],
        assistMaxSampleCounts: [Int] = [],
        contextFactory: @escaping (String) throws -> any ParakeetRuntimeContext,
        assistContextFactory: ((String) throws -> any ParakeetRuntimeContext)? = nil
    ) {
        self.cache = cache
        self.log = log
        self.idleUnloadMs = idleUnloadMs
        self.coreMLWarm = coreMLWarm
        self.assistModelPaths = assistModelPaths
        self.assistMaxSampleCounts = assistMaxSampleCounts
        self.contextFactory = contextFactory
        // Assist contexts use their own per-model weight arenas so their weights stay
        // file-backed mmap rather than wired Metal buffers (the footprint mechanism).
        // The bias-variant variance fix-up folds before the arena commit and warm
        // loads skip it, so the arena never drifts.
        self.assistContextFactory =
            assistContextFactory
            ?? { try ParakeetContext(modelPath: $0, weightArenaPath: $0 + ".weight-arena") }
    }

    public func startupStatus() -> BackendStatus {
        cache.cacheOK() ? .ready : .modelMissing
    }

    public func health() -> ASRBackendHealth {
        let cacheOk = cache.cacheOK()
        stateLock.lock()
        let loaded = context != nil
        let failed = loadFailed
        let fraction = downloadFraction
        let warming = warmingInProgress
        let acquisitionError = lastAcquisitionError
        stateLock.unlock()
        return ASRBackendHealth(
            backendId: backendId,
            backendStatus: cacheOk ? .ready : .modelMissing,
            ready: cacheOk && !failed,
            modelLoaded: loaded,
            cacheOk: cacheOk,
            downloadFraction: fraction,
            // Nil rather than false once the model is loaded, so an idle-unloaded backend does
            // not read as warming when it is simply resting.
            warming: warming && !loaded ? true : nil,
            lastAcquisitionError: acquisitionError
        )
    }

    /// Downloads the artifact if needed, loads the model, and runs one throwaway decode.
    ///
    /// The throwaway decode is not superstition: the first `parakeet_full` of a process pays
    /// 58-348 ms materialising Metal pipelines, and the very first run of a given binary on a
    /// machine additionally compiles the embedded shader library (about 7.5 s, then cached by
    /// the OS). Paying both here keeps them off the user's first dictation.
    public func warmUp() throws {
        try warmUp(isShuttingDown: { false })
    }

    func warmUp(isShuttingDown: @escaping () -> Bool) throws {
        guard !isShuttingDown() else { return }
        withState {
            $0.warmingInProgress = true
            $0.shutdownProbe = isShuttingDown
        }
        defer {
            withState {
                $0.warmingInProgress = false
                $0.downloadFraction = nil
            }
        }
        let loaded: (any ParakeetRuntimeContext)?
        do {
            loaded = try acquireModel(isShuttingDown: isShuttingDown)
        } catch {
            // The one place an acquisition failure is observed. Before this latch the server
            // caught it, logged one stderr line and dropped it, leaving the app to infer a
            // failure from "was acquiring, now neither" — invisible on a first probe and never
            // produced at all by a refusal that fails instantly.
            withState { $0.lastAcquisitionError = Self.acquisitionFailure(for: error) }
            throw error
        }
        // A warm decode owns Metal buffers too, so shutdown must never begin one after EOF.
        guard let loaded, !isShuttingDown() else { return }
        // Outside the latch on purpose: the throwaway decode is an optimization, not
        // acquisition. The artifact is on disk and loaded, and a decode that cannot run
        // belongs to the request that hits it, with its own request id and terminal.
        _ = try decode(
            loaded,
            samples: [Float](repeating: 0, count: 8000),
            isCancelled: { false },
            isWarmUp: true
        )
        // Tier priming is scheduled by `loadContext` for every newly created context, so the
        // preload path needs nothing further here: the prime thread is already running against
        // the context this warm-up loaded.
    }

    /// Fetches the artifact if needed and builds the context. Nil when shutdown cut it short.
    private func acquireModel(isShuttingDown: () -> Bool) throws -> (any ParakeetRuntimeContext)? {
        try cache.ensureModel { fraction in
            self.withState { $0.downloadFraction = fraction }
            self.log(String(format: "VOICEOUR_PRELOAD download %.0f%%", fraction * 100))
        }
        withState { $0.downloadFraction = nil }

        // EOF may arrive during acquisition. Avoid constructing a Metal-backed context that
        // shutdown would immediately have to tear down from another thread.
        guard !isShuttingDown() else { return nil }
        return try loadContext()
    }

    /// The wire shape of an acquisition failure. `ParakeetModelCacheError` carries its own code
    /// so the taxonomy stays in one place; anything else here came out of the context build.
    static func acquisitionFailure(for error: Error) -> ASRAcquisitionFailure {
        if let cacheError = error as? ParakeetModelCacheError {
            return ASRAcquisitionFailure(code: cacheError.wireCode, detail: cacheError.description)
        }
        return ASRAcquisitionFailure(code: .modelLoadFailed, detail: String(describing: error))
    }

    private func withState(_ body: (ParakeetSidecarBackend) -> Void) {
        stateLock.lock()
        body(self)
        stateLock.unlock()
    }

    /// Drops the model before the process exits. See `SidecarBackend.shutdown`: ggml's Metal
    /// device destructor aborts if a residency set still holds one of this context's buffers.
    public func shutdown() {
        stateLock.lock()
        let released = context
        let releasedAssists = assistContexts
        context = nil
        assistContexts = []
        stateLock.unlock()
        _ = released
        _ = releasedAssists
    }

    public func transcribe(
        _ request: ASRTranscribeRequest,
        isCancelled: @escaping () -> Bool
    ) -> SidecarTerminal {
        if isCancelled() { return .cancelled }

        let samples: [Float]
        let context: any ParakeetRuntimeContext
        switch prepare(request) {
        case .failure(let code, let detail): return .failure(code: code, detail: detail, fatal: false)
        case .ready(let decoded, let loaded):
            samples = decoded
            context = loaded
        }

        if isCancelled() { return .cancelled }

        // A crash-recovery-truncated WAV can legitimately decode to zero samples. `parakeet_full`
        // on an empty buffer must never reach the fatal path below: nothing is wrong with the
        // device, there is simply nothing to transcribe.
        if samples.isEmpty {
            stateLock.lock()
            let loadMs = self.loadMs
            stateLock.unlock()
            return .result(
                transcript: TokenMapping.transcript(from: []),
                backendId: backendId,
                modelId: ASRModelContract.modelId,
                modelRevision: ASRModelContract.revision,
                timings: ASRTimings(load: loadMs, inference: 0, total: loadMs)
            )
        }

        let started = DispatchTime.now().uptimeNanoseconds

        // The assist decodes run concurrently with the primary: distinct contexts, and
        // the primary's short-audio path is ANE + CPU while the assists run their own
        // Metal backends (chained serially on one thread — they share the GPU). Each
        // context's own decode stays serialized by its lock. A per-model cap may omit
        // a costly assist while preserving the configured ordering of those that run.
        let runAssist = assistMaxSampleCounts.contains { samples.count <= $0 }
        var assistOutcome: Result<[[ParakeetSegmentRaw]], Error>?
        let assistJoin = DispatchSemaphore(value: 0)
        if runAssist {
            let assistSamples = samples
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { assistJoin.signal() }
                guard let self else {
                    assistOutcome = .failure(ParakeetAssistError.emptyModelPath)
                    return
                }
                assistOutcome = Result {
                    let assists = try self.loadAssistContexts()
                    return try zip(assists, self.assistMaxSampleCounts).compactMap {
                        context, maximumSamples in
                        guard assistSamples.count <= maximumSamples else { return nil }
                        return try self.decode(
                            context,
                            samples: assistSamples,
                            isCancelled: isCancelled
                        )
                    }
                }
            }
        }

        let segments: [ParakeetSegmentRaw]
        do {
            segments = try decode(context, samples: samples, isCancelled: isCancelled)
        } catch {
            // A client `cancel` trips parakeet.cpp's abort callback, and `parakeet_full` reports
            // that as a plain -6 rather than a distinct status. Answer the cancel that was asked
            // for instead of inventing an inference failure.
            if runAssist { assistJoin.wait() }
            if isCancelled() { return .cancelled }
            return .failure(code: .inferenceFailed, detail: String(describing: error), fatal: true)
        }

        var assistTexts: [String]?
        if runAssist {
            assistJoin.wait()
            switch assistOutcome {
            case .success(let assistSegments):
                assistTexts = assistSegments.map { TokenMapping.transcript(from: $0).text }
            case .failure(let error):
                // Assist is configured on purpose; a silent fallback to the primary-only
                // transcript would report a run that never exercised the candidate.
                if isCancelled() { return .cancelled }
                return .failure(
                    code: .inferenceFailed,
                    detail: "assist decode failed: \(String(describing: error))",
                    fatal: true
                )
            case .none:
                return .failure(
                    code: .inferenceFailed,
                    detail: "assist decode returned no outcome",
                    fatal: true
                )
            }
        }
        let inferenceMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        if isCancelled() { return .cancelled }

        stateLock.lock()
        let loadMs = self.loadMs
        stateLock.unlock()

        var transcript = TokenMapping.transcript(from: segments)
        transcript.assistTexts = assistTexts
        return .result(
            transcript: transcript,
            backendId: backendId,
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision,
            timings: ASRTimings(load: loadMs, inference: inferenceMs, total: loadMs + inferenceMs)
        )
    }

    private enum Preparation {
        case ready([Float], any ParakeetRuntimeContext)
        case failure(code: ASRErrorCode, detail: String?)
    }

    /// Everything that can fail before the decode: request shape, model availability,
    /// audio decoding and model load, in the order the retired Python backend applied them.
    private func prepare(_ request: ASRTranscribeRequest) -> Preparation {
        let audioURL: URL
        switch SidecarRequestValidation.validate(
            request,
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision,
            modelFile: cache.artifact.file
        ) {
        case .audioPath(let url): audioURL = url
        case .failure(let code, let detail): return .failure(code: code, detail: detail)
        }

        // A cold acquisition cannot fit inside the client's 30 s transcribe timeout, so this
        // never blocks on the download: the preload thread is already fetching, and the client
        // is told to retry. Blocking would spend the whole budget, time out, and have the
        // client kill the sidecar mid-download.
        guard cache.cacheOK() else {
            return .failure(
                code: .modelNotInstalled,
                detail: "\(ASRModelContract.modelId) is still being acquired; retry once it has finished"
            )
        }

        let samples: [Float]
        do {
            samples = try WAVFile.readSamples(at: audioURL)
        } catch {
            return .failure(code: .unsupportedAudioFormat, detail: String(describing: error))
        }

        do {
            return .ready(samples, try loadContext())
        } catch let error as ParakeetModelCacheError {
            if case .manifestMismatch = error {
                return .failure(code: .manifestMismatch, detail: error.description)
            }
            return loadFailure(error.description)
        } catch {
            return loadFailure(String(describing: error))
        }
    }

    /// Maps a model-load failure, first asking whether the cached bytes are still the pinned
    /// artifact.
    ///
    /// `cacheOK()` checks the pinned manifest fields and byte count, because hashing 1.26 GB
    /// on every start would dominate the cold path. A load failure is the one moment where
    /// truncated-then-padded or bit-rotted cache is otherwise indistinguishable from a broken
    /// runtime, and the user sees a permanent failure instead of a re-download.
    private func loadFailure(_ detail: String) -> Preparation {
        guard !cache.verifyModelDigestOnDisk() else {
            return .failure(code: .modelLoadFailed, detail: detail)
        }
        log("cached model failed digest re-verification after a load failure; removing it and its weight arena")
        cache.removeCorruptModelAndDerivedCache()
        reacquireOnce()
        return .failure(
            code: .modelNotInstalled,
            detail: "cached model failed digest re-verification and was removed; it will be re-downloaded"
        )
    }

    /// Re-acquires the artifact the load-failure path just deleted, at most once per process.
    ///
    /// The deletion above leaves the sidecar with no weights at all, and nothing else in the
    /// process would fetch them again: every later `transcribe` would answer
    /// `model_not_installed` — which the app presents as "the speech model has not finished
    /// downloading yet" — until the reader found the menu's retry or relaunched. This is what
    /// makes that sentence, and the promise in the detail above, true.
    ///
    /// Off the caller's thread because the caller is a decode inside the client's 30 s timeout,
    /// which a fresh 1.26 GB transfer cannot fit. Latched at one attempt because an automatic
    /// re-download must never become a loop; it cannot become one on its own either, since
    /// `ensureModel` verifies the digest before the bytes are moved into place, so a load failure
    /// over freshly fetched bytes finds a matching digest and reports a broken runtime instead of
    /// deleting them again. The latch is the second brake, not the only one.
    private func reacquireOnce() {
        stateLock.lock()
        let claimed = !reacquisitionSpent
        reacquisitionSpent = true
        let isShuttingDown = shutdownProbe ?? { false }
        stateLock.unlock()
        guard claimed, !isShuttingDown() else { return }

        log("re-acquiring the removed model once; the next dictation can use it")
        Thread.detachNewThread { [self] in
            do {
                try warmUp(isShuttingDown: isShuttingDown)
            } catch {
                log("automatic re-acquisition failed: \(error)")
            }
        }
    }

    /// Creates the context on first use, exactly once.
    ///
    /// Callers are the decode queue and the preload thread. The load lock is held across
    /// construction rather than only around the state update: a "build then discard the loser"
    /// race destroys a live Metal device, which is not recoverable in-process.
    private func loadContext() throws -> any ParakeetRuntimeContext {
        if let existing = currentContext() { return existing }

        loadLock.lock()
        defer { loadLock.unlock() }
        if let existing = currentContext() { return existing }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let created = try contextFactory(cache.modelURL.path)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            stateLock.lock()
            context = created
            loadMs = elapsed
            loadFailed = false
            // The artifact is here and it loads, so whatever the last attempt tripped over is
            // settled. Same rule as `loadFailed`, and it must be the same event: a stale
            // DOWNLOAD FAILED outliving a working model is the mirror of the bug this fixes.
            lastAcquisitionError = nil
            lastDecodeEndedAt = DispatchTime.now()
            stateLock.unlock()
            startIdleTimerIfNeeded()
            // A context that loaded is the strongest evidence this artifact is the wanted one —
            // far stronger than the byte count `cacheOK()` compares — so this is where the
            // superseded variants are retired. Any earlier and a selected artifact that has
            // rotted to the right size passes `cacheOK()`, its sibling is deleted, the load
            // fails, the load-failure path removes the selection too, and the reader is left
            // with no model at all. Every process that loads a model reaches this line once,
            // whether or not the acquisition above fetched anything, so a switch onto an
            // already-cached variant still retires the one it replaced.
            cache.removeSupersededVariants()
            scheduleTierPrime(created)
            return created
        } catch {
            stateLock.lock()
            loadFailed = true
            stateLock.unlock()
            throw error
        }
    }

    /// Creates the assist contexts on first assisted decode, exactly once, under the
    /// same load lock as the primary: contexts share ggml's Metal device and their
    /// constructions must never race (see `loadContext`).
    private func loadAssistContexts() throws -> [any ParakeetRuntimeContext] {
        stateLock.lock()
        let existing = assistContexts
        stateLock.unlock()
        if existing.count == assistModelPaths.count { return existing }

        loadLock.lock()
        defer { loadLock.unlock() }
        stateLock.lock()
        let raced = assistContexts
        stateLock.unlock()
        if raced.count == assistModelPaths.count { return raced }

        let started = DispatchTime.now().uptimeNanoseconds
        let created = try assistModelPaths.map { try assistContextFactory($0) }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        stateLock.lock()
        assistContexts = created
        stateLock.unlock()
        log("VOICEOUR_ASSIST_MODEL loaded \(created.count) assist model(s) in \(elapsed)ms")
        return created
    }

    /// Primes the configured CoreML tiers for a newly created context, off the request path.
    ///
    /// Runs for every creation — the preload thread's and the post-idle-unload reload on the
    /// decode queue alike — so a long-idle sidecar does not pay a cold tier specialization
    /// inside the user's next dictation. Lock-free by design: priming loads throwaway models
    /// to heat the system's specialization cache and touches no decode state, so a real
    /// request never waits behind it. A context released before the thread runs is skipped.
    private func scheduleTierPrime(_ created: any ParakeetRuntimeContext) {
        guard coreMLWarm.warmsAllTiers else { return }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            guard self.currentContext() === created else { return }
            created.primeCoreMLTiers(log: self.log)
        }
    }

    // MARK: - Idle unload

    /// Whether a loaded model has now been idle long enough to release.
    ///
    /// Split out from the timer so the decision is testable without a loadable 1.26 GB model;
    /// the process-level behaviour is covered by the integration test in `SidecarProcessTests`.
    static func isIdleUnloadDue(idleUnloadMs: Int, contextLoaded: Bool, idleMs: Int) -> Bool {
        idleUnloadMs > 0 && contextLoaded && idleMs >= idleUnloadMs
    }

    func shouldUnloadNow(now: DispatchTime) -> Bool {
        stateLock.lock()
        let loaded = context != nil
        let idleMs = Self.elapsedMs(from: lastDecodeEndedAt, to: now)
        stateLock.unlock()
        return Self.isIdleUnloadDue(idleUnloadMs: idleUnloadMs, contextLoaded: loaded, idleMs: idleMs)
    }

    private static func elapsedMs(from start: DispatchTime, to end: DispatchTime) -> Int {
        guard end.uptimeNanoseconds > start.uptimeNanoseconds else { return 0 }
        return Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Starts the idle check once, after the first successful load.
    private func startIdleTimerIfNeeded() {
        guard idleUnloadMs > 0 else { return }
        stateLock.lock()
        var created: DispatchSourceTimer?
        if idleTimer == nil {
            created = DispatchSource.makeTimerSource(queue: idleQueue)
            idleTimer = created
        }
        stateLock.unlock()

        guard let timer = created else { return }
        timer.schedule(deadline: .now() + Self.idleTickSeconds, repeating: Self.idleTickSeconds)
        timer.setEventHandler { [weak self] in self?.unloadIfIdle() }
        timer.resume()
    }

    private func unloadIfIdle() {
        guard shouldUnloadNow(now: .now()) else { return }
        // A decode owns its context for its whole duration, so dropping either context
        // needs its lock. Skip this tick rather than make the user wait behind a timer
        // that only ever needs to be approximately right.
        guard decodeLock.try() else { return }
        defer { decodeLock.unlock() }
        guard assistDecodeLock.try() else { return }
        defer { assistDecodeLock.unlock() }

        stateLock.lock()
        let idleMs = Self.elapsedMs(from: lastDecodeEndedAt, to: .now())
        let released = context
        let releasedAssists = assistContexts
        context = nil
        assistContexts = []
        stateLock.unlock()
        _ = releasedAssists

        guard released != nil else { return }
        log("idle unload after \(idleMs)ms; the next dictation reloads (~314 ms plus a warm decode)")
    }

    private func currentContext() -> (any ParakeetRuntimeContext)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context
    }

    /// Runs one decode with the context held exclusively under its own lock.
    ///
    /// The server already serializes real transcribes on one queue, but the preload thread's
    /// throwaway decode does not run there, and `parakeet_full` is documented as not thread safe
    /// for the same context. Distinct contexts decode concurrently on purpose: the assist
    /// overlap in `transcribe` relies on the primary and assist locks being separate.
    private func decode(
        _ context: any ParakeetRuntimeContext,
        samples: [Float],
        isCancelled: @escaping () -> Bool,
        isWarmUp: Bool = false
    ) throws -> [ParakeetSegmentRaw] {
        stateLock.lock()
        let isAssist = assistContexts.contains(where: { $0 === context })
        stateLock.unlock()
        let lock = isAssist ? assistDecodeLock : decodeLock
        lock.lock()
        defer {
            withState { $0.lastDecodeEndedAt = DispatchTime.now() }
            lock.unlock()
        }
        if isWarmUp {
            return try context.transcribeForWarmUp(
                samples: samples,
                isCancelled: isCancelled
            )
        }
        return try context.transcribe(samples: samples, isCancelled: isCancelled)
    }
}
