import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("SidecarLifecycleTests", .timeLimit(.minutes(1)))
struct SidecarLifecycleTests {
    @Test func aSuccessfulReloadClearsThePreviousLoadFailure() throws {
        let bytes = Data("model".utf8)
        let artifact = ParakeetModelManifest(
            modelId: "test/model",
            revision: "test-revision",
            file: "model.bin",
            sha256: "test-digest",
            sizeBytes: Int64(bytes.count)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-load-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A one-off pinned directory, like `VOICEOUR_MODEL_CACHE`: retirement is not this
        // test's subject, and its neighbours in the shared temp root are not ours to delete.
        let cache = ParakeetModelCache(directory: directory, artifact: artifact, ownsVariantRoot: false)
        try bytes.write(to: cache.modelURL)
        try JSONEncoder().encode(artifact).write(to: cache.manifestURL)

        let factory = FailThenSucceedContextFactory()
        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: factory.makeContext
        )

        #expect(throws: ScriptedLoadError.self) { try backend.warmUp() }
        #expect(!backend.health().ready)
        // The same event has to settle both latches, and this one is what the app reads: the
        // failure used to reach one stderr line and nothing else, leaving the app to guess.
        #expect(backend.health().lastAcquisitionError?.code == .modelLoadFailed)

        try backend.warmUp()

        #expect(backend.health().ready)
        #expect(backend.health().modelLoaded)
        #expect(backend.health().lastAcquisitionError == nil)
    }

    @Test func preloadWarmDecodeStaysNativeSoCoreMLTiersRemainLazy() throws {
        let bytes = Data("model".utf8)
        let artifact = ParakeetModelManifest(
            modelId: "test/model",
            revision: "test-revision",
            file: "model.bin",
            sha256: "test-digest",
            sizeBytes: Int64(bytes.count)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-native-warmup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ParakeetModelCache(directory: directory, artifact: artifact, ownsVariantRoot: false)
        try bytes.write(to: cache.modelURL)
        try JSONEncoder().encode(artifact).write(to: cache.manifestURL)
        let context = WarmUpRecordingContext()
        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in context }
        )

        try backend.warmUp()

