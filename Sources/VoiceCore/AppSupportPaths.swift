import Foundation

extension URL {
    /// `~/Library/Application Support/Voiceour/` — the base for persisted
    /// settings and recent-session history.
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

/// Moves an unreadable durable file aside and returns where it went.
///
/// The alternative to quarantine is one of two worse things: refusing to launch
/// on a file the user cannot see or edit, or silently overwriting it with
/// defaults and destroying whatever could have been recovered from it — a
/// glossary someone spent months teaching, in the settings case. The suffix is
/// the failure's timestamp so repeated launches cannot collide, and the caller
/// reports the path so the file is discoverable rather than merely preserved.
public func quarantineUnreadableVoiceourState(at url: URL) -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let stamp = ISO8601DateFormatter.voiceourFileStamp.string(from: Date())
    let destination = url.deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
    do {
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    } catch {
        return nil
    }
}

extension ISO8601DateFormatter {
    /// Colons are legal in HFS+/APFS names but read as path separators to
    /// Carbon-era APIs and to anyone pasting the name into a shell, so the
    /// quarantine stamp omits them.
    static let voiceourFileStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter
    }()
}
