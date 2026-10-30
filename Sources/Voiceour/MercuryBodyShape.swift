import Foundation

/// The body's low-order shape — how much mercury there is, how it is proportioned, where it sits on
/// its spine, and the two envelope modulators gestures are made of — advanced one substep at a time.
///
/// The simulation's modes carry the crests; this carries the body they ride on. Every coordinate is
/// a plain value advanced by an exact propagator, so a body that took N substeps is the same body
/// however they were batched.
///
/// The shape is parameterised by volume `V = L·H` (pt², proportional to the area the body draws) and
/// log-aspect `α = ln(L / H)`:
///
///     L = √(V e^α),    H = √(V e^−α)
///
/// so `L·H = V` by construction. Squash and stretch, the jelly's signature, is motion in `α` alone: it
/// moves area between length and thickness without creating or destroying any. Incompressibility is a
/// choice of coordinates, not a constraint the integrator has to enforce and could drift from.
///
/// Each coordinate has its own law:
///
/// - Volume is mass flowing through the notch, not a shape, so it is critically damped at
///   `ω_V = 10` rad/s: the fastest second-order response that cannot overshoot from rest. An overshoot
///   would be mercury leaving the housing and flowing back. A first-order law would start the flow
///   with a jump in rate; this one starts it from zero, so the body emerges instead of appearing.
///   90 % of a step takes 0.39 s.
/// - Aspect and sway are ``MercuryZener`` gels. A pose step meets the glassy stiffness and rings —
///   the aspect overshoots by 58 % and is within 2 % in 1.4 s — and a held deformation creeps.
/// - Skew and neck modulate the mean envelope and are critically damped at 12 rad/s: a lopsided lurch
///   and a pinched waist are poses, not wobbles.
///
/// Reduce Motion keeps every destination and reaches each once, with nothing bouncing. The sway is
/// critically damped at its rubbery frequency with the arm's stress zeroed. The extent is not left to
/// volume and aspect: a reader sees `L` and `H`, and a volume and an aspect that each settle
/// monotonically, at their different rates, can still compose an `L = √(V e^α)` that turns back. A
/// processing body collapsing into the error pose overshot its length by 4 pt that way. So Reduce
/// Motion moves `L` and `H` themselves, each critically damped at `ω_V` toward the pose, and reads `V`,
/// `α` and their rates off them with the aspect's arm unloaded, so the gel laws carry on with the same
/// motion when Reduce Motion ends. The area alone may turn back: where one extent shrinks while the
/// other grows, `L·H` swells on the way by up to 7 % of the larger end's area on the ladder. The
/// panel's acceleration still leans the sway but no longer squashes the extent.
///
/// Critical damping is monotone from rest, not from every motion, and Reduce Motion can be turned on
/// while the gel is still swinging. Taken over whole, the gel's rates carried the body past its pose
/// in 3,906 of 6,776 island runs and 6,835 of 10,890 collar runs, by up to 26 and 57 pt, over every
/// ordered pair of ladder poses with Reduce Motion turned on at each substep from 0 to 120. So Reduce
/// Motion takes over only the motion that heads for the pose: `L̇`, `Ḣ` and the sway's rate are each
/// projected into the set from which their law neither turns back nor crosses its target, a set the
/// law never leaves while the target holds still. Wherever Reduce Motion finds the body, it goes
/// straight to its pose.
///
/// A pose is a new reference configuration, and both springs of a gel are referenced to it: moving
/// the target by `Δ` shifts the offset by `−Δ` and loads the arm by `−Ω₁² Δ` at once, because the
/// arm's spring stretches and its dashpot cannot. Frame forcing is a pseudo-force on the mass instead.
/// It shifts only the rubbery equilibrium, by `f / Ω∞²`, which is exact for a piecewise-constant
/// force, and it never touches the stress.
///
/// Every target is first projected into the bounds below, by `reset` as by `step`, so no spring is
/// ever anchored past a wall and no body is placed past one. A pose anchored beyond a wall would wind
/// the arm up against it while the body waited there, then fling the body back by the whole anchor
/// displacement when the pose returned: a 30 pt sway target held against a 12 pt wall sends the body
/// into the opposite wall. A body reset past a wall would be drawn there once and snapped back by the
/// first substep. Each bound is then Moreau's inelastic wall for whatever momentum still reaches it:
/// the coordinate is projected onto the wall and the outward velocity is removed, so the body slides
/// along the wall instead of being re-clamped every substep, which would read as a stutter. A gel also
/// gives up the outward part of its arm's push `−σ` — the load a target that moved toward the wall
/// mid-swing can leave pressing into it — so the body is never held against a wall by its own stored
/// stress. The bounds are:
///
/// - `0 ≤ V ≤ Lmax·Hmax`.
/// - `ln V − 2 ln Hmax ≤ α ≤ 2 ln Lmax − ln V` when `V > 0`, which is exactly `L ≤ Lmax` and
///   `H ≤ Hmax`. Reduce Motion's extent meets them as they are, `0 ≤ L ≤ Lmax` and `0 ≤ H ≤ Hmax`, and
///   a body that reaches the floor along either is empty.
/// - `|sway| ≤ min(maxSway, (Lmax − L)/2)`: the sway's own wall, and the ends of the body's track.
///   Every body rides the same `Lmax` of spine, centred on its rest centre, and a body `L` long reaches
///   `|sway| + L/2` from the middle, so no sway carries an end past where the longest body's end lies.
///   A speaking island body, 160 of the track's 168 pt, has 4 pt to sway either way; the 185×32 pt
///   collar's 356 pt spine leaves every speaking body the whole 12. A pose's sway is held to the
///   pose's length, the body's to the length it has.
/// - `skew ∈ skewRange`, `neck ∈ neckRange`.
///
/// A zero target volume is an outflow through the notch into a reservoir `R²` below empty. Aimed at
/// empty itself, a critically damped volume only approaches it: the island's 160 × 9.5 pt speaking
/// body still holds 26 pt² at 0.6 s and needs 0.97 s to fall below 1 pt². An orifice drains in finite
/// time, so the outflow aims past empty and the floor stops it exactly at `V = 0`: from rest at `V`,
/// on the first substep at which `(1 + ω_V t) e^(−ω_V t) ≤ R² / (V + R²)`. The speaking body empties
/// on the 40th substep, 0.333 s; the largest island body, 168 × 13.24 pt, on the 45th, 0.375 s; and
/// the largest collar body, the 220×38 pt housing's whole 401 pt spine at 13.24 pt, on the 57th,
/// 0.475 s. With no target shape, an idle aspect holds where it is. Reduce Motion drains its extent
/// into the same reservoir at the held aspect: `L` aims at `−R e^(α/2)` and `H` at `−R e^(−α/2)`,
/// both below empty and in proportion, so the body keeps its proportions and both reach zero on the
/// same substep, the first at which `(1 + ω_V t) e^(−ω_V t) ≤ R / (√V + R)`: the speaking body's
/// 30th, 0.250 s, and the largest collar body's 37th, 0.308 s.
///
/// `R` is the containment ceiling's 17 pt, not the height limit a body is handed. The simulation holds
/// bodies below the ceiling to leave the crests headroom, and a reservoir that shrank with that limit
/// would slow every swallow: at 13.24 pt the speaking body would empty on the 47th substep, 0.392 s,
/// and on the 33rd, 0.275 s, under Reduce Motion. How deep a body may be is the crests' business; how
/// fast it swallows is not.
///
/// An empty body has no shape to remember. While `V = 0` its aspect, sway, skew and neck sit on their
/// targets with no stress, so the body grows out of the notch already in its pose. Velocities are
/// kept: an arrival kick handed to an empty body becomes the first motion of the mercury that emerges.
/// Reduce Motion, which spares the body its kicks, keeps an empty body at rest instead, so the motion a
/// swallow ends with is not carried into the next emergence.
struct MercuryBodyShape: Sendable, Equatable {
    /// Where the body is asked to be. `reset` and `step` project every field into the bounds first.
    struct Target: Sendable, Equatable {
        /// Points along the spine. With `halfHeight`, sets the volume `L·H` and the aspect `ln(L/H)`.
        var length: Double
        /// Points: the mean envelope's value at the body's centre.
        var halfHeight: Double
        /// Points along the spine, from where a body with no sway is centred.
        var sway: Double
        /// Lopsidedness of the envelope.
        var skew: Double
        /// Depth of the waist pinch.
        var neck: Double
    }

