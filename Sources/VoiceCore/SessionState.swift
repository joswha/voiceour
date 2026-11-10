public enum SessionState: Equatable, Sendable {
    case idle
    case checkingPermissions
    case recording
    case finalizingAudio
    case transcribing
    case cleaning
    case readyToInsert
    case pasteAttempted
    case copiedOnly(reason: String)
    case insertFailed(reason: String)
    /// A note was saved to memory and delivered nowhere. Terminal, like the
    /// delivery outcomes it stands in for.
    case noteSaved
    case error(ASRErrorCode)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .idle, .pasteAttempted, .copiedOnly, .insertFailed, .noteSaved, .error, .cancelled:
            false
        default:
            true
        }
    }

    public var isCritical: Bool {
        switch self {
        case .insertFailed, .error:
            true
        default:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .checkingPermissions: "Checking permissions"
        case .recording: "Recording"
        case .finalizingAudio: "Finalizing audio"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning"
        case .readyToInsert: "Ready to insert"
        case .pasteAttempted: "Paste attempted"
        case .copiedOnly(let reason): "Copied: \(reason)"
        case .insertFailed(let reason): "Delivery failed: \(reason)"
        case .noteSaved: "Note saved"
        case .error(let code): "Error: \(code.rawValue)"
        case .cancelled: "Cancelled"
        }
    }
}
