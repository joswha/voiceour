import Foundation

// MARK: - Grids

/// One integer control of the island's look: its legal range, its spacing and its stock value.
///
/// Every value the garage stores is an integer in UI units on one of these grids. A look then
/// compares by exact equality, a slider publishes integral accessibility values, and a value
/// decoded from disk or drawn by Surprise Me lands on a point a slider can reach.
public struct IslandGrid: Equatable, Sendable {
    public let range: ClosedRange<Int>
    public let step: Int
    public let stock: Int

    /// The grid point nearest `value` once it is clamped into `range`.
    ///
    /// Ties round up. The result never passes the last grid point, so a range whose upper
    /// bound is off the grid still snaps inside itself.
    public func snap(_ value: Int) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let lastIndex = (range.upperBound - range.lowerBound) / step
        let index = min((clamped - range.lowerBound + step / 2) / step, lastIndex)
        return range.lowerBound + index * step
    }
}

/// The grid of every integer island control except the film, whose grid belongs to the coat
/// (``IslandCoat/film``).
///
/// Each comment quotes how the renderer reads the value, so a range change is reviewed against
/// the mapping it feeds.
public enum IslandGrids {
    /// Candy dye hue, degrees.
    public static let candyHue = IslandGrid(range: 0...359, step: 1, stock: 355)
    /// Candy dye saturation, percent.
    public static let candySaturation = IslandGrid(range: 0...100, step: 1, stock: 90)
    /// Candy dye brightness, percent.
    public static let candyBrightness = IslandGrid(range: 10...100, step: 1, stock: 80)
    /// Surface roughness `r = 0.03·(25/3)^(v/100)`; 0 is the stock mirror.
    public static let finish = IslandGrid(range: 0...100, step: 5, stock: 0)
    /// Room white balance `t = v/100`, cool below 0 and warm above.
    public static let temperature = IslandGrid(range: -100...100, step: 10, stock: 0)
    /// Underglow hue, degrees.
    public static let underglowHue = IslandGrid(range: 0...359, step: 1, stock: 190)
    /// Underglow saturation, percent.
    public static let underglowSaturation = IslandGrid(range: 0...100, step: 1, stock: 80)
    /// Underglow strength `s = v/100`.
    public static let underglowStrength = IslandGrid(range: 10...100, step: 10, stock: 60)
    /// Display-response middle tone `b = v/100`.
    public static let brightness = IslandGrid(range: -100...100, step: 10, stock: 0)
    /// Display-response highlight spread `c = v/100`.
    public static let contrast = IslandGrid(range: -100...100, step: 10, stock: 0)
    /// Length and thickness together, percent; stock is the largest body the island holds.
    public static let size = IslandGrid(range: 85...100, step: 1, stock: 100)
    /// Thickness alone, percent.
    public static let build = IslandGrid(range: 80...100, step: 2, stock: 100)
    /// Crown aspect `β = v/100`.
    public static let crown = IslandGrid(range: 60...100, step: 2, stock: 78)
    /// End taper `gEnd = 0.46 − 0.0016·v`.
    public static let taper = IslandGrid(range: 0...100, step: 10, stock: 0)
    /// Time scale of every ripple, percent of stock.
    public static let tempo = IslandGrid(range: 70...150, step: 10, stock: 100)
    /// Ripple damping, percent of stock.
    public static let viscosity = IslandGrid(range: 50...200, step: 10, stock: 100)
    /// Autonomous motion between words, percent of stock.
    public static let shimmer = IslandGrid(range: 0...200, step: 10, stock: 100)
    /// Voice drive gains, percent of stock.
    public static let reactivity = IslandGrid(range: 50...150, step: 10, stock: 100)
    /// Contact-line voice gain and autonomous kicks, percent of stock.
    public static let slither = IslandGrid(range: 75...250, step: 5, stock: 100)
    /// Shape time scale `m = v/100`: the aspect and sway gels and the skew and neck modulators run
    /// `m` times as slowly; the volume never.
    public static let morph = IslandGrid(range: 60...160, step: 10, stock: 100)
    /// Outcome-gesture impulses, percent of stock.
    public static let drama = IslandGrid(range: 50...300, step: 10, stock: 100)
}

// MARK: - Material

/// The conductor the island's body is made of.
///
/// Its color is the metal's own complex-refractive-index reflection of the room; nothing is
/// painted. Stored as its raw tag and resolved through ``resolved(_:)``, like ``MercuryWorld``.
public enum IslandMetal: String, Codable, CaseIterable, Sendable {
    case mercury
    case silver
    case aluminum
    case chromium
    case platinum
    case titanium
    case gold
    case copper

