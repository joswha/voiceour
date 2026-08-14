import AppKit
import SwiftUI

struct ConsoleView: View {
    var coordinator: DictationCoordinator
    @State private var section: ConsoleSection

    init(coordinator: DictationCoordinator, initialSection: ConsoleSection = .home) {
        self.coordinator = coordinator
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        ConsoleScaffold(section: $section, coordinator: coordinator)
            .background(WindowChromeConfigurator())
            .environment(\.colorScheme, .dark)
            .onAppear {
                // `.accessory` (no Dock icon, absent from Cmd+Tab — see
                // VoiceourApp.init) is right for the idle menu-bar-only
                // state, but this console is a real 1280x860 window a user
                // expects to treat like a normal app window: reachable via
                // Cmd+Tab, not swallowed behind other windows with no way
                // back except re-clicking the menu bar icon. Promote to
                // `.regular` for as long as this window is open; `onDisappear`
                // drops back to `.accessory` once it actually closes.
                guard ConsoleView.managesActivationPolicy else { return }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                guard ConsoleView.managesActivationPolicy else { return }
                NSApp.setActivationPolicy(.accessory)
            }
    }

    /// False for the two callers that must never take the user's screen: the offscreen
    /// UI harness, which pins `.prohibited` in `UIHarnessRuntime.prepareProcess()` and
    /// hosts this very view offscreen, and any launch passing `--no-activate`. Both
    /// branches above are no-ops then, so the harness cannot promote the app to
    /// `.regular`, and teardown cannot demote `.prohibited` to the self-activating
    /// `.accessory`. A normal user launch matches neither and behaves as before.
    @MainActor
    private static var managesActivationPolicy: Bool {
        !LaunchOptions.suppressActivation && NSApp.activationPolicy() != .prohibited
    }
}
