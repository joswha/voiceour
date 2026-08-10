import VoiceCore
import VoiceMac

/// Model identity shown for the selected ASR backend.
///
/// The fake backend is the deliberate exception: Diagnostics shows the pinned
/// Parakeet contract there, because that is the model a real run would load.
/// Voice's own readout says "no model" instead — see `VoicePane.modelSummary`.
func asrModelLabel(for backend: String) -> String {
    guard backend != "fake" else { return ASRModelContract.modelId }
    return ASRBackendRegistry.builtIn.descriptor(for: backend)?.modelLabel ?? ASRModelContract.modelId
}
