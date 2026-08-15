import SwiftUI
import VoiceCore
import VoiceMac

/// Voice settings: which recogniser transcribes a capture, and how a capture
/// starts, ends, and is cleaned up.
///
/// Two cards, each an honest promise about the rows under it. BACKEND owns the
/// recogniser; CAPTURE owns the whole hotkey round-trip — the trigger, the
/// hands-free stop, and the cleanup pass that runs before insertion. Auto-stop
/// used to sit under BACKEND, which made that eyebrow a lie for half its card
/// and inflated it beyond its siblings.
///
/// Every row is one structure: a control band, then a footer of caption lines
/// at the value-column origin — the row primitive owns that gap now, so no row
/// here hand-rolls a `VStack` of control-plus-caption. A dependent control sits
/// on the same band as the switch that governs it and is disabled with it, so a
/// row can never read as "auto-stop is on at 2500 ms" while the switch beside
/// it is off.
struct VoicePane: View {
    var coordinator: DictationCoordinator

    private enum FocusTarget: Hashable {
        case silence
    }

    /// The free-text duration commits on submit or focus loss, not on every
    /// keystroke: a half-typed number could not be cleared because the setter
    /// dropped anything that was not an `Int`. `nil` means "no edit in flight",
    /// and the field renders the stored value.
    @State private var silenceDraft: String?
    @FocusState private var focusedField: FocusTarget?
    private var a11y = A11y()

    /// One source for the backend vocabulary, so the picker, the running
    /// readout and the restart notice can never disagree about a name.
    private static let backends: [(id: String, name: String)] =
        ASRBackendRegistry.builtIn.descriptors.map { ($0.id, $0.displayName) }

