import AppKit

/// One installed application as LaunchServices knows it: its user-facing name
/// and its icon.
///
/// The name is Finder's display name, which is what the reader calls the app —
/// localized, and honouring a rename in Finder. Neither field is derived from
/// anything Voiceour persisted; a persisted snapshot name is the caller's
/// fallback when this Mac no longer has the app.
public struct InstalledApp {
    public var name: String
    public var icon: NSImage

    public init(name: String, icon: NSImage) {
        self.name = name
        self.icon = icon
    }
}

/// Cached bundle-id to installed-app lookup.
///
/// Main-actor: every consumer is a view, `NSImage` is not `Sendable`, and the
/// cache is deliberately unsynchronized. Misses are cached too — a reader
/// dictates into a bounded set of apps, and the lookup is on a row that
/// re-renders whenever History reloads, so re-asking LaunchServices for an app
/// that is not installed would be a repeated disk walk for a known answer. An
/// app installed mid-session shows its icon after the next launch, which is an
/// accepted trade.
@MainActor
public enum InstalledAppCatalog {
    private static var cache: [String: InstalledApp?] = [:]

    public static func lookup(bundleId: String?) -> InstalledApp? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        if let cached = cache[bundleId] { return cached }
        let resolved = resolve(bundleId)
        cache[bundleId] = resolved
        return resolved
    }

    private static func resolve(_ bundleId: String) -> InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
            let name = cleanedDisplayName(FileManager.default.displayName(atPath: url.path))
        else { return nil }
        return InstalledApp(name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    /// Strips one trailing ".app" — Finder leaks the extension into
    /// `displayName(atPath:)` for a reader who turned on "show all filename
    /// extensions" — then trims, then answers nil for an empty result so the
    /// caller falls back rather than showing a blank label.
    nonisolated static func cleanedDisplayName(_ raw: String) -> String? {
        var name = raw
        if name.suffix(4).lowercased() == ".app" {
            name = String(name.dropLast(4))
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
