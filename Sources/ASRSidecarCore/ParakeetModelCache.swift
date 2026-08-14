import CryptoKit
import Foundation
import VoiceCore

/// Failures the cache raises on its own; anything else surfaces as the underlying error.
public enum ParakeetModelCacheError: Error, Equatable, CustomStringConvertible {
    /// A manifest exists but names a different model or revision. Never overwritten
    /// automatically: the directory may hold a deliberately pinned older artifact.
    case manifestMismatch(String)
    /// The downloaded bytes did not match the pinned size or digest.
    case artifactMismatch(String)
    /// The transfer never produced the artifact.
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .manifestMismatch(let detail): return detail
        case .artifactMismatch(let detail): return detail
        case .downloadFailed(let detail): return detail
        }
    }
}

/// Identity of the one weight file the sidecar loads, and what gets written next to it.
///
/// `sizeBytes` is what later launches re-check; the digest is verified once, at download,
/// because hashing 1.26 GB on every start would dominate the sidecar's cold path.
public struct ParakeetModelManifest: Codable, Equatable, Sendable {
    public var modelId: String
    public var revision: String
    public var file: String
    public var sha256: String
    public var sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case revision
        case file
        case sha256
        case sizeBytes = "size_bytes"
    }

    public init(modelId: String, revision: String, file: String, sha256: String, sizeBytes: Int64) {
        self.modelId = modelId
        self.revision = revision
        self.file = file
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    /// The artifact this build ships against.
    public static let pinned = ParakeetModelManifest(
        modelId: ASRModelContract.modelId,
        revision: ASRModelContract.revision,
        file: ASRModelContract.fileName,
        sha256: ASRModelContract.sha256,
        sizeBytes: ASRModelContract.sizeBytes
    )
}

/// The app-owned directory holding one pinned GGUF weight file plus its manifest.
///
/// Unlike the Hugging Face snapshot layout it replaces, this is a flat directory with two
/// entries and no shared global cache: the sidecar owns it, and deleting it is a complete
/// uninstall of the model.
public struct ParakeetModelCache: Sendable {
    public let directory: URL
    /// What must be in the directory. Defaults to the shipped pin; tests substitute a
    /// small artifact so the real download, verify and rename path is exercised for real.
    public let artifact: ParakeetModelManifest
    public let source: URL

    public init(
        directory: URL,
        artifact: ParakeetModelManifest = .pinned,
        source: URL = ASRModelContract.downloadURL
    ) {
        self.directory = directory
        self.artifact = artifact
        self.source = source
    }

    /// `VOICEOUR_MODEL_CACHE` when set, else the app cache directory.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ParakeetModelCache {
        if let override = environment["VOICEOUR_MODEL_CACHE"], !override.isEmpty {
            return ParakeetModelCache(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ParakeetModelCache(
            directory:
                caches
                .appendingPathComponent("Voiceour", isDirectory: true)
                .appendingPathComponent("parakeet-tdt-0.6b-v3-ggml", isDirectory: true)
        )
    }

    public var modelURL: URL { directory.appendingPathComponent(artifact.file) }
    public var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    public func manifest() -> ParakeetModelManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ParakeetModelManifest.self, from: data)
    }

    /// True when the pinned artifact is present and complete enough to load.
    public func cacheOK() -> Bool {
        guard let manifest = manifest() else { return false }
        guard manifest.modelId == artifact.modelId else { return false }
        guard manifest.revision == artifact.revision else { return false }
        guard let size = fileSize(at: modelURL) else { return false }
        return size == manifest.sizeBytes
    }

    /// Downloads the pinned artifact if it is not already cached.
    ///
    /// Verifies size and SHA-256 before the file is moved into place, so a partial or corrupt
    /// download can never be mistaken for a good cache by a later launch. `progress` reports
    /// 0...1 and is called at most once per 5% of the transfer.
    public func ensureModel(progress: ((Double) -> Void)? = nil) throws {
        if cacheOK() { return }
        try requirePinnedManifestOrAbsent()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(artifact.file + ".download")
        try? FileManager.default.removeItem(at: temporaryURL)

        let digest = try streamArtifact(to: temporaryURL, progress: progress)
        try verify(temporaryURL, digest: digest)

        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: temporaryURL, to: modelURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: manifestURL, options: .atomic)
    }

    private func requirePinnedManifestOrAbsent() throws {
        guard let existing = manifest() else { return }
        let matches = existing.modelId == artifact.modelId && existing.revision == artifact.revision
        guard matches else {
            throw ParakeetModelCacheError.manifestMismatch(
                "manifest has model_id=\(existing.modelId) revision=\(existing.revision)"
            )
        }
    }

    private func verify(_ url: URL, digest: String) throws {
        let size = fileSize(at: url) ?? -1
        guard size == artifact.sizeBytes else {
            try? FileManager.default.removeItem(at: url)
            throw ParakeetModelCacheError.artifactMismatch(
                "downloaded \(size) bytes, expected \(artifact.sizeBytes)"
            )
        }
        guard digest == artifact.sha256 else {
            try? FileManager.default.removeItem(at: url)
            throw ParakeetModelCacheError.artifactMismatch("sha256 \(digest), expected \(artifact.sha256)")
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Streams the artifact to `destination` and returns its lowercase hex SHA-256.
    ///
    /// Hand-rolled rather than `URLSession.download` because the digest has to be computed as
    /// the bytes arrive: buffering 1.26 GB to hash afterwards is the one thing a model download
    /// on a laptop must not do. Blocking is deliberate — the only caller is a worker thread.
    private func streamArtifact(to destination: URL, progress: ((Double) -> Void)?) throws -> String {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ParakeetModelCacheError.downloadFailed("cannot create \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let sink = ArtifactSink(handle: handle, expectedBytes: artifact.sizeBytes, progress: progress)
        let delegate = StreamingDownloadDelegate(sink: sink)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        session.dataTask(with: source).resume()
        sink.waitUntilFinished()

        if let error = sink.failure {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try handle.synchronize()
        return sink.digest()
    }
}

/// Hashes and writes the streamed bytes, and carries the completion signal.
///
/// Every method runs on the session's serial delegate queue except `waitUntilFinished`
/// and the post-completion reads, which are ordered behind the semaphore.
private final class ArtifactSink: @unchecked Sendable {
    private let handle: FileHandle
    private let expectedBytes: Int64
    private let progress: ((Double) -> Void)?
    private let semaphore = DispatchSemaphore(value: 0)
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var lastReportedBucket = -1

    private(set) var failure: Error?

    init(handle: FileHandle, expectedBytes: Int64, progress: ((Double) -> Void)?) {
        self.handle = handle
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func accept(response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        guard http.statusCode == 200 else {
            failure = ParakeetModelCacheError.downloadFailed("HTTP \(http.statusCode)")
            return false
        }
        return true
    }

    func accept(data: Data) -> Bool {
        hasher.update(data: data)
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            return false
        }
        written += Int64(data.count)
        let fraction = expectedBytes > 0 ? Double(written) / Double(expectedBytes) : 1
        let bucket = Int(fraction * 20)
        if bucket != lastReportedBucket {
            lastReportedBucket = bucket
            progress?(min(1, fraction))
        }
        return true
    }

    func finish(error: Error?) {
        if let error, failure == nil { failure = error }
        semaphore.signal()
    }

    func waitUntilFinished() { semaphore.wait() }

    func digest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let sink: ArtifactSink

    init(sink: ArtifactSink) {
        self.sink = sink
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(sink.accept(response: response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !sink.accept(data: data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sink.finish(error: error)
    }
}