    struct Limits: Sendable, Equatable {
        /// Points: the longest body, and the track every body rides, centred on the spine's rest centre.
        var maxLength: Double
        var maxHalfHeight: Double
        /// Points either way from the rest centre, where the track's ends leave that much room.
        var maxSway: Double

        /// `Lmax·Hmax`, the volume's ceiling.
        fileprivate var maxVolume: Double { max(0, maxLength) * max(0, maxHalfHeight) }
    }

    /// The acceleration of the panel the body is drawn in, in pt/s².
    struct Forcing: Sendable, Equatable {
        /// Along the spine.
        var tangentialAcceleration = 0.0
        /// Along the spine's normal.
        var normalAcceleration = 0.0

        static let none = Forcing()
    }

    /// Velocity kicks, applied once.
    struct Impulse: Sendable, Equatable {
        /// s⁻¹, on `α`.
        var aspectRate = 0.0
        /// pt/s.
        var swayRate = 0.0
        /// pt²/s.
        var volumeRate = 0.0
    }

    /// `ω_V`, rad/s: the volume's, and under Reduce Motion the length's and the thickness's.
    static let volumeFrequency: Double = 10
    /// `Ω∞ = 13.8`, `Ω₁ = 8.8` rad/s (`Ω_g = 16.4`), loss ratio 0.14 against `Ω_g`, `τ = 0.32` s.
    static let aspectGel = gel(rubbery: 13.8, arm: 8.8, lossRatio: 0.14, relaxationTime: 0.32)
    /// `Ω∞ = 10`, `Ω₁ = 6.3` rad/s (`Ω_g = 11.8`), loss ratio 0.16 against `Ω_g`, `τ = 0.32` s.
    static let swayGel = gel(rubbery: 10, arm: 6.3, lossRatio: 0.16, relaxationTime: 0.32)
    /// Skew and neck, rad/s.
    static let modulatorFrequency: Double = 12
    /// At most 80/20 between the two ends; the insert-failed lurch's 0.4 is 70/30.
    static let skewRange: ClosedRange<Double> = -0.6...0.6
    /// The waist keeps at least 15 % of its thickness, so the deepest pinch reads as two drips joined
    /// by a thread and never as two bodies.
    static let neckRange: ClosedRange<Double> = 0...0.85
    /// pt/s². A panel that jumps — a re-frame, a display change — has no finite acceleration; the clamp
    /// keeps its pseudo-force a slosh rather than a teleport.
    static let maxFrameAcceleration: Double = 40_000
    /// Sway pseudo-force per unit tangential acceleration: the body lags 3 % of the panel's
    /// acceleration, the inertia of a liquid carried in a moving cup.
    static let swayCoupling: Double = -0.03
    /// Aspect pseudo-force (s⁻²) per unit normal acceleration (pt/s²): a positive normal acceleration
    /// shortens and thickens the body at constant volume, a negative one stretches it.
    static let aspectCoupling: Double = -1.4e-3

