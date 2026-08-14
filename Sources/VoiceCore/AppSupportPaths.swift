import Foundation

extension URL {
    /// `~/Library/Application Support/Voiceour/` — the base for persisted
    /// settings, recent-session history, and OMP onboarding/RPC state.
    ///
    /// Deliberately not named `applicationSupportDirectory`: Foundation already
    /// vends that symbol for the container itself, and shadowing it with this
    /// subdirectory would silently repoint every caller.
    public static var voiceourSupportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Voiceour", isDirectory: true)
    }
}

func writeVoiceourPrivateState(_ data: Data, to url: URL) throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try data.write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// One encoder configuration for every persisted Voiceour file. `sortedKeys`
/// keeps the on-disk bytes stable across launches, so a settings or history
/// file changes only when its content actually does — and a store that adopts
/// this helper cannot drift from the others by forgetting a formatting option.
func writeVoiceourPrivateJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeVoiceourPrivateState(encoder.encode(value), to: url)
}

/// Removal is idempotent: an already-absent file is exactly the state the
/// caller asked for, so only a failure that leaves the file on disk is an error.
func removeVoiceourPrivateState(at url: URL) throws {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        if FileManager.default.fileExists(atPath: url.path) {
            throw error
        }
    }
}
