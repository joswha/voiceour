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
        asrDirectory: URL(fileURLWithPath: "/tmp/voiceoour-asr"),
        speechLocale: "en_US"
    )

    @Test func builtInCarriesExactlyTheFiveShippedBackendsInPickerOrder() {
        #expect(registry.descriptors.map(\.id) == ["fake", "mlx", "apple", "ark-0.6b", "ark-3b"])
        #expect(registry.backendIDs == ["fake", "mlx", "apple", "ark-0.6b", "ark-3b"])
    }

    @Test func descriptorMetadataMatchesWhatTheUISurfaces() throws {
        let fake = try #require(registry.descriptor(for: "fake"))
        #expect(fake.displayName == "FAKE")
        #expect(fake.modelLabel == "no model · synthetic transcripts")
        #expect(fake.modelId == nil)
        #expect(fake.modelRevision == nil)

        let mlx = try #require(registry.descriptor(for: "mlx"))
        #expect(mlx.displayName == "PARAKEET MLX")
        #expect(mlx.modelLabel == ASRModelContract.modelId)
        #expect(mlx.modelId == ASRModelContract.modelId)
        #expect(mlx.modelRevision == ASRModelContract.revision)

        let apple = try #require(registry.descriptor(for: "apple"))
        #expect(apple.displayName == "APPLE SPEECH")
        #expect(apple.modelLabel == "apple/SpeechTranscriber (system-managed)")
        #expect(apple.modelId == "apple/SpeechTranscriber")
        // System-managed: the OS owns the assets, so nothing here pins a revision.
        #expect(apple.modelRevision == nil)
    }

    /// The ARK pins are the converted MLX repositories the sidecar downloads. A
    /// wrong revision costs gigabytes of re-download and runs weights that the
    /// numbers in `docs/performance-roadmap.md` were never measured on.
    @Test func arkDescriptorsPinTheirConvertedModels() throws {
        let small = try #require(registry.descriptor(for: "ark-0.6b"))
        #expect(small.displayName == "ARK 0.6B")
        #expect(small.modelLabel == "leope/ark-asr-0.6B-mlx")
        #expect(small.modelId == "leope/ark-asr-0.6B-mlx")
        #expect(small.modelRevision == "6ec069bd68cbbe165aa42728eac482c90cb58d2f")

        let large = try #require(registry.descriptor(for: "ark-3b"))
        #expect(large.displayName == "ARK 3B")
        #expect(large.modelLabel == "leope/ark-asr-3B-mlx")
        #expect(large.modelId == "leope/ark-asr-3B-mlx")
        #expect(large.modelRevision == "63d9fb8ba352c5c7c65ff2336019048170563d63")
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

        #expect(components.recorder is MicrophoneRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(components.usesSystemAudioMuter)
    }

    /// Both ARK sizes are sidecar backends shaped exactly like `mlx` — real
    /// microphone, muter, Python client — not a native engine and not a variant
    /// of the fake backend.
    @Test(arguments: ["ark-0.6b", "ark-3b"])
    func arkBackendsRunThroughTheSidecarLikeMLX(id: String) {
        let components = registry.liveComponents(for: id, context: context)

        #expect(components.recorder is MicrophoneRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(components.usesSystemAudioMuter)
        #expect(registry.client(for: id, context: context) is SidecarASRClient)
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
            #expect(components.recorder is MicrophoneRecorder)
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
        #expect(VoiceCore.LaunchOptions.validBackend("ARK-0.6B", validBackendIDs: ids) == "ark-0.6b")
        #expect(VoiceCore.LaunchOptions.validBackend("quantum-ears", validBackendIDs: ids) == nil)
        #expect(VoiceCore.LaunchOptions.validBackend(nil, validBackendIDs: ids) == nil)
    }

    /// `LaunchOptions` hardcodes the same ids because VoiceCore may not import
    /// VoiceMac to read the registry. This is the drift check for that copy: a
    /// backend registered here but missing there is selectable in the app and
    /// rejected on the command line.
    @Test func launchOptionDefaultsCoverEveryRegisteredBackend() {
        for id in registry.backendIDs {
            #expect(VoiceCore.LaunchOptions.validBackend(id) == id)
        }
    }
}
