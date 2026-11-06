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
    public static let defaultBackendIDs: Set<String> = ["fake", "granite"]

    /// Backend ids that existed in shipped builds and no longer do.
    ///
    /// `parakeet` was the NVIDIA Parakeet TDT recognizer; `mlx`, `ark-0.6b` and `ark-3b` ran
    /// the same family through an earlier Python sidecar; `apple` was the opt-in system
    /// transcriber. Every one now runs Granite, the one local recognizer. Every source of a
    /// backend id — launch argument, environment, persisted settings — funnels through
    /// `validBackend`, so normalizing here means an existing install keeps real dictation instead
    /// of silently dropping to the fake backend, and `client(for: "parakeet")` callers get Granite.
    public static let retiredBackendIDs: [String: String] = [
        "parakeet": "granite",
        "mlx": "granite",
        "ark-0.6b": "granite",
        "ark-3b": "granite",
        "apple": "granite",
    ]

    /// Normalizes a backend id, rejecting anything unregistered.
    ///
    /// The default keeps VoiceCore free of the registry, which lives in VoiceMac
    /// and imports AVFoundation. Callers that have the registry pass its
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

    /// The backend a PERSISTED settings file may select: one only in a debug launch, where it
    /// is the Backend picker's saved choice. A release build has no backend picker, and every
    /// launch writes its resolved id into settings, so a release launch that honored the file
    /// would pin users to whatever an earlier launch ran — synthetic `fake` transcripts, or a
    /// backend that is no longer the default — with no way back. Launch arguments and the
    /// environment are unaffected.
    public static func persistedBackend(
        _ value: String?,
        validBackendIDs: Set<String>,
        allowsDevBackend: Bool
    ) -> String? {
        guard allowsDevBackend else { return nil }
        return validBackend(value, validBackendIDs: validBackendIDs)
    }

    /// The backend a launch runs, highest precedence first: the `--asr-backend` argument,
    /// then `VOICEOUR_ASR_BACKEND`, then the persisted setting (`persistedBackend`'s rules),
    /// then the registry default. Every source normalizes through `validBackend`, so an
    /// invalid value falls through to the next source instead of winning, and a retired id
    /// normalizes at its own source's precedence.
    ///
    /// `launchArgument` is `asrBackend` as parsed, already normalized.
    public static func resolvedBackend(
        launchArgument: String?,
        environment: String?,
        persisted: String?,
        validBackendIDs: Set<String>,
        allowsDevBackend: Bool,
        defaultBackend: String
    ) -> String {
        launchArgument
            ?? validBackend(environment, validBackendIDs: validBackendIDs)
            ?? persistedBackend(persisted, validBackendIDs: validBackendIDs, allowsDevBackend: allowsDevBackend)
            ?? defaultBackend
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
