import CoreGraphics
import Foundation

/// The two gains the mode law needs, solved once at boot rather than typed in.
///
/// See ``MercuryCalibration``: `drive` is solved by proportional iteration against the drawn crest
/// prominence at the speaking pose under live speech, and `snake` is bisected against the
/// anti-mirror correlation at the listening pose in the quiet room held still, both measured through
/// the shipping geometry path.
struct MercuryGains: Equatable {
    var drive: Double
    var snake: Double
}

/// The kick a body takes as it emerges on the display it was handed to.
///
/// A token rather than a flag: the conductor hands over the same arrival with every frame of an
/// emergence and the body still feels one kick. Tokens are issued with increasing `id`s, so the
/// simulation keeps the highest it has applied and kicks only for a greater one: an older token
/// handed over again after a newer one is not a new arrival. A reset forgets them all.
struct MercuryArrival: Equatable, Sendable {
    var id: Int
    /// Points per second along the spine's left-to-right traversal: away from the side the body
    /// came from.
    var swayRate: Double
    /// s⁻¹ on the aspect `ln(L/H)`. A landing squash is negative.
    var aspectRate: Double
}

/// One mercury body: two mode families, eight modes each, riding a body shape, with every
/// coordinate advanced by an exact propagator at a fixed substep.
///
/// Not an `ObservableObject`. `MercurySurfaceView` advances it from a view-bound display
/// link and writes the returned image directly to a layer; publishing a frame index would
/// route 120 Hz work back through SwiftUI for no new information.
///
/// The law, in points along the spine the body lies on and along the spine's normal —
/// `MercuryField` lays it on the island's straight line or around the collar's housing:
///
/// - Material coordinate `a` in `[0, 1]`, `x = (a - 0.5) * L`.
/// - Mean envelope `G(a) = 1 - (1 - gEnd) * (2a - 1)^2`, shaped by the gestures' modulators:
///   `G_s(a) = G(a) * (1 + skew * (2a - 1)) * (1 - neck * exp(-((a - 0.5) / w)^2))`.
/// - `y_T(a) = +H0 * G_s(a) * exp(theta_T(a))`, `y_B(a) = -H0 * G_s(a) * exp(theta_B(a))`,
///   with `theta_T = sum Re[(V_m + N_m) e^{i m pi a}]` and
///   `theta_B = sum Re[(V_m e^{-i m pi delta} - N_m) e^{i m pi a}]`.
///
/// `V` is the varicose (thickness) family and `N` the contact-line (snake) family. `N`
/// entering the two edges with opposite sign is the whole reason the edges are
/// independent rather than mirrored; `delta` is a group lag, a linear phase in `m`.
///
/// Every mode is a ``MercuryZener`` gel at wavenumber `m pi / L` on a pool `H0` deep: the
/// capillary–gravity liquid with a relaxing network added, so a crest rings like a jelly and a
/// held one creeps like a gum. The voice is a force on it, which moves each mode's equilibrium
/// and never the arm's stress. `L`, `H0`, the sway that places the body on its spine, `skew`
/// and `neck` are ``MercuryBodyShape``: the same gel law, for the body as a whole.
///
/// Because `y_T` and `y_B` are exponentials of a sum linear in the amplitudes, the drawn body
/// is bounded *exactly* rather than clamped: the containment gauge holds every station the
/// field reads inside the drive's ceiling, `maxHalfHeight`, and on a collar every station
/// beside a wall short of that wall's bisector with the screen's top edge, which is a proof,
/// not a hope, and it is the only limiter in the geometry path. The body shape holds `H` to
/// ``maxBodyHalfHeight(ceiling:)``, a crest headroom under that ceiling, so every station keeps
/// room for a crest and the gauge never has to erase the body to honour one.
///
/// A ``MercuryTune`` is resolved once into the law's constants, and ``retune(_:)`` swaps it under
/// a live body. Its motion knobs multiply the gel's own constants, one multiplication each, and
/// every factor is exactly 1 for the shipped body, which therefore runs the shipped law to the
/// bit: Tempo and Viscosity enter every mode's ``MercuryGel/modal(waveNumber:depth:tempo:viscosity:)``,
/// Shimmer the kick variance, Reactivity and Slither the voice gains, Morph the body shape's
/// ``MercuryBodyShape/Laws`` and Drama the gestures' kicks. Its body kit is a drawing transform
/// applied where the geometry is emitted (see ``Geometry``), so the dynamics, the containment
/// proof and calibration all stay on the stock law and the stock envelope.
@MainActor
final class MercurySimulation {
    /// Everything the session tells the body.
    ///
    /// There is deliberately no `isSpeaking`: the pose ladder already resolves it into
    /// a length, a half-height and a drive scale, and a second copy of the same fact
    /// could only ever disagree with the first.
    ///
    /// `Equatable` so the harness can cache its one pinned frame: with a step index
    /// pinned, an unchanged drive is a frame that has already been computed.
    struct Drive: Equatable {
        var pose: MercuryPose
        /// The model's eleven-sample meter buffer, oldest first, each in `[0, 1]`.
        var samples: [Float]
        var reduceMotion: Bool
        /// Toward the window the text will land in, −1…1. The sway target moves
        /// `lean * MercuryMetrics.leanSway` along the spine.
        var lean: Double = 0
        /// The panel's own acceleration: a pseudo-force on the body shape, so a moving panel
        /// sloshes the mercury it carries.
        var forcing: MercuryBodyShape.Forcing = .none
        /// Points: the longest body the layout can draw. The island's 168, or the collar's
        /// whole spine.
        var maxLength: Double = Double(MercuryMetrics.maxLength)
        /// Points: the ceiling every drawn edge stays inside, the layout spine's
        /// `maxHalfHeight`. The island's 17, or the collar's deeper chin ceiling.
        var maxHalfHeight: Double = Double(MercuryMetrics.maxHalfHeight)
        /// The collar's spine, whose walls hold the stations beside them short of the screen's top
        /// edge (`MercurySpine.reach(at:under:)`). Nil on the island, which only has its ceiling.
        var spine: MercurySpine?
        /// The hand-off's arrival kick: applied once, and only for a token newer than every one
        /// applied since the last reset.
        var arrival: MercuryArrival?
    }

