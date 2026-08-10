import Testing
import VoiceCore
import VoiceMac

@testable import VoiceOour

@Suite("Refiner key accounts")
struct RefinerKeyAccountTests {
    @Test func nonCustomAccountsRemainStable() {
        let cases: [(RefinerProvider, String)] = [
            (.gemini, "api-key-gemini"),
            (.openAI, "api-key-openAI"),
            (.openRouter, "api-key-openRouter"),
            (.omp, "api-key-omp"),
            (.appleOnDevice, "api-key-appleOnDevice"),
        ]

        for (provider, expectedAccount) in cases {
            #expect(
                DictationCoordinator.keychainAccount(
                    for: provider,
                    endpoint: "https://ignored.example"
                ) == expectedAccount
            )
        }
    }

    @Test func customEndpointsHaveSeparateAccounts() {
        let first = DictationCoordinator.keychainAccount(
            for: .custom,
            endpoint: "https://a.example/v1"
        )
        let second = DictationCoordinator.keychainAccount(
            for: .custom,
            endpoint: "https://b.example/v1"
        )

        #expect(first != second)
    }

    @Test func customEndpointNormalizationIsStable() {
        let canonical = DictationCoordinator.keychainAccount(
            for: .custom,
            endpoint: "https://api.example.com/v1"
        )
        let triviallyFormatted = DictationCoordinator.keychainAccount(
            for: .custom,
            endpoint: "  HTTPS://API.EXAMPLE.COM/v1/ \n"
        )

        #expect(canonical == triviallyFormatted)
        #expect(canonical == "api-key-custom-53aee2ca762b9729")
    }

    @Test func providerSpecificEnvironmentKeyWins() {
        let provider = DictationCoordinator.envKeyProvider(
            for: .openAI,
            environment: [
                "OPENAI_API_KEY": "provider-key",
                "VOICEOOUR_REFINER_API_KEY": "generic-key",
            ]
        )

        #expect(provider.apiKey() == "provider-key")
    }
}
