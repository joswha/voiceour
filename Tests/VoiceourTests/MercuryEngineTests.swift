import CoreGraphics
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

@MainActor
struct MercuryEngineTests {
    // MARK: - Looks

    /// The stock appearance is the shipped renderer input for input, which is what keeps
    /// every stock image byte-identical.
    @Test func theStockAppearanceIsTheStockLook() {
        #expect(MercuryLook(island: .stock) == .stock)
        #expect(MercuryLook(island: IslandLook.stock.appearance) == .stock)
        #expect(MercuryLook.stock.world == .default)
        #expect(MercuryLook.stock.paint == .stock)
        #expect(MercuryLook.stock.lighting == .stock)
        #expect(MercuryLook.stock.tone == .stock)
        #expect(MercuryLook.stock.tune == .stock)

        // Values the appearance keeps but does not show never reach the look.
        var hidden = IslandAppearance.stock
        hidden.candyHue = 10
        hidden.underglowHue = 10
        hidden.underglowStrength = 100
        #expect(MercuryLook(island: hidden) == .stock)
    }

    @Test func anAppearanceMapsOntoItsPhysicalInputs() {
        var island = IslandAppearance.stock
        island.metal = .platinum
        island.select(coat: .pearl)
        island.film = 90
        island.finish = 20
        island.room = .spectralWeather
        island.temperature = -80
        island.underglow = true
        island.underglowHue = 190
        island.underglowSaturation = 35
        island.underglowStrength = 30
        island.brightness = 30
        island.contrast = -30
        island.build = 96
        island.crown = 84
        island.taper = 50
        island.morph = 140
        let look = MercuryLook(island: island)

        #expect(look.world == .spectralWeather)
        #expect(
            look.paint
                == MercuryPaint(
                    metal: .platinum,
                    coat: .pearl,
                    filmNanometers: 90,
                    candy: SIMD3(repeating: 1)
                )
        )
        #expect(look.lighting.finish == Float(0.03 * pow(25.0 / 3.0, 0.2)))
        #expect(look.lighting.whiteBalance == MercuryWhiteBalance.multipliers(temperature: -0.8))
        #expect(
            look.lighting.underglow
                == MercuryUnderglow(
                    color: MercuryColor.luminanceNormalized(
                        MercuryColor.linearRGB(hue: 190, saturation: 35, brightness: 100)
                    ),
                    strength: 0.3
                )
        )
        #expect(look.underglowStrength == 0.3)
        #expect(look.tone == MercuryTone(brightness: 0.3, contrast: -0.3))
        #expect(look.tune.size == 1)
        #expect(look.tune.build == 0.96)
        #expect(look.tune.crownAspect == 0.84)
        #expect(abs(look.tune.endTaper - 0.38) < 1e-12)
        #expect(look.tune.morph == 1.4)

        // A dye is its round-trip transmittance, held where the lacquer keeps it.
        var candy = IslandAppearance.stock
        candy.metal = .silver
        candy.select(coat: .candy)
        candy.candyHue = 120
        candy.candySaturation = 100
        candy.candyBrightness = 100
        #expect(MercuryLook(island: candy).paint.candy == SIMD3<Double>(0.02, 1, 0.02))
    }

    // MARK: - Light and body

    @Test func reseedingRebuildsTheBodyAndLightingTogether() throws {
        let drive = Drives.speaking()
        let reused = MercuryEngine(
            seed: 1,
            look: .stock,
            hitRegion: MercuryHitRegion()
        )
        _ = reused.pinnedFrame(
            step: 600,
            seed: 1,
            look: .stock,
            drive: drive,
            appearance: .standard,
            layout: .island
        )
        let reseeded = try #require(
            reused.pinnedFrame(
                step: 600,
                seed: 2,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        let fresh = MercuryEngine(
            seed: 2,
            look: .stock,
            hitRegion: MercuryHitRegion()
        )
        let expected = try #require(
            fresh.pinnedFrame(
                step: 600,
                seed: 2,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        #expect(Self.bytes(reseeded) == Self.bytes(expected))
    }

    /// Whatever an engine drew before, a pinned frame depends only on its seed, look and
    /// layout. A look drawn again after others have moved every cache on draws what a fresh
    /// engine draws, and what a body, room and response built without any engine draw.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func aReusedEngineDrawsEveryLookLikeAFreshOne(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        // A seed no other test draws, one per layout, so each engine-free render below bakes
        // its room and settles its first bodies cold.
        let seed: UInt64 = layout.kind == .collar ? 0x5245_5553_4544_0002 : 0x5245_5553_4544_0001
        let oilSlick = MercuryLook(island: IslandLook.oilSlick.appearance)
        var toned = oilSlick
        toned.tone = MercuryTone(brightness: -0.2, contrast: 0.4)
        var warm = MercuryLook.stock
        warm.lighting.whiteBalance = MercuryWhiteBalance.multipliers(temperature: 0.6)
        let looks = [
            oilSlick,
            toned,
            MercuryLook(island: IslandLook.neonKit.appearance),
            MercuryLook(island: IslandLook.candyApple.appearance),
            .stock,
            warm,
        ]
        var cold: [Data] = []
        for look in looks {
            cold.append(
                try Self.coldPinnedFrame(step: 600, seed: seed, look: look, drive: drive, layout: layout)
            )
        }
        let reused = MercuryEngine(seed: seed, look: .stock, hitRegion: MercuryHitRegion())
        // Every look, then three of them again.
        for index in [0, 1, 2, 3, 4, 5, 1, 0, 4] {
            let look = looks[index]
            let image = try #require(
                reused.pinnedFrame(
                    step: 600,
                    seed: seed,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            let fresh = MercuryEngine(seed: seed, look: look, hitRegion: MercuryHitRegion())
            let expected = try #require(
                fresh.pinnedFrame(
                    step: 600,
                    seed: seed,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            #expect(Self.bytes(image) == Self.bytes(expected), "\(display.id) \(look)")
            #expect(Self.bytes(image) == cold[index], "\(display.id) \(look)")
        }
    }

    /// A new seed is a new session: a new body grows afresh under the new look's light, frame
    /// for frame as a fresh engine grows its first, and its first frame is as empty.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func aNewSeedStartsAFreshBodyUnderItsLook(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        let neon = MercuryLook(island: IslandLook.neonKit.appearance)
        let reused = MercuryEngine(seed: 20, look: .stock, hitRegion: MercuryHitRegion())
        _ = try Self.emerged(reused, seed: 20, drive: drive, appearance: .standard, layout: layout)
        let fresh = MercuryEngine(seed: 21, look: neon, hitRegion: MercuryHitRegion())
        func frame(_ engine: MercuryEngine, advancing steps: Int) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: 21,
                look: neon,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        }
        #expect(frame(reused, advancing: 2) == nil)
        #expect(frame(fresh, advancing: 0) == nil)
        var grown: CGImage?
        for index in 0..<18 {
            grown = frame(reused, advancing: MercuryMetrics.maxSubstepsPerFrame)
            let expected = frame(fresh, advancing: MercuryMetrics.maxSubstepsPerFrame)
            #expect(grown.map(Self.bytes) == expected.map(Self.bytes), "\(display.id) frame \(index)")
        }
        _ = try #require(grown)
    }

    /// Paint, tone and tune solve the response again over the same room; only a new seed,
    /// world or room lighting changes it, and a room shown before comes back as that same room.
    /// An unchanged look solves nothing, and a pinned frame draws under the light a live frame
    /// built.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func aLookChangeRebuildsOnlyWhatItReaches(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        let engine = MercuryEngine(seed: 18, look: .stock, hitRegion: MercuryHitRegion())
        let stockRoom = engine.environment
        _ = try Self.emerged(engine, seed: 18, drive: drive, appearance: .standard, layout: layout)
        #expect(engine.environment === stockRoom)
        #expect(engine.meteredResponses == 1)

        func frame(seed: UInt64 = 18, _ look: MercuryLook) -> CGImage? {
            engine.frame(
                advancing: 1,
                seed: seed,
                look: look,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        }
        var look = MercuryLook.stock
        look.paint.metal = .gold
        look.tone.contrast = 0.4
        look.tune.morph = 1.3
        _ = try #require(frame(look))
        #expect(engine.environment === stockRoom)
        #expect(engine.meteredResponses == 2)
        _ = try #require(frame(look))
        #expect(engine.meteredResponses == 2)

        look.lighting.whiteBalance = MercuryWhiteBalance.multipliers(temperature: 0.5)
        _ = try #require(frame(look))
        let warmRoom = engine.environment
        #expect(warmRoom !== stockRoom)
        #expect(warmRoom.lighting == look.lighting)
        #expect(engine.meteredResponses == 3)

        _ = try #require(
            engine.pinnedFrame(
                step: 600,
                seed: 18,
                look: look,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        )
        #expect(engine.environment === warmRoom)
        #expect(engine.meteredResponses == 3)

        look.lighting = .stock
        _ = try #require(frame(look))
        #expect(engine.environment === stockRoom)
        #expect(engine.meteredResponses == 4)

        look.world = .spectralWeather
        _ = try #require(frame(look))
        let overcast = engine.environment
        #expect(overcast !== warmRoom)
        #expect(overcast.world == .spectralWeather)
        #expect(engine.meteredResponses == 5)

        // A new seed is a new body, which emerges empty and so lights nothing yet.
        #expect(frame(seed: 19, look) == nil)
        #expect(engine.environment !== overcast)
        #expect(engine.meteredResponses == 5)
    }

    /// A tune retunes the moving body in the same room: the frame is exactly that body,
    /// retuned mid-flight, under the response metered for the new look.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func retuningKeepsTheRoomAndTheMovingBody(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        var tuned = MercuryLook.stock
        tuned.tune.size = 0.9
        tuned.tune.crownAspect = 0.9
        tuned.tune.shimmer = 1.5
        let engine = MercuryEngine(seed: 11, look: .stock, hitRegion: MercuryHitRegion())
        let room = engine.environment
        _ = try Self.emerged(engine, seed: 11, drive: drive, appearance: .standard, layout: layout)
        let retuned = try #require(
            engine.frame(
                advancing: 2,
                seed: 11,
                look: tuned,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        )
        #expect(engine.environment === room)

        let body = MercurySimulation(seed: 11, gains: MercuryCalibration.shared.gains)
        body.reset(to: drive, emerging: true)
        for _ in 0..<18 {
            body.advance(steps: MercuryMetrics.maxSubstepsPerFrame, drive: drive)
        }
        body.retune(tuned.tune)
        body.advance(steps: 2, drive: drive)
        let expected = try #require(
            MercuryRasterizer().image(
                field: MercuryField(
                    geometry: body.geometry,
                    spine: layout.spine,
                    canvas: layout.canvasRect.size
                ),
                environment: room,
                response: MercuryCalibration.shared.displayResponse(
                    for: room,
                    bodySeed: 11,
                    layout: layout,
                    look: tuned
                ),
                appearance: .standard,
                paint: MercuryPaintLookup.lookup(for: tuned.paint),
                scale: MercuryMetrics.rasterScale
            )
        )
        #expect(Self.bytes(retuned) == Self.bytes(expected))
    }

    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func pinnedFrameKeysOnTheLook(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        let engine = MercuryEngine(seed: 16, look: .stock, hitRegion: MercuryHitRegion())
        func pinned(_ look: MercuryLook) throws -> CGImage {
            try #require(
                engine.pinnedFrame(
                    step: 600,
                    seed: 16,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
        }
        let first = try pinned(.stock)
        let cached = try pinned(.stock)
        #expect(first === cached)
        #expect(engine.meteredResponses == 1)

        var brighter = MercuryLook.stock
        brighter.tone.brightness = 0.3
        let toned = try pinned(brighter)
        #expect(toned !== first)
        #expect(Self.bytes(toned) != Self.bytes(first))
        #expect(engine.meteredResponses == 2)
    }

    /// A pinned frame that moves only the light redraws the body the previous one settled,
    /// and a new tune settles a new body: each draws what a fresh engine draws.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func aPinnedFrameRedrawsItsSettledBodyUnderNewLight(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        var next = MercuryLook.stock
        var looks = [next]
        // Only the paint, then only the tone, only the room lighting and only the tune.
        next.paint.metal = .gold
        looks.append(next)
        next.tone = MercuryTone(brightness: 0.3, contrast: -0.2)
        looks.append(next)
        next.lighting.whiteBalance = MercuryWhiteBalance.multipliers(temperature: -0.5)
        looks.append(next)
        next.tune.size = 0.9
        looks.append(next)
        let engine = MercuryEngine(seed: 24, look: .stock, hitRegion: MercuryHitRegion())
        for look in looks {
            let image = try #require(
                engine.pinnedFrame(
                    step: 600,
                    seed: 24,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            let fresh = MercuryEngine(seed: 24, look: look, hitRegion: MercuryHitRegion())
            let expected = try #require(
                fresh.pinnedFrame(
                    step: 600,
                    seed: 24,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            #expect(Self.bytes(image) == Self.bytes(expected), "\(display.id) \(look)")
        }
    }

    /// Live and pinned frames drive one body. A live frame after a pinned frame that redrew
    /// its settled body carries that body on; a pinned frame after live frames settles its
    /// own rather than redrawing the body they moved.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func liveAndPinnedFramesShareOneBody(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let drive = Drives.speaking(on: layout)
        var gold = MercuryLook.stock
        gold.paint.metal = .gold
        func pinned(_ engine: MercuryEngine, _ look: MercuryLook) -> CGImage? {
            engine.pinnedFrame(
                step: 600,
                seed: 25,
                look: look,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        }
        let reused = MercuryEngine(seed: 25, look: .stock, hitRegion: MercuryHitRegion())
        let control = MercuryEngine(seed: 25, look: .stock, hitRegion: MercuryHitRegion())
        // Started, so the live frames below advance whatever body a pinned frame left.
        for engine in [reused, control] {
            _ = engine.frame(
                advancing: 0,
                seed: 25,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: layout
            )
        }
        for look in [MercuryLook.stock, gold] {
            _ = pinned(reused, look)
        }
        _ = pinned(control, gold)

        var resumed: [Data] = []
        for engine in [reused, control] {
            let image = try #require(
                engine.frame(
                    advancing: 2,
                    seed: 25,
                    look: gold,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            resumed.append(Self.bytes(image))
        }
        #expect(resumed[0] == resumed[1], "\(display.id)")

        let repinned = try #require(pinned(reused, .stock))
        let fresh = MercuryEngine(seed: 25, look: .stock, hitRegion: MercuryHitRegion())
        let expected = try #require(pinned(fresh, .stock))
        #expect(Self.bytes(repinned) == Self.bytes(expected), "\(display.id)")
    }

    /// The caches keep each layout's own metering. An engine that redraws one pinned body on
    /// the island, the collar and the island again lights every frame as an engine-free render
    /// on that layout does, never by the response another layout's bodies metered, and solves
    /// a response for each layout it arrives on, cached or not.
    @Test func cachedLightingKeepsEachLayoutsOwnResponse() throws {
        let drive = Drives.speaking()
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        // No other test draws this seed, so the collar first asks while the cache holds only
        // the island's anchors for this room, paint and tune.
        let seed: UInt64 = 0x4C41_594F_5554
        let look = MercuryLook(island: IslandLook.oilSlick.appearance)
        let engine = MercuryEngine(seed: seed, look: look, hitRegion: MercuryHitRegion())
        for layout in [RecordingOverlayLayout.island, collar, .island] {
            let image = try #require(
                engine.pinnedFrame(
                    step: 600,
                    seed: seed,
                    look: look,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
            let cold = try Self.coldPinnedFrame(step: 600, seed: seed, look: look, drive: drive, layout: layout)
            #expect(Self.bytes(image) == cold, "\(layout.kind)")
        }
        #expect(engine.meteredResponses == 3)
    }

    // MARK: - Replay

    /// A replay requested before the body's first frame survives the reset that starts it
    /// and fires on the first advancing frame, exactly as one requested after that reset.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func replayGestureFiresAgainEvenBeforeTheFirstFrame(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let outcome = try Drives.outcome(.insertFailed(reason: "no focused element"), on: layout)
        let source = Drives.processingPose(on: layout)
        let early = MercuryEngine(seed: 14, look: .stock, hitRegion: MercuryHitRegion())
        let late = MercuryEngine(seed: 14, look: .stock, hitRegion: MercuryHitRegion())
        let unarmed = MercuryEngine(seed: 14, look: .stock, hitRegion: MercuryHitRegion())
        func frame(_ engine: MercuryEngine, advancing steps: Int) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: 14,
                look: .stock,
                drive: outcome,
                appearance: .standard,
                layout: layout
            )
        }
        early.replayGesture(from: source)
        for engine in [early, late, unarmed] {
            #expect(frame(engine, advancing: 0) == nil)
        }
        late.replayGesture(from: source)

        var images: [Data?] = []
        for engine in [early, late, unarmed] {
            var image = frame(engine, advancing: 2)
            for _ in 0..<18 {
                image = frame(engine, advancing: MercuryMetrics.maxSubstepsPerFrame)
            }
            images.append(image.map(Self.bytes))
        }
        _ = try #require(images[0])
        #expect(images[0] == images[1])
        #expect(images[0] != images[2])
    }

    /// A replay that meets a live pose is dropped rather than kept for the next outcome.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func replayGestureIsDroppedOnALivePose(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let live = Drives.speaking(on: layout)
        let outcome = try Drives.outcome(.insertFailed(reason: "no focused element"), on: layout)
        let replayed = MercuryEngine(seed: 15, look: .stock, hitRegion: MercuryHitRegion())
        let control = MercuryEngine(seed: 15, look: .stock, hitRegion: MercuryHitRegion())
        for engine in [replayed, control] {
            _ = try Self.emerged(engine, seed: 15, drive: live, appearance: .standard, layout: layout)
        }
        replayed.replayGesture(from: Drives.processingPose(on: layout))

        var images: [[Data]] = []
        for engine in [replayed, control] {
            var frames: [Data] = []
            for drive in [live, outcome, outcome] {
                let image = try #require(
                    engine.frame(
                        advancing: 2,
                        seed: 15,
                        look: .stock,
                        drive: drive,
                        appearance: .standard,
                        layout: layout
                    )
                )
                frames.append(Self.bytes(image))
            }
            images.append(frames)
        }
        #expect(images[0] == images[1])
    }

    /// The first configuration only records its generation, however high; each later
    /// increase replays once, and the same generation again replays nothing.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func surfaceViewReplaysOncePerGeneration(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        let outcome = try Drives.outcome(.error(.inferenceFailed), on: layout)
        let source = Drives.processingPose(on: layout)
        let view = MercurySurfaceView(seed: 13, look: .stock, hitRegion: MercuryHitRegion())
        let control = MercuryEngine(seed: 13, look: .stock, hitRegion: MercuryHitRegion())
        func configure(generation: Int) {
            view.update(
                MercurySurfaceView.Configuration(
                    seed: 13,
                    look: .stock,
                    drive: outcome,
                    appearance: .standard,
                    layout: layout,
                    pinnedStep: nil,
                    replayGeneration: generation,
                    replaySource: source
                )
            )
        }
        func controlFrame(advancing steps: Int) -> CGImage? {
            control.frame(
                advancing: steps,
                seed: 13,
                look: .stock,
                drive: outcome,
                appearance: .standard,
                layout: layout
            )
        }
        // Steps the view and the control engine together; true when they drew the same.
        func stepMatches(replaying: Bool) throws -> Bool {
            if replaying {
                control.replayGesture(from: source)
            }
            view.renderLive(steps: 2)
            let expected = try #require(controlFrame(advancing: 2))
            return Self.bytes(try #require(view.currentImage)) == Self.bytes(expected)
        }

        // The first configuration draws the view's first live frame: the body about to emerge.
        configure(generation: 3)
        #expect(view.currentImage == nil)
        #expect(controlFrame(advancing: 0) == nil)
        for _ in 0..<18 {
            view.renderLive(steps: MercuryMetrics.maxSubstepsPerFrame)
            _ = controlFrame(advancing: MercuryMetrics.maxSubstepsPerFrame)
        }
        #expect(try stepMatches(replaying: false))

        configure(generation: 4)
        #expect(try stepMatches(replaying: true))

        configure(generation: 4)
        #expect(try stepMatches(replaying: false))

        configure(generation: 6)
        #expect(try stepMatches(replaying: true))
    }

    // MARK: - Presentation

    @Test func livePresentationRendersEveryCommittedStepAndCachesDuplicates() throws {
        let drive = Drives.speaking()
        let engine = MercuryEngine(
            seed: 7,
            look: .stock,
            hitRegion: MercuryHitRegion()
        )
        let first = try Self.emerged(engine, seed: 7, drive: drive, appearance: .standard, layout: .island)
        let duplicate = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        let next = try #require(
            engine.frame(
                advancing: 1,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        #expect(first === duplicate)
        #expect(first !== next)
    }

    @Test func appearanceChangesAlwaysRerasterTheCurrentGeometry() throws {
        let drive = Drives.speaking()
        let engine = MercuryEngine(
            seed: 9,
            look: .stock,
            hitRegion: MercuryHitRegion()
        )
        let standard = try Self.emerged(engine, seed: 9, drive: drive, appearance: .standard, layout: .island)
        let increased = try #require(
            engine.frame(
                advancing: 0,
                seed: 9,
                look: .stock,
                drive: drive,
                appearance: MercuryAppearance(increasedContrast: true),
                layout: .island
            )
        )

        #expect(standard !== increased)
    }

    /// A collar frame covers exactly its canvas at the raster scale, and not one of its
    /// pixels inside the camera housing is set. The body runs along nine tenths of the
    /// spine, so the walls, the fillets and both ears carry mercury right beside the housing
    /// edge; the housing is rebuilt from its outline here rather than read through the chart
    /// the rasterizer consults.
    @Test(arguments: [OverlayDisplay.fixtureNotch, .fixtureWideNotch])
    func collarPinnedFramesFillTheirCanvasAndNeverDrawInsideTheHousing(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        guard case .collar(let outline) = layout.spine.kind else {
            Issue.record("a notched display wears the collar")
            return
        }
        let engine = MercuryEngine(
            seed: 5,
            look: .stock,
            hitRegion: MercuryHitRegion()
        )
        let image = try #require(
            engine.pinnedFrame(
                step: 600,
                seed: 5,
                look: .stock,
                drive: Drives.collar(spine: layout.spine),
                appearance: .standard,
                layout: layout
            )
        )
        let scale = Double(MercuryMetrics.rasterScale)
        let canvas = layout.canvasRect.size
        #expect(image.width == Int((Double(canvas.width) * scale).rounded()))
        #expect(image.height == Int((Double(canvas.height) * scale).rounded()))

        let bytes = [UInt8](Self.bytes(image))
        var housed = 0
        var drawnInHousing = 0
        var drawnOutside = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * 4
                let drawn = bytes[offset..<offset + 4].contains { $0 != 0 }
                let centre = SIMD2(
                    (Double(column) + 0.5) / scale - Double(canvas.width) / 2,
                    Double(canvas.height) / 2 - (Double(row) + 0.5) / scale
                )
                if Self.housing(outline, contains: centre) {
                    housed += 1
                    if drawn { drawnInHousing += 1 }
                } else if drawn {
                    drawnOutside += 1
                }
            }
        }
        #expect(housed > 0)
        #expect(drawnInHousing == 0)
        #expect(drawnOutside > 0)
    }

    /// A repeated collar frame is the image already on the layer, a layout change is a new
    /// image, and the hit region answers in the layout of the frame it was last handed.
    @Test func collarFramesReuseTheirImageAndHandTheHitRegionTheirLayout() throws {
        let drive = Drives.speaking()
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let region = MercuryHitRegion()
        let engine = MercuryEngine(seed: 7, look: .stock, hitRegion: region)
        let island = try Self.emerged(engine, seed: 7, drive: drive, appearance: .standard, layout: .island)
        // 3 pt above the island's centre: on the island's body, and in the collar's band.
        let raised = CGPoint(x: 130, y: 30)
        #expect(region.contains(raised, slop: MercuryMetrics.dragSlop))

        let collared = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let repeated = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        #expect(collared !== island)
        #expect(collared === repeated)
        #expect(collared.width == Int((collar.canvasRect.width * MercuryMetrics.rasterScale).rounded()))
        #expect(!region.contains(raised, slop: MercuryMetrics.dragSlop))
        // 2 pt under the housing's centre, on the chin.
        #expect(region.contains(CGPoint(x: collar.canvasRect.midX, y: collar.statusRect.minY + 2), slop: 0))

        let stepped = try #require(
            engine.frame(
                advancing: 1,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        #expect(stepped !== collared)

        let pinning = MercuryEngine(seed: 7, look: .stock, hitRegion: MercuryHitRegion())
        let pinned = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let pinnedAgain = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let pinnedIsland = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        #expect(pinned === pinnedAgain)
        #expect(pinnedIsland !== pinned)
    }

    /// A room is metered against the bodies of the layout it lights. An engine meters once
    /// for the first layout it draws and keeps that response for every frame on it, whatever
    /// the appearance or the step; a frame on another layout meters again, in the same room.
    /// So a collar the engine reaches from the island is lit exactly as a collar it started
    /// on, and never by the island's response.
    @Test func lightingIsMeteredOnTheLayoutItLightsAndKeptUntilTheLayoutChanges() throws {
        let drive = Drives.speaking()
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let room = MercuryEnvironment(world: .roomOfTen, seed: 7)
        let calibration = MercuryCalibration.shared
        // Two different responses, or nothing below could tell which one lit a frame.
        #expect(
            calibration.displayResponse(for: room, bodySeed: 7, layout: .island)
                != calibration.displayResponse(for: room, bodySeed: 7, layout: collar)
        )

        let engine = MercuryEngine(seed: 7, look: .stock, hitRegion: MercuryHitRegion())
        func frame(
            advancing steps: Int,
            on layout: RecordingOverlayLayout,
            appearance: MercuryAppearance = .standard
        ) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: 7,
                look: .stock,
                drive: drive,
                appearance: appearance,
                layout: layout
            )
        }
        // The emerging body's first frame is empty, and an empty frame lights nothing.
        #expect(frame(advancing: 0, on: .island) == nil)
        #expect(engine.meteredResponses == 0)
        for _ in 0..<60 {
            _ = frame(advancing: 2, on: .island)
        }
        _ = try #require(frame(advancing: 1, on: .island, appearance: MercuryAppearance(increasedContrast: true)))
        #expect(engine.meteredResponses == 1)

        _ = try #require(frame(advancing: 1, on: collar))
        #expect(engine.meteredResponses == 2)
        for _ in 0..<60 {
            _ = frame(advancing: 2, on: collar)
        }
        #expect(engine.meteredResponses == 2)
        _ = try #require(frame(advancing: 1, on: .island))
        #expect(engine.meteredResponses == 3)

        let travelled = MercuryEngine(seed: 7, look: .stock, hitRegion: MercuryHitRegion())
        let fresh = MercuryEngine(seed: 7, look: .stock, hitRegion: MercuryHitRegion())
        func pinned(_ engine: MercuryEngine, step: Int, on layout: RecordingOverlayLayout) throws -> CGImage {
            try #require(
                engine.pinnedFrame(
                    step: step,
                    seed: 7,
                    look: .stock,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
        }
        _ = try pinned(travelled, step: 120, on: .island)
        let relit = try pinned(travelled, step: 120, on: collar)
        let collarFromTheStart = try pinned(fresh, step: 120, on: collar)
        #expect(Self.bytes(relit) == Self.bytes(collarFromTheStart))
        _ = try pinned(travelled, step: 240, on: collar)
        #expect(travelled.meteredResponses == 2)
        #expect(fresh.meteredResponses == 1)
    }

    // MARK: - Fixtures

    /// Strictly inside the camera housing: between its walls and above its bottom edge, less
    /// the two rounded bottom corners.
    private static func housing(_ outline: MercurySpine.Outline, contains point: SIMD2<Double>) -> Bool {
        guard point.x > outline.minX, point.x < outline.maxX, point.y > outline.bottom else { return false }
        let radius = outline.cornerRadius
        let cornerY = outline.bottom + radius
        guard point.y < cornerY else { return true }
        let cornerX = Swift.min(Swift.max(point.x, outline.minX + radius), outline.maxX - radius)
        let lateral = point.x - cornerX
        let vertical = point.y - cornerY
        return lateral * lateral + vertical * vertical < radius * radius
    }

    /// A pinned frame built without any engine: a new body, a newly baked room and a newly
    /// metered response, laid out and lit for `layout`.
    private static func coldPinnedFrame(
        step: Int,
        seed: UInt64,
        look: MercuryLook,
        drive: MercurySimulation.Drive,
        layout: RecordingOverlayLayout
    ) throws -> Data {
        let body = MercurySimulation(
            seed: seed,
            gains: MercuryCalibration.shared.gains,
            tune: look.tune
        )
        body.reset(to: drive)
        body.advance(steps: step, drive: drive)
        let room = MercuryEnvironment(world: look.world, seed: seed, lighting: look.lighting)
        let image = try #require(
            MercuryRasterizer().image(
                field: MercuryField(
                    geometry: body.geometry,
                    spine: layout.spine,
                    canvas: layout.canvasRect.size
                ),
                environment: room,
                response: MercuryCalibration.shared.displayResponse(
                    for: room,
                    bodySeed: seed,
                    layout: layout,
                    look: look
                ),
                appearance: .standard,
                paint: MercuryPaintLookup.lookup(for: look.paint),
                scale: MercuryMetrics.rasterScale
            )
        )
        return bytes(image)
    }

    private static func bytes(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    /// A fresh engine's emergence under the stock look. Its first live frame is the empty body
    /// about to grow out of the notch or the top edge, which draws nothing; 0.6 s of full frames
    /// later the body is in its pose.
    private static func emerged(
        _ engine: MercuryEngine,
        seed: UInt64,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) throws -> CGImage {
        func frame(advancing steps: Int) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: seed,
                look: .stock,
                drive: drive,
                appearance: appearance,
                layout: layout
            )
        }
        #expect(frame(advancing: 0) == nil)
        var image: CGImage?
        for _ in 0..<18 {
            image = frame(advancing: MercuryMetrics.maxSubstepsPerFrame)
        }
        return try #require(image)
    }
}