    /// Points: `R`, the outflow reservoir's scale.
    private static let reservoir = Double(MercuryMetrics.maxHalfHeight)
    private static let volumeLaw = CriticalDamping(frequency: volumeFrequency)
    private static let aspectLaw = MercuryZener(parameters: aspectGel, step: MercuryMetrics.substep)
    private static let swayLaw = GelLaw(swayGel)
    private static let modulatorLaw = CriticalDamping(frequency: modulatorFrequency)

    private var volumeCoordinate = DampedCoordinate()
    private var aspect = GelCoordinate()
    private var lateral = GelCoordinate()
    private var skewCoordinate = DampedCoordinate()
    private var neckCoordinate = DampedCoordinate()
    private(set) var length = 0.0
    private(set) var halfHeight = 0.0
    /// `(L̇, Ḣ)` as Reduce Motion's law left them, while it carries the extent, so its closed form runs
    /// on its own state rather than on rates re-derived every substep through `V̇` and `α̇`, a round trip
    /// that is the identity only to rounding. Nil while the gel laws carry the extent, and once a kick
    /// lands: `V̇` and `α̇` are then the rates of record, and the next Reduce Motion substep takes over
    /// from them. Nil is also how that substep knows to take over the sway's rate.
    private var extentRate: SIMD2<Double>?

    /// Idle and empty.
    init() {}

    var sway: Double { lateral.value }
    var skew: Double { skewCoordinate.value }
    var neck: Double { neckCoordinate.value }
    var volume: Double { volumeCoordinate.value }

