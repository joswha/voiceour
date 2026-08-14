import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("ParakeetModelCacheTests")
struct ParakeetModelCacheTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-cache-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small stand-in for the 1.26 GB pin so the real download, verify, rename and manifest
    /// path runs end to end in a test.
    private func artifact(for bytes: Data, file: String = "tiny.bin") -> ParakeetModelManifest {
        ParakeetModelManifest(
            modelId: "test/tiny",
            revision: "0123456789abcdef",
            file: file,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(bytes.count)
        )
    }

    @Test func standardHonorsTheEnvironmentOverride() {
        let cache = ParakeetModelCache.standard(environment: ["VOICEOUR_MODEL_CACHE": "/tmp/voiceour-model-cache"])

        #expect(cache.directory.path == "/tmp/voiceour-model-cache")
        #expect(cache.modelURL.lastPathComponent == ASRModelContract.fileName)
    }

    @Test func standardFallsBackToTheAppCacheDirectory() {
        let cache = ParakeetModelCache.standard(environment: [:])

        #expect(cache.directory.lastPathComponent == "parakeet-tdt-0.6b-v3-ggml")
        #expect(cache.directory.deletingLastPathComponent().lastPathComponent == "Voiceour")
    }

    @Test func cacheIsNotOkWithoutAManifest() {
        let cache = ParakeetModelCache(directory: temporaryDirectory())

        #expect(!cache.cacheOK())
    }

    @Test func downloadVerifiesWritesTheManifestAndSatisfiesCacheOK() throws {
        let bytes = Data("pretend these are weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let directory = temporaryDirectory()
        let cache = ParakeetModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

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
        let cache = ParakeetModelCache(
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
        let cache = ParakeetModelCache(
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
        let stale = ParakeetModelManifest(
            modelId: "test/tiny",
            revision: "some-older-revision",
            file: "tiny.bin",
            sha256: "0",
            sizeBytes: 7
        )
        try JSONEncoder().encode(stale).write(to: directory.appendingPathComponent("manifest.json"))

        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ParakeetModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
    }

    @Test func aCorruptDownloadIsDiscardedRatherThanCached() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try Data("different bytes entirely".utf8).write(to: source)
        let cache = ParakeetModelCache(
            directory: temporaryDirectory(),
            artifact: artifact(for: bytes),
            source: source
        )

        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
        #expect(!cache.cacheOK())
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path + ".download"))
    }

    @Test func ensureModelIsANoOpOnceCached() throws {
        let bytes = Data("weights".utf8)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let cache = ParakeetModelCache(
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
}
