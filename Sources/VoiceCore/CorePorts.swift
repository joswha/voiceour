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

    public func discardRecording() async {
        if let audio = try? await stop() {
            try? FileManager.default.removeItem(at: audio.url)
        }
    }
}

/// The raw audio captured so far, for a preview decode of a live utterance.
///
/// A file rather than a buffer: the sidecar reads it by path exactly as it reads the finished
/// WAV, so a partial costs one open and no copy of the samples through the protocol.
public struct PartialAudioSnapshot: Sendable {
    public var pcmURL: URL
    public var sampleCount: Int

    public init(pcmURL: URL, sampleCount: Int) {
        self.pcmURL = pcmURL
        self.sampleCount = sampleCount
    }
}

/// A recorder that can hand out the utterance so far without ending it.
///
/// Only `MicrophoneRecorder` adopts this. The fake and Apple-Speech paths deliberately do not:
/// there are no partial previews in fake development, and the system transcriber streams its
/// own.
public protocol PartialAudioProviding: Sendable {
    /// The audio captured so far, as raw 16 kHz mono s16le. Nil until capture is live.
    func partialAudio() -> PartialAudioSnapshot?
}

public protocol ASRClienting: Sendable {
    func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult
    func health(timeoutMs: Int) async throws -> ASRBackendHealth
    func warmUp() async
    func lastTranscriptionPath() -> String?
    /// Decodes the utterance so far for preview only. Never inserted, never adopted unless the
    /// tail after the snapshot proved to be silence.
    func transcribePartial(pcmURL: URL, sampleCount: Int, timeoutMs: Int) async throws -> ASRResult
}

extension ASRClienting {
    public func warmUp() async {}
    public func lastTranscriptionPath() -> String? { nil }

    /// Backends without a partial path fail once, and the preview engine disables itself for
    /// the session. That is the whole opt-in mechanism: no capability flag to keep in sync.
    public func transcribePartial(pcmURL: URL, sampleCount: Int, timeoutMs: Int) async throws -> ASRResult {
        throw ASRErrorMessage(
            code: .backendUnavailable,
            requestId: nil,
            detail: "partial transcription unsupported"
        )
    }
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

public protocol TranscriptRefining: Sendable {
    func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle) async
        -> RefineOutcome
    /// Optional startup hook so refiners with expensive backends (persistent
    /// child processes, model sessions) can warm up off the dictation path.
    func warmUp() async
    /// The model that produced the most recent `refine` call's candidate, as
    /// the backend identifies it, or nil when no model ran.
    ///
    /// Read-after-call like `ASRClienting.lastTranscriptionPath()`, and safe
    /// for the same reason: the coordinator runs one refinement at a time. A
    /// backend that answers this MUST clear it when a call fails before the
    /// model ran, so a stale identity can never be attributed to a session the
    /// model never saw.
    func lastModelIdentity() -> String?
}

extension TranscriptRefining {
    public func warmUp() async {}
    public func lastModelIdentity() -> String? { nil }
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
