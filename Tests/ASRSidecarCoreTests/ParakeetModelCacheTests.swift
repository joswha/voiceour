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

    /// An explicit override owns the one directory it names, so the selected variant decides the
    /// artifact inside it rather than earning a subdirectory of its own.
    @Test func standardHonorsTheEnvironmentOverride() {
        let cache = ParakeetModelCache.standard(environment: ["VOICEOUR_MODEL_CACHE": "/tmp/voiceour-model-cache"])

        #expect(cache.directory.path == "/tmp/voiceour-model-cache")
        #expect(cache.modelURL.lastPathComponent == ASRModelVariant.default.fileName)
    }

    /// The literal name is the assertion: `f16` keeps the directory it has always had, so an
    /// existing install is not orphaned into re-downloading 1.26 GB the first time this runs.
    /// That directory is one of the app's own per-variant subdirectories, so this cache is the
    /// one that may retire its siblings.
    @Test func standardFallsBackToTheAppCacheDirectory() {
        let cache = ParakeetModelCache.standard(environment: [:])

        #expect(cache.directory.lastPathComponent == "parakeet-tdt-0.6b-v3-ggml")
        #expect(cache.directory.deletingLastPathComponent().lastPathComponent == "Voiceour")
        #expect(cache.ownsVariantRoot)
    }

    /// The selection reaches the sidecar as an environment value, and it has to move the whole
    /// triple together: a directory, an artifact and a URL that disagree would download one
    /// variant's bytes over another's manifest.
    @Test func standardResolvesTheSelectedVariantsDirectoryArtifactAndSource() {
        let cache = ParakeetModelCache.standard(environment: [ASRModelVariant.environmentKey: "q8_0"])

        #expect(cache.directory.lastPathComponent == ASRModelVariant.q8.cacheDirectoryName)
        #expect(cache.artifact == .pinned(.q8))
        #expect(cache.source == ASRModelVariant.q8.downloadURL)
    }

    /// A tag no build of this app ever wrote must load the default rather than fail: the
    /// environment is also how a shell reaches in, and a typo there is not a reason to refuse
    /// to dictate.
    @Test func standardFallsBackToTheDefaultVariantForAnUnknownTag() {
        let cache = ParakeetModelCache.standard(environment: [ASRModelVariant.environmentKey: "q3_k_xxs"])

        #expect(cache.artifact == .pinned(.default))
        #expect(cache.directory.lastPathComponent == ASRModelVariant.default.cacheDirectoryName)
    }

    @Test func cacheIsNotOkWithoutAManifest() {
        let cache = ParakeetModelCache(directory: temporaryDirectory())

        #expect(!cache.cacheOK())
    }

    @Test func cacheOKRejectsWrongSHAAndAcceptsTheExactPin() throws {
        let bytes = Data("weights".utf8)
        let pinned = artifact(for: bytes)
        let cache = ParakeetModelCache(directory: temporaryDirectory(), artifact: pinned)
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

    /// The case `model_id` and `revision` cannot see: one pinned repository holds several
    /// conversions of the same checkpoint, so a directory left by the other variant agrees on
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
        let cache = ParakeetModelCache(directory: directory, artifact: artifact(for: bytes), source: source)

        #expect(throws: ParakeetModelCacheError.self) { try cache.ensureModel() }
        #expect(cache.manifest() == sibling)
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
    }

    /// Only one artifact is ever wanted, so a proven selection has to retire the previous one:
    /// without this a switch leaves up to 1.26 GB of superseded weights on disk forever. The
    /// cache's own directory decides who its siblings are, so nothing outside the models root
    /// can be reached. When the retirement happens is `SidecarLifecycleTests`' subject.
    @Test func retiringTheSupersededVariantsReachesTheSiblingsAndNothingElse() throws {
        let root = temporaryDirectory()
        let kept = ASRModelVariant.f16
        let superseded = ASRModelVariant.q8
        let unrelated = root.appendingPathComponent("someone-elses-cache", isDirectory: true)
        for directory in [
            root.appendingPathComponent(kept.cacheDirectoryName, isDirectory: true),
            root.appendingPathComponent(superseded.cacheDirectoryName, isDirectory: true),
            unrelated,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: directory.appendingPathComponent("model.bin"))
        }

        let cache = ParakeetModelCache(
            directory: root.appendingPathComponent(kept.cacheDirectoryName, isDirectory: true),
            artifact: .pinned(kept)
        )
        cache.removeSupersededVariants()

        #expect(FileManager.default.fileExists(atPath: cache.directory.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(superseded.cacheDirectoryName).path))
    }

    /// The override names one directory the caller owns, so a development or benchmark run that
    /// pins the path must never have its neighbours deleted. `standard` is where that is
    /// decided, because it is the only place that knows the path came from the environment.
    @Test func anOverriddenCacheDirectoryNeverRetiresItsNeighbours() throws {
        let root = temporaryDirectory()
        let overridden = root.appendingPathComponent(ASRModelVariant.f16.cacheDirectoryName, isDirectory: true)
        let neighbour = root.appendingPathComponent(ASRModelVariant.q8.cacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        let cache = ParakeetModelCache.standard(environment: ["VOICEOUR_MODEL_CACHE": overridden.path])
        #expect(!cache.ownsVariantRoot)

        cache.removeSupersededVariants()

        #expect(FileManager.default.fileExists(atPath: neighbour.path))
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

    /// A transfer the volume cannot finish is refused before it starts. Without the preflight
    /// the reader waits out a 1.26 GB download and is then told the write failed, which is the
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
        let cache = ParakeetModelCache(
            directory: directory,
            artifact: artifact(for: bytes),
            source: source,
            availableCapacity: { _ in ParakeetModelCache.downloadHeadroomBytes }
        )

        do {
            try cache.ensureModel()
            Issue.record("a volume with no room for the artifact still started the download")
        } catch ParakeetModelCacheError.insufficientDiskSpace {
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
        let cache = ParakeetModelCache(
            directory: directory,
            artifact: pinned,
            source: source,
            // Room for the margin plus one byte: enough for what is missing, nowhere near
            // enough for the whole artifact again.
            availableCapacity: { _ in ParakeetModelCache.downloadHeadroomBytes + 1 }
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

        let capacity = try #require(ParakeetModelCache.volumeAvailableCapacity(missing))

        #expect(capacity > 0)
    }
}
