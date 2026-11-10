import AppKit
import SwiftUI
import VoiceCore

struct MenuActionBlock: View {
    let isGated: Bool
    let dictationTitle: String
    let dictationRowTitle: String
    /// The glyph the dictation row's badge draws, in step with its title.
    let dictationRowSystemImage: String
    let startOrStopDictation: () -> Void
    /// Starts a recording that is saved as a note, or nil while a session is in
    /// flight: a recording offers its stop action and nothing else.
    let takeNote: (() -> Void)?
    /// The failure the rows offer a way out of, when there is one.
    let failure: UserFacingDictationFailure?
    let retry: () -> Void

    @Environment(\.openWindow) private var openWindow
    private var a11y = A11y()

    init(
        isGated: Bool,
        dictationTitle: String,
        dictationRowTitle: String,
        dictationRowSystemImage: String,
        startOrStopDictation: @escaping () -> Void,
        takeNote: (() -> Void)? = nil,
        failure: UserFacingDictationFailure? = nil,
        retry: @escaping () -> Void = {}
    ) {
        self.isGated = isGated
        self.dictationTitle = dictationTitle
        self.dictationRowTitle = dictationRowTitle
        self.dictationRowSystemImage = dictationRowSystemImage
        self.startOrStopDictation = startOrStopDictation
        self.takeNote = takeNote
        self.failure = failure
        self.retry = retry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            primaryAction
            commandGroup
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
                MenuCommandRow(title: "Try Again", systemImage: "arrow.clockwise", closingRule: true) { retry() }
            } else if let failure, failure.destination == .systemSettings {
                MenuCommandRow(
                    title: "Open System Settings",
                    systemImage: "gearshape.fill",
                    accessory: .chevron,
                    closingRule: true
                ) {
                    PrivacySettings.microphone.open()
                }
            }

            if isGated {
                MenuCommandRow(title: dictationRowTitle, systemImage: dictationRowSystemImage, closingRule: true) {
                    startOrStopDictation()
                }
            } else {
                // A note records through the same microphone and model as a
                // dictation, so beside a failure's remedy it would buy the same
                // failure; leaving it out there also keeps the container at the
                // three rows the popover's height was measured for.
                if let takeNote, !offersFailureRemedy {
                    MenuCommandRow(title: "Take a Note", systemImage: "note.text", closingRule: true) { takeNote() }
                        .accessibilityIdentifier("menu.take-note")
                }
                MenuCommandRow(title: "Open Console", systemImage: "macwindow", accessory: .chevron, closingRule: true)
                {
                    openConsole()
                }
            }

            MenuCommandRow(title: "Quit", systemImage: "power", accessory: .keys("⌘Q")) {
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

    /// Whether the container opens with a row that leads out of `failure`.
    private var offersFailureRemedy: Bool {
        guard let failure else { return false }
        return failure.isRetryable || failure.destination == .systemSettings
    }

    /// `openWindow` creates the window on the launch where it does not exist yet;
    /// ``ConsolePresentation`` is what shows one that already does.
    private func openConsole() {
        openWindow(id: ConsolePresentation.windowID)
        ConsolePresentation.show()
    }
}
