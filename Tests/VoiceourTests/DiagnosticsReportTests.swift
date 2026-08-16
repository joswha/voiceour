import Foundation
import Testing
import VoiceCore
import VoiceMac

@testable import Voiceour

/// The diagnostics text is the app's bug-report surface: it must name the model
/// pin, the backend status, the storage paths, and the self-test command a
/// report needs to be actionable.
@MainActor
@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {
    @Test func diagnosticsReportNamesTheModelPinAndStoragePaths() {
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("unused")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: VoiceCore.Settings(),
            activeASRBackend: "parakeet",
            settingsStore: SettingsStore(),
            recentSessionStore: RecentSessionStore(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("voiceour-diagnostics-tests-\(UUID().uuidString)")
                    .appendingPathComponent("recent-sessions.json")
            ),
            recentSessionSnapshotSave: { store, sessions in try store.save(sessions) },
            audioMuter: NoOpSystemAudioMuter(),
            temporaryAudioRemover: { try FileManager.default.removeItem(at: $0) }
        )
        RenderOverrides.settingsPath = "/pinned/settings.json"
        RenderOverrides.recentSessionsPath = "/pinned/recent-sessions.json"
        defer {
            RenderOverrides.settingsPath = nil
            RenderOverrides.recentSessionsPath = nil
        }

        let report = DiagnosticsReport.text(
            coordinator: coordinator,
            microphone: .granted,
            accessibility: .denied,
            synthPaste: .notDetermined
        )

        #expect(report.contains("ggml-org/parakeet-GGUF"))
        // No probe has answered in this test, which is itself a named status.
        #expect(report.contains("status: unknown"))
        #expect(report.contains("settings: /pinned/settings.json"))
        #expect(report.contains("recent sessions: /pinned/recent-sessions.json"))
        #expect(report.contains(DiagnosticsReport.selfTestCommand))
    }
}
