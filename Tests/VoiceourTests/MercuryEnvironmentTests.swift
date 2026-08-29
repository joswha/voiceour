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
    private static let seeds: [UInt64] = [1, 7, 0x5155_4943_4B53_4C56]

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
        let environment = MercuryEnvironment(world: .roomOfTen, seed: 17)
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
    @Test(arguments: MercuryWorld.allCases)
    func radianceIsPositiveAndRoughnessConservesPower(world: MercuryWorld) {
        for seed in Self.seeds {
            let environment = MercuryEnvironment(world: world, seed: seed)
            environment.advance(steps: 120, frozen: false)
            var means: [Double] = []
            for roughness in MercuryMetrics.environmentRoughness {
                var total = 0.0
                for direction in Self.denseDirections {
                    let value = environment.radiance(direction, roughness: roughness)
                    #expect(value.min() > 0)
                    total += MercuryDisplayResponse.luminance(
                        SIMD3(
                            Double(value.x), Double(value.y), Double(value.z)
                        )
                    )
                }
                means.append(total / Double(Self.denseDirections.count))
            }
            let lowest = means.min() ?? 0
            let highest = means.max() ?? 0
            #expect(highest - lowest <= 0.06 * highest, "\(world.rawValue) seed \(seed) means \(means)")
        }
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

    /// Enough to say "these two rooms are not the same room".
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

}