        #expect(context.warmUpDecodeCount == 1)
        #expect(context.requestDecodeCount == 0)
    }

    /// A refusal the volume raises before a byte is fetched has to reach the wire.
    ///
    /// This is the shape inference can never see. `warmUp` fails in microseconds, so the health
    /// frame that follows has no fraction, nothing warming and no cache — byte for byte the
    /// answer a probe gets when the preload simply has not started yet. Only the backend's own
    /// verdict tells those two apart, and without it the app showed a stale MODEL NEEDED
    /// sentence while every dictation was already being refused.
    @Test func aVolumeRefusalIsReportedOnHealthRatherThanOnlyLogged() throws {
        let bytes = Data("pretend these are weights".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-no-room-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("published.bin")
        try bytes.write(to: source)

        let cache = ParakeetModelCache(
            directory: directory.appendingPathComponent("model", isDirectory: true),
            artifact: ParakeetModelManifest(
                modelId: "test/model",
                revision: "test-revision",
                file: "model.bin",
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                sizeBytes: Int64(bytes.count)
            ),
            source: source,
            ownsVariantRoot: false,
            // Exactly the headroom margin, so the artifact's own bytes are what does not fit.
            availableCapacity: { _ in ParakeetModelCache.downloadHeadroomBytes }
        )
        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in EmptyParakeetRuntimeContext() }
        )

        #expect(throws: ParakeetModelCacheError.self) { try backend.warmUp() }

        let health = backend.health()
        let reported = try #require(health.lastAcquisitionError)
        #expect(reported.code == .insufficientDiskSpace)
        // The byte budget the user has to act on, carried as a diagnostic.
        #expect(reported.detail?.contains("bytes free for model.bin") == true)
        // Indistinguishable from a preload that has not started, but for the field above.
        #expect(health.downloadFraction == nil)
        #expect(health.warming == nil)
        #expect(!health.cacheOk)
    }

    /// The superseded variant is retired once the selected one has *loaded*, never merely once
    /// it matches the pinned byte count.
    ///
    /// `cacheOK()` does not hash, so a selected artifact that has bit-rotted to the same size
    /// still passes it. Retiring the sibling on that evidence deletes the last weights that
    /// would actually have loaded; the load then fails, the load-failure path removes the
    /// selection too, and the reader is left with no model on disk at all and a mandatory
    /// 1.26 GB re-download. Driven through `warmUp` because the ordering, not the deletion,
    /// is what this defends.
    @Test func theSupersededVariantIsRetiredOnlyOnceTheSelectionHasLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-prune-order-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func cacheDirectory(_ variant: ASRModelVariant) -> URL {
            root.appendingPathComponent(variant.cacheDirectoryName, isDirectory: true)
        }
        let selectedDirectory = cacheDirectory(.f16)
        let supersededDirectory = cacheDirectory(.q8)
        for directory in [selectedDirectory, supersededDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("the other conversion".utf8)
            .write(to: supersededDirectory.appendingPathComponent(ASRModelVariant.q8.fileName))

        let bytes = Data("rotted weights of exactly the pinned length".utf8)
        let selected = ParakeetModelManifest(
            modelId: "test/model",
            revision: "test-revision",
            file: ASRModelVariant.f16.fileName,
            sha256: "test-digest",
            sizeBytes: Int64(bytes.count)
        )
        let cache = ParakeetModelCache(directory: selectedDirectory, artifact: selected)
        try bytes.write(to: cache.modelURL)
        try JSONEncoder().encode(selected).write(to: cache.manifestURL)
        // Acquisition is therefore a no-op, and the load is the only thing that can fail.
        #expect(cache.cacheOK())

        let factory = FailThenSucceedContextFactory()
        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: factory.makeContext
        )

        #expect(throws: ScriptedLoadError.self) { try backend.warmUp() }
        #expect(FileManager.default.fileExists(atPath: supersededDirectory.path))

        try backend.warmUp()

        #expect(!FileManager.default.fileExists(atPath: supersededDirectory.path))
        #expect(FileManager.default.fileExists(atPath: cache.modelURL.path))
    }

    /// Removing a cache that no longer hashes to the pin leaves the sidecar with no weights at
    /// all, so the removal re-acquires them — once.
    ///
    /// Without that, every later `transcribe` answers `model_not_installed`, which the app
    /// presents as "the speech model has not finished downloading yet" while nothing is
    /// downloading, until the reader finds the menu's retry or relaunches. The bound is the
    /// other half of the contract: a corrupt cache must not become a download loop.
    @Test func aRemovedCorruptArtifactIsReacquiredExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-reacquire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = Data("the artifact as published".utf8)
        // Same length, different bytes: exactly what `cacheOK()` cannot see and a load failure
        // is the first thing to notice.
        let rotted = Data(good.reversed())
        let source = directory.appendingPathComponent("published.bin")
        try good.write(to: source)
        let artifact = ParakeetModelManifest(
            modelId: "test/model",
            revision: "test-revision",
            file: "model.bin",
            sha256: SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(good.count)
        )
        let cache = ParakeetModelCache(
            directory: directory,
            artifact: artifact,
            source: source,
            ownsVariantRoot: false
        )
        try rotted.write(to: cache.modelURL)
        try JSONEncoder().encode(artifact).write(to: cache.manifestURL)
        #expect(cache.cacheOK())
        #expect(!cache.verifyModelDigestOnDisk())

        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            contextFactory: { _ in throw ScriptedLoadError.unloadable }
        )
        let request = transcribeRequest(audio: try writeSilentWAV(in: directory))

        guard case .failure(let code, _, _) = backend.transcribe(request, isCancelled: { false }) else {
            Issue.record("a cache that fails digest re-verification must not produce a transcript")
            return
        }
        #expect(code == .modelNotInstalled)
        #expect(waitUntil(timeout: 5) { cache.cacheOK() })
        #expect(try Data(contentsOf: cache.modelURL) == good)

        // Rot it again. The artifact is restorable and the source is still there, so only the
        // latch can stop a second automatic download — and it must.
        try rotted.write(to: cache.modelURL)
        guard case .failure(let secondCode, _, _) = backend.transcribe(request, isCancelled: { false })
        else {
            Issue.record("the second load failure must not produce a transcript either")
            return
        }
        #expect(secondCode == .modelNotInstalled)
        #expect(!waitUntil(timeout: 1) { cache.cacheOK() })
        #expect(!FileManager.default.fileExists(atPath: cache.modelURL.path))
    }

    @Test func eofDuringScriptedPreloadWaitsForItAndSkipsModelWork() throws {
        let backend = ScriptedPreloadBackend()
        let input = Pipe()
        let output = Pipe()
        let server = SidecarServer(
            backend: backend,
            output: SidecarOutput(handle: output.fileHandleForWriting),
            log: { _ in },
            preloadEnabled: true
        )
        let run = LockedRunResult()
        let runCompleted = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            run.store(server.run(input: input.fileHandleForReading))
            runCompleted.signal()
        }

        #expect(backend.acquisitionStarted.wait(timeout: .now() + 1) == .success)
        try input.fileHandleForWriting.close()
        #expect(waitUntil(timeout: 1) { server.isShuttingDown })
        #expect(runCompleted.wait(timeout: .now()) == .timedOut)

        backend.allowAcquisitionToFinish.signal()

        #expect(runCompleted.wait(timeout: .now() + 1) == .success)
        #expect(run.value == 0)
        let state = backend.snapshot
        #expect(!state.modelLoadStarted)
        #expect(!state.decodeStarted)
        #expect(!state.shutdownWhilePreloading)
        #expect(state.shutdownCalled)
    }

    /// The fatal-decode exit path shares `joinPreloadForShutdown` with EOF: the
    /// shutdown flag is raised before the join so the preload thread bails out of
    /// model work, and the join reports success once that thread finishes within
    /// grace. Exit codes themselves stay covered by the gated process tests.
    @Test func joinPreloadForShutdownWaitsForTheScriptedPreload() throws {
        let backend = ScriptedPreloadBackend()
        let input = Pipe()
        let output = Pipe()
        let server = SidecarServer(
            backend: backend,
            output: SidecarOutput(handle: output.fileHandleForWriting),
            log: { _ in },
            preloadEnabled: true
        )
        let run = LockedRunResult()
        let runCompleted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            run.store(server.run(input: input.fileHandleForReading))
            runCompleted.signal()
        }
        #expect(backend.acquisitionStarted.wait(timeout: .now() + 1) == .success)

        let join = LockedRunResult()
        let joinCompleted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            join.store(server.joinPreloadForShutdown() ? 1 : 0)
            joinCompleted.signal()
        }

        // The flag goes up before the wait, so the preload observes it…
        #expect(waitUntil(timeout: 1) { server.isShuttingDown })
        // …and the join stays blocked until the preload thread actually finishes.
        #expect(joinCompleted.wait(timeout: .now()) == .timedOut)

        backend.allowAcquisitionToFinish.signal()

        #expect(joinCompleted.wait(timeout: .now() + 1) == .success)
        #expect(join.value == 1)
        let state = backend.snapshot
        #expect(!state.modelLoadStarted)
        #expect(!state.decodeStarted)

        // EOF joins again after the latch; run() must return promptly, not
        // block on a semaphore whose one signal was already consumed.
        try input.fileHandleForWriting.close()
        #expect(runCompleted.wait(timeout: .now() + 2) == .success)
        #expect(run.value == 0)
    }
    @Test func aThirdAssistCanCarryItsOwnDurationCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-assist-chain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = (1...3).map { directory.appendingPathComponent("assist-\($0).bin").path }
        for path in paths {
            try Data("assist".utf8).write(to: URL(fileURLWithPath: path))
        }
        var logs: [String] = []

        _ = try ParakeetSidecarBackend(
            cache: ParakeetModelCache(directory: directory),
            environment: [
                "VOICEOUR_ASSIST_MODEL": paths[0],
                "VOICEOUR_ASSIST_MODEL_2": paths[1],
                "VOICEOUR_ASSIST_MODEL_3": paths[2],
                "VOICEOUR_ASSIST_MAX_S": "15",
                "VOICEOUR_ASSIST_MODEL_3_MAX_S": "8",
            ],
            log: { logs.append($0) },
            idleUnloadMs: 0
        )

        let assistLog = try #require(logs.first { $0.contains("VOICEOUR_ASSIST_MODEL mode=chain") })
        #expect(assistLog.contains(paths.joined(separator: ",")))
        #expect(assistLog.contains("max_s=15.0,15.0,8.0"))
    }
    @Test func anAssistBeyondItsOwnSampleCapIsNotDecoded() throws {
        let bytes = Data("model".utf8)
        let artifact = ParakeetModelManifest(
            modelId: "test/model",
            revision: "test-revision",
            file: "model.bin",
            sha256: "test-digest",
            sizeBytes: Int64(bytes.count)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-assist-cap-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ParakeetModelCache(
            directory: directory,
            artifact: artifact,
            ownsVariantRoot: false
        )
        try bytes.write(to: cache.modelURL)
        try JSONEncoder().encode(artifact).write(to: cache.manifestURL)

        let included = AssistRecordingContext(text: "included")
        let excluded = AssistRecordingContext(text: "excluded")
        let contexts = ["included": included, "excluded": excluded]
        let backend = ParakeetSidecarBackend(
            cache: cache,
            log: { _ in },
            idleUnloadMs: 0,
            assistModelPaths: ["included", "excluded"],
            assistMaxSampleCounts: [32, 8],
            contextFactory: { _ in EmptyParakeetRuntimeContext() },
            assistContextFactory: { contexts[$0]! }
        )

        let terminal = backend.transcribe(
            transcribeRequest(audio: try writeSilentWAV(in: directory)),
            isCancelled: { false }
        )
        guard case .result(let transcript, _, _, _, _) = terminal else {
            Issue.record("the scripted decode must produce a transcript")
            return
        }
        #expect(transcript.assistTexts?.count == 1)
        #expect(included.decodeCount == 1)
        #expect(excluded.decodeCount == 0)
    }

}

