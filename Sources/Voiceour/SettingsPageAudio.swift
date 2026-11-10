import SwiftUI
import VoiceCore
import VoiceMac

/// Settings ▸ Audio: the sound hardware around a capture — which microphone
/// records, the one thing capture does to the rest of the Mac, and the cues.
struct SettingsAudioPage: View {
    private let coordinator: DictationCoordinator
    /// The tab's enumeration, refreshed on appear and whenever the app returns to
    /// the front.
    private let availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone]

    init(coordinator: DictationCoordinator, availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone]) {
        self.coordinator = coordinator
        self.availableMicrophones = availableMicrophones
    }

    var body: some View {
        SettingsPage(.audio) {
            SettingsIsland {
                microphoneRow
                Kit.Rule()
                muteRow
                Kit.Rule()
                cueRow
            }
        }
    }

    /// The severities this page reports, for the sidebar item's attention: the
    /// mute readout's, and a warning while the saved microphone is missing.
    static func severities(
        _ coordinator: DictationCoordinator,
        availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone]
    ) -> [ConsoleReadout.Severity] {
        let missing = isMissing(coordinator, availableMicrophones: availableMicrophones)
        return [muteReadout(coordinator).severity] + (missing ? [.warn] : [])
    }

    // MARK: Microphone

    /// The picker states what is *saved*: a durable device UID, or nil for
    /// Automatic. An unplugged selection stays on the menu under its persisted
    /// name with a NOT CONNECTED mark, because silently snapping the control back
    /// to Automatic would misreport what the next recording will try first.
    private var microphoneRow: some View {
        let missing = Self.isMissing(coordinator, availableMicrophones: availableMicrophones)
        return VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Kit.SettingRow("Microphone", caption: microphoneCaption(missing: missing)) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if missing {
                        Kit.Mark("NOT CONNECTED", tone: .caution)
                    }
                    Picker("Microphone", selection: microphoneBinding) {
                        Text("Automatic").tag(String?.none)
                        ForEach(availableMicrophones, id: \.uid) { microphone in
                            Text(microphone.name).tag(Optional(microphone.uid))
                        }
                        if let uid = coordinator.settings.preferredMicrophoneUID, missing {
                            Text(coordinator.settings.preferredMicrophoneName ?? "Selected microphone")
                                .tag(Optional(uid))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("voice.microphone.picker")
                }
            }

            if coordinator.state.isActive {
                SettingsNote("Applies from the next recording.")
            }
        }
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { coordinator.settings.preferredMicrophoneUID },
            set: { uid in
                let name =
                    uid.flatMap { chosen in
                        availableMicrophones.first { $0.uid == chosen }?.name
                    }
                    ?? (uid == coordinator.settings.preferredMicrophoneUID
                        ? coordinator.settings.preferredMicrophoneName : nil)
                coordinator.selectMicrophone(uid: uid, name: name)
            }
        )
    }

    private static func isMissing(
        _ coordinator: DictationCoordinator,
        availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone]
    ) -> Bool {
        guard let uid = coordinator.settings.preferredMicrophoneUID else { return false }
        return !availableMicrophones.contains { $0.uid == uid }
    }

    private func microphoneCaption(missing: Bool) -> String {
        guard let name = coordinator.settings.preferredMicrophoneName ?? coordinator.settings.preferredMicrophoneUID
        else {
            return "Automatic records from the system default input, and sidesteps a Bluetooth headset's "
                + "mic — it loses over a second to Bluetooth negotiation — whenever the built-in "
                + "microphone can record instead."
        }
        return missing
            ? "\(name) is not connected, so recordings use Automatic until it returns."
            : "Recordings use \(name) whenever it is connected; when it is not, Automatic takes over."
    }

    // MARK: Mute

    /// What system audio is doing right now, on the three-state ladder. It is a
    /// readout *of* the switch beside it, so it rides that row rather than
    /// restating the setting as a fact of its own.
    ///
    /// UNAVAILABLE outranks MUTE ON because it is the same promise, refused. A
    /// device with neither a settable mute nor a settable volume — a DisplayPort
    /// monitor, measured — cannot be silenced at all, and a row that kept saying
    /// "will be muted" is exactly how that went unnoticed. The state is sticky
    /// until the next capture answers the question again.
    private var muteRow: some View {
        let readout = Self.muteReadout(coordinator)
        return VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Kit.SettingRow("Mute system audio while recording", caption: readout.detail) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Kit.Mark(readout.label, tone: Kit.Mark.Tone(readout.severity))
                    Toggle(
                        "Mute system audio while recording",
                        isOn: settingBinding(coordinator, \.muteSystemAudioDuringCapture)
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("voice.mute.toggle")
                }
            }

            if coordinator.state.isActive {
                SettingsNote("Applies from the next recording.")
            }
        }
    }

    static func muteReadout(
        _ coordinator: DictationCoordinator
    ) -> (label: String, severity: ConsoleReadout.Severity, detail: String) {
        if coordinator.isSystemAudioMuted {
            return (
                "MUTED NOW", .ok,
                "System audio is currently muted and will be restored when the recording ends."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture, coordinator.isSystemAudioMuteUnavailable {
            return (
                "UNAVAILABLE", .warn,
                "The current output device offers no mute or volume control, so audio kept playing."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture {
            return (
                "MUTE ON", .neutral,
                "System audio fades out for the recording and fades back when it ends."
            )
        } else {
            return ("MUTE OFF", .neutral, "System audio will continue playing while recording.")
        }
    }

    // MARK: Cues

    private var cueRow: some View {
        Kit.SettingRow(
            "Play a sound when listening starts, stops or is discarded",
            caption: "A rising tone when the microphone opens, a falling tone when it closes, and two "
                + "clipped falling tones when you discard the utterance. System audio fades out after "
                + "the rising tone rather than over it."
        ) {
            Toggle(
                "Play a sound when listening starts, stops or is discarded",
                isOn: settingBinding(coordinator, \.sessionSoundsEnabled)
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("voice.cues.toggle")
        }
    }
}
