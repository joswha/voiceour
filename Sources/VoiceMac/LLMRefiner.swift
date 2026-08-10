import Foundation
import VoiceCore

public struct LLMRefinerConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: URL?
    public var model: String
    public var timeoutMs: Int

    public init(enabled: Bool, baseURL: URL?, model: String, timeoutMs: Int = 3000) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeoutMs = timeoutMs
    }
}

public protocol RefinerAPIKeyProviding: Sendable {
    func apiKey() -> String?
    /// Why an empty answer is empty. This has to be a protocol requirement, not
    /// just an extension member: a caller holding `any RefinerAPIKeyProviding`
    /// statically dispatches extension members, so a store's real outcome would
    /// be silently replaced by the default derived from `apiKey()`.
    func readAPIKey() -> RefinerAPIKeyReadOutcome
}

public struct StaticRefinerAPIKeyProvider: RefinerAPIKeyProviding, Sendable {
    private let value: String?
    public init(_ value: String?) { self.value = value }
    public func apiKey() -> String? { value }
}

public final class LLMRefiner: TranscriptRefining, @unchecked Sendable {
    private let configuration: LLMRefinerConfiguration
    private let apiKeyProvider: RefinerAPIKeyProviding
    private let session: URLSession
    private let deterministicFallback: ((String) -> String)?

    public init(
        configuration: LLMRefinerConfiguration,
        apiKeyProvider: RefinerAPIKeyProviding = StaticRefinerAPIKeyProvider(nil),
        session: URLSession = .shared,
        deterministicFallback: ((String) -> String)? = nil
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.deterministicFallback = deterministicFallback
    }

    public func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle)
        async -> RefineOutcome
    {
        let fallback = RefinerPolicy.deterministicFallback(for: raw, using: deterministicFallback)
        if let reason = RefinerPolicy.preflightSkipReason(
            enabled: configuration.enabled,
            safety: safety,
            isConfigured: configuration.baseURL != nil && !configuration.model.isEmpty
        ) {
            return .skipped(reason: reason)
        }

        let apiKey = apiKeyProvider.apiKey()
        let url = configuration.baseURL!.appendingPathComponent("chat/completions")
        if let apiKey, !apiKey.isEmpty, !RefinerEndpointPolicy.allowsCredential(url) {
            return .skipped(reason: "credential_endpoint_refused")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let timeoutMs = RefinerPolicy.effectiveTimeoutMs(configuredMs: configuration.timeoutMs, transcript: raw)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let cloudGlossary = RefinerPolicy.cloudEligible(glossary)
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                [
                    "role": "user",
                    "content": RefinerPolicy.llmUserMessage(raw: raw, glossary: cloudGlossary, style: style),
                ],
            ],
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let configuredRequest = request
            let (data, response) = try await withWallClockTimeout(
                timeoutNanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000,
                timeoutError: { URLError(.timedOut) },
                operation: {
                    try await self.session.data(for: configuredRequest)
                }
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .fellBack(fallback, reason: "http_\(status)") }
            let finalText = try Self.extractFinalText(from: data)
            return RefinerPolicy.guardedOutcome(
                original: raw, candidate: finalText, glossary: glossary, fallback: fallback)
        } catch {
            return .fellBack(fallback, reason: "request_failed")
        }
    }

    static func extractFinalText(from data: Data) throws -> String {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        let contentData = Data(content.utf8)
        let object = try JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        guard let finalText = object?["final_text"] as? String,
            !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CocoaError(.coderInvalidValue)
        }
        return finalText
    }

    static let systemPrompt = RefinerPolicy.systemPrompt(for: .json)
}
