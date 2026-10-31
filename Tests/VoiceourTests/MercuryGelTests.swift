import Foundation
import Testing

@testable import Voiceour

/// The gel law, held to what the body depends on: the propagator is the exact exponential, it is the
/// liquid's own oscillator when the arm is off, its kick statistics are exact, the material it
/// describes rings like a jelly and remembers like a gum, Tempo plays it faster and Viscosity only
/// damps it, and its following gain is what a carried equilibrium does to it.
struct MercuryGelTests {
    private static let step = MercuryMetrics.substep

    /// Mode 1 of a 160 × 11.5 pt fixture body, the collar's speaking depth at the island's speaking
    /// length: `Ω_g ≈ 13` rad/s.
    private static let fundamental = MercuryGel.modal(waveNumber: .pi / 160, depth: 11.5)

    /// Every mode of a 160 × 11.5 pt and a 130 × 8 pt fixture body, the corners of the modal range,
    /// and the two gels of the body shape.
    private static let modes: [MercuryZener.Parameters] = {
        var modes: [MercuryZener.Parameters] = []
        for mode in 1...MercuryMetrics.modeCount {
            modes.append(MercuryGel.modal(waveNumber: Double(mode) * .pi / 160, depth: 11.5))
            modes.append(MercuryGel.modal(waveNumber: Double(mode) * .pi / 130, depth: 8))
        }
        for waveNumber in [Double.pi / 400, 8 * Double.pi / 20] {
            for depth in [0.25, 17] {
                modes.append(MercuryGel.modal(waveNumber: waveNumber, depth: depth))
            }
        }
        modes.append(MercuryBodyShape.aspectGel)
        modes.append(MercuryBodyShape.swayGel)
        return modes
    }()

    @Test func theZeroStepIsTheIdentity() {
        for parameters in Self.modes {
            let zener = MercuryZener(parameters: parameters, step: 0)
            #expect(zener.row0 == SIMD3(1, 0, 0))
            #expect(zener.row1 == SIMD3(0, 1, 0))
            #expect(zener.row2 == SIMD3(0, 0, 1))
        }
    }

    /// The exponential is a semigroup, `Φ(2h) = Φ(h)²`. Compared in velocity units, where every entry
    /// is of order one, so the absolute bound is a relative one.
    @Test func doublingTheStepSquaresThePropagator() {
        for parameters in Self.modes {
            let single = Self.dimensionless(MercuryZener(parameters: parameters, step: Self.step))
            let doubled = Self.dimensionless(MercuryZener(parameters: parameters, step: 2 * Self.step))
            let squared = Self.product(single, single)
            #expect(Self.largestGap(doubled, squared) <= 1e-12, "\(parameters)")
        }
    }

    /// With the arm off, `σ` is driven by nothing and the `(q, v)` block must be the liquid's own
    /// damped oscillator. The oracle is that oscillator's closed-form transition over one step, written
    /// out below from `ζ ω = c / 2` and `ω_d = ω √(1 − ζ²)`: `e^(−ζωh)` times
    /// `cos ω_d h ± (ζω / ω_d) sin ω_d h` on the diagonal, and `sin(ω_d h) / ω_d` and
    /// `−ω² sin(ω_d h) / ω_d` off it.
    @Test func withTheArmOffTheBlockIsTheDampedOscillator() throws {
        for parameters in Self.modes {
            var released = parameters
            released.armStiffness = 0
            let zener = MercuryZener(parameters: released, step: Self.step)

            let omega = released.rubberyStiffness.squareRoot()
            let damping = released.damping / (2 * omega)
            try #require(damping < 1)
            let step = Self.step
            let damped = omega * (1 - damping * damping).squareRoot()
            let decay = exp(-damping * omega * step)
            let cosine = cos(damped * step)
            let sine = sin(damped * step)
            let decayed = damping * omega
            let ratio = sine / damped
            // The transition applied to the unit offset and the unit velocity: the block's two columns.
            let offsetFromOffset = decay * (cosine + ratio * decayed)
            let offsetFromRate = decay * ratio
            let rateFromOffset = -decay * ratio * omega * omega
            let rateFromRate = decay * (cosine - ratio * decayed)

            // Each entry in its natural unit: `q` against `1 / ω`, `v` against one.
            #expect(abs(zener.row0.x - offsetFromOffset) <= 1e-12, "\(released)")
            #expect(abs(zener.row0.y - offsetFromRate) * omega <= 1e-12, "\(released)")
            #expect(abs(zener.row1.x - rateFromOffset) / omega <= 1e-12, "\(released)")
            #expect(abs(zener.row1.y - rateFromRate) <= 1e-12, "\(released)")
            // Decoupled exactly, not approximately: nothing drives the arm, and it only relaxes.
            #expect(zener.row2.x == 0)
            #expect(zener.row2.y == 0)
            #expect(abs(zener.row2.z - exp(-released.relaxationRate * step)) <= 1e-12)
        }
    }

