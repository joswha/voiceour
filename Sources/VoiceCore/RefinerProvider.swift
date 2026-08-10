public enum RefinerProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case gemini
    case openAI
    case openRouter
    case omp
    case appleOnDevice
    case custom

    public var displayName: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .omp: "Oh My Pi"
        case .appleOnDevice: "Apple On-Device"
        case .custom: "Custom"
        }
    }

    /// Effective OpenAI-compatible base URL for non-custom providers. Empty for custom.
    var defaultBaseURL: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .omp: ""
        case .appleOnDevice: ""
        case .custom: ""
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .gemini: ["gemini-2.5-flash-lite", "gemini-3.1-flash-lite", "gemini-2.5-flash"]
        case .openAI: ["gpt-4.1-nano", "gpt-5-nano", "gpt-4.1-mini"]
        case .openRouter: ["meta-llama/llama-3.3-70b-instruct", "google/gemini-2.5-flash-lite", "x-ai/grok-4.20"]
        case .omp:
            [
                "anthropic/claude-haiku-4-5",
                "openai-codex/gpt-5.5",
                "google-gemini-cli/gemini-2.5-flash",
                "kimi-code/k3",
                "openai-codex/gpt-5.3-codex-spark",
            ]
        case .appleOnDevice: ["on-device"]
        case .custom: []
        }
    }

    /// Where the user gets a key. nil for custom.
    public var apiKeyURL: String? {
        switch self {
        case .gemini: "https://aistudio.google.com/apikey"
        case .openAI: "https://platform.openai.com/api-keys"
        case .openRouter: "https://openrouter.ai/keys"
        case .omp: nil
        case .appleOnDevice: nil
        case .custom: nil
        }
    }

    /// Environment variable holding this provider's key. nil for custom.
    public var apiKeyEnvName: String? {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        case .omp: nil
        case .appleOnDevice: nil
        case .custom: nil
        }
    }

    public var isCustom: Bool { self == .custom }
}

public enum RefinerResolved: Sendable {
    /// Effective base URL: custom -> user field; else provider default.
    public static func baseURL(_ s: Settings) -> String {
        s.refinerProvider == .custom ? s.refinerBaseURL : s.refinerProvider.defaultBaseURL
    }

    /// The provider's built-in endpoint, ignoring any custom field. Exposed so a
    /// descriptor outside this module can carry the same value the enum defines
    /// instead of restating it.
    public static func defaultBaseURL(_ provider: RefinerProvider) -> String {
        provider.defaultBaseURL
    }

    /// Effective model: explicit refinerModel if non-empty; else provider's first suggested.
    public static func model(_ s: Settings) -> String {
        s.refinerModel.isEmpty ? (s.refinerProvider.suggestedModels.first ?? "") : s.refinerModel
    }
}

public enum RefinerReadiness: Equatable, Sendable {
    case disabled, needsBaseURL, needsModel, needsKey, ready

    public var label: String {
        switch self {
        case .disabled: "OFF"
        case .needsBaseURL: "NEEDS BASE URL"
        case .needsModel: "NEEDS MODEL"
        case .needsKey: "NEEDS KEY"
        case .ready: "READY"
        }
    }

    public var isReady: Bool { self == .ready }

    public static func evaluate(settings: Settings, hasKey: Bool) -> RefinerReadiness {
        guard settings.refinerEnabled else { return .disabled }
        if settings.refinerProvider == .omp {
            if RefinerResolved.model(settings).isEmpty { return .needsModel }
            return .ready
        }
        if settings.refinerProvider == .appleOnDevice {
            // The system model needs no base URL, key, or model choice; runtime
            // availability (Apple Intelligence state) is checked by the refiner.
            return .ready
        }
        if RefinerResolved.baseURL(settings).isEmpty { return .needsBaseURL }
        if RefinerResolved.model(settings).isEmpty { return .needsModel }
        if settings.refinerProvider == .custom { return .ready }
        if !hasKey { return .needsKey }
        return .ready
    }
}

public enum RefinerKeySource: Equatable, Sendable {
    case none, keychain, environment

    public var label: String {
        switch self {
        case .none: "NO KEY"
        case .keychain: "KEY SAVED"
        case .environment: "KEY VIA ENV"
        }
    }

}

public enum RefinerReachability: Equatable, Sendable {
    case unknown, checking
    case ok(models: Int)
    case unauthorized
    case failed(String)
}
