import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// The registry replaced backend selection that was spread across ten files:
/// the coordinator's live wiring, the recorder and muter choice, the launch
/// validator, the Voice picker, the model-label helper, and the benchmark's
/// parser, factory and metadata. These pin the descriptor values those call
/// sites now read, so a wrong one is a test failure rather than a silently
/// mislabelled UI or a benchmark measuring the wrong engine.
@Suite("ASR backend registry")
struct ASRBackendRegistryTests {
    private let registry = ASRBackendRegistry.builtIn
    private let context = ASRBackendContext(
        asrDirectory: URL(fileURLWithPath: "/tmp/voiceoour-asr"),
        speechLocale: "en_US"
    )

    @Test func builtInCarriesExactlyTheThreeShippedBackendsInPickerOrder() {
        #expect(registry.descriptors.map(\.id) == ["fake", "mlx", "apple"])
        #expect(registry.backendIDs == ["fake", "mlx", "apple"])
    }

    @Test func descriptorMetadataMatchesWhatTheUISurfaces() throws {
        let fake = try #require(registry.descriptor(for: "fake"))
        #expect(fake.displayName == "FAKE")
        #expect(fake.modelLabel == "no model · synthetic transcripts")

        let mlx = try #require(registry.descriptor(for: "mlx"))
        #expect(mlx.displayName == "PARAKEET MLX")
        #expect(mlx.modelLabel == ASRModelContract.modelId)

        let apple = try #require(registry.descriptor(for: "apple"))
        #expect(apple.displayName == "APPLE SPEECH")
        #expect(apple.modelLabel == "apple/SpeechTranscriber (system-managed)")
    }

    /// The fake backend needs neither a real recorder nor a muter: it produces
    /// synthetic audio and has no speaker output worth silencing.
    @Test func fakeBackendUsesTheFakeRecorderAndNoMuter() {
        let components = registry.liveComponents(for: "fake", context: context)

        #expect(components.recorder is FakeAudioRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(!components.usesSystemAudioMuter)
    }

    @Test func mlxBackendUsesTheRealRecorderAndTheMuter() {
        let components = registry.liveComponents(for: "mlx", context: context)

        #expect(components.recorder is AVAudioEngineRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(components.usesSystemAudioMuter)
    }

    /// Below macOS 26 the Apple backend still resolves — it stays selectable and
    /// reports the reason through `UnsupportedASRClient` rather than vanishing
    /// from the picker.
    @Test func appleBackendReportsUnsupportedBelowMacOS26() {
        let components = registry.liveComponents(for: "apple", context: context)
        #expect(components.usesSystemAudioMuter)

        if #available(macOS 26.0, *) {
            #expect(!(components.client is UnsupportedASRClient))
        } else {
            #expect(components.client is UnsupportedASRClient)
            #expect(components.recorder is AVAudioEngineRecorder)
            #expect(registry.client(for: "apple", context: context) is UnsupportedASRClient)
        }
    }

    /// A stale `settings.asrBackend` written by a future build must not crash the
    /// app, which is why an unknown id resolves to the fake backend instead of
    /// trapping — the same `?? fake` the coordinator applied before.
    @Test func unknownBackendFallsBackToFakeWithoutTrapping() {
        #expect(registry.descriptor(for: "quantum-ears") == nil)
        #expect(registry.defaultDescriptor.id == "fake")

        let components = registry.liveComponents(for: "quantum-ears", context: context)
        #expect(components.recorder is FakeAudioRecorder)
        #expect(!components.usesSystemAudioMuter)
    }

    @Test func launchOptionValidationCanBeDrivenByTheRegistry() {
        let ids = registry.backendIDs
        #expect(VoiceCore.LaunchOptions.validBackend("MLX", validBackendIDs: ids) == "mlx")
        #expect(VoiceCore.LaunchOptions.validBackend("  apple ", validBackendIDs: ids) == "apple")
        #expect(VoiceCore.LaunchOptions.validBackend("quantum-ears", validBackendIDs: ids) == nil)
        #expect(VoiceCore.LaunchOptions.validBackend(nil, validBackendIDs: ids) == nil)
    }
}