private enum ScriptedLoadError: Error {
    case firstAttempt
    /// A model this process can never load, however many times it tries.
    case unloadable
}

/// The smallest request that reaches the model-load stage: validation only checks that the
/// audio exists and is WAV, and everything after the load is the decode's business.
private func transcribeRequest(audio: URL) -> ASRTranscribeRequest {
    ASRTranscribeRequest(
        requestId: "lifecycle",
        audio: ASRAudioMeta(
            path: audio.path,
            format: "wav",
            sampleRateHz: 16000,
            channels: 1,
            durationMs: 1,
            byteCount: 0
        ),
        expectedModel: nil,
        timeoutMs: 30_000
    )
}

/// A canonical 16 kHz mono PCM WAV holding a handful of silent frames.
private func writeSilentWAV(in directory: URL) throws -> URL {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let frames = 16
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

private final class FailThenSucceedContextFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func makeContext(modelPath _: String) throws -> any ParakeetRuntimeContext {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw ScriptedLoadError.firstAttempt }
        return EmptyParakeetRuntimeContext()
    }
}

private final class AssistRecordingContext: ParakeetRuntimeContext, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var recordedDecodeCount = 0

    init(text: String) {
        self.text = text
    }

    var decodeCount: Int {
        lock.withLock { recordedDecodeCount }
    }

    func transcribe(
        samples _: [Float],
        isCancelled _: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        lock.withLock { recordedDecodeCount += 1 }
        return [ParakeetSegmentRaw(startMs: 0, endMs: 1, text: text, tokens: [])]
    }
}