    /// The shipped liquid-mercury body.
    public static let stock = IslandMetal.mercury

    /// What Settings ▸ Island shows; chromium goes by its trade name.
    public var displayName: String {
        switch self {
        case .mercury: return "Mercury"
        case .silver: return "Silver"
        case .aluminum: return "Aluminum"
        case .chromium: return "Chrome"
        case .platinum: return "Platinum"
        case .titanium: return "Titanium"
        case .gold: return "Gold"
        case .copper: return "Copper"
        }
    }

    /// A metal written by a future build must not quarantine the settings file.
    public static func resolved(_ rawValue: String?) -> IslandMetal {
        guard let rawValue, let metal = IslandMetal(rawValue: rawValue) else { return .stock }
        return metal
    }
}

/// What covers the metal.
///
/// Every coat colors the body physically, through a lacquer's reflection and absorption or
/// through thin-film interference whose color the film thickness sets
/// (``IslandAppearance/film``). Stored and resolved like ``IslandMetal``.
public enum IslandCoat: String, Codable, CaseIterable, Sendable {
    /// Bare metal.
    case none
    /// A thick clear lacquer: a slightly darker face and a whiter edge.
    case clear
    /// The clear lacquer, dyed with the appearance's candy color.
    case candy
    /// A thin titanium-dioxide film whose thickness sets a soft tint.
    case pearl
    /// A titanium-dioxide film across anodizing's range of thicknesses: bronze, blue, gold, green.
    case anodized
    /// A thick silica film: rainbow bands that slide across the body as it moves.
    case oilSlick = "oil_slick"
    /// A silica spacer under 8 nm of chromium. The absorbing chromium makes the color shift
    /// show even on silver and aluminum, which a bare oxide film barely tints.
    case chameleon

    public static let stock = IslandCoat.none

    /// What Settings ▸ Island shows.
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .clear: return "Clear Coat"
        case .candy: return "Candy"
        case .pearl: return "Pearl"
        case .anodized: return "Anodized"
        case .oilSlick: return "Oil Slick"
        case .chameleon: return "Chameleon"
        }
    }

    /// The film-thickness grid in nanometers, or nil for a coat that has no film.
    public var film: IslandGrid? {
        switch self {
        case .pearl: return IslandGrid(range: 60...140, step: 5, stock: 70)
        case .anodized: return IslandGrid(range: 20...220, step: 5, stock: 50)
        case .oilSlick: return IslandGrid(range: 250...700, step: 10, stock: 450)
        case .chameleon: return IslandGrid(range: 300...550, step: 10, stock: 350)
        case .none, .clear, .candy: return nil
        }
    }

    /// A coat written by a future build must not quarantine the settings file.
    public static func resolved(_ rawValue: String?) -> IslandCoat {
        guard let rawValue, let coat = IslandCoat(rawValue: rawValue) else { return .stock }
        return coat
    }
}

// MARK: - Appearance

/// The recording island's look from Settings ▸ Island: material, room lighting, body kit and
/// motion law.
///
/// Besides the metal, coat, room and underglow switch, every field is an integer in UI units on
/// a fixed grid (``IslandGrids``, ``IslandCoat/film``), so looks compare by exact equality and
/// random draws land where a slider can reach. The renderer maps the units to physics; this
/// type only stores and normalizes them.
///
/// Decoding never fails over a field: a missing or wrong-typed value takes its stock value, an
/// unknown metal, coat or room resolves to stock, and an out-of-range number is clamped and
/// snapped. ``Settings`` decodes an `island` that is not an object at all as stock, so nothing
/// about the island's look can quarantine the file that holds the user's glossary.
public struct IslandAppearance: Codable, Equatable, Sendable {
    // Material: metal, coat, film, candy dye and finish.
    public var metal: IslandMetal = .stock
    public var coat: IslandCoat = .stock
    /// Film thickness in nanometers on `coat.film`'s grid; 0 while the coat has no film.
    public var film: Int = 0
    /// The candy dye, as HSB. Kept under every coat so that returning to Candy restores it;
    /// ``canonical`` ignores it under any other coat.
    public var candyHue: Int = IslandGrids.candyHue.stock
    public var candySaturation: Int = IslandGrids.candySaturation.stock
    public var candyBrightness: Int = IslandGrids.candyBrightness.stock
    public var finish: Int = IslandGrids.finish.stock

