import SwiftUI
import VoiceMac

struct OmpConnectionsRow: View {
    let connections: [OmpProviderConnection]
    let statusState: OmpProviderStatusState
    let onboardingState: OmpOnboardingState
    let selectedProviderID: String?
    let onboardingDetail: (text: String, isFailure: Bool)?
    let onRefresh: () -> Void
    let onConnect: (OmpSubscription) -> Void

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(
        connections: [OmpProviderConnection],
        statusState: OmpProviderStatusState,
        onboardingState: OmpOnboardingState,
        selectedProviderID: String?,
        onboardingDetail: (text: String, isFailure: Bool)?,
        onRefresh: @escaping () -> Void,
        onConnect: @escaping (OmpSubscription) -> Void
    ) {
        self.connections = connections
        self.statusState = statusState
        self.onboardingState = onboardingState
        self.selectedProviderID = selectedProviderID
        self.onboardingDetail = onboardingDetail
        self.onRefresh = onRefresh
        self.onConnect = onConnect
    }

    var body: some View {
        let rows = providerRows
        let connected = rows.filter { $0.connection?.isConnected == true }
        let needsAttention = rows.filter {
            $0.connection?.isConnected != true && ($0.connection?.disabledAccounts ?? 0) > 0
        }
        let available = rows.filter {
            $0.subscription != nil
                && $0.connection?.isConnected != true
                && ($0.connection?.disabledAccounts ?? 0) == 0
        }

        HStack(alignment: .top, spacing: VoiceourMetrics.Space.xl) {
            Text("Connections")
                .font(VoiceourTypography.label)
                .foregroundStyle(isEnabled ? VoiceourPalette.Text.high : a11y.textLow)
                .recordTextRole(
                    .label,
                    foreground: isEnabled ? VoiceourPalette.Text.high : a11y.textLow
                )
                .frame(width: VoiceourMetrics.Column.settingsLabel, alignment: .leading)

            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    StatusChip(
                        label: summaryStatus.label,
                        mode: summaryStatus.mode,
                        size: .compact
                    )

                    Spacer(minLength: VoiceourMetrics.Space.sm)

                    Button(
                        statusState.isChecking ? "REFRESHING…" : "REFRESH",
                        action: onRefresh
                    )
                    .buttonStyle(
                        GlassButtonStyle(kind: .ghost, isInFlight: statusState.isChecking)
                    )
                    .disabled(statusState.isChecking)
                    .accessibilityLabel("Refresh Oh My Pi account status")
                    .accessibilityIdentifier("refinement.omp.refresh")
                }
                .frame(minHeight: VoiceourMetrics.Control.medium)

                VStack(alignment: .leading, spacing: 0) {
                    if !connected.isEmpty {
                        providerGroup("CONNECTED", rows: connected)
                    }
                    if !needsAttention.isEmpty {
                        if !connected.isEmpty { HairlineDivider() }
                        providerGroup("NEEDS ATTENTION", rows: needsAttention)
                    }
                    if !available.isEmpty {
                        if !connected.isEmpty || !needsAttention.isEmpty { HairlineDivider() }
                        providerGroup("AVAILABLE TO CONNECT", rows: available)
                    }
                    if !rows.isEmpty { HairlineDivider() }
                    OmpBrowseProviderRow(
                        isOnboarding: onboardingState.isInFlight,
                        onBrowse: { onConnect(.other) }
                    )
                }
                .plateSurface(kind: .well, cornerRadius: VoiceourMetrics.Radius.row)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Oh My Pi provider connections")

                if let onboardingDetail {
                    CaptionText(
                        onboardingDetail.text,
                        color: onboardingDetail.isFailure
                            ? VoiceourPalette.Signal.crimson
                            : a11y.textMid
                    )
                }
                if case .failed(let detail) = statusState {
                    CaptionText(detail, color: VoiceourPalette.Signal.crimson)
                }
                CaptionText(
                    "Status comes from OMP's redacted account inventory. "
                        + "Connect opens OMP's own sign-in in Terminal; Voiceour never reads "
                        + "or stores the credentials."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, VoiceourMetrics.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .anchorPreference(key: SettingsRowBoundsPreferenceKey.self, value: .bounds) { [$0] }
        .settingsContentLead(VoiceourMetrics.Space.sm)
    }

    private var providerRows: [OmpConnectionRowModel] {
        var knownProviderIDs = Set<String>()
        let known = OmpSubscription.allCases.compactMap { subscription -> OmpConnectionRowModel? in
            guard let providerID = subscription.providerID else { return nil }
            knownProviderIDs.insert(providerID)
            return OmpConnectionRowModel(
                providerID: providerID,
                displayName: subscription.displayName,
                connection: connections.first { $0.providerID == providerID },
                subscription: subscription
            )
        }
        let extras =
            connections
            .filter { !knownProviderIDs.contains($0.providerID) }
            .map {
                OmpConnectionRowModel(
                    providerID: $0.providerID,
                    displayName: $0.displayName,
                    connection: $0,
                    subscription: nil
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        return known + extras
    }

    private var summaryStatus: (label: String, mode: StatusChip.Mode) {
        let connectedCount = connections.reduce(0) { $0 + ($1.isConnected ? 1 : 0) }
        let accountCount = connections.reduce(0) { $0 + $1.activeAccounts }
        switch statusState {
        case .idle:
            return ("NOT CHECKED", .neutral)
        case .checking:
            return ("CHECKING…", .neutral)
        case .loaded:
            if connectedCount == 0 { return ("NO ACCOUNTS", .neutral) }
            let accountLabel = accountCount == 1 ? "ACCOUNT" : "ACCOUNTS"
            return ("\(connectedCount) PROVIDERS · \(accountCount) \(accountLabel)", .ok)
        case .failed:
            return connections.isEmpty ? ("STATUS UNKNOWN", .warn) : ("STATUS STALE", .warn)
        }
    }

    @ViewBuilder
    private func providerGroup(_ title: String, rows: [OmpConnectionRowModel]) -> some View {
        Text(title)
            .font(VoiceourTypography.micro)
            .tracking(TextRole.micro.tracking)
            .foregroundStyle(a11y.textLow)
            .recordTextRole(.micro, foreground: a11y.textLow)
            .padding(.horizontal, VoiceourMetrics.Space.sm)
            .padding(.top, VoiceourMetrics.Space.sm)
            .padding(.bottom, VoiceourMetrics.Space.xs)

        ForEach(rows) { row in
            if row.id != rows.first?.id { HairlineDivider() }
            OmpProviderConnectionRow(
                row: row,
                statusState: statusState,
                onboardingState: onboardingState,
                isInUse: selectedProviderID == row.providerID,
                onConnect: onConnect
            )
        }
    }
}