    /// Exactly at rest on `target` as `step` projects it into `limits`: no transient and no stored
    /// stress. Inside the bounds `length` and `halfHeight` are the pose's own values, so a pinned frame
    /// draws the pose to the bit. Past a wall the body starts at the wall, where `step` holds it: a
    /// speaking island body leaning its full 6 pt starts at the track's end, 4 pt out.
    mutating func reset(to target: Target, limits: Limits) {
        let pose = projected(target, limits: limits)
        volumeCoordinate = DampedCoordinate(value: pose.volume, rate: 0)
        aspect = GelCoordinate(value: pose.aspect, rate: 0, stress: 0, anchor: pose.aspect)
        lateral = GelCoordinate(value: pose.sway, rate: 0, stress: 0, anchor: pose.sway)
        skewCoordinate = DampedCoordinate(value: pose.skew, rate: 0)
        neckCoordinate = DampedCoordinate(value: pose.neck, rate: 0)
        length = pose.length
        halfHeight = pose.halfHeight
        extentRate = nil
    }

    /// One `MercuryMetrics.substep` toward `target`.
    mutating func step(toward target: Target, limits: Limits, forcing: Forcing, reduceMotion: Bool) {
        let pose = projected(target, limits: limits)
        let aspectForce = Self.aspectCoupling * Self.frameAcceleration(forcing.normalAcceleration)
        let swayForce = Self.swayCoupling * Self.frameAcceleration(forcing.tangentialAcceleration)

        if volumeCoordinate.value == 0 {
            aspect.seat(on: pose.aspect, force: aspectForce, law: Self.aspectLaw)
            lateral.seat(on: pose.sway, force: swayForce, law: Self.swayLaw.gel)
            skewCoordinate.value = pose.skew
            neckCoordinate.value = pose.neck
            if reduceMotion {
                // Under Reduce Motion an empty body is at rest: its sway, skew and neck, as well as its extent.
                lateral.rate = 0
                skewCoordinate.rate = 0
                neckCoordinate.rate = 0
            }
        }

        if reduceMotion {
            let goal: (length: Double, halfHeight: Double)
            if pose.volume > 0 {
                goal = (pose.length, pose.halfHeight)
            } else {
                let stretch = exp(0.5 * pose.aspect)
                goal = (-Self.reservoir * stretch, -Self.reservoir / stretch)
            }
            // With no rates of its own yet, Reduce Motion takes over from the gel or a kick.
            let takingOver = extentRate == nil
            settleExtent(toward: goal, aspectTarget: pose.aspect, limits: limits)
            lateral.settle(toward: pose.sway, force: swayForce, law: Self.swayLaw, takingOver: takingOver)
        } else {
            let fill = pose.volume > 0 ? pose.volume : -Self.reservoir * Self.reservoir
            volumeCoordinate.step(toward: fill, law: Self.volumeLaw)
            volumeCoordinate.clamp(lower: 0, upper: limits.maxVolume)
            aspect.step(toward: pose.aspect, force: aspectForce, law: Self.aspectLaw)
            let filled = volumeCoordinate.value
            if filled > 0 {
                let walls = Self.aspectWalls(volume: filled, limits: limits)
                aspect.clamp(lower: walls.lower, upper: walls.upper)
            }
            (length, halfHeight) = Self.extent(filled, aspect.value, limits: limits)
            extentRate = nil
            lateral.step(toward: pose.sway, force: swayForce, law: Self.swayLaw.gel)
        }
        let reach = Self.reach(length: length, limits: limits)
        lateral.clamp(lower: -reach, upper: reach)

        skewCoordinate.step(toward: pose.skew, law: Self.modulatorLaw)
        skewCoordinate.clamp(lower: Self.skewRange.lowerBound, upper: Self.skewRange.upperBound)
        neckCoordinate.step(toward: pose.neck, law: Self.modulatorLaw)
        neckCoordinate.clamp(lower: Self.neckRange.lowerBound, upper: Self.neckRange.upperBound)
    }

    /// Velocity kicks, applied once: a gesture's, or an arrival's. They land on `V̇` and `α̇`, so a
    /// Reduce Motion extent takes its rates afresh from them on its next substep, as far as they head
    /// for the pose.
    mutating func apply(_ impulse: Impulse) {
        aspect.rate += impulse.aspectRate
        lateral.rate += impulse.swayRate
        volumeCoordinate.rate += impulse.volumeRate
        extentRate = nil
    }

