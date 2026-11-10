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
    /// Transcribes and spots `spotTerms` over the decode; the result's `termSpots` index them.
    func transcribe(_ audio: RecordedAudio, timeoutMs: Int, spotTerms: [ASRSpotTerm]) async throws -> ASRResult
    func health(timeoutMs: Int) async throws -> ASRBackendHealth
    func warmUp() async
}

extension ASRClienting {
    /// A client that cannot spot transcribes alone; its result carries no `termSpots`.
    public func transcribe(_ audio: RecordedAudio, timeoutMs: Int, spotTerms: [ASRSpotTerm]) async throws -> ASRResult {
        try await transcribe(audio, timeoutMs: timeoutMs)
    }

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

/// Finds the agent session whose input received a paste.
///
/// `capture` reads the host's focused pane before the paste; `resolve` reads it
/// again after the paste and returns a session only when the same pane and
/// foreground process still have focus and every live source names one
/// session. Every other answer is one `AgentLinkMiss`, so an unlinked
/// dictation can say why. Neither waits for another call. Implementations run
/// off the main actor.
public protocol AgentSessionResolving: Sendable {
    func capture(target: TargetSnapshot) async -> Result<AgentFocusCapture, AgentLinkMiss>
    func resolve(
        target: TargetSnapshot,
        before: AgentFocusCapture
    ) async -> Result<ResolvedAgentSession, AgentLinkMiss>
}

/// No host can be asked, so every answer is that Tern could not be read.
public struct NoAgentSessionResolving: AgentSessionResolving {
    public init() {}

    public func capture(target: TargetSnapshot) async -> Result<AgentFocusCapture, AgentLinkMiss> {
        .failure(.ternUnavailable)
    }

    public func resolve(
        target: TargetSnapshot,
        before: AgentFocusCapture
    ) async -> Result<ResolvedAgentSession, AgentLinkMiss> {
        .failure(.ternUnavailable)
    }
}

/// Reads a bound session's own records: its title and the prompts it recorded
/// after the binding's prompt-log offset. Nil when nothing can be read.
public protocol AgentSessionReading: Sendable {
    func read(_ binding: AgentSessionBinding) -> AgentSessionSnapshot?
}

public struct NoAgentSessionReading: AgentSessionReading {
    public init() {}

    public func read(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
        nil
    }
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
