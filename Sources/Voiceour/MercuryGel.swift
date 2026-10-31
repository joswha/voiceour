import Foundation

/// The gel law: every surface mode of the body is a standard linear solid, so one material wobbles
/// like a jelly and creeps like a gum.
///
/// A purely elastic mode — the capillary–gravity oscillator the body was before — rings at one
/// frequency and forgets how it was deformed. The standard linear solid (Zener) adds the one internal
/// variable a gel has: a Maxwell arm, a spring `Ω₁²` in series with a dashpot of relaxation time `τ`,
/// in parallel with the rubbery network `Ω∞²`. Per unit modal mass, with `q` the offset from
/// equilibrium and `σ` the arm's stress in acceleration units:
///
///     q̇ = v,    v̇ = −Ω∞² q − c v − σ,    σ̇ = Ω₁² v − σ / τ
///
/// Driven at angular frequency `ω`, the arm adds the complex stiffness `Ω₁² iωτ / (1 + iωτ)`:
///
/// - Storage, `Ω∞² + Ω₁² ω²τ² / (1 + ω²τ²)`, runs from the rubbery `Ω∞²` at `ωτ ≪ 1` to the glassy
///   `Ω_g² = Ω∞² + Ω₁²` at `ωτ ≫ 1`. A fast wobble meets the stiffer glassy spring and rings: jelly.
/// - Loss, `Ω₁² ωτ / (1 + ω²τ²)`, peaks at `ωτ = 1` and falls as `1 / (ωτ)` above it. The speaking
///   fundamental sits at `Ω_g τ ≈ 4`, so it rings for several periods, while a deformation held for
///   `τ` or longer drains into the arm and returns as creep rather than as a spring: gum.
///
/// The wave speeds turn one oscillator into a dispersion law. A shear wave of speed `c` on a gel has
/// modal stiffness `(c k)²`, added to the capillary–gravity stiffness the liquid already had. `c∞`
/// and `c₁` are tuned at the body's tempo, not measured. `c∞² + c₁² ≈ 650²` puts mode `m` of the
/// 160 pt speaking body at `Ω_g ≈ 13 m` rad/s, above the `m π / 0.44 s ≈ 7.1 m` rad/s at which the
/// voice spectrum advects. The crests are driven below the glassy resonance: quasi-static and springy,
/// never a ring the voice did not ask for.
enum MercuryGel {
    /// `c∞`, points per second of displayed time — already at the body's tempo, where the
    /// capillary–gravity term is slowed by `MercuryMetrics.tempo` — the rubbery network's shear-wave
    /// speed: the stiffness a mode keeps after its arm has relaxed.
    static let rubberyWaveSpeed: Double = 505
    /// `c₁`, points per second: the Maxwell arm's shear-wave speed, felt in full only by motion faster
    /// than `1 / τ`.
    static let armWaveSpeed: Double = 410
    /// `τ`, seconds: how long the arm holds stress. Several radians of a crest's wobble (`Ω_g τ ≈ 4` for
    /// the speaking fundamental) yet short against a held pose, so wobbles ring and holds creep.
    static let relaxationTime: Double = 0.30
    /// `ζ0`: loss outside the arm, as a damping ratio against the glassy frequency. Small, because the
    /// arm already supplies the frequency-selective part of the loss.
    static let lossRatio: Double = 0.10
    /// `ν`, points² per second: an effective viscosity at the body's tempo. It adds `2νk²` of velocity
    /// damping — the `k²` law of viscous wave damping — so short modes die while long ones ring.
    static let viscosity: Double = 200

