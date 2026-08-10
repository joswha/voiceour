import SwiftUI
import VoiceCore
import VoiceMac

struct RefinementProviderSection: View {
    var coordinator: DictationCoordinator
    let provider: RefinerProvider
    let startOmpSignIn: (OmpSubscription) async -> Void

    var body: some View {
        SettingsSectionBlock(eyebrow: "PROVIDER") {
            providerRow()

            if provider == .appleOnDevice {
                onDeviceRow()
            }
            if provider == .omp {
                ompConnectionsRow()
            }
            if provider.isCustom {
                baseURLRow()
            }
            if let endpoint = resolvedEndpoint(for: provider) {
                endpointRow(endpoint)
            }
            if provider != .appleOnDevice {
                modelRow(provider: provider)
            }
        }
    }

    // MARK: - Provider

    private func providerRow() -> some View {
        SettingsRow(label: "Provider") {
            RefinerProviderPicker(
                selection: Binding(
                    get: { coordinator.settings.refinerProvider },
                    set: { coordinator.selectRefinerProvider($0) }
                )
            )
        }
    }

    /// Valueless fact rows: there is nothing to configure, only something to
    /// know. Both prose-only rows use the same primitive so they cannot render
    /// with two different label tones two rows apart.
    private func onDeviceRow() -> some View {
        PropertyRow(
            "On-device",
            caption:
                "Apple Intelligence runs the model in process — no endpoint and no API key to configure. \(foundationModelsDetail)."
        )
    }

    /// Apple Intelligence readiness is this Mac's state: OS version, hardware,
    /// and whether the user ever switched it on. The offscreen harness pins the
    /// sentence for the same reason it pins TCC answers — a golden may not
    /// record one developer's setup. The seam is nil everywhere else.
    private var foundationModelsDetail: String {
        RenderOverrides.foundationModelsDetail ?? FoundationModelsAvailability.summary().detail
    }

    private func ompConnectionsRow() -> some View {
        OmpConnectionsRow(
            connections: displayedOmpProviderConnections,
            statusState: displayedOmpProviderStatusState,
            onboardingState: displayedOmpOnboardingState,
            selectedProviderID: RefinerResolved.model(coordinator.settings)
                .split(separator: "/", maxSplits: 1)
                .first
                .map(String.init),
            onboardingDetail: ompOnboardingDetail(displayedOmpOnboardingState),
            onRefresh: {
                Task { await coordinator.refreshOmpProviderStatuses() }
            },
            onConnect: { subscription in
                Task { await startOmpSignIn(subscription) }
            }
        )
    }

    private func baseURLRow() -> some View {
        SettingsRow(label: "Base URL") {
            TextField("https://host/v1", text: settingBinding(coordinator, \.refinerBaseURL))
                .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                .accessibilityLabel("Base URL")
        } footer: {
            CaptionText("OpenAI-compatible base URL; VoiceOour appends /chat/completions.")
        }
    }

    /// The destination is a resolved machine value, so it takes the ledger's
    /// machine-value policy — mono, middle-truncated, help text for the full
    /// string — and its disabled tone comes from the row rather than from a
    /// bespoke view reading `isEnabled` for itself.
    private func endpointRow(_ endpoint: String) -> some View {
        PropertyRow("Endpoint", value: endpoint, valueStyle: .mono)
    }

    private func modelRow(provider: RefinerProvider) -> some View {
        SettingsRow(label: "Model") {
            TextField("model id", text: settingBinding(coordinator, \.refinerModel))
                .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                .accessibilityLabel("Model")
        } footer: {
            CaptionText(modelHelp(for: provider))
        }
    }

    private var displayedOmpOnboardingState: OmpOnboardingState {
        RenderOverrides.ompOnboardingState ?? coordinator.ompOnboardingState
    }

    private var displayedOmpProviderConnections: [OmpProviderConnection] {
        RenderOverrides.ompProviderConnections ?? coordinator.ompProviderConnections
    }

    private var displayedOmpProviderStatusState: OmpProviderStatusState {
        RenderOverrides.ompProviderStatusState ?? coordinator.ompProviderStatusState
    }

    private func ompOnboardingDetail(
        _ state: OmpOnboardingState
    ) -> (text: String, isFailure: Bool)? {
        switch state {
        case .idle:
            return nil
        case .opening:
            return ("Preparing OMP's provider catalog and temporary sign-in command.", false)
        case .terminalOpen:
            let detail =
                "Finish the browser, device-code, or key prompt in Terminal. "
                + "VoiceOour is waiting for OMP to return."
            return (detail, false)
        case .signedIn(_, _, let detail):
            return (detail, false)
        case .cancelled:
            return ("The OMP sign-in was cancelled; VoiceOour created no credential.", false)
        case .failed(_, let detail):
            return (detail, true)
        }
    }

    /// The endpoint is shown as its own row only where it is a resolved constant.
    /// Custom edits it in the Base URL row; the local and brokered providers have
    /// no endpoint to state.
    private func resolvedEndpoint(for provider: RefinerProvider) -> String? {
        guard provider != .omp, provider != .appleOnDevice, !provider.isCustom else { return nil }
        let baseURL = RefinerResolved.baseURL(coordinator.settings)
        return baseURL.isEmpty ? nil : baseURL
    }

    /// The suggested list doubles as a statement of the effective value, so an
    /// empty field reads as "defaulted", not as "unset".
    private func modelHelp(for provider: RefinerProvider) -> String {
        var sentences: [String] = []
        let isDefaulted = coordinator.settings.refinerModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if provider == .omp {
            if isDefaulted, let fallback = provider.suggestedModels.first {
                sentences.append("Empty uses the provider default, \(fallback).")
            }
            sentences.append("Connecting a common provider selects a matching subscription model.")
            sentences.append("Format: provider/model; CHECK validates any manual id.")
            return sentences.joined(separator: " ")
        }

        let suggestions = provider.suggestedModels
        if isDefaulted, let fallback = suggestions.first {
            sentences.append("Empty uses the provider default, \(fallback).")
            let alternatives = suggestions.dropFirst()
            if !alternatives.isEmpty {
                sentences.append("Also available: \(alternatives.joined(separator: ", ")).")
            }
        } else if !suggestions.isEmpty {
            sentences.append("Suggested: \(suggestions.joined(separator: ", ")).")
        }

        switch provider {
        case .custom:
            // Custom is the one provider with nothing to suggest, so without a
            // line of its own the field that most needs guidance ships a blank
            // caption instead.
            sentences.append("The model id your endpoint expects; VoiceOour sends it verbatim.")
        case .gemini, .openAI, .openRouter, .omp, .appleOnDevice:
            break
        }
        return sentences.joined(separator: " ")
    }
}

/// Six providers do not fit one 536 pt row, and a segment group is the wrong
/// place to start eliding names, so the group wraps to two rows of three.
private struct RefinerProviderPicker: View {
    @Binding var selection: RefinerProvider

    var body: some View {
        SegmentGroup(rows: 2) {
            ForEach(RefinerProvider.allCases, id: \.self) { provider in
                SegmentOption(
                    label: provider.displayName.uppercased(),
                    isSelected: selection == provider
                ) {
                    selection = provider
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Refiner provider")
    }
}
