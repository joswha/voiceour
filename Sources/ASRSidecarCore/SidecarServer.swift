import Foundation
import VoiceCore

protocol ShutdownAwareSidecarPreloading: AnyObject {
    func warmUp(isShuttingDown: @escaping () -> Bool) throws
}

/// The NDJSON protocol loop.
///
/// One line of JSON per message on stdout and nothing else, ever: stderr carries diagnostics.
/// Requests are multiplexed by `request_id`; the reader thread stays responsive so `health`
/// and `cancel` are answered while a decode is running.
public final class SidecarServer {
    public static let sidecarVersion = "1.0.0"

    /// Ceiling on how long EOF waits for accepted requests to answer. Two minutes covers a cold
    /// model load plus the longest decode this runtime is asked for; past it the process is
    /// assumed wedged and exits without teardown.
    static let eofGraceSeconds: TimeInterval = 120
    /// Preload gets a short bounded join of its own before request draining. If it cannot stop,
    /// `_exit` is safer than running ggml's static destructors against live Metal buffers.
    static let preloadGraceSeconds: TimeInterval = 5

    private let backend: SidecarBackend?
    private let output: SidecarOutput
    private let log: (String) -> Void
    private let preloadEnabled: Bool
    private let lifecycleLock = NSLock()
    private var shutdownRequested = false

    var isShuttingDown: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return shutdownRequested
    }

    /// Decodes are serialized: the parakeet context is not thread safe, and the retired
    /// Python sidecar serialized them the same way through a single-worker executor.
    private let decodeQueue = DispatchQueue(label: "voiceour.asr.decode")
    private let inflight = InflightRegistry()

    /// `backend` is nil when `VOICEOUR_ASR_BACKEND` names something unrecognized. That is a
    /// reportable state, not a crash: the sidecar still speaks the protocol and answers every
    /// request with `backend_unavailable` so the app can show why dictation is not working.
    public init(
        backend: SidecarBackend?,
        output: SidecarOutput,
        log: @escaping (String) -> Void,
        preloadEnabled: Bool
    ) {
        self.backend = backend
        self.output = output
        self.log = log
        self.preloadEnabled = preloadEnabled
    }

    /// Emits `hello`, then serves until stdin reaches EOF. Returns the process exit code.
    public func run(input: FileHandle) -> Int32 {
        emitHello()
        let preloadCompletion = startPreloadIfRequested()

        let reader = LineReader(handle: input)
        while let line = reader.next() {
            handle(line: line)
        }

        beginShutdown()
        if let preloadCompletion,
            preloadCompletion.wait(timeout: .now() + Self.preloadGraceSeconds) == .timedOut
        {
            log("shutdown: preload still running after grace; exiting without teardown")
            _exit(0)
        }

        // A request the server accepted is owed its terminal, so EOF waits for the in-flight
        // set rather than cutting it off. 0.2 s used to be the whole grace, which was invisible
        // while every test used the fake backend: with the real one, EOF lands during the 3.5 s
        // model load and every accepted transcribe was truncated to nothing.
        //
        // Bounded all the same. In production EOF only happens because the parent is tearing
        // the child down, and the parent terminates it anyway, so a generous ceiling costs
        // nothing and a wedged decode still cannot hold the process open forever.
        inflight.waitForCompletion(timeout: Self.eofGraceSeconds)
        // Drain the decode queue before tearing the backend down, so a request that is still
        // holding the context cannot race the release.
        let drained = DispatchSemaphore(value: 0)
        decodeQueue.async { drained.signal() }
        if drained.wait(timeout: .now() + 0.3) == .timedOut {
            log("shutdown: decode still running after grace; exiting without teardown")
            // Deliberately skips C++ static destructors: a live context at `exit()` would
            // SIGABRT inside ggml's Metal-device destructor, which asserts that no residency
            // set still holds one of its buffers.
            _exit(0)
        }
        backend?.shutdown()
        return 0
    }

    private func emitHello() {
        let hello = ASRHello(
            sidecarVersion: Self.sidecarVersion,
            backendId: backend?.backendId ?? "unknown",
            backendStatus: backend?.startupStatus() ?? .backendUnavailable,
            capabilities: ASRCapabilities(finalUtterance: true)
        )
        output.emit(hello)
    }

    private func beginShutdown() {
        lifecycleLock.lock()
        shutdownRequested = true
        lifecycleLock.unlock()
    }

    private func startPreloadIfRequested() -> DispatchSemaphore? {
        guard preloadEnabled, let backend else { return nil }
        let completed = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self, log] in
            defer { completed.signal() }
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                guard !isShuttingDown else { return }
                if let controlled = backend as? ShutdownAwareSidecarPreloading {
                    try controlled.warmUp(isShuttingDown: { self.isShuttingDown })
                } else {
                    try backend.warmUp()
                }
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                log("VOICEOUR_PRELOAD warm in \(elapsed)ms")
            } catch {
                log("VOICEOUR_PRELOAD failed: \(error)")
            }
        }
        return completed
    }

    // MARK: - Dispatch

    private func handle(line: String) {
        switch SidecarRequestParser.parse(line) {
        case .malformed(let error):
            output.emit(error)
        case .health(let request):
            guard let backend = requireBackend(requestId: request.requestId) else { return }
            let health = backend.health()
            output.emit(
                ASRHealthResponse(
                    requestId: request.requestId,
                    ready: health.ready,
                    modelLoaded: health.modelLoaded,
                    cacheOk: health.cacheOk,
                    downloadFraction: health.downloadFraction,
                    warming: health.warming
                )
            )
        case .cancel(let request):
            guard requireBackend(requestId: request.requestId) != nil else { return }
            // An unknown or already-finished id is ignored: the worker owns the terminal
            // message, and a late cancel must not manufacture a second one.
            inflight.cancel(request.requestId)
        case .transcribe(let request):
            guard let backend = requireBackend(requestId: request.requestId) else { return }
            start(request, on: backend) { backend.transcribe($0, isCancelled: $1) }
        }
    }

    private func requireBackend(requestId: String?) -> SidecarBackend? {
        guard let backend else {
            output.emit(ASRErrorMessage(code: .backendUnavailable, requestId: requestId, detail: "unknown backend"))
            return nil
        }
        return backend
    }

    /// Registers, runs and answers one decode request. `decode` selects which backend entry
    /// point runs; everything else — duplicate-id rejection, the single terminal, cancellation
    /// and the fatal-exit check — is shared.
    private func start(
        _ request: ASRTranscribeRequest,
        on backend: SidecarBackend,
        decode: @escaping (ASRTranscribeRequest, @escaping () -> Bool) -> SidecarTerminal
    ) {
        guard let token = inflight.register(request.requestId) else {
            output.emit(
                ASRErrorMessage(
                    code: .invalidRequest,
                    requestId: request.requestId,
                    detail: "request_id already in flight"
                )
            )
            return
        }
        decodeQueue.async { [output, inflight, log, backend] in
            let terminal = decode(request, { token.isCancelled })
            output.emit(terminal: terminal, requestId: request.requestId)
            inflight.finish(request.requestId)
            if case .failure(_, _, fatal: true) = terminal {
                log("fatal backend failure; exiting so the client respawns a clean process")
                backend.shutdown()
                exit(70)  // EX_SOFTWARE
            }
        }
    }
}