    /// What the field reads: points along the spine and along its normal, for the body as it is
    /// drawn.
    ///
    /// The tune's body kit is applied here and nowhere else. The containment gauge proves the stock
    /// body inside its ceiling, and on a collar inside every wall's reach, and the drawn body lies
    /// pointwise inside the stock one: each edge is the stock edge times `size · build · G′(a) / G(a)`,
    /// where `G′` is the mean envelope at the kit's end taper, never above the gauged `gEnd`, and
    /// `size · build ≤ 1`. On the island, whose ceiling is the same at every station, the length is
    /// drawn `size` times as long as well. A collar draws the stock length: its stations lie along the
    /// housing's outline at the arc lengths the gauge proved, and moving them along a curved spine
    /// would carry them to reaches it never measured. The sway is never scaled.
    struct Geometry: Equatable {
        var length: CGFloat
        /// `H0 · size · build`, the depth the shaped mean envelope is drawn at.
        var halfHeight: CGFloat
        /// Points along the spine, from its rest centre to the body's centre: the body
        /// shape's sway.
        var lateralOffset: CGFloat
        /// `columns + 1` samples of the top edge's offset along the spine's normal, never
        /// negative. Untapered: the field applies the spine's taper.
        var top: [Float]
        /// `columns + 1` samples of the bottom edge's offset, never positive.
        var bottom: [Float]
        /// The half-elliptic crown's vertical aspect. It travels with the silhouette, so every
        /// reader of this body, metering included, lifts the same crown.
        var crownAspect: Double = MercuryMetrics.crownAspect
    }

    /// One complex mode: its two real components, advanced together.
    private struct Mode {
        /// `u`, the absolute amplitude: the equilibrium the rest draw and the voice hold it
        /// to, plus the offset the propagator carries.
        var value = SIMD2<Double>()
        var velocity = SIMD2<Double>()
        /// The Maxwell arm's `σ`, in the acceleration units of `v̇`.
        var stress = SIMD2<Double>()

        /// One substep about `equilibrium`: `q = u − u*` goes through the propagator and `u*`
        /// comes back. The stress is the arm's own, so an equilibrium the voice moved — a
        /// force — leaves it as it was.
        mutating func advance(_ propagator: MercuryZener, about equilibrium: SIMD2<Double>) {
            let next = propagator.advance(
                MercuryZener.State(offset: value - equilibrium, velocity: velocity, stress: stress)
            )
            value = next.offset + equilibrium
            velocity = next.velocity
            stress = next.stress
        }

        /// Scaled toward the origin, with the outward parts of the velocity and of the arm's
        /// push `−σ` removed. See ``MercurySimulation/contain(depth:drive:)``.
        mutating func retract(scale: Double) {
            value *= scale
            let size = (value.x * value.x + value.y * value.y).squareRoot()
            guard size > 0 else { return }
            let radial = value / size
            let outward = (velocity * radial).sum()
            if outward > 0 {
                velocity -= outward * radial
            }
            let push = -(stress * radial).sum()
            if push > 0 {
                stress += push * radial
            }
        }
    }

    /// A tune resolved into the law's constants, once per tune rather than once per substep. Each
    /// is a shipped constant times one tune value, which is exactly 1 at stock, so each enters its
    /// expression as one multiplication and the stock body runs the shipped expressions to the bit.
    private struct Law {
        /// Tempo and Viscosity, handed to every mode's gel.
        let tempo: Double
        let viscosity: Double
        /// Whether either moves the modes off their stock gel. Without, every mode's following
        /// compensation is exactly 1 and is never evaluated.
        let compensates: Bool
        /// `restRMS · shimmer`: the autonomous shimmer's rms at the fundamental. Zero draws no kicks.
        let shimmerRMS: Double
        /// The contact-line family's factor on its own kicks.
        let slither: Double
        /// `gains.drive · reactivity`.
        let drive: Double
        /// `gains.snake · reactivity · slither`.
        let snake: Double
        /// The gestures' kicks times Drama. The copy-only bead's squash is not one of them.
        let lurchImpulse: Double
        let collapseImpulse: Double
        let lurchSwayRate: Double
        let collapseAspectRate: Double
        /// The body shape's laws at the tune's Morph.
        let shape: MercuryBodyShape.Laws
        /// Drawn length over the body's own, on the island: `size`.
        let lengthScale: Double
        /// Drawn depth over the body's own: `size · build`.
        let depthScale: Double
        let crownAspect: Double
        /// `G′(a)` at every station, the mean envelope at the kit's end taper; nil at the gauged
        /// `gEnd`, where the drawn envelope is the gauged one.
        let drawnMean: [Double]?
    }

