import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The Granite backend's observable contract, driven through a scripted context: the 506 MB
/// artifact is only loaded by the opt-in `VOICEOUR_GRANITE_INTEGRATION` case below.
@Suite("GraniteSidecarBackendTests", .timeLimit(.minutes(1)))
struct GraniteSidecarBackendTests {
    @Test func reportsItsOwnWireIdentity() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext()
        let backend = fixture.backend(context: context)

        guard
            case .result(let transcript, let backendId, let modelId, let revision, let timings) =
                backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("a scripted decode must produce a result")
            return
        }
        #expect(backendId == "granite-ctc")
        #expect(backend.backendId == "granite-ctc")
        #expect(modelId == GraniteModelContract.modelId)
        #expect(revision == GraniteModelContract.revision)
        #expect(transcript.text == "hello world")
        #expect(transcript.confidenceMode == .greedyTokenProb)
        #expect(timings.total == timings.load + timings.inference)
        #expect(context.requestSampleCounts == [16])
    }

    @Test func theGranitePinIsAccepted() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext())

        let terminal = backend.transcribe(
            fixture.request(expectedModel: GraniteModelContract.expectedModel),
            isCancelled: { false }
        )

        guard case .result = terminal else {
            Issue.record("the Granite pin must be accepted")
            return
        }
    }

    /// Empty `expected_model` fields are wildcards, exactly as for Parakeet.
    @Test func emptyExpectedModelFieldsAreWildcards() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext())

        let terminal = backend.transcribe(
            fixture.request(expectedModel: ASRExpectedModel(modelId: "", revision: "", file: "")),
            isCancelled: { false }
        )

        guard case .result = terminal else {
            Issue.record("an all-wildcard expected_model must be accepted")
            return
        }
    }

    @Test(arguments: [
        (ASRExpectedModel(modelId: "", revision: "", file: "ggml-parakeet-tdt-0.6b-v3-f16.bin"), "file"),
        (
            ASRExpectedModel(
                modelId: ASRModelContract.modelId,
                revision: GraniteModelContract.revision,
                file: GraniteModelContract.fileName
            ), "model_id"
        ),
        (
            ASRExpectedModel(
                modelId: GraniteModelContract.modelId,
                revision: ASRModelContract.revision,
                file: GraniteModelContract.fileName
            ), "revision"
        ),
    ])
    func aMismatchedPinIsRefused(expected: ASRExpectedModel, field: String) throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext()
        let backend = fixture.backend(context: context)

        guard
            case .failure(let code, let detail, let fatal) =
                backend.transcribe(fixture.request(expectedModel: expected), isCancelled: { false })
        else {
            Issue.record("a mismatched pin must be refused")
            return
        }
        #expect(code == .manifestMismatch)
        #expect(detail == "expected_model \(field) mismatch")
        #expect(!fatal)
        #expect(context.requestSampleCounts.isEmpty)
    }

    @Test func healthBeforeAndAfterTheCacheAndTheLoad() throws {
        let fixture = try GraniteFixture(installed: false)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext())

        #expect(backend.startupStatus() == .modelMissing)
        let missing = backend.health()
        #expect(missing.backendId == "granite-ctc")
        #expect(missing.backendStatus == .modelMissing)
        #expect(!missing.ready)
        #expect(!missing.cacheOk)
        #expect(!missing.modelLoaded)
        #expect(missing.warming == nil)
        #expect(missing.downloadFraction == nil)
        #expect(missing.lastAcquisitionError == nil)

        try fixture.install()
        #expect(backend.startupStatus() == .ready)
        let cached = backend.health()
        #expect(cached.backendStatus == .ready)
        // Ready does not require a resident context: an unloaded valid cache is ready.
        #expect(cached.ready)
        #expect(cached.cacheOk)
        #expect(!cached.modelLoaded)

        try backend.warmUp()
        let loaded = backend.health()
        #expect(loaded.ready)
        #expect(loaded.modelLoaded)
        #expect(loaded.warming == nil)

        backend.shutdown()
        #expect(!backend.health().modelLoaded)
    }

    /// The request path never downloads: a cold acquisition cannot fit the client's timeout.
    @Test func aRequestIsRefusedWhileTheModelIsNotInstalled() throws {
        let fixture = try GraniteFixture(installed: false)
        defer { fixture.remove() }
        let factory = CountingGraniteFactory()
        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: factory.make
        )

        guard
            case .failure(let code, let detail, let fatal) =
                backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("a missing model must be refused")
            return
        }
        #expect(code == .modelNotInstalled)
        #expect(detail == "\(GraniteModelContract.modelId) is still being acquired; retry once it has finished")
        #expect(!fatal)
        #expect(factory.count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.modelURL.path))
    }

    @Test func aCancelBeforeTheDecodeNeverReachesTheModel() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext()
        let backend = fixture.backend(context: context)

        guard case .cancelled = backend.transcribe(fixture.request(), isCancelled: { true }) else {
            Issue.record("a request cancelled before the decode must answer cancelled")
            return
        }
        #expect(context.requestSampleCounts.isEmpty)
    }

    @Test func aNativeCancellationAnswersCancelled() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext(failure: .cancelled))

        guard case .cancelled = backend.transcribe(fixture.request(), isCancelled: { false }) else {
            Issue.record("GRANITE_ERR_CANCELLED must answer cancelled")
            return
        }
    }

    /// A failure that raced a client cancel answers the cancel that was asked for.
    @Test func aFailureAfterACancelAnswersCancelled() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let cancel = CancelFlag()
        let context = ScriptedGraniteContext(failure: .backendFailed, onDecode: { cancel.set() })
        let backend = fixture.backend(context: context)

        guard case .cancelled = backend.transcribe(fixture.request(), isCancelled: { cancel.value }) else {
            Issue.record("a failure under a set cancel flag must answer cancelled")
            return
        }
    }

    @Test func aBackendFailureIsFatal() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext(failure: .backendFailed))

        guard case .failure(let code, _, let fatal) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("GRANITE_ERR_BACKEND must fail the request")
            return
        }
        #expect(code == .inferenceFailed)
        #expect(fatal)
    }

    @Test func anUnknownStatusIsFatal() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext(failure: .unexpectedStatus(42)))

        guard case .failure(let code, _, let fatal) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("an unknown status must fail the request")
            return
        }
        #expect(code == .inferenceFailed)
        #expect(fatal)
    }

    @Test func anInvalidArgumentIsAnAudioRefusalNotAFatal() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext(failure: .invalidArgument("bad pcm")))

        guard
            case .failure(let code, let detail, let fatal) =
                backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("GRANITE_ERR_INVALID_ARGUMENT must fail the request")
            return
        }
        #expect(code == .unsupportedAudioFormat)
        #expect(detail == "bad pcm")
        #expect(!fatal)
    }

    /// A crash-recovery-truncated WAV holds zero samples: an empty transcript, no native call.
    @Test func anEmptyRecordingIsAnEmptyTranscriptWithoutADecode() throws {
        let fixture = try GraniteFixture(installed: true, frames: 0)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext()
        let backend = fixture.backend(context: context)

        guard
            case .result(let transcript, _, _, _, let timings) =
                backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("an empty recording must produce a result")
            return
        }
        #expect(transcript == GraniteTranscriptMapping.emptyTranscript)
        #expect(timings.inference == 0)
        #expect(context.requestSampleCounts.isEmpty)
    }

    @Test func warmUpDecodesHalfASecondOfSilenceOnce() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext()
        let backend = fixture.backend(context: context)

        try backend.warmUp()

        #expect(context.requestSampleCounts == [8_000])
        #expect(context.sawOnlySilence)
    }

    /// A load failure latches, and the next successful load clears both latches.
    @Test func aSuccessfulReloadClearsThePreviousLoadFailure() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let factory = CountingGraniteFactory(failures: 1)
        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: factory.make
        )

        #expect(throws: GraniteContextError.self) { try backend.warmUp() }
        #expect(!backend.health().ready)
        #expect(backend.health().lastAcquisitionError?.code == .modelLoadFailed)

        try backend.warmUp()

        #expect(backend.health().ready)
        #expect(backend.health().modelLoaded)
        #expect(backend.health().lastAcquisitionError == nil)
    }

    /// A load failure over bytes that still hash to the pin keeps them: the runtime is broken,
    /// not the cache.
    @Test func aLoadFailureOverGoodBytesKeepsThem() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in throw GraniteContextError.loadFailed("scripted") }
        )

        guard case .failure(let code, _, let fatal) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("an unloadable model must not produce a transcript")
            return
        }
        #expect(code == .modelLoadFailed)
        #expect(!fatal)
        #expect(fixture.cache.cacheOK())
    }

    /// A cache that no longer hashes to the pin is removed — the artifact and manifest only —
    /// and re-acquired exactly once.
    @Test func aRemovedCorruptArtifactIsReacquiredExactlyOnce() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let rotted = Data(fixture.artifactBytes.reversed())
        try rotted.write(to: fixture.cache.modelURL)
        // Something beside the artifact that is not the artifact's: never touched.
        let neighbour = fixture.cache.directory.appendingPathComponent("neighbour.txt")
        try Data("keep".utf8).write(to: neighbour)
        #expect(fixture.cache.cacheOK())
        #expect(!fixture.cache.verifyModelDigestOnDisk())

        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in throw GraniteContextError.loadFailed("scripted") }
        )

        guard case .failure(let code, let detail, _) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("a cache that fails digest re-verification must not produce a transcript")
            return
        }
        #expect(code == .modelNotInstalled)
        #expect(detail == "cached model failed digest re-verification and was removed; it will be re-downloaded")
        #expect(waitUntil(timeout: 5) { fixture.cache.cacheOK() })
        #expect(try Data(contentsOf: fixture.cache.modelURL) == fixture.artifactBytes)
        #expect(FileManager.default.fileExists(atPath: neighbour.path))

        try rotted.write(to: fixture.cache.modelURL)
        guard case .failure(let secondCode, _, _) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("the second load failure must not produce a transcript either")
            return
        }
        #expect(secondCode == .modelNotInstalled)
        #expect(!waitUntil(timeout: 1) { fixture.cache.cacheOK() })
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.modelURL.path))
    }

    /// Preload acquires through the shared streaming cache and writes the Granite manifest.
    @Test func warmUpAcquiresTheArtifactAndItsManifest() throws {
        let fixture = try GraniteFixture(installed: false)
        defer { fixture.remove() }
        var progress: [String] = []
        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { progress.append($0) },
            idleUnloadMs: 0,
            contextFactory: { _ in ScriptedGraniteContext() }
        )

        try backend.warmUp()

        #expect(fixture.cache.cacheOK())
        #expect(fixture.cache.manifest() == fixture.cache.artifact)
        #expect(progress.contains("VOICEOUR_PRELOAD download 100%"))
        #expect(backend.health().modelLoaded)
    }

    @Test func anAcquisitionFailureIsLatchedOnHealth() throws {
        let fixture = try GraniteFixture(installed: false, availableCapacity: 0)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext())

        #expect(throws: ParakeetModelCacheError.self) { try backend.warmUp() }

        let reported = try #require(backend.health().lastAcquisitionError)
        #expect(reported.code == .insufficientDiskSpace)
        #expect(backend.health().warming == nil)
    }

    /// Loading Granite never retires anything, even when its directory sits among the Parakeet
    /// variant directories and the cache were (wrongly) told it owns that root.
    @Test func loadingGraniteNeverPrunesTheParakeetVariants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-no-prune-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parakeetDirectories = ASRModelVariant.allCases.map {
            root.appendingPathComponent($0.cacheDirectoryName, isDirectory: true)
        }
        for (directory, variant) in zip(parakeetDirectories, ASRModelVariant.allCases) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: directory.appendingPathComponent(variant.fileName))
        }
        let bytes = Data("granite weights".utf8)
        let artifact = graniteTestArtifact(for: bytes)
        let cache = ParakeetModelCache(
            directory: root.appendingPathComponent(GraniteModelContract.cacheDirectoryName, isDirectory: true),
            artifact: artifact,
            ownsVariantRoot: true
        )
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try bytes.write(to: cache.modelURL)
        try JSONEncoder().encode(artifact).write(to: cache.manifestURL)
        let backend = GraniteSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in ScriptedGraniteContext() }
        )

        try backend.warmUp()

        for directory in parakeetDirectories {
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func idleUnloadIsDueOnlyOnceLoadedAndIdle() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 1,
            contextFactory: { _ in ScriptedGraniteContext() }
        )
        #expect(!backend.shouldUnloadNow(now: DispatchTime.now() + .seconds(3_600)))

        try backend.warmUp()

        #expect(backend.shouldUnloadNow(now: DispatchTime.now() + .seconds(3_600)))
        let disabled = GraniteSidecarBackend(
            cache: fixture.cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in ScriptedGraniteContext() }
        )
        try disabled.warmUp()
        #expect(!disabled.shouldUnloadNow(now: DispatchTime.now() + .seconds(3_600)))
    }

    /// Opt-in: decodes the real fixture with the real model. Needs the pinned GGUF at
    /// `VOICEOUR_GRANITE_MODEL` or in the default Granite cache; enable with
    /// `VOICEOUR_GRANITE_INTEGRATION=1`.
    @Test func theRealModelTranscribesTheHelloFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICEOUR_GRANITE_INTEGRATION"] != nil else { return }
        let modelPath =
            environment["VOICEOUR_GRANITE_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ParakeetModelCache.granite(environment: [:]).modelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "no Granite model at \(modelPath)")
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/audio/hello_16k_mono.wav")
        try #require(FileManager.default.fileExists(atPath: fixture.path), "missing \(fixture.path)")
        let samples = try WAVFile.readSamples(at: fixture)

        let context = try GraniteContext(modelPath: modelPath)
        #expect(context.msPerFrame == 80)
        #expect(context.nospeechTokenId >= 0)

        #expect(throws: GraniteContextError.cancelled) {
            try context.transcribe(samples: samples, isCancelled: { true })
        }

        let raw = try context.transcribe(samples: samples, isCancelled: { false })
        let transcript = GraniteTranscriptMapping.transcript(from: raw)
        let text = transcript.text.lowercased()
        #expect(text.contains("hello"), "transcript: \(transcript.text)")
        #expect(text.contains("world"), "transcript: \(transcript.text)")
        let words = try #require(transcript.segments?.first?.words)
        #expect(words.allSatisfy { $0.startMs <= $0.endMs })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        #expect(transcript.confidence.map { $0 > 0 && $0 <= 1 } == true)

        let silence = try context.transcribe(samples: [], isCancelled: { false })
        #expect(silence.tokens.isEmpty)
    }
}