// MARK: - Output

/// Serializes every stdout write. Nothing but protocol JSON is allowed through here.
public final class SidecarOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func emit<T: Encodable>(_ message: T) {
        guard let line = try? ASRWire.encodeLine(message) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: line)
    }

    func emit(terminal: SidecarTerminal, requestId: String) {
        switch terminal {
        case .result(let transcript, let backendId, let modelId, let modelRevision, let timings):
            emit(
                ASRResult(
                    requestId: requestId,
                    backendId: backendId,
                    modelId: modelId,
                    modelRevision: modelRevision,
                    transcript: transcript,
                    timingsMs: timings
                )
            )
        case .failure(let code, let detail, _):
            emit(ASRErrorMessage(code: code, requestId: requestId, detail: detail))
        case .cancelled:
            emit(ASRCancelledMessage(requestId: requestId))
        }
    }
}

// MARK: - In-flight requests

/// One cancellation flag per in-flight request, readable from the decode queue.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Tracks which request ids are running so duplicates are rejected, cancels reach the right
/// worker, and EOF can give in-flight work a bounded grace period.
final class InflightRegistry: @unchecked Sendable {
    private let lock = NSCondition()
    private var tokens: [String: CancellationToken] = [:]

    /// Returns nil when the id is already running.
    func register(_ requestId: String) -> CancellationToken? {
        lock.lock()
        defer { lock.unlock() }
        if tokens[requestId] != nil { return nil }
        let token = CancellationToken()
        tokens[requestId] = token
        return token
    }

    func cancel(_ requestId: String) {
        lock.lock()
        let token = tokens[requestId]
        lock.unlock()
        token?.cancel()
    }

    func finish(_ requestId: String) {
        lock.lock()
        tokens[requestId] = nil
        let empty = tokens.isEmpty
        if empty { lock.broadcast() }
        lock.unlock()
    }

    func waitForCompletion(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while !tokens.isEmpty, lock.wait(until: deadline) {}
        lock.unlock()
    }
}

// MARK: - Parsing

/// Splits stdin into lines without assuming the client writes one line per `write`.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var atEOF = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(bytes: line, encoding: .utf8) ?? ""
            }
            if atEOF {
                guard !buffer.isEmpty else { return nil }
                let line = String(bytes: buffer, encoding: .utf8) ?? ""
                buffer.removeAll()
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                atEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}

/// Turns a line into one of the three request types, or the error the client should see.
///
/// Version and type are read from the raw object before the typed decode so that a message
/// from an incompatible client still gets its `request_id` echoed back.
enum SidecarRequestParser {
    enum Parsed {
        case health(ASRHealthRequest)
        case transcribe(ASRTranscribeRequest)
        case cancel(ASRCancelRequest)
        case malformed(ASRErrorMessage)
    }

    static func parse(_ line: String) -> Parsed {
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed(
                ASRErrorMessage(code: .invalidRequest, requestId: nil, detail: "line is not a JSON object")
            )
        }
        let requestId = object["request_id"] as? String
        guard object["protocol_version"] as? Int == asrProtocolVersion else {
            return .malformed(
                ASRErrorMessage(
                    code: .incompatibleProtocol,
                    requestId: requestId,
                    detail: "protocol_version mismatch"
                )
            )
        }

        do {
            switch object["type"] as? String {
            case "health":
                return .health(try ASRWire.decode(ASRHealthRequest.self, from: data))
            case "transcribe":
                return .transcribe(try ASRWire.decode(ASRTranscribeRequest.self, from: data))
            case "cancel":
                return .cancel(try ASRWire.decode(ASRCancelRequest.self, from: data))
            case let other:
                let described = other.map { "'\($0)'" } ?? "nil"
                return .malformed(
                    ASRErrorMessage(code: .invalidRequest, requestId: requestId, detail: "unknown type \(described)")
                )
            }
        } catch {
            return .malformed(
                ASRErrorMessage(code: .invalidRequest, requestId: requestId, detail: String(describing: error))
            )
        }
    }
}
