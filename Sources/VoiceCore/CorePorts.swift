import Foundation

public protocol AudioRecording: Sendable {
    func start() throws
    func stop() async throws -> RecordedAudio
    func currentInputLevel() -> Float?
    func lastStartLatencyMs() -> Int?
    /// Whether microphone buffers are actually flowing for the live recording.
    /// UI uses this to distinguish "starting the mic" from "listening".
    func captureIsLive() -> Bool
    func discardRecording() async
    /// Pins future recordings to the capture device with this durable UID, or
    /// returns to automatic device choice on nil. Applies from the next
    /// `start()`; a live recording keeps the device it opened.
    func setPreferredCaptureDevice(uid: String?)
}

extension AudioRecording {
    public func currentInputLevel() -> Float? {
        nil
    }

    public func lastStartLatencyMs() -> Int? {
        nil
    }

    /// Recorders without buffer-arrival tracking count as live once started.
    public func captureIsLive() -> Bool {
        true
    }

    /// Recorders that do not capture from real hardware have no device to pin.
    public func setPreferredCaptureDevice(uid: String?) {}
    public func discardRecording() async {
        if let audio = try? await stop() {
            try? FileManager.default.removeItem(at: audio.url)
        }
    }
}

public protocol ASRClienting: Sendable {
    func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult
    func health(timeoutMs: Int) async throws -> ASRBackendHealth
    func warmUp() async
}

extension ASRClienting {
    public func warmUp() async {}
}

public protocol TargetTracking: Sendable {
    func snapshot() -> TargetSnapshot
    func stillMatches(_ snap: TargetSnapshot) -> Bool
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome
}

public protocol PermissionsChecking: Sendable {
    func microphone() -> PermissionState
    func requestMicrophone() async -> Bool
    func synthPaste() -> PermissionState
    func requestSynthPaste() async -> Bool
    func accessibility() -> PermissionState
}

extension PermissionsChecking {
    public func requestMicrophone() async -> Bool {
        microphone() == .granted
    }

    public func requestSynthPaste() async -> Bool {
        synthPaste() == .granted
    }
}

public protocol HotkeyBinding: Sendable {
    func onToggle(_ handler: @escaping @Sendable () -> Void)
    /// Escape dismisses a live dictation session. The binder claims Escape only
    /// while `setCancelArmed(true)` is in effect, so the key reaches the focused
    /// app untouched whenever no session is running.
    func onCancel(_ handler: @escaping @Sendable () -> Void)
    func setCancelArmed(_ isArmed: Bool)
}

public protocol SystemAudioMuting: Sendable {
    func mute() async -> Bool
    func restore() async
}

public struct NoOpSystemAudioMuter: SystemAudioMuting {
    public init() {}

    public func mute() async -> Bool {
        false
    }

    public func restore() async {}
}

/// Plays a session cue through whatever the default output device is.
///
/// Fire-and-forget: `play` returns once the sound has been started, never when it
/// has finished. A cue that cannot be played is not a dictation failure.
public protocol SessionCuePlaying: Sendable {
    func play(_ cue: SessionCue) async
}

public struct NoOpSessionCuePlayer: SessionCuePlaying {
    public init() {}

    public func play(_ cue: SessionCue) async {}
}
