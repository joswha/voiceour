import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// The registry replaced backend selection that was spread across ten files:
/// the coordinator's live wiring, the recorder and muter choice, the launch
/// validator, the Voice picker, the model readouts in Voice and Diagnostics,
/// and the benchmark's parser, factory and metadata. These pin the descriptor
/// values those call sites now read, so a wrong one is a test failure rather
/// than a silently mislabelled UI or a benchmark measuring the wrong engine.
@Suite("ASR backend registry")
struct ASRBackendRegistryTests {
    private let registry = ASRBackendRegistry.builtIn
    private let context = ASRBackendContext(
        sidecarExecutableURL: URL(fileURLWithPath: "/tmp/voiceour-asr")
    )

    @Test func builtInCarriesTheTwoBackendsInPickerOrder() {
        #expect(registry.descriptors.map(\.id) == ["fake", "granite"])
        #expect(registry.backendIDs == ["fake", "granite"])
        // Granite is the default; the picker order does not follow it.
        #expect(registry.defaultDescriptor.id == "granite")
    }

    @Test func descriptorMetadataMatchesWhatTheUISurfaces() throws {
        let fake = try #require(registry.descriptor(for: "fake"))
        #expect(fake.displayName == "FAKE")
        #expect(fake.modelLabel == "no model · synthetic transcripts")
        #expect(fake.modelArtifact == nil)

        let granite = try #require(registry.descriptor(for: "granite"))
        #expect(granite.displayName == "GRANITE")
        #expect(granite.modelLabel == GraniteModelContract.modelId)
        #expect(granite.modelArtifact == .granite)
    }

    /// The artifact values every readout and the bench stamp read are exactly Granite's contract.
    @Test func modelArtifactsCarryTheirContracts() {
        let granite = ASRModelArtifact.granite
        #expect(granite.modelId == "vladers/granite-speech-5.0-470m-turboctc-GGUF")
        #expect(granite.revision == "bd7db273aa69a26fc81e370c84597fa738fe2ad0")
        #expect(granite.file == "granite-speech-5.0-470m-turboctc-Q8_0.gguf")
        #expect(granite.sizeBytes == 505_663_136)
        #expect(granite.displayName == "Granite Speech 5.0 TurboCTC 470M")
        #expect(granite.expectedModel == GraniteModelContract.expectedModel)
        #expect(
            GraniteModelContract.downloadURL.absoluteString
                == "https://huggingface.co/vladers/granite-speech-5.0-470m-turboctc-GGUF/resolve/"
                + "bd7db273aa69a26fc81e370c84597fa738fe2ad0/granite-speech-5.0-470m-turboctc-Q8_0.gguf"
        )
    }

    /// The sidecar helper is resolved as a sibling of whatever executable is running, which is
    /// the one rule that holds for `swift run`, the benchmark and `Contents/MacOS` alike.
    @Test func siblingSidecarURLResolvesNextToTheRunningExecutable() {
        let url = ASRBackendContext.siblingSidecarURL(of: URL(fileURLWithPath: "/opt/App.app/Contents/MacOS/Voiceour"))

        #expect(url.path == "/opt/App.app/Contents/MacOS/voiceour-asr")
    }

    /// The fake backend needs neither a real recorder nor a muter: it produces
    /// synthetic audio and has no speaker output worth silencing.
    @Test func fakeBackendUsesTheFakeRecorderAndNoMuter() {
        let components = registry.liveComponents(for: "fake", context: context)

        #expect(components.recorder is FakeAudioRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(!components.usesSystemAudioMuter)
    }

    /// Granite is model-backed: a real recorder and the muter. Its client launches the
    /// `granite` sidecar and pins Granite's own artifact on every transcribe, whatever variant
    /// an external caller's context passes.
    @Test func graniteBackendUsesTheRealRecorderTheMuterAndItsOwnPin() throws {
        let context = ASRBackendContext(
            sidecarExecutableURL: URL(fileURLWithPath: "/tmp/voiceour-asr"),
            modelVariant: .q8
        )
        let components = registry.liveComponents(for: "granite", context: context)

        #expect(components.recorder is MicrophoneRecorder)
        #expect(components.usesSystemAudioMuter)
        let client = try #require(components.client as? SidecarASRClient)
        #expect(client.expectedModel == GraniteModelContract.expectedModel)
        #expect(client.launch.environment["VOICEOUR_ASR_BACKEND"] == "granite")
    }

    /// The retired `parakeet` id, which external callers still pass, yields Granite's client.
    @Test func theRetiredParakeetIdYieldsGranite() throws {
        let client = try #require(registry.client(for: "parakeet", context: context) as? SidecarASRClient)

        #expect(client.expectedModel == GraniteModelContract.expectedModel)
        #expect(client.launch.environment["VOICEOUR_ASR_BACKEND"] == "granite")
    }

    /// A stale `settings.asrBackend` written by a future build must not crash the
    /// app: an unknown id resolves to the default descriptor instead of trapping.
    /// That default is Granite, a real local recognizer, so an unrecognised id degrades
    /// to real dictation rather than to synthetic text the user cannot tell apart.
    @Test func unknownBackendFallsBackToTheRealBackendWithoutTrapping() {
        #expect(registry.descriptor(for: "quantum-ears") == nil)
        #expect(registry.defaultDescriptor.id == "granite")

        let components = registry.liveComponents(for: "quantum-ears", context: context)
        #expect(components.recorder is MicrophoneRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(components.usesSystemAudioMuter)
    }

    @Test func launchOptionValidationCanBeDrivenByTheRegistry() {
        let ids = registry.backendIDs
        #expect(VoiceCore.LaunchOptions.validBackend("GRANITE", validBackendIDs: ids) == "granite")
        #expect(VoiceCore.LaunchOptions.validBackend("  fake ", validBackendIDs: ids) == "fake")
        #expect(VoiceCore.LaunchOptions.validBackend(" Granite\n", validBackendIDs: ids) == "granite")
        // Retired ids normalize before the membership test, so an "mlx" from any source still
        // resolves against the live registry rather than falling through to the default.
        #expect(VoiceCore.LaunchOptions.validBackend("MLX", validBackendIDs: ids) == "granite")
        #expect(VoiceCore.LaunchOptions.validBackend("ARK-0.6B", validBackendIDs: ids) == "granite")
        #expect(VoiceCore.LaunchOptions.validBackend("Parakeet", validBackendIDs: ids) == "granite")
        #expect(VoiceCore.LaunchOptions.validBackend("quantum-ears", validBackendIDs: ids) == nil)
        #expect(VoiceCore.LaunchOptions.validBackend(nil, validBackendIDs: ids) == nil)
        // The wire id is the sidecar's self-report, never a selector.
        #expect(VoiceCore.LaunchOptions.validBackend("granite-ctc", validBackendIDs: ids) == nil)
    }

    /// VoiceCore cannot import VoiceMac to read the registry, so this exact
    /// equality assertion catches drift in either direction.
    @Test func launchOptionDefaultsMatchRegisteredBackends() {
        #expect(LaunchOptions.defaultBackendIDs == registry.backendIDs)
    }
}
