import CoreGraphics
import Foundation
import VoiceCore

/// The three constants the body's look depends on, solved once at boot against the
/// shipping geometry and shading paths rather than typed in.
///
/// Typed-in gains are how a procedural surface rots: the law changes, the number stays,
/// and the body quietly stops meaning what its constants claim. Each value here is
/// bisected against a measurement of the real thing, and each measurement is asserted by
/// a test rather than trusted.
///
/// **Why the two geometry solves difference two runs.** The body has autonomous life —
/// a static rest asymmetry plus an Ornstein-Uhlenbeck shimmer — whose amplitude at the
/// speaking pose is comparable to the crest train the voice paints. Measuring the total
/// would therefore be very nearly independent of the gain being solved for, and the
/// bisection would return a meaningless number. So each measurement runs two simulations
/// from the *same* seed with Reduce Motion on, one driven and one with `driveScale` at
/// zero, and takes the difference. Below the containment gauge the mode law is linear, so
/// that difference is exactly the voice's own contribution — the quantity these two gains
/// actually control.
@MainActor
final class MercuryCalibration {
    static let shared = MercuryCalibration()

    let gains: MercuryGains

    /// What the solved constants actually achieved, for the tests to hold them to.
    let crestProminence: Double
    let mirrorCorrelation: Double

    private init() {
        let drive = Self.solveDriveGain()
        let snake = Self.solveSnakeGain(drive: drive)
        gains = MercuryGains(drive: drive, snake: snake)
        crestProminence = Self.crestProminence(gains: gains)
        mirrorCorrelation = Self.mirrorCorrelation(gains: gains)
    }

    /// The bounded display response for one generated room, metered over both live poses.
    /// Two scene anchors solve its two parameters; no bisection and no runtime clamp can
    /// turn a different seed into a different material.
    func displayResponse(
        for environment: MercuryEnvironment,
        bodySeed: UInt64
    ) -> MercuryDisplayResponse {
        let samples = Self.sceneRadianceSamples(
            gains: gains,
            environment: environment,
            seed: bodySeed
        )
        let values = samples.map {
            MercuryDisplayResponse.luminance(
                SIMD3(Double($0.x), Double($0.y), Double($0.z))
            )
        }.sorted()
        guard
            values.count > 100,
            let response = MercuryDisplayResponse.solve(
                sceneMedian: values[values.count / 2],
                sceneHighlight: values[values.count * 98 / 100],
                medianTarget: MercuryMetrics.targetDisplayLuminance,
                highlightTarget: MercuryMetrics.targetHighlightLuminance,
                ceiling: MercuryMetrics.displayCeiling
            )
        else {
            preconditionFailure("generated mercury room has no solvable luminance spread")
        }
        return response
    }

    /// The metered median after the bounded response, for the calibration tests.
    func displayLuminance(for environment: MercuryEnvironment, bodySeed: UInt64) -> Double {
        let samples = Self.sceneRadianceSamples(
            gains: gains,
            environment: environment,
            seed: bodySeed
        )
        let response = displayResponse(for: environment, bodySeed: bodySeed)
        return Self.median(
            samples.map {
                MercuryDisplayResponse.luminance(
                    response.map(SIMD3(Double($0.x), Double($0.y), Double($0.z)))
                )
            }
        )
    }

    // MARK: - Fixed measurement conditions

    /// A speech-like meter buffer, oldest first. The same shape the live meter produces.
    private static let speakingSamples: [Float] = [
        0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46,
    ]
    /// A live microphone in a quiet room: every level at or below the release threshold,
    /// so the voice-activity hysteresis never starts and the pose is the listening one.
    private static let listeningSamples: [Float] = [
        0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02,
    ]

    private static let seeds: [UInt64] = [
        0x5155_4943_4B53_4C56, 0x1d3a_7f21_9c4e_b806, 0xa07b_5514_ee92_3fd1,
        0x6c19_e83d_402f_a75b, 0xf24d_0b6a_9137_5ce8, 0x3e85_c9f0_71ab_2d64,
    ]

    private static let settleSteps = 180
    private static let measuredFrames = 48
    private static let stepsPerFrame = 2
    private static let bisectionSteps = 18

    /// The pose ladder itself, not a copy of it: building the model the ladder reads also
    /// proves the voice-activity hysteresis lands on the pose this measurement names.
    private static func pose(speaking: Bool) -> MercuryPose {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in speaking ? speakingSamples : listeningSamples {
            model.record(level)
        }
        return MercuryPose.target(for: model)
    }

    // MARK: - Solves

