import Foundation
import Testing

@testable import VoiceMac

/// Covers environment-backed and composite refiner API key selection.
@Suite("Refiner API Key Providers")
struct RefinerAPIKeyProviderTests {
    @Test func envAndCompositeKeyProviders() {
        #expect(EnvRefinerAPIKeyProvider(names: ["A", "B"], environment: ["B": "x"]).apiKey() == "x")
        #expect(EnvRefinerAPIKeyProvider(names: ["A"], environment: ["A": ""]).apiKey() == nil)
        #expect(
            CompositeRefinerAPIKeyProvider([
                EnvRefinerAPIKeyProvider(names: ["A"], environment: [:]),
                StaticRefinerAPIKeyProvider("fallback"),
            ]).apiKey() == "fallback")
        #expect(
            CompositeRefinerAPIKeyProvider([
                StaticRefinerAPIKeyProvider("first"),
                StaticRefinerAPIKeyProvider("second"),
            ]).apiKey() == "first")
    }

    /// A keychain that cannot answer is not the same thing as a user who has not
    /// configured a key: falling through would send whatever credential happens
    /// to be in the environment to a provider the user never paired it with.
    @Test func compositeStopsAtAnUnavailableProviderInsteadOfUsingTheNextOne() {
        let composite = CompositeRefinerAPIKeyProvider([
            UnavailableRefinerAPIKeyProvider(status: errSecInteractionNotAllowed),
            StaticRefinerAPIKeyProvider("environment-key"),
        ])

        #expect(composite.readAPIKey() == .unavailable(errSecInteractionNotAllowed))
        #expect(composite.apiKey() == nil)
    }

    @Test func compositeSkipsProvidersThatAreMerelyEmpty() {
        let composite = CompositeRefinerAPIKeyProvider([
            StaticRefinerAPIKeyProvider(nil),
            StaticRefinerAPIKeyProvider("environment-key"),
        ])

        #expect(composite.readAPIKey() == .found("environment-key"))
    }
}

private struct UnavailableRefinerAPIKeyProvider: RefinerAPIKeyProviding {
    let status: OSStatus

    func apiKey() -> String? { nil }
    func readAPIKey() -> RefinerAPIKeyReadOutcome { .unavailable(status) }
}
