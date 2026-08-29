import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// The body's law, held to the four properties the design depends on: it replays, it
/// cannot leave the island, its two edges are not mirrors of each other, and Reduce
/// Motion stops the shimmer without stopping the information.
@MainActor
struct MercurySimulationTests {
    private static let gains = MercuryGains(drive: 1, snake: 0.011)

    private static func model(_ levels: [Float], live: Bool = true) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(live)
        for level in levels {
            model.record(level)
        }
        return model
    }

    private static func drive(
        _ levels: [Float],
        live: Bool = true,
        reduceMotion: Bool = false
    ) -> MercurySimulation.Drive {
        let model = model(levels, live: live)
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: reduceMotion
        )
    }

    private static let speaking: [Float] = [0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46]
    private static let quiet: [Float] = [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]

    /// Counter-based noise means the state after N substeps cannot depend on how those
    /// substeps were batched. That is what lets a harness frame be pinned to a step index
    /// and a 24 Hz machine draw the same body a 120 Hz one does.
    @Test func advancingIsReplayableAndBatchIndependent() {
        let drive = Self.drive(Self.speaking)

        let first = MercurySimulation(seed: 7, gains: Self.gains)
        let second = MercurySimulation(seed: 7, gains: Self.gains)
        let batched = MercurySimulation(seed: 7, gains: Self.gains)
        for simulation in [first, second, batched] {
            simulation.reset(to: drive)
        }

        first.advance(steps: 600, drive: drive)
        second.advance(steps: 600, drive: drive)
        for _ in 0..<6 {
            batched.advance(steps: 100, drive: drive)
        }

        #expect(first.geometry.top == second.geometry.top)
        #expect(first.geometry.bottom == second.geometry.bottom)
        #expect(first.geometry.top == batched.geometry.top)
        #expect(first.geometry.bottom == batched.geometry.bottom)
    }

    /// A different world is a different body. Without this the "new world per session"
    /// decision would be decoration.
    @Test func differentSeedsProduceDifferentBodies() {
        let drive = Self.drive(Self.speaking)
        let first = MercurySimulation(seed: 7, gains: Self.gains)
        let second = MercurySimulation(seed: 8, gains: Self.gains)
        first.reset(to: drive)
        second.reset(to: drive)
        first.advance(steps: 300, drive: drive)
        second.advance(steps: 300, drive: drive)

        #expect(first.geometry.top != second.geometry.top)
    }

    /// The containment gauge is a proof, not a hope: `Theta` bounds `|theta|` exactly, so
    /// no drive can push the drawn body past the island. Adversarial inputs included,
    /// because a meter buffer is whatever the room hands it.
    @Test(arguments: [
        [Float](repeating: 0, count: 11),
        [Float](repeating: 1, count: 11),
        [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
        [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0],
        [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    ])
    func theBodyNeverLeavesTheIsland(levels: [Float]) {
        let drive = Self.drive(levels)
        for seed in [UInt64(1), 7, 0x5155_4943_4B53_4C56] {
            let simulation = MercurySimulation(seed: seed, gains: Self.gains)
            simulation.reset(to: drive)
            for _ in 0..<900 {
                simulation.advance(steps: 1, drive: drive)
                let geometry = simulation.geometry
                #expect(geometry.length <= MercuryMetrics.maxLength)
                #expect(Double(geometry.top.max() ?? 0) <= Double(MercuryMetrics.maxHalfHeight))
                #expect(Double(geometry.bottom.min() ?? 0) >= -Double(MercuryMetrics.maxHalfHeight))
            }
        }
    }

    /// A pill is exactly +1. The two edges must be independent, which is what the
    /// contact-line family entering them with opposite sign is for.
    @Test func theTwoEdgesAreNotMirrors() {
        for levels in [Self.speaking, Self.quiet] {
            let drive = Self.drive(levels)
            let simulation = MercurySimulation(seed: 11, gains: Self.gains)
            simulation.reset(to: drive)
            simulation.advance(steps: 600, drive: drive)
            #expect(Self.mirrorCorrelation(simulation.geometry) < 0.2)
        }
    }

    /// Warming and working disconnect the voice entirely, so only the body's own
    /// autonomous life is left. Even there it must not fit an ellipse.
    @Test func theStillPosesAreNotMirrorsEither() {
        let warming = MercurySimulation.Drive(
            pose: MercuryPose.target(for: Self.model(Self.speaking, live: false)),
            samples: Self.speaking,
            reduceMotion: false
        )
        let working = MercurySimulation.Drive(
            pose: MercuryPose.target(
                for: { () -> RecordingOverlayModel in
                    let model = RecordingOverlayModel()
                    model.update(.transcribing)
                    return model
                }()),
            samples: [Float](repeating: 0, count: 11),
            reduceMotion: false
        )
        for drive in [warming, working] {
            let simulation = MercurySimulation(seed: 13, gains: Self.gains)
            simulation.reset(to: drive)
            simulation.advance(steps: 600, drive: drive)
            #expect(Self.mirrorCorrelation(simulation.geometry) < 0.8)
        }
    }

    /// Reduce Motion stops the shimmer and nothing else. A silent drive holds the body
    /// perfectly still — including the rest asymmetry, which must not decay to the
    /// mirror-symmetric capsule — and speech still moves it.
    @Test func reduceMotionStopsDecorationButNotInformation() {
        let silent = Self.drive([Float](repeating: 0, count: 11), reduceMotion: true)
        let still = MercurySimulation(seed: 17, gains: Self.gains)
        still.reset(to: silent)
        let start = still.geometry
        still.advance(steps: 300, drive: silent)
        #expect(still.geometry.top == start.top)
        #expect(still.geometry.bottom == start.bottom)
        // Never zero: zero is the mirror-symmetric minimiser, which is a capsule.
        #expect(Self.mirrorCorrelation(still.geometry) < 0.8)

        let speaking = Self.drive(Self.speaking, reduceMotion: true)
        let moving = MercurySimulation(seed: 17, gains: Self.gains)
        moving.reset(to: speaking)
        let before = moving.geometry
        moving.advance(steps: 60, drive: speaking)
        #expect(moving.geometry.top != before.top)
    }

    /// Lurch and collapse are transition gestures, not merely different settled poses.
    /// Start two bodies from the same pose with no gesture; only the one whose gesture
    /// latches may receive the one-shot mode impulse.
    @Test func outcomeImpulsesFireOnGestureEntry() {
        for state in [
            SessionState.insertFailed(reason: "no focused element"),
            .error(.inferenceFailed),
        ] {
            let model = RecordingOverlayModel()
            model.update(state)
            guard let outcome = RecordingOverlayOutcome(state: state) else {
                Issue.record("terminal state must produce an overlay outcome")
                continue
            }
            model.present(outcome)
            let transition = MercurySimulation.Drive(
                pose: MercuryPose.target(for: model),
                samples: model.samples,
                reduceMotion: true
            )
            var neutralPose = transition.pose
            neutralPose.gesture = nil
            let neutral = MercurySimulation.Drive(
                pose: neutralPose,
                samples: transition.samples,
                reduceMotion: true
            )
            let impulsed = MercurySimulation(seed: 23, gains: Self.gains)
            let control = MercurySimulation(seed: 23, gains: Self.gains)
            impulsed.reset(to: neutral)
            control.reset(to: neutral)
            impulsed.advance(steps: 2, drive: transition)
            control.advance(steps: 2, drive: neutral)

            #expect(impulsed.geometry.top != control.geometry.top)
            #expect(impulsed.geometry.bottom != control.geometry.bottom)
        }
    }

    /// The pose ladder is the only sighted channel between session states, so warm-up
    /// must differ from silent listening in kind — a compact bead versus a long lens —
    /// rather than by a few points of length.
    @Test func eachPoseIsADistinctBody() {
        let poses = [
            MercuryPose.target(for: Self.model(Self.speaking, live: false)),
            MercuryPose.target(for: Self.model(Self.quiet)),
            MercuryPose.target(for: Self.model(Self.speaking)),
        ]
        let lengths = poses.map(\.length)
        #expect(Set(lengths).count == lengths.count)
        #expect(poses[1].length - poses[0].length >= 60)
        #expect(poses[0].length / (2 * poses[0].halfHeight) <= 4.5)
        #expect(poses[1].length / (2 * poses[1].halfHeight) >= 7.5)
        for pose in poses {
            #expect(pose.length <= MercuryMetrics.maxLength)
            #expect(pose.halfHeight <= MercuryMetrics.maxHalfHeight)
        }
    }

    /// Pearson correlation of the top edge against the negated bottom edge, with the
    /// shared even envelope removed. Exactly what a capsule scores +1 on.
    static func mirrorCorrelation(_ geometry: MercurySimulation.Geometry) -> Double {
        let columns = MercuryMetrics.columns
        var upper: [Double] = []
        var lower: [Double] = []
        upper.reserveCapacity(columns + 1)
        lower.reserveCapacity(columns + 1)
        for station in 0...columns {
            let position = 2 * Double(station) / Double(columns) - 1
            let envelope =
                Double(geometry.halfHeight) * (1 - (1 - MercuryMetrics.gEnd) * position * position)
            upper.append(Double(geometry.top[station]) - envelope)
            lower.append(-Double(geometry.bottom[station]) - envelope)
        }
        return MercuryCalibration.correlation(upper, lower)
    }
}
