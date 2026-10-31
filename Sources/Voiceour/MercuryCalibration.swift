import CoreGraphics
import Foundation
import VoiceCore

/// The three constants the body's look depends on, solved once at boot against the
/// shipping geometry and shading paths rather than typed in.
///
/// Typed-in gains are how a procedural surface rots: the law changes, the number stays,
/// and the body quietly stops meaning what its constants claim. Each value here is
/// solved against a measurement of the real thing, and each measurement is asserted by
/// a test rather than trusted.
///
/// **Why the two geometry solves difference two runs.** The body has autonomous life —
/// a static rest asymmetry plus a shimmer of randomly kicked gel modes — whose amplitude at
/// the speaking pose is comparable to the crest train the voice paints. Measuring the total
/// would therefore be very nearly independent of the gain being solved for, and the
/// solve would return a meaningless number. So each measurement runs two simulations
/// from the *same* seed on the same meter with Reduce Motion on, one driven and one with
/// its voice disconnected, and takes the difference. Below the containment gauge the mode
/// law is linear, so that difference is exactly the voice's own contribution — the quantity
/// these two gains actually control.
///
/// **Why the two solves hear different meters.** The drive gain sets how large a crest a
/// speaking user sees, so it is solved under live speech: a ``MercurySpeechMeter`` shifting
/// a new level into the buffer every 40 ms, as a session's meter does and as the chrome
/// benchmark's speaking bodies hear. One buffer held still under-reads it. The gel draws the
/// voice quasi-statically, and a frozen buffer's crest train spends half of every 0.88 s in
/// its band-limited extension's thin, smooth trough, so at one gain the median live crest
/// stands 14 % above the frozen one, and a gain solved frozen drew live crests that pressed
/// the speaking body against its ceiling. The contact-line gain sets whether the two edges
/// move independently: a structural property of the law, solved at the listening pose, which
/// speech never reaches. There the meter hears the quiet room held still, as the benchmark's
/// listening bodies do, and a stationary periodic input is the right probe: one crest period
/// measures the correlation exactly. Played on a loop instead, the quiet room's correlation is
/// already −0.19 at zero contact line, the solve has no root, and it returns a degenerate zero.
@MainActor
final class MercuryCalibration {
    static let shared = MercuryCalibration()

    let gains: MercuryGains

    /// What the solved constants actually achieved, with both gains on, for the tests to hold
    /// them to: the crest prominence under live speech and the correlation in the quiet room.
    let crestProminence: Double
    let mirrorCorrelation: Double

    private init() {
        let speech = Probe(speaking: true, frames: Self.speechFrames, stepsPerFrame: Self.speechStepsPerFrame)
        let quietRoom = Probe(
            speaking: false,
            frames: Self.crestPeriodFrames,
            stepsPerFrame: Self.crestPeriodStepsPerFrame
        )
        let drive = Self.solveDriveGain(on: speech)
        let snake = Self.solveSnakeGain(drive: drive, on: quietRoom)
        gains = MercuryGains(drive: drive, snake: snake)
        crestProminence = speech.crestProminence(gains: gains)
        mirrorCorrelation = quietRoom.mirrorCorrelation(gains: gains)
    }

    /// The bounded display response for one generated room and look, metered over both live
    /// poses of the bodies `layout` draws. Two scene anchors solve its two parameters; no
    /// bisection and no runtime clamp can turn a different seed into a different material.
    ///
    /// `environment` is the look's room, already baked with its lighting. `look` supplies the
    /// rest of what the response is metered against, the paint table and the tune its bodies
    /// move and are drawn under, and the tone and underglow strength its targets come from.
    func displayResponse(
        for environment: MercuryEnvironment,
        bodySeed: UInt64,
        layout: RecordingOverlayLayout,
        look: MercuryLook = .stock
    ) -> MercuryDisplayResponse {
        meter(environment: environment, bodySeed: bodySeed, layout: layout, look: look).response
    }