/// The two layouts, held to the numbers they are built from: the island's established
/// frames, and each notch fixture's collar rebuilt here from its housing rect.
@MainActor
struct RecordingOverlayLayoutTests {
    /// The panel and the status element keep the island's established frames: the element is
    /// exactly the envelope placement measures, turned into the panel's flipped space. The
    /// canvas runs 8 pt past it at each end, centred on it, and the spine runs the canvas.
    @Test func theIslandKeepsItsEstablishedFrames() {
        let island = RecordingOverlayLayout.island
        #expect(island.kind == .island)
        #expect(island.panelSize == NSSize(width: 260, height: 80))
        #expect(island.statusRect == CGRect(x: 40, y: 16, width: 180, height: 34))
        let panel = NSRect(origin: .zero, size: RecordingOverlayMetrics.windowSize)
        let envelope = RecordingOverlayMetrics.islandFrame(forWindow: panel)
        #expect(island.statusRect == CGRect(x: envelope.minX, y: panel.maxY - envelope.maxY, width: 180, height: 34))
        #expect(island.canvasRect == CGRect(x: 32, y: 16, width: 196, height: 34))
        #expect(island.canvasRect.midX == island.statusRect.midX)
        #expect(island.spine == MercurySpine(straightLength: 196))
        #expect(island.bandHeight == 0)
    }

