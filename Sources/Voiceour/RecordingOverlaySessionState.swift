import VoiceCore

extension SessionState {
    var isOverlayProcessing: Bool {
        switch self {
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            true
        default:
            false
        }
    }
}

/// Unclean delivery the island can dwell on. A clean paste and a cancel have
/// nothing extra to say: the transcript arriving in the target, or the user
/// having just asked, is already the confirmation.
struct RecordingOverlayOutcome: Equatable, Sendable {
    var symbol: String
    var word: String
    var isFailure: Bool
    var accessibilityStatus: String

    /// Nil for idle, every active state, `pasteAttempted`, and `cancelled`. A
    /// value only for the three deliveries that would otherwise vanish as a
    /// blank capsule. `failure` is the coordinator's published presentation,
    /// when it has one: an ASR code is deliberately coarser than the cause that
    /// produced it, so reconstructing from the code alone can turn a denied
    /// microphone into "the transcription engine is not running."
    init?(
        state: SessionState,
        failure: UserFacingDictationFailure? = nil
    ) {
        switch state {
        case .copiedOnly:
            symbol = "doc.on.doc"
            word = "COPIED"
            isFailure = false
            accessibilityStatus = "The transcript is on the clipboard."
        case .insertFailed:
            symbol = "exclamationmark.triangle"
            word = "COPIED"
            isFailure = false
            // Paste failed, but the clipboard still holds the transcript —
            // that half is what the user can act on. The associated reason
            // is an insertion token, never spoken.
            accessibilityStatus = "Paste failed. The transcript is on the clipboard."
        case .error(let code):
            symbol = "exclamationmark.triangle"
            word = "FAILED"
            isFailure = true
            // The published presentation is the same sentence the menu and
            // announcement use. The code's own row is only the floor for a
            // sidecar that stated no more precise cause. Neither path speaks
            // the wire token `SessionState.displayName` interpolates.
            accessibilityStatus =
                failure?.cause
                ?? UserFacingDictationFailure(code: code, detail: nil).cause
        default:
            return nil
        }
    }
}
