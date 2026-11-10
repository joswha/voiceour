import SwiftUI
import VoiceCore

/// Settings ▸ Privacy: what is kept on this Mac, and how dictations link to the
/// agent sessions they were spoken into.
struct SettingsPrivacyPage: View {
    private let coordinator: DictationCoordinator
    private let microphone: PermissionState
    private let accessibility: PermissionState
    private let synthPaste: PermissionState
    private let flash: Kit.Flash
    private var a11y = A11y()

    init(
        coordinator: DictationCoordinator,
        microphone: PermissionState,
        accessibility: PermissionState,
        synthPaste: PermissionState,
        flash: Kit.Flash
    ) {
        self.coordinator = coordinator
        self.microphone = microphone
        self.accessibility = accessibility
        self.synthPaste = synthPaste
        self.flash = flash
    }

    var body: some View {
        SettingsPage(.privacy) {
            Kit.Group {
                dataHandlingRow
            }
            Kit.Group {
                agentLinksRow
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                linkEarlierRow
            }
        }
    }

    private var dataHandlingRow: some View {
        Kit.SettingRow(
            "Data handling",
            caption:
                "Recent transcript history is saved locally on this Mac for the Journal tab. Audio temp "
                + "files are removed after ASR. Network is used only to download the local speech model."
        ) {
            Kit.Button("Copy Diagnostics") { copyDiagnostics() }
                .help("Copy storage paths, backend health, permissions and build info.")
                .accessibilityIdentifier("system.diagnostics.copy")
        }
    }

    private func copyDiagnostics() {
        let report = DiagnosticsReport.text(
            coordinator: coordinator,
            microphone: microphone,
            accessibility: accessibility,
            synthPaste: synthPaste
        )
        SettingsClipboard.copy(report, confirming: "Diagnostics copied to clipboard", through: flash, a11y: a11y)
    }

    /// Not `settingBinding`: turning binding off removes every row's binding and
    /// cancels the passes in flight, and a bare setting write does neither.
    private var agentLinksRow: some View {
        Kit.SettingRow(
            "Link dictations to agent sessions",
            caption:
                "When you dictate into Tern, Voiceour asks Tern which pane has focus and links the "
                + "dictation to the omp or Claude Code session running there. It reads only that "
                + "session's records in ~/.omp and ~/.claude, and nothing leaves this Mac. Turning "
                + "this off deletes every link; only Link Earlier Dictations can link them again, by their words."
        ) {
            Toggle(
                "Link dictations to agent sessions",
                isOn: Binding(
                    get: { coordinator.settings.agentSessionBindingEnabled },
                    set: { coordinator.setAgentSessionBinding($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("system.agent-links.toggle")
        }
    }

    /// Offered only while linking is on, because a run writes links the toggle
    /// would delete, and not while a run reads the agents' prompt logs, so one
    /// press is one run. The caption is the run's own result, never rebuilt here.
    private var linkEarlierRow: some View {
        let run = coordinator.linkEarlierRun
        return Kit.SettingRow(
            "Earlier dictations",
            caption: run.map { $0.isRunning ? "Linking\u{2026}" : $0.summary }
                ?? "Finds earlier dictations whose exact words reached one omp or Claude Code session on this "
                + "Mac, and links them to it."
        ) {
            Kit.Button("Link Earlier Dictations") { coordinator.linkEarlierDictations() }
                .help("Link earlier dictations to the agent session whose prompts hold their exact words.")
                .disabled(!coordinator.settings.agentSessionBindingEnabled || run?.isRunning == true)
                .accessibilityIdentifier("system.agent.link-earlier")
        }
    }
}
