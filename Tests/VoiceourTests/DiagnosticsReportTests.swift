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
        let coordinator = makeCoordinator(backend: "granite")
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

        #expect(report.contains(GraniteModelContract.modelId))
        // No probe has answered in this test, which is itself a named status.
        #expect(report.contains("status: unknown"))
        // No selection saved means automatic device choice, and the report says so.
        #expect(report.contains("microphone selection: automatic"))
        #expect(report.contains("settings: /pinned/settings.json"))
        #expect(report.contains("recent sessions: /pinned/recent-sessions.json"))
        #expect(report.contains(DiagnosticsReport.selfTestCommand))
    }

    /// Memory off by default: the report says so, counts nothing, and names the
    /// folder beside the History file this coordinator was built with rather than
    /// the real support directory.
    @Test func memoryLinesDefaultToOffAndNameTheIsolatedFolder() {
        let coordinator = makeCoordinator(backend: "granite")
        // A harness suite that ran earlier in this process leaves its own path
        // pinned, and this test reads the unpinned one.
        let pinned = RenderOverrides.memoryPath
        RenderOverrides.memoryPath = nil
        defer { RenderOverrides.memoryPath = pinned }

        let report = DiagnosticsReport.text(
            coordinator: coordinator,
            microphone: .granted,
            accessibility: .granted,
            synthPaste: .granted
        )

        #expect(report.contains("  keep dictations in memory: off\n"))
        #expect(report.contains("  memory entries: 0\n"))
        #expect(report.contains("  memory: \(coordinator.memoryStore.root.path)\n"))
        #expect(coordinator.memoryStore.root.path.hasSuffix("/memory"))
    }

    /// The switch and the count are reported, and the pinned path wins over the
    /// real one; what memory holds never reaches a report meant to be pasted:
    /// no kept text, topic name, session id or session directory.
    @Test func memoryLinesReportStateAndCountButNeverContents() {
        let coordinator = makeCoordinator(
            backend: "granite",
            settings: VoiceCore.Settings(asrBackend: "granite", memoryEnabled: true)
        )
        let createdAt = Date(timeIntervalSince1970: 1_793_000_000)
        coordinator.memoryTopics = [
            MemoryTopic(id: "garden-plans", name: "Garden plans", summary: "Beds and seeds.", createdAt: createdAt)
        ]
        coordinator.memoryEntries = [
            MemoryEntry(
                id: UUID(),
                createdAt: createdAt,
                text: "plant the tomatoes beside the fence",
                thread: JournalThreadRef(
                    agent: .claudeCode,
                    sessionId: "session-4f2a9c",
                    title: "Sprinkler timer",
                    workingDirectory: "/Users/someone/projects/sprinkler"
                ),
                userTopicID: "garden-plans"
            ),
            MemoryEntry(id: UUID(), createdAt: createdAt, kind: .note, text: "order more mulch"),
        ]
        RenderOverrides.memoryPath = "/pinned/memory"
        defer { RenderOverrides.memoryPath = nil }

        let report = DiagnosticsReport.text(
            coordinator: coordinator,
            microphone: .granted,
            accessibility: .granted,
            synthPaste: .granted
        )

        #expect(report.contains("  keep dictations in memory: on\n"))
        #expect(report.contains("  memory entries: 2\n"))
        #expect(report.contains("  memory: /pinned/memory\n"))
        #expect(!report.contains(coordinator.memoryStore.root.path))
        for secret in [
            "tomatoes", "mulch", "Garden plans", "garden-plans", "session-4f2a9c", "Sprinkler timer",
            "/projects/sprinkler",
        ] {
            #expect(!report.contains(secret))
        }
    }

    /// Granite names its own pin and file in the `<id>@<rev> (<file>)` spelling bug reports
    /// carry — even with a variant tag saved in settings, which no backend reads.
    @Test func graniteIdentifierNamesItsOwnPinAndFile() {
        var settings = VoiceCore.Settings(asrBackend: "granite")
        settings.asrModelVariant = .q8
        let coordinator = makeCoordinator(backend: "granite", settings: settings)

        let identifier = DiagnosticsReport.modelIdentifier(coordinator)
        #expect(
            identifier
                == "vladers/granite-speech-5.0-470m-turboctc-GGUF"
                + "@bd7db273aa69a26fc81e370c84597fa738fe2ad0"
                + " (granite-speech-5.0-470m-turboctc-Q8_0.gguf)"
        )
        #expect(!identifier.contains("q8_0)"))
    }

    /// A model-less backend keeps its descriptor's own label, and an unregistered id its id.
    @Test func modelLessAndUnknownBackendsFallBackWithoutBorrowingAPin() {
        let fake = makeCoordinator(backend: "fake")
        #expect(DiagnosticsReport.modelIdentifier(fake) == "no model · synthetic transcripts")
        #expect(fake.activeModelArtifact == nil)
        #expect(DiagnosticsReport.modelIdentifier(makeCoordinator(backend: "future-backend")) == "future-backend")
    }

    /// The active artifact follows the running backend: Granite's fixed pin, none for fake.
    @Test func activeModelArtifactFollowsTheRunningBackend() {
        #expect(makeCoordinator(backend: "granite").activeModelArtifact == .granite)
        #expect(makeCoordinator(backend: "fake").activeModelArtifact == nil)
    }

    /// Mid-download, the readout and the report size Granite's own 0.51 GB artifact, the one
    /// the running backend resolves.
    @Test func graniteDownloadIsSizedFromItsOwnArtifact() {
        let coordinator = makeCoordinator(backend: "granite")
        let artifact = coordinator.activeModelArtifact

        #expect(
            ConsoleReadiness.downloadDetail(
                modelLabel: ConsoleReadiness.activeModelLabel(coordinator), artifact: artifact)
                == "\(GraniteModelContract.modelId) — 0.51 GB."
        )
        #expect(
            DiagnosticsReport.downloadLine(fraction: 0.42, artifact: artifact)
                == "  download: 42% of 505663136 bytes"
        )
    }

    @Test func gigabytesIsDecimalAndLocaleIndependent() {
        #expect(ConsoleReadiness.gigabytes(GraniteModelContract.sizeBytes) == "0.51 GB")
        #expect(ConsoleReadiness.gigabytes(1_255_897_319) == "1.26 GB")
        #expect(ConsoleReadiness.gigabytes(1_337_514_238) == "1.34 GB")
    }

    private func makeCoordinator(
        backend: String,
        settings: VoiceCore.Settings? = nil,
        health: ASRBackendHealth = FakeASR.ready
    ) -> DictationCoordinator {
        DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("unused"), backendHealth: health),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            settings: settings ?? VoiceCore.Settings(asrBackend: backend),
            activeASRBackend: backend,
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
    }
}