    /// Zener parameters of the surface mode with wavenumber `k` (pt⁻¹) on a body of depth `H` (pt),
    /// at the island's Tempo `t` and Viscosity `v` (``MercuryTune``):
    ///
    ///     ω_cg² = (t · tempo)² (g k + (σ/ρ) k³) tanh(k H)
    ///     Ω∞² = ω_cg² + (t c∞ k)²,    Ω₁² = (t c₁ k)²,    Ω_g = √(Ω∞² + Ω₁²)
    ///     c = 2 v ζ0 Ω_g + 2 t v ν k²,    t / τ
    ///
    /// `ω_cg` is the capillary–gravity dispersion of a mercury pool this deep, slowed by the one global
    /// `MercuryMetrics.tempo`. The gel only adds stiffness and memory to it; it never removes the
    /// liquid. Every term is positive for `k > 0`, `H > 0`, `t > 0` and `v > 0`, so every mode is
    /// strictly dissipative.
    ///
    /// Tempo is an exact time scale. Every rate of the law is multiplied by `t` — both stiffnesses by
    /// `t²`, the damping and the arm's relaxation rate by `t` — so the tuned mode is the stock one run
    /// `t` times as fast: every eigenvalue times `t`, the damping ratio and the shape of the dispersion
    /// unchanged. Viscosity multiplies the damping alone, both its parts. Each enters as one
    /// multiplication of a constant, so at `t = v = 1` these are the shipped parameters to the bit.
    static func modal(
        waveNumber: Double,
        depth: Double,
        tempo timeScale: Double = 1,
        viscosity lossScale: Double = 1
    ) -> MercuryZener.Parameters {
        let tempo = MercuryMetrics.tempo * timeScale
        let restoring =
            MercuryMetrics.gravity * waveNumber
            + MercuryMetrics.surfaceTensionOverDensity * waveNumber * waveNumber * waveNumber
        let capillaryGravity = tempo * tempo * restoring * tanh(waveNumber * depth)
        let rubberyRate = rubberyWaveSpeed * timeScale * waveNumber
        let armRate = armWaveSpeed * timeScale * waveNumber
        let rubbery = capillaryGravity + rubberyRate * rubberyRate
        let arm = armRate * armRate
        let glassy = (rubbery + arm).squareRoot()
        let loss = lossRatio * lossScale
        let kinematic = viscosity * timeScale * lossScale
        return MercuryZener.Parameters(
            rubberyStiffness: rubbery,
            armStiffness: arm,
            damping: 2 * loss * glassy + 2 * kinematic * waveNumber * waveNumber,
            relaxationRate: timeScale / relaxationTime
        )
    }
}

/// The exact one-step propagator of a standard linear solid, for two real components at once.
///
/// `Φ = exp(A h)` on `(q, v, σ)`, with
///
///     A = | 0      1      0    |
///         | −Ω∞²   −c     −1   |
///         | 0      Ω₁²    −1/τ |
///
/// is the exact transition of the linear law across a step in which the equilibrium does not move.
/// Nothing here is an integrator: there is no order, no stability limit and no step-size dependence
/// beyond rounding. Between steps the caller moves the equilibrium, and how it moves decides the
/// stress; both cases are exact for a piecewise-constant equilibrium:
///
/// - A force `f` — the voice, or a moving panel's pseudo-force — acts on the mass. It shifts the
///   rubbery equilibrium by `f / Ω∞²` and leaves `σ` untouched: the arm only ever feels the motion
///   the force produces.
/// - A new reference configuration — a pose step `Δ` — moves the point both springs are referenced
///   to. `q` shifts by `−Δ` and `σ` by `−Ω₁² Δ`, because the arm's spring stretches at once and its
///   dashpot cannot. The step meets the glassy stiffness first and the arm then relaxes.
///
/// `Φ` is scaling and squaring with the diagonal [6/6] Padé approximant (Higham 2005). With
/// `s = max(0, ⌈log₂(‖Ã h‖₁ / 0.5)⌉)` the scaled argument lies inside `θ₆ ≈ 0.54`, where the Padé
/// backward error is below the unit roundoff, so `Φ` is `exp(A h)` to Double precision. The
/// denominator is solved by LU with partial pivoting and `Φ` recovered by `s` squarings.
///
/// The one preprocessing step is `Ã = D A D⁻¹`, with `D = diag(2ᵉ, 1, 2⁻ᵉ)` and `2ᵉ ≤ Ω_g < 2ᵉ⁺¹`
/// (`D = I` below 1 rad/s). A power-of-two similarity is exact in floating point and brings every entry
/// to the order of `Ω_g`, so the norm that chooses `s` measures the dynamics rather than the units.
/// Across the modal range (`k` from `π/400` to `8π/20` pt⁻¹, depth 0.25–17 pt) the stiffest mode needs
/// 14 squarings and is good to 2e-12 of `‖Φ‖` unbalanced; balanced, it needs 5, and every mode is
/// within 5e-15 of a 50-digit reference.
struct MercuryZener: Sendable, Equatable {
    struct Parameters: Sendable, Equatable {
        /// `Ω∞² ≥ 0`, s⁻²: the rubbery network, the stiffness left once the arm has relaxed.
        var rubberyStiffness: Double
        /// `Ω₁² ≥ 0`, s⁻²: the Maxwell arm's spring.
        var armStiffness: Double
        /// `c ≥ 0`, s⁻¹: velocity damping outside the arm.
        var damping: Double
        /// `1 / τ > 0`, s⁻¹: how fast the arm's dashpot lets its stress go.
        var relaxationRate: Double

