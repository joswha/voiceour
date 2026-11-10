import SwiftUI
import VoiceCore

/// Settings ▸ Memory: the folder of dictations Voiceour keeps for coding agents,
/// how an agent learns of it, and how its entries are sorted.
struct SettingsMemoryPage: View {
    private let coordinator: DictationCoordinator
    private let flash: Kit.Flash
    private var a11y = A11y()
    @Environment(\.theme) private var theme

    @State private var agentSkillWriteFailed = false

    /// The TypeSafe key being pasted. It lives only in this field until Save Key
    /// writes it, is cleared the moment the write succeeds, and is never drawn
    /// anywhere but the secure field itself.
    @State private var typeSafeKeyDraft = ""
    @State private var isConfirmingTypeSafeKeyRemoval = false
    @State private var typeSafeKeyWriteFailed = false

    init(coordinator: DictationCoordinator, flash: Kit.Flash) {
        self.coordinator = coordinator
        self.flash = flash
    }

    var body: some View {
        SettingsPage(.memory) {
            Kit.Group {
                memoryToggleRow
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                agentInstructionsRow
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                agentSkillRow
            }
            Kit.Group {
                organizerToggleRow
                Kit.Rule(inset: VoiceourMetrics.Space.md)
                typeSafeKeyRow
            }
        }
    }

    // MARK: Memory

