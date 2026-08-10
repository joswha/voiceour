import Foundation

/// Why a key lookup came back empty. `apiKey()` collapses every outcome to
/// `nil`, which makes "the user has not configured a key" indistinguishable from
/// "the keychain could not answer" — and those two must not be treated alike:
/// the first is a reason to try the next credential source, the second is not.
public enum RefinerAPIKeyReadOutcome: Equatable, Sendable {
    case found(String)
    case absent
    case unavailable(OSStatus)
}

extension RefinerAPIKeyProviding {
    /// Providers that cannot fail — environment, static, composite fixtures —
    /// inherit this: an empty answer is a genuine absence.
    public func readAPIKey() -> RefinerAPIKeyReadOutcome {
        guard let apiKey = apiKey(), !apiKey.isEmpty else { return .absent }
        return .found(apiKey)
    }
}

public struct EnvRefinerAPIKeyProvider: RefinerAPIKeyProviding, Sendable {
    private let names: [String]
    private let environment: [String: String]

    public init(
        names: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.names = names
        self.environment = environment
    }

    public func apiKey() -> String? {
        for name in names {
            if let value = environment[name], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public struct CompositeRefinerAPIKeyProvider: RefinerAPIKeyProviding, Sendable {
    private let providers: [any RefinerAPIKeyProviding]

    public init(_ providers: [any RefinerAPIKeyProviding]) {
        self.providers = providers
    }

    public func apiKey() -> String? {
        guard case .found(let apiKey) = readAPIKey() else { return nil }
        return apiKey
    }

    public func readAPIKey() -> RefinerAPIKeyReadOutcome {
        for provider in providers {
            switch provider.readAPIKey() {
            case .found(let apiKey):
                return .found(apiKey)
            case .absent:
                continue
            case .unavailable(let status):
                // Stop here rather than reaching for a lower-priority source. A
                // locked or unreachable keychain must not silently downgrade the
                // request to whatever key happens to be in the environment: that
                // sends a credential the user did not choose for this provider.
                return .unavailable(status)
            }
        }
        return .absent
    }
}