    private let noise: MercuryNoise
    private let gains: MercuryGains
    private var law: Law

    private var varicose: [Mode]
    private var snake: [Mode]
    /// The body's own static rest asymmetry, drawn once per seed. Never zero: zero is
    /// the mirror-symmetric minimiser, which is a capsule.
    private let restVaricose: [SIMD2<Double>]
    private let restSnake: [SIMD2<Double>]

    /// The advected voice spectrum, one complex coefficient per mode.
    private var voice: [SIMD2<Double>]
    private var lastSamples: [Float]

    /// The body the modes ride on: its length, depth, sway, skew and neck.
    private var body: MercuryBodyShape
    private var substepIndex: UInt64 = 0
    private var lastReduceMotion: Bool
    private var lastGesture: MercuryOutcomeGesture?
    /// The greatest arrival `id` applied since the last reset. Tokens only grow, so one at or
    /// below it has kicked already, however frames interleave them.
    private var highestAppliedArrival: Int?
    /// The pose a replay starts from. ``rearmGesture(from:)`` hands it over, and the next advance
    /// that moves the body places the body shape on it.
    private var replaySource: MercuryPose?
    /// Whether the last drive laid the body on a collar, which draws the stock length.
    private var collared = false

    /// `(L, H0)`, floored, that `propagators`, `kickScales` and `compensation` were built for. A
    /// held pose stops moving them, so a pinned frame, calibration and a still body build them once.
    private var modalExtent: SIMD2<Double>?
    private var propagators: [MercuryZener] = []
    /// `σ_w` per mode, built only when kicks are due at this extent: Reduce Motion and a body
    /// without shimmer never pay for the stationary solve.
    private var kickScales: [Double]
    private var kickScalesBuilt = false
    /// Each mode's following compensation at this extent, `|H_stock(iW)| / |H_tuned(iW)|`: exactly
    /// 1 unless the tune moves Tempo or Viscosity.
    private var compensation: [Double]

    /// `G_s` at every station, for the skew and neck it was last built with.
    private var shapedEnvelope: [Double]
    /// `G′_s`, the envelope the kit draws when it retapers the ends, at the same skew and neck. Nil
    /// draws `shapedEnvelope`.
    private var drawnEnvelope: [Double]?
    private var envelopeSkew = 0.0
    private var envelopeNeck = 0.0

    private var top: [Float]
    private var bottom: [Float]

    var geometry: Geometry {
        Geometry(
            length: CGFloat(collared ? body.length : body.length * law.lengthScale),
            halfHeight: CGFloat(depth * law.depthScale),
            lateralOffset: CGFloat(body.sway),
            top: top,
            bottom: bottom,
            crownAspect: law.crownAspect
        )
    }

    /// `tune` defaults to stock, the shipped body to the bit, which calibration, the harness and
    /// the benchmarks measure.
    init(seed: UInt64, gains: MercuryGains, tune: MercuryTune = .stock) {
        noise = MercuryNoise(seed: seed)
        self.gains = gains
        let law = Self.resolve(tune, gains: gains)
        self.law = law
        let count = MercuryMetrics.modeCount
        let restVaricose = Self.restDraw(noise: MercuryNoise(seed: seed), family: 0)
        let restSnake = Self.restDraw(noise: MercuryNoise(seed: seed), family: 1)
        self.restVaricose = restVaricose
        self.restSnake = restSnake
        varicose = restVaricose.map { Mode(value: $0) }
        snake = restSnake.map { Mode(value: $0) }
        voice = Array(repeating: SIMD2<Double>(), count: count)
        lastSamples = Array(repeating: 0, count: 11)
        body = MercuryBodyShape(laws: law.shape)
        lastReduceMotion = false
        lastGesture = nil
        kickScales = Array(repeating: 0, count: count)
        compensation = Array(repeating: 1, count: count)
        shapedEnvelope = Self.meanEnvelope
        drawnEnvelope = law.drawnMean
        top = Array(repeating: 0, count: MercuryMetrics.columns + 1)
        bottom = Array(repeating: 0, count: MercuryMetrics.columns + 1)
        propagators.reserveCapacity(count)
        rebuildGeometry()
    }

    /// Places the body in this drive with its modes at rest — at the drive's equilibrium, with
    /// no velocity and no stress — so no transient is left to settle.
    ///
    /// At rest on the pose, the body draws the pose to the bit: the harness's pinned frame,
    /// calibration, and Reduce Motion, which shows a pose rather than its arrival. `emerging`
    /// starts the body empty instead, and it grows out of the notch or the top edge.
    ///
    /// A reset is itself the transition into this drive, so a gesture the pose already
    /// carries is spent rather than kicked, as is an arrival handed to a body at rest. An
    /// emerging body takes its arrival on the next advance, as the first motion of the
    /// mercury that emerges. Either way, arrivals the body took before the reset are forgotten,
    /// and so is a replay ``rearmGesture(from:)`` handed over: the reset is the placement.
    func reset(to drive: Drive, emerging: Bool = false) {
        substepIndex = 0
        lastReduceMotion = drive.reduceMotion
        lastGesture = drive.pose.gesture
        highestAppliedArrival = emerging ? nil : drive.arrival?.id
        replaySource = nil
        collared = drive.spine != nil
        lastSamples = drive.samples
        voice = Self.spectrum(of: drive.samples)
        if emerging {
            body = MercuryBodyShape(laws: law.shape)
        } else {
            body.reset(to: Self.bodyTarget(for: drive), limits: Self.bodyLimits(for: drive))
        }
        reshapeEnvelope()
        settleToEquilibrium(drive: drive)
        rebuildGeometry()
    }

