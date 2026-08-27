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
    @State private var isConfirmingVocabularyClear = false
    @State private var isClearingHistory = false
    @State private var historyClearFailed = false
    @State private var didCopyDiagnostics = false
    @State private var resetCopyFeedbackTask: Task<Void, Never>?

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

            // Not debug-gated, unlike Backend below: two artifacts actually ship
            // and the difference between them is 0.6 GB of this Mac's disk, which
            // is a trade only the reader can make.
            Section("Model") {
                modelVariantRow
            }

            // One real backend ships, so a release build has nothing to choose
            // between: the picker exists to reach `fake` during development, and
            // a release user who found it could only downgrade their own
            // dictation to synthetic text. The running model is still stated by
            // the Readiness rows below.
            if LaunchOptions.showsDebugPanes {
                Section("Backend") {
                    backendRow
                }
            }

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
                        "Recent transcript history is saved locally on this Mac for the History tab. Audio temp "
                        + "files are removed after ASR. Network is used only to download the local speech model."
                ) {
                    LabeledContent {
                        HStack(spacing: VoiceourMetrics.Space.sm) {
                            if didCopyDiagnostics {
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
            } header: {
                Text("Privacy")
            }

            Section("Danger") {
                clearHistoryRow
                clearVocabularyRow
            }
        }
        .formStyle(.grouped)
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

    /// The picker states what is *saved* and its caption states what that choice
    /// costs; the mark states whether the sidecar is already running it. The
    /// artifact is chosen when the sidecar launches and cannot be swapped under a
    /// loaded model, so this is restart-to-apply on the same path the Backend
    /// picker below uses.
    private var modelVariantRow: some View {
        ConsoleRow(caption: modelVariantSummary) {
            Picker("Speech model", selection: settingBinding(coordinator, \.asrModelVariant)) {
                ForEach(ASRModelVariant.allCases, id: \.self) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            // Radio buttons rather than a segmented control: two options that each need a
            // sentence of explanation read better stacked, and a segmented control answers an
            // accessibility press with false while still changing selection, which leaves the
            // offscreen flow unable to drive the one control this feature turns on.
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("voice.model.picker")

            HStack(spacing: VoiceourMetrics.Space.sm) {
                ConsoleStateMark(
                    modelRestartRequired ? "RESTART TO APPLY" : "IN USE",
                    modelRestartRequired ? .warn : .neutral
                )

                if modelRestartRequired && restartAvailable {
                    Button("Restart Voiceour") { restartApplication() }
                        .accessibilityLabel("Restart Voiceour to apply speech model")
                        .accessibilityIdentifier("voice.model.restart")
                }
            }
        }
    }

    private var modelRestartRequired: Bool {
        coordinator.settings.asrModelVariant != coordinator.activeModelVariant
    }

    /// What the choice costs, stated about the *selected* variant because that is
    /// the option the reader is weighing — the Readiness rows below stay with what
    /// is loaded.
    ///
    /// Sized by hand rather than through ByteCountFormatter for the reason the
    /// download readout gives: that formatter is locale-aware and would bake the
    /// developer's region into a committed golden.
    ///
    /// Compact is never sold as faster or better. The committed corpus puts the two
    /// at the same word error rate and Compact at lower throughput, so the disk is
    /// the only honest reason to pick it.
    private var modelVariantSummary: String {
        let variant = coordinator.settings.asrModelVariant
        let sizeText = String(format: "%.2f GB", Double(variant.sizeBytes) / 1_000_000_000)
        switch variant {
        case .f16:
            return "\(sizeText) on disk. The default, and the faster of the two."
        case .q8:
            return "\(sizeText) on disk, roughly half of Balanced. Transcripts match Balanced to "
                + "within what the committed corpus can resolve, at slightly lower throughput."
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
        GeneralPasteboard.copy(
            DiagnosticsReport.text(
                coordinator: coordinator,
                microphone: microphone,
                accessibility: accessibility,
                synthPaste: synthPaste
            )
        )
        resetCopyFeedbackTask?.cancel()
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
            didCopyDiagnostics = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
                didCopyDiagnostics = false
            }
        }
    }

    // MARK: Danger

    /// The two erases the app owns. They read directly on the privacy row above:
    /// that row states what is kept locally, these two are how a user unkeeps it.
    /// Both are guarded by the system's own destructive confirmation rather than a
    /// typed token — the sheet names the subject, states the scope, and puts the
    /// destructive verb behind a deliberate second press.
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
            Button("Clear History", role: .destructive) { clearHistory() }
                .accessibilityIdentifier("system.history.confirm")
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

    private func clearHistory() {
        isClearingHistory = true
        historyClearFailed = false
        Task {
            let historyCleared = await coordinator.clearRecentSessions()
            let statsCleared = await coordinator.clearDictationStats()
            isClearingHistory = false
            // A destructive action that half-succeeds must say so: the row reports
            // that the data survived on disk instead of reporting nothing.
            historyClearFailed = !(historyCleared && statsCleared)
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