    @Test func theStationaryCovarianceSolvesTheLyapunovEquation() {
        for parameters in Self.modes {
            let zener = MercuryZener(parameters: parameters, step: Self.step)
            let covariance = zener.stationaryCovariance()
            let transition = Self.rows(zener)
            let transpose = (0..<3).map { row in (0..<3).map { column in transition[column][row] } }
            let propagated = Self.product(Self.product(transition, covariance), transpose)
            var kick = [[Double]](repeating: [0, 0, 0], count: 3)
            kick[1][1] = 1
            let residual = (0..<3).map { row in
                (0..<3).map { column in
                    covariance[row][column] - propagated[row][column] - kick[row][column]
                }
            }
            let size = Self.largestMagnitude(covariance)

            #expect(Self.largestMagnitude(residual) <= 1e-12 * size, "\(parameters)")
            #expect(covariance[0][0] > 0)
            #expect(zener.unitKickOffsetVariance() == covariance[0][0])
        }
    }

    /// The solve against an oracle that shares none of its algebra: the stationary covariance of
    /// `x ← Φ x + e w` is `Σ Φⁿ e eᵀ Φⁿᵀ`, summed until the fundamental's slowest mode has decayed
    /// below the last digit.
    @Test func theKickVarianceIsTheSumOfItsImpulseResponse() {
        let zener = MercuryZener(parameters: Self.fundamental, step: Self.step)
        var response = SIMD3<Double>(0, 1, 0)
        var series = [[Double]](repeating: [0, 0, 0], count: 3)
        for _ in 0..<6_000 {
            for row in 0..<3 {
                for column in 0..<3 {
                    series[row][column] += response[row] * response[column]
                }
            }
            response = SIMD3(
                (zener.row0 * response).sum(),
                (zener.row1 * response).sum(),
                (zener.row2 * response).sum()
            )
        }
        let covariance = zener.stationaryCovariance()

        #expect(Self.largestGap(covariance, series) <= 1e-10 * Self.largestMagnitude(covariance))
    }

    /// Jelly: struck at `Ω_g ≈ 13` rad/s, the body swings through equilibrium again and again before
    /// it falls quiet, rather than oozing back once.
    @Test func anImpulseRingsLikeAJelly() {
        #expect(abs(Self.fundamental.glassyFrequency - 13) < 0.5)
        let zener = MercuryZener(parameters: Self.fundamental, step: Self.step)
        var state = MercuryZener.State(offset: SIMD2(), velocity: SIMD2(1, 0), stress: SIMD2())
        var offsets = [0.0]
        for _ in 0..<1_200 {
            state = zener.advance(state)
            offsets.append(state.offset.x)
        }
        let peak = offsets.map { abs($0) }.max() ?? 0
        let lastLoud = offsets.lastIndex { abs($0) >= 0.05 * peak } ?? 0
        var crossings = 0
        for index in 1..<(lastLoud + 1) where offsets[index - 1] * offsets[index] < 0 {
            crossings += 1
        }

        #expect(lastLoud < offsets.count - 1)
        #expect(crossings >= 3)
    }

    /// Gum: a body held out for two seconds has let its arm relax, so on release it creeps home with
    /// a small swing; held for 50 ms it still carries the glassy load and springs well past.
    @Test func aHeldBodyRemembersHowLongItWasHeld() {
        let brief = Self.swingPastEquilibrium(afterHolding: 0.05)
        let long = Self.swingPastEquilibrium(afterHolding: 2)

        #expect(long < brief)
        #expect(long < 0.5 * brief)
    }