    /// A target inside the bounds: where `reset` places the body, and what `step` anchors every spring
    /// on.
    private struct Projection {
        /// `L·H`, up to `Lmax·Hmax`; zero for an empty pose.
        var volume: Double
        /// `ln(L/H)`, between the walls the volume sets. An empty pose holds the body's own aspect.
        var aspect: Double
        /// A pose's own extent inside the bounds, to the bit, and its projection's past them; zero for an
        /// empty pose.
        var length: Double
        var halfHeight: Double
        /// Inside the reach the pose's own length leaves.
        var sway: Double
        var skew: Double
        var neck: Double
    }

    /// `target` projected into `limits`, every field onto its bound.
    private func projected(_ target: Target, limits: Limits) -> Projection {
        let volume = min(max(0, target.length) * max(0, target.halfHeight), limits.maxVolume)
        var ratio = aspect.value
        var pose = (length: 0.0, halfHeight: 0.0)
        if volume > 0 {
            let walls = Self.aspectWalls(volume: volume, limits: limits)
            ratio = min(max(log(target.length / target.halfHeight), walls.lower), walls.upper)
            // A pose inside the bounds is its own extent, to the bit; one past them is its projection's.
            let inside = target.length <= limits.maxLength && target.halfHeight <= limits.maxHalfHeight
            pose = inside ? (target.length, target.halfHeight) : Self.extent(volume, ratio, limits: limits)
        }
        let reach = Self.reach(length: pose.length, limits: limits)
        return Projection(
            volume: volume,
            aspect: ratio,
            length: pose.length,
            halfHeight: pose.halfHeight,
            sway: min(max(target.sway, -reach), reach),
            skew: Self.clamp(target.skew, to: Self.skewRange),
            neck: Self.clamp(target.neck, to: Self.neckRange)
        )
    }

    /// Reduce Motion's extent: `L` and `H` each critically damped at `ω_V` toward `goal`, inside
    /// `[0, Lmax]` and `[0, Hmax]`. They continue from the rates this law left them; after a gel
    /// substep or a kick, from `takeoverRate(toward:)`. `V`, `α` and their rates are then read back off
    /// them, with the aspect's arm unloaded and anchored on `aspectTarget`, so a gel substep that
    /// follows starts where this one ended, moving as it moved and with no pose left to load. A body
    /// that reaches the floor along either extent is empty, and at rest.
    private mutating func settleExtent(
        toward goal: (length: Double, halfHeight: Double),
        aspectTarget: Double,
        limits: Limits
    ) {
        let rate = extentRate ?? takeoverRate(toward: goal)
        var long = DampedCoordinate(value: length, rate: rate.x)
        var deep = DampedCoordinate(value: halfHeight, rate: rate.y)
        long.step(toward: goal.length, law: Self.volumeLaw)
        long.clamp(lower: 0, upper: limits.maxLength)
        deep.step(toward: goal.halfHeight, law: Self.volumeLaw)
        deep.clamp(lower: 0, upper: limits.maxHalfHeight)
        guard long.value > 0, deep.value > 0 else {
            length = 0
            halfHeight = 0
            extentRate = SIMD2()
            volumeCoordinate = DampedCoordinate()
            aspect = GelCoordinate(value: aspect.value, rate: 0, stress: 0, anchor: aspectTarget)
            return
        }
        length = long.value
        halfHeight = deep.value
        extentRate = SIMD2(long.rate, deep.rate)
        volumeCoordinate = DampedCoordinate(
            value: length * halfHeight,
            rate: long.rate * halfHeight + length * deep.rate
        )
        aspect = GelCoordinate(
            value: log(length / halfHeight),
            rate: long.rate / length - deep.rate / halfHeight,
            stress: 0,
            anchor: aspectTarget
        )
    }

