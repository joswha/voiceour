import Darwin
import Foundation
import VoiceCore
import VoiceMac

enum LaunchOptions {
    static var showConsoleOnLaunch: Bool {
        CommandLine.arguments.contains("--show-console")
    }

    /// `--no-activate` stops the console window from promoting the app to `.regular`
    /// and calling `NSApp.activate` in `ConsoleView.onAppear`. `scripts/console_shot.sh`
    /// passes it to shrink its focus blip; it cannot remove it, because the window still
    /// has to be onscreen to be screenshotted and the show-console notification handler
    /// in `MenuBarLabel.body`'s `.onReceive` (`MenuBarLabel.swift`) still activates. The offscreen UI harness needs no flag at all — it is
    /// covered by the `.prohibited` branch of the same guard. A normal user launch never
    /// passes this, so clicking the menu bar item still hands over a focused window.
    static var suppressActivation: Bool {
        CommandLine.arguments.contains("--no-activate")
    }

    /// Reveals the machine-facing panes (`ConsolePaneRailPlacement.debug`) in the
    /// rail. A launch argument rather than a setting: these panes report on the
    /// install, not on anything the user configures, and a shipped user should never
    /// be one mis-click away from a page of paths and probe evidence.
    static var showsDebugPanes: Bool {
        CommandLine.arguments.contains("--debug")
    }

    static var consoleSection: ConsoleSection {
        CommandLine.arguments
            .first { $0.hasPrefix("--console-section=") }
            .flatMap { ConsoleSection(rawValue: String($0.dropFirst("--console-section=".count))) } ?? .sessions
    }
}

extension Notification.Name {
    static let voiceourShowConsole = Notification.Name("voiceourShowConsole")
}

enum VoiceourSelfTest {
    static func run() -> Bool {
        let cleaned = CleanupEngine.clean(
            "um the the API is at https://x.io/v1 --port 8080", glossary: VoiceCore.Settings.defaultGlossary)
        guard cleaned == "the API is at https://x.io/v1 --port 8080" else {
            fputs("cleanup self-test failed: \(cleaned)\n", stderr)
            return false
        }
        let terminalFocus = TargetFocusInspection.inspected(role: nil, subrole: nil)
        guard SafetyClassifier.classify(bundleId: "com.apple.Terminal", focus: terminalFocus) == .terminal else {
            fputs("safety self-test failed\n", stderr)
            return false
        }
        print("Voiceour self-test passed")
        return true
    }
}