    // Lighting: room, temperature, underglow, brightness and contrast.
    public var room: MercuryWorld = .default
    public var temperature: Int = IslandGrids.temperature.stock
    /// A colored light beneath the body, reflected like the rest of the room. Its color and
    /// strength are kept while it is off; ``canonical`` ignores them then.
    public var underglow: Bool = false
    public var underglowHue: Int = IslandGrids.underglowHue.stock
    public var underglowSaturation: Int = IslandGrids.underglowSaturation.stock
    public var underglowStrength: Int = IslandGrids.underglowStrength.stock
    /// The display response's two anchors. Increase Contrast overrides both, so the island
    /// keeps its accessible tone whatever the user chose.
    public var brightness: Int = IslandGrids.brightness.stock
    public var contrast: Int = IslandGrids.contrast.stock

    // Body kit: size, build, crown and taper. A drawing transform; the dynamics are unchanged.
    public var size: Int = IslandGrids.size.stock
    public var build: Int = IslandGrids.build.stock
    public var crown: Int = IslandGrids.crown.stock
    public var taper: Int = IslandGrids.taper.stock

    // Motion law: each a multiplier on the stock dynamics. Reduce Motion still zeroes the
    // autonomous motion whatever `shimmer` and `slither` say.
    public var tempo: Int = IslandGrids.tempo.stock
    public var viscosity: Int = IslandGrids.viscosity.stock
    public var shimmer: Int = IslandGrids.shimmer.stock
    public var reactivity: Int = IslandGrids.reactivity.stock
    public var slither: Int = IslandGrids.slither.stock
    public var morph: Int = IslandGrids.morph.stock
    public var drama: Int = IslandGrids.drama.stock