        /// `Ω_g = √(Ω∞² + Ω₁²)`: the frequency of motion too fast for the arm to relax, which meets
        /// both springs.
        var glassyFrequency: Double {
            (rubberyStiffness + armStiffness).squareRoot()
        }

        /// `|H(iω)|`: how fully the mode follows an equilibrium that a force carries round at angular
        /// frequency `ω`, the steady swing of `u` over the swing of `u*`:
        ///
        ///     H(iω) = Ω∞² / (Ω∞² − ω² + i c ω + Ω₁² iωτ / (1 + iωτ))
        ///
        /// A force moves the rubbery equilibrium by `f / Ω∞²`, and the arm answers the motion it
        /// produces with its complex stiffness. So a held force is followed exactly, `|H(0)| = 1`, and
        /// a carried one meets the gel's storage and loss at `ω`. The quadrature part,
        /// `ω (c + Ω₁² τ / (1 + ω²τ²))`, is positive for `ω > 0` in every strictly dissipative mode, so
        /// the gain is finite at every frequency.
        func followingGain(at frequency: Double) -> Double {
            let squared = frequency * frequency
            let relaxed = armStiffness / (relaxationRate * relaxationRate + squared)
            let inPhase = rubberyStiffness - squared + relaxed * squared
            let quadrature = frequency * (damping + relaxed * relaxationRate)
            return rubberyStiffness / (inPhase * inPhase + quadrature * quadrature).squareRoot()
        }
    }

    /// Two real components of one complex mode, advanced together by the same `Φ`.
    struct State: Sendable, Equatable {
        /// `q = u − u*`, against the equilibrium the current step holds.
        var offset: SIMD2<Double>
        var velocity: SIMD2<Double>
        /// The arm's `σ`, in the acceleration units of `v̇`.
        var stress: SIMD2<Double>

        static let zero = State(offset: SIMD2(), velocity: SIMD2(), stress: SIMD2())
    }

    let parameters: Parameters
    let step: Double
    /// `Φ = exp(A · step)`, row by row, on `(q, v, σ)`.
    let row0: SIMD3<Double>
    let row1: SIMD3<Double>
    let row2: SIMD3<Double>

    init(parameters: Parameters, step: Double) {
        self.parameters = parameters
        self.step = step
        let balance = ZenerBalance(parameters)
        let generator = Matrix3(
            row0: SIMD3(0, 1, 0),
            row1: SIMD3(-parameters.rubberyStiffness, -parameters.damping, -1),
            row2: SIMD3(0, parameters.armStiffness, -parameters.relaxationRate)
        )
        let transition = balance.restored(Matrix3.exponential(step * balance.balanced(generator)))
        row0 = transition.row0
        row1 = transition.row1
        row2 = transition.row2
    }

