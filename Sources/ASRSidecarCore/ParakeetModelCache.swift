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
/// Later launches re-check every manifest field and the artifact's byte count. The artifact
/// bytes themselves are hashed at download and after a load failure, not on every cold start.
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

    /// The artifact for one variant of the pinned repository.
    public static func pinned(_ variant: ASRModelVariant) -> ParakeetModelManifest {
        ParakeetModelManifest(
            modelId: ASRModelContract.modelId,
            revision: ASRModelContract.revision,
            file: variant.fileName,
            sha256: variant.sha256,
            sizeBytes: variant.sizeBytes
        )
    }
}

/// The app-owned directory holding one pinned GGUF weight file plus its manifest.
///
/// Unlike the Hugging Face snapshot layout it replaces, this is a flat directory with two
/// entries and no shared global cache: the sidecar owns it, and deleting it is a complete
/// uninstall of the model.
public struct ParakeetModelCache: @unchecked Sendable {
    public let directory: URL
    /// What must be in the directory. Defaults to the shipped pin; tests substitute a
    /// small artifact so the real download, verify and rename path is exercised for real.
    public let artifact: ParakeetModelManifest
    public let source: URL
    /// Configuration every download attempt is made with. Tests inject one whose
    /// `protocolClasses` carries a stub so the resume, restart and retry paths run without a
    /// network; nothing else about the transfer is substituted.
    public let sessionConfiguration: URLSessionConfiguration
    /// Pause between download attempts. A test seam: the shipped value is a courtesy to a
    /// server that just dropped us, and a unit suite must not sleep through it.
    public let retryDelay: TimeInterval

    /// Attempts one `ensureModel` makes before giving up. Each resumes where the last stopped.
    public static let downloadAttempts = 3

    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    public init(
        directory: URL,
        artifact: ParakeetModelManifest = .pinned(.default),
        source: URL = ASRModelVariant.default.downloadURL,
        sessionConfiguration: URLSessionConfiguration = ParakeetModelCache.defaultSessionConfiguration(),
        retryDelay: TimeInterval = 2
    ) {
        self.directory = directory
        self.artifact = artifact
        self.source = source
        self.sessionConfiguration = sessionConfiguration
        self.retryDelay = retryDelay
    }

