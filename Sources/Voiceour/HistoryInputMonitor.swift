import AppKit
import SwiftUI

/// The History tab's two AppKit-only inputs: a click beside the form's content
/// column, which closes the open transcript, and the keys that act on it —
/// Escape to close, Command-T to teach the current text selection.
///
/// This exists because SwiftUI cannot see either. A grouped `Form` on macOS is an
/// `NSScrollView`, and it consumes every click that lands in the empty margin
/// beside its plates: measured in the shipping app, neither `.onTapGesture` on the
/// form, nor the same gesture on a `Color.clear` background behind it, nor
/// `.onExitCommand` on the form ever fired — not for a margin click, not for a
/// click on a non-interactive row inside a plate, and not for Escape. AppKit is the
/// only layer left that still sees them. Command-T joins them because the tab has
/// no button to hang a `.keyboardShortcut` on: teaching is a text gesture now.
///
/// The click test is horizontal only. `NSEvent.locationInWindow` is bottom-left and
/// SwiftUI's global space is top-left, but both share the window's left edge, so
/// matching on x needs no flip and cannot silently invert. `contentLayoutRect`
/// keeps the title bar and the tab strip out of it.
@MainActor
final class HistoryInputMonitor {
    /// The x range of the form's plates, in window coordinates. Nil until the tab
    /// has laid out, which is also the only state in which no click can deselect.
    var columnX: ClosedRange<CGFloat>?

    /// True while the teach editor is open, so Escape reaches its own cancel first
    /// rather than closing the transcript being taught from.
    var defersEscape = false

    var onDeselect: (() -> Void)?
    var onTeach: (() -> Void)?

    private var clickMonitor: Any?
    private var keyMonitor: Any?

    /// Installed while the tab is on screen and removed when it leaves, so no other
    /// tab pays for a monitor it cannot use.
    func start() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleClick(event)
                return event
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handleKey(event) else { return event }
                return nil
            }
        }
    }

    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    private func handleClick(_ event: NSEvent) {
        guard let columnX, let window = event.window, isConsole(window) else { return }
        let point = event.locationInWindow
        guard window.contentLayoutRect.contains(point), !columnX.contains(point.x) else { return }
        onDeselect?()
    }

    /// Returns true when the key was consumed. Escape closes the transcript,
    /// Command-T teaches from it, and every other key — plus Escape while the teach
    /// editor owns it — is passed on untouched.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, isConsole(window) else { return false }
        if event.keyCode == 17, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onTeach?()
            return true
        }
        guard event.keyCode == 53, !defersEscape else { return false }
        onDeselect?()
        return true
    }

    /// The console is the app's only titled window — the menu popover and the
    /// recording panel are borderless — and this monitor exists only while the
    /// History tab is on screen. Identifying the window by style beats naming it
    /// through a probe view: a zero-size `NSViewRepresentable` behind the form made
    /// SwiftUI wrap the entire tab in one more accessibility group, which every
    /// History golden then had to carry.
    private func isConsole(_ window: NSWindow) -> Bool {
        window.isKeyWindow && window.styleMask.contains(.titled)
    }
}
