import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Settings: everything the reader can change about dictation, then everything
/// this Mac has to allow for those choices to hold, then what is kept on disk
/// and how to unkeep it.
///
/// Preferences lead and readouts follow, because that is the order the questions
/// arrive in: a reader opens this tab to change something, and only reads the
/// readiness rows when what they changed did not happen. Splitting the two
/// across a General tab and a System tab made that second half a different
/// destination — the switch was on one tab and the reason it had no effect was
/// on another.
///
/// Section names stay distinct on purpose. **Dictation** owns the round trip
/// (trigger, hands-free stop, the cleanup pass before insertion) and **Audio**
/// owns the sound hardware around a capture — which microphone records, and the
/// one thing capture does to the rest of the Mac — while **Capture**
/// below owns the OS grants the key tap and synthetic paste depend on. Auto-stop
/// once sat under a BACKEND heading, which made that heading a lie for half its
/// rows; two sections both called "Capture" would be the same failure.
///
/// **Island** is the last preference and the only one drawn as a picture: how the
/// recording island looks, previewed in a showroom of its own rather than on the
/// real panel, because a visible island means a live microphone. Its options fold
/// shut, so the readouts still follow the choices within a short scroll.
///
/// Every OS grant this app asks for is reported exactly once, in the row for the
/// capability it gates — microphone by **Microphone**, Accessibility by **Fn/Globe
/// capture** for the key tap and by **Insertion** for synthetic paste. There is no
/// second permissions section restating those grants: a grant reported twice is a
/// grant a reader has to reconcile. Remediation rides the row it remedies, and
/// only when the grant is actually missing.
struct ConsoleSettingsTab: View {
    var coordinator: DictationCoordinator

    /// Real TCC state in production. The offscreen UI harness pins a fixed
    /// snapshot (`RenderOverrides.permissions`) so a golden never encodes this
    /// Mac's privacy grants, and so both the granted and the denied treatments can
    /// be captured.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    private var a11y = A11y()

    private enum FocusTarget: Hashable {
        case silence
    }

    /// The free-text duration commits on submit or focus loss, not on every
    /// keystroke: a half-typed number could not be cleared because the setter
    /// dropped anything that was not an `Int`. `nil` means "no edit in flight",
    /// and the field renders the stored value.
    @State private var silenceDraft: String?
    @FocusState private var focusedField: FocusTarget?

    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined
    @State private var accessibility: PermissionState = .notDetermined

