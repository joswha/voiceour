import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("ModelCacheTests")
struct ModelCacheTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cache-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small stand-in for the pinned artifact so the real download, verify, rename and manifest
    /// path runs end to end in a test.
    private func artifact(for bytes: Data, file: String = "tiny.bin") -> ModelManifest {
        ModelManifest(
            modelId: "test/tiny",
            revision: "0123456789abcdef",
            file: file,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(bytes.count)
        )
    }

    @Test func cacheIsNotOkWithoutAManifest() {
        let cache = ModelCache(directory: temporaryDirectory())

        #expect(!cache.cacheOK())
    }

    @Test func cacheOKRejectsWrongSHAAndAcceptsTheExactPin() throws {
        let bytes = Data("weights".utf8)
        let pinned = artifact(for: bytes)
        let cache = ModelCache(directory: temporaryDirectory(), artifact: pinned)
        try bytes.write(to: cache.modelURL)

        var wrongDigest = pinned
        wrongDigest.sha256 = String(repeating: "0", count: 64)
        try JSONEncoder().encode(wrongDigest).write(to: cache.manifestURL)
        #expect(!cache.cacheOK())

        try JSONEncoder().encode(pinned).write(to: cache.manifestURL)
        #expect(cache.cacheOK())
    }

    @Test func downloadVerifiesWritesTheManifestAndSatisfiesCacheOK() throws {
        let bytes = Data("pretend these are weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let directory = temporaryDirectory()
        let cache = ModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

        var reported: [Double] = []
        try cache.ensureModel { reported.append($0) }

        #expect(cache.cacheOK())
        #expect(try Data(contentsOf: cache.modelURL) == bytes)
        #expect(!reported.isEmpty)
        #expect(reported.allSatisfy { $0 > 0 && $0 <= 1 })

        let manifest = try #require(cache.manifest())
        #expect(manifest.modelId == "test/tiny")
        #expect(manifest.sizeBytes == Int64(bytes.count))
        // No partial file survives a successful acquisition.
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path + ".download"))
    }

    @Test func manifestRoundTripsThroughTheOnDiskSnakeCaseKeys() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ModelCache(
            directory: temporaryDirectory(),
            artifact: artifact(for: bytes),
            source: source
        )
        try cache.ensureModel()

        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: cache.manifestURL))
        let object = try #require(raw as? [String: Any])

        #expect(object["model_id"] as? String == "test/tiny")
        #expect(object["revision"] as? String == "0123456789abcdef")
        #expect(object["file"] as? String == "tiny.bin")
        #expect(object["size_bytes"] as? Int == bytes.count)
        #expect(object["sha256"] as? String == cache.artifact.sha256)
    }

    @Test func sizeMismatchOnDiskInvalidatesTheCache() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ModelCache(
            directory: temporaryDirectory(),
            artifact: artifact(for: bytes),
            source: source
        )
        try cache.ensureModel()
        #expect(cache.cacheOK())

        // A truncated weight file is exactly what an interrupted copy leaves behind.
        try Data("short".utf8).write(to: cache.modelURL)

        #expect(!cache.cacheOK())
    }

    @Test func aManifestForADifferentRevisionIsNeverOverwritten() throws {
        let bytes = Data("weights".utf8)
        let directory = temporaryDirectory()
        let stale = ModelManifest(
            modelId: "test/tiny",
            revision: "some-older-revision",
            file: "tiny.bin",
            sha256: "0",
            sizeBytes: 7
        )
        try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent("manifest.json"))

        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

        #expect(throws: ModelCacheError.self) { try cache.ensureModel() }
    }

    /// The case `model_id` and `revision` cannot see: one pinned repository holds several
    /// conversions of the same checkpoint, so a directory left by another conversion agrees on
    /// both and differs only in `file`. Overwriting its manifest would leave the previous
    /// weight file orphaned beside a manifest that no longer describes it — and the manifest is
    /// the only record of what those bytes are.
    @Test func aManifestForADifferentArtifactOfTheSameRevisionIsNeverOverwritten() throws {
        let bytes = Data("weights".utf8)
        let directory = temporaryDirectory()
        let sibling = artifact(for: Data("the other conversion".utf8), file: "tiny-other.bin")
        try JSONEncoder().encode(sibling).write(to: directory.appendingPathComponent("manifest.json"))

        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

        #expect(throws: ModelCacheError.self) { try cache.ensureModel() }
        #expect(cache.manifest() == sibling)
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
    }

    @Test func aCorruptDownloadIsDiscardedRatherThanCached() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try Data("different bytes entirely".utf8).write(to: source)
        let cache = ModelCache(
            directory: temporaryDirectory(),
            artifact: artifact(for: bytes),
            source: source
        )

        #expect(throws: ModelCacheError.self) { try cache.ensureModel() }
        #expect(!cache.cacheOK())
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path + ".download"))
    }

    @Test func ensureModelIsANoOpOnceCached() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ModelCache(
            directory: temporaryDirectory(),
            artifact: artifact(for: bytes),
            source: source
        )
        try cache.ensureModel()
        try FileManager.default.removeItem(at: source)

        // The source is gone; a second call must not attempt to fetch it again.
        try cache.ensureModel()
        #expect(cache.cacheOK())
    }

    /// A transfer the volume cannot finish is refused before it starts. Without the preflight
    /// the reader waits out a half-gigabyte download and is then told the write failed, which is the
    /// same information an hour later — and the refusal carries its own case so the sentence
    /// shown can name disk space instead of blaming the network.
    ///
    /// The injected capacity is exactly the headroom margin, so what this pins is that the
    /// artifact's own bytes are required *on top of* it.
    @Test func aVolumeThatCannotHoldTheArtifactIsRefusedBeforeAnythingIsWritten() throws {
        let bytes = Data("pretend these are weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let directory = temporaryDirectory().appendingPathComponent("model", isDirectory: true)
        let cache = ModelCache(
            directory: directory,
            artifact: artifact(for: bytes),
            source: source,
            availableCapacity: { _ in ModelCache.downloadHeadroomBytes }
        )

        do {
            try cache.ensureModel()
            Issue.record("a volume with no room for the artifact still started the download")
        } catch ModelCacheError.insufficientDiskSpace {
            // The one acceptable outcome; any other error fails this test by escaping it.
        }

        #expect(!cache.cacheOK())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// A resumed transfer already owns the bytes on disk, so only the missing ones are required.
    /// Demanding the whole artifact again would refuse a download that is one chunk from done —
    /// exactly the hotel-connection case the partial file exists for.
    @Test func aResumedDownloadOnlyRequiresTheBytesItStillHasToFetch() throws {
        let bytes = Data("pretend these are weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let directory = temporaryDirectory()
        let pinned = artifact(for: bytes)
        let cache = ModelCache(
            directory: directory,
            artifact: pinned,
            source: source,
            // Room for the margin plus one byte: enough for what is missing, nowhere near
            // enough for the whole artifact again.
            availableCapacity: { _ in ModelCache.downloadHeadroomBytes + 1 }
        )
        try bytes.dropLast().write(to: directory.appendingPathComponent(pinned.file + ".download"))

        try cache.ensureModel()

        #expect(cache.cacheOK())
        #expect(try Data(contentsOf: cache.modelURL) == bytes)
    }

    /// The shipped probe answers about the volume, not about the path, so it has to survive a
    /// cache directory that does not exist yet — which is every first launch.
    @Test func theVolumeProbeAnswersForADirectoryThatDoesNotExistYet() throws {
        let missing = temporaryDirectory()
            .appendingPathComponent("not-created-yet", isDirectory: true)
            .appendingPathComponent("nor-this", isDirectory: true)

        let capacity = try #require(ModelCache.volumeAvailableCapacity(missing))

        #expect(capacity > 0)
    }
}
