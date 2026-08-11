import SwiftUI
import VoiceCore

struct RefinementConnectionSection: View {
    let provider: RefinerProvider
    let displayedReachability: RefinerReachability
    let statusMode: (StatusChip.Mode) -> StatusChip.Mode
    let runReachabilityCheck: () async -> Void
    private var a11y = A11y()

    init(
        provider: RefinerProvider,
        displayedReachability: RefinerReachability,
        statusMode: @escaping (StatusChip.Mode) -> StatusChip.Mode,
        runReachabilityCheck: @escaping () async -> Void
    ) {
        self.provider = provider
        self.displayedReachability = displayedReachability
        self.statusMode = statusMode
        self.runReachabilityCheck = runReachabilityCheck
    }

    var body: some View {
        SettingsSectionBlock(eyebrow: "CONNECTION") {
            statusRow(provider: provider)
        }
    }

    // MARK: - Connection

    private func statusRow(provider: RefinerProvider) -> some View {
        let reachability = displayedReachability
        let status = reachabilityStatus(reachability, provider: provider)

        return SettingsRow(
            label: "Status",
            status: (label: status.label, mode: statusMode(status.mode))
        ) {
            Button(isCheckingReachability ? "CHECKING…" : "CHECK") {
                Task { await runReachabilityCheck() }
            }
            .buttonStyle(GlassButtonStyle(kind: .ghost, isInFlight: isCheckingReachability))
        } footer: {
            // The verdict's reason and the permanent explanation of what the
            // probe does are both wanted at once; the reason leads because it is
            // the answer to the question the CHECK button just asked.
            if let detail = statusDetail(reachability) {
                CaptionText(detail, color: a11y.textMid)
            }
            CaptionText(probeExplanation(for: provider))
        }
    }

    private var isCheckingReachability: Bool {
        if case .checking = displayedReachability {
            return true
        }
        return false
    }

    private func probeExplanation(for provider: RefinerProvider) -> String {
        switch provider {
        case .appleOnDevice:
            return "Checks whether Apple Intelligence is available on this Mac. Nothing is sent anywhere."
        case .omp:
            return "Runs `omp models` locally and looks for the selected model in the result. No transcript is sent."
        }
    }

    private func reachabilityStatus(
        _ reachability: RefinerReachability,
        provider: RefinerProvider
    ) -> (label: String, mode: StatusChip.Mode) {
        switch reachability {
        case .unknown:
            ("NOT CHECKED", .neutral)
        case .checking:
            ("CHECKING…", .neutral)
        case .ok(let models):
            provider == .appleOnDevice
                ? ("AVAILABLE", .ok)
                : ("REACHABLE · \(models) \(models == 1 ? "MODEL" : "MODELS")", .ok)
        case .failed:
            ("UNREACHABLE", .warn)
        }
    }

    /// The probe knows why it failed; the row that exists to answer "why doesn't
    /// refinement work" is the one place that answer belongs.
    private func statusDetail(_ reachability: RefinerReachability) -> String? {
        switch reachability {
        case .failed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .unknown, .checking, .ok:
            return nil
        }
    }
}
