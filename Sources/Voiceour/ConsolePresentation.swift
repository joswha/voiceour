import AppKit
import SwiftUI

/// Ownership of *showing* the console window.
///
/// `openWindow(id:)` creates the `Window("Voiceour", id: "main")` scene's window
/// and orders it front the first time. It is not a dependable way to put that
/// window back in front of a reader afterwards: a `Window` scene keeps one
/// `NSWindow` for the life of the process, and the one state that window cannot
/// leave by itself is miniaturized — `deminiaturize(_:)` is the only call that
/// undoes it, and nothing in SwiftUI ever makes it.
///
/// That matters more here than in an ordinary app, because this app's Dock icon
/// is not permanent: the console promotes the process to `.regular` while it is
/// open and drops back to `.accessory` when it closes, so the Dock tile a
/// minimized window is normally clicked back from can be taken away while the
/// window is still parked. Measured on a wedged instance: an 835×1084 console
/// whose only WindowServer surface was a 53×68 tile at (2830, 1011),
/// `AXMinimized` reporting false, `Window ▸ Voiceour` and `NSApp.activate` both
/// doing nothing — while dictation itself kept working, because the Fn tap never
/// needed a window. Quitting with the window minimized and relaunching
/// reproduced the other half: AppKit restored that state, so an idle
/// `.accessory` launch began with a `Voiceour` entry in its Window menu backed
/// by no surface and no accessibility attributes at all.
///
/// So presentation is owned in one place. Every path that shows the console
/// calls ``show()``, every path that stops hosting it calls ``windowDidClose()``,
/// and the two states the window has no way back from are taken away from it in
/// ``harden(_:)``.
@MainActor
enum ConsolePresentation {
    /// The scene id declared in ``VoiceourApp``, so `openWindow(id:)` callers
    /// spell it once.
    static let windowID = "main"

    /// Makes the console visible, front and focused.
    ///
    /// Callers invoke `openWindow(id:)` first — only a `View` can, and it is the
    /// only thing that can *create* the window. This is what makes an existing
    /// window appear. On the launch where the window does not exist yet the
    /// window half is a no-op and `ConsoleWindowView.onAppear` calls this again
    /// the moment SwiftUI hosts the content.
    static func show() {
        guard managesPresentation else { return }
        // `.accessory` (no Dock icon, absent from Cmd+Tab — see
        // VoiceourApp.init) is right for the idle menu-bar-only state, but this
        // console is a real window a reader expects to treat like a normal app
        // window: reachable via Cmd+Tab, not swallowed behind other windows with
        // no way back except re-clicking the menu bar icon.
        NSApp.setActivationPolicy(.regular)
        if let window = consoleWindow {
            harden(window)
            // Unconditional: the state this recovers from is one AppKit and the
            // WindowServer can disagree about, and it is documented to do
            // nothing to a window that is not miniaturized.
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// The console stopped being hosted — a real close, not a lost focus — so the
    /// app returns to its menu-bar-only state.
    static func windowDidClose() {
        guard managesPresentation else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Takes away the two states this window has no way back from. Idempotent,
    /// and applied on every show because SwiftUI owns the window's creation:
    /// this is the only moment it can be reached.
    ///
    /// * Miniaturizable. A minimized window is clicked back from its Dock tile,
    ///   and this app's tile exists only while the console is open. Nothing else
    ///   about the window changes: it still closes, zooms, resizes and remembers
    ///   its frame, and ⌘W plus the menu bar item stay the pair a reader already
    ///   uses to put it away and bring it back.
    /// * Restorable. AppKit's window restoration is what carried a parked window
    ///   across a quit into a launch that had no Dock icon to rescue it with.
    ///   The frame is *not* restoration — that is `setFrameAutosaveName`, whose
    ///   `NSWindow Frame main` entry is written and read independently — so the
    ///   console still opens where it was left.
    static func harden(_ window: NSWindow) {
        window.styleMask.remove(.miniaturizable)
        window.isRestorable = false
    }

    /// The app's one titled window. The menu popover, the recording panel and
    /// the offscreen harness's window are all borderless.
    ///
    /// Identifying it by style rather than by a probe view is measured, not
    /// taste: ``HistoryInputMonitor`` records what a zero-size
    /// `NSViewRepresentable` behind the content costs, which is one more
    /// accessibility group in every golden that contains it.
    static func isConsole(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
    }

    private static var consoleWindow: NSWindow? {
        NSApp.windows.first(where: isConsole)
    }

    /// False for the two callers that must never take the reader's screen: the
    /// offscreen UI harness, which pins `.prohibited` in
    /// `UIHarnessRuntime.prepareProcess()` and hosts the console view in a parked
    /// window, and any launch passing `--no-activate`. Both keep every branch
    /// above a no-op, so the harness cannot promote the app to `.regular`, cannot
    /// order a window front, and teardown cannot demote `.prohibited` to the
    /// self-activating `.accessory`. A normal user launch matches neither.
    private static var managesPresentation: Bool {
        !LaunchOptions.suppressActivation && NSApp.activationPolicy() != .prohibited
    }
}
