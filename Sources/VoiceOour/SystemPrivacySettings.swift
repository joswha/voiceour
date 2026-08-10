import AppKit

/// The two System Settings privacy panes this surface links to. One spelling
/// each, so two rows reporting the same grant cannot drift to two URLs.
///
/// There is no Automation entry. Insertion used to deep-link there, but nothing
/// in this app drives paste through AppleScript: `PasteboardInserter` posts a
/// synthetic Cmd-V with `CGEvent`, and `SystemPermissions.synthPaste()` reads
/// `CGPreflightPostEventAccess() || AXIsProcessTrusted()`. Both are the
/// Accessibility grant, so Automation was a link to a pane that could never
/// clear the warning it was offered for.
enum PrivacySettings: String {
    case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    func open() {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
