/// The island's body kit and motion law: what a user may change about the mercury body,
/// as values `MercurySimulation` resolves into its law once.
///
/// Two halves with different contracts:
///
/// - The **body kit** — `size`, `build`, `endTaper`, `crownAspect` — is a drawing
///   transform. The simulation keeps integrating the stock law on the unscaled pose
///   ladder and keeps proving containment against the stock envelope; only the drawn
///   geometry is scaled, retapered and recrowned. Every edge is drawn at the stock edge
///   times `size · build · G′(a) / G(a)`, and on the island the length at `size` times the
///   stock length; a collar keeps the stock length, the housing outline its stations are
///   laid along. Containment, horizontal reach and pose distinctness then follow from ratios
///   against the stock body (`size · build ≤ 1`, and a drawn envelope pointwise inside the
///   gauged one) rather than from new measurements.
/// - The **motion** — the other seven — multiplies the gel's own constants: Tempo every rate
///   of every surface mode's ``MercuryGel/modal(waveNumber:depth:tempo:viscosity:)``, Viscosity
///   its damping, Shimmer the autonomous kick variance, Reactivity and Slither the voice gains
///   and the contact line's kicks, Morph the body shape's ``MercuryBodyShape/Laws`` and Drama
///   the outcome gestures' kicks. The volume law, the flow through the notch that paces
///   emergence, the swallow and the hand-off's drain, is never scaled.
///
/// `stock` is the shipped body bit for bit: every multiplier is exactly 1, every absolute
/// value is the shipped constant, and each enters its expression as one multiplication.
///
/// Each range is where the law's proofs and the pose ladder's distinctness still hold, so
/// the simulation only ever runs `clamped()`.
struct MercuryTune: Equatable, Sendable {
    /// Drawn length and half-height of every pose, ×. A collar draws only the half-height.
    var size = 1.0
    /// Drawn half-height of every pose, ×, on top of `size`.
    var build = 1.0
    /// The drawn envelope's value at both ends: `G′(a) = 1 - (1 - endTaper) * (2a - 1)^2`.
    var endTaper = MercuryMetrics.gEnd
    /// The half-elliptic crown's vertical aspect. Only the rasterizer reads it.
    var crownAspect = MercuryMetrics.crownAspect
    /// Every rate of every surface mode, ×: the stiffnesses by its square, the damping and
    /// the arm's relaxation by it.
    var tempo = 1.0
    /// Every surface mode's damping `c`, both its parts, ×.
    var viscosity = 1.0
    /// The autonomous kick rms of both families, ×. Reduce Motion still removes it.
    var shimmer = 1.0
    /// The voice drive and snake gains together, ×, so their calibrated ratio — and with
    /// it the two edges' independence — survives.
    var reactivity = 1.0
    /// The contact-line family, ×: its voice gain and its autonomous kicks.
    var slither = 1.0
    /// The body shape's time scale, ×: the aspect and sway gels and the skew and neck
    /// modulators run this many times as slowly. Not the volume.
    var morph = 1.0
    /// The lurch's and the collapse's kicks, ×; not the copy-only bead's gathering.
    var drama = 1.0

    static let stock = MercuryTune()

