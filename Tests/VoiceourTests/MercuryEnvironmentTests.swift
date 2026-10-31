import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Both generated rooms, held to the same contract.
///
/// The debug world is not a sketch: it writes into the same prefiltered tables the
/// shipped one does, so every property below is asserted for both. A world that only the
/// `--debug` build can reach is exactly the kind of thing that rots quietly.
@MainActor
struct MercuryEnvironmentTests {
    /// The seed of the stock rooms the chroma, seam and room-lighting tests share.
    private static let roomSeed: UInt64 = 17

    /// Room of Ten at `roomSeed`, baked once for every test that only reads it.
    private static let roomOfTen = MercuryEnvironment(world: .roomOfTen, seed: roomSeed)

    /// Source sharpnesses are drawn log-uniform over the room-scale bounds. Measured
    /// with a Kolmogorov-Smirnov statistic against the declared marginal rather than a
    /// histogram, because the marginal is the contract.
    @Test func roomSharpnessIsLogUniform() {
        var samples: [Double] = []
        let rooms = 410
        for seed in 0..<rooms {
            samples.append(
                contentsOf: RoomOfTenWorld(
                    seed: UInt64(seed) &* 0x9e37_79b9_7f4a_7c15
                ).sharpnesses
            )
        }
        #expect(samples.count == rooms * MercuryMetrics.roomLobeCount)
        #expect(
            samples.allSatisfy {
                $0 >= MercuryMetrics.roomLambdaMin
                    && $0 <= MercuryMetrics.roomLambdaMax
            }
        )

