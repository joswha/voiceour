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

    /// The request's terms are spotted over the decode's own logits and mapped to its words; the
    /// tokenizer is built once for the loaded context however many requests spot.
    @Test func spotsTheRequestsTermsOverTheDecodesLogits() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext(run: .kubectl)
        let backend = fixture.backend(context: context)
        var request = fixture.request()
        request.spotTerms = [
            ASRSpotTerm(variants: TermSpotting.variants(for: "kubectl")),
            ASRSpotTerm(variants: TermSpotting.variants(for: "nginx")),
        ]

        for _ in 0..<2 {
            guard case .result(let transcript, _, _, _, _) = backend.transcribe(request, isCancelled: { false }) else {
                Issue.record("a scripted decode must produce a result")
                return
            }
            #expect(transcript.text == "run cube cuddle now")
            #expect(
                transcript.termSpots == [
                    TermSpot(term: 0, variant: 0, firstWord: 1, lastWord: 2, score: -4, tokenCount: 8)
                ])
        }
        #expect(context.encoderBuilds == 1)
    }

    /// No `spot_terms`, no spotting and no `term_spots`.
    @Test func aRequestWithoutSpotTermsCarriesNoTermSpots() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let context = ScriptedGraniteContext(run: .kubectl)
        let backend = fixture.backend(context: context)

        guard case .result(let transcript, _, _, _, _) = backend.transcribe(fixture.request(), isCancelled: { false })
        else {
            Issue.record("a scripted decode must produce a result")
            return
        }
        #expect(transcript.text == "run cube cuddle now")
        #expect(transcript.termSpots == nil)
        #expect(context.encoderBuilds == 0)
    }

    /// Spotting that cannot run never costs the transcript: it goes out without `term_spots`.
    @Test func aSpottingFailureStillDeliversTheTranscript() throws {
        let fixture = try GraniteFixture(installed: true)
        defer { fixture.remove() }
        let backend = fixture.backend(context: ScriptedGraniteContext())
        var request = fixture.request()
        request.spotTerms = [ASRSpotTerm(variants: TermSpotting.variants(for: "kubectl"))]

        guard case .result(let transcript, _, _, _, _) = backend.transcribe(request, isCancelled: { false }) else {
            Issue.record("a spotting failure must not fail the decode")
            return
        }
        #expect(transcript.text == "hello world")
        #expect(transcript.termSpots == nil)
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

    /// Empty `expected_model` fields are wildcards.
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
        (ASRExpectedModel(modelId: "", revision: "", file: GraniteModelContract.supersededPins[0].file), "file"),
        (
            ASRExpectedModel(
                modelId: GraniteModelContract.supersededPins[0].modelId,
                revision: GraniteModelContract.revision,
                file: GraniteModelContract.fileName
            ), "model_id"
        ),
        (
            ASRExpectedModel(
                modelId: GraniteModelContract.modelId,
                revision: GraniteModelContract.supersededPins[0].revision,
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

        #expect(throws: ModelCacheError.self) { try backend.warmUp() }

        let health = backend.health()
        let reported = try #require(health.lastAcquisitionError)
        #expect(reported.code == .insufficientDiskSpace)
        // The byte budget the user has to act on, carried as a diagnostic.
        #expect(reported.detail?.contains("bytes free for \(GraniteModelContract.fileName)") == true)
        // Indistinguishable from a preload that has not started, but for the field above.
        #expect(health.downloadFraction == nil)
        #expect(health.warming == nil)
        #expect(!health.cacheOk)
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
            ?? ModelCache.granite(environment: [:]).modelURL.path
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

private func graniteTestArtifact(for bytes: Data) -> ModelManifest {
    ModelManifest(
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
    let cache: ModelCache
    let artifactBytes = Data("granite stand-in weights".utf8)
    let audio: URL

    init(installed: Bool, frames: Int = 16, availableCapacity: Int64? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-backend-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("published.gguf")
        try artifactBytes.write(to: source)
        cache = ModelCache(
            directory: root.appendingPathComponent("model", isDirectory: true),
            artifact: graniteTestArtifact(for: artifactBytes),
            source: source,
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

/// What a scripted decode returns, and the logits and tokenizer spotting reads after it.
private struct ScriptedRun {
    var tokens: [GraniteRawToken]
    var pieces: [String]
    var frames: Int
    var logits: [Float]

    private static func token(_ id: Int32, _ frames: (Int32, Int32), _ text: String) -> GraniteRawToken {
        GraniteRawToken(
            id: id, frameBegin: frames.0, frameEnd: frames.1, probability: 0.9, isSpecial: false,
            bytes: Array(text.utf8))
    }

    /// "hello world" with no logits and no tokenizer: spotting over it fails.
    static let helloWorld = ScriptedRun(
        tokens: [token(1, (0, 1), " hello"), token(2, (1, 2), " world")],
        pieces: [],
        frames: 0,
        logits: []
    )

    /// "run cube cuddle now" over 16 frames, where the posteriors spell `▁kubectl` one letter a
    /// frame across frames 3...10, each letter 0.5 nats below the greedy label: the canonical
    /// `kubectl` scores −4 over *cube cuddle*. The vocabulary is the blank, the four words, `▁`
    /// and kubectl's letters, then the 256 byte pieces; there are no merges.
    static let kubectl: ScriptedRun = {
        let words = ["<blank>", "▁run", "▁cube", "▁cuddle", "▁now"]
        let letters = ["▁", "k", "u", "b", "e", "c", "t", "l"]
        let pieces = words + letters + (0...255).map { String(format: "<0x%02X>", $0) }
        let frames = 16
        let greedy: [Int] = [1, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 4, 0, 0]
        var logits = [Float](repeating: 0, count: frames * pieces.count)
        for frame in 0..<frames {
            logits[frame * pieces.count + greedy[frame]] = 10
        }
        for offset in letters.indices {
            logits[(3 + offset) * pieces.count + words.count + offset] = 9.5
        }
        return ScriptedRun(
            tokens: [
                token(1, (0, 3), " run"), token(2, (3, 7), " cube"), token(3, (7, 13), " cuddle"),
                token(4, (13, 16), " now"),
            ],
            pieces: pieces,
            frames: frames,
            logits: logits
        )
    }()
}

// `lock` protects the recorded decodes and encoder builds.
private final class ScriptedGraniteContext: GraniteRuntimeContext, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: GraniteContextError?
    private let onDecode: () -> Void
    private let run: ScriptedRun
    private var counts: [Int] = []
    private var silentOnly = true
    private var encoders = 0

    init(failure: GraniteContextError? = nil, run: ScriptedRun = .helloWorld, onDecode: @escaping () -> Void = {}) {
        self.failure = failure
        self.run = run
        self.onDecode = onDecode
    }

    var requestSampleCounts: [Int] { lock.withLock { counts } }
    var sawOnlySilence: Bool { lock.withLock { silentOnly } }
    var encoderBuilds: Int { lock.withLock { encoders } }

    var vocabularySize: Int { run.pieces.count }
    let blankId: Int32 = 0

    func transcribe(samples: [Float], isCancelled _: @escaping () -> Bool) throws -> GraniteRawResult {
        lock.withLock {
            counts.append(samples.count)
            if samples.contains(where: { $0 != 0 }) { silentOnly = false }
        }
        onDecode()
        if let failure { throw failure }
        return GraniteRawResult(tokens: run.tokens, msPerFrame: 80, nospeechTokenId: -1)
    }

    func withLastLogits<Result>(
        _ body: (_ logits: UnsafeBufferPointer<Float>, _ frames: Int) throws -> Result
    ) rethrows -> Result? {
        guard run.frames > 0 else { return nil }
        return try run.logits.withUnsafeBufferPointer { try body($0, run.frames) }
    }

    func makeEncoder() throws -> GraniteBPEEncoder {
        lock.withLock { encoders += 1 }
        return try GraniteBPEEncoder(pieces: run.pieces, merges: [])
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