    /// One step. Exact for an equilibrium that is constant across the step.
    func advance(_ state: State) -> State {
        State(
            offset: Self.combine(row0, state),
            velocity: Self.combine(row1, state),
            stress: Self.combine(row2, state)
        )
    }

    /// Stationary `Var(q)` of the discrete process `x ← Φ x + e w`, with `e = (0, 1, 0)` and
    /// `w ~ N(0, 1)`: the variance one unit velocity kick per substep sustains.
    ///
    /// It is `P₀₀` of the unique solution of the discrete Lyapunov equation `P = Φ P Φᵀ + e eᵀ`.
    /// Discrete rather than continuous, because the kick lands once per substep: this is the exact
    /// statistic of the process the simulation runs, and the continuous-time variance is only its
    /// `h → 0` limit. The solution is unique when the mode is strictly dissipative, which every
    /// ``MercuryGel/modal(waveNumber:depth:tempo:viscosity:)`` mode is.
    func unitKickOffsetVariance() -> Double {
        stationaryMatrix().row0.x
    }

    /// The whole `P`, row by row, from the same solve.
    func stationaryCovariance() -> [[Double]] {
        let covariance = stationaryMatrix()
        return [covariance.row0, covariance.row1, covariance.row2].map { [$0.x, $0.y, $0.z] }
    }

    @inline(__always)
    private static func combine(_ row: SIMD3<Double>, _ state: State) -> SIMD2<Double> {
        let offset: SIMD2<Double> = row.x * state.offset
        let velocity: SIMD2<Double> = row.y * state.velocity
        let stress: SIMD2<Double> = row.z * state.stress
        return offset + velocity + stress
    }

    /// Solves `(I − Φ̃ ⊗ Φ̃) vec P̃ = vec(e eᵀ)`, the 9×9 Kronecker form of the Lyapunov equation, by
    /// Gaussian elimination with partial pivoting, in the balanced coordinates where every entry of
    /// `Φ̃` is of order one. `D e = e`, so the kick is the same there, and `P = D⁻¹ P̃ D⁻¹` is exact.
    ///
    /// `vec(Φ P Φᵀ) = (Φ ⊗ Φ) vec P` holds for either vectorisation order, so equation `3i + j` has
    /// coefficient `δᵢₖ δⱼₗ − Φ̃ᵢₖ Φ̃ⱼₗ` on unknown `3k + l`. Lane 9 carries the right-hand side.
    private func stationaryMatrix() -> Matrix3 {
        let balance = ZenerBalance(parameters)
        let transition = balance.balanced(Matrix3(row0: row0, row1: row1, row2: row2))
        var system = InlineArray<9, SIMD16<Double>>(repeating: SIMD16())
        for left in 0..<3 {
            let leftRow = transition.row(left)
            for right in 0..<3 {
                let rightRow = transition.row(right)
                var equation = SIMD16<Double>()
                for column in 0..<3 {
                    for inner in 0..<3 {
                        equation[3 * column + inner] = -leftRow[column] * rightRow[inner]
                    }
                }
                equation[3 * left + right] += 1
                equation[9] = left == 1 && right == 1 ? 1 : 0
                system[3 * left + right] = equation
            }
        }
        solveAugmented(&system)
        let balanced = Matrix3(
            row0: SIMD3(system[0][9], system[1][9], system[2][9]),
            row1: SIMD3(system[3][9], system[4][9], system[5][9]),
            row2: SIMD3(system[6][9], system[7][9], system[8][9])
        )
        return balance.restoredCovariance(balanced)
    }
}