    /// The range `AutoStopDetector` is actually built with. Published in the
    /// caption instead of being silently applied after the fact.
    private static let silenceRange = 500...30_000

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        SettingsPaneScroll {
            SettingsSectionBlock(eyebrow: "BACKEND") {
                backendRow
            }

            SettingsSectionBlock(eyebrow: "CAPTURE") {
                triggerRow
                autoStopRow
                cleanupRow
            }
        }
        .onChange(of: focusedField) { previous, current in
            if previous == .silence, current != .silence { commitSilence() }
        }
        .onDisappear {
            commitSilence()
        }
    }

    // MARK: Backend

    /// The picker states what is *saved*; the line under it states what is
    /// *running*. They are the same thing until the user changes the picker,
    /// at which point the chip turns amber and becomes the one-click restart
    /// action — the user never has to quit and relaunch the app manually.
    private var backendRow: some View {
        let saved = settingBinding(coordinator, \.asrBackend)

        return SettingsRow(
            label: "ASR backend",
            status: (
                label: restartRequired ? "RESTART TO APPLY" : "IN USE",
                mode: restartRequired ? .warn : .neutral
            ),
            statusAction: restartRequired && restartAvailable ? { restartApplication() } : nil,
            statusActionAccessibilityLabel: "Restart Voiceour to apply backend",
            statusActionAccessibilityIdentifier: "voice.backend.restart"
        ) {
            // Both registered backends fit one row of the control band beside either
            // the IN USE mark or the wider RESTART TO APPLY one.
            SegmentGroup(rows: 2) {
                ForEach(Self.backends, id: \.id) { backend in
                    SegmentOption(
                        label: backend.name,
                        isSelected: saved.wrappedValue == backend.id
                    ) {
                        saved.wrappedValue = backend.id
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("ASR backend")
        } footer: {
            // One mark, not prose: the mono line names the model actually
            // loaded. The deferral state is the row's own status mark, on the
            // trailing rail with every other chip in the console, so this
            // footer no longer hand-rolls a chip-plus-line band of its own.
            Text(runningSummary)
                .roleStyle(.bodyMono)
                .lineLimit(1)
        }
        .animation(
            a11y.reduceMotion ? nil : VoiceourMotion.quick,
            value: coordinator.settings.asrBackend
        )
    }

    // MARK: Capture

    private var triggerRow: some View {
        SettingsRow(label: "Trigger", status: (label: "STANDALONE TAP", mode: .neutral)) {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                KeyCap("Fn")
                Text("or").roleStyle(.caption)
                KeyCap("Globe")
            }
        } footer: {
            CaptionText("Captured with the event tap fallback. Reassignment is reserved for a future release.")
        }
    }

    /// Switch and governed value share one band: the switch used to sit ~500 pt
    /// from the field it governs and ~700 pt from the designator that names it.
    private var autoStopRow: some View {
        SettingsRow(label: "Auto-stop") {
            HStack(spacing: VoiceourMetrics.Space.md) {
                Toggle("Stop after silence", isOn: settingBinding(coordinator, \.autoStopEnabled))
                    .compactGlassToggle()

                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.xs) {
                    TextField(silencePlaceholder, text: silenceBinding)
                        .textFieldStyle(GlassTextFieldStyle(font: VoiceourTypography.bodyMono))
                        .frame(width: VoiceourMetrics.Field.short)
                        .focused($focusedField, equals: .silence)
                        .onSubmit { commitSilence() }
                        .accessibilityLabel("Auto-stop silence, milliseconds")

                    // The unit is a mark on the value, so it follows the
                    // console's metric-unit voice rather than caption prose.
                    Text("ms")
                        .font(VoiceourTypography.micro)
                        .foregroundStyle(
                            coordinator.settings.autoStopEnabled ? a11y.textMid : a11y.textLow
                        )
                }
                .disabled(!coordinator.settings.autoStopEnabled)
            }
        } footer: {
            CaptionText(
                "Ends a recording after \(Self.silenceRange.lowerBound)–\(Self.silenceRange.upperBound) ms "
                    + "of silence, never before 3 s of capture."
            )
        }
    }

    private var cleanupRow: some View {
        SettingsRow(label: "Transcript cleanup") {
            Toggle("Clean up after capture", isOn: settingBinding(coordinator, \.cleanupEnabled))
                .compactGlassToggle()
        } footer: {
            CaptionText("Removes filler words and normalizes protected terms before insertion.")
        }
    }

    // MARK: Backend readout

    private var restartRequired: Bool {
        coordinator.activeBackend != coordinator.settings.asrBackend
    }

    private var restartAvailable: Bool {
        !coordinator.state.isActive
    }

    private func restartApplication() {
        VoiceourAppDelegate.shared?.restartApplication()
    }

    /// What is transcribing right now: the model when the running backend is
    /// the saved one, and the running backend's own name when it is not. Both
    /// halves say "in use" so the chip and the line share one vocabulary.
    private var runningSummary: String {
        restartRequired
            ? "\(Self.displayName(coordinator.activeBackend)) IN USE"
            : Self.modelSummary(for: coordinator.activeBackend)
    }

    private static func displayName(_ backend: String) -> String {
        backends.first { $0.id == backend }?.name ?? backend.uppercased()
    }

    /// The fake backend synthesises text and loads nothing; printing the pinned
    /// Parakeet contract for it asserted a model that would never be used. The
    /// registry owns the per-backend wording, including for an id it does not
    /// know: an unregistered backend resolves to the same default the registry
    /// would actually build, rather than to whichever model was hardcoded here.
    private static func modelSummary(for backend: String) -> String {
        let registry = ASRBackendRegistry.builtIn
        return (registry.descriptor(for: backend) ?? registry.defaultDescriptor).modelLabel
    }

    // MARK: Silence editing

    private var silencePlaceholder: String {
        "\(Self.silenceRange.lowerBound)–\(Self.silenceRange.upperBound)"
    }

    private var silenceBinding: Binding<String> {
        Binding(
            get: { silenceDraft ?? String(coordinator.settings.autoStopSilenceMs) },
            set: { silenceDraft = $0 }
        )
    }

    private func commitSilence() {
        guard let draft = silenceDraft else { return }
        silenceDraft = nil
        guard let parsed = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let clamped = min(max(parsed, Self.silenceRange.lowerBound), Self.silenceRange.upperBound)
        guard clamped != coordinator.settings.autoStopSilenceMs else { return }
        coordinator.settings.autoStopSilenceMs = clamped
        coordinator.saveSettings()
    }
}
