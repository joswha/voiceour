import Foundation

/// What may be done with dictated text for a given target.
public enum InsertionDisposition: Equatable, Sendable {
    /// Write the pasteboard and post Cmd-V.
    case paste
    /// Write the pasteboard only, carrying the reason the paste was refused.
    case copyOnly(reason: String)
}

/// The one place that decides whether dictated text may be pasted.
///
/// After the fail-closed work the decision spanned four places: `SafetyClassifier`
/// mapping a target to a class, `WorkspaceTargetTracker` deciding what counts as
/// the same target, coordinator snapshot timing, and `PasteboardInserter`. This
/// owns the class-to-disposition mapping and the reason strings; the inserter is
/// the mechanism.
///
/// Not configurable, in either direction. A "paste everywhere" switch would turn a
/// password field into a one-toggle mistake, and there is no legitimate caller for
/// one: `.normalText` pastes, everything else is copy-only, full stop.
public enum InsertionSafetyPolicy: Sendable {
    /// Reason emitted when the captured class itself forbids pasting.
    public static func targetClassReason(_ safety: TargetSafetyClass) -> String {
        "target_\(safety.rawValue)"
    }

    /// Reason emitted when the target changed between capture and delivery.
    public static let targetChangedBeforeCopy = "target_changed_before_copy"
    /// Reason emitted when the target changed after the pasteboard write.
    public static let targetChangedAfterCopy = "target_changed_after_copy"
    /// Reason emitted when synthetic-paste permission is unavailable.
    public static let missingSynthPastePermission = "synth_paste_permission"
    /// Reason emitted when Cmd-V could not be posted after the write. The
    /// clipboard already carries the text, so this is copy-only, not a failure.
    public static let postEventFailed = "post_event_failed"
    /// Reason emitted when the task was cancelled after the pasteboard write.
    public static let cancelledAfterCopy = "cancelled_after_copy"

    /// Whether a class may receive synthetic Cmd-V.
    ///
    /// `.normalText` is the only class that may be pasted into. Everything else
    /// is copy-only, including `.unknownRisky`.
    ///
    /// There is deliberately no parameter to loosen this. An earlier version let
    /// the caller opt `.unknownRisky` into pasting; nothing in the app ever did,
    /// but the knob contradicted the rule stated in AGENTS.md and became actively
    /// dangerous once a failed AX inspection started classifying as
    /// `.unknownRisky` — that class now includes "we were trusted to look and the
    /// focused-element lookup failed", which can be a password field. Absent
    /// information is not evidence that pasting is safe.
    public static func disposition(for safety: TargetSafetyClass) -> InsertionDisposition {
        switch safety {
        case .secure, .terminal, .codeEditor, .unknownRisky:
            .copyOnly(reason: targetClassReason(safety))
        case .normalText:
            .paste
        }
    }

    /// Whether a copied command should have exactly one trailing newline stripped.
    ///
    /// A trailing newline executes a pasted command. Unknown-risky targets get
    /// the terminal treatment because the app could not rule out a shell.
    public static func stripsTrailingNewline(for safety: TargetSafetyClass) -> Bool {
        safety == .terminal || safety == .unknownRisky
    }
}