    /// The canvas reaches the 4.5 pt fillet, the 56 pt ear and 4 pt more beyond each wall,
    /// and the collar's 24 pt ceiling + 3 pt below the housing, which hangs centred from its top
    /// edge. The status element is the chin's strip directly under the housing.
    @Test func notchedDisplaysWearACollarHungFromTheTopEdge() throws {
        let expectations: [(display: OverlayDisplay, canvas: CGSize, status: CGRect, outline: MercurySpine.Outline)] = [
            (
                .fixtureNotch,
                CGSize(width: 314, height: 59),
                CGRect(x: 64.5, y: 32, width: 185, height: 27),
                MercurySpine.Outline(
                    minX: -92.5,
                    maxX: 92.5,
                    bottom: -2.5,
                    top: 29.5,
                    cornerRadius: 0.44 * 32,
                    filletRadius: 4.5,
                    earLength: 56,
                    bandFilm: 3.5,
                    maxHalfHeight: 24
                )
            ),
            (
                .fixtureWideNotch,
                CGSize(width: 349, height: 65),
                CGRect(x: 64.5, y: 38, width: 220, height: 27),
                // 0.44 × 38 = 16.72 rounds to the largest corner, 16 pt.
                MercurySpine.Outline(
                    minX: -110,
                    maxX: 110,
                    bottom: -5.5,
                    top: 32.5,
                    cornerRadius: 16,
                    filletRadius: 4.5,
                    earLength: 56,
                    bandFilm: 3.5,
                    maxHalfHeight: 24
                )
            ),
        ]
        for expected in expectations {
            let layout = RecordingOverlayLayout.forDisplay(expected.display)
            #expect(layout.kind == .collar)
            #expect(layout.panelSize == expected.canvas)
            #expect(layout.canvasRect == CGRect(origin: .zero, size: expected.canvas))
            #expect(layout.statusRect == expected.status)
            #expect(layout.bandHeight == expected.display.bandHeight)
            #expect(layout.spine.kind == .collar(expected.outline))
            #expect(layout.spine == MercurySpine(collar: expected.outline))
            let housing = try #require(expected.display.housing)
            #expect(
                RecordingOverlayLayout.collar(housingSize: housing.size, bandHeight: expected.display.bandHeight)
                    == layout
            )
        }
    }

    @Test func displaysWithoutAWearableHousingGetTheIsland() {
        #expect(RecordingOverlayLayout.forDisplay(.fixtureNotchless) == .island)
        var mirrored = OverlayDisplay.fixtureNotch
        mirrored.isMirrored = true
        #expect(RecordingOverlayLayout.forDisplay(mirrored) == .island)
        var shallow = OverlayDisplay.fixtureNotch
        shallow.housing = CGRect(x: 771.5, y: 1_107, width: 185, height: 10)
        #expect(RecordingOverlayLayout.forDisplay(shallow) == .island)
    }

    /// The spine lays any housing taller than its fillet. The layout refuses one that would
    /// round its corner below 6 pt, `4.5 + 6` pt deep or less, and one no wider than its two
    /// corners, which leaves the chin no bottom run.
    @Test func housingsTooShallowOrTooNarrowAreNotCollars() {
        func collar(width: CGFloat, height: CGFloat) -> RecordingOverlayLayout? {
            RecordingOverlayLayout.collar(
                housingSize: CGSize(width: width, height: height),
                bandHeight: height + 1
            )
        }
        #expect(collar(width: 185, height: 10.5) == nil)
        #expect(collar(width: 185, height: 11)?.kind == .collar)
        let corners = CGFloat(2 * 0.44 * 32)
        #expect(collar(width: corners, height: 32) == nil)
        #expect(collar(width: corners + 0.5, height: 32)?.kind == .collar)
        #expect(collar(width: 0, height: 32) == nil)
        #expect(collar(width: .nan, height: 32) == nil)
        #expect(collar(width: 185, height: .infinity) == nil)
    }

    /// The collar's film in the menu-bar band is drawn but never claimed. Below the band the
    /// region is exactly the field with its drag slop, converted through the canvas.
    @Test func theCollarHitRegionRejectsTheMenuBarBandAndAcceptsTheChin() {
        let layout = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let drive = Drives.collar(spine: layout.spine)
        let simulation = MercurySimulation(seed: 21, gains: MercuryGains(drive: 1, snake: 0.011))
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        let field = MercuryField(
            geometry: simulation.geometry,
            spine: layout.spine,
            canvas: layout.canvasRect.size
        )
        let region = MercuryHitRegion()
        region.update(field, layout: layout)
        let slop = MercuryMetrics.dragSlop
        let canvas = layout.canvasRect

        var mismatches = 0
        var coveredInBand = 0
        var claimed = 0
        for x in stride(from: canvas.minX + 0.25, to: canvas.maxX, by: 0.5) {
            for y in stride(from: canvas.minY + 0.25, to: canvas.maxY, by: 0.5) {
                let covered = field.value(at: CGPoint(x: x - canvas.midX, y: canvas.midY - y)) >= -slop
                let contained = region.contains(CGPoint(x: x, y: y), slop: slop)
                if y < layout.bandHeight {
                    if covered { coveredInBand += 1 }
                    if contained { mismatches += 1 }
                } else {
                    if contained != covered { mismatches += 1 }
                    if contained { claimed += 1 }
                }
            }
        }
        #expect(mismatches == 0)
        #expect(coveredInBand > 0)
        #expect(claimed > 0)

        // 2 pt under the housing's centre, on the chin.
        let chin = CGPoint(x: canvas.midX, y: layout.statusRect.minY + 2)
        #expect(region.contains(chin, slop: 0))
        region.clear()
        #expect(!region.contains(chin, slop: slop))
    }
}

