import Foundation

/// A dictation failure as the user should read it, and where they can go to fix it.
///
/// The wire's `ASRErrorCode` names a mechanism (`manifest_mismatch`,
/// `unsupported_audio_format`), and the menu used to render that mechanism
/// verbatim: `Error: manifest_mismatch` says nothing about what the user can do.
/// This is the one translation from code to sentence, so the menu, the pipeline
/// and any later surface cannot describe the same failure differently.
///
/// `detail` from the sidecar is deliberately NOT the user-facing sentence. It is a
/// diagnostic — a path, a decoder message, a device name — and it is carried
/// alongside so Diagnostics can still show it.
public struct UserFacingDictationFailure: Equatable, Sendable {
    /// Where the user has to go to clear this failure.
    public enum Destination: Equatable, Sendable {
        /// The app's own settings, e.g. the backend or model state.
        case voiceSettings
        /// System Settings — a permission only macOS can grant.
        case systemSettings
        /// Nothing to configure: retrying or speaking again is the whole remedy.
        case none
    }

    /// Three or four words, in the app's status voice.
    public let title: String
    /// One sentence naming the cause in the user's terms.
    public let cause: String
    /// Whether repeating the same dictation could plausibly succeed.
    public let isRetryable: Bool
    public let destination: Destination
    /// The backend's own message, when there was one. Never shown as the cause.
    public let detail: String?

    public init(
        title: String,
        cause: String,
        isRetryable: Bool,
        destination: Destination,
        detail: String? = nil
    ) {
        self.title = title
        self.cause = cause
        self.isRetryable = isRetryable
        self.destination = destination
        self.detail = detail
    }
}

extension UserFacingDictationFailure {
    /// One mapped row: what the user reads and where they can act.
    struct Row: Equatable, Sendable {
        let title: String
        let cause: String
        let isRetryable: Bool
        let destination: Destination
    }

    /// One row per wire error code.
    ///
    /// A table rather than a switch so the mapping reads as data, and
    /// `UserFacingDictationFailureTests.everyErrorCodeHasAUserFacingRow` pins it
    /// against `ASRErrorCode.allCases` — a code added to the wire without a
    /// sentence here fails that test rather than reaching a user.
    static let rows: [ASRErrorCode: Row] = [
        .modelNotInstalled: Row(
            title: "MODEL NEEDED",
            cause: "The speech model has not finished downloading yet.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .manifestMismatch: Row(
            title: "MODEL MISMATCH",
            cause: "The cached speech model is not the one this build expects; it will be fetched again.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .artifactMismatch: Row(
            title: "DOWNLOAD DAMAGED",
            cause: "The speech model that arrived did not match what this build expects, so it was discarded.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .modelDownloadFailed: Row(
            title: "DOWNLOAD FAILED",
            cause: "The speech model could not be downloaded.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .insufficientDiskSpace: Row(
            // The byte budget the sidecar measured stays in `detail`: a reader who has to free
            // space needs to know that, not that 1,342,177,280 bytes were wanted.
            title: "DISK FULL",
            cause: "Voiceour needs more free space on this Mac before it can download the speech model.",
            isRetryable: false,
            destination: .voiceSettings
        ),
        .modelLoadFailed: Row(
            title: "MODEL FAILED",
            cause: "The speech model could not be loaded on this Mac.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .backendUnavailable: Row(
            title: "ENGINE OFFLINE",
            cause: "The transcription engine is not running.",
            isRetryable: true,
            destination: .voiceSettings
        ),
        .incompatibleProtocol: Row(
            title: "ENGINE MISMATCH",
            cause: "The transcription engine speaks a different protocol than this build.",
            isRetryable: false,
            destination: .voiceSettings
        ),
        .timeout: Row(
            title: "TIMED OUT",
            cause: "Transcription took too long and was stopped.",
            isRetryable: true,
            destination: .none
        ),
        .inferenceFailed: Row(
            title: "TRANSCRIBE FAILED",
            cause: "The engine could not transcribe that recording.",
            isRetryable: true,
            destination: .none
        ),
        .audioNotFound: Row(
            title: "RECORDING LOST",
            cause: "The recording could not be read back for transcription.",
            isRetryable: true,
            destination: .none
        ),
        .unsupportedAudioFormat: Row(
            title: "RECORDING LOST",
            cause: "The recording could not be read back for transcription.",
            isRetryable: true,
            destination: .none
        ),
        .cancelled: Row(
            title: "CANCELLED",
            cause: "That dictation was cancelled.",
            isRetryable: true,
            destination: .none
        ),
        .invalidRequest: Row(
            title: "INTERNAL ERROR",
            cause: "Something inside Voiceour went wrong during that dictation.",
            isRetryable: true,
            destination: .none
        ),
        .internalError: Row(
            title: "INTERNAL ERROR",
            cause: "Something inside Voiceour went wrong during that dictation.",
            isRetryable: true,
            destination: .none
        ),
    ]

    /// Maps a wire failure to what the user reads.
    ///
    /// `acquisitionFraction` is the model download's progress when one is running.
    /// `model_not_installed` during a download is not a fault the user can act on,
    /// it is a wait, so it renders as progress instead.
    public init(code: ASRErrorCode, detail: String?, acquisitionFraction: Double? = nil) {
        if code == .modelNotInstalled, let fraction = acquisitionFraction {
            self.init(
                title: "DOWNLOADING MODEL",
                cause: "The speech model is still downloading — \(Self.percent(fraction)) done.",
                isRetryable: true,
                destination: .none,
                detail: detail
            )
            return
        }
        let row =
            Self.rows[code]
            ?? Row(
                title: "INTERNAL ERROR",
                cause: "Something inside Voiceour went wrong during that dictation.",
                isRetryable: true,
                destination: .none
            )
        self.init(
            title: row.title,
            cause: row.cause,
            isRetryable: row.isRetryable,
            destination: row.destination,
            detail: detail
        )
    }

    /// A capture that never produced usable audio. Distinct from every wire code:
    /// nothing reached the engine, so nothing about the engine is at fault.
    public static func captureFailed(reason: String) -> UserFacingDictationFailure {
        UserFacingDictationFailure(
            title: "NO AUDIO",
            cause: "Nothing was recorded — \(reason).",
            isRetryable: true,
            destination: .systemSettings,
            detail: reason
        )
    }

    /// Microphone access refused. The only remedy is outside the app.
    public static let microphoneDenied = UserFacingDictationFailure(
        title: "MIC BLOCKED",
        cause: "Voiceour cannot use the microphone until you allow it in System Settings.",
        isRetryable: false,
        destination: .systemSettings
    )

    /// Progress as whole percent, floored: 99.6% reads as 99%, never as a
    /// finished download that is still running.
    static func percent(_ fraction: Double) -> String {
        let clamped = Swift.min(Swift.max(fraction, 0), 1)
        return "\(Int(clamped * 100))%"
    }
}
