import Dispatch
import Foundation

/// Subscription choices VoiceOour names directly. `other` delegates provider
/// selection to OMP so newly added login providers remain reachable without an
/// app update.
public enum OmpSubscription: String, CaseIterable, Hashable, Sendable, Identifiable {
    case chatGPT
    case claude
    case gemini
    case kimi
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .kimi: "Kimi"
        case .other: "Other"
        }
    }

    /// OMP's provider id. `nil` asks OMP to show its current interactive list.
    public var providerID: String? {
        switch self {
        case .chatGPT: "openai-codex"
        case .claude: "anthropic"
        case .gemini: "google-gemini-cli"
        case .kimi: "kimi-code"
        case .other: nil
        }
    }

    /// A fast refinement model to select after a successful provider login.
    public var preferredModel: String? {
        switch self {
        case .chatGPT: "openai-codex/gpt-5.5"
        case .claude: "anthropic/claude-haiku-4-5"
        case .gemini: "google-gemini-cli/gemini-2.5-flash"
        case .kimi: "kimi-code/k3"
        case .other: nil
        }
    }

    public static func matching(model: String) -> OmpSubscription? {
        let provider = model.split(separator: "/", maxSplits: 1).first.map(String.init)
        return allCases.first { $0.providerID == provider }
    }
}

/// The subset of OMP's model JSON VoiceOour needs for post-login selection.
public struct OmpAvailableModel: Decodable, Equatable, Sendable {
    public let provider: String
    public let selector: String
    public let name: String

    public init(provider: String, selector: String, name: String) {
        self.provider = provider
        self.selector = selector
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case selector
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let selector = try container.decode(String.self, forKey: .selector)
        self.selector = selector
        self.provider =
            try container.decodeIfPresent(String.self, forKey: .provider)
            ?? selector.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? selector
    }
}

private struct OmpModelsEnvelope: Decodable {
    let models: [OmpAvailableModel]
}

enum OmpModelCatalogError: Error, Equatable {
    case invalidJSON

    var shortMessage: String {
        switch self {
        case .invalidJSON: "invalid models JSON"
        }
    }
}

/// Shared OMP model loader used by the Model picker, reachability and
/// onboarding. It runs in the same hermetic profile as refinement, so the list
/// is the one the subscription-backed path can serve rather than anything an
/// API key inherited from the launching shell would add.
///
/// It is the one omp call that deliberately runs without the credential
/// tombstones: omp advertises a provider whenever its variable is *set*, so a
/// shadowed query answers with 50 providers the refiner cannot reach, and with
/// `GITLAB_TOKEN=" "` it never answers at all. See `OmpEnvironment.augmented`.
public enum OmpModelCatalog {
    public static func load(
        executableURL: URL,
        argumentPrefix: [String],
        providerID: String? = nil,
        timeoutMs: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileDirectory: URL? = OmpRpcProfile.defaultDirectory()
    ) async throws -> [OmpAvailableModel] {
        let start = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(max(timeoutMs, 1)) * 1_000_000
        let (deadline, overflow) = start.addingReportingOverflow(duration)

        if let profileDirectory {
            try OmpRpcProfile.provision(
                at: profileDirectory,
                environment: OmpEnvironment.augmented(
                    environment,
                    workingDirectory: profileDirectory
                )
            )
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = overflow || deadline > now ? (overflow ? UInt64.max : deadline - now) : 0
        guard remaining > 0 else { throw OmpProcessError.timeout }
        let remainingMs =
            remaining == UInt64.max
            ? Int.max
            : Int(min(remaining / 1_000_000 + 1, UInt64(Int.max)))
        var arguments = argumentPrefix + ["models"]
        if let providerID, !providerID.isEmpty {
            arguments.append(providerID)
        }
        arguments.append("--json")
        let stdout = try await OmpProcess.run(
            executableURL: executableURL,
            arguments: arguments,
            timeoutMs: remainingMs,
            environment: environment,
            currentDirectoryURL: profileDirectory,
            shadowCredentials: false
        )
        guard
            let envelope = try? JSONDecoder().decode(
                OmpModelsEnvelope.self,
                from: Data(stdout.utf8)
            )
        else {
            throw OmpModelCatalogError.invalidJSON
        }
        return envelope.models
    }
}