    /// The extent's rates as Reduce Motion takes over: the motion the volume and the aspect carry,
    /// `L̇ = V̇ / 2H + L α̇ / 2` and `Ḣ = V̇ / 2L − H α̇ / 2`, each projected into the monotone set of its
    /// law toward `goal`, so that neither extent turns back or overshoots. Zero for an empty body.
    private func takeoverRate(toward goal: (length: Double, halfHeight: Double)) -> SIMD2<Double> {
        guard length > 0, halfHeight > 0 else { return SIMD2() }
        let flow = 0.5 * volumeCoordinate.rate
        let stretch = 0.5 * aspect.rate
        return SIMD2(
            Self.volumeLaw.monotoneRate(flow / halfHeight + length * stretch, offset: length - goal.length),
            Self.volumeLaw.monotoneRate(flow / length - halfHeight * stretch, offset: halfHeight - goal.halfHeight)
        )
    }

    /// `L = √V e^(α/2)` and `H = √V e^(−α/2)`: one square root and one exponential, finite for every
    /// `α` the aspect wall admits. The wall is exact; `min` only removes the last ulp that `exp` and
    /// `sqrt` can add on top of it.
    private static func extent(
        _ volume: Double,
        _ aspect: Double,
        limits: Limits
    ) -> (length: Double, halfHeight: Double) {
        guard volume > 0 else { return (0, 0) }
        let root = volume.squareRoot()
        let stretch = exp(0.5 * aspect)
        return (min(root * stretch, limits.maxLength), min(root / stretch, limits.maxHalfHeight))
    }

    /// How far a body `length` long may sway: to its wall, or until an end meets the track's.
    private static func reach(length: Double, limits: Limits) -> Double {
        min(max(0, limits.maxSway), max(0, 0.5 * (limits.maxLength - length)))
    }

    /// `ln V − 2 ln Hmax ≤ α ≤ 2 ln Lmax − ln V`: exactly `L ≤ Lmax` and `H ≤ Hmax` at a volume `V > 0`.
    /// A pair rather than a range, because at `V = Lmax·Hmax` the two coincide and rounding may cross them.
    private static func aspectWalls(volume: Double, limits: Limits) -> (lower: Double, upper: Double) {
        let logVolume = log(volume)
        return (logVolume - 2 * log(limits.maxHalfHeight), 2 * log(limits.maxLength) - logVolume)
    }

    private static func gel(
        rubbery: Double,
        arm: Double,
        lossRatio: Double,
        relaxationTime: Double
    ) -> MercuryZener.Parameters {
        let glassy = (rubbery * rubbery + arm * arm).squareRoot()
        return MercuryZener.Parameters(
            rubberyStiffness: rubbery * rubbery,
            armStiffness: arm * arm,
            damping: 2 * lossRatio * glassy,
            relaxationRate: 1 / relaxationTime
        )
    }