/// `D = diag(d, 1, 1/d)` with `d = 2^⌊log₂ Ω_g⌋`, or 1 below 1 rad/s: the exact similarity that balances
/// a Zener generator.
///
/// Velocity is the unscaled coordinate, so the unit kick `e = (0, 1, 0)` is unchanged by it.
private struct ZenerBalance {
    let scale: Double

    init(_ parameters: MercuryZener.Parameters) {
        let glassy = parameters.glassyFrequency
        scale = glassy >= 1 ? Double(sign: .plus, exponent: glassy.exponent, significand: 1) : 1
    }

    /// `D M D⁻¹`.
    func balanced(_ matrix: Matrix3) -> Matrix3 {
        let squared = scale * scale
        return Matrix3(
            row0: matrix.row0 * SIMD3(1, scale, squared),
            row1: matrix.row1 * SIMD3(1 / scale, 1, scale),
            row2: matrix.row2 * SIMD3(1 / squared, 1 / scale, 1)
        )
    }

    /// `D⁻¹ M D`.
    func restored(_ matrix: Matrix3) -> Matrix3 {
        let squared = scale * scale
        return Matrix3(
            row0: matrix.row0 * SIMD3(1, 1 / scale, 1 / squared),
            row1: matrix.row1 * SIMD3(scale, 1, 1 / scale),
            row2: matrix.row2 * SIMD3(squared, scale, 1)
        )
    }

    /// `D⁻¹ P D⁻¹`. A covariance is a bilinear form, not a map, so both sides scale the same way.
    func restoredCovariance(_ covariance: Matrix3) -> Matrix3 {
        let squared = scale * scale
        return Matrix3(
            row0: covariance.row0 * SIMD3(1 / squared, 1 / scale, 1),
            row1: covariance.row1 * SIMD3(1 / scale, 1, scale),
            row2: covariance.row2 * SIMD3(1, scale, squared)
        )
    }
}

/// Row-major 3×3: exactly the linear algebra one Zener propagator needs.
private struct Matrix3 {
    var row0: SIMD3<Double>
    var row1: SIMD3<Double>
    var row2: SIMD3<Double>

    static let identity = Matrix3(row0: SIMD3(1, 0, 0), row1: SIMD3(0, 1, 0), row2: SIMD3(0, 0, 1))

    func row(_ index: Int) -> SIMD3<Double> {
        switch index {
        case 0: row0
        case 1: row1
        default: row2
        }
    }

    /// `‖M‖₁`, the largest absolute column sum.
    var columnNorm: Double {
        let first = abs(row0.x) + abs(row1.x) + abs(row2.x)
        let second = abs(row0.y) + abs(row1.y) + abs(row2.y)
        let third = abs(row0.z) + abs(row1.z) + abs(row2.z)
        return Swift.max(first, second, third)
    }

    static func + (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        Matrix3(row0: lhs.row0 + rhs.row0, row1: lhs.row1 + rhs.row1, row2: lhs.row2 + rhs.row2)
    }

    static func - (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        Matrix3(row0: lhs.row0 - rhs.row0, row1: lhs.row1 - rhs.row1, row2: lhs.row2 - rhs.row2)
    }

    static func * (scale: Double, matrix: Matrix3) -> Matrix3 {
        Matrix3(row0: scale * matrix.row0, row1: scale * matrix.row1, row2: scale * matrix.row2)
    }

