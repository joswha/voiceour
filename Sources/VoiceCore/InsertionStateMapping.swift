extension DictationPolicy {
    public static func sessionState(for insertionOutcome: InsertionOutcome) -> SessionState {
        switch insertionOutcome {
        case .pasteAttempted:
            .pasteAttempted
        case .copiedOnly(let reason):
            .copiedOnly(reason: reason)
        case .failed(let reason):
            .insertFailed(reason: reason)
        }
    }
}
