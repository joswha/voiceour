import Foundation

/// The one place a bundle id becomes a human label. Pure: no NSWorkspace,
/// so the offscreen harness and tests resolve names identically everywhere.
public enum AppDisplayName {
    /// `name` when non-empty; else the most specific meaningful dot component of
    /// `bundleId` with its first letter uppercased; else "Unknown app".
    public static func label(bundleId: String?, name: String?) -> String {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let bundleId else { return unknown }
        let components = bundleId.split(separator: ".").filter { !$0.isEmpty }
        // A trailing "app" is a suffix, not a name: `com.cmuxterm.app` reads as
        // "App" under a plain last-component rule, which names nothing. Measured
        // on a real history where 59 of 104 rows carried that bundle id.
        let meaningful =
            components.count > 1 && components[components.count - 1].lowercased() == "app"
            ? components[components.count - 2]
            : components.last
        guard let component = meaningful else { return unknown }
        return component.prefix(1).uppercased() + component.dropFirst()
    }

    private static let unknown = "Unknown app"
}
