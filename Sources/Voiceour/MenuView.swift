import SwiftUI
import VoiceCore

/// The menu-bar popover.
///
/// Three blocks separated by `Space.lg`, each block internally at `Space.sm` /
/// `Space.xs`, so the grouping is legible from the whitespace alone instead of
/// resting entirely on two hairlines (one of which used to rasterise to zero
/// pixels and separated nothing):
///
/// * **status** — the session chip, the mute chip and the capture hotkey on one
///   row, then the target line. The target line is suppressed whenever it would
///   contradict the state under it: it is a future-tense promise, and an error
///   means it cannot be kept while a finished outcome means it is already spent.
/// * **report** — what just happened: the error, the transcript, the copy
///   confirmation, the outcome detail. Absent entirely when there is nothing to
///   report.
/// * **actions** — one floating primary, then ONE bordered container holding the
///   remaining commands as zero-gap rows closed by inset rules. Four
///   independently filled and stroked plates for four peer commands read as
///   "four unrelated objects"; a single container reads as "one list of
///   choices", and it leaves the primary as the only bounded, filled, tinted
///   object in the action region.
///
/// The standard popover owns its system glass chrome; content adds no second ground.
struct MenuView: View {
    var coordinator: DictationCoordinator
    private var a11y = A11y()
    @State private var didCopyTranscript = false
    @Environment(\.openWindow) private var openWindow

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        menuBehavior(menuContent)
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
            MenuStatusBlock(
                statusLabel: statusLabel,
                statusTone: statusTone,
                isSystemAudioMuted: coordinator.isSystemAudioMuted,
                headline: headline
            )
            if hasReport {
                MenuReportBlock(
                    text: coordinator.lastTranscript,
                    isCopied: $didCopyTranscript,
                    summary: reportedSummary,
                    link: reportLink,
                    openThread: openThread
                )
            }
            MenuActionBlock(
                isGated: isGated,
                dictationTitle: dictationTitle,
                dictationRowTitle: dictationRowTitle,
                dictationRowSystemImage: dictationRowSystemImage,
                startOrStopDictation: { coordinator.toggle() },
                takeNote: takeNote,
                failure: coordinator.lastFailure ?? coordinator.acquisitionFailure,
                retry: { coordinator.warmUpBackend() }
            )
        }
        .padding(VoiceourMetrics.Space.md)
        .frame(width: MenuLayout.popoverWidth, alignment: .topLeading)
        .task(id: acquisitionTaskID) {
            // The menu is where a first launch waits out a 1.26 GB download, so it
            // asks for health on open and keeps asking while an acquisition runs.
            // Without this the percentage only advanced when the user happened to
            // open the console's Settings tab.
            coordinator.refreshBackendHealth()
        }
    }

    /// Re-runs the health probe whenever an acquisition's progress changes, which is
    /// what keeps the percentage moving while the popover stays open.
    private var acquisitionTaskID: String {
        "\(coordinator.modelDownloadFraction ?? -1)-\(coordinator.isBackendWarming)"
    }

    private func menuBehavior<Content: View>(_ content: Content) -> some View {
        content
            .animation(transition, value: coordinator.state)
            .animation(transition, value: coordinator.lastTranscript)
            .animation(transition, value: coordinator.errorMessage)
            .animation(transition, value: coordinator.lastSavedNoteID)
            .animation(transition, value: reportLink)
            .animation(transition, value: didCopyTranscript)
            .onChange(of: coordinator.lastTranscript) {
                didCopyTranscript = false
            }
    }

    /// One state change used to shove the whole action stack down 115 pt in a
    /// single frame while the popover window resized under the pointer.
    private var transition: Animation? {
        a11y.reduceMotion ? nil : VoiceourMotion.standard
    }

    // MARK: Status

    /// The status block's second line: the failure, the model's own progress, or
    /// the future-tense target promise, in that order — never two at once. An error
    /// means the promise cannot be kept; a model that has not arrived yet means the
    /// promise cannot be kept either, and saying so is the difference between a
    /// download and a hang.
    private var headline: (text: String, color: Color?, progress: Double?)? {
        if let failure = coordinator.lastFailure ?? coordinator.acquisitionFailure {
            return (failure.cause, VoiceourPalette.Signal.crimson, nil)
        }
        if let error = coordinator.errorMessage {
            return (error, VoiceourPalette.Signal.crimson, nil)
        }
        if let acquisition = acquisitionHeadline {
            return (acquisition, VoiceourPalette.Signal.amber, coordinator.modelDownloadFraction)
        }
        guard reportedSummary == nil else { return nil }
        return (targetLine, nil, nil)
    }

    /// A note is delivered nowhere, so while one is in flight the promise names
    /// where it goes instead of the app that happens to have focus.
    private var targetLine: String {
        if coordinator.state.isActive, coordinator.captureIntent == .note {
            return "Will save as a note"
        }
        return coordinator.targetLabel
    }

    /// What the model is doing when it is not ready. Downloading reports its own
    /// bar; warming has no fraction to report, only a reason to wait.
    private var acquisitionHeadline: String? {
        if coordinator.modelDownloadFraction != nil {
            return "Downloading the speech model."
        }
        if coordinator.isBackendWarming {
            return "Loading the speech model…"
        }
        return nil
    }

    // MARK: Report

    private var hasReport: Bool {
        !coordinator.lastTranscript.isEmpty || reportedSummary != nil
    }

    /// The terminal outcome the chip and the detail line both read from.
    /// `DictationCoordinator` sets the matching terminal state and then hops to
    /// the next main-actor turn to reset it to `.idle`, so the state alone
    /// reports `IDLE` for a dictation that was never pasted.
    private var reportedOutcome: InsertionOutcome? {
        guard coordinator.errorMessage == nil, !coordinator.state.isActive else {
            return nil
        }
        return coordinator.lastOutcome
    }

    /// What the chip and the detail line report: the delivery outcome, else a
    /// saved note. `.noteSaved` lives one main-actor turn like the delivery
    /// states, so the note is read from `lastSavedNoteID`, which holds until the
    /// next start, under the same gate as the outcome.
    private var reportedSummary: InsertionOutcomeSummary? {
        if let outcome = reportedOutcome {
            return outcome.summary(in: coordinator.lastDeliveredApp)
        }
        guard coordinator.errorMessage == nil, !coordinator.state.isActive,
            coordinator.lastSavedNoteID != nil
        else {
            return nil
        }
        return .noteSaved
    }

    /// The thread the reported paste reached, or why it reached none. Read from
    /// the row the outcome belongs to, never from the newest row: a secure or
    /// empty delivery writes no row, so the newest can be an older dictation.
    /// Nil while the link is still resolving, and for every outcome that was not
    /// eligible to link in the first place.
    private var reportLink: MenuReportLink? {
        guard reportedOutcome == .pasteAttempted,
            coordinator.settings.agentSessionBindingEnabled,
            let rowID = coordinator.lastDeliveredRowID,
            let row = coordinator.recentSessions.first(where: { $0.id == rowID })
        else {
            return nil
        }
        if let binding = row.agentSession {
            return .thread(title: binding.displayTitle, key: binding.key)
        }
        return row.unlinked.map(MenuReportLink.unlinked)
    }

    /// Asks the console for the thread, then shows it the way the Open Console
    /// row does: `openWindow` creates the window on a launch where it does not
    /// exist yet, and ``ConsolePresentation`` shows one that already does. The
    /// console consumes the request on appear and on change, so it lands whether
    /// the window was closed, open on another tab, or already on the Journal.
    private func openThread(_ key: AgentSessionKey) {
        coordinator.pendingJournalThread = key
        openWindow(id: ConsolePresentation.windowID)
        ConsolePresentation.show()
    }

    // MARK: Actions

    private var isGated: Bool {
        coordinator.errorMessage != nil
    }

    /// Offered only between sessions and outside a gate: a session in flight
    /// offers its stop action alone, and a gated menu points at the console.
    private var takeNote: (() -> Void)? {
        guard !isGated, !coordinator.state.isActive else { return nil }
        return { coordinator.startNote() }
    }

    /// The primary capsule speaks the app's button voice; the same command
    /// demoted into the menu list speaks the list's sentence voice.
    private var dictationTitle: String {
        coordinator.state == .recording ? "STOP DICTATION" : "START DICTATION"
    }

    private var dictationRowTitle: String {
        coordinator.state == .recording ? "Stop Dictation" : "Start Dictation"
    }

    private var dictationRowSystemImage: String {
        coordinator.state == .recording ? "stop.fill" : "mic.fill"
    }

    // MARK: Status vocabulary

    /// Terminal outcomes name themselves. The three `SessionState` cases that
    /// used to supply those labels live for exactly one main-actor turn before
    /// `resetToIdleWhenInactive` flips them to `.idle`, so reading them here
    /// rendered `IDLE` over a dictation that had just failed to paste. A saved
    /// note names itself the same way, and `.noteSaved` falls to `IDLE` with them.
    ///
    /// An unacknowledged `errorMessage` is read the same way, and for the same
    /// reason: a microphone denial now returns to idle rather than parking the
    /// coordinator in `.error`, so the state enum no longer outlives the failure
    /// it describes. The headline above is gated on the same value, so the label
    /// and the reason appear together and clear together on the next `start()`.
    private var statusLabel: String {
        if let summary = reportedSummary {
            return summary.label
        }
        // The failure names itself: "MODEL NEEDED" and "MIC BLOCKED" say what to do
        // about it, where a bare "ERROR" makes the user open the console to find out.
        if let failure = coordinator.lastFailure ?? coordinator.acquisitionFailure {
            return failure.title
        }
        if coordinator.errorMessage != nil {
            return "ERROR"
        }
        if coordinator.modelDownloadFraction != nil || coordinator.isBackendWarming {
            return "PREPARING"
        }

        switch coordinator.state {
        case .recording:
            return "LIVE"
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            return "WORKING"
        case .error:
            return "ERROR"
        default:
            return "IDLE"
        }
    }

    /// Same lifetime as `statusLabel`, and the colour has to agree with the word.
    /// It reads the failure the same way, with one exception: while the model is
    /// still arriving, a refusal is amber rather than crimson, so "DOWNLOADING
    /// MODEL" is painted as the wait it is instead of as a fault.
    private var statusTone: Kit.Mark.Tone {
        if let summary = reportedSummary {
            switch summary.severity {
            case .crit: return .critical
            case .warn: return .caution
            case .ok: return .success
            case .neutral: return .neutral
            }
        }
        // A start refused because the model is still arriving is a wait, not a fault, so it
        // keeps the amber the chip already showed before the tap: nothing got worse by asking.
        // `acquisitionFailure` is excluded deliberately — a download that stopped IS a fault,
        // and it outranks the fraction that is still sitting in `backendHealth`.
        let acquiring = coordinator.modelDownloadFraction != nil || coordinator.isBackendWarming
        if acquiring && coordinator.acquisitionFailure == nil {
            return .caution
        }
        if coordinator.errorMessage != nil || coordinator.lastFailure != nil
            || coordinator.acquisitionFailure != nil
        {
            return .critical
        }
        if acquiring {
            return .caution
        }

        switch coordinator.state {
        case .error:
            return .critical
        case .recording, .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            return .live
        default:
            return .neutral
        }
    }
}