    /// The input devices the microphone picker offers. Real HAL enumeration in
    /// production; the offscreen harness pins a fixed list
    /// (`RenderOverrides.availableMicrophones`) so a golden never encodes which
    /// microphones this Mac has.
    @State private var availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone] = []

    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingMemoryClear = false
    @State private var isConfirmingVocabularyClear = false
    @State private var isClearingHistory = false
    @State private var historyClearFailed = false
    @State private var isClearingMemory = false
    @State private var memoryClearFailed = false
    @State private var agentSkillWriteFailed = false
    @State private var copiedItem: CopiedItem?
    @State private var resetCopyFeedbackTask: Task<Void, Never>?

    /// The TypeSafe key being pasted. It lives only in this field until Save Key
    /// writes it, is cleared the moment the write succeeds, and is never drawn
    /// anywhere but the secure field itself.
    @State private var typeSafeKeyDraft = ""
    @State private var isConfirmingTypeSafeKeyRemoval = false
    @State private var typeSafeKeyWriteFailed = false

    /// Which copy action last reached the clipboard. One value rather than a flag
    /// per button: a copy replaces the clipboard, so the previous button's COPIED
    /// mark would be a false statement the moment the next copy lands.
    private enum CopiedItem {
        case diagnostics
        case agentInstructions
        case agentSkillCommand
    }

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
            Section("Dictation") {
                triggerRow
                autoStopRow
                cleanupRow
            }

            Section("Audio") {
                microphoneRow
                muteRow
                cueRow
            }

            // Not debug-gated, unlike Backend below: the one model Voiceour transcribes with,
            // what it downloads and what it keeps on disk.
            Section("Model") {
                modelRowContent
            }

            // Granite is the one recognizer a release launch selects, so a release build
            // has nothing to choose between: the picker exists to reach `fake` during
            // development, and a release user who found it could only move their own
            // dictation to synthetic text. The running model is still stated by the
            // Readiness rows below.
            if LaunchOptions.showsDebugPanes {
                Section("Backend") {
                    backendRow
                }
            }

            ConsoleIslandSection(coordinator: coordinator)

            Section("Readiness") {
                readinessRow(
                    "Backend",
                    ConsoleReadiness.backend(coordinator),
                    statusIdentifier: "system.backend.status"
                )
                modelRow
                readinessRow("Microphone", ConsoleReadiness.microphone(coordinator, microphone))
            }

            Section("Capture") {
                readinessRow("Fn/Globe capture", ConsoleReadiness.capture(accessibility))
                readinessRow("Insertion", ConsoleReadiness.insertion(synthPaste))
            }

            Section {
                ConsoleRow(
                    caption:
                        "Recent transcript history is saved locally on this Mac for the Journal tab. Audio temp "
                        + "files are removed after ASR. Network is used only to download the local speech model."
                ) {
                    LabeledContent {
                        HStack(spacing: VoiceourMetrics.Space.sm) {
                            if copiedItem == .diagnostics {
                                ConsoleStateMark("COPIED", .ok)
                            }
                            Button("Copy Diagnostics") { copyDiagnostics() }
                                .help("Copy storage paths, backend health, permissions and build info.")
                                .accessibilityIdentifier("system.diagnostics.copy")
                        }
                    } label: {
                        Text("Data handling")
                    }
                }
                ConsoleRow(
                    caption:
                        "When you dictate into Tern, Voiceour asks Tern which pane has focus and links the "
                        + "dictation to the omp or Claude Code session running there. It reads only that "
                        + "session's records in ~/.omp and ~/.claude, and nothing leaves this Mac. Turning "
                        + "this off deletes every link; links cannot be rebuilt."
                ) {
                    // Not `settingBinding`: turning binding off removes every row's binding
                    // and cancels the passes in flight, and a bare setting write does neither.
                    Toggle(
                        "Link dictations to agent sessions",
                        isOn: Binding(
                            get: { coordinator.settings.agentSessionBindingEnabled },
                            set: { coordinator.setAgentSessionBinding($0) }
                        )
                    )
                    .accessibilityIdentifier("system.agent-links.toggle")
                }
            } header: {
                Text("Privacy")
            }

            Section("Memory") {
                memoryToggleRow
                agentInstructionsRow
                agentSkillRow
                organizerToggleRow
                typeSafeKeyRow
            }

            Section("Danger") {
                clearHistoryRow
                clearMemoryRow
                clearVocabularyRow
            }
        }
        .formStyle(.grouped)
        // The window's default size is this tab's ideal size, so an update anywhere in the
        // form never makes the console's tab view measure the whole form for it. Without
        // it, every Island control step re-measured every row: measured at about 12 ms of
        // the 22 ms a step cost with all four Island folds open. Proposed sizes, and with
        // them the window's minimum and every laid-out row, are unchanged.
        .frame(
            idealWidth: VoiceourMetrics.Window.defaultWidth,
            idealHeight: VoiceourMetrics.Window.defaultHeight
        )
        .onChange(of: focusedField) { previous, current in
            if previous == .silence, current != .silence { commitSilence() }
        }
        .onAppear {
            coordinator.refreshBackendHealth()
            refreshPermissions(animated: false)
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(animated: true)
            refreshMicrophones()
        }
        .onDisappear {
            commitSilence()
            resetCopyFeedbackTask?.cancel()
        }
    }

    /// The user returning from System Settings is this tab's most important state
    /// change: three readouts change word and hue and up to three remediation
    /// buttons leave. Animating it means the grant visibly resolves instead of
    /// jump-cutting the rows that carry them.
    private func refreshPermissions(animated: Bool) {
        guard animated, !a11y.reduceMotion else {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
            return
        }
        withAnimation(VoiceourMotion.deliberate) {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
        }
    }

    private func refreshMicrophones() {
        availableMicrophones = RenderOverrides.availableMicrophones ?? CoreAudioInputDevice.availableMicrophones()
    }

    // MARK: Dictation

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

    /// The picker states what is *saved*: a durable device UID, or nil for
    /// Automatic. An unplugged selection stays on the menu under its persisted
    /// name with a NOT CONNECTED mark, because silently snapping the control back
    /// to Automatic would misreport what the next recording will try first.
    private var microphoneRow: some View {
        ConsoleRow(caption: microphoneCaption) {
            Picker("Microphone", selection: microphoneBinding) {
                Text("Automatic").tag(String?.none)
                ForEach(availableMicrophones, id: \.uid) { microphone in
                    Text(microphone.name).tag(Optional(microphone.uid))
                }
                if let uid = coordinator.settings.preferredMicrophoneUID, selectedMicrophoneIsMissing {
                    Text(coordinator.settings.preferredMicrophoneName ?? "Selected microphone")
                        .tag(Optional(uid))
                }
            }
            .accessibilityIdentifier("voice.microphone.picker")

            if selectedMicrophoneIsMissing {
                ConsoleStateMark("NOT CONNECTED", .warn)
            }

            if coordinator.state.isActive {
                ConsoleCaption("Applies from the next recording.")
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

    private var selectedMicrophoneIsMissing: Bool {
        guard let uid = coordinator.settings.preferredMicrophoneUID else { return false }
        return !availableMicrophones.contains { $0.uid == uid }
    }

    private var microphoneCaption: String {
        guard let name = coordinator.settings.preferredMicrophoneName ?? coordinator.settings.preferredMicrophoneUID
        else {
            return "Automatic records from the system default input, and sidesteps a Bluetooth headset's "
                + "mic — it loses over a second to Bluetooth negotiation — whenever the built-in "
                + "microphone can record instead."
        }
        return selectedMicrophoneIsMissing
            ? "\(name) is not connected, so recordings use Automatic until it returns."
            : "Recordings use \(name) whenever it is connected; when it is not, Automatic takes over."
    }

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

    // MARK: Model

    /// Granite pins one artifact, so there is nothing to choose and nothing to restart into:
    /// the row names the model, what it downloads, and its cache, which is the download alone
    /// because the file is mapped read-only and nothing is derived from it.
    private var modelRowContent: some View {
        let artifact = ASRModelArtifact.granite
        return ConsoleRow(
            caption: "Downloads \(ConsoleReadiness.gigabytes(artifact.sizeBytes)); "
                + "uses about \(ConsoleReadiness.gigabytes(artifact.sizeBytes)) after first load."
        ) {
            LabeledContent {
                Text(artifact.displayName)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.model.granite")
            } label: {
                Text("Speech model")
            }
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
    ///
    /// An unregistered id resolves here to the descriptor the registry would
    /// actually build, because this caption answers "what will load". The
    /// Readiness readouts below deliberately resolve it to the bare id instead: a
    /// readout must never name a model that is not running.
    private var runningSummary: String {
        restartRequired
            ? "\(ConsoleReadiness.activeBackendName(coordinator)) IN USE"
            : (ConsoleReadiness.activeDescriptor(coordinator) ?? ASRBackendRegistry.builtIn.defaultDescriptor)
                .modelLabel
    }

    // MARK: Readiness rows

    /// The readouts themselves live in ``ConsoleReadiness``, shared with Home's
    /// first-run card. This tab owns only the row shape: the branch ladders that
    /// choose between readouts are written once, over there.

    /// A fact row: state on the trailing rail, its explanation on the caption
    /// line, remediation after the mark — what is wrong, then what to do about it.
    /// Healthy states keep their sentence: the reader who wants to know *why* the
    /// app is ready is the same reader who needs to know why it is not.
    private func readinessRow(
        _ label: String,
        _ readout: ConsoleReadout,
        statusIdentifier: String? = nil
    ) -> some View {
        ConsoleRow(caption: readout.detail) {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                LabeledContent {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        if let statusIdentifier {
                            ConsoleStateMark(readout.label, readout.severity)
                                .accessibilityIdentifier(statusIdentifier)
                        } else {
                            ConsoleStateMark(readout.label, readout.severity)
                        }

                        if let remediation = readout.remediation {
                            Button(remediation.title, action: remediation.perform)
                                .accessibilityLabel(remediation.accessibilityLabel)
                                .accessibilityIdentifier(remediation.identifier)
                        }
                    }
                } label: {
                    Text(label)
                }

                if let progress = readout.progress {
                    MeterBar(fraction: progress, style: .download(ground: .system))
                        .accessibilityIdentifier("system.backend.progress")
                }
            }
        }
    }

    /// The pinned model behind the running backend, with the revision it is
    /// pinned to. A machine string, so it is monospaced and copyable in place.
    private var modelRow: some View {
        LabeledContent {
            Text(DiagnosticsReport.modelIdentifier(coordinator))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text("Model")
        }
    }

    // MARK: Diagnostics

    private func copyDiagnostics() {
        let report = DiagnosticsReport.text(
            coordinator: coordinator,
            microphone: microphone,
            accessibility: accessibility,
            synthPaste: synthPaste
        )
        copy(report, as: .diagnostics)
    }

    /// Every copy button writes through here, so the clipboard helper, the success
    /// rule and the mark's lifetime cannot drift between them.
    private func copy(_ text: String, as item: CopiedItem, announcement: String? = nil) {
        // "Copied" is a statement about the clipboard: a refused write shows nothing.
        guard GeneralPasteboard.copy(text) != nil else { return }
        if let announcement {
            announce(announcement)
        }
        resetCopyFeedbackTask?.cancel()
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
            copiedItem = item
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
                copiedItem = nil
            }
        }
    }

    /// VoiceOver hears the sentence the mark shows, because a mark that appears
    /// beside a button the cursor has already left confirms nothing. A no-op when
    /// VoiceOver is not running.
    private func announce(_ sentence: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: Memory

    /// Not `settingBinding`: turning memory on also keeps every History row the
    /// folder does not hold yet, and a bare setting write would leave those out.
    private var memoryToggleRow: some View {
        ConsoleRow(
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
            .accessibilityIdentifier("system.memory.toggle")
        }
    }

    /// Offered while memory is on or a folder is left over from when it was:
    /// either way there is a folder, now or after the next dictation, for the
    /// paragraph to point an agent at.
    private var agentInstructionsRow: some View {
        ConsoleRow(
            caption:
                "Copies one paragraph for AGENTS.md or CLAUDE.md that tells an agent where the memory folder "
                + "is and how to use it."
        ) {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if copiedItem == .agentInstructions {
                        ConsoleStateMark("COPIED", .ok)
                    }
                    Button("Copy Agent Instructions") { copyAgentInstructions() }
                        .help("Copy a paragraph that tells a coding agent where the memory folder is.")
                        .disabled(!(coordinator.settings.memoryEnabled || coordinator.memoryExistsOnDisk))
                        .accessibilityIdentifier("system.memory.copy-instructions")
                }
            } label: {
                Text("Agent access")
            }
        }
    }

    private func copyAgentInstructions() {
        copy(MemoryPages.agentInstructions(root: coordinator.memoryStore.root), as: .agentInstructions)
    }

    /// Offered on the same terms as Copy Agent Instructions, and not while the
    /// app quits: the press writes the skill into the memory folder, and a write
    /// the termination drain has already passed would never land.
    private var agentSkillRow: some View {
        ConsoleRow(
            caption: agentSkillWriteFailed
                ? "The skill could not be written on this Mac."
                : "Run it once in Terminal. It links one skill into the omp, Claude Code and Codex skill folders "
                    + "that exist, so every agent learns where your dictations are kept. Voiceour writes only "
                    + "inside its own folder. Agents may ask before they read outside the project. A project "
                    + "with an omp includeSkills list must add voiceour-memory.",
            captionColor: agentSkillWriteFailed ? .red : nil
        ) {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if copiedItem == .agentSkillCommand {
                        ConsoleStateMark("COPIED", .ok)
                    }
                    Button("Copy Install Command") { copyAgentSkillCommand() }
                        .help(
                            "Copy a Terminal command that links the Voiceour memory skill into your agents' skill folders."
                        )
                        .disabled(
                            !(coordinator.settings.memoryEnabled || coordinator.memoryExistsOnDisk)
                                || coordinator.isPreparingForTermination
                        )
                        .accessibilityIdentifier("system.memory.copy-skill-command")
                }
            } label: {
                Text("Agent skill")
            }
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
            copy(
                MemoryPages.skillInstallCommand(root: coordinator.memoryStore.root),
                as: .agentSkillCommand,
                announcement: "Install command copied to clipboard"
            )
        }
    }

    /// Not `settingBinding`: turning sorting off also cancels every labelling
    /// task in flight, which a bare setting write would leave running.
    ///
    /// Offered only once there is a key, because without one the switch would do
    /// nothing. A switch already on stays operable after its key goes, so a reader
    /// is never left with an "on" they cannot turn off.
    private var organizerToggleRow: some View {
        ConsoleRow(
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
            .disabled(coordinator.typeSafeKeyOrigin == nil && !coordinator.settings.organizerEnabled)
            .accessibilityIdentifier("system.organizer.toggle")
        }
    }

    /// Says where the key comes from and never what it is: the status names a
    /// source, the field is secure, and a saved key leaves the field empty.
    private var typeSafeKeyRow: some View {
        let origin = coordinator.typeSafeKeyOrigin
        return ConsoleRow(
            caption: typeSafeKeyWriteFailed
                ? "The key file could not be changed on this Mac."
                : "The key stays on this Mac, in a file only your account can read. An environment variable "
                    + "takes precedence over the file.",
            captionColor: typeSafeKeyWriteFailed ? .red : nil
        ) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: VoiceourMetrics.Space.xs) {
                    Text(Self.typeSafeKeyStatus(origin))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("system.organizer.key.status")
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        // The prompt is drawn inside the field, where a click lands on the
                        // field; a visible title would sit beside an empty field that shows
                        // nothing of itself.
                        SecureField("TypeSafe key to save", text: $typeSafeKeyDraft, prompt: Text("Paste a key"))
                            .labelsHidden()
                            .frame(minWidth: VoiceourMetrics.Field.short)
                            .onSubmit { saveTypeSafeKey() }
                            .accessibilityIdentifier("system.organizer.key.field")
                        Button("Save Key") { saveTypeSafeKey() }
                            .disabled(isTypeSafeKeyDraftBlank)
                            .accessibilityIdentifier("system.organizer.key.save")
                        if origin == .keyFile {
                            Button("Remove Key", role: .destructive) {
                                typeSafeKeyWriteFailed = false
                                isConfirmingTypeSafeKeyRemoval = true
                            }
                            .accessibilityIdentifier("system.organizer.key.remove")
                        }
                    }
                }
            } label: {
                Text("TypeSafe key")
            }
            // A container element, so the row's identifier does not overwrite
            // the field's and the buttons' own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("system.organizer.key")
        }
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

    // MARK: Danger

    /// The erases the app owns. They read directly on the Privacy and Memory rows
    /// above: those rows state what is kept locally, these are how a user unkeeps
    /// it. Each is guarded by the system's own destructive confirmation rather
    /// than a typed token — the sheet names the subject, states the scope, and
    /// puts the destructive verb behind a deliberate second press.
    private var clearHistoryRow: some View {
        ConsoleRow(
            caption: historyClearFailed
                ? "Transcript history could not be erased from disk — it will come back on relaunch."
                : Self.historyClearSentence,
            captionColor: historyClearFailed ? .red : nil
        ) {
            LabeledContent {
                Button(isClearingHistory ? "Clearing…" : "Clear History…", role: .destructive) {
                    historyClearFailed = false
                    isConfirmingHistoryClear = true
                }
                .disabled(hasNothingToClear || isClearingHistory)
                .accessibilityIdentifier("system.history.arm")
            } label: {
                Text("Clear history")
            }
        }
        .confirmationDialog(
            "Clear transcript history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearHistory(includingMemory: false) }
                .accessibilityIdentifier("system.history.confirm")
            // Offered beside the plain clear, never folded into it: Clear History
            // leaves memory alone, and a reader erasing History to start over is
            // the one most likely to want the kept copy gone too.
            if hasMemoryToClear {
                Button("Clear History and Memory", role: .destructive) { clearHistory(includingMemory: true) }
                    .accessibilityIdentifier("system.history.confirm-with-memory")
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing transcript history")
                .accessibilityIdentifier("system.history.cancel")
        } message: {
            Text(Self.historyClearSentence)
        }
    }

    /// Named once because the row caption and the confirmation both state it,
    /// and a destructive action whose two sentences disagree about its scope is
    /// worse than one that says nothing.
    private static let historyClearSentence =
        "Clear local transcript history and the lifetime dictation stats on Home. "
        + "Settings and glossary terms are kept."

    /// The stats ledger outlives individual transcripts — a reader who deleted
    /// every row one at a time in History still has counts here — so an empty
    /// journal alone must not disarm the only control that erases them.
    private var hasNothingToClear: Bool {
        coordinator.recentSessions.isEmpty && coordinator.dictationStats == DictationStatsLedger()
    }

    /// With `includingMemory` the memory erase runs after History and the ledger,
    /// and the row stays in its clearing state until all three have answered.
    /// Each failure is reported on the row that names what survived: a memory
    /// folder that could not be removed is the Clear memory row's caption, so the
    /// History row never claims transcripts survived when they did not.
    private func clearHistory(includingMemory: Bool) {
        isClearingHistory = true
        historyClearFailed = false
        if includingMemory {
            isClearingMemory = true
            memoryClearFailed = false
        }
        Task {
            let historyCleared = await coordinator.clearRecentSessions()
            let statsCleared = await coordinator.clearDictationStats()
            if includingMemory {
                let memoryCleared = await coordinator.clearMemory()
                isClearingMemory = false
                memoryClearFailed = !memoryCleared
            }
            isClearingHistory = false
            // A destructive action that half-succeeds must say so: the row reports
            // that the data survived on disk instead of reporting nothing.
            historyClearFailed = !(historyCleared && statsCleared)
        }
    }

    private var clearMemoryRow: some View {
        ConsoleRow(
            caption: memoryClearFailed
                ? "Memory could not be erased from disk — it will come back on relaunch."
                : Self.memoryClearSentence,
            captionColor: memoryClearFailed ? .red : nil
        ) {
            LabeledContent {
                Button(isClearingMemory ? "Clearing…" : "Clear Memory…", role: .destructive) {
                    memoryClearFailed = false
                    isConfirmingMemoryClear = true
                }
                .disabled(!hasMemoryToClear || isClearingMemory)
                .accessibilityIdentifier("system.memory.arm")
            } label: {
                Text("Clear memory")
            }
        }
        .confirmationDialog(
            "Clear memory?",
            isPresented: $isConfirmingMemoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear Memory", role: .destructive) { clearMemory() }
                .accessibilityIdentifier("system.memory.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing memory")
                .accessibilityIdentifier("system.memory.cancel")
        } message: {
            Text(Self.memoryClearSentence)
        }
    }

    /// Named once for the same reason as `historyClearSentence`: the caption and
    /// the confirmation must state one scope.
    private static let memoryClearSentence =
        "Erase the memory folder: every kept dictation and note, your topics, the Markdown pages, and "
        + "anything agents saved there. History and the Home figures are kept."

    /// The folder on disk, or entries whose first write is still queued behind
    /// it. The second half matters for one turn only: a memory switched on with
    /// History already present publishes its entries before the folder exists,
    /// and the disk check alone is not something this view observes.
    private var hasMemoryToClear: Bool {
        coordinator.memoryExistsOnDisk || !coordinator.memoryEntries.isEmpty
    }

    private func clearMemory() {
        isClearingMemory = true
        memoryClearFailed = false
        Task {
            let cleared = await coordinator.clearMemory()
            isClearingMemory = false
            // Mirrors the History row: an erase that left the folder says so.
            memoryClearFailed = !cleared
        }
    }

    /// Unlike `clearRecentSessions` this mutation is synchronous and publishes no
    /// durability result, so there is no failure state for the row to report.
    private var clearVocabularyRow: some View {
        ConsoleRow(
            caption:
                "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled "
                + "defaults back to their shipped surfaces."
        ) {
            LabeledContent {
                Button("Clear Vocabulary…", role: .destructive) {
                    isConfirmingVocabularyClear = true
                }
                .disabled(!coordinator.hasLearnedVocabulary)
                .accessibilityIdentifier("system.vocabulary.arm")
            } label: {
                Text("Clear vocabulary")
            }
        }
        .confirmationDialog(
            "Clear learned vocabulary?",
            isPresented: $isConfirmingVocabularyClear,
            titleVisibility: .visible
        ) {
            Button("Clear Vocabulary", role: .destructive) {
                coordinator.clearLearnedVocabulary()
            }
            .accessibilityIdentifier("system.vocabulary.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing learned vocabulary")
                .accessibilityIdentifier("system.vocabulary.cancel")
        } message: {
            Text(
                "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled "
                    + "defaults back to their shipped surfaces."
            )
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