    /// Swaps the tune under a live body, for a look that changes mid-session.
    ///
    /// The modes, the voice and the body shape's coordinates, rates and arm stresses carry on as
    /// they are, so the body changes character without a jump. Only the laws change — the modes'
    /// propagators, kick scales and following compensation, rebuilt by the next substep, and the
    /// body shape's ``MercuryBodyShape/Laws`` — and the geometry is redrawn with the new kit at
    /// once. Nothing needs containing again: the state is the one the last reset or advance
    /// contained, against the stock envelope that no tune moves, and every kit draws inside it.
    func retune(_ tune: MercuryTune) {
        law = Self.resolve(tune, gains: gains)
        body.laws = law.shape
        modalExtent = nil
        for index in compensation.indices {
            compensation[index] = 1
        }
        redrawEnvelope()
        rebuildGeometry()
    }

    /// Lets the latched outcome gesture land again on the next advance, for a replay. The
    /// impulse is a pose-entry event, so forgetting the latched gesture is all it takes.
    ///
    /// With `source`, the replay also starts from that pose, as the live processing-to-outcome
    /// transition does. The next advance that moves the body first places the body shape at rest
    /// on `source`, exactly where ``reset(to:emerging:)`` would place it in that advance's drive,
    /// its limits included, then kicks it and relaxes it toward that drive's pose. That drive is
    /// meant to carry an outcome pose: a live pose has no gesture, so its replay would be the jump
    /// to `source` alone. The modes keep their state, and that advance's substeps contain them
    /// against the placed body before anything is drawn. Placing the body here instead would need
    /// limits this call does not have, and would draw a body no containment had seen.
    func rearmGesture(from source: MercuryPose? = nil) {
        lastGesture = nil
        replaySource = source
    }

    /// `steps` substeps of this drive. Zero leaves the body exactly as it is: nothing in it
    /// moves between substeps, and a replay waits for an advance that moves it.
    func advance(steps: Int, drive: Drive) {
        guard steps > 0 else { return }
        collared = drive.spine != nil
        if let source = replaySource {
            replaySource = nil
            var from = drive
            from.pose = source
            body.reset(to: Self.bodyTarget(for: from), limits: Self.bodyLimits(for: drive))
            reshapeEnvelope()
        }
        refreshVoice(drive: drive)
        applyGestureImpulse(drive: drive)
        applyArrival(drive: drive)
        if drive.reduceMotion, !lastReduceMotion {
            // Reduce Motion keeps the body's shape and drops its shimmer: the modes go
            // to their own equilibrium and stay there, which is a still asymmetric lens
            // rather than a still capsule.
            settleToEquilibrium(drive: drive)
        }
        lastReduceMotion = drive.reduceMotion

        for _ in 0..<steps {
            step(drive: drive)
        }
        rebuildGeometry()
    }

    // MARK: - One substep

    private func step(drive: Drive) {
        body.step(
            toward: Self.bodyTarget(for: drive),
            limits: Self.bodyLimits(for: drive),
            forcing: drive.forcing,
            reduceMotion: drive.reduceMotion
        )
        reshapeEnvelope()
        advectVoice(step: MercuryMetrics.substep)

        let effectiveLength = Swift.max(body.length, 1)
        let effectiveHalf = Swift.max(depth, 0.25)
        // Reduce Motion removes the autonomous kicks whatever the tune asks for, and a tune
        // without shimmer draws none: the noise is counter-based, so a skipped draw cannot shift
        // a later one.
        let kicked = !drive.reduceMotion && law.shimmerRMS > 0
        prepareModes(length: effectiveLength, depth: effectiveHalf, kicked: kicked)
        let driveScale = Double(drive.pose.driveScale)

        for index in 0..<MercuryMetrics.modeCount {
            let target = equilibrium(index, driveScale: driveScale)
            let propagator = propagators[index]
            varicose[index].advance(propagator, about: target.varicose)
            snake[index].advance(propagator, about: target.snake)

            guard kicked else { continue }
            let deviation = kickScales[index]
            let counter = substepIndex &* UInt64(MercuryMetrics.modeCount) &+ UInt64(index)
            let varicoseKick = noise.gaussianPair(stream: MercuryNoiseStream.varicoseForcing, counter: counter)
            let snakeKick = noise.gaussianPair(stream: MercuryNoiseStream.snakeForcing, counter: counter)
            varicose[index].velocity += deviation * varicoseKick
            // Slither drives the contact line's own life as well as its voice gain; the voice's
            // share alone barely shows.
            snake[index].velocity += (deviation * law.slither) * snakeKick
        }

        contain(depth: effectiveHalf, drive: drive)
        substepIndex &+= 1
    }