    static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        Matrix3(row0: rhs.weighted(lhs.row0), row1: rhs.weighted(lhs.row1), row2: rhs.weighted(lhs.row2))
    }

    /// `wᵀ M`: one row of a product whose left factor has the row `w`.
    private func weighted(_ weights: SIMD3<Double>) -> SIMD3<Double> {
        let first: SIMD3<Double> = weights.x * row0
        let second: SIMD3<Double> = weights.y * row1
        let third: SIMD3<Double> = weights.z * row2
        return first + second + third
    }

    /// `exp(X)` by scaling and squaring with the diagonal [6/6] Padé approximant.
    ///
    /// `r₆(X) = p(X) / p(−X)` with `p(X) = Σ bⱼ Xʲ` and `bⱼ = (12 − j)! 6! / (12! j! (6 − j)!)`, that
    /// is `1, 1/2, 5/44, 1/66, 1/792, 1/15840, 1/665280`. Splitting `p` into its even part `V` and
    /// odd part `U` gives `r₆ = (V − U)⁻¹ (V + U)` from four products.
    static func exponential(_ generator: Matrix3) -> Matrix3 {
        let squarings = squaringCount(norm: generator.columnNorm)
        let scaled = Double(sign: .plus, exponent: -squarings, significand: 1) * generator
        let square = scaled * scaled
        let fourth = square * square
        let sixth = fourth * square
        let odd = scaled * (0.5 * identity + (1.0 / 66) * square + (1.0 / 15_840) * fourth)
        let even = identity + (5.0 / 44) * square + (1.0 / 792) * fourth + (1.0 / 665_280) * sixth
        var result = quotient(even - odd, even + odd)
        for _ in 0..<squarings {
            result = result * result
        }
        return result
    }

    /// `max(0, ⌈log₂(norm / ½)⌉)` read off the binary exponent, so it is exact: doubling a step adds
    /// exactly one squaring, and `Φ(2h)` is `Φ(h)²` to the bit whenever `Φ(h)` needed one.
    /// A non-finite norm takes none and propagates as NaN instead of trapping.
    private static func squaringCount(norm: Double) -> Int {
        let ratio = 2 * norm
        guard ratio > 1, ratio.isFinite else { return 0 }
        return Int(ratio.exponent) + (ratio.significand > 1 ? 1 : 0)
    }

    /// `X` with `denominator · X = numerator`, all three right-hand sides in one elimination.
    private static func quotient(_ denominator: Matrix3, _ numerator: Matrix3) -> Matrix3 {
        var system: InlineArray<3, SIMD8<Double>> = [
            augmented(denominator.row0, numerator.row0),
            augmented(denominator.row1, numerator.row1),
            augmented(denominator.row2, numerator.row2),
        ]
        solveAugmented(&system)
        return Matrix3(
            row0: SIMD3(system[0][3], system[0][4], system[0][5]),
            row1: SIMD3(system[1][3], system[1][4], system[1][5]),
            row2: SIMD3(system[2][3], system[2][4], system[2][5])
        )
    }

    private static func augmented(_ coefficients: SIMD3<Double>, _ sides: SIMD3<Double>) -> SIMD8<Double> {
        SIMD8(coefficients.x, coefficients.y, coefficients.z, sides.x, sides.y, sides.z, 0, 0)
    }
}

/// Solves an augmented linear system in place by Gaussian elimination with partial pivoting.
///
/// Lanes `0..<count` of each row are its coefficients and every later lane is a right-hand side, so
/// one elimination solves for all of them at once; on return those lanes hold the solution, row by
/// row. Pivoting picks the largest remaining entry of each column, which bounds every multiplier by
/// one. Fixed-size rows on the stack keep it free of allocation.
private func solveAugmented<let count: Int, Row: SIMD>(_ rows: inout InlineArray<count, Row>)
where Row.Scalar == Double {
    for column in 0..<count {
        var pivot = column
        for row in (column + 1)..<count where abs(rows[row][column]) > abs(rows[pivot][column]) {
            pivot = row
        }
        rows.swapAt(column, pivot)
        let lead = rows[column]
        for row in (column + 1)..<count {
            rows[row] -= (rows[row][column] / lead[column]) * lead
        }
    }
    for column in (0..<count).reversed() {
        rows[column] /= rows[column][column]
        let lead = rows[column]
        for row in 0..<column {
            rows[row] -= rows[row][column] * lead
        }
    }
}
