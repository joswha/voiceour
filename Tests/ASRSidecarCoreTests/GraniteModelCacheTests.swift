import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The Granite artifact in the cache implementation: where it lives, what it fetches, and how a
/// directory holding another artifact is treated.
@Suite("GraniteModelCacheTests")
struct GraniteModelCacheTests {
    @Test func theDefaultDirectoryIsGranitesOwnAppCacheDirectory() {
        let cache = ModelCache.granite(environment: [:])

        #expect(cache.directory.lastPathComponent == "granite-speech-5.0-470m-turboctc-q8_0")
        #expect(cache.directory.lastPathComponent == GraniteModelContract.cacheDirectoryName)
        #expect(cache.directory.deletingLastPathComponent().lastPathComponent == "Voiceour")
        #expect(cache.supersededPins == GraniteModelContract.supersededPins)
    }

    /// The acquisition fetches exactly the pinned resolve URL: repository, revision and file.
    @Test func theDownloadURLIsThePinnedResolveURL() {
        #expect(
            ModelCache.granite(environment: [:]).source.absoluteString
                == "https://huggingface.co/vladers/granite-speech-5.0-470m-turboctc-GGUF/resolve/bd7db273aa69a26fc81e370c84597fa738fe2ad0/granite-speech-5.0-470m-turboctc-Q8_0.gguf"
        )
    }

    /// The override names the caller's directory exactly, with no subdirectory, and replaces
    /// nothing on its own initiative.
    @Test func theOverrideIsHonouredVerbatim() {
        let cache = ModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": "/tmp/voiceour-granite-cache"])

        #expect(cache.directory.path == "/tmp/voiceour-granite-cache")
        #expect(cache.artifact == .granite)
        #expect(cache.supersededPins.isEmpty)
    }

    @Test func anEmptyOverrideFallsBackToTheDefaultDirectory() {
        let cache = ModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": ""])

        #expect(cache.directory.lastPathComponent == GraniteModelContract.cacheDirectoryName)
    }

    /// Another model's manifest in the Granite directory is refused, never overwritten:
    /// `file` and `model_id` both differ.
    @Test func aForeignManifestInTheGraniteDirectoryIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-cache-mismatch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": directory.path])
        let foreign = ModelManifest(
            modelId: "example/other-model-GGUF",
            revision: "0123456789abcdef0123456789abcdef01234567",
            file: "other-model-f16.gguf",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1_024
        )
        try JSONEncoder().encode(foreign).write(to: cache.manifestURL)

        #expect(!cache.cacheOK())
        #expect(throws: ModelCacheError.self) { try cache.ensureModel() }
        #expect(cache.manifest() == foreign)
    }

    /// A pin an earlier build cached in the app directory makes way for the current one: the
    /// next acquisition clears its weights and manifest and downloads the current artifact.
    @Test func aSupersededPinIsReplacedByTheCurrentArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-superseded-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = ModelManifest(
            modelId: "earlier/granite", revision: "0000000000000000000000000000000000000001",
            file: "earlier.gguf", sha256: String(repeating: "0", count: 64), sizeBytes: 3)
        try Data("old".utf8).write(to: directory.appendingPathComponent(old.file))
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("manifest.json"))
        let current = Data("current granite weights".utf8)
        let published = root.appendingPathComponent("published.gguf")
        try current.write(to: published)
        let cache = ModelCache(
            directory: directory,
            artifact: ModelManifest(
                modelId: "current/granite", revision: "0000000000000000000000000000000000000002",
                file: "current.gguf", sha256: SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined(),
                sizeBytes: Int64(current.count)),
            source: published,
            supersededPins: [ASRExpectedModel(modelId: old.modelId, revision: old.revision, file: old.file)],
            retryDelay: 0,
            availableCapacity: { _ in nil }
        )

        try cache.ensureModel()

        #expect(cache.cacheOK())
        #expect(cache.manifest() == cache.artifact)
        #expect(try Data(contentsOf: cache.modelURL) == current)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.file).path))
    }

    /// Under a caller-owned `VOICEOUR_MODEL_CACHE` a superseded pin is that caller's file: it is
    /// refused like any mismatch and left exactly as it was.
    @Test func aSupersededPinInACallerOwnedCacheIsKept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-superseded-override-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pin = try #require(GraniteModelContract.supersededPins.first)
        // A superseded pin is never the live one; were it, ensureModel would download the real artifact.
        try #require(pin != GraniteModelContract.expectedModel)
        let kept = ModelManifest(
            modelId: pin.modelId, revision: pin.revision, file: pin.file,
            sha256: String(repeating: "0", count: 64), sizeBytes: 4)
        let cache = ModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": directory.path])
        try Data("kept".utf8).write(to: directory.appendingPathComponent(pin.file))
        try JSONEncoder().encode(kept).write(to: cache.manifestURL)

        #expect(throws: ModelCacheError.self) { try cache.ensureModel() }
        #expect(cache.manifest() == kept)
        #expect(try Data(contentsOf: directory.appendingPathComponent(pin.file)) == Data("kept".utf8))
    }

    /// The removal a Granite load failure uses takes the artifact and manifest and nothing else.
    @Test func removeModelAndManifestRemovesExactlyThoseTwo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-remove-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": directory.path])
        try Data("model".utf8).write(to: cache.modelURL)
        try JSONEncoder().encode(cache.artifact).write(to: cache.manifestURL)
        let partial = directory.appendingPathComponent(GraniteModelContract.fileName + ".download")
        try Data("partial".utf8).write(to: partial)

        cache.removeModelAndManifest()

        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: cache.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
