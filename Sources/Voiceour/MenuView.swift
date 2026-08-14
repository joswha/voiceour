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
/// * **report** — what just happened: the error, the transcript, the outcome
///   detail. Absent entirely when there is nothing to report.
/// * **actions** — one floating primary, then ONE bordered container holding the
///   remaining commands as zero-gap rows closed by inset rules. Four
///   independently filled and stroked plates for four peer commands read as
///   "four unrelated objects"; a single container reads as "one list of
///   choices", and it leaves the primary as the only bounded, filled, tinted
///   object in the action region.
///
/// On macOS 26 the standard popover owns its system glass chrome. The legacy
/// path paints one opaque rounded ground after clearing the host window so it
/// never stacks a second rounded rectangle inside AppKit's popover shape.
struct MenuView: View {
    var coordinator: DictationCoordinator
    private var a11y = A11y()
    @State private var didCopyTranscript = false

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26, *) {
            if RenderOverrides.forceLegacyGlass {
                legacyBody
            } else {
                menuBehavior(menuContent)
            }
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        menuBehavior(
            menuContent
                .background { popoverGround }
                .clipShape(MenuLayout.popoverShape)
                .background { PopoverChromeConfigurator() }
        )
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
            MenuStatusBlock(
                statusLabel: statusLabel,
                statusMode: statusMode,
                isSystemAudioMuted: coordinator.isSystemAudioMuted,
                headline: headline
            )
            if hasReport {
                MenuReportBlock(
                    text: coordinator.lastTranscript,
                    isCopied: $didCopyTranscript,
                    summary: reportedOutcome?.summary
                )
            }
            MenuActionBlock(
                isGated: isGated,
                dictationTitle: dictationTitle,
                dictationRowTitle: dictationRowTitle,
                savedSessionCountText: savedSessionCountText,
                startOrStopDictation: { coordinator.toggle() }
            )
        }
        .padding(VoiceourMetrics.Space.md)
        .frame(width: MenuLayout.popoverWidth, alignment: .topLeading)
    }

    private func menuBehavior<Content: View>(_ content: Content) -> some View {
        content
            .animation(transition, value: coordinator.state)
            .animation(transition, value: coordinator.lastTranscript)
            .animation(transition, value: coordinator.errorMessage)
            .onChange(of: coordinator.lastTranscript) {
                didCopyTranscript = false
            }
    }

    /// One state change used to shove the whole action stack down 115 pt in a
    /// single frame while the popover window resized under the pointer.
    private var transition: Animation? {
        a11y.reduceMotion ? nil : VoiceourMotion.standard
    }

    // MARK: Ground

    private var popoverGround: some View {
        MenuLayout.popoverShape
            .fill(VoiceourPalette.Ink.void)
            .overlay {
                MenuLayout.popoverShape
                    .strokeBorder(
                        a11y.lineEdge,
                        lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    )
            }
    }

    // MARK: Status

    /// The status block's second line: the error, or the future-tense target
    /// promise, never both. An error means the promise cannot be kept, and a
    /// finished outcome means it is already spent and reported in the past
    /// tense below — a promise stacked on a report about the same target, in
    /// opposite tenses, is the surface not knowing its own state.
    private var headline: (text: String, color: Color?)? {
        if let error = coordinator.errorMessage {
            return (error, VoiceourPalette.Signal.crimson)
        }
        guard reportedOutcome == nil else { return nil }
        return (coordinator.targetLabel, nil)
    }

    // MARK: Report

    private var hasReport: Bool {
        !coordinator.lastTranscript.isEmpty || reportedOutcome != nil
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

    // MARK: Actions

    private var isGated: Bool {
        coordinator.errorMessage != nil
    }

    /// The primary capsule speaks the app's button voice; the same command
    /// demoted into the menu list speaks the list's sentence voice.
    private var dictationTitle: String {
        coordinator.state == .recording ? "STOP DICTATION" : "START DICTATION"
    }

    private var dictationRowTitle: String {
        coordinator.state == .recording ? "Stop Dictation" : "Start Dictation"
    }

    // MARK: Status vocabulary

    /// Terminal outcomes name themselves. The three `SessionState` cases that
    /// used to supply those labels live for exactly one main-actor turn before
    /// `resetToIdleWhenInactive` flips them to `.idle`, so reading them here
    /// rendered `IDLE` over a dictation that had just failed to paste.
    ///
    /// An unacknowledged `errorMessage` is read the same way, and for the same
    /// reason: a microphone denial now returns to idle rather than parking the
    /// coordinator in `.error`, so the state enum no longer outlives the failure
    /// it describes. The headline above is gated on the same value, so the label
    /// and the reason appear together and clear together on the next `start()`.
    private var statusLabel: String {
        if let summary = reportedOutcome?.summary {
            return summary.label
        }
        if coordinator.errorMessage != nil {
            return "ERROR"
        }

        switch coordinator.state {
        case .recording:
            return "LIVE"
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
            return "WORKING"
        case .error:
            return "ERROR"
        default:
            return "IDLE"
        }
    }

    /// Same lifetime as `statusLabel`: the chip's colour has to agree with its
    /// word, so both read `errorMessage` before falling through to the state.
    private var statusMode: StatusChip.Mode {
        if let summary = reportedOutcome?.summary {
            switch summary.severity {
            case .crit: return .crit
            case .warn: return .warn
            case .ok: return .ok
            case .neutral: return .neutral
            }
        }
        if coordinator.errorMessage != nil {
            return .crit
        }

        switch coordinator.state {
        case .error:
            return .crit
        case .recording, .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
            return .live
        default:
            return .neutral
        }
    }

    private var savedSessionCountText: String {
        let count = coordinator.recentSessions.count
        return count == 1 ? "1 SAVED SESSION" : "\(count) SAVED SESSIONS"
    }
}
