import SwiftUI
import VoiceCore

struct RefinementOptInSection: View {
    var coordinator: DictationCoordinator
    let provider: RefinerProvider
    let statusMode: (StatusChip.Mode) -> StatusChip.Mode
    private var a11y = A11y()

    init(
        coordinator: DictationCoordinator,
        provider: RefinerProvider,
        statusMode: @escaping (StatusChip.Mode) -> StatusChip.Mode
    ) {
        self.coordinator = coordinator
        self.provider = provider
        self.statusMode = statusMode
    }

    var body: some View {
        // The eyebrow stays derived: "ON-DEVICE REFINER" and "NETWORK
        // REFINER" are the fastest answer this pane gives to the only
        // question it exists to answer, and a static "REFINER" would make
        // the destination readable only after the caption.
        SettingsSectionBlock(eyebrow: eyebrow(for: provider)) {
            optInRow(provider: provider)
        }
    }

    // MARK: - Refiner

    /// Always enabled, and always outside the dependent group. It carries the
    /// pane's one privacy statement, because the consequence of the switch
    /// belongs beside the switch, and the readiness chip, because "on" and
    /// "usable" are two different facts about the same row.
    private func optInRow(provider: RefinerProvider) -> some View {
        SettingsRow(
            label: "Opt in",
            status: (
                label: coordinator.refinerReadiness.label,
                mode: statusMode(readinessMode(coordinator.refinerReadiness))
            )
        ) {
            Toggle("Enable refiner", isOn: settingBinding(coordinator, \.refinerEnabled))
                .toggleStyle(GlassToggleStyle())
                // The style leaves `configuration.label` on SwiftUI's inherited
                // font; naming the token pins the size the design system chose.
                .font(VoiceOourTypography.body)
                .fixedSize(horizontal: true, vertical: false)
        } footer: {
            CaptionText(destinationAdvisory(for: provider), color: a11y.textMid)
        }
    }

    private func eyebrow(for provider: RefinerProvider) -> String {
        provider == .appleOnDevice ? "ON-DEVICE REFINER" : "NETWORK REFINER"
    }

    private func destinationAdvisory(for provider: RefinerProvider) -> String {
        switch provider {
        case .appleOnDevice:
            return "Refinement runs on this Mac. Dictated text never leaves the device."
        case .omp:
            return "While this is on, dictated text is sent over the network to the Oh My Pi provider you select."
        case .gemini, .openAI, .openRouter, .custom:
            let destination =
                host(of: RefinerResolved.baseURL(coordinator.settings))
                ?? "the endpoint you configure below"
            return "While this is on, dictated text is sent over the network to \(destination)."
        }
    }

    private func host(of baseURL: String) -> String? {
        guard let host = URL(string: baseURL)?.host, !host.isEmpty else { return nil }
        return host
    }

    private func readinessMode(_ readiness: RefinerReadiness) -> StatusChip.Mode {
        switch readiness {
        case .ready:
            .ok
        case .disabled:
            .neutral
        case .needsBaseURL, .needsModel, .needsKey:
            .warn
        }
    }
}
