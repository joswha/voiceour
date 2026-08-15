import Foundation

/// Parses process arguments on behalf of the app layer.
public struct LaunchOptions: Equatable, Sendable {
    public var repoRoot: String?
    public var asrBackend: String?

    public init<Arguments: Sequence>(arguments: Arguments) where Arguments.Element == String {
        let values = Array(arguments)
        var index = values.startIndex
        while index < values.endIndex {
            let argument = values[index]
            switch argument {
            case "--repo-root":
                if let value = Self.value(after: index, in: values) { repoRoot = value }
            case "--asr-backend":
                if let value = Self.value(after: index, in: values) { asrBackend = Self.validBackend(value) }
            default:
                if let value = Self.inlineValue(for: "--repo-root", in: argument) {
                    repoRoot = value
                } else if let value = Self.inlineValue(for: "--asr-backend", in: argument) {
                    asrBackend = Self.validBackend(value)
                }
            }
            index += 1
        }
    }

    /// Backend ids accepted when validation is not supplied by a registry.
    public static let defaultBackendIDs: Set<String> = ["fake", "parakeet"]

    /// Backend ids that existed in shipped builds and no longer do.
    ///
    /// `mlx`, `ark-0.6b` and `ark-3b` ran the same Parakeet family through the retired Python
    /// sidecar. `apple` was the opt-in system transcriber, deleted after it lost every content
    /// axis to the local sidecar and nearly tripled ASR p95. Every source of a backend id —
    /// launch argument, environment, persisted settings — funnels through `validBackend`, so
    /// normalizing here means an existing install keeps working instead of silently dropping to
    /// the fake one.
    public static let retiredBackendIDs: [String: String] = [
        "mlx": "parakeet",
        "ark-0.6b": "parakeet",
        "ark-3b": "parakeet",
        "apple": "parakeet",
    ]

    /// Normalizes a backend id, rejecting anything unregistered.
    ///
    /// The default keeps VoiceCore free of the registry (which must import
    /// AVFoundation and Speech). Callers that have the registry pass its
    /// `backendIDs` so there is one source of truth at runtime; the default is
    /// only the fallback for argument parsing during `init`.
    ///
    /// `ASRBackendRegistryTests.launchOptionDefaultsMatchRegisteredBackends`
    /// enforces exact equality between this default and
    /// `ASRBackendRegistry.builtIn.backendIDs`.
    public static func validBackend(
        _ value: String?,
        validBackendIDs: Set<String> = Self.defaultBackendIDs
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolved = retiredBackendIDs[normalized] ?? normalized
        return validBackendIDs.contains(resolved) ? resolved : nil
    }

    private static func value(after index: Array<String>.Index, in values: [String]) -> String? {
        let nextIndex = index + 1
        guard nextIndex < values.endIndex else { return nil }
        let value = values[nextIndex]
        return value.hasPrefix("--") ? nil : value
    }

    private static func inlineValue(for option: String, in argument: String) -> String? {
        let prefix = option + "="
        guard argument.hasPrefix(prefix) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }
}
