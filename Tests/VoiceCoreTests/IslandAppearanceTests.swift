import Foundation
import Testing

@testable import VoiceCore

/// The island's persisted look: lenient decoding inside the settings file, the grids, canonical
/// equivalence, the named looks and Surprise Me.
@Suite("Island appearance")
struct IslandAppearanceTests {
    private static let seed: UInt64 = 0x5EED

    // MARK: Persistence

    @Test func aSettingsFileWithoutAnIslandDecodesToStock() throws {
        let empty = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))

        #expect(empty.island == .stock)
        #expect(empty == Settings())
        #expect(Settings().island == .stock)
    }

    /// A word written by a future build costs only its own field, never its neighbors.
    @Test func anUnknownMetalCoatOrRoomResetsOnlyThatField() throws {
        let unknownMetal = try island(#"{"metal": "unobtainium", "coat": "pearl", "film": 90}"#)
        #expect(unknownMetal.metal == .mercury)
        #expect(unknownMetal.coat == .pearl)
        #expect(unknownMetal.film == 90)

        let unknownCoat = try island(
            #"{"metal": "gold", "coat": "flake", "film": 90, "room": "spectral_weather"}"#
        )
        #expect(unknownCoat.metal == .gold)
        #expect(unknownCoat.coat == IslandCoat.none)
        #expect(unknownCoat.film == 0)
        #expect(unknownCoat.room == .spectralWeather)

        let unknownRoom = try island(#"{"metal": "copper", "room": "lunar", "finish": 45}"#)
        #expect(unknownRoom.metal == .copper)
        #expect(unknownRoom.room == .roomOfTen)
        #expect(unknownRoom.finish == 45)
    }

    @Test func aWrongTypedFieldResetsOnlyThatField() throws {
        let decoded = try island(
            #"""
            {"metal": 7, "coat": "anodized", "film": "thick", "finish": "glossy",
             "underglow": "yes", "underglow_hue": 300, "crown": 90, "drama": [200],
             "room": false, "slither": 150}
            """#
        )

        #expect(decoded.metal == .mercury)
        #expect(decoded.coat == .anodized)
        // An unreadable film takes the coat's own stock thickness.
        #expect(decoded.film == 50)
        #expect(decoded.finish == 0)
        #expect(decoded.underglow == false)
        #expect(decoded.underglowHue == 300)
        #expect(decoded.crown == 90)
        #expect(decoded.drama == 100)
        #expect(decoded.room == .roomOfTen)
        #expect(decoded.slither == 150)
    }

    @Test func outOfRangeValuesAreClampedThenSnapped() throws {
        let decoded = try island(
            #"""
            {"coat": "pearl", "film": 1000, "finish": 13, "temperature": -15, "build": 81,
             "size": 50, "slither": 77, "candy_hue": 400, "underglow_strength": 0,
             "drama": 100000, "morph": -100000}
            """#
        )

        #expect(decoded.film == 140)
        #expect(decoded.finish == 15)
        #expect(decoded.temperature == -10)  // halfway rounds up
        #expect(decoded.build == 82)  // halfway rounds up
        #expect(decoded.size == 85)
        #expect(decoded.slither == 75)
        #expect(decoded.candyHue == 359)
        #expect(decoded.underglowStrength == 10)
        #expect(decoded.drama == 300)
        #expect(decoded.morph == 60)
        #expect(decoded.snapped() == decoded)
    }

    /// The island lives in the same file as the glossary: a mangled island must cost the
    /// island, never the file.
    @Test func anIslandThatIsNotAnObjectIsStockAndTheRestOfTheFileSurvives() throws {
        for value in ["42", #""chrome""#, "[1, 2]", "true", "null"] {
            let json = #"""
                {"cleanup_enabled": false, "island": \#(value),
                 "glossary": [{"canonical": "Voiceour", "spoken_aliases": ["voice our"]}]}
                """#
            let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

            #expect(settings.island == .stock, "\(value)")
            #expect(settings.cleanupEnabled == false, "\(value)")
            #expect(settings.glossary.map(\.canonical) == ["Voiceour"], "\(value)")
        }
    }

    @Test func theAppearanceRoundTripsThroughSortedKeyJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // Every key, written even when stock, so the file states the whole look.
        let stockJSON = try encoder.encode(IslandAppearance.stock)
        let expected: String =
            #"{"brightness":0,"build":100,"candy_brightness":80,"candy_hue":355,"#
            + #""candy_saturation":90,"coat":"none","contrast":0,"crown":78,"drama":100,"#
            + #""film":0,"finish":0,"metal":"mercury","morph":100,"reactivity":100,"#
            + #""room":"room_of_ten","shimmer":100,"size":100,"slither":100,"taper":0,"#
            + #""temperature":0,"tempo":100,"underglow":false,"underglow_hue":190,"#
            + #""underglow_saturation":80,"underglow_strength":60,"viscosity":100}"#
        #expect(String(decoding: stockJSON, as: UTF8.self) == expected)

        var settings = Settings()
        settings.island = IslandLook.arcticPlatinum.appearance
        // Stored under a coat that hides it: kept as written, not canonicalized away.
        settings.island.candyHue = 12

        let decoded = try JSONDecoder().decode(Settings.self, from: encoder.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.island.candyHue == 12)
    }

    // MARK: Grids

    private static let everyGrid: [IslandGrid] =
        [
            IslandGrids.candyHue, IslandGrids.candySaturation, IslandGrids.candyBrightness,
            IslandGrids.finish, IslandGrids.temperature, IslandGrids.underglowHue,
            IslandGrids.underglowSaturation, IslandGrids.underglowStrength, IslandGrids.brightness,
            IslandGrids.contrast, IslandGrids.size, IslandGrids.build, IslandGrids.crown,
            IslandGrids.taper, IslandGrids.tempo, IslandGrids.viscosity, IslandGrids.shimmer,
            IslandGrids.reactivity, IslandGrids.slither, IslandGrids.morph, IslandGrids.drama,
        ] + IslandCoat.allCases.compactMap(\.film)

    @Test func snappingClampsFirstAndRoundsHalfwayUp() {
        let signed = IslandGrid(range: -100...100, step: 10, stock: 0)
        #expect(signed.snap(-15) == -10)
        #expect(signed.snap(-16) == -20)
        #expect(signed.snap(14) == 10)
        #expect(signed.snap(15) == 20)
        #expect(signed.snap(.max) == 100)
        #expect(signed.snap(.min) == -100)

        // An upper bound off the grid never snaps past the last grid point.
        let ragged = IslandGrid(range: 0...359, step: 10, stock: 0)
        #expect(ragged.snap(356) == 350)
        #expect(ragged.snap(359) == 350)

        for grid in Self.everyGrid {
            #expect(grid.snap(grid.stock) == grid.stock)
            #expect(grid.snap(grid.range.upperBound) == grid.range.upperBound)
        }
        #expect(IslandCoat.pearl.film == IslandGrid(range: 60...140, step: 5, stock: 70))
        #expect(IslandCoat.anodized.film == IslandGrid(range: 20...220, step: 5, stock: 50))
        #expect(IslandCoat.oilSlick.film == IslandGrid(range: 250...700, step: 10, stock: 450))
        #expect(IslandCoat.chameleon.film == IslandGrid(range: 300...550, step: 10, stock: 350))
        #expect(IslandCoat.none.film == nil)
        #expect(IslandCoat.clear.film == nil)
        #expect(IslandCoat.candy.film == nil)
    }

    @Test func snappedIsIdempotent() {
        var wild = IslandAppearance()
        wild.coat = .oilSlick
        wild.film = 703
        wild.candyHue = -4
        wild.candySaturation = 101
        wild.candyBrightness = 3
        wild.finish = 7
        wild.temperature = 44
        wild.underglowHue = 360
        wild.underglowSaturation = -1
        wild.underglowStrength = 55
        wild.brightness = -101
        wild.contrast = 5
        wild.size = 101
        wild.build = 99
        wild.crown = 79
        wild.taper = 101
        wild.tempo = 65
        wild.viscosity = 205
        wild.shimmer = 33
        wild.reactivity = 149
        wild.slither = 252
        wild.morph = 155
        wild.drama = 49

        let once = wild.snapped()
        #expect(once.snapped() == once)
        #expect(
            [once.film, once.candyHue, once.candySaturation, once.candyBrightness, once.finish]
                == [700, 0, 100, 10, 5] as [Int])
        #expect(
            [once.temperature, once.underglowHue, once.underglowSaturation, once.underglowStrength]
                == [40, 359, 0, 60] as [Int])
        #expect(
            [once.brightness, once.contrast, once.size, once.build, once.crown, once.taper]
                == [-100, 10, 100, 100, 80, 100] as [Int])
        #expect([once.tempo, once.viscosity, once.shimmer, once.reactivity] == [70, 200, 30, 150] as [Int])
        #expect([once.slither, once.morph, once.drama] == [250, 160, 50] as [Int])

        // Under a coat without a film the film snaps to 0.
        wild.coat = .clear
        #expect(wild.snapped().film == 0)
        #expect(IslandAppearance.stock.snapped() == .stock)
    }

    // MARK: Canonical form

    @Test func canonicalIgnoresWhatTheIslandCannotShow() {
        var hidden = IslandAppearance()
        hidden.film = 120  // no film under bare metal
        hidden.candyHue = 10  // no dye unless the coat is Candy
        hidden.underglowHue = 10  // no underglow color while it is off
        hidden.underglowStrength = 100

        #expect(hidden != .stock)
        #expect(hidden.canonical == .stock)
        #expect(hidden.isEquivalent(to: .stock))
        #expect(hidden.canonicalDescription == IslandAppearance.stock.canonicalDescription)
        #expect(IslandLook.matching(hidden) == .stock)

        var clear = hidden
        clear.coat = .clear
        var stockClear = IslandAppearance.stock
        stockClear.coat = .clear
        #expect(clear.isEquivalent(to: stockClear))

        // Each one counts once the coat or the underglow shows it.
        var pearl = hidden
        pearl.coat = .pearl
        var stockPearl = IslandAppearance.stock
        stockPearl.select(coat: .pearl)
        #expect(!pearl.isEquivalent(to: stockPearl))

        var candy = hidden
        candy.coat = .candy
        var stockCandy = IslandAppearance.stock
        stockCandy.coat = .candy
        #expect(!candy.isEquivalent(to: stockCandy))

        var glowing = hidden
        glowing.underglow = true
        var stockGlowing = IslandAppearance.stock
        stockGlowing.underglow = true
        #expect(!glowing.isEquivalent(to: stockGlowing))
    }

    @Test func selectingACoatResetsTheFilmToThatCoatsStock() {
        let stockFilms: [(IslandCoat, Int)] = [
            (.pearl, 70), (.anodized, 50), (.oilSlick, 450), (.chameleon, 350),
            (.clear, 0), (.candy, 0), (IslandCoat.none, 0),
        ]
        var appearance = IslandAppearance()
        for (coat, film) in stockFilms {
            appearance.film = 135  // chosen under the previous coat
            appearance.select(coat: coat)
            #expect(appearance.coat == coat)
            #expect(appearance.film == film)
        }
    }

    @Test func eachGroupRestoresAndReportsStockOnItsOwn() {
        var appearance = IslandLook.arcticPlatinum.appearance
        #expect(!appearance.hasStockMaterial)
        #expect(!appearance.hasStockLighting)
        #expect(!appearance.hasStockBody)
        #expect(!appearance.hasStockMotion)

        appearance.restoreStockMaterial()
        #expect(appearance.hasStockMaterial)
        #expect(appearance.metal == .mercury)
        #expect(appearance.coat == IslandCoat.none)
        #expect(appearance.film == 0)
        #expect(appearance.finish == 0)
        #expect(!appearance.hasStockLighting)
        #expect(appearance.room == .spectralWeather)

        appearance.restoreStockLighting()
        #expect(appearance.hasStockLighting)
        #expect(appearance.room == .roomOfTen)
        #expect(appearance.underglow == false)
        #expect(!appearance.hasStockBody)

        appearance.restoreStockBody()
        #expect(appearance.hasStockBody)
        #expect(!appearance.hasStockMotion)

        appearance.restoreStockMotion()
        #expect(appearance.hasStockMotion)
        #expect(appearance == .stock)

        // Stock checks compare canonical forms: values the island cannot show do not count.
        var hidden = IslandAppearance.stock
        hidden.film = 90
        hidden.candyBrightness = 30
        hidden.underglowSaturation = 5
        #expect(hidden.hasStockMaterial)
        #expect(hidden.hasStockLighting)

        // A change in one group leaves the others stock.
        var crowned = IslandAppearance.stock
        crowned.crown = 90
        #expect(!crowned.hasStockBody)
        #expect(crowned.hasStockMaterial)
        #expect(crowned.hasStockLighting)
        #expect(crowned.hasStockMotion)
    }

    @Test func canonicalDescriptionOfStockIsPinned() {
        let stock = """
            metal=mercury coat=none film=0 candy=355/90/80 finish=0 room=room_of_ten temperature=0 \
            underglow=off brightness=0 contrast=0 size=100 build=100 crown=78 taper=0 tempo=100 \
            viscosity=100 shimmer=100 reactivity=100 slither=100 morph=100 drama=100
            """
        #expect(IslandAppearance.stock.canonicalDescription == stock)
    }

    // MARK: Looks

    /// Transcribed from the looks table independently of ``IslandLook/appearance``, so a typo
    /// in either one fails here.
    private static let lookDescriptions: [IslandLook: String] = [
        .stock: """
        metal=mercury coat=none film=0 candy=355/90/80 finish=0 room=room_of_ten temperature=0 \
        underglow=off brightness=0 contrast=0 size=100 build=100 crown=78 taper=0 tempo=100 \
        viscosity=100 shimmer=100 reactivity=100 slither=100 morph=100 drama=100
        """,
        .showroomChrome: """
        metal=chromium coat=none film=0 candy=355/90/80 finish=0 room=room_of_ten \
        temperature=-10 underglow=off brightness=10 contrast=30 size=100 build=100 crown=82 \
        taper=0 tempo=100 viscosity=100 shimmer=80 reactivity=100 slither=100 morph=100 \
        drama=100
        """,
        .liquidGold: """
        metal=gold coat=clear film=0 candy=355/90/80 finish=0 room=room_of_ten temperature=30 \
        underglow=off brightness=10 contrast=10 size=100 build=100 crown=86 taper=0 tempo=90 \
        viscosity=140 shimmer=70 reactivity=100 slither=80 morph=130 drama=80
        """,
        .candyApple: """
        metal=silver coat=candy film=0 candy=355/90/80 finish=0 room=room_of_ten temperature=0 \
        underglow=off brightness=0 contrast=20 size=100 build=100 crown=84 taper=10 tempo=100 \
        viscosity=100 shimmer=100 reactivity=110 slither=100 morph=100 drama=100
        """,
        .bluedTitanium: """
        metal=titanium coat=anodized film=50 candy=355/90/80 finish=10 room=room_of_ten \
        temperature=-20 underglow=off brightness=0 contrast=-20 size=100 build=90 crown=78 \
        taper=30 tempo=110 viscosity=90 shimmer=90 reactivity=110 slither=100 morph=90 \
        drama=120
        """,
        .chameleon: """
        metal=aluminum coat=chameleon film=350 candy=355/90/80 finish=0 room=room_of_ten \
        temperature=0 underglow=off brightness=20 contrast=0 size=100 build=100 crown=86 \
        taper=10 tempo=100 viscosity=100 shimmer=120 reactivity=100 slither=120 morph=110 \
        drama=120
        """,
        .oilSlick: """
        metal=titanium coat=oil_slick film=450 candy=355/90/80 finish=5 room=spectral_weather \
        temperature=0 underglow=off brightness=100 contrast=-20 size=100 build=100 crown=86 \
        taper=10 tempo=90 viscosity=120 shimmer=140 reactivity=100 slither=140 morph=120 \
        drama=100
        """,
        .arcticPlatinum: """
        metal=platinum coat=pearl film=90 candy=355/90/80 finish=20 room=spectral_weather \
        temperature=-80 underglow=190/35/30 brightness=30 contrast=-30 size=100 build=96 \
        crown=84 taper=0 tempo=80 viscosity=70 shimmer=50 reactivity=80 slither=75 morph=140 \
        drama=60
        """,
        .desertHeat: """
        metal=copper coat=none film=0 candy=355/90/80 finish=45 room=room_of_ten \
        temperature=80 underglow=off brightness=10 contrast=-10 size=95 build=100 crown=70 \
        taper=20 tempo=70 viscosity=160 shimmer=140 reactivity=90 slither=75 morph=120 \
        drama=140
        """,
        .midnightCruise: """
        metal=silver coat=clear film=0 candy=355/90/80 finish=5 room=spectral_weather \
        temperature=-50 underglow=214/85/60 brightness=0 contrast=20 size=95 build=94 \
        crown=80 taper=20 tempo=80 viscosity=110 shimmer=60 reactivity=90 slither=80 morph=130 \
        drama=80
        """,
        .neonKit: """
        metal=mercury coat=none film=0 candy=355/90/80 finish=0 room=room_of_ten temperature=0 \
        underglow=316/90/100 brightness=-20 contrast=30 size=100 build=90 crown=78 taper=40 \
        tempo=120 viscosity=90 shimmer=120 reactivity=120 slither=160 morph=80 drama=200
        """,
        .streetRacer: """
        metal=aluminum coat=clear film=0 candy=355/90/80 finish=30 room=room_of_ten \
        temperature=-10 underglow=96/90/30 brightness=10 contrast=0 size=90 build=86 crown=70 \
        taper=60 tempo=150 viscosity=70 shimmer=90 reactivity=120 slither=220 morph=60 \
        drama=250
        """,
    ]

    @Test func everyLookIsOnGridCanonicalDistinctAndRecognized() {
        #expect(
            IslandLook.allCases.map(\.rawValue) == [
                "stock", "showroom_chrome", "liquid_gold", "candy_apple", "blued_titanium",
                "chameleon", "oil_slick", "arctic_platinum", "desert_heat", "midnight_cruise",
                "neon_kit", "street_racer",
            ])
        #expect(
            IslandLook.allCases.map(\.displayName) == [
                "Stock", "Showroom Chrome", "Liquid Gold", "Candy Apple", "Blued Titanium",
                "Chameleon", "Oil Slick", "Arctic Platinum", "Desert Heat", "Midnight Cruise",
                "Neon Kit", "Street Racer",
            ])
        #expect(IslandLook.stock.appearance == .stock)
        #expect(IslandLook.matching(.stock) == .stock)

        for look in IslandLook.allCases {
            let appearance = look.appearance
            #expect(appearance.snapped() == appearance, "\(look) is off its grids")
            #expect(appearance.canonical == appearance, "\(look) stores hidden values")
            #expect(appearance.canonicalDescription == Self.lookDescriptions[look], "\(look)")
            #expect(IslandLook.matching(appearance) == look)
            for other in IslandLook.allCases where other != look {
                #expect(!appearance.isEquivalent(to: other.appearance), "\(look) = \(other)")
            }
        }
    }

    @Test func aChangeTheIslandShowsLeavesEveryLook() {
        var custom = IslandLook.liquidGold.appearance
        custom.drama = 90
        #expect(IslandLook.matching(custom) == nil)

        custom.drama = 80
        custom.film = 300  // no film under a clear coat
        custom.underglowHue = 12  // no underglow color while it is off
        #expect(IslandLook.matching(custom) == .liquidGold)
    }

    @Test func materialsAndRoomsCarryTheirSettingsNames() {
        #expect(
            IslandMetal.allCases.map(\.displayName) == [
                "Mercury", "Silver", "Aluminum", "Chrome", "Platinum", "Titanium", "Gold", "Copper",
            ])
        #expect(
            IslandCoat.allCases.map(\.displayName) == [
                "None", "Clear Coat", "Candy", "Pearl", "Anodized", "Oil Slick", "Chameleon",
            ])
        #expect(IslandMetal.stock == .mercury)
        #expect(IslandCoat.stock == IslandCoat.none)
        #expect(IslandMetal.resolved(nil) == .mercury)
        #expect(IslandMetal.resolved("chromium") == .chromium)
        #expect(IslandCoat.resolved("oil_slick") == .oilSlick)
        // The persisted tag is the raw value, never the Swift case name.
        #expect(IslandCoat.resolved("oilSlick") == IslandCoat.none)
        #expect(MercuryWorld.roomOfTen.displayName == "Studio")
        #expect(MercuryWorld.spectralWeather.displayName == "Overcast")
    }

    // MARK: Surprise Me

    @Test func surpriseReplaysFromSeedAndDraw() {
        for draw: UInt64 in 0..<32 {
            let look = surprise(draw)
            #expect(surprise(draw) == look)
            #expect(!surprise(draw + 1).isEquivalent(to: look), "draw \(draw)")
            #expect(!surprise(draw, seed: Self.seed + 1).isEquivalent(to: look), "draw \(draw)")
        }
    }

    @Test func surpriseStaysOnGridInsideItsDrawTable() {
        var metals = Set<IslandMetal>()
        var coats = Set<IslandCoat>()
        var rooms = Set<MercuryWorld>()
        var underglows = Set<Bool>()
        for draw: UInt64 in 0..<2_000 {
            let look = surprise(draw)
            #expect(insideDrawTable(look), "\(look.canonicalDescription)")
            metals.insert(look.metal)
            coats.insert(look.coat)
            rooms.insert(look.room)
            underglows.insert(look.underglow)
        }
        #expect(metals == Set(IslandMetal.allCases))
        #expect(coats == Set(IslandCoat.allCases))
        #expect(rooms == Set(MercuryWorld.allCases))
        #expect(underglows == [false, true])
    }

    /// Silver and aluminum reflect nearly all light, so a bare oxide film barely tints them.
    @Test func silverAndAluminumDrawOnlyCoatsThatStillShow() {
        var coats = Set<IslandCoat>()
        for draw: UInt64 in 0..<4_000 {
            let look = surprise(draw)
            if look.metal == .silver || look.metal == .aluminum {
                coats.insert(look.coat)
            }
        }
        #expect(coats == [IslandCoat.none, .clear, .candy, .chameleon])
    }

    @Test func surpriseNeverRepeatsTheCurrentLook() {
        for draw: UInt64 in 0..<64 {
            let first = IslandAppearance.surpriseCandidate(seed: Self.seed, draw: draw, attempt: 0)
            #expect(surprise(draw) == first)

            // Pressing while that very look shows draws the next attempt instead.
            let pressed = surprise(draw, avoiding: first)
            let second = IslandAppearance.surpriseCandidate(
                seed: Self.seed, draw: draw, attempt: 1)
            #expect(!pressed.isEquivalent(to: first))
            #expect(pressed == second)
        }
        for look in IslandLook.allCases {
            for draw: UInt64 in 0..<16 {
                let pressed = surprise(draw, avoiding: look.appearance)
                #expect(!pressed.isEquivalent(to: look.appearance), "\(look), draw \(draw)")
            }
        }
    }

    /// Recomputed outside Swift from the algorithm the doc comment of
    /// ``IslandAppearance/surprise(seed:draw:avoiding:)`` states, so the two cannot drift
    /// apart. A deliberate change to the draw updates these lines.
    @Test func surpriseFollowsItsDocumentedMixing() {
        let seedZero = """
            metal=titanium coat=anodized film=95 candy=355/90/80 finish=35 room=room_of_ten \
            temperature=-20 underglow=off brightness=0 contrast=10 size=93 build=96 crown=86 \
            taper=50 tempo=70 viscosity=160 shimmer=110 reactivity=110 slither=190 morph=110 \
            drama=170
            """
        #expect(surprise(0, seed: 0).canonicalDescription == seedZero)

        let candyUnderglow = """
            metal=chromium coat=candy film=0 candy=327/80/54 finish=25 room=spectral_weather \
            temperature=-40 underglow=50/95/60 brightness=20 contrast=-10 size=92 build=96 \
            crown=72 taper=0 tempo=90 viscosity=70 shimmer=110 reactivity=90 slither=155 morph=110 \
            drama=60
            """
        #expect(surprise(21).canonicalDescription == candyUnderglow)

        let silverChameleon = """
            metal=silver coat=chameleon film=430 candy=355/90/80 finish=35 room=room_of_ten \
            temperature=30 underglow=off brightness=-20 contrast=0 size=92 build=88 crown=72 \
            taper=10 tempo=70 viscosity=130 shimmer=60 reactivity=100 slither=145 morph=140 \
            drama=170
            """
        #expect(surprise(49).canonicalDescription == silverChameleon)

        let redrawn = """
            metal=mercury coat=clear film=0 candy=355/90/80 finish=0 room=room_of_ten \
            temperature=-50 underglow=340/88/80 brightness=30 contrast=-10 size=99 build=98 \
            crown=84 taper=60 tempo=80 viscosity=160 shimmer=160 reactivity=70 slither=155 \
            morph=70 drama=120
            """
        #expect(surprise(0, avoiding: surprise(0)).canonicalDescription == redrawn)
    }

    // MARK: Helpers

    /// Decodes `json` as the `island` of an otherwise empty settings file, the path every real
    /// read takes.
    private func island(_ json: String) throws -> IslandAppearance {
        try JSONDecoder().decode(Settings.self, from: Data(#"{"island": \#(json)}"#.utf8)).island
    }

    private func surprise(
        _ draw: UInt64,
        seed: UInt64 = IslandAppearanceTests.seed,
        avoiding current: IslandAppearance = .stock
    ) -> IslandAppearance {
        IslandAppearance.surprise(seed: seed, draw: draw, avoiding: current)
    }

    /// Whether `look` lies inside the draw table ``IslandAppearance/surprise(seed:draw:avoiding:)``
    /// documents, on its grids and canonical.
    private func insideDrawTable(_ look: IslandAppearance) -> Bool {
        var ranged: [(value: Int, bounds: ClosedRange<Int>)] = [
            (look.finish, 0...40), (look.temperature, -60...60), (look.brightness, -30...30),
            (look.contrast, -20...40), (look.size, 90...100), (look.build, 86...100),
            (look.crown, 64...92), (look.taper, 0...60), (look.tempo, 70...140),
            (look.viscosity, 70...160), (look.shimmer, 40...160), (look.reactivity, 70...140),
            (look.slither, 75...220), (look.morph, 70...140), (look.drama, 60...200),
        ]
        if look.coat == .candy {
            ranged += [(look.candySaturation, 60...100), (look.candyBrightness, 50...100)]
        }
        if look.underglow {
            ranged += [(look.underglowSaturation, 60...100), (look.underglowStrength, 30...90)]
        }
        let brightMetal = look.metal == .silver || look.metal == .aluminum
        let brightCoats = [IslandCoat.none, .clear, .candy, .chameleon]
        return look.snapped() == look && look.canonical == look
            && (!brightMetal || brightCoats.contains(look.coat))
            && ranged.allSatisfy { $0.bounds.contains($0.value) }
    }
}
