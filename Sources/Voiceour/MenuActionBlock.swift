import AppKit
import SwiftUI
import VoiceCore

struct MenuActionBlock: View {
    let isGated: Bool
    let dictationTitle: String
    let dictationRowTitle: String
    let savedSessionCountText: String
    let startOrStopDictation: () -> Void
    /// The failure the rows offer a way out of, when there is one.
    let failure: UserFacingDictationFailure?
    let retry: () -> Void

    @Environment(\.openWindow) private var openWindow
    private var a11y = A11y()

    init(
        isGated: Bool,
        dictationTitle: String,
        dictationRowTitle: String,
        savedSessionCountText: String,
        startOrStopDictation: @escaping () -> Void,
        failure: UserFacingDictationFailure? = nil,
        retry: @escaping () -> Void = {}
    ) {
        self.isGated = isGated
        self.dictationTitle = dictationTitle
        self.dictationRowTitle = dictationRowTitle
        self.savedSessionCountText = savedSessionCountText
        self.startOrStopDictation = startOrStopDictation
        self.failure = failure
        self.retry = retry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
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
            // A failure the user can act on gets its own row, pointing where the
            // remedy actually is: a retry for a model that has to finish arriving,
            // System Settings for a permission this app cannot grant itself.
            if let failure, failure.isRetryable, failure.destination != .systemSettings {
                MenuCommandRow(title: "Try Again", closingRule: true) { retry() }
            } else if let failure, failure.destination == .systemSettings {
                MenuCommandRow(title: "Open System Settings", accessory: .chevron, closingRule: true) {
                    PrivacySettings.microphone.open()
                }
            }

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
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
        }
    }

    /// `openWindow` creates the window on the launch where it does not exist yet;
    /// ``ConsolePresentation`` is what shows one that already does.
    private func openConsole() {
        openWindow(id: ConsolePresentation.windowID)
        ConsolePresentation.show()
    }
}
