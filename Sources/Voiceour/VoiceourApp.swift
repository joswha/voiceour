import AppKit
import Darwin
import SwiftUI
import VoiceMac

@main
struct VoiceourApp: App {
    @NSApplicationDelegateAdaptor(VoiceourAppDelegate.self) private var appDelegate
    @State private var coordinator: DictationCoordinator
    private let recordingOverlay: RecordingOverlayController

    init() {
        // First statement in the process, before any side effect: the offscreen UI
        // harness must not mute audio, build a coordinator, or claim an activation
        // policy. `UIHarnessRequest` is nil unless `--ui-harness` is present, so a
        // normal launch falls straight through.
        //
        // `scripts/bundle.sh` builds without `-DUI_HARNESS`, so this block and the
        // harness objects behind it never link into the shipping binary.
        #if UI_HARNESS
            if CommandLine.arguments.contains(UIHarnessRequest.flag) {
                guard let request = UIHarnessRequest(arguments: CommandLine.arguments) else {
                    fputs(UIHarnessRequest.usage + "\n", stderr)
                    Darwin.exit(2)
                }
                Darwin.exit(UIHarnessMain.run(request) ? 0 : 1)
            }
        #endif
        // SwiftUI constructs the live coordinator before did-finish-launching;
        // guard here too so a duplicate cannot spawn its hotkey or sidecar first.
        if VoiceourAppDelegate.terminateIfDuplicateApplication() {
            Darwin.exit(0)
        }
        SystemAudioMuter.recoverDurableOwnershipIfNeeded()
        if CommandLine.arguments.contains("--self-test") {
            let ok = VoiceourSelfTest.run()
            Darwin.exit(ok ? 0 : 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let liveCoordinator = DictationCoordinator.live()
        let recordingOverlay = RecordingOverlayController(coordinator: liveCoordinator)
        recordingOverlay.bind(to: liveCoordinator.statePublisher)
        _coordinator = State(initialValue: liveCoordinator)
        self.recordingOverlay = recordingOverlay
        appDelegate.coordinator = liveCoordinator
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(coordinator: coordinator)
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Voiceour", id: "main") {
            ConsoleView(coordinator: coordinator, initialSection: LaunchOptions.consoleSection)
        }
        .defaultSize(
            width: VoiceourMetrics.Window.defaultWidth,
            height: VoiceourMetrics.Window.defaultHeight
        )
    }
}
