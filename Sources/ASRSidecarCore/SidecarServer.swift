import Foundation
import VoiceCore

/// The NDJSON protocol loop.
///
/// One line of JSON per message on stdout and nothing else, ever: stderr carries diagnostics.
/// Requests are multiplexed by `request_id`; the reader thread stays responsive so `health`
/// and `cancel` are answered while a decode is running.
public final class SidecarServer {
    public static let sidecarVersion = "1.0.0"

    private let backend: SidecarBackend?
    private let output: SidecarOutput
    private let log: (String) -> Void
    private let preloadEnabled: Bool

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
        startPreloadIfRequested()

        let reader = LineReader(handle: input)
        while let line = reader.next() {
            handle(line: line)
        }

        inflight.waitForCompletion(timeout: 0.2)
        // Drain the decode queue before tearing the backend down, so a request that is still
        // holding the context cannot race the release.
        decodeQueue.sync {}
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

    private func startPreloadIfRequested() {
        guard preloadEnabled, let backend else { return }
        Thread.detachNewThread { [log] in
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                try backend.warmUp()
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                log("VOICEOUR_PRELOAD warm in \(elapsed)ms")
            } catch {
                log("VOICEOUR_PRELOAD failed: \(error)")
            }
        }
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
                    cacheOk: health.cacheOk
                )
            )
        case .cancel(let request):
            guard requireBackend(requestId: request.requestId) != nil else { return }
            // An unknown or already-finished id is ignored: the worker owns the terminal
            // message, and a late cancel must not manufacture a second one.
            inflight.cancel(request.requestId)
        case .transcribe(let request):
            guard let backend = requireBackend(requestId: request.requestId) else { return }
            start(request, on: backend)
        }
    }

    private func requireBackend(requestId: String?) -> SidecarBackend? {
        guard let backend else {
            output.emit(SidecarErrors.message(.backendUnavailable, requestId: requestId, detail: "unknown backend"))
            return nil
        }
        return backend
    }

    private func start(_ request: ASRTranscribeRequest, on backend: SidecarBackend) {
        guard let token = inflight.register(request.requestId) else {
            output.emit(
                SidecarErrors.message(
                    .invalidRequest,
                    requestId: request.requestId,
                    detail: "request_id already in flight"
                )
            )
            return
        }
        decodeQueue.async { [output, inflight] in
            let terminal = backend.transcribe(request, isCancelled: { token.isCancelled })
            output.emit(terminal: terminal, requestId: request.requestId)
            inflight.finish(request.requestId)
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
        case .failure(let code, let detail):
            emit(SidecarErrors.message(code, requestId: requestId, detail: detail))
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
                SidecarErrors.message(.invalidRequest, requestId: nil, detail: "line is not a JSON object")
            )
        }
        let requestId = object["request_id"] as? String
        guard object["protocol_version"] as? Int == asrProtocolVersion else {
            return .malformed(
                SidecarErrors.message(
                    .incompatibleProtocol,
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
                    SidecarErrors.message(.invalidRequest, requestId: requestId, detail: "unknown type \(described)")
                )
            }
        } catch {
            return .malformed(
                SidecarErrors.message(.invalidRequest, requestId: requestId, detail: String(describing: error))
            )
        }
    }
}