    @Test func modalParametersStayPositiveAndFinite() {
        let lowest = log(Double.pi / 400)
        let highest = log(8 * Double.pi / 20)
        for index in 0...24 {
            let waveNumber = exp(lowest + Double(index) / 24 * (highest - lowest))
            for depth in [0.25, 0.5, 1, 2, 4, 8, 11.5, 17] {
                let parameters = MercuryGel.modal(waveNumber: waveNumber, depth: depth)
                for value in [
                    parameters.rubberyStiffness,
                    parameters.armStiffness,
                    parameters.damping,
                    parameters.relaxationRate,
                    parameters.glassyFrequency,
                ] {
                    #expect(value > 0 && value.isFinite, "k \(waveNumber), H \(depth)")
                }
            }
        }
    }

    @Test func aZeroStateStaysZero() {
        for parameters in Self.modes {
            let zener = MercuryZener(parameters: parameters, step: Self.step)
            #expect(zener.advance(.zero) == .zero)
        }
    }

    /// The propagator is exact, so the step size is not a parameter of the motion: 600 substeps and
    /// six 100-substep propagators land on the same state.
    @Test func batchingTheStepsChangesNothing() {
        let single = MercuryZener(parameters: Self.fundamental, step: Self.step)
        let batch = MercuryZener(parameters: Self.fundamental, step: 100 * Self.step)
        let start = MercuryZener.State(offset: SIMD2(1, -0.5), velocity: SIMD2(0.3, 2), stress: SIMD2(4, -1))
        var stepped = start
        for _ in 0..<600 {
            stepped = single.advance(stepped)
        }
        var batched = start
        for _ in 0..<6 {
            batched = batch.advance(batched)
        }
        let glassy = Self.fundamental.glassyFrequency

        #expect(Self.largestLane(stepped.offset - batched.offset) * glassy <= 1e-12)
        #expect(Self.largestLane(stepped.velocity - batched.velocity) <= 1e-12)
        #expect(Self.largestLane(stepped.stress - batched.stress) / glassy <= 1e-12)
    }

    /// Tempo runs every mode faster and changes nothing else about it: a mode at Tempo `t` over one
    /// substep is the stock mode over `t` substeps, in the coordinates a clock running `t` times as
    /// fast reads, velocity times `t` and stress times `t²`. Viscosity changes the damping alone,
    /// both its parts. Across the modal range, from `π/400` to `8π/20` pt⁻¹ and 0.25 to 17 pt deep.
    @Test func tempoRunsEveryModeFasterAndViscosityOnlyDampsIt() {
        for mode in 1...MercuryMetrics.modeCount {
            for (length, depth) in [(160.0, 11.5), (58.0, 8.5), (400.0, 17.0), (20.0, 0.25)] {
                let waveNumber = Double(mode) * .pi / length
                let stock = MercuryGel.modal(waveNumber: waveNumber, depth: depth)
                for tempo in [MercuryTune.tempoRange.lowerBound, MercuryTune.tempoRange.upperBound] {
                    let faster = MercuryGel.modal(waveNumber: waveNumber, depth: depth, tempo: tempo)
                    let tuned = Self.rows(MercuryZener(parameters: faster, step: Self.step))
                    let played = Self.rows(MercuryZener(parameters: stock, step: tempo * Self.step))
                    // `Φ_t(h) = S⁻¹ Φ(t h) S` with `S = diag(1, 1/t, 1/t²)`, compared in velocity units.
                    let clock = [1, 1 / tempo, 1 / (tempo * tempo)]
                    let glassy = faster.glassyFrequency
                    let units = [glassy, 1, 1 / glassy]
                    var gap = 0.0
                    for row in 0..<3 {
                        for column in 0..<3 {
                            let expected = played[row][column] * clock[column] / clock[row]
                            gap = max(gap, abs(tuned[row][column] - expected) * units[row] / units[column])
                        }
                    }
                    #expect(gap <= 1e-12, "k \(waveNumber), H \(depth), tempo \(tempo)")
                }
                for viscosity in [MercuryTune.viscosityRange.lowerBound, MercuryTune.viscosityRange.upperBound] {
                    let thicker = MercuryGel.modal(waveNumber: waveNumber, depth: depth, viscosity: viscosity)
                    #expect(thicker.rubberyStiffness == stock.rubberyStiffness)
                    #expect(thicker.armStiffness == stock.armStiffness)
                    #expect(thicker.relaxationRate == stock.relaxationRate)
                    #expect(abs(thicker.damping / (viscosity * stock.damping) - 1) <= 1e-15)
                }
            }
        }
    }