    /// Not above 1: containment is proven on the stock body, and the drawn one lies inside it
    /// only while `size · build ≤ 1`. Not below 0.85: the island's listening lens stays 70 pt
    /// longer than its warming bead, `82 × size` on the ladder against the 60 that keeps the
    /// two different in kind.
    static let sizeRange: ClosedRange<Double> = 0.85...1.0
    /// Not above 1, for the same proof. Not below 0.80: warming stays a compact bead,
    /// `58 / (17 × build) ≤ 4.5` on the island, and on a collar, which keeps its lengths,
    /// `58 / (24 × size × build) ≤ 4.5` at every size.
    static let buildRange: ClosedRange<Double> = 0.80...1.0
    /// Never above the gauged `gEnd`, so `G′ ≤ G` and the drawn envelope stays pointwise
    /// inside the proven one, and `G′ ≥ endTaper > 0` keeps both caps round.
    static let endTaperRange: ClosedRange<Double> = 0.30...MercuryMetrics.gEnd
    /// At most 1, a semicircular section: the crown rises no higher than the body is
    /// half-thick, so it stays under the layout's ceiling, where `MercuryOptics.viewDirection`'s
    /// binomial error bound holds (2.0e-8 on the widest collar canvas). Toward zero the flat
    /// plateau of the rejected crown returns.
    static let crownAspectRange: ClosedRange<Double> = 0.60...1.00
    /// An exact time scale: every eigenvalue of every mode times `tempo`, its damping ratio
    /// unchanged (0.13–0.23 over both ladders), on a propagator exact at any stiffness. The
    /// shimmer's kick scale is the exact stationary variance, so mode `m` moves the edge
    /// `restRMS · shimmer · m^-1.5` rms whatever the tempo: at 1.5 only the warming bead's
    /// seventh and eighth modes pass the 60 Hz Nyquist limit of 120 Hz presentation, at 60
    /// and 69 Hz and under 0.07 pt rms at full shimmer, and no mode the range lifts past 15 Hz
    /// moves the edge more than 0.44 pt rms. At 0.70 the island's crests are still driven
    /// below their glassy resonance, at no more than 0.81 of their glassy frequency. The
    /// following compensation restores every mode's stock following gain across the range,
    /// from 0.27 to 4.8 times the voice force at its corners on the collar's long bodies and
    /// from 0.58 to 1.24 on the island's.
    static let tempoRange: ClosedRange<Double> = 0.70...1.50
    /// Damping alone, so every mode stays strictly dissipative and the propagator has no
    /// critical-damping case to avoid. Over both ladders the damping ratios run 0.073–0.137
    /// at 0.5, where the least damped crest still falls to 5 % within seven periods, and
    /// 0.24–0.46 at 2, where every mode is still underdamped and the stiffest dies within one.
    static let viscosityRange: ClosedRange<Double> = 0.50...2.00
    /// At 2 the fundamental shimmers at 1.24 pt rms, a quarter of the calibrated 5 pt crest,
    /// and the containment gauge retracts it like any other amplitude. At 0 no kick is drawn,
    /// and the seed's rest asymmetry, which shimmer does not scale, keeps the still body off
    /// the capsule.
    static let shimmerRange: ClosedRange<Double> = 0.0...2.0
    /// The containment gauge bounds the loudest voice at 1.5 as it does at 1, and at 0.5 the
    /// speaking crest still stands at half the calibrated prominence.
    static let reactivityRange: ClosedRange<Double> = 0.50...1.50
    /// At 0.75 the speaking body's and the quiet listening lip's edges still average a mirror
    /// correlation under the 0.6 of a body reading as a mirrored pill, and lower slither
    /// mirrors them further. At 2.5 the contact line outweighs the thickness wave and the
    /// body snakes, its two edges moving together.
    static let slitherRange: ClosedRange<Double> = 0.75...2.50
    /// At 1.6 the skew and neck that sign the lurch and the collapse reach 90 % of their pose
    /// in 0.53 s and 99.9 % within the outcome's 1.2 s hold, while its proportions and sway
    /// ring through it, within 12 % and 15 % of their step at its end. At 0.6 the aspect
    /// overshoots 0.12 s after a step and is within 2 % in 0.83 s. The volume, which paces the
    /// swallow and the hand-off's 48-substep drain, is never scaled.
    static let morphRange: ClosedRange<Double> = 0.60...1.60
    /// At 3 the lurch throws the sway at 180 pt/s and the collapse stretches the aspect at
    /// 4.5 s⁻¹, kicks the sway's and the aspect's Moreau walls stop whatever their size, and
    /// kicks the contact-line and varicose fundamentals at 3.3 and 3.0 s⁻¹, amplitudes the
    /// containment gauge retracts like any other. At 0.5 each gesture keeps half its blow.
    static let dramaRange: ClosedRange<Double> = 0.50...3.00

    /// Every value inside its range; values already inside are returned unchanged. A
    /// non-finite value takes its stock value rather than a bound, because NaN has no
    /// nearer end.
    func clamped() -> MercuryTune {
        let stock = Self.stock
        return MercuryTune(
            size: Self.clamp(size, Self.sizeRange, stock.size),
            build: Self.clamp(build, Self.buildRange, stock.build),
            endTaper: Self.clamp(endTaper, Self.endTaperRange, stock.endTaper),
            crownAspect: Self.clamp(crownAspect, Self.crownAspectRange, stock.crownAspect),
            tempo: Self.clamp(tempo, Self.tempoRange, stock.tempo),
            viscosity: Self.clamp(viscosity, Self.viscosityRange, stock.viscosity),
            shimmer: Self.clamp(shimmer, Self.shimmerRange, stock.shimmer),
            reactivity: Self.clamp(reactivity, Self.reactivityRange, stock.reactivity),
            slither: Self.clamp(slither, Self.slitherRange, stock.slither),
            morph: Self.clamp(morph, Self.morphRange, stock.morph),
            drama: Self.clamp(drama, Self.dramaRange, stock.drama)
        )
    }

    /// `value` inside `range`, or `fallback` when `value` is not finite.
    private static func clamp(
        _ value: Double,
        _ range: ClosedRange<Double>,
        _ fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}
