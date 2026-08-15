import Foundation
import VoiceCore

/// The real backend: parakeet.cpp over the pinned GGUF checkpoint.
///
/// State that both the reader thread (`health`) and the decode queue (`transcribe`, `warmUp`)
/// touch lives behind `stateLock`. The context itself is only ever used from the decode queue —
/// `parakeet_full` is documented as not thread safe for the same context.
public final class ParakeetSidecarBackend: SidecarBackend, @unchecked Sendable {
    public let backendId = "parakeet-cpp"

    private let cache: ParakeetModelCache
    private let log: (String) -> Void

    private let stateLock = NSLock()
    /// Held for the whole duration of a model load so exactly one context is ever constructed.
    ///
    /// This cannot be `stateLock`: a first load compiles the embedded Metal shader library and
    /// takes seconds, and `health()` must stay answerable throughout. It cannot be omitted
    /// either — two contexts in one process share ggml's Metal device, so releasing the loser of
    /// a construction race runs `parakeet_free`, tears the device down under the survivor, and
    /// every later encode fails with "command buffer failed with status 1".
    private let loadLock = NSLock()
    /// Held for the duration of one `parakeet_full`. See `decode(_:samples:isCancelled:)`.
    private let decodeLock = NSLock()
    private var context: ParakeetContext?
    private var loadMs = 0
    private var loadFailed = false
    /// 0...1 while `warmUp` is acquiring the artifact; nil at every other moment.
    private var downloadFraction: Double?
    /// True from `warmUp` entry until it returns, the download included.
    private var warmingInProgress = false
    /// When the last decode finished, or the model was loaded. Drives the idle unload.
    private var lastDecodeEndedAt = DispatchTime.now()
    private var idleTimer: DispatchSourceTimer?

    /// Idle time after which the loaded model is released, or 0 to keep it forever.
    ///
    /// 30 minutes by default: the model is 1.26 GB of wired-down weights, and a dictation app
    /// spends most of a working day doing nothing. A reload costs ~314 ms plus one warm decode,
    /// which is paid by the next dictation and not by the one that already ended.
    private let idleUnloadMs: Int
    private let idleQueue = DispatchQueue(label: "voiceour.asr.idle")
    /// How often the idle check runs. Coarse on purpose: the deadline it guards is in minutes.
    private static let idleTickSeconds = 60.0

