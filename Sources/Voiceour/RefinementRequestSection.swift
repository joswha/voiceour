import SwiftUI
import VoiceCore

struct RefinementRequestSection: View {
    var coordinator: DictationCoordinator
    let provider: RefinerProvider
    @Binding var timeoutDraft: String?
    @FocusState.Binding var timeoutFocused: Bool

    /// The band a refinement request may take. Below 500 ms every request times
    /// out and silently falls back; above 30 s the paste is no longer a paste.
    private static let timeoutBounds = 500...30_000

    var body: some View {
        SettingsSectionBlock(eyebrow: "REQUEST") {
            timeoutRow(provider: provider)
        }
    }

    // MARK: - Request

    private func timeoutRow(provider: RefinerProvider) -> some View {
        SettingsRow(label: "Timeout") {
            TextField("3000", text: timeoutBinding)
                .textFieldStyle(GlassTextFieldStyle(font: VoiceourTypography.bodyMono))
                .frame(width: VoiceourMetrics.Field.short)
                .focused($timeoutFocused)
                .onSubmit(commitTimeout)
                .onChange(of: timeoutFocused) { _, isFocused in
                    if !isFocused { commitTimeout() }
                }
                .accessibilityLabel("Timeout in milliseconds")
        } footer: {
            CaptionText(timeoutHelp(for: provider))
        }
    }

    private var timeoutBinding: Binding<String> {
        Binding(
            get: { timeoutDraft ?? String(coordinator.settings.refinerTimeoutMs) },
            set: { timeoutDraft = $0 }
        )
    }

    private func commitTimeout() {
        guard let draft = timeoutDraft else { return }
        // Dropping the draft reverts the field to the persisted value, which is
        // also what an unparseable entry deserves.
        timeoutDraft = nil
        guard let entered = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let clamped = min(max(entered, Self.timeoutBounds.lowerBound), Self.timeoutBounds.upperBound)
        guard clamped != coordinator.settings.refinerTimeoutMs else { return }
        coordinator.settings.refinerTimeoutMs = clamped
        coordinator.saveSettings()
    }

    private func timeoutHelp(for provider: RefinerProvider) -> String {
        // The refiner is rebound from settings before each utterance, so a saved
        // timeout governs the next thing dictated. The pane used to promise a
        // relaunch, which described an older binding and is now simply untrue.
        //
        // The field is a base, not the budget: `RefinerPolicy.effectiveTimeoutMs`
        // grants 20 ms per transcript word on top of it, up to twice the base.
        // So the copy states what refinement costs and what a miss does, and
        // never claims a particular setting always times out.
        let band =
            "Milliseconds, \(Self.timeoutBounds.lowerBound)–\(Self.timeoutBounds.upperBound). Saved changes apply to the next utterance — no relaunch."
        switch provider {
        case .omp:
            return "\(band) Oh My Pi routes through your subscription via a persistent background session (~1–2s warm)."
        case .appleOnDevice:
            return
                "\(band) The Apple on-device model runs locally. Measured refinements are typically 1.6–2.0s; timeouts and guard rejections fall back to the deterministic cleanup text."
        }
    }
}
