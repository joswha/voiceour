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

        let cache = ParakeetModelCache(directory: directory, artifact: artifact)
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

        try backend.warmUp()

        #expect(backend.health().ready)
        #expect(backend.health().modelLoaded)
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
}

private enum ScriptedLoadError: Error {
    case firstAttempt
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

private final class EmptyParakeetRuntimeContext: ParakeetRuntimeContext {
    func transcribe(samples _: [Float], isCancelled _: @escaping () -> Bool) throws -> [ParakeetSegmentRaw] {
        []
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
