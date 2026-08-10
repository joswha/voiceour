import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// The registry replaced a provider `if` chain in the coordinator and the vendor
/// types that leaked out of VoiceMac with it. Its one hard constraint is that it
/// cannot change the stored settings format: `RefinerProvider` stays a closed
/// `Codable` enum whose raw values are the `refiner_provider` key in
/// `settings.json`, and the registry is runtime dispatch only.
@Suite("Refiner provider registry")
struct RefinerProviderRegistryTests {
    private func registry() -> RefinerProviderRegistry {
        RefinerProviderRegistry.live(
            environment: [:],
            apiKeyProvider: { _ in StaticRefinerAPIKeyProvider("token") },
            deterministicFallback: { "DET:\($0)" }
        )
    }

    private func settings(_ provider: RefinerProvider) -> Settings {
        var settings = Settings()
        settings.refinerEnabled = true
        settings.refinerProvider = provider
        return settings
    }

    @Test func everyProviderCaseHasADescriptor() {
        let registry = registry()
        for provider in RefinerProvider.allCases {
            #expect(registry.descriptor(for: provider) != nil, "no descriptor for \(provider.rawValue)")
        }
        #expect(registry.descriptors.map(\.id) == RefinerProvider.allCases)
    }

    /// Descriptor metadata must equal the enum's own values, not a second copy of
    /// them, or the picker and the resolver drift.
    @Test func descriptorMetadataMatchesTheEnum() throws {
        let registry = registry()
        for provider in RefinerProvider.allCases {
            let descriptor = try #require(registry.descriptor(for: provider))
            #expect(descriptor.displayName == provider.displayName)
            #expect(descriptor.defaultBaseURL == RefinerResolved.defaultBaseURL(provider))
            #expect(descriptor.suggestedModels == provider.suggestedModels)
            #expect(descriptor.apiKeyURL == provider.apiKeyURL)
            #expect(descriptor.apiKeyEnvName == provider.apiKeyEnvName)
        }
    }

    @Test func directProvidersBuildTheHTTPRefinerAndOmpBuildsTheRpcRefiner() {
        let registry = registry()

        for provider in [RefinerProvider.gemini, .openAI, .openRouter, .custom] {
            #expect(
                registry.make(settings: settings(provider)) is LLMRefiner,
                "\(provider.rawValue) should build the OpenAI-compatible refiner"
            )
        }
        #expect(registry.make(settings: settings(.omp)) is OmpRpcRefiner)
    }

    /// Below macOS 26 the on-device provider reports the reason rather than
    /// vanishing, exactly as the hand-wired chain did.
    @Test func onDeviceProviderReportsUnsupportedBelowMacOS26() {
        let refiner = registry().make(settings: settings(.appleOnDevice))

        if #available(macOS 26.0, *) {
            #expect(!(refiner is UnsupportedRefiner))
        } else {
            #expect(refiner is UnsupportedRefiner)
        }
    }

    /// The registry never writes a provider id, so a round trip through
    /// `settings.json` still produces the same raw values it always did. This is
    /// the guard on the stored format.
    @Test func settingsRoundTripKeepsEveryProviderRawValue() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for provider in RefinerProvider.allCases {
            let data = try encoder.encode(settings(provider))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["refiner_provider"] as? String == provider.rawValue)

            let decoded = try decoder.decode(Settings.self, from: data)
            #expect(decoded.refinerProvider == provider)
        }
    }
}
