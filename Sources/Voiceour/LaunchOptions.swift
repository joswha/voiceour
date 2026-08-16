import Darwin
import Foundation
import VoiceCore
import VoiceMac

enum LaunchOptions {
    static var showConsoleOnLaunch: Bool {
        CommandLine.arguments.contains("--show-console")
    }

    /// `--no-activate` stops the console window from promoting the app to `.regular`
    /// and calling `NSApp.activate` in `ConsoleWindowView.onAppear`. `scripts/console_shot.sh`
    /// passes it to shrink its focus blip; it cannot remove it, because the window still
    /// has to be onscreen to be screenshotted and the show-console notification handler
    /// in `MenuBarLabel.body`'s `.onReceive` (`MenuBarLabel.swift`) still activates. The offscreen UI harness needs no flag at all — it is
    /// covered by the `.prohibited` branch of the same guard. A normal user launch never
    /// passes this, so clicking the menu bar item still hands over a focused window.
    static var suppressActivation: Bool {
        CommandLine.arguments.contains("--no-activate")
    }

    /// Reveals the development-only backend picker on the General tab — the one
    /// control that can switch dictation to the synthetic `fake` recogniser. A
    /// launch argument rather than a setting: it configures how the install is
    /// developed, not anything a shipped user has a reason to choose, and a
    /// release user who found it could only downgrade their own dictation.
    static var showsDebugPanes: Bool {
        CommandLine.arguments.contains("--debug")
    }

    /// The tab the console window is forced to open on. `--console-section=`
    /// keeps its spelling: it is a development deep link that predates the tabs,
    /// and nothing outside this app types it. Nil when the flag is absent OR
    /// names an unknown tab — junk used to fall back to `.general`; now junk
    /// means "no override" and the stored last-used tab wins.
    static var consoleSectionOverride: ConsoleTab? {
        consoleSectionOverride(in: CommandLine.arguments)
    }

    /// Split from the `var` so the parse is testable without forging argv.
    static func consoleSectionOverride(in arguments: [String]) -> ConsoleTab? {
        arguments
            .first { $0.hasPrefix("--console-section=") }
            .flatMap { ConsoleTab(rawValue: String($0.dropFirst("--console-section=".count))) }
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
