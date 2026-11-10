import SwiftUI
import VoiceCore

/// Settings ▸ Dictation: the round trip — the trigger, the hands-free stop, and
/// the cleanup pass before insertion.
struct SettingsDictationPage: View {
    private let coordinator: DictationCoordinator

    private enum FocusTarget: Hashable {
        case silence
    }

    /// The free-text duration commits on submit or focus loss, not on every
    /// keystroke: a half-typed number could not be cleared because the setter
    /// dropped anything that was not an `Int`. `nil` means "no edit in flight",
    /// and the field renders the stored value.
    @State private var silenceDraft: String?
    @FocusState private var focusedField: FocusTarget?

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
        SettingsPage(.dictation) {
            SettingsIsland {
                triggerRow
                Kit.Rule()
                autoStopRows
                Kit.Rule()
                cleanupRow
            }
        }
        .onChange(of: focusedField) { previous, current in
            if previous == .silence, current != .silence { commitSilence() }
        }
        // Leaving the page, or the tab, is a focus loss the field never reports.
        .onDisappear { commitSilence() }
    }

    private var triggerRow: some View {
        Kit.SettingRow(
            "Trigger",
            caption: "Captured with the event tap fallback. Reassignment is reserved for a future release."
        ) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Text("Fn or Globe")
                    .font(.body.monospaced())
                    .accessibilityLabel("Capture hotkey")
                    .accessibilityValue("Fn or Globe")
                    .accessibilityIdentifier("capture.hotkey")
                Kit.Mark("STANDALONE TAP")
            }
        }
    }

    /// Switch and governed value stay together and are disabled together, so the
    /// page can never read as "auto-stop is on at 2500 ms" while the switch above
    /// it is off.
    private var autoStopRows: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            Kit.SettingRow("Stop after silence") {
                Toggle("Stop after silence", isOn: settingBinding(coordinator, \.autoStopEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("voice.auto-stop.toggle")
            }

            Kit.SettingRow(
                "Auto-stop silence",
                caption: "Ends a recording after \(Self.silenceRange.lowerBound)–\(Self.silenceRange.upperBound) ms "
                    + "of silence, never before 3 s of capture."
            ) {
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
                .disabled(!coordinator.settings.autoStopEnabled)
            }
        }
    }

    private var cleanupRow: some View {
        Kit.SettingRow(
            "Clean up after capture",
            caption: "Removes filler words and normalizes protected terms before insertion."
        ) {
            Toggle("Clean up after capture", isOn: settingBinding(coordinator, \.cleanupEnabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("voice.cleanup.toggle")
        }
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
