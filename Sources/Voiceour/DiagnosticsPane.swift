import SwiftUI
import VoiceCore
import VoiceMac

/// Diagnostics as one property sheet.
///
/// A debug pane (`ConsolePaneRailPlacement.debug`): storage paths, a model id,
/// probe evidence and a CLI command are facts about the install, not about the
/// app a user bought, so the rail hides this pane unless it was launched with
/// `--debug` or Diagnostics is already open. The two destructive actions that
/// used to live at the bottom of it are user-facing, not machine-facing, so
/// they moved to System's DANGER section rather than going behind the flag.
///
/// Every fact here is a designator and a value, so the pane is rows on the
/// console's shared settings grid rather than tiles on a bespoke four-column
/// measure. The measure is what broke: a 421pt model id sat alone in 940pt
/// while SAVED BACKEND and ACTIVE BACKEND — the one pair on the pane that
/// exists to be compared — rendered at 200pt and 728pt holding the same string.
/// A property row gives every value the same origin for free, and prominence
/// drops to what it always meant here: a `StatusChip` mode, never a 32pt
/// numeral face.
///
/// The clusters collapsed with the measure. Version and build were two tiles
/// reporting one release; backend status, cache, offline load and model-loaded
/// were four tiles reporting one probe, and OFFLINE LOAD only restated CACHE in
/// different words. Saved and active backend are one row that says nothing
/// unless they differ, which is the only diagnostic content the pair ever had.
/// PERMISSIONS & AUDIO is gone outright: System owns every capability, and it
/// is the only pane that can offer remediation for one.
struct DiagnosticsPane: View {
    var coordinator: DictationCoordinator

    private static let selfTestCommand = "Voiceour --self-test"

    var body: some View {
        SettingsPaneScroll {
            applicationSection
            backendSection
            storageSection
            selfTestSection
        }
        .scrollEdge(.soft, for: .bottom)
        .onAppear {
            coordinator.refreshBackendHealth()
        }
    }

    // MARK: APPLICATION

