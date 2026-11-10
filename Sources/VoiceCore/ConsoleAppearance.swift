import Foundation

/// Whether the console and the menu follow macOS or keep one appearance.
///
/// Stored as its raw tag and resolved through ``resolved(_:)``: a value written by a
/// future build must not quarantine the settings file that holds the user's glossary.
public enum ConsoleAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// Unknown or missing values read as `.system`, the appearance macOS already asks for.
    public static func resolved(_ raw: String?) -> ConsoleAppearance {
        guard let raw, let appearance = ConsoleAppearance(rawValue: raw) else { return .system }
        return appearance
    }
}

/// The one colour the console acts in: primary buttons, switches, selection and links.
///
/// `.system` follows the Mac's own accent colour. Stored and resolved like
/// ``ConsoleAppearance``, so an unknown accent degrades to the default instead of throwing.
public enum ConsoleAccent: String, Codable, CaseIterable, Sendable {
    case system
    case green
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case graphite

    /// Unknown or missing values read as `.green`, the console's own signal colour.
    public static func resolved(_ raw: String?) -> ConsoleAccent {
        guard let raw, let accent = ConsoleAccent(rawValue: raw) else { return .green }
        return accent
    }
}
