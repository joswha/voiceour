import AppKit
import Darwin
import VoiceCore
import VoiceMac

/// Internal rather than private: the console's restart action reaches the live
/// delegate through `VoiceourAppDelegate.shared`. The General tab receives only
/// the coordinator, and threading a delegate reference through the window for one
/// action is not worth the signature churn.
@MainActor
final class VoiceourAppDelegate: NSObject, NSApplicationDelegate {
    /// `@NSApplicationDelegateAdaptor` does **not** install this object as
    /// `NSApp.delegate`: SwiftUI installs its own `SwiftUI.AppDelegate` there
    /// and forwards the callbacks on. `NSApp.delegate as? VoiceourAppDelegate`
    /// is therefore always nil, which silently disabled every pane action that
    /// reached for it. Set from `applicationDidFinishLaunching`, the one place
    /// that is guaranteed to run on the instance AppKit is actually talking to.
    private(set) static weak var shared: VoiceourAppDelegate?

    weak var coordinator: DictationCoordinator?
    private var isRestarting = false
    private let applicationRelauncher = ProcessApplicationRelauncher(
        executableURL: URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    )
    private var isTerminatingAfterCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu item, hotkey tap and sidecar all have process-wide effects;
        // a duplicate must leave before any launch setup can claim them.
        guard !Self.terminateIfDuplicateApplication() else { return }
        Self.shared = self

        guard LaunchOptions.showConsoleOnLaunch || owesFirstRunGuidance else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceourShowConsole, object: nil)
        }
    }

    /// Whether this launch should open the console because the install has never
    /// completed a dictation. A menu-bar app's entire first-run surface is one
    /// glyph, which cannot state the gesture, the model download or which grants
    /// matter; Home's first-run card can, and this is what puts it in front of a
    /// reader who has no reason to go looking for it.
    ///
    /// Four things keep the offscreen UI harness out of this, and the first two are
    /// structural rather than conditional:
    ///
    /// 1. `--ui-harness` exits the process inside `VoiceourApp.init()`, before
    ///    SwiftUI finishes launching, so this callback never runs at all.
    /// 2. The harness is compiled only under `-DUI_HARNESS` and never installs this
    ///    delegate, so `coordinator` is nil and the check below is false anyway.
    /// 3. The policy guard: the harness pins `.prohibited` in
    ///    `UIHarnessRuntime.prepareProcess()`, and a prohibited process may never
    ///    order a window front. It is the same guard `ConsolePresentation`
    ///    already makes, made here so nothing is even posted.
    /// 4. The harness builds coordinators through `UIFixtures`, never
    ///    `DictationCoordinator.live()`.
    ///
    /// `--show-console` above is deliberately *not* behind the policy guard: it is
    /// an explicit request, `scripts/console_shot.sh` pairs it with `--no-activate`,
    /// and the presentation layer already declines to steal focus for that pair.
    private var owesFirstRunGuidance: Bool {
        NSApp.activationPolicy() != .prohibited && coordinator?.owesFirstRunGuidance == true
    }

    /// `open -a Voiceour`, a click on the Dock icon the open console puts there,
    /// and a second launch of the bundle all arrive here. A menu-bar app needs an
    /// answer to "show me this app" that does not depend on a window already
    /// being visible: while `.accessory` there is no Dock tile and no window to
    /// click, and the duplicate instance a re-launch spawns terminates itself
    /// before it can show anything.
    ///
    /// The notification is the same one `--show-console` posts, handled by the
    /// menu bar label, which is hosted for the life of the process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .voiceourShowConsole, object: nil)
        return true
    }

    nonisolated static func shouldTerminateAsDuplicate(
        bundleIdentifier: String?,
        runningProcessIdentifiers: [Int32],
        currentProcessIdentifier: Int32
    ) -> Bool {
        guard bundleIdentifier != nil else {
            return false
        }
        return runningProcessIdentifiers.contains { $0 != currentProcessIdentifier }
    }

    @discardableResult
    static func terminateIfDuplicateApplication() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        let currentProcessIdentifier = NSRunningApplication.current.processIdentifier
        let runningProcessIdentifiers =
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
        guard
            shouldTerminateAsDuplicate(
                bundleIdentifier: bundleIdentifier,
                runningProcessIdentifiers: runningProcessIdentifiers,
                currentProcessIdentifier: currentProcessIdentifier
            )
        else {
            return false
        }

        fputs("Voiceour: another instance is already running; terminating this duplicate.\n", stderr)
        NSApp.terminate(nil)
        return true
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
                fputs("Voiceour restart failed: \(error)\n", stderr)
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

    /// The environment a restart hands its successor, minus the overrides that would outrank the
    /// settings the user just changed.
    ///
    /// Bootstrap reads the environment ahead of the persisted value for both the backend and the
    /// model variant, so leaving either here would restart the app into the old selection and make
    /// the restart-to-apply button look broken.
    static func restartEnvironment(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String:
        String]
    {
        var result = environment
        result.removeValue(forKey: "VOICEOUR_ASR_BACKEND")
        result.removeValue(forKey: ASRModelVariant.environmentKey)
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