    /// The shipped island, which the renderer draws byte for byte as it always has.
    public static let stock = IslandAppearance()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case metal
        case coat
        case film
        case candyHue = "candy_hue"
        case candySaturation = "candy_saturation"
        case candyBrightness = "candy_brightness"
        case finish
        case room
        case temperature
        case underglow
        case underglowHue = "underglow_hue"
        case underglowSaturation = "underglow_saturation"
        case underglowStrength = "underglow_strength"
        case brightness
        case contrast
        case size
        case build
        case crown
        case taper
        case tempo
        case viscosity
        case shimmer
        case reactivity
        case slither
        case morph
        case drama
    }

    /// Reads every field on its own, so one bad value costs only that field.
    ///
    /// A missing film takes its coat's stock thickness: 0 would snap to the thinnest film the
    /// coat allows, a color nobody chose.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int? {
            try? container.decodeIfPresent(Int.self, forKey: key)
        }
        func string(_ key: CodingKeys) -> String? {
            try? container.decodeIfPresent(String.self, forKey: key)
        }
        self.init()
        metal = IslandMetal.resolved(string(.metal))
        coat = IslandCoat.resolved(string(.coat))
        film = int(.film) ?? coat.film?.stock ?? 0
        candyHue = int(.candyHue) ?? candyHue
        candySaturation = int(.candySaturation) ?? candySaturation
        candyBrightness = int(.candyBrightness) ?? candyBrightness
        finish = int(.finish) ?? finish
        room = MercuryWorld.resolved(string(.room))
        temperature = int(.temperature) ?? temperature
        underglow = (try? container.decodeIfPresent(Bool.self, forKey: .underglow)) ?? underglow
        underglowHue = int(.underglowHue) ?? underglowHue
        underglowSaturation = int(.underglowSaturation) ?? underglowSaturation
        underglowStrength = int(.underglowStrength) ?? underglowStrength
        brightness = int(.brightness) ?? brightness
        contrast = int(.contrast) ?? contrast
        size = int(.size) ?? size
        build = int(.build) ?? build
        crown = int(.crown) ?? crown
        taper = int(.taper) ?? taper
        tempo = int(.tempo) ?? tempo
        viscosity = int(.viscosity) ?? viscosity
        shimmer = int(.shimmer) ?? shimmer
        reactivity = int(.reactivity) ?? reactivity
        slither = int(.slither) ?? slither
        morph = int(.morph) ?? morph
        drama = int(.drama) ?? drama
        self = snapped()
    }

    /// Every field clamped and snapped onto its grid; the film onto its coat's grid, or 0.
    public func snapped() -> IslandAppearance {
        var result = self
        result.film = coat.film?.snap(film) ?? 0
        result.candyHue = IslandGrids.candyHue.snap(candyHue)
        result.candySaturation = IslandGrids.candySaturation.snap(candySaturation)
        result.candyBrightness = IslandGrids.candyBrightness.snap(candyBrightness)
        result.finish = IslandGrids.finish.snap(finish)
        result.temperature = IslandGrids.temperature.snap(temperature)
        result.underglowHue = IslandGrids.underglowHue.snap(underglowHue)
        result.underglowSaturation = IslandGrids.underglowSaturation.snap(underglowSaturation)
        result.underglowStrength = IslandGrids.underglowStrength.snap(underglowStrength)
        result.brightness = IslandGrids.brightness.snap(brightness)
        result.contrast = IslandGrids.contrast.snap(contrast)
        result.size = IslandGrids.size.snap(size)
        result.build = IslandGrids.build.snap(build)
        result.crown = IslandGrids.crown.snap(crown)
        result.taper = IslandGrids.taper.snap(taper)
        result.tempo = IslandGrids.tempo.snap(tempo)
        result.viscosity = IslandGrids.viscosity.snap(viscosity)
        result.shimmer = IslandGrids.shimmer.snap(shimmer)
        result.reactivity = IslandGrids.reactivity.snap(reactivity)
        result.slither = IslandGrids.slither.snap(slither)
        result.morph = IslandGrids.morph.snap(morph)
        result.drama = IslandGrids.drama.snap(drama)
        return result
    }

    /// This appearance with every value the island cannot show reset to stock: the film under
    /// a coat without one, the candy dye under any coat but Candy, and the underglow's color
    /// and strength while it is off. Looks, Surprise Me and the stock checks compare this form.
    public var canonical: IslandAppearance {
        var result = self
        if coat.film == nil {
            result.film = 0
        }
        if coat != .candy {
            result.candyHue = IslandGrids.candyHue.stock
            result.candySaturation = IslandGrids.candySaturation.stock
            result.candyBrightness = IslandGrids.candyBrightness.stock
        }
        if !underglow {
            result.underglowHue = IslandGrids.underglowHue.stock
            result.underglowSaturation = IslandGrids.underglowSaturation.stock
            result.underglowStrength = IslandGrids.underglowStrength.stock
        }
        return result
    }

    /// Whether both draw the same island.
    public func isEquivalent(to other: IslandAppearance) -> Bool {
        canonical == other.canonical
    }

    /// Switches the coat and resets the film to that coat's stock thickness: one thickness is a
    /// different color under every coat, so carrying it over would pick a color nobody chose.
    public mutating func select(coat: IslandCoat) {
        self.coat = coat
        film = coat.film?.stock ?? 0
    }

    // MARK: Groups

    // Each group's canonical form depends on that group's fields alone (film and candy dye
    // follow the coat, the underglow's color follows the underglow), so restoring one group
    // and comparing canonical forms asks exactly whether that group is stock.

    public var hasStockMaterial: Bool { hasStock { $0.restoreStockMaterial() } }
    public var hasStockLighting: Bool { hasStock { $0.restoreStockLighting() } }
    public var hasStockBody: Bool { hasStock { $0.restoreStockBody() } }
    public var hasStockMotion: Bool { hasStock { $0.restoreStockMotion() } }

    /// Metal, coat, film, candy dye and finish.
    public mutating func restoreStockMaterial() {
        let stock = IslandAppearance.stock
        metal = stock.metal
        coat = stock.coat
        film = stock.film
        candyHue = stock.candyHue
        candySaturation = stock.candySaturation
        candyBrightness = stock.candyBrightness
        finish = stock.finish
    }

    /// Room, temperature, underglow with its color and strength, brightness and contrast.
    public mutating func restoreStockLighting() {
        let stock = IslandAppearance.stock
        room = stock.room
        temperature = stock.temperature
        underglow = stock.underglow
        underglowHue = stock.underglowHue
        underglowSaturation = stock.underglowSaturation
        underglowStrength = stock.underglowStrength
        brightness = stock.brightness
        contrast = stock.contrast
    }

    /// Size, build, crown and taper.
    public mutating func restoreStockBody() {
        let stock = IslandAppearance.stock
        size = stock.size
        build = stock.build
        crown = stock.crown
        taper = stock.taper
    }

    /// Tempo, viscosity, shimmer, reactivity, slither, morph and drama.
    public mutating func restoreStockMotion() {
        let stock = IslandAppearance.stock
        tempo = stock.tempo
        viscosity = stock.viscosity
        shimmer = stock.shimmer
        reactivity = stock.reactivity
        slither = stock.slither
        morph = stock.morph
        drama = stock.drama
    }

    private func hasStock(restoring restore: (inout IslandAppearance) -> Void) -> Bool {
        var restored = self
        restore(&restored)
        return isEquivalent(to: restored)
    }

    /// The canonical form on one line, in a fixed format that names every field:
    ///
    ///     metal=<raw> coat=<raw> film=<int> candy=<h>/<s>/<b> finish=<int> room=<raw>
    ///     temperature=<int> underglow=<off|h/s/strength> brightness=<int> contrast=<int>
    ///     size=<int> build=<int> crown=<int> taper=<int> tempo=<int> viscosity=<int>
    ///     shimmer=<int> reactivity=<int> slither=<int> morph=<int> drama=<int>
    ///
    /// (one line, single spaces). Two appearances share a description exactly when they are
    /// equivalent, so reports and test names can quote it.
    public var canonicalDescription: String {
        let look = canonical
        let color = "\(look.underglowHue)/\(look.underglowSaturation)/\(look.underglowStrength)"
        let glow = look.underglow ? color : "off"
        return [
            "metal=\(look.metal.rawValue)",
            "coat=\(look.coat.rawValue)",
            "film=\(look.film)",
            "candy=\(look.candyHue)/\(look.candySaturation)/\(look.candyBrightness)",
            "finish=\(look.finish)",
            "room=\(look.room.rawValue)",
            "temperature=\(look.temperature)",
            "underglow=\(glow)",
            "brightness=\(look.brightness)",
            "contrast=\(look.contrast)",
            "size=\(look.size)",
            "build=\(look.build)",
            "crown=\(look.crown)",
            "taper=\(look.taper)",
            "tempo=\(look.tempo)",
            "viscosity=\(look.viscosity)",
            "shimmer=\(look.shimmer)",
            "reactivity=\(look.reactivity)",
            "slither=\(look.slither)",
            "morph=\(look.morph)",
            "drama=\(look.drama)",
        ].joined(separator: " ")
    }
}