// MARK: - Fixtures

private func graniteTestArtifact(for bytes: Data) -> ParakeetModelManifest {
    ParakeetModelManifest(
        modelId: GraniteModelContract.modelId,
        revision: GraniteModelContract.revision,
        file: GraniteModelContract.fileName,
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        sizeBytes: Int64(bytes.count)
    )
}

/// A temporary Granite cache holding a small stand-in artifact under the pinned file name,
/// its published copy as a `file://` source, and a 16 kHz mono WAV.
private struct GraniteFixture {
    let root: URL
    let cache: ParakeetModelCache
    let artifactBytes = Data("granite stand-in weights".utf8)
    let audio: URL

    init(installed: Bool, frames: Int = 16, availableCapacity: Int64? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-backend-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("published.gguf")
        try artifactBytes.write(to: source)
        cache = ParakeetModelCache(
            directory: root.appendingPathComponent("model", isDirectory: true),
            artifact: graniteTestArtifact(for: artifactBytes),
            source: source,
            ownsVariantRoot: false,
            retryDelay: 0,
            availableCapacity: { _ in availableCapacity }
        )
        audio = try writeGraniteWAV(frames: frames, in: root)
        if installed { try install() }
    }

    func install() throws {
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try artifactBytes.write(to: cache.modelURL)
        try JSONEncoder().encode(cache.artifact).write(to: cache.manifestURL)
    }

