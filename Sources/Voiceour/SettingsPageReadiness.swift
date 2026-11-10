import SwiftUI
import VoiceCore

/// Settings ▸ Readiness: whether the backend, its model and the microphone are
/// ready for a real dictation.
///
/// The readouts themselves live in ``ConsoleReadiness``, shared with Home's
/// first-run card. These pages own only the row shape: the branch ladders that
/// choose between readouts are written once, over there.
struct SettingsReadinessPage: View {
    private let coordinator: DictationCoordinator
    private let microphone: PermissionState

    init(coordinator: DictationCoordinator, microphone: PermissionState) {
        self.coordinator = coordinator
        self.microphone = microphone
    }

    var body: some View {
        SettingsPage(.readiness) {
            SettingsIsland {
                SettingsReadinessRow(
                    "Backend",
                    readout: ConsoleReadiness.backend(coordinator),
                    statusIdentifier: "system.backend.status"
                )
                Kit.Rule()
                modelRow
                Kit.Rule()
                SettingsReadinessRow("Microphone", readout: ConsoleReadiness.microphone(coordinator, microphone))
            }
        }
    }

    /// The pinned model behind the running backend, with the revision it is
    /// pinned to. A machine string, so it is monospaced and copyable in place.
    private var modelRow: some View {
        Kit.SettingRow("Model") {
            Text(DiagnosticsReport.modelIdentifier(coordinator))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Settings ▸ Capture: the Accessibility grant the Fn/Globe key tap and
/// synthetic paste depend on, reported once per capability it gates.
struct SettingsCapturePage: View {
    private let accessibility: PermissionState
    private let synthPaste: PermissionState

    init(accessibility: PermissionState, synthPaste: PermissionState) {
        self.accessibility = accessibility
        self.synthPaste = synthPaste
    }

    var body: some View {
        SettingsPage(.capture) {
            SettingsIsland {
                SettingsReadinessRow("Fn/Globe capture", readout: ConsoleReadiness.capture(accessibility))
                Kit.Rule()
                SettingsReadinessRow("Insertion", readout: ConsoleReadiness.insertion(synthPaste))
            }
        }
    }
}

/// A fact row: the state's mark on the title line, remediation after the mark —
/// what is wrong, then what to do about it — and its explanation as the caption.
/// Healthy states keep their sentence: the reader who wants to know *why* the
/// app is ready is the same reader who needs to know why it is not.
struct SettingsReadinessRow: View {
    private let label: String
    private let readout: ConsoleReadout
    private let statusIdentifier: String?

    init(_ label: String, readout: ConsoleReadout, statusIdentifier: String? = nil) {
        self.label = label
        self.readout = readout
        self.statusIdentifier = statusIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Kit.SettingRow(label, caption: readout.detail) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    mark

                    if let remediation = readout.remediation {
                        Kit.ActionButton(remediation.title, action: remediation.perform)
                            .accessibilityLabel(remediation.accessibilityLabel)
                            .accessibilityIdentifier(remediation.identifier)
                    }
                }
            }

            if let progress = readout.progress {
                MeterBar(fraction: progress, style: .download)
                    .accessibilityIdentifier("system.backend.progress")
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        let word = Kit.Mark(readout.label, tone: Kit.Mark.Tone(readout.severity))
        if let statusIdentifier {
            word.accessibilityIdentifier(statusIdentifier)
        } else {
            word
        }
    }
}
