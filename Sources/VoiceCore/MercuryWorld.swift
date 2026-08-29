/// Which generated room the recording island's mercury reflects.
///
/// Two worlds ship and both write into the same prefiltered linear-RGB tables, exact
/// conductor Fresnel and bounded display-response path. Both are static after their seed
/// draw; only the mercury surface moves. Only `roomOfTen` is reachable without `--debug`.
///
/// Stored as its raw tag and resolved through ``resolved(_:)``, exactly like
/// ``ASRModelVariant``: a decode failure here would quarantine the whole settings file
/// over one unknown word.
public enum MercuryWorld: String, Codable, Equatable, CaseIterable, Sendable {
    /// Bounded stratified area sources over a neutral room bounce. The default.
    case roomOfTen = "room_of_ten"
    /// A static lognormal spherical-harmonic room. Debug comparison only.
    case spectralWeather = "spectral_weather"

    /// The compiled default, and where a stale or unknown persisted value lands.
    public static let `default` = MercuryWorld.roomOfTen

    /// What the debug picker shows.
    public var displayName: String {
        switch self {
        case .roomOfTen: return "Room of Ten"
        case .spectralWeather: return "Spectral Weather"
        }
    }

    /// A value written by a future build must not quarantine the settings file.
    public static func resolved(_ rawValue: String?) -> MercuryWorld {
        guard let rawValue, let world = MercuryWorld(rawValue: rawValue) else { return .default }
        return world
    }
}