    /// The modes' gel at this length and depth: ``MercuryGel/modal(waveNumber:depth:tempo:viscosity:)``
    /// at `m pi / L` and the tune's Tempo and Viscosity, one propagator serving both families. When
    /// kicks are due, also each mode's kick scale `σ_w = sqrt(Var / unitKickOffsetVariance)`, with
    /// `Var = (restRMS · shimmer / H0 * m^-1.5)^2`.
    ///
    /// `Var` keeps the autonomous shimmer at `restRMS · shimmer` points of edge displacement at the
    /// fundamental, falling as `m^-1.5`. The divisor is the exact stationary variance of one unit
    /// kick per substep through this very propagator — the process the simulation runs, not its
    /// continuous-time limit — so the shimmer has precisely that rms however stiff, damped or
    /// creeping the gel makes the mode, at every tempo and viscosity.
    ///
    /// A tune that moves Tempo or Viscosity also gets each mode's following compensation here. The
    /// voice advects mode `m` at `W = m pi / bufferPeriod`, and a mode follows an equilibrium
    /// carried round at `W` with the gain ``MercuryZener/Parameters/followingGain(at:)``, which both
    /// knobs move. Uncompensated, the corners of their ranges would swing an island mode at 0.8 to
    /// 1.7 times its calibrated following, and the collar's long bodies, whose crests a slower
    /// tempo carries past their glassy resonance, at a fifth of it to nearly four times it.
    /// Multiplying the mode's voice force by `|H_stock(iW)| / |H_tuned(iW)|` at the mode's present
    /// extent restores the stock gain, and with it the meaning of the calibrated crest prominence.
    private func prepareModes(length: Double, depth: Double, kicked: Bool) {
        let extent = SIMD2(length, depth)
        if extent != modalExtent {
            modalExtent = extent
            kickScalesBuilt = false
            propagators.removeAll(keepingCapacity: true)
            for index in 0..<MercuryMetrics.modeCount {
                let wave = Double(index + 1) * Double.pi / length
                let parameters = MercuryGel.modal(
                    waveNumber: wave,
                    depth: depth,
                    tempo: law.tempo,
                    viscosity: law.viscosity
                )
                propagators.append(MercuryZener(parameters: parameters, step: MercuryMetrics.substep))
                guard law.compensates else { continue }
                let advection = Double(index + 1) * Double.pi / MercuryMetrics.bufferPeriod
                compensation[index] =
                    MercuryGel.modal(waveNumber: wave, depth: depth).followingGain(at: advection)
                    / parameters.followingGain(at: advection)
            }
        }
        guard kicked, !kickScalesBuilt else { return }
        kickScalesBuilt = true
        for index in 0..<MercuryMetrics.modeCount {
            let scale = law.shimmerRMS / depth * pow(Double(index + 1), -1.5)
            kickScales[index] = (scale * scale / propagators[index].unitKickOffsetVariance()).squareRoot()
        }
    }

    /// Where mode `index` of each family is held in this drive: its rest draw, plus the voice,
    /// at the tune's gains and with the mode's following compensation.
    private func equilibrium(_ index: Int, driveScale: Double) -> (varicose: SIMD2<Double>, snake: SIMD2<Double>) {
        let coefficient = voice[index]
        let following = compensation[index]
        let varicoseForce: SIMD2<Double> = ((driveScale * law.drive) * following) * coefficient
        // Multiplying by `i * m * pi` is the derivative along the material
        // coordinate: the contact line answers the crest's slope, not its height,
        // which is what stops the two edges moving as one.
        let rotated = SIMD2<Double>(-coefficient.y, coefficient.x)
        let snakeWeight: Double = driveScale * law.snake * Double(index + 1) * Double.pi * following
        return (restVaricose[index] + varicoseForce, restSnake[index] + snakeWeight * rotated)
    }

    // MARK: - Containment

    /// Moreau's inelastic rule on the envelope the body is actually drawn against.
    ///
    /// The drawn edge is `y_T[j] = H0 * G_s[j] * exp(theta_T[j])` at each of the stations the
    /// field reads, so `theta_j <= ln(maxHalfHeight / (H0 * G_s[j]))` is an exact statement
    /// about every pixel that can exist — there is no other geometry representation for it
    /// to be approximate about. `theta` is linear in the amplitudes, so scaling them by
    /// `1 / gauge` lands the binding station exactly on the envelope.
    ///
    /// The first version of this bounded `|theta|` by `sum(|V_m| + |N_m|)` instead, which
    /// is closed-form and needs no station loop. It is also the worst case over all phase
    /// alignments, and eight modes at random phase realise about four tenths of it — so it
    /// spent more than half the amplitude range defending against an alignment that does
    /// not occur, and the body could not be driven hard enough to look like a liquid. The
    /// station loop costs 1,552 multiply-adds per substep.
    ///
    /// One scalar retraction on both families cannot change `|N| / |V|`, so containment
    /// provably cannot flatten the two-edge asymmetry into a pill; zeroing the outward
    /// radial velocity makes the state slide along the boundary instead of being
    /// re-clamped every substep, which would read as a stutter. The arm's push `−σ` gives
    /// up its outward part for the same reason: stress a mode stored on its way into the
    /// boundary would otherwise press it straight back out through it.
    private func contain(depth: Double, drive: Drive) {
        let gauge = envelopeGauge(depth: depth, drive: drive)
        guard gauge > 1 else { return }
        let scale = 1 / gauge
        for index in 0..<MercuryMetrics.modeCount {
            varicose[index].retract(scale: scale)
            snake[index].retract(scale: scale)
        }
    }

