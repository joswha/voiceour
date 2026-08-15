import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

// MARK: - Scripted transport

/// One scripted answer. `status` 200 means the server sends the whole body from byte zero
/// whatever the request asked for; 206 means it honours the request's `Range` header.
struct ScriptedResponse {
    var status: Int
    /// Deliver this many bytes of the chosen slice and then drop the connection. Nil sends all.
    var truncateAfter: Int?

    init(status: Int, truncateAfter: Int? = nil) {
        self.status = status
        self.truncateAfter = truncateAfter
    }
}

/// A `URLProtocol` that replays a script, one entry per request.
///
/// The real `ParakeetModelCache` transfer runs through it unchanged: same delegate, same sink,
/// same digest. Only the bytes' origin is substituted, which is the point — the resume, restart
/// and retry paths are exactly what a network cannot be asked to reproduce on demand.
final class ScriptedDownloadProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [ScriptedResponse] = []
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var seenRangeHeaders: [String?] = []

    static func install(payload: Data, script: [ScriptedResponse]) {
        lock.lock()
        defer { lock.unlock() }
        Self.payload = payload
        Self.script = script
        Self.seenRangeHeaders = []
    }

    static var rangeHeaders: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return seenRangeHeaders
    }

    private static func take(rangeHeader: String?) -> (ScriptedResponse, Data)? {
        lock.lock()
        defer { lock.unlock() }
        seenRangeHeaders.append(rangeHeader)
        guard !script.isEmpty else { return nil }
        return (script.removeFirst(), payload)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        guard let (step, payload) = Self.take(rangeHeader: rangeHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        var offset = 0
        var headers: [String: String] = [:]
        if step.status == 206, let rangeHeader,
            let start = Int(rangeHeader.dropFirst("bytes=".count).split(separator: "-").first ?? "")
        {
            offset = min(start, payload.count)
            headers["Content-Range"] = "bytes \(offset)-\(payload.count - 1)/\(payload.count)"
        }
        let slice = payload.subdata(in: offset..<payload.count)
        let delivered = step.truncateAfter.map { Data(slice.prefix($0)) } ?? slice
        // No Content-Length: a truncated body that contradicts one makes URLSession replace the
        // connection error with badServerResponse and drop the bytes it had already delivered,
        // which is the opposite of the partial this suite is about.

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: step.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Chunked and off the calling thread so the delegate observes bytes before the failure,
        // the way a dropped TCP connection actually presents.
        Self.deliveryQueue.async { [weak self] in
            guard let self else { return }
            var index = 0
            while index < delivered.count {
                let end = min(index + 256, delivered.count)
                self.client?.urlProtocol(self, didLoad: delivered.subdata(in: index..<end))
                index = end
                Thread.sleep(forTimeInterval: 0.0005)
            }
            if step.truncateAfter == nil {
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
    }

    private static let deliveryQueue = DispatchQueue(label: "voiceour.tests.scripted-download")

    override func stopLoading() {}
}

// MARK: - Suite

@Suite("DownloadResumeTests", .serialized)
struct DownloadResumeTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-resume-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 4 KiB of deterministic bytes: large enough that a truncated prefix is a real partial.
    private let payload = Data((0..<4096).map { UInt8($0 % 251) })

    private func artifact(for bytes: Data) -> ParakeetModelManifest {
        ParakeetModelManifest(
            modelId: "test/tiny",
            revision: "0123456789abcdef",
            file: "tiny.bin",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(bytes.count)
        )
    }

    private func makeCache(directory: URL) -> ParakeetModelCache {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDownloadProtocol.self]
        return ParakeetModelCache(
            directory: directory,
            artifact: artifact(for: payload),
            source: URL(string: "https://example.invalid/tiny.bin")!,
            sessionConfiguration: configuration,
            retryDelay: 0
        )
    }

    @Test func aDroppedConnectionResumesFromThePartialFile() throws {
        ScriptedDownloadProtocol.install(
            payload: payload,
            script: [ScriptedResponse(status: 200, truncateAfter: 1000), ScriptedResponse(status: 206)]
        )
        let cache = makeCache(directory: temporaryDirectory())

        try cache.ensureModel()

        #expect(cache.cacheOK())
        #expect(try Data(contentsOf: cache.modelURL) == payload)
        let manifest = try #require(cache.manifest())
        #expect(manifest.sizeBytes == Int64(payload.count))
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path + ".download"))
        // The first attempt asks for the whole file; the second resumes at the byte it reached.
        #expect(ScriptedDownloadProtocol.rangeHeaders == [nil, "bytes=1000-"])
    }

    @Test func aRangeRequestAnsweredWith200RestartsCleanly() throws {
        ScriptedDownloadProtocol.install(
            payload: payload,
            script: [ScriptedResponse(status: 200, truncateAfter: 1000), ScriptedResponse(status: 200)]
        )
        let cache = makeCache(directory: temporaryDirectory())

        try cache.ensureModel()

        // The server ignored the Range header and replayed from zero. Appending would have
        // produced 5096 bytes and a digest mismatch; the sink truncates instead.
        #expect(cache.cacheOK())
        #expect(try Data(contentsOf: cache.modelURL) == payload)
        #expect(ScriptedDownloadProtocol.rangeHeaders == [nil, "bytes=1000-"])
    }

    @Test func threeFailuresThrowAndKeepThePartialForALaterCall() throws {
        ScriptedDownloadProtocol.install(
            payload: payload,
            // Above 512 bytes per attempt: URLSession buffers a smaller body and discards it
            // when the task then fails, which would test the stub rather than the resume.
            script: [
                ScriptedResponse(status: 200, truncateAfter: 1000),
                ScriptedResponse(status: 206, truncateAfter: 1000),
                ScriptedResponse(status: 206, truncateAfter: 1000),
            ]
        )
        let directory = temporaryDirectory()
        let cache = makeCache(directory: directory)

        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
        #expect(!cache.cacheOK())

        // The partial survives: 1.26 GB is not re-fetched because three connections died.
        let temporaryURL = URL(fileURLWithPath: cache.modelURL.path + ".download")
        let partial = try Data(contentsOf: temporaryURL)
        #expect(partial.count == 3000)
        #expect(ScriptedDownloadProtocol.rangeHeaders == [nil, "bytes=1000-", "bytes=2000-"])

        // A later call — a later process, in production — picks the transfer back up.
        ScriptedDownloadProtocol.install(payload: payload, script: [ScriptedResponse(status: 206)])
        try cache.ensureModel()

        #expect(cache.cacheOK())
        #expect(try Data(contentsOf: cache.modelURL) == payload)
        #expect(ScriptedDownloadProtocol.rangeHeaders == ["bytes=3000-"])
    }

    @Test func aServerErrorIsNotRetriedIntoASuccessWithoutAGoodBody() throws {
        ScriptedDownloadProtocol.install(
            payload: payload,
            script: [
                ScriptedResponse(status: 503),
                ScriptedResponse(status: 503),
                ScriptedResponse(status: 503),
            ]
        )
        let cache = makeCache(directory: temporaryDirectory())

        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
        #expect(!cache.cacheOK())
    }

    @Test func digestReverificationCatchesACorruptCacheThatStillHasTheRightSize() throws {
        ScriptedDownloadProtocol.install(payload: payload, script: [ScriptedResponse(status: 200)])
        let cache = makeCache(directory: temporaryDirectory())
        try cache.ensureModel()

        #expect(cache.cacheOK())
        #expect(cache.verifyModelDigestOnDisk())

        // Same length, different bytes: exactly what bit rot or a truncated-then-padded copy
        // leaves behind, and exactly what the size-only cacheOK() cannot see.
        var corrupt = payload
        corrupt[0] = corrupt[0] &+ 1
        try corrupt.write(to: cache.modelURL)

        #expect(cache.cacheOK())
        #expect(!cache.verifyModelDigestOnDisk())
    }
}
