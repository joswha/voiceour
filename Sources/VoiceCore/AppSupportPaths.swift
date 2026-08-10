import Foundation

extension URL {
    /// `~/Library/Application Support/VoiceOour/` — the base for persisted
    /// settings, recent-session history, and OMP onboarding/RPC state.
    ///
    /// Deliberately not named `applicationSupportDirectory`: Foundation already
    /// vends that symbol for the container itself, and shadowing it with this
    /// subdirectory would silently repoint every caller.
    public static var voiceOourSupportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoiceOour", isDirectory: true)
    }
}

func writeVoiceOourPrivateState(_ data: Data, to url: URL) throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try data.write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
