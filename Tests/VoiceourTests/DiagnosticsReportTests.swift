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
        let coordinator = makeCoordinator(backend: "parakeet")
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
        // No selection saved means automatic device choice, and the report says so.
        #expect(report.contains("microphone selection: automatic"))
        #expect(report.contains("settings: /pinned/settings.json"))
        #expect(report.contains("recent sessions: /pinned/recent-sessions.json"))
        #expect(report.contains(DiagnosticsReport.selfTestCommand))
    }

    /// Parakeet keeps the exact `<id>@<rev> (<variant>)` spelling bug reports already carry,
    /// naming the variant the sidecar was launched with rather than the saved one.
    @Test func parakeetIdentifierNamesTheActiveVariant() {
        var settings = VoiceCore.Settings()
        settings.asrModelVariant = .f16
        let coordinator = makeCoordinator(backend: "parakeet", variant: .q8, settings: settings)

        #expect(
            DiagnosticsReport.modelIdentifier(coordinator)
                == "ggml-org/parakeet-GGUF@35156454d1a39de06863303dd209fd2bed6ee079 (q8_0)"
        )
    }

    /// Granite names its own pin and file, never a Parakeet quantization tag — even with a
    /// Parakeet variant saved and active, which Granite does not read.
    @Test func graniteIdentifierNamesItsOwnPinAndFile() {
        var settings = VoiceCore.Settings(asrBackend: "granite")
        settings.asrModelVariant = .q8
        let coordinator = makeCoordinator(backend: "granite", variant: .q8, settings: settings)

        let identifier = DiagnosticsReport.modelIdentifier(coordinator)
        #expect(
            identifier
                == "vladers/granite-speech-5.0-470m-turboctc-GGUF"
                + "@bd7db273aa69a26fc81e370c84597fa738fe2ad0"
                + " (granite-speech-5.0-470m-turboctc-Q8_0.gguf)"
        )
        #expect(!identifier.contains("q8_0)"))
        #expect(!identifier.contains("parakeet"))
    }

    /// A model-less backend keeps its descriptor's own label, and an unregistered id its id.
    @Test func modelLessAndUnknownBackendsFallBackWithoutBorrowingAPin() {
        let fake = makeCoordinator(backend: "fake")
        #expect(DiagnosticsReport.modelIdentifier(fake) == "no model · synthetic transcripts")
        #expect(fake.activeModelArtifact == nil)
        #expect(DiagnosticsReport.modelIdentifier(makeCoordinator(backend: "future-backend")) == "future-backend")
    }

    /// The active artifact follows the running backend: Granite's fixed pin regardless of
    /// the Parakeet variant, Parakeet's selected variant otherwise.
    @Test func activeModelArtifactFollowsTheRunningBackend() {
        #expect(makeCoordinator(backend: "granite", variant: .q8).activeModelArtifact == .granite)
        #expect(makeCoordinator(backend: "parakeet", variant: .q8).activeModelArtifact == .parakeet(.q8))
        #expect(makeCoordinator(backend: "parakeet", variant: .f16).activeModelArtifact == .parakeet(.f16))
    }

    /// Mid-download, the readout and the report size Granite's own 0.51 GB artifact rather
    /// than a Parakeet variant's 1.26 GB, for the artifact the running backend resolves.
    @Test func graniteDownloadIsSizedFromItsOwnArtifact() {
        let coordinator = makeCoordinator(backend: "granite", variant: .f16)
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

    /// The Parakeet download readout keeps its committed sentence and byte count.
    @Test func parakeetDownloadKeepsItsVariantSize() {
        let coordinator = makeCoordinator(backend: "parakeet", variant: .f16)
        let artifact = coordinator.activeModelArtifact

        #expect(
            ConsoleReadiness.downloadDetail(
                modelLabel: ConsoleReadiness.activeModelLabel(coordinator), artifact: artifact)
                == "ggml-org/parakeet-GGUF — 1.26 GB."
        )
        #expect(
            DiagnosticsReport.downloadLine(fraction: 0.42, artifact: artifact)
                == "  download: 42% of 1255897319 bytes"
        )
    }

    @Test func gigabytesIsDecimalAndLocaleIndependent() {
        #expect(ConsoleReadiness.gigabytes(GraniteModelContract.sizeBytes) == "0.51 GB")
        #expect(ConsoleReadiness.gigabytes(ASRModelVariant.f16.sizeBytes) == "1.26 GB")
        #expect(ConsoleReadiness.gigabytes(ASRModelVariant.q8.sizeBytes * 2) == "1.34 GB")
    }

    private func makeCoordinator(
        backend: String,
        variant: ASRModelVariant? = nil,
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
            activeModelVariant: variant,
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
