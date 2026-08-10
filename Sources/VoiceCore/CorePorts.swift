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

public protocol ASRClienting: Sendable {
    func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult
    func transcribe(_ audio: RecordedAudio, timeoutMs: Int, biasPhrases: [ASRBiasPhrase]) async throws -> ASRResult
    func health(timeoutMs: Int) async throws -> ASRBackendHealth
    func warmUp() async
    func lastTranscriptionPath() -> String?
}

extension ASRClienting {
    public func warmUp() async {}
    public func lastTranscriptionPath() -> String? { nil }

    /// Bias-aware decode. The default ignores `biasPhrases` and forwards to the
    /// unbiased two-argument path, so only backends that support decoder biasing
    /// (the sidecar) need to override it; Apple/Fake/Unsupported clients inherit
    /// this byte-identical default.
    public func transcribe(_ audio: RecordedAudio, timeoutMs: Int, biasPhrases: [ASRBiasPhrase]) async throws
        -> ASRResult
    {
        try await transcribe(audio, timeoutMs: timeoutMs)
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
}

extension TranscriptRefining {
    public func warmUp() async {}
}

public protocol SystemAudioMuting: Sendable {
    func mute(scope: MuteScope) async -> Bool
    func restore() async
}

public struct NoOpSystemAudioMuter: SystemAudioMuting {
    public init() {}

    public func mute(scope: MuteScope) async -> Bool {
        false
    }

    public func restore() async {}
}
