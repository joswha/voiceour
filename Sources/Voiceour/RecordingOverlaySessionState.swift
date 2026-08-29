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

/// How the body reports an unclean delivery.
///
/// Three deterministic silhouette gestures, held for `RecordingOverlayMetrics.outcomeDwell`.
/// No glyph, no word, and never a hue: the island paints no text at all, and the sentence
/// a reader needs is already in the status element's accessibility value, the VoiceOver
/// announcement, and the menu.
enum MercuryOutcomeGesture: Sendable, Equatable {
    /// A copy-only delivery that cost the user nothing: the body draws in on itself.
    case gathered
    /// A paste that was refused: one lateral lean and rebound.
    case lurch
    /// A dictation that produced no text: the body flattens and trembles.
    case collapse
}

/// Unclean delivery the island can dwell on. A clean paste and a cancel have
/// nothing extra to say: the transcript arriving in the target, or the user
/// having just asked, is already the confirmation.
struct RecordingOverlayOutcome: Equatable, Sendable {
    var gesture: MercuryOutcomeGesture
    var isFailure: Bool
    var accessibilityStatus: String

    /// Nil for idle, every active state, `pasteAttempted`, and `cancelled`. A
    /// value only for the three deliveries that would otherwise disappear with no
    /// visible report. `failure` is the coordinator's published presentation,
    /// when it has one: an ASR code is deliberately coarser than the cause that
    /// produced it, so reconstructing from the code alone can turn a denied
    /// microphone into "the transcription engine is not running."
    init?(
        state: SessionState,
        failure: UserFacingDictationFailure? = nil
    ) {
        switch state {
        case .copiedOnly:
            gesture = .gathered
            isFailure = false
            accessibilityStatus = "The transcript is on the clipboard."
        case .insertFailed:
            gesture = .lurch
            isFailure = false
            // Paste failed, but the clipboard still holds the transcript —
            // that half is what the user can act on. The associated reason
            // is an insertion token, never spoken.
            accessibilityStatus = "Paste failed. The transcript is on the clipboard."
        case .error(let code):
            gesture = .collapse
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