    public init(cache: ParakeetModelCache, log: @escaping (String) -> Void, idleUnloadMs: Int = 1_800_000) {
        self.cache = cache
        self.log = log
        self.idleUnloadMs = idleUnloadMs
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
            warming: warming && !loaded ? true : nil
        )
    }

    /// Downloads the artifact if needed, loads the model, and runs one throwaway decode.
    ///
    /// The throwaway decode is not superstition: the first `parakeet_full` of a process pays
    /// 58-348 ms materialising Metal pipelines, and the very first run of a given binary on a
    /// machine additionally compiles the embedded shader library (about 7.5 s, then cached by
    /// the OS). Paying both here keeps them off the user's first dictation.
    public func warmUp() throws {
        withState { $0.warmingInProgress = true }
        defer {
            withState {
                $0.warmingInProgress = false
                $0.downloadFraction = nil
            }
        }
        try cache.ensureModel { fraction in
            self.withState { $0.downloadFraction = fraction }
            self.log(String(format: "VOICEOUR_PRELOAD download %.0f%%", fraction * 100))
        }
        withState { $0.downloadFraction = nil }
        let context = try loadContext()
        _ = try decode(context, samples: [Float](repeating: 0, count: 8000), isCancelled: { false })
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
        context = nil
        stateLock.unlock()
        _ = released
    }

    public func transcribe(
        _ request: ASRTranscribeRequest,
        isCancelled: @escaping () -> Bool
    ) -> SidecarTerminal {
        if isCancelled() { return .cancelled }

        let samples: [Float]
        let context: ParakeetContext
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
        let segments: [ParakeetSegmentRaw]
        do {
            segments = try decode(context, samples: samples, isCancelled: isCancelled)
        } catch {
            // A client `cancel` trips parakeet.cpp's abort callback, and `parakeet_full` reports
            // that as a plain -6 rather than a distinct status. Answer the cancel that was asked
            // for instead of inventing an inference failure.
            if isCancelled() { return .cancelled }
            return .failure(code: .inferenceFailed, detail: String(describing: error), fatal: true)
        }
        let inferenceMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        if isCancelled() { return .cancelled }

        stateLock.lock()
        let loadMs = self.loadMs
        stateLock.unlock()

        return .result(
            transcript: TokenMapping.transcript(from: segments),
            backendId: backendId,
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision,
            timings: ASRTimings(load: loadMs, inference: inferenceMs, total: loadMs + inferenceMs)
        )
    }

    private enum Preparation {
        case ready([Float], ParakeetContext)
        case failure(code: ASRErrorCode, detail: String?)
    }

    /// Everything that can fail before the decode: request shape, model availability,
    /// audio decoding and model load, in the order the retired Python backend applied them.
    private func prepare(_ request: ASRTranscribeRequest) -> Preparation {
        let audioURL: URL
        switch SidecarRequestValidation.validate(
            request,
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision
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
    /// `cacheOK()` only checks the size, because hashing 1.26 GB on every start would dominate
    /// the cold path. A load failure is the one moment where paying that 1-2 s is worth it: a
    /// truncated-then-padded or bit-rotted cache is otherwise indistinguishable from a broken
    /// runtime, and the user sees a permanent failure instead of a re-download.
    private func loadFailure(_ detail: String) -> Preparation {
        guard !cache.verifyModelDigestOnDisk() else {
            return .failure(code: .modelLoadFailed, detail: detail)
        }
        log("cached model failed digest re-verification after a load failure; removing it")
        try? FileManager.default.removeItem(at: cache.modelURL)
        try? FileManager.default.removeItem(at: cache.manifestURL)
        return .failure(
            code: .modelNotInstalled,
            detail: "cached model failed digest re-verification and was removed; it will be re-downloaded"
        )
    }

    /// Creates the context on first use, exactly once.
    ///
    /// Callers are the decode queue and the preload thread. The load lock is held across
    /// construction rather than only around the state update: a "build then discard the loser"
    /// race destroys a live Metal device, which is not recoverable in-process.
    private func loadContext() throws -> ParakeetContext {
        if let existing = currentContext() { return existing }

        loadLock.lock()
        defer { loadLock.unlock() }
        if let existing = currentContext() { return existing }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let created = try ParakeetContext(modelPath: cache.modelURL.path)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            stateLock.lock()
            context = created
            loadMs = elapsed
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
        // A decode owns the context for its whole duration. Skip this tick rather than make the
        // user wait behind a timer that only ever needs to be approximately right.
        guard decodeLock.try() else { return }
        defer { decodeLock.unlock() }

        stateLock.lock()
        let idleMs = Self.elapsedMs(from: lastDecodeEndedAt, to: .now())
        let released = context
        context = nil
        stateLock.unlock()

        guard released != nil else { return }
        log("idle unload after \(idleMs)ms; the next dictation reloads (~314 ms plus a warm decode)")
    }

    private func currentContext() -> ParakeetContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context
    }

    /// Runs one decode with the context held exclusively.
    ///
    /// The server already serializes real transcribes on one queue, but the preload thread's
    /// throwaway decode does not run there, and `parakeet_full` is documented as not thread safe
    /// for the same context.
    private func decode(_ context: ParakeetContext, samples: [Float], isCancelled: @escaping () -> Bool) throws
        -> [ParakeetSegmentRaw]
    {
        decodeLock.lock()
        defer {
            withState { $0.lastDecodeEndedAt = DispatchTime.now() }
            decodeLock.unlock()
        }
        return try context.transcribe(samples: samples, isCancelled: isCancelled)
    }
}
