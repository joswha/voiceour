public enum SessionState: Equatable, Sendable {
    case idle
    case checkingPermissions
    case recording
    case finalizingAudio
    case transcribing
    case cleaning
    case refining
    case readyToInsert
    case pasteAttempted
    case copiedOnly(reason: String)
    case insertFailed(reason: String)
    case error(ASRErrorCode)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .idle, .pasteAttempted, .copiedOnly, .insertFailed, .error, .cancelled:
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
        case .refining: "Refining"
        case .readyToInsert: "Ready to insert"
        case .pasteAttempted: "Paste attempted"
        case .copiedOnly(let reason): "Copied: \(reason)"
        case .insertFailed(let reason): "Copied, paste failed: \(reason)"
        case .error(let code): "Error: \(code.rawValue)"
        case .cancelled: "Cancelled"
        }
    }
}
