import AppKit
import SwiftUI

struct MenuActionBlock: View {
    let isGated: Bool
    let dictationTitle: String
    let dictationRowTitle: String
    let savedSessionCountText: String
    let startOrStopDictation: () -> Void

    @Environment(\.openWindow) private var openWindow
    private var a11y = A11y()

    init(
        isGated: Bool,
        dictationTitle: String,
        dictationRowTitle: String,
        savedSessionCountText: String,
        startOrStopDictation: @escaping () -> Void
    ) {
        self.isGated = isGated
        self.dictationTitle = dictationTitle
        self.dictationRowTitle = dictationRowTitle
        self.savedSessionCountText = savedSessionCountText
        self.startOrStopDictation = startOrStopDictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            primaryAction
            commandGroup

            Text(savedSessionCountText)
                .roleStyle(.micro)
        }
    }

    /// The popover's one floating action, and in a gated state it points at the
    /// thing that can actually succeed. Re-pressing a primary-styled
    /// `Start Dictation` under a closed permission gate buys the user a second
    /// identical failure; the console is where every gate and every backend
    /// fault is diagnosed and cleared. Start stays reachable one row below, so
    /// the slot count and the layout do not move between states.
    private var primaryAction: some View {
        Button(action: isGated ? openConsole : startOrStopDictation) {
            Text(isGated ? "OPEN CONSOLE" : dictationTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionButtonStyle())
    }

    private var commandGroup: some View {
        VStack(spacing: 0) {
            if isGated {
                MenuCommandRow(title: dictationRowTitle, closingRule: true) {
                    startOrStopDictation()
                }
            } else {
                MenuCommandRow(title: "Open Console", accessory: .chevron, closingRule: true) {
                    openConsole()
                }
            }

            MenuCommandRow(title: "Quit", accessory: .keys("⌘Q")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .clipShape(MenuLayout.innerShape)
        .overlay {
            MenuLayout.innerShape
                .strokeBorder(
                    a11y.lineControl,
                    lineWidth: VoiceOourMetrics.Stroke.hairline(a11y.contrast)
                )
        }
    }

    private func openConsole() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
