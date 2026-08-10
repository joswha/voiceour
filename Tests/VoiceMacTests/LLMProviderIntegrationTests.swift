import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Covers opt-in live LLM provider integration paths.
@Suite("LLM Provider Integration")
struct LLMProviderIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil))
    func llmRefinerGeminiIntegration() async throws {
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
                model: "gemini-2.5-flash-lite",
                timeoutMs: 15000
            ),
            apiKeyProvider: StaticRefinerAPIKeyProvider(ProcessInfo.processInfo.environment["GEMINI_API_KEY"]),
            session: .shared
        )

        let outcome = await refiner.refine(
            "okay send this to to Sarah no wait send it to Morgan instead and mention the staging is broken",
            glossary: [], safety: .normalText, style: .standard)
        guard let refined = refinedString(outcome) else {
            Issue.record("Gemini refiner should return .refined for the self-correction prompt")
            return
        }
        let normalized = refined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        #expect(normalized.contains("morgan"))
        #expect(!normalized.contains("sarah"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
    func llmRefinerOpenRouterIntegration() async throws {
        let refiner = LLMRefiner(
            configuration: LLMRefinerConfiguration(
                enabled: true,
                baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                model: "meta-llama/llama-3.3-70b-instruct",
                timeoutMs: 15000
            ),
            apiKeyProvider: StaticRefinerAPIKeyProvider(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]),
            session: .shared
        )

        let outcome = await refiner.refine(
            "okay send this to to Sarah no wait send it to Morgan instead and mention the staging is broken",
            glossary: [], safety: .normalText, style: .standard)
        guard let refined = refinedString(outcome) else {
            Issue.record("OpenRouter refiner should return .refined for the self-correction prompt")
            return
        }
        let normalized = refined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        #expect(normalized.contains("morgan"))
        #expect(!normalized.contains("sarah"))
    }
    private func refinedString(_ outcome: RefineOutcome) -> String? {
        guard case .refined(let value) = outcome else { return nil }
        return value
    }
}