    /// The metered median after the bounded response, for the calibration tests.
    func displayLuminance(
        for environment: MercuryEnvironment,
        bodySeed: UInt64,
        layout: RecordingOverlayLayout,
        look: MercuryLook = .stock
    ) -> Double {
        let (samples, response) = meter(environment: environment, bodySeed: bodySeed, layout: layout, look: look)
        return Self.median(
            samples.map {
                MercuryDisplayResponse.luminance(
                    response.map(SIMD3(Double($0.x), Double($0.y), Double($0.z)))
                )
            }
        )
    }

    /// One scene sampling and the response solved on it, so ``displayLuminance(for:bodySeed:layout:look:)``
    /// reads the very samples the response was solved on.
    ///
    /// The targets are the look's tone anchors for its paint's albedo. Stock, they are the shipped
    /// constants themselves, and stock bodies under the stock table sample what the shipped
    /// renderer samples, so the stock look's response is the shipped one bit for bit.
    private func meter(
        environment: MercuryEnvironment,
        bodySeed: UInt64,
        layout: RecordingOverlayLayout,
        look: MercuryLook
    ) -> (samples: [SIMD3<Float>], response: MercuryDisplayResponse) {
        let paint = MercuryPaintLookup.lookup(for: look.paint)
        let samples = Self.sceneRadianceSamples(
            gains: gains,
            tune: look.tune,
            environment: environment,
            paint: paint,
            seed: bodySeed,
            layout: layout
        )
        let targets = MercuryToneAnchors.targets(
            albedo: paint.albedo,
            tone: look.tone,
            underglowStrength: look.underglowStrength
        )
        let response = Self.response(
            metering: samples,
            highlightPercentile: Self.highlightPercentile(for: layout),
            medianTarget: targets.median,
            highlightTarget: targets.highlight
        )
        return (samples, response)
    }

    // MARK: - Fixed measurement conditions

    /// The bodies both geometry solves measure.
    private static let seeds: [UInt64] = [0x5155_4943_4B53_4C56, 0x1d3a_7f21_9c4e_b806]

    /// Substeps between the reset and the first measured frame. A reset leaves the body at
    /// rest on its pose, which under Reduce Motion it never leaves, so the body shape has no
    /// transient at all. The modes start at the equilibrium of the voice at that instant, and
    /// the voice moves on at once; the gel's slowest answer to that is the arm's creep, at
    /// 2.1 s⁻¹ for the speaking fundamental. After 1.5 s it is gone: measured over one voice
    /// period, the prominence after 180 substeps agrees with the prominence after 1,440 to
    /// 0.01 %, and the correlation to 0.001. Under live speech, the median prominence pooled
    /// over 48 seeds shows no trend from the first second after the reset on.
    private static let settleSteps = 180

    /// One period of the quiet room's crest train. Every mode advects through whole turns in
    /// `2 * bufferPeriod`, 0.88 s, so 53 frames of 2 substeps span it to within 0.4 of a
    /// substep, and the correlation cannot depend on where in the period the window starts. A
    /// 48-frame window left out an eleventh of the period, and which eleventh moved the median
    /// prominence of the speaking body, frozen, at one gain between 4.3 and 5.2 pt.
    private static let crestPeriodStepsPerFrame = 2
    private static let crestPeriodFrames = Int(
        (2 * MercuryMetrics.bufferPeriod / MercuryMetrics.substep / Double(crestPeriodStepsPerFrame)).rounded()
    )

    /// Five seconds of speech per seed, a frame every 50 ms. Live speech never repeats, so no
    /// window spans a period of it; this one is long enough that where it starts stops
    /// mattering. Over six starts from 1.5 s to 9 s after the reset, the gain solved on these
    /// two seeds moves by 2 % (one standard deviation); over six pairs of other seeds, by 3 %.
    /// Frames closer than 50 ms add almost nothing to the median, and each costs a copy of
    /// both edges.
    private static let speechStepsPerFrame = 6
    private static let speechFrames = 100