    /// The cache for one variant: `VOICEOUR_MODEL_CACHE` when set, else the app cache directory.
    ///
    /// The override names one explicit directory, so it deliberately does not gain a per-variant
    /// subdirectory: a caller who pins the path owns what lands there.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ParakeetModelCache {
        let variant = ASRModelVariant.resolved(environment[ASRModelVariant.environmentKey])
        if let override = environment["VOICEOUR_MODEL_CACHE"], !override.isEmpty {
            return ParakeetModelCache(
                directory: URL(fileURLWithPath: override, isDirectory: true),
                artifact: .pinned(variant),
                source: variant.downloadURL
            )
        }
        return ParakeetModelCache(
            directory: Self.variantDirectory(variant),
            artifact: .pinned(variant),
            source: variant.downloadURL
        )
    }

    private static func variantDirectory(_ variant: ASRModelVariant) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiceour", isDirectory: true)
            .appendingPathComponent(variant.cacheDirectoryName, isDirectory: true)
    }

    /// Deletes the cached artifacts of every variant other than this cache's own.
    ///
    /// Called once this cache's artifact is acquired and verified. Only one variant is ever
    /// wanted, so without this a switch would leave the superseded artifact — up to 1.26 GB —
    /// on disk forever.
    ///
    /// Resolved from this cache's own directory rather than from the caches root, so the rule is
    /// "retire my siblings" and a test can exercise it in a temporary directory. Skipped under
    /// `VOICEOUR_MODEL_CACHE`, whose single directory is the caller's to manage.
    public func removeSupersededVariants(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard (environment["VOICEOUR_MODEL_CACHE"] ?? "").isEmpty else { return }
        let parent = directory.deletingLastPathComponent()
        for variant in ASRModelVariant.allCases where variant.fileName != artifact.file {
            try? FileManager.default.removeItem(
                at: parent.appendingPathComponent(variant.cacheDirectoryName, isDirectory: true)
            )
        }
    }

    public var modelURL: URL { directory.appendingPathComponent(artifact.file) }
    public var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    public func manifest() -> ParakeetModelManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ParakeetModelManifest.self, from: data)
    }

    /// True only when the manifest exactly names this build's pin and the pinned file has the
    /// pinned byte count. Comparing every manifest field prevents a partial or hand-edited
    /// manifest from lending another artifact the pin's identity without hashing 1.26 GB on
    /// every launch.
    public func cacheOK() -> Bool {
        guard let manifest = manifest() else { return false }
        guard manifest.modelId == artifact.modelId else { return false }
        guard manifest.revision == artifact.revision else { return false }
        guard manifest.file == artifact.file else { return false }
        guard manifest.sha256 == artifact.sha256 else { return false }
        guard manifest.sizeBytes == artifact.sizeBytes else { return false }
        guard let size = fileSize(at: modelURL) else { return false }
        return size == artifact.sizeBytes
    }

    /// Downloads the pinned artifact if it is not already cached.
    ///
    /// Verifies size and SHA-256 before the file is moved into place, so a partial or corrupt
    /// download can never be mistaken for a good cache by a later launch. `progress` reports
    /// 0...1 and is called at most once per 5% of the transfer.
    ///
    /// A partial `.download` file is deliberately left in place on failure, both between
    /// attempts and across process restarts: 1.26 GB over a hotel connection is not something
    /// to start over because one TCP connection died.
    public func ensureModel(progress: ((Double) -> Void)? = nil) throws {
        if cacheOK() { return }
        try requireMatchingManifestOrAbsent()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(artifact.file + ".download")

        let digest = try streamArtifact(to: temporaryURL, progress: progress)
        try verify(temporaryURL, digest: digest)

        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: temporaryURL, to: modelURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: manifestURL, options: .atomic)
    }

    /// Refuses to overwrite a directory that already holds a different artifact.
    ///
    /// `file` is part of the comparison because every variant shares `modelId` and `revision`:
    /// on those two alone this guard would pass for any of them, and a download would clobber
    /// the manifest while leaving the previous weight file orphaned beside it.
    private func requireMatchingManifestOrAbsent() throws {
        guard let existing = manifest() else { return }
        let matches =
            existing.modelId == artifact.modelId && existing.revision == artifact.revision
            && existing.file == artifact.file
        guard matches else {
            throw ParakeetModelCacheError.manifestMismatch(
                "manifest has model_id=\(existing.modelId) revision=\(existing.revision) file=\(existing.file)"
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

    /// Verifies the cached model's bytes against the pinned digest.
    ///
    /// Not part of the normal path — `cacheOK()` checks the manifest pin and byte count, because
    /// hashing 1.26 GB on every start would dominate the cold path. This is what a *load failure*
    /// pays (~1-2 s) to tell a corrupt cache apart from a broken runtime.
    public func verifyModelDigestOnDisk() -> Bool {
        guard let size = fileSize(at: modelURL) else { return false }
        guard var hasher = try? Self.hashPrefix(of: modelURL, byteCount: size) else { return false }
        return Self.hexDigest(&hasher) == artifact.sha256
    }

    /// Streams the artifact to `destination` and returns its lowercase hex SHA-256.
    ///
    /// Hand-rolled rather than `URLSession.download` because the digest has to be computed as
    /// the bytes arrive: buffering 1.26 GB to hash afterwards is the one thing a model download
    /// on a laptop must not do. Blocking is deliberate — the only caller is a worker thread.
    ///
    /// Retries `downloadAttempts` times, resuming from whatever the previous attempt left on
    /// disk. The temporary file survives a failed attempt on purpose; only `verify` deletes it,
    /// because corrupt bytes must never seed a resume.
    private func streamArtifact(to destination: URL, progress: ((Double) -> Void)?) throws -> String {
        var lastError: Error = ParakeetModelCacheError.downloadFailed("no attempt was made")
        for attempt in 1...Self.downloadAttempts {
            if attempt > 1, retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
            do {
                return try attemptStream(to: destination, progress: progress)
            } catch {
                lastError = error
            }
        }
        throw ParakeetModelCacheError.downloadFailed(
            "\(Self.downloadAttempts) attempts failed, last: \(lastError)"
        )
    }

    /// One transfer. Resumes from `destination`'s existing bytes when there are any.
    private func attemptStream(to destination: URL, progress: ((Double) -> Void)?) throws -> String {
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ParakeetModelCacheError.downloadFailed("cannot create \(destination.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // Rehash what is already there rather than storing a partial hasher: SHA-256 state is
        // not serializable, and re-reading a partial file is disk-local and bounded.
        let existing = fileSize(at: destination) ?? 0
        var hasher = SHA256()
        if existing > 0 {
            hasher = try Self.hashPrefix(of: destination, byteCount: existing)
            try handle.seek(toOffset: UInt64(existing))
        }

        let sink = ArtifactSink(
            handle: handle,
            expectedBytes: artifact.sizeBytes,
            hasher: hasher,
            written: existing,
            resumeRequested: existing > 0,
            progress: progress
        )
        var request = URLRequest(url: source)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let delegate = StreamingDownloadDelegate(sink: sink)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        session.dataTask(with: request).resume()
        sink.waitUntilFinished()

        if let error = sink.failure { throw error }
        try handle.synchronize()
        return sink.digest()
    }

    /// Streams `byteCount` bytes of `url` through a fresh SHA-256, 1 MiB at a time.
    static func hashPrefix(of url: URL, byteCount: Int64) throws -> SHA256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            let wanted = Int(min(remaining, 1 << 20))
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hasher
    }

    static func hexDigest(_ hasher: inout SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
    private let resumeRequested: Bool
    private let semaphore = DispatchSemaphore(value: 0)
    private var hasher: SHA256
    private var written: Int64
    private var lastReportedBucket = -1

    private(set) var failure: Error?

    init(
        handle: FileHandle,
        expectedBytes: Int64,
        hasher: SHA256,
        written: Int64,
        resumeRequested: Bool,
        progress: ((Double) -> Void)?
    ) {
        self.handle = handle
        self.expectedBytes = expectedBytes
        self.hasher = hasher
        self.written = written
        self.resumeRequested = resumeRequested
        self.progress = progress
    }

    func accept(response: URLResponse) -> Bool {
        // A non-HTTP response (a `file://` source in tests) carries no status and cannot have
        // honoured a Range header, so a resumed attempt has to start over.
        guard let http = response as? HTTPURLResponse else { return resumeRequested ? restart() : true }
        switch http.statusCode {
        case 200:
            // Either this attempt started from byte 0, or the server ignored our Range header
            // (some CDNs do, and a redirect can drop it). Both mean the body starts at zero, so
            // any resumed state is now wrong: truncate and restart inside this same attempt.
            return resumeRequested ? restart() : true
        case 206 where resumeRequested:
            return true
        default:
            failure = ParakeetModelCacheError.downloadFailed("HTTP \(http.statusCode)")
            return false
        }
    }

    /// Throws away everything this attempt resumed from and starts the file at byte zero.
    private func restart() -> Bool {
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        } catch {
            failure = error
            return false
        }
        hasher = SHA256()
        written = 0
        lastReportedBucket = -1
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
