import SwiftUI
import VoiceCore
import VoiceMac

/// General: the whole hotkey round-trip — the trigger, the hands-free stop, the
/// cleanup pass that runs before insertion, and what system audio does while a
/// capture is live. Plus, on a development launch only, which recogniser
/// transcribes.
///
/// CAPTURE owns the round-trip and AUDIO owns the one thing capture does to the
/// rest of the Mac. Auto-stop used to sit under a BACKEND heading, which made
/// that heading a lie for half its rows.
struct ConsoleGeneralTab: View {
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

    /// One source for the backend vocabulary, so the picker, the running readout
    /// and the restart notice can never disagree about a name.
    private static let backends: [(id: String, name: String)] =
        ASRBackendRegistry.builtIn.descriptors.map { ($0.id, $0.displayName) }

    /// The range `AutoStopDetector` is actually built with. Published in the
    /// caption instead of being silently applied after the fact.
    private static let silenceRange = 500...30_000

    /// Half a second per press: the smallest step a listener can feel between
    /// "it cut me off" and "it waited".
    private static let silenceStep = 500

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Form {
            Section("Capture") {
                triggerRow
                autoStopRow
                cleanupRow
            }

            Section("Audio") {
                muteRow
                cueRow
            }

            // One real backend ships, so a release build has nothing to choose
            // between: the picker exists to reach `fake` during development, and
            // a release user who found it could only downgrade their own
            // dictation to synthetic text. The running model is still stated on
            // the System tab.
            if LaunchOptions.showsDebugPanes {
                Section("Backend") {
                    backendRow
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: focusedField) { previous, current in
            if previous == .silence, current != .silence { commitSilence() }
        }
        .onDisappear {
            commitSilence()
        }
    }

    // MARK: Capture

    private var triggerRow: some View {
        ConsoleRow(
            caption: "Captured with the event tap fallback. Reassignment is reserved for a future release."
        ) {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Text("Fn or Globe")
                        .font(.body.monospaced())
                        .accessibilityLabel("Capture hotkey")
                        .accessibilityValue("Fn or Globe")
                        .accessibilityIdentifier("capture.hotkey")
                    ConsoleStateMark("STANDALONE TAP", .neutral)
                }
            } label: {
                Text("Trigger")
            }
        }
    }

    /// Switch and governed value stay in one row and are disabled together, so
    /// the tab can never read as "auto-stop is on at 2500 ms" while the switch
    /// above it is off.
    private var autoStopRow: some View {
        ConsoleRow(
            caption: "Ends a recording after \(Self.silenceRange.lowerBound)–\(Self.silenceRange.upperBound) ms "
                + "of silence, never before 3 s of capture."
        ) {
            Toggle("Stop after silence", isOn: settingBinding(coordinator, \.autoStopEnabled))
                .accessibilityIdentifier("voice.auto-stop.toggle")

            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    TextField(silencePlaceholder, text: silenceBinding)
                        .frame(width: VoiceourMetrics.Field.short)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focusedField, equals: .silence)
                        .onSubmit { commitSilence() }
                        .accessibilityLabel("Auto-stop silence, milliseconds")
                        .accessibilityIdentifier("voice.auto-stop.duration")

                    Text("ms")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Stepper(
                        "Auto-stop silence",
                        value: silenceStepBinding,
                        in: Self.silenceRange,
                        step: Self.silenceStep
                    )
                    .labelsHidden()
                    .accessibilityLabel("Step auto-stop silence")
                }
            } label: {
                Text("Auto-stop silence")
            }
            .disabled(!coordinator.settings.autoStopEnabled)
        }
    }

    private var cleanupRow: some View {
        ConsoleRow(caption: "Removes filler words and normalizes protected terms before insertion.") {
            Toggle("Clean up after capture", isOn: settingBinding(coordinator, \.cleanupEnabled))
                .accessibilityIdentifier("voice.cleanup.toggle")
        }
    }

    // MARK: Audio

    /// What system audio is doing right now, on the three-state ladder the
    /// System pane's mute row carried. It is a readout *of* the switch above it,
    /// so it rides that row rather than restating the setting as a fact of its
    /// own.
    ///
    /// UNAVAILABLE outranks MUTE ON because it is the same promise, refused. A
    /// device with neither a settable mute nor a settable volume — a DisplayPort
    /// monitor, measured — cannot be silenced at all, and a row that kept saying
    /// "will be muted" is exactly how that went unnoticed. The state is sticky
    /// until the next capture answers the question again.
    private var muteRow: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Toggle(
                "Mute system audio while recording",
                isOn: settingBinding(coordinator, \.muteSystemAudioDuringCapture)
            )
            .accessibilityIdentifier("voice.mute.toggle")

            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                ConsoleStateMark(muteReadout.label, muteReadout.severity)
                ConsoleCaption(muteReadout.detail)
            }

            if coordinator.state.isActive {
                ConsoleCaption("Applies from the next recording.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cueRow: some View {
        ConsoleRow(
            caption: "A rising tone when the microphone opens, a falling tone when it closes, and two "
                + "clipped falling tones when you discard the utterance. System audio fades out after "
                + "the rising tone rather than over it."
        ) {
            Toggle(
                "Play a sound when listening starts, stops or is discarded",
                isOn: settingBinding(coordinator, \.sessionSoundsEnabled)
            )
            .accessibilityIdentifier("voice.cues.toggle")
        }
    }

    private var muteReadout: (label: String, severity: ConsoleStateMark.Severity, detail: String) {
        if coordinator.isSystemAudioMuted {
            return (
                "MUTED NOW", .ok,
                "System audio is currently muted and will be restored when the session ends."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture, coordinator.isSystemAudioMuteUnavailable {
            return (
                "UNAVAILABLE", .warn,
                "The current output device offers no mute or volume control, so audio kept playing."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture {
            return (
                "MUTE ON", .neutral,
                "System audio fades out for the recording and fades back when the session ends."
            )
        } else {
            return ("MUTE OFF", .neutral, "System audio will continue playing while recording.")
        }
    }

    // MARK: Backend

    /// The picker states what is *saved*; the line under it states what is
    /// *running*. They are the same thing until the user changes the picker, at
    /// which point the mark turns amber and the restart action appears beside it
    /// — the user never has to quit and relaunch the app manually.
    private var backendRow: some View {
        ConsoleRow(caption: runningSummary) {
            Picker("ASR backend", selection: settingBinding(coordinator, \.asrBackend)) {
                ForEach(Self.backends, id: \.id) { backend in
                    Text(backend.name).tag(backend.id)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("voice.backend.picker")

            HStack(spacing: VoiceourMetrics.Space.sm) {
                ConsoleStateMark(
                    restartRequired ? "RESTART TO APPLY" : "IN USE",
                    restartRequired ? .warn : .neutral
                )

                if restartRequired && restartAvailable {
                    Button("Restart Voiceour") { restartApplication() }
                        .accessibilityLabel("Restart Voiceour to apply backend")
                        .accessibilityIdentifier("voice.backend.restart")
                }
            }
        }
    }

    private var restartRequired: Bool {
        coordinator.activeBackend != coordinator.settings.asrBackend
    }

    private var restartAvailable: Bool {
        !coordinator.state.isActive
    }

    private func restartApplication() {
        VoiceourAppDelegate.shared?.restartApplication()
    }

    /// What is transcribing right now: the model when the running backend is the
    /// saved one, and the running backend's own name when it is not. Both halves
    /// say "in use" so the mark and the line share one vocabulary.
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

    /// A stepper press is a decision about the *stored* value, so it discards any
    /// half-typed draft rather than leaving the field to re-commit a stale number
    /// on the next focus loss.
    private var silenceStepBinding: Binding<Int> {
        Binding(
            get: { coordinator.settings.autoStopSilenceMs },
            set: { value in
                silenceDraft = nil
                store(value)
            }
        )
    }

    private func commitSilence() {
        guard let draft = silenceDraft else { return }
        silenceDraft = nil
        guard let parsed = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        store(parsed)
    }

    private func store(_ milliseconds: Int) {
        let clamped = min(max(milliseconds, Self.silenceRange.lowerBound), Self.silenceRange.upperBound)
        guard clamped != coordinator.settings.autoStopSilenceMs else { return }
        coordinator.settings.autoStopSilenceMs = clamped
        coordinator.saveSettings()
    }
}
