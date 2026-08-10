import VoiceCore

extension SessionState {
    var isOverlayVisible: Bool {
        isActive
    }

    var isOverlayProcessing: Bool {
        switch self {
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
            true
        default:
            false
        }
    }

}
