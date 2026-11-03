import Foundation
import VoiceCore

/// What the backend needs from a loaded Granite model; `GraniteContext` in production, a
/// scripted stand-in in tests that cannot load the 506 MB artifact.
protocol GraniteRuntimeContext: AnyObject {
    func transcribe(samples: [Float], isCancelled: @escaping () -> Bool) throws -> GraniteRawResult
}

extension GraniteContext: GraniteRuntimeContext {}

/// The Granite Speech 5 TurboCTC evaluation backend over the pinned Q8_0 GGUF.
///
/// Mirrors `ParakeetSidecarBackend`'s observable contract — health and readiness, preload
/// acquisition and its latched failure, request-path refusal while the model is missing, the
/// load-failure digest re-verification and single re-acquisition, idle unload, cancellation and
/// fatal-failure semantics — over a single artifact with none of Parakeet's variants or
/// experimental seams. It never prunes: it has no siblings, and the Parakeet directories are
/// not its business.
///
/// State shared by the reader thread (`health`), decode queue (`transcribe`) and preload thread
/// (`warmUp`) lives behind `stateLock`. Context construction is serialized by `loadLock`, and
/// every `granite_transcribe` by `decodeLock`.
public final class GraniteSidecarBackend: SidecarBackend, ShutdownAwareSidecarPreloading, @unchecked Sendable {
    public let backendId = "granite-ctc"

    private let cache: ParakeetModelCache
    private let log: (String) -> Void
    private let contextFactory: (String) throws -> any GraniteRuntimeContext

    private let stateLock = NSLock()
    /// Held for a whole model load so exactly one context is ever constructed: two contexts
    /// share ggml's Metal device, and freeing the loser of a construction race would tear the
    /// device down under the survivor. Not `stateLock`, so `health()` stays answerable while the
    /// first load compiles Metal pipelines.
    private let loadLock = NSLock()
    /// Held for the duration of one `granite_transcribe`: a context holds one run's results.
    private let decodeLock = NSLock()
    private var context: (any GraniteRuntimeContext)?
    private var loadMs = 0
    private var loadFailed = false
    /// 0...1 while `warmUp` is acquiring the artifact; nil at every other moment.
    private var downloadFraction: Double?
    /// True from `warmUp` entry until it returns, the download included.
    private var warmingInProgress = false
    /// Why the last acquisition did not finish, or nil when none has failed since the last
    /// success. Cleared where `loadFailed` is cleared, because the same event settles both.
    private var lastAcquisitionError: ASRAcquisitionFailure?
    /// When the last decode finished, or the model was loaded. Drives the idle unload.
    private var lastDecodeEndedAt = DispatchTime.now()
    private var idleTimer: DispatchSourceTimer?
    /// Whether this process has already spent its one automatic re-acquisition.
    private var reacquisitionSpent = false
    /// The shutdown latch the server hands to `warmUp`, kept so the automatic re-acquisition
    /// bails out of model work on EOF exactly as the preload thread does.
    private var shutdownProbe: (@Sendable () -> Bool)?

    /// Idle time after which the loaded model is released, or <= 0 to keep it forever.
    private let idleUnloadMs: Int
    private let idleQueue = DispatchQueue(label: "voiceour.asr.granite.idle")
    /// How often the idle check runs. Coarse on purpose: the deadline it guards is in minutes.
    private static let idleTickSeconds = 60.0
    /// Samples of silence the preload decodes once, so the first dictation does not pay the
    /// process's Metal pipeline materialisation.
    static let warmUpSampleCount = 8_000

    public convenience init(
        cache: ParakeetModelCache,
        log: @escaping (String) -> Void,
        idleUnloadMs: Int = 1_800_000
    ) {
        self.init(
            cache: cache,
            log: log,
            idleUnloadMs: idleUnloadMs,
            contextFactory: { try GraniteContext(modelPath: $0) }
        )
    }

