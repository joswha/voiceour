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
    private var discards = 0
    private var pins: [String?] = []

    /// How many times the coordinator asked this recorder to throw its session
    /// away. Exactly one owner per session is the invariant: a cancel and the
    /// pipeline both discarding raced over the same WAV.
    var discardCount: Int {
        lock.withLock { discards }
    }

    var producedURL: URL? {
        lock.withLock { _producedURL }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    /// Every capture-device pin pushed at this recorder, in order, nils included:
    /// the coordinator pushes once at init and once per Settings change.
    var pinnedDeviceUIDs: [String?] {
        lock.withLock { pins }
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
        lock.withLock { discards += 1 }
        if let url = producedURL { try? FileManager.default.removeItem(at: url) }
    }

    func currentInputLevel() -> Float? { nil }
    func captureIsLive() -> Bool { true }
    func setPreferredCaptureDevice(uid: String?) {
        lock.withLock { pins.append(uid) }
    }
}

final class FakeASR: ASRClienting, @unchecked Sendable {
    enum Behavior {
        case text(String)
        case gatedText(TestGate, String)
        case custom(ASRResult)
        case throwError(Error)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var _backendHealth: ASRBackendHealth

    /// What a health probe answers. Settable because model readiness is a start
    /// precondition: a test that wants a session refused has to be able to say the
    /// artifact is not on disk.
    var backendHealth: ASRBackendHealth {
        get { lock.withLock { _backendHealth } }
        set { lock.withLock { _backendHealth = newValue } }
    }

    init(behavior: Behavior, backendHealth: ASRBackendHealth = FakeASR.ready) {
        self.behavior = behavior
        self._backendHealth = backendHealth
    }

    static let ready = ASRBackendHealth(
        backendId: "fake", backendStatus: .ready, ready: true, modelLoaded: true, cacheOk: true
    )

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

    func health(timeoutMs: Int) async throws -> ASRBackendHealth {
        backendHealth
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
    var bundleId: String? = "com.apple.TextEdit"
    var appName: String? = "TextEdit"
    var safety: TargetSafetyClass = .normalText

    func snapshot() -> TargetSnapshot {
        TargetSnapshot(bundleId: bundleId, appName: appName, pid: 1, safety: safety)
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

/// The directory SwiftPM built this test bundle into, which is also where the `voiceour-asr`
/// helper lands. The app resolves the sidecar as a sibling of its own executable; an
/// integration test that wants the real sidecar has to apply the same rule.
func testProductsDirectory() -> URL {
    Bundle(for: TestProductsAnchor.self).bundleURL.deletingLastPathComponent()
}

private final class TestProductsAnchor {}