@MainActor
private enum Drives {
    static func speaking() -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in MercurySpeechMeter.syllable {
            model.record(level)
        }
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: false
        )
    }

    /// The speaking drive on a body nine tenths of the spine long, which the collar's whole
    /// spine lets it grow to: it covers the bottom and both corners, climbs the walls, turns
    /// the fillets and runs out along both ears.
    static func collar(spine: MercurySpine) -> MercurySimulation.Drive {
        var drive = speaking()
        drive.pose.length = CGFloat(0.9 * spine.length)
        drive.maxLength = spine.length
        return drive
    }

    /// The drive the ribbon hands the engine for a microphone on `layout` hearing the syllable:
    /// that layout's own speaking rung.
    static func speaking(on layout: RecordingOverlayLayout) -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in MercurySpeechMeter.syllable {
            model.record(level)
        }
        return .target(for: model, reduceMotion: false)
    }

    /// An outcome pose on `layout`'s ladder, the only kind with a gesture to replay.
    static func outcome(_ state: SessionState, on layout: RecordingOverlayLayout) throws -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(state)
        model.present(try #require(RecordingOverlayOutcome(state: state)))
        let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
        _ = try #require(drive.pose.gesture)
        return drive
    }

    /// The pose a replay starts from on `layout`, as the live processing-to-outcome transition
    /// does.
    static func processingPose(on layout: RecordingOverlayLayout) -> MercuryPose {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.transcribing)
        return MercurySimulation.Drive.target(for: model, reduceMotion: false).pose
    }
}
