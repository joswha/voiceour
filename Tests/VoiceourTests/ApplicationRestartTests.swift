import AppKit
import Foundation
import Testing

@testable import VoiceMac
@testable import Voiceour

@Suite("Application restart")
@MainActor
struct ApplicationRestartTests {
    @Test func processRelauncherStartsTheRequestedSuccessor() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-relaunch-\(UUID().uuidString)")
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
        let arguments = VoiceourAppDelegate.restartArguments(from: [
            "--repo-root", "/tmp/voiceour",
            "--asr-backend", "parakeet",
            "--asr-backend=fake",
            "--no-activate",
        ])

        #expect(
            arguments == [
                "--repo-root", "/tmp/voiceour",
                "--no-activate",
                "--show-console",
            ])
    }

    @Test func restartDoesNotDuplicateShowConsole() {
        let arguments = VoiceourAppDelegate.restartArguments(from: [
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
        let environment = VoiceourAppDelegate.restartEnvironment(from: [
            "VOICEOUR_ASR_BACKEND": "mlx",
            "VOICEOUR_REPO_ROOT": "/tmp/voiceour",
            "PATH": "/usr/bin",
        ])

        #expect(
            environment == [
                "VOICEOUR_REPO_ROOT": "/tmp/voiceour",
                "PATH": "/usr/bin",
            ])
    }

    /// `@NSApplicationDelegateAdaptor` leaves `SwiftUI.AppDelegate` in
    /// `NSApp.delegate`, so panes that cast that object to this class got nil
    /// and every restart press was a silent no-op. The pane path now resolves
    /// through `shared`, which only `applicationDidFinishLaunching` publishes.
    @Test func launchPublishesTheDelegatePanesReachFor() {
        let delegate = VoiceourAppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(VoiceourAppDelegate.shared === delegate)
    }
}