// MARK: - Looks

/// The named looks Settings ▸ Island offers.
///
/// Derived, never stored: Settings keeps only the ``IslandAppearance``, and the selected look is
/// whichever one ``matching(_:)`` finds. Tuning a look's values back selects it again; anything
/// else is Custom.
public enum IslandLook: String, CaseIterable, Sendable {
    case stock
    case showroomChrome = "showroom_chrome"
    case liquidGold = "liquid_gold"
    case candyApple = "candy_apple"
    case bluedTitanium = "blued_titanium"
    case chameleon
    case oilSlick = "oil_slick"
    case arcticPlatinum = "arctic_platinum"
    case desertHeat = "desert_heat"
    case midnightCruise = "midnight_cruise"
    case neonKit = "neon_kit"
    case streetRacer = "street_racer"

    /// What Settings ▸ Island shows.
    public var displayName: String {
        switch self {
        case .stock: return "Stock"
        case .showroomChrome: return "Showroom Chrome"
        case .liquidGold: return "Liquid Gold"
        case .candyApple: return "Candy Apple"
        case .bluedTitanium: return "Blued Titanium"
        case .chameleon: return "Chameleon"
        case .oilSlick: return "Oil Slick"
        case .arcticPlatinum: return "Arctic Platinum"
        case .desertHeat: return "Desert Heat"
        case .midnightCruise: return "Midnight Cruise"
        case .neonKit: return "Neon Kit"
        case .streetRacer: return "Street Racer"
        }
    }

