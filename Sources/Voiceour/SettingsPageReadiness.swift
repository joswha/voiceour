import SwiftUI
import VoiceCore

/// Settings ▸ Readiness: whether the backend, its model and the microphone are
/// ready for a real dictation.
///
/// The readouts themselves live in ``ConsoleReadiness``, shared with Home's
/// first-run checklist. These pages own only the row shape: the branch ladders
/// that choose between readouts are written once, over there.
struct SettingsReadinessPage: View {
    private let coordinator: DictationCoordinator
    private let microphone: PermissionState
    @Environment(\.theme) private var theme

    init(coordinator: DictationCoordinator, microphone: PermissionState) {
        self.coordinator = coordinator
        self.microphone = microphone
    }

    var body: some View {
        SettingsPage(.readiness) {
            Kit.Group {
                SettingsReadinessRow(
                    "Backend",
                    readout: ConsoleReadiness.backend(coordinator),
                    statusIdentifier: "system.backend.status"
                )
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                modelRow
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                SettingsReadinessRow("Microphone", readout: ConsoleReadiness.microphone(coordinator, microphone))
            }
        }
    }

    /// The pinned model behind the running backend, with the revision it is
    /// pinned to. A machine string, so it is monospaced and copyable in place,
    /// and a long one gives up its middle rather than the row's title.
    private var modelRow: some View {
        Kit.SettingRow("Model") {
            Text(DiagnosticsReport.modelIdentifier(coordinator))
                .roleStyle(.code)
                .foregroundStyle(theme.text2)
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
            Kit.Group {
                SettingsReadinessRow("Fn/Globe capture", readout: ConsoleReadiness.capture(accessibility))
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                SettingsReadinessRow("Insertion", readout: ConsoleReadiness.insertion(synthPaste))
            }
        }
    }
}

/// A fact row: the state's pill, then the remediation — what is wrong, then what
/// to do about it — trailing the title, its explanation as the caption, and a
/// download's meter under the caption. Healthy states keep their sentence: the
/// reader who wants to know *why* the app is ready is the same reader who needs
/// to know why it is not.
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
        VStack(alignment: .leading, spacing: 0) {
            Kit.SettingRow(label, caption: readout.detail) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    pill

                    if let remediation = readout.remediation {
                        Kit.Button(remediation.title, action: remediation.perform)
                            .accessibilityLabel(remediation.accessibilityLabel)
                            .accessibilityIdentifier(remediation.identifier)
                    }
                }
            }

            if let progress = readout.progress {
                meter(progress)
            }
        }
    }

    /// The readout's word in sentence case: the vocabulary in ``ConsoleReadiness``
    /// is shared with Home, and the pill is where it takes the console's case.
    @ViewBuilder
    private var pill: some View {
        let word = Kit.Pill(Kit.Pill.sentence(readout.label), tone: Kit.Pill.Tone(readout.severity))
        if let statusIdentifier {
            word.accessibilityIdentifier(statusIdentifier)
        } else {
            word
        }
    }

    /// Inset to the row's text and kept to the reading measure of the caption
    /// above it. The bar announces its own percentage, because the caption beside
    /// it names the model and its size but not how far the download has got.
    private func meter(_ progress: Double) -> some View {
        let value = progress.isFinite ? min(max(progress, 0), 1) : (progress > 0 ? 1 : 0)
        return Kit.Meter(fraction: value, style: .download)
            .frame(maxWidth: Self.meterWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .padding(.bottom, VoiceourMetrics.Space.md)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model download")
            .accessibilityValue("\(Int(value * 100))%")
            .accessibilityIdentifier("system.backend.progress")
    }

    /// The download bar's longest measure, so a wide page does not stretch a
    /// short fact into a rule across the group.
    private static let meterWidth: CGFloat = 320
}
