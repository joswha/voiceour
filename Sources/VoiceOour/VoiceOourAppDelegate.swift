import AppKit
import Darwin
import VoiceMac

/// Internal rather than private: `VoicePane`'s restart action reaches the
/// live delegate through `VoiceOourAppDelegate.shared`. That pane receives
/// only the coordinator today, and threading a delegate reference through
/// `ConsoleView` for one action is not worth the signature churn.
@MainActor
final class VoiceOourAppDelegate: NSObject, NSApplicationDelegate {
    /// `@NSApplicationDelegateAdaptor` does **not** install this object as
    /// `NSApp.delegate`: SwiftUI installs its own `SwiftUI.AppDelegate` there
    /// and forwards the callbacks on. `NSApp.delegate as? VoiceOourAppDelegate`
    /// is therefore always nil, which silently disabled every pane action that
    /// reached for it. Set from `applicationDidFinishLaunching`, the one place
    /// that is guaranteed to run on the instance AppKit is actually talking to.
    private(set) static weak var shared: VoiceOourAppDelegate?

    weak var coordinator: DictationCoordinator?
    private var isRestarting = false
    private let applicationRelauncher: ApplicationRelaunching = ProcessApplicationRelauncher(
        executableURL: URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    )
    private var isTerminatingAfterCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        guard LaunchOptions.showConsoleOnLaunch else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceOourShowConsole, object: nil)
        }
    }

    /// Applies a saved backend switch without asking the user to quit and
    /// relaunch the app manually. The successor inherits the launch context
    /// needed by development and bundled runs, but not a stale backend
    /// override that would win over the newly saved setting.
    func restartApplication() {
        guard !isRestarting else { return }
        guard let coordinator, !coordinator.state.isActive else { return }

        isRestarting = true

        Task { @MainActor in
            await coordinator.prepareForTermination()
            do {
                try applicationRelauncher.launch(
                    arguments: Self.restartArguments(),
                    environment: Self.restartEnvironment()
                )
                Darwin.exit(0)
            } catch {
                isRestarting = false
                fputs("VoiceOour restart failed: \(error)\n", stderr)
            }
        }
    }

    /// Removes command-line backend selection so the successor resolves the
    /// backend from the setting the user just changed. Keeping the console
    /// open makes the restart feel like applying a setting, not losing the
    /// user in the menu bar.
    static func restartArguments(from arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> [String] {
        var result: [String] = []
        var skippingBackendValue = false

        for argument in arguments {
            if skippingBackendValue {
                skippingBackendValue = false
                continue
            }
            if argument == "--asr-backend" {
                skippingBackendValue = true
                continue
            }
            if argument.hasPrefix("--asr-backend=") {
                continue
            }
            result.append(argument)
        }

        if !result.contains("--show-console") {
            result.append("--show-console")
        }
        return result
    }

    static func restartEnvironment(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String:
        String]
    {
        var result = environment
        result.removeValue(forKey: "VOICEOOUR_ASR_BACKEND")
        return result
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingAfterCleanup {
            return .terminateNow
        }

        guard let coordinator else { return .terminateNow }

        isTerminatingAfterCleanup = true
        Task { @MainActor in
            await coordinator.prepareForTermination()
            Darwin.exit(0)
        }
        return .terminateLater
    }
}