    func backend(context: ScriptedGraniteContext) -> GraniteSidecarBackend {
        GraniteSidecarBackend(cache: cache, log: { _ in }, idleUnloadMs: 0, contextFactory: { _ in context })
    }

    func request(expectedModel: ASRExpectedModel? = nil) -> ASRTranscribeRequest {
        ASRTranscribeRequest(
            requestId: "granite",
            audio: ASRAudioMeta(
                path: audio.path,
                format: "wav",
                sampleRateHz: 16000,
                channels: 1,
                durationMs: 1,
                byteCount: 0
            ),
            expectedModel: expectedModel,
            timeoutMs: 30_000
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func writeGraniteWAV(frames: Int, in directory: URL) throws -> URL {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + frames * 2))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(16000))
    append(UInt32(32000))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(frames * 2))
    for _ in 0..<frames { append(Int16(0)) }

    let url = directory.appendingPathComponent("utterance.wav")
    try data.write(to: url)
    return url
}

// `lock` protects the recorded decodes.
private final class ScriptedGraniteContext: GraniteRuntimeContext, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: GraniteContextError?
    private let onDecode: () -> Void
    private var counts: [Int] = []
    private var silentOnly = true

    init(failure: GraniteContextError? = nil, onDecode: @escaping () -> Void = {}) {
        self.failure = failure
        self.onDecode = onDecode
    }

    var requestSampleCounts: [Int] { lock.withLock { counts } }
    var sawOnlySilence: Bool { lock.withLock { silentOnly } }

    func transcribe(samples: [Float], isCancelled _: @escaping () -> Bool) throws -> GraniteRawResult {
        lock.withLock {
            counts.append(samples.count)
            if samples.contains(where: { $0 != 0 }) { silentOnly = false }
        }
        onDecode()
        if let failure { throw failure }
        return GraniteRawResult(
            tokens: [
                GraniteRawToken(
                    id: 1,
                    frameBegin: 0,
                    frameEnd: 1,
                    probability: 0.9,
                    isSpecial: false,
                    bytes: Array(" hello".utf8)
                ),
                GraniteRawToken(
                    id: 2,
                    frameBegin: 1,
                    frameEnd: 2,
                    probability: 0.8,
                    isSpecial: false,
                    bytes: Array(" world".utf8)
                ),
            ],
            msPerFrame: 80,
            nospeechTokenId: -1
        )
    }
}

// `lock` protects the attempt count.
private final class CountingGraniteFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let failures: Int

    init(failures: Int = 0) {
        self.failures = failures
    }

    var count: Int { lock.withLock { attempts } }

    func make(_: String) throws -> any GraniteRuntimeContext {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt <= failures { throw GraniteContextError.loadFailed("scripted attempt \(attempt)") }
        return ScriptedGraniteContext()
    }
}

// `lock` protects the flag.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }

    func set() {
        lock.withLock { flag = true }
    }
}

private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
