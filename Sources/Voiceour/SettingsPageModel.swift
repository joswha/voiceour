import SwiftUI
import VoiceCore
import VoiceMac

/// Settings ▸ Model: the one model Voiceour transcribes with, what it downloads
/// and what it keeps on disk. Not debug-gated, unlike Backend.
struct SettingsModelPage: View {
    var body: some View {
        SettingsPage(.model) {
            SettingsIsland {
                speechModelRow
            }
        }
    }

    /// Granite pins one artifact, so there is nothing to choose and nothing to restart into:
    /// the row names the model, what it downloads, and its cache, which is the download alone
    /// because the file is mapped read-only and nothing is derived from it.
    private var speechModelRow: some View {
        let artifact = ASRModelArtifact.granite
        return Kit.SettingRow(
            "Speech model",
            caption: "Downloads \(ConsoleReadiness.gigabytes(artifact.sizeBytes)); "
                + "uses about \(ConsoleReadiness.gigabytes(artifact.sizeBytes)) after first load."
        ) {
            Text(artifact.displayName)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice.model.granite")
        }
    }
}

/// Settings ▸ Backend, offered only with the debug panes: the picker exists to
/// reach `fake` during development, and a release user who found it could only
/// move their own dictation to synthetic text. The running model is still stated
/// on Readiness.
struct SettingsBackendPage: View {
    private let coordinator: DictationCoordinator

    /// One source for the backend vocabulary, so the picker, the running readout
    /// and the restart notice can never disagree about a name.
    private static let backends: [(id: String, name: String)] =
        ASRBackendRegistry.builtIn.descriptors.map { ($0.id, $0.displayName) }

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        SettingsPage(.backend) {
            SettingsIsland {
                backendRow
            }
        }
    }

    /// The picker states what is *saved*; the caption under it states what is
    /// *running*. They are the same thing until the user changes the picker, at
    /// which point the mark turns amber and the restart action appears beside it
    /// — the user never has to quit and relaunch the app manually.
    private var backendRow: some View {
        Kit.SettingRow("ASR backend", caption: runningSummary) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.Mark(
                    restartRequired ? "RESTART TO APPLY" : "IN USE",
                    tone: restartRequired ? .caution : .neutral
                )

                if restartRequired && restartAvailable {
                    Kit.ActionButton("Restart Voiceour") { restartApplication() }
                        .accessibilityLabel("Restart Voiceour to apply backend")
                        .accessibilityIdentifier("voice.backend.restart")
                }

                Picker("ASR backend", selection: settingBinding(coordinator, \.asrBackend)) {
                    ForEach(Self.backends, id: \.id) { backend in
                        Text(backend.name).tag(backend.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("voice.backend.picker")
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
    ///
    /// An unregistered id resolves here to the descriptor the registry would
    /// actually build, because this caption answers "what will load". The
    /// Readiness readouts deliberately resolve it to the bare id instead: a
    /// readout must never name a model that is not running.
    private var runningSummary: String {
        restartRequired
            ? "\(ConsoleReadiness.activeBackendName(coordinator)) IN USE"
            : (ConsoleReadiness.activeDescriptor(coordinator) ?? ASRBackendRegistry.builtIn.defaultDescriptor)
                .modelLabel
    }
}
