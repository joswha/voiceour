import AppKit
import Testing

@testable import Voiceour

/// The console window is created by SwiftUI, so the only contract this app can
/// hold it to is what ``ConsolePresentation`` does to it on every show: identify
/// it, and take away the two states it has no way back from. A miniaturized
/// window is clicked back from a Dock tile this app only has while the console is
/// open, and window restoration is what carried that parked state across a quit
/// into a launch with no tile at all.
@Suite("Console presentation")
@MainActor
struct ConsolePresentationTests {
    private func titledWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
    }

    @Test func hardeningRemovesMinimizeAndRestorationAndNothingElse() {
        let window = titledWindow()
        window.isRestorable = true

        ConsolePresentation.harden(window)

        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(!window.isRestorable)
        // ⌘W and the zoom/resize a reader already uses are untouched: only the
        // affordance with no way back is gone.
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func hardeningIsIdempotent() {
        let window = titledWindow()

        ConsolePresentation.harden(window)
        let once = window.styleMask
        ConsolePresentation.harden(window)

        #expect(window.styleMask == once)
        #expect(!window.isRestorable)
    }

    /// The identification rule the presenter and ``HistoryInputMonitor`` share:
    /// the console is the app's one titled window. The menu popover, the
    /// recording panel and the offscreen harness's window are all borderless, so
    /// none of them can be mistaken for it and hardened, ordered front, or
    /// deminiaturized.
    @Test func onlyTheTitledWindowIsTheConsole() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        let harnessLike = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 835, height: 1084),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )

        #expect(ConsolePresentation.isConsole(titledWindow()))
        #expect(!ConsolePresentation.isConsole(panel))
        #expect(!ConsolePresentation.isConsole(harnessLike))
    }

    /// One spelling of the scene id, shared by the scene that declares the window
    /// and by every `openWindow(id:)` that asks for it.
    @Test func sceneIdentifierIsSpelledOnce() {
        #expect(ConsolePresentation.windowID == "main")
    }
}