    /// A build number is a qualifier on a version, never an independent fact,
    /// so it is parenthetical to the value it qualifies instead of a second
    /// row with its own label column.
    private var applicationSection: some View {
        SettingsSectionBlock(eyebrow: "APPLICATION") {
            PropertyRow("Version", value: "\(appVersion) (build \(appBuild))")

            PropertyRow("Saved sessions", value: "\(coordinator.recentSessions.count)")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "local"
    }

    // MARK: BACKEND

    /// Four facts about one speech backend: which one is running, what its last
    /// probe found, which model that resolves to, and whether the probe itself
    /// answered.
    private var backendSection: some View {
        SettingsSectionBlock(eyebrow: "BACKEND") {
            PropertyRow(
                "Backend",
                value: backendValue,
                accessories: hasBackendDrift ? [.status("DRIFT", .warn)] : []
            )

            PropertyRow(
                "Status",
                value: backendEvidence,
                accessories: [backendStatusAccessory]
            )

            PropertyRow(
                "Model",
                value: modelIdentifier,
                valueStyle: .mono,
                accessories: [
                    .copy(
                        payload: modelIdentifier,
                        label: "Copy the model identifier",
                        identifier: "copy.model"
                    )
                ]
            )

            // The chip carries the outcome and the caption carries the
            // evidence, so a probe that has not answered yet still reads
            // differently from one that failed — a distinction the four
            // `UNKNOWN` tiles this row replaces could not express.
            PropertyRow(
                "Health probe",
                caption: healthProbeCaption,
                accessories: healthProbeAccessories
            )
        }
    }

    // MARK: STORAGE

    /// Machine paths in the mono face, middle-truncated, each with the copy
    /// action that is the only reason to read a storage path off a screen.
    private var storageSection: some View {
        SettingsSectionBlock(eyebrow: "STORAGE") {
            PropertyRow(
                "Settings",
                value: settingsPath,
                valueStyle: .mono,
                accessories: [
                    // The label and identifier are the pair the harness and
                    // every committed golden already address this button by;
                    // they outlive the `SETTINGS PATH` eyebrow that generated
                    // them.
                    .copy(
                        payload: settingsPath,
                        label: "Copy SETTINGS PATH",
                        identifier: "copy.settings-path"
                    )
                ]
            )

            PropertyRow(
                "Recent sessions",
                value: recentSessionsPath,
                valueStyle: .mono,
                accessories: [
                    .copy(
                        payload: recentSessionsPath,
                        label: "Copy RECENT SESSIONS PATH",
                        identifier: "copy.recent-sessions-path"
                    )
                ]
            )
        }
    }

    /// Pinned under the offscreen UI harness so a committed fixture never
    /// contains the developer's home directory.
    private var settingsPath: String {
        RenderOverrides.settingsPath ?? SettingsStore.defaultURL.path
    }

    private var recentSessionsPath: String {
        RenderOverrides.recentSessionsPath ?? RecentSessionStore.defaultURL.path
    }

    // MARK: SELF-TEST

    /// The command in the mono face every other machine string on the pane
    /// uses, with a copy action. It used to be a sentence in the 12pt prose
    /// face with markdown backticks rendered as literal punctuation, next to a
    /// `LOCAL` chip that repeated the cluster header and said nothing about a
    /// command.
    private var selfTestSection: some View {
        SettingsSectionBlock(eyebrow: "SELF-TEST") {
            PropertyRow(
                "Self-test",
                value: Self.selfTestCommand,
                valueStyle: .mono,
                caption: "Runs the lightweight cleanup and safety classifier check from the app bundle.",
                accessories: [
                    .copy(
                        payload: Self.selfTestCommand,
                        label: "Copy the self-test command",
                        identifier: "copy.selfTest"
                    )
                ]
            )
        }
    }

    // MARK: Backend facts

    private var hasBackendDrift: Bool {
        coordinator.settings.asrBackend != coordinator.activeBackend
    }

    /// One row for the saved/active pair. The only diagnostic content the two
    /// ever carried is whether they differ — the symptom of a backend switch
    /// that did not take — so agreement prints one name and disagreement prints
    /// the transition, next to the chip that names it.
    private var backendValue: String {
        let saved = coordinator.settings.asrBackend.uppercased()
        guard hasBackendDrift else { return saved }
        return "\(saved) → \(coordinator.activeBackend.uppercased())"
    }

    /// The model the running backend loads, with the revision it is pinned to.
    /// Backends without pinned model metadata fall back to their descriptor's
    /// own label rather than borrowing another backend's model id.
    private var modelIdentifier: String {
        guard let descriptor = ASRBackendRegistry.builtIn.descriptor(for: coordinator.activeBackend) else {
            return coordinator.activeBackend
        }
        guard let modelId = descriptor.modelId else { return descriptor.modelLabel }
        guard let revision = descriptor.modelRevision else { return modelId }
        return "\(modelId)@\(revision)"
    }

    /// What the chip's verdict is made of. Cache and model residency were two
    /// tiles each announcing a bare `OK`/`YES` under a kerned eyebrow; as the
    /// status row's own value they read as the evidence they are. A probe that
    /// has not answered leaves both unknown rather than false — the difference
    /// between "the cache is missing" and "nobody has looked" is the whole
    /// content of this row on a cold start.
    private var backendEvidence: String {
        let health = coordinator.backendHealth
        let cache = health.map { $0.cacheOk ? "cache OK" : "cache missing" } ?? "cache unknown"
        let model = health.map { $0.modelLoaded ? "model loaded" : "model not loaded" } ?? "model unknown"
        return "\(cache) · \(model)"
    }

    /// A missing model is a recoverable gap — download it and dictation works.
    /// An unavailable backend is not: nothing transcribes until it comes back,
    /// which is a hard failure and reads as one.
    private var backendStatusAccessory: PropertyAccessory {
        switch coordinator.backendHealth?.backendStatus {
        case .ready:
            .status("READY", .ok)
        case .modelMissing:
            .status("MODEL MISSING", .warn)
        case .backendUnavailable:
            .status("BACKEND UNAVAILABLE", .crit)
        case nil:
            .status("UNKNOWN", .neutral)
        }
    }

    private var healthProbeAccessories: [PropertyAccessory] {
        var accessories: [PropertyAccessory] = [healthProbeAccessory]
        if let payload = coordinator.backendHealthError {
            // The copy action carries the untouched `String(describing:)`
            // dump, which is the form a bug report wants, and only exists
            // when there is a dump to carry.
            accessories.append(
                .copy(
                    payload: payload,
                    label: "Copy the backend health report",
                    identifier: "copy.backendHealth"
                )
            )
        }
        return accessories
    }

    private var healthProbeCaption: String {
        if let payload = coordinator.backendHealthError {
            return Self.sentence(in: payload)
        }
        return coordinator.backendHealth == nil
            ? "No health probe has answered yet."
            : "The speech backend answered its health probe."
    }

    private var healthProbeAccessory: PropertyAccessory {
        if coordinator.backendHealthError != nil {
            return .status("ERROR", .crit)
        }
        return coordinator.backendHealth == nil ? .status("NOT PROBED", .neutral) : .status("ALL CLEAR", .ok)
    }

    /// The human sentence inside the health payload.
    ///
    /// `backendHealthError` is published as `String(describing:)`, so by the
    /// time it reaches a view the structure is gone. Every error the sidecar
    /// itself raises is an `ASRErrorMessage`, which carries its one written
    /// sentence in `detail`; this lifts that field back out. Anything else — a
    /// launch failure, a decode error — has no such field and is shown whole,
    /// because then the dump is the only message there is.
    private static func sentence(in payload: String) -> String {
        guard let start = payload.range(of: "detail: Optional(\"")?.upperBound else {
            return payload
        }
        var sentence = ""
        var index = start
        while index < payload.endIndex {
            let character = payload[index]
            index = payload.index(after: index)
            switch character {
            case "\"":
                return sentence
            case "\\" where index < payload.endIndex:
                sentence.append(payload[index])
                index = payload.index(after: index)
            default:
                sentence.append(character)
            }
        }
        return payload
    }
}