    /// The look's whole appearance. Every value it does not set is stock, including the candy
    /// dye under other coats and the underglow's color while it is off, so every look is
    /// already canonical and choosing one stores no hidden leftovers.
    public var appearance: IslandAppearance {
        var look = IslandAppearance.stock
        switch self {
        case .stock:
            break
        case .showroomChrome:
            look.metal = .chromium
            look.temperature = -10
            look.brightness = 10
            look.contrast = 30
            look.crown = 82
            look.shimmer = 80
        case .liquidGold:
            look.metal = .gold
            look.coat = .clear
            look.temperature = 30
            look.brightness = 10
            look.contrast = 10
            look.crown = 86
            look.tempo = 90
            look.viscosity = 140
            look.shimmer = 70
            look.slither = 80
            look.morph = 130
            look.drama = 80
        case .candyApple:
            look.metal = .silver
            look.coat = .candy
            look.candyHue = 355
            look.candySaturation = 90
            look.candyBrightness = 80
            look.contrast = 20
            look.crown = 84
            look.taper = 10
            look.reactivity = 110
        case .bluedTitanium:
            look.metal = .titanium
            look.coat = .anodized
            look.film = 50
            look.finish = 10
            look.temperature = -20
            look.contrast = -20
            look.build = 90
            look.taper = 30
            look.tempo = 110
            look.viscosity = 90
            look.shimmer = 90
            look.reactivity = 110
            look.morph = 90
            look.drama = 120
        case .chameleon:
            look.metal = .aluminum
            look.coat = .chameleon
            look.film = 350
            look.brightness = 20
            look.crown = 86
            look.taper = 10
            look.shimmer = 120
            look.slither = 120
            look.morph = 110
            look.drama = 120
        case .oilSlick:
            look.metal = .titanium
            look.coat = .oilSlick
            look.film = 450
            look.finish = 5
            look.room = .spectralWeather
            look.brightness = 100
            look.contrast = -20
            look.crown = 86
            look.taper = 10
            look.tempo = 90
            look.viscosity = 120
            look.shimmer = 140
            look.slither = 140
            look.morph = 120
        case .arcticPlatinum:
            look.metal = .platinum
            look.coat = .pearl
            look.film = 90
            look.finish = 20
            look.room = .spectralWeather
            look.temperature = -80
            look.underglow = true
            look.underglowHue = 190
            look.underglowSaturation = 35
            look.underglowStrength = 30
            look.brightness = 30
            look.contrast = -30
            look.build = 96
            look.crown = 84
            look.tempo = 80
            look.viscosity = 70
            look.shimmer = 50
            look.reactivity = 80
            look.slither = 75
            look.morph = 140
            look.drama = 60
        case .desertHeat:
            look.metal = .copper
            look.finish = 45
            look.temperature = 80
            look.brightness = 10
            look.contrast = -10
            look.size = 95
            look.crown = 70
            look.taper = 20
            look.tempo = 70
            look.viscosity = 160
            look.shimmer = 140
            look.reactivity = 90
            look.slither = 75
            look.morph = 120
            look.drama = 140
        case .midnightCruise:
            look.metal = .silver
            look.coat = .clear
            look.finish = 5
            look.room = .spectralWeather
            look.temperature = -50
            look.underglow = true
            look.underglowHue = 214
            look.underglowSaturation = 85
            look.underglowStrength = 60
            look.contrast = 20
            look.size = 95
            look.build = 94
            look.crown = 80
            look.taper = 20
            look.tempo = 80
            look.viscosity = 110
            look.shimmer = 60
            look.reactivity = 90
            look.slither = 80
            look.morph = 130
            look.drama = 80
        case .neonKit:
            look.underglow = true
            look.underglowHue = 316
            look.underglowSaturation = 90
            look.underglowStrength = 100
            look.brightness = -20
            look.contrast = 30
            look.build = 90
            look.taper = 40
            look.tempo = 120
            look.viscosity = 90
            look.shimmer = 120
            look.reactivity = 120
            look.slither = 160
            look.morph = 80
            look.drama = 200
        case .streetRacer:
            look.metal = .aluminum
            look.coat = .clear
            look.finish = 30
            look.temperature = -10
            look.underglow = true
            look.underglowHue = 96
            look.underglowSaturation = 90
            look.underglowStrength = 30
            look.brightness = 10
            look.size = 90
            look.build = 86
            look.crown = 70
            look.taper = 60
            look.tempo = 150
            look.viscosity = 70
            look.shimmer = 90
            look.reactivity = 120
            look.slither = 220
            look.morph = 60
            look.drama = 250
        }
        return look
    }

    /// The look that draws the same island as `appearance`, or nil for Custom.
    public static func matching(_ appearance: IslandAppearance) -> IslandLook? {
        allCases.first { $0.appearance.isEquivalent(to: appearance) }
    }
}

// MARK: - Surprise Me

extension IslandAppearance {
    /// Attempts one press draws before the deterministic fallback.
    static let surpriseAttempts: UInt64 = 8

