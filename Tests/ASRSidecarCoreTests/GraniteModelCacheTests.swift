import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The Granite artifact in the shared cache implementation, and its isolation from Parakeet's
/// variant retirement in both directions.
@Suite("GraniteModelCacheTests")
struct GraniteModelCacheTests {
    @Test func theDefaultDirectoryIsGranitesOwnAppCacheDirectory() {
        let cache = ParakeetModelCache.granite(environment: [:])

        #expect(cache.directory.lastPathComponent == "granite-speech-5.0-470m-turboctc-q8_0")
        #expect(cache.directory.lastPathComponent == GraniteModelContract.cacheDirectoryName)
        #expect(cache.directory.deletingLastPathComponent().lastPathComponent == "Voiceour")
        #expect(
            cache.directory.deletingLastPathComponent()
                == ParakeetModelCache.standard(environment: [:]).directory.deletingLastPathComponent())
        // One artifact, no siblings: it retires nothing, wherever it lives.
        #expect(!cache.ownsVariantRoot)
    }

    /// The acquisition fetches exactly the pinned resolve URL: repository, revision and file.
    @Test func theDownloadURLIsThePinnedResolveURL() {
        #expect(
            ParakeetModelCache.granite(environment: [:]).source.absoluteString
                == "https://huggingface.co/17slever17/granite-speech-5.0-470m-turboctc-multilingual-GGUF/resolve/62f64d9d5ad35989b06caf199cafe7155944a22b/granite-speech-5.0-470m-turboctc-multilingual-Q8_0.gguf"
        )
    }

    /// The override names the caller's directory exactly, and the Parakeet variant selection
    /// has no say over a Granite artifact.
    @Test func theOverrideIsHonouredAndTheParakeetVariantIgnored() {
        let cache = ParakeetModelCache.granite(environment: [
            "VOICEOUR_MODEL_CACHE": "/tmp/voiceour-granite-cache",
            ASRModelVariant.environmentKey: "q8_0",
        ])

        #expect(cache.directory.path == "/tmp/voiceour-granite-cache")
        #expect(cache.artifact == .granite)
        #expect(!cache.ownsVariantRoot)
        #expect(ParakeetModelCache.granite(environment: [ASRModelVariant.environmentKey: "q8_0"]).artifact == .granite)
    }

    @Test func anEmptyOverrideFallsBackToTheDefaultDirectory() {
        let cache = ParakeetModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": ""])

        #expect(cache.directory.lastPathComponent == GraniteModelContract.cacheDirectoryName)
    }

    /// A Parakeet manifest in the Granite directory (or the reverse) is refused, never
    /// overwritten: `file` and `model_id` both differ.
    @Test func aParakeetManifestInTheGraniteDirectoryIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-cache-mismatch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ParakeetModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": directory.path])
        try JSONEncoder().encode(ParakeetModelManifest.pinned(.default)).write(to: cache.manifestURL)

        #expect(!cache.cacheOK())
        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
        #expect(cache.manifest() == .pinned(.default))
    }

    /// Parakeet's retirement only ever names Parakeet variant directories.
    @Test func parakeetPruningNeverTouchesTheGraniteDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-prune-isolation-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let granite = root.appendingPathComponent(GraniteModelContract.cacheDirectoryName, isDirectory: true)
        let superseded = root.appendingPathComponent(ASRModelVariant.q8.cacheDirectoryName, isDirectory: true)
        for directory in [granite, superseded] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("granite".utf8).write(to: granite.appendingPathComponent(GraniteModelContract.fileName))

        let parakeet = ParakeetModelCache(
            directory: root.appendingPathComponent(ASRModelVariant.f16.cacheDirectoryName, isDirectory: true),
            artifact: .pinned(.f16)
        )
        #expect(parakeet.ownsVariantRoot)
        parakeet.removeSupersededVariants()

        #expect(!FileManager.default.fileExists(atPath: superseded.path))
        #expect(
            FileManager.default.fileExists(atPath: granite.appendingPathComponent(GraniteModelContract.fileName).path))
    }

    /// The removal a Granite load failure uses takes the artifact and manifest and nothing else.
    @Test func removeModelAndManifestRemovesExactlyThoseTwo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-remove-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ParakeetModelCache.granite(environment: ["VOICEOUR_MODEL_CACHE": directory.path])
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
