import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac
@testable import Voiceour

/// Test doubles shared across the `Voiceour` test target.
///
/// Swift test targets cannot import one another, so each target keeps its own
/// support file. Doubles live here when more than one test file needs them;
/// single-consumer, behaviour-specific fakes stay private to their own file.
final class FakeRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var _producedURL: URL?
    private var starts = 0

    var producedURL: URL? {
        lock.withLock { _producedURL }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() throws {
        lock.withLock { starts += 1 }
    }

    func stop() async throws -> RecordedAudio {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2, 3]))
        lock.withLock { _producedURL = url }
        return RecordedAudio(
            url: url,
            meta: ASRAudioMeta(
                path: url.path,
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 100,
                byteCount: 4
            )
        )
    }

    func discardRecording() async {
        if let url = producedURL { try? FileManager.default.removeItem(at: url) }
    }

    func currentInputLevel() -> Float? { nil }
    func captureIsLive() -> Bool { true }
}

final class FakeASR: ASRClienting, @unchecked Sendable {
    enum Behavior {
        case text(String)
        case gatedText(TestGate, String)
        case custom(ASRResult)
        case throwError(Error)
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private var _receivedBiasPhrases: [ASRBiasPhrase] = []

    /// Bias phrases seen by the three-argument `transcribe` overload. Empty when
    /// the coordinator took the two-argument path (decoder bias disabled).
    var receivedBiasPhrases: [ASRBiasPhrase] {
        lock.withLock { _receivedBiasPhrases }
    }

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
        switch behavior {
        case .text(let text):
            return Self.result(text)
        case .gatedText(let gate, let text):
            await gate.wait()
            return Self.result(text)
        case .custom(let result):
            return result
        case .throwError(let error):
            throw error
        }
    }

    func transcribe(_ audio: RecordedAudio, timeoutMs: Int, biasPhrases: [ASRBiasPhrase]) async throws -> ASRResult {
        lock.withLock { _receivedBiasPhrases = biasPhrases }
        return try await transcribe(audio, timeoutMs: timeoutMs)
    }

    func health(timeoutMs: Int) async throws -> ASRBackendHealth {
        ASRBackendHealth(backendId: "fake", backendStatus: .ready, ready: true, modelLoaded: true, cacheOk: true)
    }

    private static func result(_ text: String) -> ASRResult {
        ASRResult(
            requestId: "req",
            backendId: "fake",
            modelId: "fake",
            modelRevision: "dev",
            transcript: ASRTranscript(text: text, language: "en", segments: nil),
            timingsMs: ASRTimings(load: 7, inference: 31, total: 38)
        )
    }
}

struct FakeTracker: TargetTracking {
    func snapshot() -> TargetSnapshot {
        TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1, safety: .normalText)
    }
    func stillMatches(_ snap: TargetSnapshot) -> Bool { true }
}

struct FakeInserter: TextInserting {
    let outcome: InsertionOutcome
    func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome { outcome }
}

struct FakePermissions: PermissionsChecking {
    func microphone() -> PermissionState { .granted }
    func synthPaste() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
}

final class FakeHotkey: HotkeyBinding, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancelHandler: (@Sendable () -> Void)?
    private var cancelArmed = false

    var isCancelArmed: Bool { lock.withLock { cancelArmed } }

    func onToggle(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.cancelHandler = handler }
    }

    func setCancelArmed(_ isArmed: Bool) {
        lock.withLock { cancelArmed = isArmed }
    }

    func trigger() {
        let callback: (@Sendable () -> Void)? = lock.withLock { self.handler }
        callback?()
    }

    /// Fires the Escape handler unconditionally; `isCancelArmed` is what the real
    /// binder gates on, so assert against it separately.
    func triggerCancel() {
        let callback: (@Sendable () -> Void)? = lock.withLock { self.cancelHandler }
        callback?()
    }
}

struct FakeRefiner: TranscriptRefining {
    func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle) async
        -> RefineOutcome
    {
        .skipped(reason: "test")
    }
}
