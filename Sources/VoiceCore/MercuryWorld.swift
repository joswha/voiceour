/// Which generated room the recording island's body reflects.
///
/// Two rooms ship, and both are user choices in Settings ▸ Island
/// (``IslandAppearance/room``): Studio and Overcast. Both fill the same prefiltered linear-RGB
/// tables that every metal and coat reflects, and both are static after their seed draw; only
/// the body moves.
///
/// Stored as its raw tag and resolved through ``resolved(_:)``, exactly like
/// ``ASRModelVariant``: a decode failure here would quarantine the whole settings file
/// over one unknown word.
public enum MercuryWorld: String, Codable, Equatable, CaseIterable, Sendable {
    /// Studio: bounded stratified area sources over a neutral room bounce. The default.
    case roomOfTen = "room_of_ten"
    /// Overcast: a static lognormal spherical-harmonic sky.
    case spectralWeather = "spectral_weather"

    /// The compiled default, and where a stale or unknown persisted value lands.
    public static let `default` = MercuryWorld.roomOfTen

    /// What Settings ▸ Island calls the room. The raw tags keep the renderer's names, so a
    /// value already on disk still resolves.
    public var displayName: String {
        switch self {
        case .roomOfTen: return "Studio"
        case .spectralWeather: return "Overcast"
        }
    }

    /// A value written by a future build must not quarantine the settings file.
    public static func resolved(_ rawValue: String?) -> MercuryWorld {
        guard let rawValue, let world = MercuryWorld(rawValue: rawValue) else { return .default }
        return world
    }
}