    private static let bisectionSteps = 18
    /// The drive solve stops when the prominence is within this fraction of its target.
    private static let proportionTolerance = 1e-3
    private static let proportionSteps = 12

    /// The drive `MercuryRibbon` hands the engine for a microphone on `layout` hearing the
    /// syllable or the quiet room held still, built through the pose ladder itself, not a copy
    /// of it: building the model the ladder reads also proves the voice-activity hysteresis lands
    /// on the pose this measurement names.
    private static func drive(
        speaking: Bool,
        layout: RecordingOverlayLayout,
        reduceMotion: Bool
    ) -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in speaking ? MercurySpeechMeter.syllable : MercurySpeechMeter.quietRoom {
            model.record(level)
        }
        return .target(for: model, reduceMotion: reduceMotion)
    }

    // MARK: - Solves

    /// The drive gain whose live crests reach the target prominence, with the contact line off.
    /// Both gains are the body law's, not the lighting's, so both are solved on the island's
    /// canonical bodies, whatever layout a session goes on to draw, and on the stock law,
    /// whatever its look: a tune scales the law's own constants about these gains.
    ///
    /// Solved by proportion rather than bisection. Below the containment gauge the voice's
    /// amplitudes are linear in the gain, and the drawn edge's exponential and the gauge bend
    /// the prominence away from proportional by a few percent, so scaling the gain by target
    /// over measured converges geometrically. Measured from a unit gain: four to six
    /// measurements land within 0.1 % of the target and agree with the bisected root to
    /// 0.04 %, where bisection takes twenty. That is what affords a window of live speech long
    /// enough to be stationary: bisected, the same window alone took 190 ms.
    private static func solveDriveGain(on speech: Probe) -> Double {
        // Snake is zero here and solved next, against the drive this returns. The two
        // are mildly coupled and the order is the one the design fixes.
        let target = MercuryMetrics.targetCrestProminence
        var gain = 1.0
        for _ in 0..<proportionSteps {
            let prominence = speech.crestProminence(gains: MercuryGains(drive: gain, snake: 0))
            // A law whose voice moves no edge has no gain to solve; the drawable answer is
            // returned, and the calibration tests reject it.
            guard prominence > 0, abs(prominence - target) > proportionTolerance * target else { break }
            gain *= target / prominence
        }
        return gain
    }

    /// Solved so the two edges are *independent*, which is the point the plan's
    /// `<= 0.2` gate is aiming at, rather than solved against that gate directly.
    ///
    /// Measured: at zero snake the correlation is already 0.11, because the varicose
    /// family's group lag inverts the phase of the higher modes on its own — so bisecting
    /// against "reach 0.2" has no root and returns a degenerate zero, deleting the
    /// contact-line family from the voice response entirely. The correlation runs from
    /// +0.11 at zero snake to -1 as snake dominates (rigidly counter-moving edges, which
    /// is a snake and not a liquid), so zero is the interior point that means what the
    /// gate wants. The gate itself is then a consequence, and the calibration test holds
    /// the achieved correlation to it.
    private static func solveSnakeGain(drive: Double, on quietRoom: Probe) -> Double {
        bisect(low: 0, high: 100) { candidate in
            quietRoom.mirrorCorrelation(gains: MercuryGains(drive: drive, snake: candidate))
        }
    }

    // MARK: - Measurements

    /// The voice's own contribution to the island's canonical body on one meter, frame by frame.
    ///
    /// Each seed runs on its meter with the candidate gains and is differenced against the same
    /// body with its voice disconnected: zero gains, which is exactly `driveScale` zero, since
    /// the voice reaches the modes through the gains alone. No candidate reaches that quiet
    /// body, so it runs once, here, rather than once per candidate, which was half of every
    /// solve's simulation.
    @MainActor
    private struct Probe {
        private let speaking: Bool
        private let frames: Int
        private let stepsPerFrame: Int
        /// The quiet body's geometry, per seed, per frame.
        private var quiet: [[MercurySimulation.Geometry]] = []

        init(speaking: Bool, frames: Int, stepsPerFrame: Int) {
            self.speaking = speaking
            self.frames = frames
            self.stepsPerFrame = stepsPerFrame
            quiet = MercuryCalibration.seeds.map { seed in
                var geometries: [MercurySimulation.Geometry] = []
                geometries.reserveCapacity(frames)
                forEachFrame(seed: seed, gains: MercuryGains(drive: 0, snake: 0)) { _, geometry in
                    geometries.append(geometry)
                }
                return geometries
            }
        }

        /// Median peak-to-trough excursion of the voice-driven top edge, in points.
        func crestProminence(gains: MercuryGains) -> Double {
            var excursions: [Double] = []
            excursions.reserveCapacity(MercuryCalibration.seeds.count * frames)
            for (index, seed) in MercuryCalibration.seeds.enumerated() {
                forEachFrame(seed: seed, gains: gains) { frame, driven in
                    let quiet = quiet[index][frame].top
                    var highest = -Double.infinity
                    var lowest = Double.infinity
                    for station in driven.top.indices {
                        let offset = Double(driven.top[station]) - Double(quiet[station])
                        highest = Swift.max(highest, offset)
                        lowest = Swift.min(lowest, offset)
                    }
                    excursions.append(highest - lowest)
                }
            }
            return MercuryCalibration.median(excursions)
        }

        /// Mean Pearson correlation between the voice-driven top edge and the negated
        /// voice-driven bottom edge. A pill is exactly +1.
        func mirrorCorrelation(gains: MercuryGains) -> Double {
            var total = 0.0
            var count = 0
            for (index, seed) in MercuryCalibration.seeds.enumerated() {
                forEachFrame(seed: seed, gains: gains) { frame, driven in
                    let quiet = quiet[index][frame]
                    let top = zip(driven.top, quiet.top).map { Double($0) - Double($1) }
                    let mirrored = zip(driven.bottom, quiet.bottom).map { Double($1) - Double($0) }
                    total += MercuryCalibration.correlation(top, mirrored)
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 1
        }

        /// `seed`'s body on its own meter, placed at rest on the meter's first drive and settled,
        /// handed to `body` once per frame.
        private func forEachFrame(
            seed: UInt64,
            gains: MercuryGains,
            _ body: (_ frame: Int, _ geometry: MercurySimulation.Geometry) -> Void
        ) {
            let meter = MercurySpeechMeter(speaking: speaking, seed: seed, layout: .island, reduceMotion: true)
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: meter.drive)
            meter.advance(simulation, steps: MercuryCalibration.settleSteps)
            for frame in 0..<frames {
                meter.advance(simulation, steps: stepsPerFrame)
                body(frame, simulation.geometry)
            }
        }
    }

    /// In-body `radiance * paint reflectance` triples for one room, pooled over the two poses
    /// the body actually spends its time in, laid out as `layout` draws them.
    ///
    /// Both, not one: metering only the listening body landed *its* median on target and
    /// left the speaking body — the one a reader watches — anywhere from 0.04 to 0.46
    /// across four rooms, because a taller ridge with deeper crests sweeps a different
    /// part of the room. The body carries the session's own seed, tune and layout, so the
    /// room is metered against the body it will light rather than against a stand-in. The
    /// layout matters as much as the pose: a collar shows only the outer half of a chin and
    /// walls, which sweeps a different part of the room than the island's whole crown. So
    /// does the tune: its law moves the body and its body kit draws it, crown included.
    ///
    /// Sampled once through the shipping crown and paint path, then solved in closed form.
    /// The room is static, so the response remains valid for as long as the layout and the
    /// look are.
    private static func sceneRadianceSamples(
        gains: MercuryGains,
        tune: MercuryTune,
        environment: MercuryEnvironment,
        paint: MercuryPaintLookup,
        seed: UInt64,
        layout: RecordingOverlayLayout
    ) -> [SIMD3<Float>] {
        let rasterizer = MercuryRasterizer()
        var samples: [SIMD3<Float>] = []
        for speaking in [false, true] {
            let drive = drive(speaking: speaking, layout: layout, reduceMotion: false)
            let simulation = MercurySimulation(seed: seed, gains: gains, tune: tune)
            simulation.reset(to: drive)
            simulation.advance(steps: settleSteps, drive: drive)
            let collected = rasterizer.sampleSceneRadiance(
                field: MercuryField(
                    geometry: simulation.geometry,
                    spine: layout.spine,
                    canvas: layout.canvasRect.size
                ),
                environment: environment,
                paint: paint,
                scale: MercuryMetrics.rasterScale
            )
            // Every fourth pixel: the median of a stride is the median, and the full set
            // would make this the slowest thing that happens when a session starts.
            samples.append(contentsOf: stride(from: 0, to: collected.count, by: 4).map { collected[$0] })
        }
        return samples
    }

    /// The pooled percentile `layout`'s highlight anchor lands on. See
    /// `MercuryMetrics.collarHighlightPercentile`.
    private static func highlightPercentile(for layout: RecordingOverlayLayout) -> Int {
        layout.kind == .collar ? MercuryMetrics.collarHighlightPercentile : MercuryMetrics.highlightPercentile
    }

    /// The response whose two anchors put the pooled samples' median and their
    /// `highlightPercentile` on their targets.
    private static func response(
        metering samples: [SIMD3<Float>],
        highlightPercentile: Int,
        medianTarget: Double,
        highlightTarget: Double
    ) -> MercuryDisplayResponse {
        let values = samples.map {
            MercuryDisplayResponse.luminance(
                SIMD3(Double($0.x), Double($0.y), Double($0.z))
            )
        }.sorted()
        guard
            values.count > 100,
            let response = MercuryDisplayResponse.solve(
                sceneMedian: values[values.count / 2],
                sceneHighlight: values[values.count * highlightPercentile / 100],
                medianTarget: medianTarget,
                highlightTarget: highlightTarget,
                ceiling: MercuryMetrics.displayCeiling
            )
        else {
            preconditionFailure("generated mercury room has no solvable luminance spread")
        }
        return response
    }

    // MARK: - Numerics

    /// Bisection on a monotone function, in either direction, over a bracket that is
    /// assumed to contain the root. When it does not, the closer end is returned, which
    /// is the drawable answer and is what the calibration tests then hold it to.
    private static func bisect(low: Double, high: Double, _ residual: (Double) -> Double) -> Double {
        var lower = low
        var upper = high
        let lowerResidual = residual(lower)
        let upperResidual = residual(upper)
        guard lowerResidual * upperResidual <= 0 else {
            return abs(lowerResidual) <= abs(upperResidual) ? lower : upper
        }
        let ascending = lowerResidual < 0
        for _ in 0..<bisectionSteps {
            let middle = (lower + upper) / 2
            let value = residual(middle)
            if (value < 0) == ascending {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) / 2
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func correlation(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        let count = Double(first.count)
        let firstMean = first.reduce(0, +) / count
        let secondMean = second.reduce(0, +) / count
        var covariance = 0.0
        var firstVariance = 0.0
        var secondVariance = 0.0
        for index in 0..<first.count {
            let left = first[index] - firstMean
            let right = second[index] - secondMean
            covariance += left * right
            firstVariance += left * left
            secondVariance += right * right
        }
        let denominator = (firstVariance * secondVariance).squareRoot()
        return denominator > 1e-15 ? covariance / denominator : 0
    }
}
