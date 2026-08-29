import CoreGraphics
import Foundation

/// The two gains the mode law needs, solved once at boot rather than typed in.
///
/// See ``MercuryCalibration``: `drive` is bisected against the drawn crest prominence
/// at the speaking pose and `snake` against the anti-mirror correlation at the
/// listening pose, both measured through the shipping geometry path.
struct MercuryGains: Equatable {
    var drive: Double
    var snake: Double
}

/// One mercury body: two mode families, eight modes each, integrated with the exact
/// propagator at a fixed substep.
///
/// Not an `ObservableObject`. The view advances it inside a `TimelineView` tick, which
/// is already re-rendering, so anything published here would invalidate the overlay
/// twice per frame.
///
/// The law, in the body's own island-local points — origin at the island centre, +y up:
///
/// - Material coordinate `a` in `[0, 1]`, `x = (a - 0.5) * L`.
/// - Mean envelope `G(a) = 1 - (1 - gEnd) * (2a - 1)^2`.
/// - `y_T(a) = +H0 * G(a) * exp(theta_T(a))`, `y_B(a) = -H0 * G(a) * exp(theta_B(a))`,
///   with `theta_T = sum Re[(V_m + N_m) e^{i m pi a}]` and
///   `theta_B = sum Re[(V_m e^{-i m pi delta} - N_m) e^{i m pi a}]`.
///
/// `V` is the varicose (thickness) family and `N` the contact-line (snake) family. `N`
/// entering the two edges with opposite sign is the whole reason the edges are
/// independent rather than mirrored; `delta` is a group lag, a linear phase in `m`.
///
/// Because `y_T` and `y_B` are exponentials of a bounded sum, the drawn body is bounded
/// *exactly* rather than clamped: `|theta| <= Theta = sum(|V_m| + |N_m|)`, so holding
/// `Theta <= ln(maxHalfHeight / H0)` is a proof, not a hope. That is the only limiter in
/// the geometry path.
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
    }

    /// What the rasterizer and the hit test read. Points, island-local, +y up.
    struct Geometry {
        var length: CGFloat
        var halfHeight: CGFloat
        /// `columns + 1` samples of the top edge.
        var top: [Float]
        /// `columns + 1` samples of the bottom edge, all negative.
        var bottom: [Float]
    }

    private struct Mode {
        var value = SIMD2<Double>()
        var velocity = SIMD2<Double>()
    }

    private let noise: MercuryNoise
    private let gains: MercuryGains

    private var varicose: [Mode]
    private var snake: [Mode]
    /// The body's own static rest asymmetry, drawn once per seed. Never zero: zero is
    /// the mirror-symmetric minimiser, which is a capsule.
    private let restVaricose: [SIMD2<Double>]
    private let restSnake: [SIMD2<Double>]

    /// The advected voice spectrum, one complex coefficient per mode.
    private var voice: [SIMD2<Double>]
    private var lastSamples: [Float]

    private var length: Double
    private var halfHeight: Double
    private var substepIndex: UInt64 = 0
    private var lastReduceMotion: Bool
    private var lastGesture: MercuryOutcomeGesture?

    private var top: [Float]
    private var bottom: [Float]

    var geometry: Geometry {
        Geometry(length: CGFloat(length), halfHeight: CGFloat(halfHeight), top: top, bottom: bottom)
    }

    init(seed: UInt64, gains: MercuryGains) {
        noise = MercuryNoise(seed: seed)
        self.gains = gains
        let count = MercuryMetrics.modeCount
        varicose = Array(repeating: Mode(), count: count)
        snake = Array(repeating: Mode(), count: count)
        restVaricose = Self.restDraw(noise: MercuryNoise(seed: seed), family: 0)
        restSnake = Self.restDraw(noise: MercuryNoise(seed: seed), family: 1)
        voice = Array(repeating: SIMD2<Double>(), count: count)
        lastSamples = Array(repeating: 0, count: 11)
        length = 0
        halfHeight = 0
        lastReduceMotion = false
        lastGesture = nil
        top = Array(repeating: 0, count: MercuryMetrics.columns + 1)
        bottom = Array(repeating: 0, count: MercuryMetrics.columns + 1)
        applyRestState()
        rebuildGeometry()
    }

    /// Places the body at rest in this drive, with no transient to settle. Used by the
    /// harness's pinned frame, by calibration, and whenever a new session starts.
    func reset(to drive: Drive) {
        length = Double(drive.pose.length)
        halfHeight = Double(drive.pose.halfHeight)
        substepIndex = 0
        lastReduceMotion = drive.reduceMotion
        lastGesture = drive.pose.gesture
        lastSamples = drive.samples
        voice = Self.spectrum(of: drive.samples)
        applyRestState()
        settleToEquilibrium(drive: drive)
        rebuildGeometry()
    }

    func advance(steps: Int, drive: Drive) {
        guard steps > 0 else { return }
        refreshVoice(drive: drive)
        applyGestureImpulse(drive: drive)
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
        let interval = MercuryMetrics.substep
        relaxPose(toward: drive.pose, step: interval)
        advectVoice(step: interval)

        let effectiveLength = Swift.max(length, 1)
        let effectiveHalf = Swift.max(halfHeight, 0.25)
        let driveScale = Double(drive.pose.driveScale)

        for index in 0..<MercuryMetrics.modeCount {
            let mode = Double(index + 1)
            let wave = mode * Double.pi / effectiveLength
            let omega = Self.frequency(waveNumber: wave, depth: effectiveHalf)
            let damping = MercuryMetrics.zeta0 / (1 + pow(wave * MercuryMetrics.capillaryLength, 2))

            let coefficient = voice[index]
            let varicoseForce: SIMD2<Double> = (driveScale * gains.drive) * coefficient
            let varicoseTarget: SIMD2<Double> = restVaricose[index] + varicoseForce
            // Multiplying by `i * m * pi` is the derivative along the material
            // coordinate: the contact line answers the crest's slope, not its height,
            // which is what stops the two edges moving as one.
            let rotated = SIMD2<Double>(-coefficient.y, coefficient.x)
            let snakeWeight: Double = driveScale * gains.snake * mode * Double.pi
            let snakeTarget: SIMD2<Double> = restSnake[index] + snakeWeight * rotated

            varicose[index] = Self.propagate(
                varicose[index],
                equilibrium: varicoseTarget,
                omega: omega,
                damping: damping,
                step: interval
            )
            snake[index] = Self.propagate(
                snake[index],
                equilibrium: snakeTarget,
                omega: omega,
                damping: damping,
                step: interval
            )

            guard !drive.reduceMotion else { continue }
            // Stationary variance is exactly `variance` per component: for
            // `u'' + 2 z w u' + w^2 u = xi`, `<u^2> = D / (2 z w^3)`, and one substep's
            // velocity increment has variance `2 D h`, with `h` this substep.
            let scale = MercuryMetrics.restRMS / effectiveHalf * pow(mode, -1.5)
            let variance = scale * scale
            let deviation = (4 * damping * omega * omega * omega * variance * interval).squareRoot()
            let counter = substepIndex &* UInt64(MercuryMetrics.modeCount) &+ UInt64(index)
            let varicoseKick = noise.gaussianPair(stream: MercuryNoiseStream.varicoseForcing, counter: counter)
            let snakeKick = noise.gaussianPair(stream: MercuryNoiseStream.snakeForcing, counter: counter)
            varicose[index].velocity += deviation * varicoseKick
            snake[index].velocity += deviation * snakeKick
        }

        contain(halfHeight: effectiveHalf)
        substepIndex &+= 1
    }

    /// Deep-water capillary-gravity dispersion on a pool of this depth, slowed by one
    /// global tempo. Nothing else sets how fast the body moves.
    private static func frequency(waveNumber: Double, depth: Double) -> Double {
        let squared =
            (MercuryMetrics.gravity * waveNumber
                + MercuryMetrics.surfaceTensionOverDensity * waveNumber * waveNumber * waveNumber)
            * tanh(waveNumber * depth)
        return MercuryMetrics.tempo * squared.squareRoot()
    }

    /// Exact 2x2 propagator for a damped oscillator about a fixed equilibrium over one
    /// step. The two real components of the complex amplitude are independent, so one
    /// `SIMD2` pass covers both.
    private static func propagate(
        _ mode: Mode,
        equilibrium: SIMD2<Double>,
        omega: Double,
        damping: Double,
        step: Double
    ) -> Mode {
        let damped = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * step)
        let cosine = cos(damped * step)
        let sine = sin(damped * step)

        let offset: SIMD2<Double> = mode.value - equilibrium
        let rate: SIMD2<Double> = mode.velocity
        let decayed: Double = damping * omega
        let ratio: Double = sine / damped

        let offsetRate: SIMD2<Double> = rate + decayed * offset
        let nextOffset: SIMD2<Double> = decay * (cosine * offset + ratio * offsetRate)
        let rateOffset: SIMD2<Double> = (omega * omega) * offset + decayed * rate
        let nextRate: SIMD2<Double> = decay * (cosine * rate - ratio * rateOffset)
        return Mode(value: nextOffset + equilibrium, velocity: nextRate)
    }

    // MARK: - Containment

    /// Moreau's inelastic rule on the envelope the body is actually drawn against.
    ///
    /// The drawn edge is `y_T[j] = H0 * G_j * exp(theta_T[j])` at each of the stations the
    /// field reads, so `theta_j <= ln(maxHalfHeight / (H0 * G_j))` is an exact statement
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
    /// re-clamped every substep, which would read as a stutter.
    private func contain(halfHeight depth: Double) {
        let gauge = envelopeGauge(halfHeight: depth)
        guard gauge > 1 else { return }
        let scale = 1 / gauge
        for index in 0..<MercuryMetrics.modeCount {
            varicose[index] = Self.retract(varicose[index], scale: scale)
            snake[index] = Self.retract(snake[index], scale: scale)
        }
    }

    /// Worst `theta_j / cap_j` over the drawn stations, on both edges.
    private func envelopeGauge(halfHeight depth: Double) -> Double {
        let stations = MercuryMetrics.columns + 1
        let ceiling = Double(MercuryMetrics.maxHalfHeight)
        var worst = 0.0
        for station in 0..<stations {
            let envelope = depth * Self.meanEnvelope[station]
            guard envelope > 1e-9 else { continue }
            let cap = log(ceiling / envelope)
            guard cap > 1e-6 else { return .greatestFiniteMagnitude }
            var upper = 0.0
            var lower = 0.0
            for index in 0..<MercuryMetrics.modeCount {
                let cosine = Self.basisCosine[index * stations + station]
                let sine = Self.basisSine[index * stations + station]
                let varicoseValue = varicose[index].value
                let snakeValue = snake[index].value
                let upperAmplitude = varicoseValue + snakeValue
                upper += upperAmplitude.x * cosine - upperAmplitude.y * sine
                let lag = Self.lagPhase[index]
                let lagged = SIMD2<Double>(
                    varicoseValue.x * lag.x - varicoseValue.y * lag.y,
                    varicoseValue.x * lag.y + varicoseValue.y * lag.x
                )
                let lowerAmplitude = lagged - snakeValue
                lower += lowerAmplitude.x * cosine - lowerAmplitude.y * sine
            }
            worst = Swift.max(worst, Swift.max(upper, lower) / cap)
        }
        return worst
    }

    private static func retract(_ mode: Mode, scale: Double) -> Mode {
        var next = Mode(value: mode.value * scale, velocity: mode.velocity)
        let size = magnitude(next.value)
        guard size > 0 else { return next }
        let radial = next.value / size
        let outward = (next.velocity * radial).sum()
        if outward > 0 {
            next.velocity -= outward * radial
        }
        return next
    }

    @inline(__always)
    private static func magnitude(_ value: SIMD2<Double>) -> Double {
        (value.x * value.x + value.y * value.y).squareRoot()
    }

    // MARK: - Pose and voice

    private func relaxPose(toward pose: MercuryPose, step: Double) {
        let pole = exp(-step / MercuryMetrics.poseTau)
        length = Double(pose.length) + (length - Double(pose.length)) * pole
        halfHeight = Double(pose.halfHeight) + (halfHeight - Double(pose.halfHeight)) * pole
    }

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

    private func applyGestureImpulse(drive: Drive) {
        let gesture = drive.pose.gesture
        defer { lastGesture = gesture }
        guard gesture != lastGesture, let gesture else { return }
        switch gesture {
        case .gathered:
            break
        case .lurch:
            snake[0].velocity.x += MercuryMetrics.lurchImpulse
        case .collapse:
            varicose[0].velocity.x += MercuryMetrics.collapseImpulse
        }
    }

    // MARK: - State helpers

    /// One draw per mode component from its own stationary measure, keyed by the seed.
    ///
    /// Scaled at construction against the deepest pose the body can hold, because the
    /// rest shape is a property of the body rather than of whatever pose it happens to
    /// be in; the containment gauge is what keeps it inside a shallower one.
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

    private func applyRestState() {
        for index in 0..<MercuryMetrics.modeCount {
            varicose[index] = Mode(value: restVaricose[index], velocity: SIMD2<Double>())
            snake[index] = Mode(value: restSnake[index], velocity: SIMD2<Double>())
        }
    }

    private func settleToEquilibrium(drive: Drive) {
        let driveScale = Double(drive.pose.driveScale)
        for index in 0..<MercuryMetrics.modeCount {
            let mode = Double(index + 1)
            let coefficient = voice[index]
            let rotated = SIMD2<Double>(-coefficient.y, coefficient.x)
            let varicoseForce: SIMD2<Double> = (driveScale * gains.drive) * coefficient
            let snakeWeight: Double = driveScale * gains.snake * mode * Double.pi
            let snakeForce: SIMD2<Double> = snakeWeight * rotated
            varicose[index] = Mode(
                value: restVaricose[index] + varicoseForce,
                velocity: SIMD2<Double>()
            )
            snake[index] = Mode(
                value: restSnake[index] + snakeForce,
                velocity: SIMD2<Double>()
            )
        }
        contain(halfHeight: Swift.max(halfHeight, 0.25))
    }

    // MARK: - Geometry

    private func rebuildGeometry() {
        let stations = MercuryMetrics.columns + 1
        let depth = halfHeight
        for station in 0..<stations {
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
            let envelope = depth * Self.meanEnvelope[station]
            top[station] = Float(envelope * exp(upper))
            bottom[station] = Float(-envelope * exp(lower))
        }
    }

    /// `cos(m * pi * a)` and `sin(m * pi * a)` at every station, and the mean envelope,
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

    private static let meanEnvelope: [Double] = {
        let stations = MercuryMetrics.columns + 1
        return (0..<stations).map { station in
            let position = 2 * Double(station) / Double(MercuryMetrics.columns) - 1
            return 1 - (1 - MercuryMetrics.gEnd) * position * position
        }
    }()

    /// `e^{-i m pi delta}`, the varicose family's group lag into the bottom edge.
    private static let lagPhase: [SIMD2<Double>] = (0..<MercuryMetrics.modeCount).map { index in
        let angle = -Double(index + 1) * Double.pi * MercuryMetrics.snakeLag
        return SIMD2(cos(angle), sin(angle))
    }
}