    /// `followingGain(at:)` is what a mode does when a force carries its equilibrium round a circle:
    /// once the start has died away, the mode runs a circle that many times the equilibrium's
    /// radius. Simulated for 20 s in 0.2 ms steps that hold each step's equilibrium at the step's
    /// middle, on the speaking fundamental and on a slow, runny and a fast, syrupy one, below, near
    /// and above their glassy frequencies. A held force is followed exactly.
    @Test func followingGainIsTheSteadySwingOfACarriedEquilibrium() {
        let fine = 2e-4
        let modes = [
            Self.fundamental,
            MercuryGel.modal(waveNumber: .pi / 160, depth: 11.5, tempo: 0.7, viscosity: 0.5),
            MercuryGel.modal(waveNumber: .pi / 160, depth: 11.5, tempo: 1.5, viscosity: 2),
        ]
        for parameters in modes {
            #expect(abs(parameters.followingGain(at: 0) - 1) <= 1e-15)
            let zener = MercuryZener(parameters: parameters, step: fine)
            for frequency in [3.0, 9.0, 25.0] {
                var position = SIMD2<Double>()
                var velocity = SIMD2<Double>()
                var stress = SIMD2<Double>()
                for index in 0..<100_000 {
                    let phase = frequency * (Double(index) + 0.5) * fine
                    let equilibrium = SIMD2(cos(phase), sin(phase))
                    let next = zener.advance(
                        MercuryZener.State(offset: position - equilibrium, velocity: velocity, stress: stress)
                    )
                    position = next.offset + equilibrium
                    velocity = next.velocity
                    stress = next.stress
                }
                let radius = (position * position).sum().squareRoot()
                let gain = parameters.followingGain(at: frequency)
                #expect(
                    abs(radius / gain - 1) <= 1e-4, "\(parameters) at \(frequency) rad/s: \(radius) against \(gain)")
            }
        }
    }

    // MARK: - Helpers

    /// A grab is glassy: the arm takes `Ω₁² q₀` at once. Held still (`v ≡ 0`) the law reduces to
    /// `σ̇ = −σ/τ`, so the hold is exact in closed form; the release is the propagator. Returns the
    /// deepest swing past equilibrium after release, which for a decaying response is the first.
    private static func swingPastEquilibrium(afterHolding hold: Double) -> Double {
        let parameters = fundamental
        let zener = MercuryZener(parameters: parameters, step: step)
        let held = parameters.armStiffness * exp(-hold * parameters.relaxationRate)
        var state = MercuryZener.State(offset: SIMD2(1, 0), velocity: SIMD2(), stress: SIMD2(held, 0))
        var lowest = 0.0
        for _ in 0..<240 {
            state = zener.advance(state)
            lowest = min(lowest, state.offset.x)
        }
        return -lowest
    }

    private static func rows(_ zener: MercuryZener) -> [[Double]] {
        [zener.row0, zener.row1, zener.row2].map { [$0.x, $0.y, $0.z] }
    }

    /// `Φ` in units where every coordinate is a velocity — `q` times `Ω_g`, `σ` over `Ω_g` — so every
    /// entry is of order one.
    private static func dimensionless(_ zener: MercuryZener) -> [[Double]] {
        let glassy = zener.parameters.glassyFrequency
        let unit = [1 / glassy, 1, glassy]
        let transition = rows(zener)
        return (0..<3).map { row in (0..<3).map { column in transition[row][column] * unit[column] / unit[row] } }
    }

    private static func product(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        (0..<3).map { row in
            (0..<3).map { column in
                (0..<3).reduce(0.0) { sum, inner in sum + lhs[row][inner] * rhs[inner][column] }
            }
        }
    }

    private static func largestMagnitude(_ matrix: [[Double]]) -> Double {
        matrix.joined().map { abs($0) }.max() ?? 0
    }

    private static func largestGap(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
        zip(lhs.joined(), rhs.joined()).map { abs($0 - $1) }.max() ?? 0
    }

    private static func largestLane(_ value: SIMD2<Double>) -> Double {
        max(abs(value.x), abs(value.y))
    }
}