    /// Not `settingBinding`: turning memory on also keeps every History row the
    /// folder does not hold yet, and a bare setting write would leave those out.
    private var memoryToggleRow: some View {
        Kit.SettingRow(
            "Keep dictations in memory",
            caption:
                "Voiceour keeps every dictation, verbatim, in a memory folder on this Mac with no 500-row "
                + "limit, and writes Markdown pages there that coding agents can read. Dictations into secure "
                + "fields are never kept. Turning this off stops new dictations from being added and keeps "
                + "the folder; Clear Memory erases it."
        ) {
            Toggle(
                "Keep dictations in memory",
                isOn: Binding(
                    get: { coordinator.settings.memoryEnabled },
                    set: { coordinator.setMemoryEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("system.memory.toggle")
        }
    }

    /// Offered while memory is on or a folder is left over from when it was:
    /// either way there is a folder, now or after the next dictation, for the
    /// paragraph to point an agent at.
    private var agentInstructionsRow: some View {
        Kit.SettingRow(
            "Agent access",
            caption:
                "Copies one paragraph for AGENTS.md or CLAUDE.md that tells an agent where the memory folder "
                + "is and how to use it."
        ) {
            Kit.Button("Copy Agent Instructions") { copyAgentInstructions() }
                .help("Copy a paragraph that tells a coding agent where the memory folder is.")
                .disabled(!(coordinator.settings.memoryEnabled || coordinator.memoryExistsOnDisk))
                .accessibilityIdentifier("system.memory.copy-instructions")
        }
    }

    private func copyAgentInstructions() {
        SettingsClipboard.copy(
            MemoryPages.agentInstructions(root: coordinator.memoryStore.root),
            confirming: "Agent instructions copied to clipboard",
            through: flash,
            a11y: a11y
        )
    }

    /// Offered on the same terms as Copy Agent Instructions, and not while the
    /// app quits: the press writes the skill into the memory folder, and a write
    /// the termination drain has already passed would never land.
    private var agentSkillRow: some View {
        Kit.SettingRow(
            "Agent skill",
            caption: agentSkillWriteFailed
                ? "The skill could not be written on this Mac."
                : "Run it once in Terminal. It links one skill into the omp, Claude Code and Codex skill folders "
                    + "that exist, so every agent learns where your dictations are kept. Voiceour writes only "
                    + "inside its own folder. Agents may ask before they read outside the project. A project "
                    + "with an omp includeSkills list must add voiceour-memory.",
            captionColor: agentSkillWriteFailed ? theme.critical.text : nil
        ) {
            Kit.Button("Copy Install Command") { copyAgentSkillCommand() }
                .help(
                    "Copy a Terminal command that links the Voiceour memory skill into your agents' skill folders."
                )
                .disabled(
                    !(coordinator.settings.memoryEnabled || coordinator.memoryExistsOnDisk)
                        || coordinator.isPreparingForTermination
                )
                .accessibilityIdentifier("system.memory.copy-skill-command")
        }
    }

    /// The command links to the skill file, so it is copied only once that file
    /// is on disk: a link to nothing would teach no agent anything.
    private func copyAgentSkillCommand() {
        agentSkillWriteFailed = false
        Task {
            guard await coordinator.prepareAgentSkill() else {
                agentSkillWriteFailed = true
                return
            }
            SettingsClipboard.copy(
                MemoryPages.skillInstallCommand(root: coordinator.memoryStore.root),
                confirming: "Install command copied to clipboard",
                through: flash,
                a11y: a11y
            )
        }
    }

    // MARK: Sorting

    /// Not `settingBinding`: turning sorting off also cancels every labelling
    /// task in flight, which a bare setting write would leave running.
    ///
    /// Offered only once there is a key, because without one the switch would do
    /// nothing. A switch already on stays operable after its key goes, so a reader
    /// is never left with an "on" they cannot turn off.
    private var organizerToggleRow: some View {
        Kit.SettingRow(
            "Sort entries with Jev",
            caption:
                "Voiceour sends the text of each new memory entry, and of earlier entries when you press Sort "
                + "Entries, with your topic names and descriptions, to TypeSafe's Jev model at api.typesafe.ai. "
                + "Jev answers with labels only: a kind, a topic and a keep score. It writes no text, and nothing "
                + "is sent while this is off."
        ) {
            Toggle(
                "Sort entries with Jev",
                isOn: Binding(
                    get: { coordinator.settings.organizerEnabled },
                    set: { coordinator.setOrganizerEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(coordinator.typeSafeKeyOrigin == nil && !coordinator.settings.organizerEnabled)
            .accessibilityIdentifier("system.organizer.toggle")
        }
    }

    /// Says where the key comes from and never what it is: the status names a
    /// source, the field is secure, and a saved key leaves the field empty.
    private var typeSafeKeyRow: some View {
        let origin = coordinator.typeSafeKeyOrigin
        return Kit.SettingRow(
            "TypeSafe key",
            caption: typeSafeKeyWriteFailed
                ? "The key file could not be changed on this Mac."
                : "The key stays on this Mac, in a file only your account can read. An environment variable "
                    + "takes precedence over the file.",
            captionColor: typeSafeKeyWriteFailed ? theme.critical.text : nil
        ) {
            VStack(alignment: .trailing, spacing: VoiceourMetrics.Space.xs) {
                Text(Self.typeSafeKeyStatus(origin))
                    .roleStyle(.body)
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("system.organizer.key.status")
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    // The prompt is drawn inside the field, where a click lands on the
                    // field; a visible title would sit beside an empty field that shows
                    // nothing of itself.
                    SecureField(
                        "TypeSafe key to save",
                        text: $typeSafeKeyDraft,
                        prompt: Text("Paste a key").foregroundStyle(theme.text3)
                    )
                    .labelsHidden()
                    .frame(minWidth: VoiceourMetrics.Field.short)
                    .onSubmit { saveTypeSafeKey() }
                    .accessibilityIdentifier("system.organizer.key.field")
                    Kit.Button("Save Key") { saveTypeSafeKey() }
                        .disabled(isTypeSafeKeyDraftBlank)
                        .accessibilityIdentifier("system.organizer.key.save")
                    if origin == .keyFile {
                        Kit.Button("Remove Key", prominence: .destructive) {
                            typeSafeKeyWriteFailed = false
                            isConfirmingTypeSafeKeyRemoval = true
                        }
                        .accessibilityIdentifier("system.organizer.key.remove")
                    }
                }
            }
        }
        // A container element, so the row's identifier does not overwrite the
        // field's and the buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("system.organizer.key")
        .confirmationDialog(
            "Remove the TypeSafe key?",
            isPresented: $isConfirmingTypeSafeKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) { removeTypeSafeKey() }
                .accessibilityIdentifier("system.organizer.key.remove.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel removing the TypeSafe key")
        } message: {
            Text("Voiceour deletes typesafe.key from this Mac. Sorting stops until you save a key again.")
        }
    }

    /// The source the key comes from, in the words the row prints.
    private static func typeSafeKeyStatus(_ origin: TypeSafeKeySource.Origin?) -> String {
        switch origin {
        case .environment: "From the TYPESAFE_API_KEY environment variable"
        case .keyFile: "Saved in typesafe.key"
        case nil: "Not set"
        }
    }

    private var isTypeSafeKeyDraftBlank: Bool {
        typeSafeKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A blank draft is refused here rather than passed on: the coordinator
    /// reads a blank key as "remove the file", which only Remove Key may ask for.
    private func saveTypeSafeKey() {
        guard !isTypeSafeKeyDraftBlank else { return }
        let saved = coordinator.saveTypeSafeKey(typeSafeKeyDraft)
        typeSafeKeyWriteFailed = !saved
        if saved { typeSafeKeyDraft = "" }
    }

    private func removeTypeSafeKey() {
        typeSafeKeyWriteFailed = !coordinator.saveTypeSafeKey("")
    }
}
