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
        sidecarExecutableURL: URL(fileURLWithPath: "/tmp/voiceour-asr"),
        speechLocale: "en_US"
    )

    @Test func builtInCarriesExactlyTheThreeShippedBackendsInPickerOrder() {
        #expect(registry.descriptors.map(\.id) == ["fake", "parakeet", "apple"])
        #expect(registry.backendIDs == ["fake", "parakeet", "apple"])
    }

    @Test func descriptorMetadataMatchesWhatTheUISurfaces() throws {
        let fake = try #require(registry.descriptor(for: "fake"))
        #expect(fake.displayName == "FAKE")
        #expect(fake.modelLabel == "no model · synthetic transcripts")
        #expect(fake.modelId == nil)
        #expect(fake.modelRevision == nil)

        let parakeet = try #require(registry.descriptor(for: "parakeet"))
        #expect(parakeet.displayName == "PARAKEET")
        #expect(parakeet.modelLabel == ASRModelContract.modelId)
        #expect(parakeet.modelId == ASRModelContract.modelId)
        #expect(parakeet.modelRevision == ASRModelContract.revision)

        let apple = try #require(registry.descriptor(for: "apple"))
        #expect(apple.displayName == "APPLE SPEECH")
        #expect(apple.modelLabel == "apple/SpeechTranscriber (system-managed)")
        #expect(apple.modelId == "apple/SpeechTranscriber")
        // System-managed: the OS owns the assets, so nothing here pins a revision.
        #expect(apple.modelRevision == nil)
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

    @Test func parakeetBackendUsesTheRealRecorderAndTheMuter() {
        let components = registry.liveComponents(for: "parakeet", context: context)

        #expect(components.recorder is MicrophoneRecorder)
        #expect(components.client is SidecarASRClient)
        #expect(components.usesSystemAudioMuter)
        #expect(registry.client(for: "parakeet", context: context) is SidecarASRClient)
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
        #expect(VoiceCore.LaunchOptions.validBackend("PARAKEET", validBackendIDs: ids) == "parakeet")
        #expect(VoiceCore.LaunchOptions.validBackend("  apple ", validBackendIDs: ids) == "apple")
        // Retired ids normalize before the membership test, so a persisted "mlx" still
        // resolves against the live registry rather than falling through to the default.
        #expect(VoiceCore.LaunchOptions.validBackend("MLX", validBackendIDs: ids) == "parakeet")
        #expect(VoiceCore.LaunchOptions.validBackend("ARK-0.6B", validBackendIDs: ids) == "parakeet")
        #expect(VoiceCore.LaunchOptions.validBackend("quantum-ears", validBackendIDs: ids) == nil)
        #expect(VoiceCore.LaunchOptions.validBackend(nil, validBackendIDs: ids) == nil)
    }

    /// VoiceCore cannot import VoiceMac to read the registry, so this exact
    /// equality assertion catches drift in either direction.
    @Test func launchOptionDefaultsMatchRegisteredBackends() {
        #expect(LaunchOptions.defaultBackendIDs == registry.backendIDs)
    }
}