    /// Worst `theta_j / cap_j` over the drawn stations, on both edges.
    ///
    /// Every station has a budget: the body shape holds `H` a crest headroom of 0.25 under the
    /// ceiling, and the widest skew lifts `G_s` at most 13 % above `G`'s peak of 1, spending
    /// `ln 1.133 = 0.125` of it, so `cap_j ≥ 0.125` everywhere under the ceiling. A collar holds
    /// the stations beside its walls to less, the reach their bisector with the screen's top edge
    /// leaves (``reach(at:drive:)``), which stands above the frame's mean envelope there. A station
    /// without a budget would be a mean envelope already at its reach, where no retraction makes
    /// room: erasing every mode leaves the envelope where it stands. The gauge leaves such a
    /// station to the body shape's limit and honours the rest, rather than answer it with an
    /// unbounded gauge, which is how a body pressed against the ceiling, before the headroom,
    /// lost every mode for a substep and grew them back.
    private func envelopeGauge(depth: Double, drive: Drive) -> Double {
        var worst = 0.0
        for station in 0...MercuryMetrics.columns {
            let envelope = depth * shapedEnvelope[station]
            guard envelope > 1e-9 else { continue }
            let cap = log(reach(at: station, drive: drive) / envelope)
            guard cap > 0 else { continue }
            let exponents = edgeExponents(at: station)
            worst = Swift.max(worst, Swift.max(exponents.upper, exponents.lower) / cap)
        }
        return worst
    }

    /// The largest untapered edge `station` may draw: the drive's ceiling, or what a collar's
    /// spine leaves it at the arc length the field lays the station at, `restCenter + sway +
    /// (j/96 − ½)·L`.
    private func reach(at station: Int, drive: Drive) -> Double {
        guard let spine = drive.spine else { return drive.maxHalfHeight }
        let position = Double(station) / Double(MercuryMetrics.columns) - 0.5
        let arcLength = spine.restCenter + body.sway + position * body.length
        return spine.reach(at: arcLength, under: drive.maxHalfHeight)
    }

    // MARK: - Body shape

    /// The pose as the body shape reads it. A lean adds its sway to the pose's own offset,
    /// and the sway wall holds whatever the two ask for together.
    private static func bodyTarget(for drive: Drive) -> MercuryBodyShape.Target {
        MercuryBodyShape.Target(
            length: Double(drive.pose.length),
            halfHeight: Double(drive.pose.halfHeight),
            sway: Double(drive.pose.lateralOffset) + drive.lean * MercuryMetrics.leanSway,
            skew: Double(drive.pose.skew),
            neck: Double(drive.pose.neck)
        )
    }

    /// The body shape's height limit under `ceiling`: `ceiling · e^−crestHeadroom`, 13.24 pt under
    /// the island's 17. The drawn edges may still reach the ceiling; the room between is the crests'.
    static func maxBodyHalfHeight(ceiling: Double) -> Double {
        ceiling * exp(-MercuryMetrics.crestHeadroom)
    }

    /// The body shape's bounds under this drive's layout. Its outflow drains into a reservoir the
    /// ceiling's size, so a deeper collar swallows in the island's time rather than slower.
    private static func bodyLimits(for drive: Drive) -> MercuryBodyShape.Limits {
        MercuryBodyShape.Limits(
            maxLength: drive.maxLength,
            maxHalfHeight: maxBodyHalfHeight(ceiling: drive.maxHalfHeight),
            maxSway: MercuryMetrics.maxSway,
            reservoir: drive.maxHalfHeight
        )
    }

    /// `H0`, the depth the shaped envelope is drawn at: the body's own `H`.
    ///
    /// It needs no cap of its own. The body shape holds `H` to ``maxBodyHalfHeight(ceiling:)``
    /// and `G_s` peaks at most 1.133, at the widest skew, so `ln(ceiling / (H0 G_s))` is at least
    /// 0.125 at every station. Held to the ceiling itself, a skewed body's peak could pass it,
    /// which no retraction scales back, and the depth used to give way instead.
    private var depth: Double {
        body.halfHeight
    }

    /// `G_s` at every station, and the kit's `G′_s`, rebuilt only when the body's skew or neck has
    /// moved since.
    private func reshapeEnvelope() {
        let skew = body.skew
        let neck = body.neck
        guard skew != envelopeSkew || neck != envelopeNeck else { return }
        envelopeSkew = skew
        envelopeNeck = neck
        for station in 0...MercuryMetrics.columns {
            shapedEnvelope[station] =
                Self.meanEnvelope[station] * (1 + skew * Self.stationPosition[station])
                * (1 - neck * Self.waist[station])
        }
        redrawEnvelope()
    }

    /// The kit's `G′_s`, its retapered mean envelope shaped by the same skew and neck as `G_s`, or
    /// nil when the kit keeps the gauged `gEnd`.
    private func redrawEnvelope() {
        guard let mean = law.drawnMean else {
            drawnEnvelope = nil
            return
        }
        if drawnEnvelope == nil {
            drawnEnvelope = mean
        }
        for station in 0...MercuryMetrics.columns {
            drawnEnvelope?[station] =
                mean[station] * (1 + envelopeSkew * Self.stationPosition[station])
                * (1 - envelopeNeck * Self.waist[station])
        }
    }

    /// A gesture's kicks, once, as its pose arrives, at the tune's Drama. The copy-only bead's
    /// squash is the gathering itself rather than a blow, so no Drama scales it.
    private func applyGestureImpulse(drive: Drive) {
        let gesture = drive.pose.gesture
        defer { lastGesture = gesture }
        guard gesture != lastGesture, let gesture else { return }
        switch gesture {
        case .gathered:
            kickBody(MercuryBodyShape.Impulse(aspectRate: MercuryMetrics.gatheredAspectRate), drive: drive)
        case .lurch:
            snake[0].velocity.x += law.lurchImpulse
            kickBody(MercuryBodyShape.Impulse(swayRate: law.lurchSwayRate), drive: drive)
        case .collapse:
            varicose[0].velocity.x += law.collapseImpulse
            kickBody(MercuryBodyShape.Impulse(aspectRate: law.collapseAspectRate), drive: drive)
        }
    }

