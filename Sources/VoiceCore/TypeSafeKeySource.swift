import Foundation

/// Where the TypeSafe key comes from: the environment first, then an owner-only key file.
///
/// The environment wins so a developer can point one launch at a different key
/// without touching the file the app saved. The key value is returned only by
/// `key()`: this type adds no description, and nothing it throws or logs carries
/// the value, so a key cannot leak through a log line or an error report.
public struct TypeSafeKeySource: Sendable {
    public static let variable = "TYPESAFE_API_KEY"

    /// The source `key()` reads, so settings can say where the key came from
    /// without ever showing it.
    public enum Origin: Equatable, Sendable {
        case environment
        case keyFile
    }

    public var environment: [String: String]
    public var keyFile: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyFile: URL = TypeSafeKeySource.defaultKeyFile
    ) {
        self.environment = environment
        self.keyFile = keyFile
    }

    /// `typesafe.key` beside the other private Voiceour state, so it inherits
    /// the support directory's owner-only permissions and its test override.
    public static var defaultKeyFile: URL {
        URL.voiceourSupportDirectory().appendingPathComponent("typesafe.key")
    }

    /// The trimmed key, or nil when no source holds one. A blank value falls
    /// through to the next source rather than counting as a key.
    public func key() -> String? {
        resolved()?.key
    }

    /// The source `key()` would use, by the same rules.
    public func origin() -> Origin? {
        resolved()?.origin
    }

    /// Writes the trimmed key to the key file, owner-only and atomic. A blank
    /// key removes the file, which is how the user forgets a saved key.
    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try removeVoiceourPrivateState(at: keyFile)
        } else {
            try writeVoiceourPrivateState(Data(trimmed.utf8), to: keyFile)
        }
    }

    /// The first non-blank source. The key file is read only when the
    /// environment gave nothing, so an environment key never touches the disk.
    private func resolved() -> (key: String, origin: Origin)? {
        if let value = environment[Self.variable] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (trimmed, .environment) }
        }
        guard let contents = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed, .keyFile)
    }
}
