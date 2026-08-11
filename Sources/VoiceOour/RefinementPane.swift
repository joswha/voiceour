import SwiftUI
import VoiceCore
import VoiceMac

/// The one pane that decides whether dictated text leaves this Mac, so it says
/// where the text goes before it says anything else, and it keeps that decision
/// reachable: the opt-in section is always live and everything it governs sits
/// in a single `DependentGroup` beneath it, because one `.disabled` over the
/// whole pane would disable the switch that turns the pane back on.
///
/// The dependent half is four ordinary sections — PROVIDER, CREDENTIALS,
/// REQUEST, CONNECTION — rather than one card with a nested disabled `VStack`.
/// A nested stack made every dependent row a child of a row-shaped container it
/// was not, and it left the group with no name of its own; the group is now a
/// single contained accessibility region that announces active or inactive once
/// instead of leaving VoiceOver to infer it from nine dimmed controls.
///
/// Row anatomy is the ledger grammar: designator, control band, then a footer
/// of `CaptionText` lines at the value-column origin, and a trailing status chip
/// on the control line. Nothing in this pane hand-rolls a chip-then-caption
/// `HStack` any more — that composition indented prose to wherever the chip
/// happened to end, which moved with the chip's label.
struct RefinementPane: View {
    var coordinator: DictationCoordinator

    /// `nil` while the field mirrors the persisted value, a draft while the user
    /// is mid-edit — so backspacing over 3000 never persists 300, 30 and 3 on the
    /// way past, and an unparseable entry reverts instead of sticking.
    @State private var timeoutDraft: String?
    /// The Model picker's search text. Pane-owned so switching provider clears
    /// a filter the user typed against a list that is no longer on screen.
    @State private var modelFilter = ""
    /// The configuration the last probe actually ran against. A verdict that
    /// predates the provider or model it measured is not a verdict.
    @State private var checkedFingerprint: String?
    @FocusState private var timeoutFocused: Bool
    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        let provider = coordinator.settings.refinerProvider
        let isEnabled = coordinator.settings.refinerEnabled

        SettingsPaneScroll {
            RefinementOptInSection(
                coordinator: coordinator,
                provider: provider,
                statusMode: statusMode
            )

            DependentGroup(isEnabled: isEnabled, label: "Refiner configuration") {
                RefinementProviderSection(
                    coordinator: coordinator,
                    provider: provider,
                    modelFilter: $modelFilter,
                    startOmpSignIn: startOmpSignIn
                )

                RefinementRequestSection(
                    coordinator: coordinator,
                    provider: provider,
                    timeoutDraft: $timeoutDraft,
                    timeoutFocused: $timeoutFocused
                )

                RefinementConnectionSection(
                    provider: provider,
                    displayedReachability: displayedReachability,
                    statusMode: statusMode,
                    runReachabilityCheck: runReachabilityCheck
                )
            }
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.deliberate, value: isEnabled)
        }
        .animation(a11y.reduceMotion ? nil : VoiceOourMotion.standard, value: provider)
        .onChange(of: provider) { _, _ in
            modelFilter = ""
        }
        .task(id: provider) {
            guard provider == .omp else { return }
            // Two independent `omp` subprocesses. Awaiting them in sequence made
            // the Model picker sit at NOT LOADED until the account inventory
            // came back, which is a second of nothing for no reason.
            async let statuses: Void = {
                guard RenderOverrides.ompProviderStatusState == nil else { return }
                _ = await coordinator.refreshOmpProviderStatuses()
            }()
            // The picker has nothing to offer until OMP has been asked, and
            // asking is a subprocess, so it happens on pane entry rather than
            // behind a button the user has no reason to press first.
            async let models: Void = {
                guard RenderOverrides.ompModelCatalogState == nil else { return }
                _ = await coordinator.refreshOmpModelCatalog()
            }()
            _ = await (statuses, models)
        }
    }

    // MARK: - Actions

    private func startOmpSignIn(_ subscription: OmpSubscription) async {
        checkedFingerprint = nil
        guard await coordinator.startOmpOnboarding(subscription) else { return }
        checkedFingerprint = configurationFingerprint
    }

    /// A probe is a verdict about the configuration it measured, and two things
    /// can invalidate it mid-flight: the coordinator refuses to commit a result
    /// that a newer check or a settings change has already superseded, and the
    /// user can move a field this pane fingerprints but the probe never saw.
    /// Only when neither happened does the configuration become checked.
    /// Otherwise the stamp goes — whatever the coordinator publishes now is not
    /// this configuration's verdict, and the stamp is what would license the
    /// Status row to show it as one.
    private func runReachabilityCheck() async {
        let fingerprint = configurationFingerprint
        let committed = await coordinator.checkRefinerReachability()
        guard configurationFingerprint == fingerprint else {
            checkedFingerprint = nil
            return
        }
        guard committed else { return }
        checkedFingerprint = fingerprint
    }

    // MARK: - Derived state

    /// Provider and model together decide what a probe measures; change either
    /// and the stored verdict describes a configuration that no longer exists.
    private var configurationFingerprint: String {
        let settings = coordinator.settings
        return "\(settings.refinerProvider.rawValue)|\(RefinerResolved.model(settings))"
    }

    /// The verdict the Status row reports.
    ///
    /// The harness override stands in for an entire probe-and-stamp cycle: a
    /// real check spawns `omp` or asks this Mac whether Apple Intelligence is
    /// on, and a golden may depend on neither. It is nil outside the harness,
    /// exactly like `RenderOverrides.permissions`.
    private var displayedReachability: RefinerReachability {
        if let pinned = RenderOverrides.refinerReachability {
            return pinned
        }
        return Self.statusVerdict(
            measured: coordinator.refinerReachability,
            checkedFingerprint: checkedFingerprint,
            configurationFingerprint: configurationFingerprint
        )
    }

    /// A refusal outranks the stamp; a green verdict does not.
    ///
    /// The coordinator publishes `.failed` from a real refine as well as from
    /// CHECK, guards it against its own refiner identity and generation, and
    /// resets the slot itself the moment the provider, model or timeout moves.
    /// It is therefore a current fact about the configuration on screen, and
    /// hiding it behind a probe the user never ran would suppress the single
    /// answer this row exists to give — the paste that just fell back to
    /// deterministic cleanup because OMP could not run. `.ok` keeps the gate:
    /// nothing but a probe produces it, and it is only as good as the
    /// configuration it measured.
    ///
    /// Static and pure because a `View`'s private state is not reachable from a
    /// test, and this rule is no longer obvious enough to leave unpinned.
    static func statusVerdict(
        measured: RefinerReachability,
        checkedFingerprint: String?,
        configurationFingerprint: String
    ) -> RefinerReachability {
        switch measured {
        case .checking, .failed:
            measured
        case .unknown:
            .unknown
        case .ok:
            checkedFingerprint == configurationFingerprint ? measured : .unknown
        }
    }

    /// While the refiner is off, every dependent status is the expected state
    /// rather than a problem: the pane stops spending its warning colour on a
    /// feature the user deliberately switched off. The dependent group's own
    /// disabled tone recedes the chip's fill; this recedes its *meaning*, which
    /// no environment value can infer.
    private func statusMode(_ mode: StatusChip.Mode) -> StatusChip.Mode {
        coordinator.settings.refinerEnabled ? mode : .neutral
    }

}