    /// An arrival's kick, once per token, and never for a token older than one already applied.
    private func applyArrival(drive: Drive) {
        guard let arrival = drive.arrival else { return }
        if let highest = highestAppliedArrival, arrival.id <= highest { return }
        highestAppliedArrival = arrival.id
        kickBody(
            MercuryBodyShape.Impulse(aspectRate: arrival.aspectRate, swayRate: arrival.swayRate),
            drive: drive
        )
    }

    /// Reduce Motion takes the body to every pose and spares it the bounce: the kick is spent
    /// without being applied, so it cannot land later either.
    private func kickBody(_ impulse: MercuryBodyShape.Impulse, drive: Drive) {
        guard !drive.reduceMotion else { return }
        body.apply(impulse)
    }

    // MARK: - Voice

    /// The meter buffer is a snapshot of the last 440 ms of speech. Its band-limited
    /// spectrum is the crest train the body carries; nothing else in the law travels.
    private static func spectrum(of samples: [Float]) -> [SIMD2<Double>] {
        let count = samples.count
        var result = [SIMD2<Double>](repeating: SIMD2<Double>(), count: MercuryMetrics.modeCount)
        guard count > 0 else { return result }
        for index in 0..<MercuryMetrics.modeCount {
            let mode = Double(index + 1)
            var real = 0.0
            var imaginary = 0.0
            for sample in 0..<count {
                let phase = -mode * Double.pi * (Double(sample) + 0.5) / Double(count)
                let level = Double(samples[sample])
                real += level * cos(phase)
                imaginary += level * sin(phase)
            }
            result[index] = SIMD2(real / Double(count), imaginary / Double(count))
        }
        return result
    }

    private func refreshVoice(drive: Drive) {
        guard drive.samples != lastSamples else { return }
        lastSamples = drive.samples
        voice = Self.spectrum(of: drive.samples)
    }

    /// Rotating the phase by `m * pi * h / bufferPeriod` every substep is exactly a
    /// right-to-left travelling crest train at `L / bufferPeriod`. Over one 40 ms model
    /// tick it accumulates `m * pi / 11`, which is precisely the phase the next
    /// one-sample buffer shift applies — so the train never steps.
    private func advectVoice(step: Double) {
        for index in 0..<MercuryMetrics.modeCount {
            let angle = Double(index + 1) * Double.pi * step / MercuryMetrics.bufferPeriod
            let cosine = cos(angle)
            let sine = sin(angle)
            let value = voice[index]
            voice[index] = SIMD2(
                value.x * cosine - value.y * sine,
                value.x * sine + value.y * cosine
            )
        }
    }

    // MARK: - State helpers

    /// Clamped first: the law's proofs and the pose ladder's distinctness hold only inside the
    /// tune's ranges.
    private static func resolve(_ requested: MercuryTune, gains: MercuryGains) -> Law {
        let tune = requested.clamped()
        return Law(
            tempo: tune.tempo,
            viscosity: tune.viscosity,
            compensates: tune.tempo != 1 || tune.viscosity != 1,
            shimmerRMS: MercuryMetrics.restRMS * tune.shimmer,
            slither: tune.slither,
            drive: gains.drive * tune.reactivity,
            snake: gains.snake * tune.reactivity * tune.slither,
            lurchImpulse: MercuryMetrics.lurchImpulse * tune.drama,
            collapseImpulse: MercuryMetrics.collapseImpulse * tune.drama,
            lurchSwayRate: MercuryMetrics.lurchSwayRate * tune.drama,
            collapseAspectRate: MercuryMetrics.collapseAspectRate * tune.drama,
            shape: MercuryBodyShape.Laws(morph: tune.morph),
            lengthScale: tune.size,
            depthScale: tune.size * tune.build,
            crownAspect: tune.crownAspect,
            drawnMean: tune.endTaper == MercuryMetrics.gEnd
                ? nil
                : stationPosition.map { position in 1 - (1 - tune.endTaper) * position * position }
        )
    }

    /// One draw per mode component from its own stationary measure, keyed by the seed.
    ///
    /// Scaled at construction against the ceiling, `maxHalfHeight`, rather than against any
    /// pose, because the rest shape is a property of the body rather than of whatever pose it
    /// happens to be in; the containment gauge is what keeps it inside a shallower one. Nor does
    /// Shimmer scale it, so a body without shimmer keeps its seed's asymmetry.
    private static func restDraw(noise: MercuryNoise, family: UInt64) -> [SIMD2<Double>] {
        var result = [SIMD2<Double>](repeating: SIMD2<Double>(), count: MercuryMetrics.modeCount)
        let reference = Double(MercuryMetrics.maxHalfHeight)
        for index in 0..<MercuryMetrics.modeCount {
            let mode = Double(index + 1)
            let scale = MercuryMetrics.restRMS / reference * pow(mode, -1.5)
            let counter = family &* UInt64(MercuryMetrics.modeCount) &+ UInt64(index)
            result[index] = scale * noise.gaussianPair(stream: MercuryNoiseStream.restShape, counter: counter)
        }
        return result
    }

