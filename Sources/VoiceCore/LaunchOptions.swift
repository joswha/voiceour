import Foundation

/// Parses process arguments on behalf of the app layer.
public struct LaunchOptions: Equatable, Sendable {
    public var repoRoot: String?
    public var asrDirectory: String?
    public var asrBackend: String?

    public init<Arguments: Sequence>(arguments: Arguments) where Arguments.Element == String {
        let values = Array(arguments)
        var index = values.startIndex
        while index < values.endIndex {
            let argument = values[index]
            switch argument {
            case "--repo-root":
                if let value = Self.value(after: index, in: values) { repoRoot = value }
            case "--asr-dir":
                if let value = Self.value(after: index, in: values) { asrDirectory = value }
            case "--asr-backend":
                if let value = Self.value(after: index, in: values) { asrBackend = Self.validBackend(value) }
            default:
                if let value = Self.inlineValue(for: "--repo-root", in: argument) {
                    repoRoot = value
                } else if let value = Self.inlineValue(for: "--asr-dir", in: argument) {
                    asrDirectory = value
                } else if let value = Self.inlineValue(for: "--asr-backend", in: argument) {
                    asrBackend = Self.validBackend(value)
                }
            }
            index += 1
        }
    }

    /// Normalizes a backend id, rejecting anything unregistered.
    ///
    /// The default keeps VoiceCore free of the registry (which must import
    /// AVFoundation and Speech). Callers that have the registry pass its
    /// `backendIDs` so there is one source of truth at runtime; the default is
    /// only the fallback for argument parsing during `init`.
    ///
    /// That default has to track `ASRBackendRegistry.builtIn` in
    /// `Sources/VoiceMac/ASRBackendRegistry.swift` by hand — VoiceCore cannot
    /// import VoiceMac to read it. An id registered there but missing here is
    /// rejected on the command line even though the app can build it.
    public static func validBackend(
        _ value: String?,
        validBackendIDs: Set<String> = ["fake", "mlx", "apple", "ark-0.6b", "ark-3b"]
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return validBackendIDs.contains(normalized) ? normalized : nil
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
