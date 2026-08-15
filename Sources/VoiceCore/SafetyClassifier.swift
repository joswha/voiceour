/// What a target-focus inspection could establish about the focused element.
///
/// Three outcomes, not two. "We looked and it was an ordinary field", "we could
/// not look", and "the app answered: nothing has keyboard focus" are different
/// facts, and collapsing any pair of them is a bug in one direction or the
/// other. Collapsing the first two classifies an unreadable focus as pasteable
/// normal text. Collapsing the last two — which this type used to do — makes
/// every Electron app copy-only the moment its composer is not already focused,
/// on the theory that a password field might be hiding behind the silence.
///
/// Measured on Discord 2026-08-10: `kAXFocusedUIElement` returns `AXTextArea`
/// while the composer holds focus and `kAXErrorNoValue` when nothing does, with
/// `kAXFocusedWindow` succeeding throughout. The tree is readable; there is
/// simply nothing focused in it, and nothing focused cannot be a password field
/// taking keystrokes. `IsSecureEventInputEnabled()` remains the backstop for the
/// case where an app focuses a secure field without exposing it.
public enum TargetFocusInspection: Equatable, Sendable {
    case inspected(role: String?, subrole: String?)
    /// The app answered `kAXErrorNoValue`: no element holds keyboard focus.
    case noFocusedElement
    /// The lookup could not be performed or the app did not answer.
    case unavailable
}

public enum SafetyClassifier {
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "dev.warp.Warp-Stable",
    ]

    static let codeEditorBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "dev.zed.Zed",
    ]

    static let secureBundleIds: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    /// Maps a target to its insertion-safety class.
    ///
    /// Precedence: active system secure input wins; then a secure AX role; then a
    /// known secure/terminal/code-editor bundle; then an unavailable inspection,
    /// which is `.unknownRisky` — copy-only by default. Failing open there would
    /// classify a password field whose focus lookup failed as ordinary pasteable
    /// text.
    ///
    /// `.noFocusedElement` deliberately does not reach that guard: the app was
    /// readable and reported an empty focus, which is evidence, not the absence
    /// of it.
    ///
    /// A readable element whose role *and* subrole both come back nil is a third
    /// case, and it reaches `.normalText`. That is deliberate and it is covered
    /// rather than overlooked: an AX role lookup can fail on a perfectly
    /// ordinary text field, so failing closed here would degrade routine
    /// dictation to copy-only across whole applications, while the field this
    /// would be protecting is already caught one line below by
    /// `secureInputActive`. Secure entry is a system-level signal that a
    /// password field raises whether or not AX will describe it, which is the
    /// entire reason that check exists and leads this precedence.
    public static func classify(
        bundleId: String?,
        focus: TargetFocusInspection,
        secureInputActive: Bool = false
    ) -> TargetSafetyClass {
        if secureInputActive { return .secure }
        if case .inspected(let role, let subrole) = focus,
            subrole == "AXSecureTextField" || role == "AXSecureTextField"
        {
            return .secure
        }
        guard let bundleId else { return .unknownRisky }
        if secureBundleIds.contains(bundleId) { return .secure }
        if terminalBundleIds.contains(bundleId) { return .terminal }
        if codeEditorBundleIds.contains(bundleId) || bundleId.hasPrefix("com.jetbrains.") { return .codeEditor }
        if focus == .unavailable { return .unknownRisky }
        return .normalText
    }
}