    /// Every mode at the equilibrium this drive holds it to, with no velocity and no stress. A
    /// tune that compensates the modes' following builds the compensation at the body's present
    /// extent first, so the modes land on the equilibrium its law holds them to there.
    private func settleToEquilibrium(drive: Drive) {
        if law.compensates {
            prepareModes(length: Swift.max(body.length, 1), depth: Swift.max(depth, 0.25), kicked: false)
        }
        let driveScale = Double(drive.pose.driveScale)
        for index in 0..<MercuryMetrics.modeCount {
            let target = equilibrium(index, driveScale: driveScale)
            varicose[index] = Mode(value: target.varicose)
            snake[index] = Mode(value: target.snake)
        }
        contain(depth: Swift.max(depth, 0.25), drive: drive)
    }

    // MARK: - Geometry

    /// The body as drawn: the stock law's `theta` on the kit's envelope, `H0 · size · build · G′_s`,
    /// which is the stock edge times `size · build · G′ / G` at every station.
    private func rebuildGeometry() {
        let depth = self.depth * law.depthScale
        let envelope = drawnEnvelope ?? shapedEnvelope
        for station in 0...MercuryMetrics.columns {
            let exponents = edgeExponents(at: station)
            let drawn = depth * envelope[station]
            top[station] = Float(drawn * exp(exponents.upper))
            bottom[station] = Float(-drawn * exp(exponents.lower))
        }
    }

    /// `theta_T` and `theta_B` at one station: the one sum the containment gauge bounds and
    /// the geometry draws.
    @inline(__always)
    private func edgeExponents(at station: Int) -> (upper: Double, lower: Double) {
        let stations = MercuryMetrics.columns + 1
        var upper = 0.0
        var lower = 0.0
        for index in 0..<MercuryMetrics.modeCount {
            let cosine = Self.basisCosine[index * stations + station]
            let sine = Self.basisSine[index * stations + station]
            let varicoseValue = varicose[index].value
            let snakeValue = snake[index].value

            let upperAmplitude: SIMD2<Double> = varicoseValue + snakeValue
            upper += upperAmplitude.x * cosine - upperAmplitude.y * sine

            let lag = Self.lagPhase[index]
            let lagged = SIMD2<Double>(
                varicoseValue.x * lag.x - varicoseValue.y * lag.y,
                varicoseValue.x * lag.y + varicoseValue.y * lag.x
            )
            let lowerAmplitude: SIMD2<Double> = lagged - snakeValue
            lower += lowerAmplitude.x * cosine - lowerAmplitude.y * sine
        }
        return (upper, lower)
    }

    /// `cos(m * pi * a)` and `sin(m * pi * a)` at every station, and the envelope tables,
    /// all of which depend only on compile-time constants.
    private static let basisCosine: [Double] = basis(\.0)
    private static let basisSine: [Double] = basis(\.1)

    private static func basis(_ component: KeyPath<(Double, Double), Double>) -> [Double] {
        let stations = MercuryMetrics.columns + 1
        var table = [Double](repeating: 0, count: MercuryMetrics.modeCount * stations)
        for index in 0..<MercuryMetrics.modeCount {
            for station in 0..<stations {
                let angle = Double(index + 1) * Double.pi * Double(station) / Double(MercuryMetrics.columns)
                table[index * stations + station] = (cos(angle), sin(angle))[keyPath: component]
            }
        }
        return table
    }

    /// `2a - 1` at every station: the mean envelope's argument and the skew's ramp.
    private static let stationPosition: [Double] = (0...MercuryMetrics.columns).map { station in
        2 * Double(station) / Double(MercuryMetrics.columns) - 1
    }

    /// `G(a)`: the envelope the containment gauge proves against, whatever the kit draws.
    private static let meanEnvelope: [Double] = stationPosition.map { position in
        1 - (1 - MercuryMetrics.gEnd) * position * position
    }

    /// `exp(-((a - 0.5) / w)^2)`: the waist the neck pinches.
    private static let waist: [Double] = stationPosition.map { position in
        let offset = position / (2 * MercuryMetrics.neckWidth)
        return exp(-offset * offset)
    }

    /// `e^{-i m pi delta}`, the varicose family's group lag into the bottom edge.
    private static let lagPhase: [SIMD2<Double>] = (0..<MercuryMetrics.modeCount).map { index in
        let angle = -Double(index + 1) * Double.pi * MercuryMetrics.snakeLag
        return SIMD2(cos(angle), sin(angle))
    }
}

extension MercurySimulation.Drive {
    /// The drive the session hands the body: the model's pose on the ladder its layout climbs, in
    /// the pose context the controller keeps, its meter buffer, how long and how deep a body that
    /// layout can draw, the lean and a hand-off's arrival kick.
    ///
    /// The one place a live drive is built from the model, so the ribbon, the harness sheets
    /// and the benchmark cannot disagree about a layout's ladder or its longest body.
    @MainActor
    static func target(for model: RecordingOverlayModel, reduceMotion: Bool) -> MercurySimulation.Drive {
        let layout = model.layout
        let collar = layout.kind == .collar
        return MercurySimulation.Drive(
            pose: MercuryPose.target(
                for: model,
                collar: collar ? layout.spine : nil,
                context: model.poseContext
            ),
            samples: model.samples,
            reduceMotion: reduceMotion,
            lean: model.lean,
            maxLength: collar ? layout.spine.length : Double(MercuryMetrics.maxLength),
            maxHalfHeight: layout.spine.maxHalfHeight,
            spine: collar ? layout.spine : nil,
            arrival: model.arrival
        )
    }
}
