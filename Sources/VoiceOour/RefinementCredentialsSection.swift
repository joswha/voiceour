import AppKit
import SwiftUI
import VoiceCore

struct RefinementCredentialsSection: View {
    var coordinator: DictationCoordinator
    let provider: RefinerProvider
    @Binding var apiKeyInput: String
    @Binding var isConfirmingKeyClear: Bool
    @Binding var checkedFingerprint: String?
    let statusMode: (StatusChip.Mode) -> StatusChip.Mode

    var body: some View {
        if needsKey(provider) {
            SettingsSectionBlock(eyebrow: "CREDENTIALS") {
                apiKeyRow(provider: provider)

                // Only the Keychain item can be deleted from here, so the
                // control exists only when there is a Keychain item to
                // delete: an environment key is not ours to erase.
                if coordinator.refinerKeySource == .keychain {
                    clearKeyRow
                }
            }
        }
    }

    // MARK: - Credentials

    private func apiKeyRow(provider: RefinerProvider) -> some View {
        SettingsRow(
            label: "API key",
            status: (
                label: coordinator.refinerKeySource.label,
                mode: statusMode(keySourceMode(coordinator.refinerKeySource))
            )
        ) {
            HStack(spacing: VoiceOourMetrics.Space.sm) {
                // The prompt is an instruction, not a value: a masked field
                // whose placeholder reads "API key" beside a chip asserting
                // KEY SAVED claims the stored credential is sitting in it.
                SecureField("Paste a new key", text: $apiKeyInput)
                    .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                    .onSubmit(saveAPIKey)
                    .accessibilityLabel("API key")

                // SAVE is the row's affirmative action and sits next to the field it
                // commits, ahead of the link-out. Ranked `.accent` for the same reason:
                // a ghost SAVE beside a ghost link-out made leaving the app the loudest
                // thing on the row.
                //
                // SAVE with an empty field deletes the stored credential, so
                // deletion is not something SAVE is allowed to do by accident.
                Button("SAVE", action: saveAPIKey)
                    .buttonStyle(GlassButtonStyle(kind: .accent))
                    .disabled(trimmedAPIKeyInput.isEmpty)

                if let apiKeyURL = provider.apiKeyURL, let url = URL(string: apiKeyURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: VoiceOourMetrics.Space.xs) {
                            Text("GET API KEY")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: VoiceOourMetrics.Icon.mark))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(GlassButtonStyle(kind: .ghost))
                    .accessibilityLabel("Get API key, opens in browser")
                }
            }
        } footer: {
            // Both notes can be true at once — a Keychain write can fail while an
            // environment key is still what the refiner would use — so they stack
            // as two caption lines instead of racing for one slot beside a chip.
            if let keychainError = coordinator.keychainError {
                CaptionText(keychainError, color: VoiceOourPalette.Signal.crimson)
            }
            if coordinator.refinerKeySource == .environment {
                CaptionText(
                    "Using a key from the environment (\(environmentKeyNames(for: provider))). Save one here to store it in the Keychain."
                )
            }
        }
    }

    /// The variables the key provider actually reads, in the order it reads
    /// them. The generic fallback covers every provider including Custom, which
    /// has no name of its own — naming neither left that row pointing at a
    /// variable that does not exist.
    private func environmentKeyNames(for provider: RefinerProvider) -> String {
        guard let providerName = provider.apiKeyEnvName else { return "VOICEOOUR_REFINER_API_KEY" }
        return "\(providerName) or VOICEOOUR_REFINER_API_KEY"
    }

    /// Deleting a credential is typed-confirmed and now shares Diagnostics'
    /// state machine outright rather than reimplementing two thirds of it: the
    /// same token, the same guarded submit, the same in-flight and NOT ERASED
    /// branches. `subject` is "API key clear" so the confirmation field keeps
    /// the accessibility label it has always published.
    private var clearKeyRow: some View {
        ConfirmActionRow(
            label: "Clear key",
            subject: "API key clear",
            scope: "Delete the key stored in this Mac's Keychain. A key from the environment is not affected.",
            actionTitle: "CLEAR KEY",
            inFlightTitle: "CLEARING…",
            failureLabel: "NOT ERASED",
            failureText: "The Keychain refused to delete the key — it is still stored on this Mac.",
            identifier: "refinement.key",
            // The row is only built for a Keychain-owned key, so by the time it
            // exists there is always something for it to erase.
            isAvailable: true,
            isConfirming: $isConfirmingKeyClear,
            perform: { await clearAPIKey() }
        )
    }

    private var trimmedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The single guarded entry point for storing a key: the Button and
    /// `.onSubmit` both land here, so neither can save an empty string.
    private func saveAPIKey() {
        let key = trimmedAPIKeyInput
        guard !key.isEmpty else { return }
        coordinator.saveRefinerAPIKey(key)
        guard coordinator.keychainError == nil else { return }
        apiKeyInput = ""
        // A new credential invalidates a verdict measured against the old one.
        checkedFingerprint = nil
    }

    /// Reports whether the credential is actually gone: a Keychain refusal keeps
    /// the confirmation armed with the reason rendered above it, exactly as the
    /// pane behaved when it owned the state machine itself.
    private func clearAPIKey() async -> Bool {
        coordinator.saveRefinerAPIKey("")
        guard coordinator.keychainError == nil, coordinator.refinerKeySource != .keychain else {
            return false
        }
        checkedFingerprint = nil
        return true
    }

    private func needsKey(_ provider: RefinerProvider) -> Bool {
        provider != .omp && provider != .appleOnDevice
    }

    private func keySourceMode(_ source: RefinerKeySource) -> StatusChip.Mode {
        switch source {
        case .keychain:
            .ok
        case .environment:
            .neutral
        case .none:
            .warn
        }
    }
}
