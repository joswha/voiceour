import SwiftUI
import VoiceCore
import VoiceMac

struct RefinementProviderSection: View {
    var coordinator: DictationCoordinator
    let provider: RefinerProvider
    @Binding var modelFilter: String
    let startOmpSignIn: (OmpSubscription) async -> Void

    var body: some View {
        SettingsSectionBlock(eyebrow: "PROVIDER") {
            providerRow()

            switch provider {
            case .appleOnDevice:
                onDeviceRow()
            case .omp:
                ompConnectionsRow()
                modelRow()
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

    /// A valueless fact row: there is nothing to configure, only something to
    /// know. The on-device model has no endpoint, no credential and no model
    /// id, so it has no picker either.
    private func onDeviceRow() -> some View {
        PropertyRow(
            "On-device",
            caption:
                "Apple Intelligence runs the model in process — no endpoint and no API key to "
                + "configure. \(foundationModelsDetail)."
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
            selectedProviderID: selectedProviderID,
            onboardingDetail: ompOnboardingDetail(displayedOmpOnboardingState),
            onRefresh: {
                Task {
                    // Independent probes; the picker must not wait on the
                    // account inventory to repopulate.
                    async let statuses = coordinator.refreshOmpProviderStatuses()
                    async let models = coordinator.refreshOmpModelCatalog()
                    _ = await (statuses, models)
                }
            },
            onConnect: { subscription in
                Task { await startOmpSignIn(subscription) }
            }
        )
    }

    /// The model is chosen from OMP's own catalog rather than typed. See
    /// `OmpModelPickerRow` for why the list is bounded and grouped the way it is.
    private func modelRow() -> some View {
        OmpModelPickerRow(
            models: displayedOmpModels,
            catalogState: displayedOmpModelCatalogState,
            connectedProviderIDs: Set(
                displayedOmpProviderConnections.filter(\.isConnected).map(\.providerID)
            ),
            resolvedModel: RefinerResolved.model(coordinator.settings),
            isDefaulted: coordinator.settings.refinerModel.isEmpty,
            defaultModel: provider.defaultModel,
            filter: $modelFilter,
            onRefresh: { Task { await coordinator.refreshOmpModelCatalog() } },
            onSelect: { coordinator.selectRefinerModel($0) }
        )
    }

    // MARK: - Derived state

    /// Which connection row wears IN USE: the provider half of the selector the
    /// refiner would use right now.
    private var selectedProviderID: String? {
        RefinerResolved.model(coordinator.settings)
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init)
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

    private var displayedOmpModels: [OmpAvailableModel] {
        RenderOverrides.ompModels ?? coordinator.ompModels
    }

    private var displayedOmpModelCatalogState: OmpModelCatalogState {
        RenderOverrides.ompModelCatalogState ?? coordinator.ompModelCatalogState
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
}

/// Two destinations, so one row of two segments. This was a wrapped two-row
/// group of six when VoiceOour spoke to four cloud vendors itself.
private struct RefinerProviderPicker: View {
    @Binding var selection: RefinerProvider

    var body: some View {
        SegmentGroup {
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
