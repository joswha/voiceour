import SwiftUI
import VoiceMac

struct OmpProviderConnectionRow: View {
    let row: OmpConnectionRowModel
    let statusState: OmpProviderStatusState
    let onboardingState: OmpOnboardingState
    let isInUse: Bool
    let onConnect: (OmpSubscription) -> Void

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(
        row: OmpConnectionRowModel,
        statusState: OmpProviderStatusState,
        onboardingState: OmpOnboardingState,
        isInUse: Bool,
        onConnect: @escaping (OmpSubscription) -> Void
    ) {
        self.row = row
        self.statusState = statusState
        self.onboardingState = onboardingState
        self.isInUse = isInUse
        self.onConnect = onConnect
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                Text(row.displayName)
                    .font(VoiceourTypography.body)
                    .foregroundStyle(isEnabled ? VoiceourPalette.Text.high : a11y.textLow)
                    .recordTextRole(
                        .body,
                        foreground: isEnabled ? VoiceourPalette.Text.high : a11y.textLow
                    )
                Text("\(row.providerID) · \(accountSummary)")
                    .font(VoiceourTypography.caption)
                    .foregroundStyle(a11y.textLow)
                    .recordTextRole(.caption, foreground: a11y.textLow)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: VoiceourMetrics.Space.sm)

            StatusChip(label: connectionStatus.label, mode: connectionStatus.mode, size: .compact)
            if isInUse {
                StatusChip(label: "IN USE", mode: .live, size: .compact)
            }
            if let subscription = row.subscription {
                Button(actionTitle) { onConnect(subscription) }
                    .buttonStyle(
                        GlassButtonStyle(kind: .ghost, isInFlight: isOnboardingThisProvider)
                    )
                    .disabled(onboardingState.isInFlight)
                    .accessibilityLabel(actionAccessibilityLabel(for: subscription))
                    .accessibilityIdentifier("refinement.omp.connect.\(subscription.rawValue)")
            }
        }
        .padding(.horizontal, VoiceourMetrics.Space.sm)
        .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Row.list, alignment: .leading)
    }

    private var connectionStatus: (label: String, mode: StatusChip.Mode) {
        if let subscription = row.subscription {
            switch onboardingState {
            case .opening(let active) where active == subscription:
                return ("OPENING…", .neutral)
            case .terminalOpen(let active) where active == subscription:
                return ("TERMINAL OPEN", .neutral)
            case .failed(let active, _) where active == subscription:
                return ("SIGN-IN FAILED", .crit)
            case .cancelled(let active) where active == subscription:
                return ("CANCELLED", .neutral)
            case .idle, .opening, .terminalOpen, .signedIn, .cancelled, .failed:
                break
            }
        }
        if row.connection?.isConnected == true { return ("CONNECTED", .ok) }
        if (row.connection?.disabledAccounts ?? 0) > 0 { return ("NEEDS SIGN-IN", .warn) }
        switch statusState {
        case .idle:
            return ("NOT CHECKED", .neutral)
        case .checking:
            return ("CHECKING…", .neutral)
        case .loaded:
            return ("NOT CONNECTED", .neutral)
        case .failed:
            return ("UNKNOWN", .warn)
        }
    }

    private var accountSummary: String {
        guard let connection = row.connection else {
            return statusState == .loaded ? "No OMP account" : "Account status pending"
        }
        if connection.activeAccounts > 0 {
            let accountLabel = connection.activeAccounts == 1 ? "account" : "accounts"
            let active = "\(connection.activeAccounts) \(accountLabel)"
            guard connection.disabledAccounts > 0 else { return active }
            let disabledLabel =
                connection.disabledAccounts == 1
                ? "account needs"
                : "accounts need"
            return "\(active) · \(connection.disabledAccounts) \(disabledLabel) sign-in"
        }
        if connection.disabledAccounts > 0 {
            let accountLabel =
                connection.disabledAccounts == 1
                ? "account needs"
                : "accounts need"
            return "\(connection.disabledAccounts) \(accountLabel) sign-in"
        }
        return "No OMP account"
    }

    private var isOnboardingThisProvider: Bool {
        guard let subscription = row.subscription else { return false }
        switch onboardingState {
        case .opening(let active), .terminalOpen(let active):
            return active == subscription
        case .idle, .signedIn, .cancelled, .failed:
            return false
        }
    }

    private var actionTitle: String {
        if isOnboardingThisProvider { return "WAITING…" }
        if row.connection?.isConnected == true { return "ADD" }
        if (row.connection?.disabledAccounts ?? 0) > 0 { return "RECONNECT" }
        return "CONNECT"
    }

    private func actionAccessibilityLabel(for subscription: OmpSubscription) -> String {
        if row.connection?.isConnected == true {
            return "Add another \(subscription.displayName) account with Oh My Pi"
        }
        if (row.connection?.disabledAccounts ?? 0) > 0 {
            return "Reconnect \(subscription.displayName) with Oh My Pi"
        }
        return "Connect \(subscription.displayName) with Oh My Pi"
    }
}

struct OmpBrowseProviderRow: View {
    let isOnboarding: Bool
    let onBrowse: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(isOnboarding: Bool, onBrowse: @escaping () -> Void) {
        self.isOnboarding = isOnboarding
        self.onBrowse = onBrowse
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                Text("More OMP providers")
                    .font(VoiceourTypography.body)
                    .foregroundStyle(isEnabled ? VoiceourPalette.Text.high : a11y.textLow)
                    .recordTextRole(
                        .body,
                        foreground: isEnabled ? VoiceourPalette.Text.high : a11y.textLow
                    )
                Text("Browse the complete sign-in catalog from your installed OMP.")
                    .font(VoiceourTypography.caption)
                    .foregroundStyle(a11y.textLow)
                    .recordTextRole(.caption, foreground: a11y.textLow)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: VoiceourMetrics.Space.sm)

            Button("BROWSE", action: onBrowse)
                .buttonStyle(GlassButtonStyle(kind: .ghost, isInFlight: isOnboarding))
                .disabled(isOnboarding)
                .accessibilityLabel("Browse all Oh My Pi sign-in providers")
                .accessibilityIdentifier("refinement.omp.connect.other")
        }
        .padding(.horizontal, VoiceourMetrics.Space.sm)
        .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Row.list, alignment: .leading)
    }
}