    /// A random look for Surprise Me, replayable from `(seed, draw)` and never equivalent to
    /// `current`.
    ///
    /// Every number is a counter-addressed SplitMix64 output: no generator state, so press
    /// `draw` costs the same as press 0, and nothing reads a clock or the system generator.
    /// With wrapping `UInt64` arithmetic, `γ = 0x9E3779B97F4A7C15` and the SplitMix64 finalizer
    ///
    ///     mix(z): z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    ///             z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    ///             return z ^ (z >> 31)
    ///
    /// a press reads `key = mix(seed + (draw + 1) * γ)` (output `draw + 1` of SplitMix64 seeded
    /// with `seed`) and slot `s` reads `w(s) = mix(key + (s + 1) * γ)` (output `s + 1` of
    /// SplitMix64 seeded with `key`). Attempt `a` reads slots `32 * a + f`, where `f` counts the
    /// fields from 0 in this order: metal, coat, film, candy hue, candy saturation, candy
    /// brightness, finish, room, temperature, underglow, underglow hue, underglow saturation,
    /// underglow strength, brightness, contrast, size, build, crown, taper, tempo, viscosity,
    /// shimmer, reactivity, slither, morph, drama. Every field owns its slot whether or not the
    /// result reads it, so one field's outcome never shifts another's.
    ///
    /// A choice among `n` options takes index `(w * n) >> 64`, the high word of the full
    /// 128-bit product. A ranged value takes that index among the grid points inside its range,
    /// in ascending order. A weighted choice takes the index below the table's total weight and
    /// walks the table in order. The tables: metal uniform; coat none 25, clear 15, candy 15,
    /// pearl 10, anodized 15, oil slick 10, chameleon 10, but on silver and aluminum only none,
    /// clear, candy and chameleon at those weights; film uniform on the coat's grid; candy hue
    /// 0...359, saturation 60...100, brightness 50...100; finish 0...40; room Studio 70,
    /// Overcast 30; temperature −60...60; underglow on when the index below 100 is under 40,
    /// then hue 0...359, saturation 60...100, strength 30...90; brightness −30...30; contrast
    /// −20...40; size 90...100; build 86...100; crown 64...92; taper 0...60; tempo 70...140;
    /// viscosity 70...160; shimmer 40...160; reactivity 70...140; slither 75...220; morph
    /// 70...140; drama 60...200. Values the result cannot show stay stock, so it is canonical.
    ///
    /// Attempts run from 0 while the result is equivalent to `current`, at most
    /// ``surpriseAttempts`` of them; should every one match (no realistic seed does), drama
    /// steps one grid point inside its range instead, which always changes the island.
    public static func surprise(
        seed: UInt64,
        draw: UInt64,
        avoiding current: IslandAppearance
    ) -> IslandAppearance {
        var candidate = surpriseCandidate(seed: seed, draw: draw, attempt: 0)
        var attempt: UInt64 = 1
        while candidate.isEquivalent(to: current), attempt < surpriseAttempts {
            candidate = surpriseCandidate(seed: seed, draw: draw, attempt: attempt)
            attempt += 1
        }
        if candidate.isEquivalent(to: current) {
            // Drama is never normalized away, so one grid step always changes the island.
            let step = IslandGrids.drama.step
            candidate.drama += candidate.drama < surpriseDrama.upperBound ? step : -step
        }
        return candidate
    }

    /// One attempt of one press, exactly as ``surprise(seed:draw:avoiding:)`` documents.
    static func surpriseCandidate(seed: UInt64, draw: UInt64, attempt: UInt64) -> IslandAppearance {
        let words = SurpriseWords(seed: seed, draw: draw, attempt: attempt)
        func value(_ slot: SurpriseSlot, _ grid: IslandGrid, _ bounds: ClosedRange<Int>) -> Int {
            words.value(slot, on: grid, in: bounds)
        }
        var look = IslandAppearance()
        look.metal = IslandMetal.allCases[words.index(.metal, count: IslandMetal.allCases.count)]
        let brightMetal = look.metal == .silver || look.metal == .aluminum
        look.coat = words.pick(.coat, from: brightMetal ? brightMetalCoats : surpriseCoats)
        if let film = look.coat.film {
            look.film = value(.film, film, film.range)
        }
        if look.coat == .candy {
            look.candyHue = value(.candyHue, IslandGrids.candyHue, 0...359)
            look.candySaturation = value(.candySaturation, IslandGrids.candySaturation, 60...100)
            look.candyBrightness = value(.candyBrightness, IslandGrids.candyBrightness, 50...100)
        }
        look.finish = value(.finish, IslandGrids.finish, 0...40)
        look.room = words.pick(.room, from: surpriseRooms)
        look.temperature = value(.temperature, IslandGrids.temperature, -60...60)
        look.underglow = words.index(.underglow, count: 100) < 40
        if look.underglow {
            look.underglowHue = value(.underglowHue, IslandGrids.underglowHue, 0...359)
            look.underglowSaturation = value(
                .underglowSaturation, IslandGrids.underglowSaturation, 60...100)
            look.underglowStrength = value(
                .underglowStrength, IslandGrids.underglowStrength, 30...90)
        }
        look.brightness = value(.brightness, IslandGrids.brightness, -30...30)
        look.contrast = value(.contrast, IslandGrids.contrast, -20...40)
        look.size = value(.size, IslandGrids.size, 90...100)
        look.build = value(.build, IslandGrids.build, 86...100)
        look.crown = value(.crown, IslandGrids.crown, 64...92)
        look.taper = value(.taper, IslandGrids.taper, 0...60)
        look.tempo = value(.tempo, IslandGrids.tempo, 70...140)
        look.viscosity = value(.viscosity, IslandGrids.viscosity, 70...160)
        look.shimmer = value(.shimmer, IslandGrids.shimmer, 40...160)
        look.reactivity = value(.reactivity, IslandGrids.reactivity, 70...140)
        look.slither = value(.slither, IslandGrids.slither, 75...220)
        look.morph = value(.morph, IslandGrids.morph, 70...140)
        look.drama = value(.drama, IslandGrids.drama, surpriseDrama)
        return look
    }