    init(
        cache: ParakeetModelCache,
        log: @escaping (String) -> Void,
        idleUnloadMs: Int,
        contextFactory: @escaping (String) throws -> any GraniteRuntimeContext
    ) {
        self.cache = cache
        self.log = log
        self.idleUnloadMs = idleUnloadMs
        self.contextFactory = contextFactory
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
            // Nil rather than false once loaded, so an idle-unloaded backend does not read as
            // warming when it is simply resting.
            warming: warming && !loaded ? true : nil,
            lastAcquisitionError: acquisitionError
        )
    }

    /// Downloads the artifact if needed, loads the model, and runs one throwaway decode.
    public func warmUp() throws {
        try warmUp(isShuttingDown: { false })
    }

    func warmUp(isShuttingDown: @escaping @Sendable () -> Bool) throws {
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
        let loaded: (any GraniteRuntimeContext)?
        do {
            loaded = try acquireModel(isShuttingDown: isShuttingDown)
        } catch {
            withState { $0.lastAcquisitionError = ParakeetSidecarBackend.acquisitionFailure(for: error) }
            throw error
        }
        // A warm decode owns Metal buffers too, so shutdown must never begin one after EOF.
        guard let loaded, !isShuttingDown() else { return }
        // Outside the latch on purpose: the throwaway decode is an optimization, not
        // acquisition, and a decode that cannot run belongs to the request that hits it.
        _ = try decode(
            loaded,
            samples: [Float](repeating: 0, count: Self.warmUpSampleCount),
            isCancelled: { false }
        )
    }

    /// Fetches the artifact if needed and builds the context. Nil when shutdown cut it short.
    private func acquireModel(isShuttingDown: () -> Bool) throws -> (any GraniteRuntimeContext)? {
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

    private func withState(_ body: (GraniteSidecarBackend) -> Void) {
        stateLock.lock()
        body(self)
        stateLock.unlock()
    }

    /// Drops the model before the process exits: ggml's Metal device destructor aborts if a
    /// residency set still holds one of this context's buffers.
    public func shutdown() {
        stateLock.lock()
        let released = context
        context = nil
        stateLock.unlock()
        _ = released
    }

    public func transcribe(
        _ request: ASRTranscribeRequest,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> SidecarTerminal {
        if isCancelled() { return .cancelled }

        let samples: [Float]
        let context: any GraniteRuntimeContext
        switch prepare(request) {
        case .failure(let code, let detail): return .failure(code: code, detail: detail, fatal: false)
        case .ready(let decoded, let loaded):
            samples = decoded
            context = loaded
        }

        if isCancelled() { return .cancelled }

        // A crash-recovery-truncated WAV can legitimately decode to zero samples: nothing is
        // wrong with the device, there is simply nothing to transcribe.
        if samples.isEmpty {
            let loadMs = stateLock.withLock { self.loadMs }
            return result(GraniteTranscriptMapping.emptyTranscript, loadMs: loadMs, inferenceMs: 0)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let raw: GraniteRawResult
        do {
            raw = try decode(context, samples: samples, isCancelled: isCancelled)
        } catch {
            // The abort callback's answer and a client cancel that raced a failure both mean the
            // reader asked for this to stop: answer that rather than an inference failure.
            if isCancelled() { return .cancelled }
            switch error as? GraniteContextError {
            case .cancelled?:
                return .cancelled
            case .invalidArgument(let detail)?:
                return .failure(code: .unsupportedAudioFormat, detail: detail, fatal: false)
            default:
                // The Metal device may be poisoned; only a fresh process recovers it.
                return .failure(code: .inferenceFailed, detail: String(describing: error), fatal: true)
            }
        }
        let inferenceMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        if isCancelled() { return .cancelled }

        let loadMs = stateLock.withLock { self.loadMs }
        return result(GraniteTranscriptMapping.transcript(from: raw), loadMs: loadMs, inferenceMs: inferenceMs)
    }

    private func result(_ transcript: ASRTranscript, loadMs: Int, inferenceMs: Int) -> SidecarTerminal {
        .result(
            transcript: transcript,
            backendId: backendId,
            modelId: GraniteModelContract.modelId,
            modelRevision: GraniteModelContract.revision,
            timings: ASRTimings(load: loadMs, inference: inferenceMs, total: loadMs + inferenceMs)
        )
    }

    private enum Preparation {
        case ready([Float], any GraniteRuntimeContext)
        case failure(code: ASRErrorCode, detail: String?)
    }

    /// Everything that can fail before the decode, in the order every backend applies it:
    /// request shape, model availability, audio decoding, model load.
    private func prepare(_ request: ASRTranscribeRequest) -> Preparation {
        let audioURL: URL
        switch SidecarRequestValidation.validate(
            request,
            modelId: GraniteModelContract.modelId,
            modelRevision: GraniteModelContract.revision,
            modelFile: cache.artifact.file
        ) {
        case .audioPath(let url): audioURL = url
        case .failure(let code, let detail): return .failure(code: code, detail: detail)
        }

        // Never blocks on the download: a cold acquisition cannot fit inside the client's 30 s
        // transcribe timeout, and the preload thread is already fetching.
        guard cache.cacheOK() else {
            return .failure(
                code: .modelNotInstalled,
                detail: "\(GraniteModelContract.modelId) is still being acquired; retry once it has finished"
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
    /// artifact: `cacheOK()` compares the manifest and byte count only, so a load failure is the
    /// one moment a bit-rotted cache can be told apart from a broken runtime.
    private func loadFailure(_ detail: String) -> Preparation {
        guard !cache.verifyModelDigestOnDisk() else {
            return .failure(code: .modelLoadFailed, detail: detail)
        }
        log("cached model failed digest re-verification after a load failure; removing it")
        // Granite derives nothing from the artifact, so there is no weight arena to remove.
        cache.removeModelAndManifest()
        reacquireOnce()
        return .failure(
            code: .modelNotInstalled,
            detail: "cached model failed digest re-verification and was removed; it will be re-downloaded"
        )
    }

    /// Re-acquires the artifact the load-failure path just deleted, at most once per process,
    /// off the caller's thread. See `ParakeetSidecarBackend.reacquireOnce` for why both the
    /// re-acquisition and its one-attempt latch are required.
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

    /// Creates the context on first use, exactly once. The load lock is held across
    /// construction: a "build then discard the loser" race destroys a live Metal device.
    private func loadContext() throws -> any GraniteRuntimeContext {
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
            // settled: the same event clears both latches.
            lastAcquisitionError = nil
            lastDecodeEndedAt = DispatchTime.now()
            stateLock.unlock()
            startIdleTimerIfNeeded()
            return created
        } catch {
            stateLock.lock()
            loadFailed = true
            stateLock.unlock()
            throw error
        }
    }

    // MARK: - Idle unload

    func shouldUnloadNow(now: DispatchTime) -> Bool {
        stateLock.lock()
        let loaded = context != nil
        let idleMs = Self.elapsedMs(from: lastDecodeEndedAt, to: now)
        stateLock.unlock()
        return ParakeetSidecarBackend.isIdleUnloadDue(
            idleUnloadMs: idleUnloadMs,
            contextLoaded: loaded,
            idleMs: idleMs
        )
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
        // A decode owns its context for its whole duration: skip a busy tick.
        guard decodeLock.try() else { return }
        defer { decodeLock.unlock() }

        stateLock.lock()
        let idleMs = Self.elapsedMs(from: lastDecodeEndedAt, to: .now())
        let released = context
        context = nil
        stateLock.unlock()

        guard released != nil else { return }
        log("idle unload after \(idleMs)ms; the next dictation reloads the model")
    }

    private func currentContext() -> (any GraniteRuntimeContext)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context
    }

    /// Runs one decode with the context held exclusively. The preload throwaway decode and a
    /// request decode can race on the same context.
    private func decode(
        _ context: any GraniteRuntimeContext,
        samples: [Float],
        isCancelled: @escaping () -> Bool
    ) throws -> GraniteRawResult {
        decodeLock.lock()
        defer {
            withState { $0.lastDecodeEndedAt = DispatchTime.now() }
            decodeLock.unlock()
        }
        return try context.transcribe(samples: samples, isCancelled: isCancelled)
    }
}
