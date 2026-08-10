import Darwin
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Test doubles and helpers shared across the `VoiceMac` test target.
///
/// Swift test targets cannot import one another, so each target keeps its own
/// support file. Helpers live here when more than one test file needs them;
/// single-consumer, behaviour-specific doubles stay private to their own file.

// MARK: HTTP stubbing

enum TestSupportError: Error {
    case missingHandler
    case missingHTTPBody
    case invalidHTTPBody
    case bodyStreamReadFailed
}

/// Answers every request on one `HTTPStub`'s session from that stub's handler.
///
/// Routing is per session, not process-wide. A single shared `static handler` was
/// tried first and raced: `.serialized` orders tests *within* a suite, so two HTTP
/// suites running concurrently answered each other's requests. Each stub stamps a
/// token into its session's additional headers and this class dispatches on it.
final class TestURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    static let tokenHeader = "X-VoiceOour-Test-Stub"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func handler(for token: String) -> Handler? {
        lock.withLock { handlers[token] }
    }

    static func setHandler(_ handler: Handler?, for token: String) {
        lock.withLock { handlers[token] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard
                let token = request.value(forHTTPHeaderField: Self.tokenHeader),
                let handler = Self.handler(for: token)
            else { throw TestSupportError.missingHandler }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A `URLSession` whose responses come from `handler`, scoped to this instance.
///
/// Reassign `handler` mid-test to script a sequence of responses. There is no
/// teardown to forget: the handler dies with the stub.
final class HTTPStub: @unchecked Sendable {
    let session: URLSession
    private let token = UUID().uuidString

    var handler: TestURLProtocol.Handler? {
        get { TestURLProtocol.handler(for: token) }
        set { TestURLProtocol.setHandler(newValue, for: token) }
    }

    init(handler: TestURLProtocol.Handler? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        var headers = config.httpAdditionalHeaders ?? [:]
        headers[TestURLProtocol.tokenHeader] = token
        config.httpAdditionalHeaders = headers
        session = URLSession(configuration: config)
        self.handler = handler
    }

    deinit {
        TestURLProtocol.setHandler(nil, for: token)
    }
}

/// A minimal OpenAI-compatible chat-completion body whose single choice carries
/// `{"final_text": …}` as its message content.
func chatCompletionResponse(url: URL, finalText: String) throws -> (HTTPURLResponse, Data) {
    let finalTextData = try JSONSerialization.data(withJSONObject: ["final_text": finalText])
    let finalTextJSON = String(data: finalTextData, encoding: .utf8)!
    let body = try JSONSerialization.data(withJSONObject: [
        "choices": [
            ["message": ["content": finalTextJSON]]
        ]
    ])
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (response, body)
}

/// `URLRequest.httpBody` is nil for stream-backed bodies, which is how
/// `URLSession` hands uploads to a `URLProtocol`; drain the stream instead.
func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw TestSupportError.missingHTTPBody }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else if count == 0 {
            break
        } else {
            throw stream.streamError ?? TestSupportError.bodyStreamReadFailed
        }
    }
    return data
}

/// Records the last request a stubbed session saw, decoded as JSON plus the raw
/// bytes, so a test can assert on either representation.
final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: [String: Any]?
    private var storedRawBody: Data?

    func record(_ request: URLRequest) throws {
        let data = try requestBodyData(request)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestSupportError.invalidHTTPBody
        }
        lock.lock()
        storedRequest = request
        storedBody = body
        storedRawBody = data
        lock.unlock()
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    var rawBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedRawBody
    }
}

// MARK: Async coordination

/// A one-shot async gate: `wait()` suspends until some other task calls
/// `fire()`. Used to hold a fake mid-flight so a test can observe intermediate
/// state. Deliberately ignores task cancellation — the point is to model work
/// that keeps running after its caller gives up.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openState
    }

    func fire() {
        lock.lock()
        openState = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if openState {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Polls `condition` until it holds or `timeout` elapses. Returning on timeout
/// rather than failing is deliberate: the caller asserts the condition after,
/// so the failure message names the state rather than the wait.
func waitUntilTimeoutCondition(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

func makeExecutableScript(_ body: String) throws -> (directory: URL, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceMacOmpTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-omp.sh")
    try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (directory, script)
}

func processIDs(in file: URL) -> [pid_t] {
    guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return
        contents
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { pid_t($0) }
}

/// The scripts below record their pid as their first act, but a loaded test
/// run can spawn slower than the deadline under test. Poll so a launch that
/// lost the race to the (correctly enforced) timeout does not read as an
/// unlaunched process.
func awaitProcessIDs(in file: URL, count: Int = 1) async -> [pid_t] {
    for _ in 0..<100 {
        let pids = processIDs(in: file)
        if pids.count >= count { return pids }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return processIDs(in: file)
}

func waitForProcessExit(_ pid: pid_t) async -> Bool {
    for _ in 0..<100 {
        if kill(pid, 0) == -1, errno == ESRCH {
            return true
        }
        if Task.isCancelled {
            return false
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return kill(pid, 0) == -1 && errno == ESRCH
}

func fellBackText(_ outcome: RefineOutcome) -> String? {
    guard case .fellBack(let value, _) = outcome else { return nil }
    return value
}

struct FakePermissions: PermissionsChecking {
    var synth: PermissionState
    var requestSynth = false
    func microphone() -> PermissionState { .granted }
    func synthPaste() -> PermissionState { synth }
    func requestSynthPaste() async -> Bool { requestSynth }
    func accessibility() -> PermissionState { .denied }
}
