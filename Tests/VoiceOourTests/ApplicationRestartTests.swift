import AppKit
import Foundation
import Testing

@testable import VoiceMac
@testable import VoiceOour

@Suite("Application restart")
@MainActor
struct ApplicationRestartTests {
    @Test func processRelauncherStartsTheRequestedSuccessor() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceoour-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let launcher = ProcessApplicationRelauncher(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch")
        )
        try launcher.launch(arguments: [marker.path], environment: [:])

        for _ in 0..<20 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func restartDropsStaleBackendOverridesAndKeepsTheConsoleOpen() {
        let arguments = VoiceOourAppDelegate.restartArguments(from: [
            "--repo-root", "/tmp/voiceoour",
            "--asr-backend", "mlx",
            "--asr-backend=apple",
            "--asr-dir", "/tmp/asr",
        ])

        #expect(
            arguments == [
                "--repo-root", "/tmp/voiceoour",
                "--asr-dir", "/tmp/asr",
                "--show-console",
            ])
    }

    @Test func restartDoesNotDuplicateShowConsole() {
        let arguments = VoiceOourAppDelegate.restartArguments(from: [
            "--show-console",
            "--console-section=voice",
        ])

        #expect(
            arguments == [
                "--show-console",
                "--console-section=voice",
            ])
    }

    @Test func restartRemovesOnlyTheBackendEnvironmentOverride() {
        let environment = VoiceOourAppDelegate.restartEnvironment(from: [
            "VOICEOOUR_ASR_BACKEND": "mlx",
            "VOICEOOUR_REPO_ROOT": "/tmp/voiceoour",
            "PATH": "/usr/bin",
        ])

        #expect(
            environment == [
                "VOICEOOUR_REPO_ROOT": "/tmp/voiceoour",
                "PATH": "/usr/bin",
            ])
    }

    /// `@NSApplicationDelegateAdaptor` leaves `SwiftUI.AppDelegate` in
    /// `NSApp.delegate`, so panes that cast that object to this class got nil
    /// and every restart press was a silent no-op. The pane path now resolves
    /// through `shared`, which only `applicationDidFinishLaunching` publishes.
    @Test func launchPublishesTheDelegatePanesReachFor() {
        let delegate = VoiceOourAppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(VoiceOourAppDelegate.shared === delegate)
    }
}
