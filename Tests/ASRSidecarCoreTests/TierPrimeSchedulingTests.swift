import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The tier-prime schedule is the contract that a newly created context — whether the preload
/// thread's or a post-idle-unload reload's — gets its CoreML tiers primed off the request path,
/// exactly once per context instance, and only when the warm mode asks for it.
private final class PrimeRecordingContext: ParakeetRuntimeContext {
    let primed = Signal()

    func transcribe(
        samples: [Float], isCancelled: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        []
    }

    func primeCoreMLTiers(log: (String) -> Void) {
        primed.hit()
    }
}

private final class Signal {
    private let lock = NSLock()
    private var count = 0

    func hit() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func wait(for expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value() >= expected { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return value() >= expected
    }
}

private func temporaryCache() throws -> ParakeetModelCache {
    let artifact = ParakeetModelManifest(
        modelId: "test/model",
        revision: "test-revision",
        file: "model.bin",
        sha256: "test-digest",
        sizeBytes: 4
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tier-prime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = ParakeetModelCache(directory: directory, artifact: artifact, ownsVariantRoot: false)
    // The context factory is stubbed, so the model file only needs to exist (with its
    // manifest, which `cacheOK` compares) for the request path to reach the load.
    try Data("stub".utf8).write(to: cache.modelURL)
    try JSONEncoder().encode(artifact).write(to: cache.manifestURL)
    return cache
}

/// A canonical 44-byte-header PCM WAV: 16 kHz mono s16, 160 frames of silence.
private func temporaryWAV() throws -> URL {
    let frames = 160
    let dataBytes = frames * 2
    var wav = Data()
    func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    wav.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + dataBytes))
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    append(16)
    append16(1)
    append16(1)
    append(16_000)
    append(32_000)
    append16(2)
    append16(16)
    wav.append(contentsOf: "data".utf8)
    append(UInt32(dataBytes))
    wav.append(Data(count: dataBytes))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tier-prime-\(UUID().uuidString).wav")
    try wav.write(to: url)
    return url
}

private func primeRequest(id: String, wav: URL) -> ASRTranscribeRequest {
    ASRTranscribeRequest(
        requestId: id,
        audio: ASRAudioMeta(
            path: wav.path, format: "wav", sampleRateHz: 16_000,
            channels: 1, durationMs: 10, byteCount: 364),
        expectedModel: nil,
        timeoutMs: 1_000
    )
}

struct TierPrimeSchedulingTests {
    @Test func warmModeTiersPrimesEveryNewContextOnce() throws {
        let context = PrimeRecordingContext()
        let backend = ParakeetSidecarBackend(
            cache: try temporaryCache(),
            log: { _ in },
            idleUnloadMs: 0,
            coreMLWarm: .tiers,
            contextFactory: { _ in context }
        )
        // A short transcribe loads the context lazily — the same path a
        // post-idle-unload dictation takes — and must schedule exactly one prime.
        let request = primeRequest(id: "prime-1", wav: try temporaryWAV())
        let terminal = backend.transcribe(request, isCancelled: { false })
        if case .failure(let code, let detail, _) = terminal {
            Issue.record("transcribe failed before loading: \(code) \(detail)")
        }
        #expect(context.primed.wait(for: 1, timeout: 2.0))

        // A second request reuses the loaded context: no further prime.
        _ = backend.transcribe(request, isCancelled: { false })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(context.primed.value() == 1)
        backend.shutdown()
    }

    @Test func defaultWarmModeSchedulesNoPrime() throws {
        let context = PrimeRecordingContext()
        let backend = ParakeetSidecarBackend(
            cache: try temporaryCache(),
            log: { _ in },
            idleUnloadMs: 0,
            coreMLWarm: .default,
            contextFactory: { _ in context }
        )
        let request = primeRequest(id: "prime-2", wav: try temporaryWAV())
        _ = backend.transcribe(request, isCancelled: { false })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(context.primed.value() == 0)
        backend.shutdown()
    }
}