    private static func frameAcceleration(_ acceleration: Double) -> Double {
        min(max(acceleration, -maxFrameAcceleration), maxFrameAcceleration)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The exact one-substep transition of `ẍ + 2ω ẋ + ω² x = 0`, critical damping's double root `−ω`:
///
///     x(h) = e^(−ωh) ((1 + ωh) x + h ẋ),    ẋ(h) = e^(−ωh) (−ω² h x + (1 − ωh) ẋ)
///
/// Its response to a moving target is the positive unit-mass kernel `ω² t e^(−ωt)`, so from rest it
/// never leaves the range of the targets it is given: no overshoot and no bounce.
private struct CriticalDamping: Sendable {
    let frequency: Double
    private let offsetRow: SIMD2<Double>
    private let rateRow: SIMD2<Double>

    init(frequency: Double) {
        self.frequency = frequency
        let step = MercuryMetrics.substep
        let decay = exp(-frequency * step)
        offsetRow = decay * SIMD2(1 + frequency * step, step)
        rateRow = decay * SIMD2(-frequency * frequency * step, 1 - frequency * step)
    }

    func advance(offset: Double, rate: Double) -> (offset: Double, rate: Double) {
        (offsetRow.x * offset + offsetRow.y * rate, rateRow.x * offset + rateRow.y * rate)
    }

    /// The rate nearest `rate` from which this law approaches a target `offset` away monotonically:
    /// never moving away from it and never crossing it.
    ///
    /// With `s = ẋ + ωx`, the closed form is `x(t) = e^(−ωt) (x + s t)` and `ẋ(t) = e^(−ωt) (ẋ − ωt s)`.
    /// It crosses the target at `t = −x / s`, which lies ahead exactly when the rate toward the target
    /// exceeds `ω|x|`. At that cap the motion is the pure exponential `x e^(−ωt)`. A rate pointing away
    /// first carries the body further from the target. The monotone set is therefore `ẋ` between 0 and
    /// `−ωx`, which is `ẋ s ≤ 0`, and the projection clamps the rate into it. The law never leaves the
    /// set: `ẋ(t) s(t) = e^(−2ωt) (ẋ s − ωt s²)` stays at or below zero once it starts there. So toward a
    /// fixed target, one projection serves every substep after it.
    func monotoneRate(_ rate: Double, offset: Double) -> Double {
        let cap = -frequency * offset
        return min(max(rate, min(0, cap)), max(0, cap))
    }
}

/// The sway's two propagators: the Zener law, and the critically damped law at its rubbery frequency
/// that Reduce Motion uses instead. The aspect needs only the first: under Reduce Motion it is read
/// off the extent.
private struct GelLaw: Sendable {
    let gel: MercuryZener
    let calm: CriticalDamping

    init(_ parameters: MercuryZener.Parameters) {
        gel = MercuryZener(parameters: parameters, step: MercuryMetrics.substep)
        calm = CriticalDamping(frequency: parameters.rubberyStiffness.squareRoot())
    }
}

/// A critically damped coordinate.
private struct DampedCoordinate: Sendable, Equatable {
    var value = 0.0
    var rate = 0.0

    mutating func step(toward target: Double, law: CriticalDamping) {
        let next = law.advance(offset: value - target, rate: rate)
        value = next.offset + target
        rate = next.rate
    }

    /// Moreau's wall: projected onto `[lower, upper]`, with the outward rate removed.
    mutating func clamp(lower: Double, upper: Double) {
        if value < lower {
            value = lower
            rate = max(rate, 0)
        } else if value > upper {
            value = upper
            rate = min(rate, 0)
        }
    }
}

/// A viscoelastic coordinate: its value and rate, the Maxwell arm's stress, and the reference
/// configuration both springs are referenced to.
private struct GelCoordinate: Sendable, Equatable {
    var value = 0.0
    var rate = 0.0
    var stress = 0.0
    var anchor = 0.0

    /// At rest on the equilibrium `target` and `force` hold, with no stress; the rate is kept.
    mutating func seat(on target: Double, force: Double, law: MercuryZener) {
        value = target + force / law.parameters.rubberyStiffness
        stress = 0
        anchor = target
    }

    /// One substep of the Zener law.
    mutating func step(toward target: Double, force: Double, law: MercuryZener) {
        let equilibrium = reanchor(on: target, force: force, law: law)
        let next = law.advance(
            MercuryZener.State(
                offset: SIMD2(value - equilibrium, 0),
                velocity: SIMD2(rate, 0),
                stress: SIMD2(stress, 0)
            )
        )
        value = next.offset.x + equilibrium
        rate = next.velocity.x
        stress = next.stress.x
    }

    /// One substep of Reduce Motion's law: critically damped at the rubbery frequency toward the same
    /// equilibrium, with the arm's stress zeroed. `takingOver` from the gel or a kick, it first projects
    /// the rate into the law's monotone set, so the motion it inherits can carry the coordinate neither
    /// away from the equilibrium nor past it.
    mutating func settle(toward target: Double, force: Double, law: GelLaw, takingOver: Bool) {
        let equilibrium = reanchor(on: target, force: force, law: law.gel)
        if takingOver {
            rate = law.calm.monotoneRate(rate, offset: value - equilibrium)
        }
        let next = law.calm.advance(offset: value - equilibrium, rate: rate)
        value = next.offset + equilibrium
        rate = next.rate
        stress = 0
    }

    /// Moreau's wall, which also takes the arm's outward push `−σ`: at the lower bound a positive
    /// stress pushes outward, at the upper bound a negative one does.
    mutating func clamp(lower: Double, upper: Double) {
        if value < lower {
            value = lower
            rate = max(rate, 0)
            stress = min(stress, 0)
        } else if value > upper {
            value = upper
            rate = min(rate, 0)
            stress = max(stress, 0)
        }
    }

    /// A new reference configuration loads the arm at once; a force never touches it. Returns the
    /// equilibrium `target` and `force` hold.
    private mutating func reanchor(on target: Double, force: Double, law: MercuryZener) -> Double {
        stress -= law.parameters.armStiffness * (target - anchor)
        anchor = target
        return target + force / law.parameters.rubberyStiffness
    }
}