private final class EmptyParakeetRuntimeContext: ParakeetRuntimeContext {
    func transcribe(samples _: [Float], isCancelled _: @escaping () -> Bool) throws -> [ParakeetSegmentRaw] {
        []
    }
}

private final class WarmUpRecordingContext: ParakeetRuntimeContext {
    private(set) var requestDecodeCount = 0
    private(set) var warmUpDecodeCount = 0

    func transcribe(
        samples _: [Float],
        isCancelled _: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        requestDecodeCount += 1
        return []
    }

    func transcribeForWarmUp(
        samples _: [Float],
        isCancelled _: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        warmUpDecodeCount += 1
        return []
    }
}

private final class ScriptedPreloadBackend: SidecarBackend, ShutdownAwareSidecarPreloading, @unchecked Sendable {
    struct State {
        var modelLoadStarted = false
        var decodeStarted = false
        var shutdownWhilePreloading = false
        var shutdownCalled = false
    }

    let backendId = "scripted-preload"
    let acquisitionStarted = DispatchSemaphore(value: 0)
    let allowAcquisitionToFinish = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var state = State()
    private var preloadActive = false

    var snapshot: State { lock.withLock { state } }

    func startupStatus() -> BackendStatus { .ready }

    func health() -> ASRBackendHealth {
        ASRBackendHealth(
            backendId: backendId,
            backendStatus: .ready,
            ready: true,
            modelLoaded: false,
            cacheOk: true
        )
    }

    func transcribe(
        _ request: ASRTranscribeRequest,
        isCancelled _: @escaping () -> Bool
    ) -> SidecarTerminal {
        .failure(code: .internalError, detail: "unused in this test", fatal: false)
    }

    func warmUp() throws {
        try warmUp(isShuttingDown: { false })
    }

    func warmUp(isShuttingDown: @escaping () -> Bool) throws {
        lock.withLock { preloadActive = true }
        defer { lock.withLock { preloadActive = false } }
        acquisitionStarted.signal()
        allowAcquisitionToFinish.wait()

        guard !isShuttingDown() else { return }
        lock.withLock { state.modelLoadStarted = true }
        guard !isShuttingDown() else { return }
        lock.withLock { state.decodeStarted = true }
    }

    func shutdown() {
        lock.withLock {
            state.shutdownWhilePreloading = preloadActive
            state.shutdownCalled = true
        }
    }
}

private final class LockedRunResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?

    var value: Int32? { lock.withLock { stored } }

    func store(_ value: Int32) {
        lock.withLock { stored = value }
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