    /// Coat odds, percent.
    private static let surpriseCoats: [(option: IslandCoat, weight: Int)] = [
        (IslandCoat.none, 25), (.clear, 15), (.candy, 15), (.pearl, 10), (.anodized, 15),
        (.oilSlick, 10), (.chameleon, 10),
    ]

    /// Silver and aluminum reflect nearly all light, so a bare oxide film barely tints them;
    /// they draw only the coats that still show, renormalized over the same weights.
    private static let brightMetalCoats: [(option: IslandCoat, weight: Int)] = [
        (IslandCoat.none, 25), (.clear, 15), (.candy, 15), (.chameleon, 10),
    ]

    private static let surpriseRooms: [(option: MercuryWorld, weight: Int)] = [
        (.roomOfTen, 70), (.spectralWeather, 30),
    ]

    /// Drama's draw range, which the fallback step also stays inside.
    private static let surpriseDrama = 60...200
}

/// The field each slot of an attempt feeds, numbered from 0 in declaration order. The order is
/// part of the replay contract: append a new field, never insert one.
private enum SurpriseSlot: UInt64 {
    case metal, coat, film, candyHue, candySaturation, candyBrightness, finish, room
    case temperature, underglow, underglowHue, underglowSaturation, underglowStrength
    case brightness, contrast, size, build, crown, taper
    case tempo, viscosity, shimmer, reactivity, slither, morph, drama
}

/// The counter-addressed SplitMix64 words one Surprise Me attempt reads.
private struct SurpriseWords {
    /// SplitMix64's increment, the odd integer nearest 2⁶⁴/φ.
    private static let gamma: UInt64 = 0x9e37_79b9_7f4a_7c15
    /// Slots per attempt: more than there are fields, so attempts never share a word.
    private static let slotsPerAttempt: UInt64 = 32

    private let key: UInt64
    private let firstSlot: UInt64

    init(seed: UInt64, draw: UInt64, attempt: UInt64) {
        key = Self.mix(seed &+ (draw &+ 1) &* Self.gamma)
        firstSlot = attempt &* Self.slotsPerAttempt
    }

    /// `(w * count) >> 64`: uniform on `0..<count` to within `count / 2⁶⁴`, with no division.
    func index(_ slot: SurpriseSlot, count: Int) -> Int {
        Int(word(slot).multipliedFullWidth(by: UInt64(count)).high)
    }

    /// A grid point drawn uniformly from those inside `bounds`.
    func value(_ slot: SurpriseSlot, on grid: IslandGrid, in bounds: ClosedRange<Int>) -> Int {
        let first = (bounds.lowerBound - grid.range.lowerBound + grid.step - 1) / grid.step
        let last = (bounds.upperBound - grid.range.lowerBound) / grid.step
        return grid.range.lowerBound + (first + index(slot, count: last - first + 1)) * grid.step
    }

    /// One option, with probability proportional to its weight.
    func pick<Option>(_ slot: SurpriseSlot, from table: [(option: Option, weight: Int)]) -> Option {
        var remaining = index(slot, count: table.reduce(0) { $0 + $1.weight })
        for entry in table.dropLast() {
            if remaining < entry.weight { return entry.option }
            remaining -= entry.weight
        }
        return table[table.count - 1].option
    }

    private func word(_ slot: SurpriseSlot) -> UInt64 {
        Self.mix(key &+ (firstSlot &+ slot.rawValue &+ 1) &* Self.gamma)
    }

    /// The SplitMix64 finalizer, the same mixer the renderer's counter noise uses.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