    private static func solveDriveGain() -> Double {
        // Snake is zero here and solved next, against the drive this returns. The two
        // are mildly coupled and the order is the one the design fixes.
        bisect(low: 0, high: 50) { candidate in
            crestProminence(gains: MercuryGains(drive: candidate, snake: 0))
                - MercuryMetrics.targetCrestProminence
        }
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
    private static func solveSnakeGain(drive: Double) -> Double {
        bisect(low: 0, high: 100) { candidate in
            mirrorCorrelation(gains: MercuryGains(drive: drive, snake: candidate))
        }
    }

    // MARK: - Measurements

    /// Median peak-to-trough excursion of the voice-driven top edge, in points.
    static func crestProminence(gains: MercuryGains) -> Double {
        var values: [Double] = []
        for seed in seeds.prefix(2) {
            for frame in voiceResponse(pose: pose(speaking: true), samples: speakingSamples, gains: gains, seed: seed) {
                let highest = frame.top.max() ?? 0
                let lowest = frame.top.min() ?? 0
                values.append(highest - lowest)
            }
        }
        return median(values)
    }

    /// Mean Pearson correlation between the voice-driven top edge and the negated
    /// voice-driven bottom edge. A pill is exactly +1.
    static func mirrorCorrelation(gains: MercuryGains) -> Double {
        var total = 0.0
        var count = 0
        for seed in seeds.prefix(2) {
            for frame in voiceResponse(
                pose: pose(speaking: false),
                samples: listeningSamples,
                gains: gains,
                seed: seed
            ) {
                let mirrored = frame.bottom.map { -$0 }
                total += correlation(frame.top, mirrored)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 1
    }

    /// One frame of the body's response to the voice alone, top and bottom, in points.
    private static func voiceResponse(
        pose: MercuryPose,
        samples: [Float],
        gains: MercuryGains,
        seed: UInt64
    ) -> [(top: [Double], bottom: [Double])] {
        var quietPose = pose
        quietPose.driveScale = 0
        let drivenDrive = MercurySimulation.Drive(pose: pose, samples: samples, reduceMotion: true)
        let quietDrive = MercurySimulation.Drive(pose: quietPose, samples: samples, reduceMotion: true)

        let driven = MercurySimulation(seed: seed, gains: gains)
        let quiet = MercurySimulation(seed: seed, gains: gains)
        driven.reset(to: drivenDrive)
        quiet.reset(to: quietDrive)
        driven.advance(steps: settleSteps, drive: drivenDrive)
        quiet.advance(steps: settleSteps, drive: quietDrive)

        var frames: [(top: [Double], bottom: [Double])] = []
        frames.reserveCapacity(measuredFrames)
        for _ in 0..<measuredFrames {
            driven.advance(steps: stepsPerFrame, drive: drivenDrive)
            quiet.advance(steps: stepsPerFrame, drive: quietDrive)
            let drivenGeometry = driven.geometry
            let quietGeometry = quiet.geometry
            var top = [Double](repeating: 0, count: drivenGeometry.top.count)
            var bottom = [Double](repeating: 0, count: drivenGeometry.bottom.count)
            for index in 0..<top.count {
                top[index] = Double(drivenGeometry.top[index]) - Double(quietGeometry.top[index])
                bottom[index] = Double(drivenGeometry.bottom[index]) - Double(quietGeometry.bottom[index])
            }
            frames.append((top, bottom))
        }
        return frames
    }

    /// In-body `radiance * Fresnel` triples for one room, pooled over the two poses the
    /// island actually spends its time in.
    ///
    /// Both, not one: metering only the listening body landed *its* median on target and
    /// left the speaking body — the one a reader watches — anywhere from 0.04 to 0.46
    /// across four rooms, because a taller ridge with deeper crests sweeps a different
    /// part of the room. The body carries the session's own seed, so the room is metered
    /// against the body it will light rather than against a stand-in.
    ///
    /// Sampled once through the shipping crown and conductor path, then solved in closed
    /// form. The room is static, so the response remains valid for the whole session.
    private static func sceneRadianceSamples(
        gains: MercuryGains,
        environment: MercuryEnvironment,
        seed: UInt64
    ) -> [SIMD3<Float>] {

        let rasterizer = MercuryRasterizer()
        var samples: [SIMD3<Float>] = []
        for speaking in [false, true] {
            let pose = pose(speaking: speaking)
            let levels = speaking ? speakingSamples : listeningSamples
            let drive = MercurySimulation.Drive(pose: pose, samples: levels, reduceMotion: false)
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: drive)
            simulation.advance(steps: settleSteps, drive: drive)
            let collected = rasterizer.sampleSceneRadiance(
                field: MercuryField(geometry: simulation.geometry, lateralOffset: pose.lateralOffset),
                environment: environment,
                scale: MercuryMetrics.rasterScale
            )
            // Every fourth pixel: the median of a stride is the median, and the full set
            // would make this the slowest thing that happens when a session starts.
            samples.append(contentsOf: stride(from: 0, to: collected.count, by: 4).map { collected[$0] })
        }
        return samples
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