        let low = Foundation.log(MercuryMetrics.roomLambdaMin)
        let high = Foundation.log(MercuryMetrics.roomLambdaMax)
        let sorted = samples.map { (Foundation.log($0) - low) / (high - low) }.sorted()
        var deviation = 0.0
        for (index, value) in sorted.enumerated() {
            let below = Double(index) / Double(sorted.count)
            let above = Double(index + 1) / Double(sorted.count)
            deviation = Swift.max(deviation, Swift.max(abs(value - below), abs(value - above)))
        }
        // 1.63 / sqrt(n) is the 99% Kolmogorov bound at this sample count.
        #expect(deviation < 1.63 / Double(sorted.count).squareRoot())
    }

    /// The reflected room is world-fixed. All visible motion belongs to the mercury
    /// surface; an environment that rotates under an unchanged body is the mechanical
    /// light sweep the material bench exists to reject.
    @Test(arguments: MercuryWorld.allCases)
    func generatedWorldDoesNotMoveIndependentlyOfTheBody(world: MercuryWorld) {
        let environment = MercuryEnvironment(world: world, seed: 3)
        let before = Self.sample(environment)

        environment.advance(steps: 3_600, frozen: false)

        #expect(Self.sample(environment) == before)
    }

    /// Chrome gets subtle colour from what it reflects, not from a tint painted on the
    /// body. Individual room directions therefore carry RGB variation while the room's
    /// sphere mean stays neutral and cannot cast the whole island green or blue.
    @Test func roomOfTenHasLocalChromaAndNeutralMean() {
        let environment = Self.roomOfTen
        var mean = SIMD3<Double>.zero
        var maximumLocalChroma = 0.0
        for direction in Self.denseDirections {
            let radiance: SIMD3<Float> = environment.radiance(
                direction,
                roughness: MercuryMetrics.environmentRoughness[0]
            )
            #expect(radiance.min() > 0)
            let value = SIMD3<Double>(
                Double(radiance.x), Double(radiance.y), Double(radiance.z)
            )
            mean += value
            maximumLocalChroma = Swift.max(
                maximumLocalChroma,
                (value.max() - value.min()) / Swift.max(value.max(), 1e-12)
            )
        }
        mean /= Double(Self.denseDirections.count)
        let cast =
            (mean.max() - mean.min())
            / Swift.max(MercuryDisplayResponse.luminance(mean), 1e-12)

        #expect(maximumLocalChroma >= 0.03)
        #expect(maximumLocalChroma <= 0.12)
        #expect(cast <= 0.01)
    }

    @Test func octahedralBorderIsContinuousAroundNegativeZ() {
        let environment = Self.roomOfTen
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let epsilon: Float = 1e-5
        for index in 0..<512 {
            let angle = Float(index) / 512 * 2 * .pi
            let direction = SIMD3(
                epsilon * cos(angle),
                epsilon * sin(angle),
                -1
            )
            let value = environment.radiance(direction)
            minimum = SIMD3(
                Swift.min(minimum.x, value.x),
                Swift.min(minimum.y, value.y),
                Swift.min(minimum.z, value.z)
            )
            maximum = SIMD3(
                Swift.max(maximum.x, value.x),
                Swift.max(maximum.y, value.y),
                Swift.max(maximum.z, value.z)
            )
        }

        #expect((maximum - minimum).max() < 0.01)
    }

    /// The same world and seed is the same room, and a different seed is a different one.
    @Test(arguments: MercuryWorld.allCases)
    func roomsReplayAndDifferBySeed(world: MercuryWorld) {
        let first = MercuryEnvironment(world: world, seed: 21)
        let second = MercuryEnvironment(world: world, seed: 21)
        let other = MercuryEnvironment(world: world, seed: 22)
        for environment in [first, second, other] {
            environment.advance(steps: 600, frozen: false)
        }
        #expect(Self.sample(first) == Self.sample(second))
        #expect(Self.sample(first) != Self.sample(other))
    }

    /// The two worlds are genuinely different rooms, not one room with two names.
    @Test func theTwoWorldsDiffer() {
        let room = MercuryEnvironment(world: .roomOfTen, seed: 21)
        let weather = MercuryEnvironment(world: .spectralWeather, seed: 21)
        room.advance(steps: 600, frozen: false)
        weather.advance(steps: 600, frozen: false)
        #expect(Self.sample(room) != Self.sample(weather))
    }

    /// Radiance is strictly positive everywhere, and prefiltering conserves power: the
    /// three roughness levels agree on the sphere mean, so a rougher patch of body is not
    /// a darker one.
    @Test(arguments: MercuryWorld.allCases, [UInt64(1), 7, 0x5155_4943_4B53_4C56])
    func radianceIsPositiveAndRoughnessConservesPower(world: MercuryWorld, seed: UInt64) {
        let environment = MercuryEnvironment(world: world, seed: seed)
        environment.advance(steps: 120, frozen: false)
        var means: [Double] = []
        var nonPositive = 0
        for roughness in MercuryMetrics.environmentRoughness {
            var total = 0.0
            for direction in Self.denseDirections {
                let value = environment.radiance(direction, roughness: roughness)
                if !(value.min() > 0) { nonPositive += 1 }
                total += MercuryDisplayResponse.luminance(
                    SIMD3(
                        Double(value.x), Double(value.y), Double(value.z)
                    )
                )
            }
            means.append(total / Double(Self.denseDirections.count))
        }
        #expect(nonPositive == 0, "\(world.rawValue) seed \(seed): \(nonPositive) non-positive samples")
        let lowest = means.min() ?? 0
        let highest = means.max() ?? 0
        #expect(highest - lowest <= 0.06 * highest, "\(world.rawValue) seed \(seed) means \(means)")
    }

    // MARK: - Room lighting

    private struct ShippedRoom {
        let world: MercuryWorld
        let seed: UInt64
        let room: MercuryEnvironment
    }

    /// One default-initialized room per world at `roomSeed`, baked once: every
    /// room-lighting test measures against it, and a room never changes after its bake. A
    /// lighting option acts on the bake, never on the seed's draw, so one room per world
    /// exercises every option's path.
    private static let shippedRooms: [ShippedRoom] = MercuryWorld.allCases.map { world in
        let room = world == .roomOfTen ? roomOfTen : MercuryEnvironment(world: world, seed: roomSeed)
        return ShippedRoom(world: world, seed: roomSeed, room: room)
    }

    /// Blackbody white balances at t = +1 and t = -1 (4,678 K and 10,667 K against
    /// 6,504 K), each at Rec.709 luminance 1. Literal, so the bake is held to its own
    /// contract apart from the spectral solve that produces them.
    private static let warmBalance = SIMD3<Double>(1.21683, 0.96884, 0.67021)
    private static let coolBalance = SIMD3<Double>(0.81855, 1.01063, 1.42899)

    /// A saturated blue at Rec.709 luminance 1 and full strength: far enough from the
    /// near-neutral room that its hue is unambiguous wherever it dominates.
    private static let blueUnderglow: MercuryUnderglow = {
        let raw = SIMD3<Double>(0.05, 0.2, 1)
        return MercuryUnderglow(color: raw / MercuryDisplayResponse.luminance(raw), strength: 1)
    }()

    /// Stock is the shipped room, not a room close to it. Explicit stock bakes exactly
    /// what the default initializer bakes, and so does every neutral value of every
    /// option at once: a finish clamped up to stock, a unit white balance and a
    /// zero-strength underglow. An option that leaks into the bake moves a whole level, so
    /// every level is compared on the sphere lattice.
    @Test(arguments: MercuryWorld.allCases)
    func neutralLightingBakesTheShippedRoom(world: MercuryWorld) {
        let neutral = MercuryRoomLighting(
            finish: 0,
            whiteBalance: SIMD3(repeating: 1),
            underglow: MercuryUnderglow(color: SIMD3(repeating: 1), strength: 0)
        )
        for shipped in Self.shippedRooms where shipped.world == world {
            #expect(shipped.room.lighting == .stock)
            let expected = Self.sample(shipped.room)
            for lighting in [MercuryRoomLighting.stock, neutral] {
                let environment = MercuryEnvironment(
                    world: world,
                    seed: shipped.seed,
                    lighting: lighting
                )
                #expect(
                    Self.sample(environment) == expected,
                    "\(world.rawValue) seed \(shipped.seed) \(lighting)"
                )
            }
        }
    }

    /// The finish replaces the smooth level and floors the rougher two, so no level is
    /// smoother than the material. Out-of-range finishes clamp into the table, and the
    /// stock finish is the shipped layout.
    @Test func finishSetsTheLevelLayout() {
        #expect(MercuryRoomLighting.stock.levelRoughness == MercuryMetrics.environmentRoughness)
        let layouts: [(finish: Float, levels: [Float])] = [
            (0, [0.03, 0.09, 0.25]),
            (0.06, [0.06, 0.09, 0.25]),
            (0.12, [0.12, 0.12, 0.25]),
            (0.25, [0.25, 0.25, 0.25]),
            (1, [0.25, 0.25, 0.25]),
        ]
        for layout in layouts {
            var lighting = MercuryRoomLighting.stock
            lighting.finish = layout.finish
            #expect(lighting.levelRoughness == layout.levels, "finish \(layout.finish)")
        }
    }

    /// A rough finish spreads every source into a broader, dimmer lobe, and the room is
    /// still normalized to the same mean: roughness costs highlight, never exposure.
    @Test(arguments: MercuryWorld.allCases)
    func roughFinishLowersPeaksAtTheSameMean(world: MercuryWorld) {
        var rough = MercuryRoomLighting.stock
        rough.finish = 0.25
        for shipped in Self.shippedRooms where shipped.world == world {
            let context = "\(world.rawValue) seed \(shipped.seed)"
            let environment = MercuryEnvironment(world: world, seed: shipped.seed, lighting: rough)
            let peak = Self.peakLuminance(environment)
            let stockPeak = Self.peakLuminance(shipped.room)
            let mean = MercuryDisplayResponse.luminance(Self.meanRadiance(environment))
            #expect(peak < stockPeak, "\(context) peak \(peak) against \(stockPeak)")
            #expect(abs(mean - 1) <= 1e-3, "\(context) mean \(mean)")
            Self.expectPhysical(environment, context)
        }
    }

    /// Colour temperature re-tints the light without re-exposing it: warm raises the
    /// room's red-to-blue ratio, cool lowers it, and the normalized mean stays 1.
    @Test(arguments: MercuryWorld.allCases)
    func whiteBalanceTintsWithoutExposure(world: MercuryWorld) {
        for shipped in Self.shippedRooms where shipped.world == world {
            let stock = Self.meanRadiance(shipped.room)
            for (balance, warm) in [(Self.warmBalance, true), (Self.coolBalance, false)] {
                var lighting = MercuryRoomLighting.stock
                lighting.whiteBalance = balance
                let mean = Self.meanRadiance(
                    MercuryEnvironment(world: world, seed: shipped.seed, lighting: lighting)
                )
                let context = "\(world.rawValue) seed \(shipped.seed) balance \(balance)"
                let ratio = mean.x / mean.z
                let stockRatio = stock.x / stock.z
                #expect(
                    warm ? ratio > stockRatio : ratio < stockRatio,
                    "\(context) red/blue \(ratio) against \(stockRatio)"
                )
                let luminance = MercuryDisplayResponse.luminance(mean)
                #expect(abs(luminance - 1) <= 1e-3, "\(context) mean \(luminance)")
            }
        }
    }

    /// The underglow is light below the island. Along its axis it adds its own colour at
    /// nearly its 0.8 peak, enough to own the hue there. At the mirrored top-light
    /// direction, 130 degrees away, the λ = 4 lobe has fallen to e^(-6.54): 1.15e-3 room
    /// means on the smooth level. Every level gains exactly the declared power,
    /// `0.8 (1 - e^-8) / 8` of the room mean, so roughness still costs no exposure.
    @Test(arguments: MercuryWorld.allCases)
    func underglowLightsTheRoomFromBelow(world: MercuryWorld) {
        var lit = MercuryRoomLighting.stock
        lit.underglow = Self.blueUnderglow
        let color = Self.blueUnderglow.color
        let axis = SIMD3<Float>(0, -0.906308, 0.422618)
        let top = SIMD3<Float>(0, 0.906308, 0.422618)
        let declaredPower = 0.8 * (1 - Foundation.exp(-8.0)) / 8
        for shipped in Self.shippedRooms where shipped.world == world {
            let context = "\(world.rawValue) seed \(shipped.seed)"
            let stock = shipped.room
            let environment = MercuryEnvironment(world: world, seed: shipped.seed, lighting: lit)

            let glowing = Self.double(environment.radiance(axis))
            let added = glowing - Self.double(stock.radiance(axis))
            let addedLuminance = MercuryDisplayResponse.luminance(added)
            let hueError = added / addedLuminance - color
            #expect(addedLuminance > 0.3, "\(context) axis gained \(addedLuminance)")
            #expect(
                Swift.max(abs(hueError.x), abs(hueError.y), abs(hueError.z)) <= 1e-3,
                "\(context) axis gained \(added)"
            )
            #expect(glowing.z > glowing.x && glowing.z > glowing.y, "\(context) axis \(glowing)")

            let topGain = MercuryDisplayResponse.luminance(
                Self.double(environment.radiance(top)) - Self.double(stock.radiance(top))
            )
            #expect(abs(topGain) < 2e-3, "\(context) top gained \(topGain)")

            for roughness in MercuryMetrics.environmentRoughness {
                let gained = MercuryDisplayResponse.luminance(
                    Self.meanRadiance(environment, roughness: roughness)
                        - Self.meanRadiance(stock, roughness: roughness)
                )
                #expect(
                    abs(gained - declaredPower) <= 1e-3,
                    "\(context) roughness \(roughness) gained \(gained)"
                )
            }
            Self.expectPhysical(environment, context)
        }
    }

    /// Every option at once (an intermediate finish, a cool balance and an underglow)
    /// replays byte for byte from the same seed, leaves the shipped room, and stays a
    /// physical light field.
    @Test(arguments: MercuryWorld.allCases)
    func litRoomsReplayAndStayPhysical(world: MercuryWorld) {
        let lighting = MercuryRoomLighting(
            finish: 0.15,
            whiteBalance: Self.coolBalance,
            underglow: Self.blueUnderglow
        )
        for shipped in Self.shippedRooms where shipped.world == world {
            let context = "\(world.rawValue) seed \(shipped.seed)"
            let first = MercuryEnvironment(world: world, seed: shipped.seed, lighting: lighting)
            let second = MercuryEnvironment(world: world, seed: shipped.seed, lighting: lighting)
            for environment in [first, second] {
                environment.advance(steps: 600, frozen: false)
            }
            #expect(first.lighting == lighting)
            let replayed = Self.sample(first)
            #expect(replayed == Self.sample(second), "\(context)")
            #expect(replayed != Self.sample(shipped.room), "\(context)")
            Self.expectPhysical(first, context)
        }
    }

    /// No other test bakes this seed, so the first room baked from it below is cold.
    private static let sharedLevelSeed: UInt64 = 0x4C45_5645_4C53

    /// Rooms of one seed share raw levels, and each runs its own lighting passes over its
    /// copy. A room baked cold under every option at once is the same room bit for bit when
    /// baked again after rooms that reuse its levels under a warm balance, an underglow, a
    /// rough finish and stock lighting: a pass that wrote into a shared level, a level kept
    /// after its passes rather than before, or a level copied into the wrong table moves
    /// these samples. The 0.06 finish keeps all three levels distinct, so the lattice reads
    /// each one.
    @Test(arguments: MercuryWorld.allCases)
    func sharedLevelsRebakeTheColdRoom(world: MercuryWorld) {
        let seed = Self.sharedLevelSeed
        let first = MercuryRoomLighting(
            finish: 0.06,
            whiteBalance: Self.coolBalance,
            underglow: Self.blueUnderglow
        )
        var warm = MercuryRoomLighting.stock
        warm.whiteBalance = Self.warmBalance
        var glowing = MercuryRoomLighting.stock
        glowing.underglow = Self.blueUnderglow
        var rough = MercuryRoomLighting.stock
        rough.finish = 0.25

        let cold = Self.sample(MercuryEnvironment(world: world, seed: seed, lighting: first))
        for lighting in [warm, glowing, rough, MercuryRoomLighting.stock] {
            _ = MercuryEnvironment(world: world, seed: seed, lighting: lighting)
        }
        let rebaked = Self.sample(MercuryEnvironment(world: world, seed: seed, lighting: first))

        #expect(rebaked == cold, "\(world.rawValue) seed \(seed)")
    }

    /// Spectral Weather keeps each level's stock blur and adds a rougher finish's extra
    /// variance at the Room of Ten rate, so under the roughest finish all three levels share
    /// one nominal roughness but not one table, and the smooth level production reads is
    /// blurred past the stock roughest level. Rooms share a level only where its bake
    /// prefilters alike, so the smooth level never arrives as another room's roughest one.
    @Test func roughWeatherKeepsItsOwnSmoothLevel() {
        var rough = MercuryRoomLighting.stock
        rough.finish = 0.25
        let room = MercuryEnvironment(world: .spectralWeather, seed: Self.roomSeed, lighting: rough)
        let smooth = Self.sphereDirections.map { room.radiance($0, roughness: 0) }
        let roughest = Self.sphereDirections.map { room.radiance($0, roughness: 1) }
        #expect(smooth != roughest)
    }

    // MARK: - Helpers

    /// Fibonacci lattices: uniform on the sphere by construction, so a mean over one is
    /// an unweighted average and no pole is over-sampled. A latitude-longitude grid is
    /// what a first attempt at this used, and it measured sampling error rather than
    /// power — it piles a third of its points inside ten degrees of each pole.
    private static func lattice(_ count: Int) -> [SIMD3<Float>] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { index in
            let height = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let radius = Swift.max(0, 1 - height * height).squareRoot()
            let angle = golden * Double(index)
            return SIMD3<Float>(
                Float(radius * cos(angle)),
                Float(radius * sin(angle)),
                Float(height)
            )
        }
    }

    /// Enough to tell two rooms apart, or to see an option leak into a whole level.
    private static let sphereDirections: [SIMD3<Float>] = lattice(2048)

    /// Two degrees apart, finer than the 3.75-degree table, so the sharpest level's peaks
    /// are resolved rather than aliased.
    private static let denseDirections: [SIMD3<Float>] = lattice(40_000)

    private static func sample(_ environment: MercuryEnvironment) -> [SIMD3<Float>] {
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(
            sphereDirections.count * MercuryMetrics.environmentRoughness.count
        )
        for roughness in MercuryMetrics.environmentRoughness {
            for direction in sphereDirections {
                values.append(environment.radiance(direction, roughness: roughness))
            }
        }
        return values
    }

    /// The normalization's own measure: the 4,096-point lattice the environment pins its
    /// mean on, so a normalized room's mean luminance there is 1 to rounding.
    private static let integrationDirections: [SIMD3<Float>] = lattice(4_096)

    /// Mean linear-RGB radiance over the normalization lattice. The default roughness
    /// reads level zero under every finish: the level production samples.
    private static func meanRadiance(
        _ environment: MercuryEnvironment,
        roughness: Float = MercuryMetrics.environmentRoughness[0]
    ) -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        for direction in integrationDirections {
            total += double(environment.radiance(direction, roughness: roughness))
        }
        return total / Double(integrationDirections.count)
    }

    /// Brightest luminance on the production level at two-degree spacing.
    private static func peakLuminance(_ environment: MercuryEnvironment) -> Double {
        var peak = 0.0
        for direction in denseDirections {
            let value = double(environment.radiance(direction))
            peak = Swift.max(peak, MercuryDisplayResponse.luminance(value))
        }
        return peak
    }

    /// Finite and non-negative wherever a caller can sample: the smooth and rough ends of
    /// this lighting's layout and a blend between its rougher levels. Every lighting pass
    /// applies one formula to every texel, so a pass that breaks either property breaks it
    /// far wider than the spacing of the 4,096-direction normalization lattice read here.
    private static func expectPhysical(_ environment: MercuryEnvironment, _ context: String) {
        let levels = environment.lighting.levelRoughness
        var finite = true
        var minimum = Float.greatestFiniteMagnitude
        for roughness in [levels[0], (levels[1] + levels[2]) / 2, levels[2]] {
            for direction in integrationDirections {
                let value = environment.radiance(direction, roughness: roughness)
                finite = finite && value.x.isFinite && value.y.isFinite && value.z.isFinite
                minimum = Swift.min(minimum, value.min())
            }
        }
        #expect(finite, "\(context) radiance is not finite")
        #expect(minimum >= 0, "\(context) minimum radiance \(minimum)")
    }

    private static func double(_ value: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(value.x), Double(value.y), Double(value.z))
    }

}
