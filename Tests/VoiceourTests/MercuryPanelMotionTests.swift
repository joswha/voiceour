import AppKit
import Testing

@testable import Voiceour

/// The forcing the body feels from its panel: the panel's acceleration by finite differences on the
/// substep clock, and the tether's pull on a docked body.
@MainActor
struct MercuryPanelMotionTests {
    /// Substeps per presented frame at 120, 60, 75 and 48 Hz.
    nonisolated static let cadences: [[Int]] = [[1], [2], [1, 2], [2, 3]]

    /// Carried at a steady speed the body feels nothing, however the frames divide the substeps: only
    /// the frame that set the panel moving from rest is an acceleration.
    @Test(arguments: MercuryPanelMotionTests.cadences)
    func aConstantVelocityDragIsFeltAsNothing(cadence: [Int]) {
        let velocity = SIMD2(640.0, -230.0)
        var acceleration = MercuryPanelAcceleration(at: SIMD2(400, 500))
        var substeps = 0
        for frame in 0..<60 {
            let steps = cadence[frame % cadence.count]
            substeps += steps
            let felt = acceleration.advance(
                to: SIMD2(400, 500) + velocity * (Double(substeps) * MercuryMetrics.substep),
                steps: steps
            )
            if frame == 0 {
                #expect(felt != SIMD2())
            } else {
                #expect(abs(felt.x) < 1e-6 && abs(felt.y) < 1e-6, "frame \(frame)")
            }
        }
    }

    /// A panel accelerating steadily is felt as exactly its acceleration, at every cadence, once the
    /// first frame has measured it from rest; past the body shape's clamp it is the clamp.
    @Test(arguments: MercuryPanelMotionTests.cadences)
    func anAccelerationIsFeltAsItselfHeldToTheClamp(cadence: [Int]) {
        for (constant, felt) in [
            (SIMD2(3_000.0, -12_500.0), SIMD2(3_000.0, -12_500.0)),
            (SIMD2(90_000.0, -55_000.0), SIMD2(40_000.0, -40_000.0)),
        ] {
            var acceleration = MercuryPanelAcceleration(at: SIMD2())
            var substeps = 0
            for frame in 0..<40 {
                let steps = cadence[frame % cadence.count]
                substeps += steps
                let time = Double(substeps) * MercuryMetrics.substep
                let measured = acceleration.advance(to: constant * (time * time / 2), steps: steps)
                guard frame > 0 else { continue }
                #expect(abs(measured.x - felt.x) < 1e-6, "frame \(frame)")
                #expect(abs(measured.y - felt.y) < 1e-6, "frame \(frame)")
            }
        }
    }

    /// The sign is the panel's own, the one `MercuryBodyShape.Forcing` is written against: a panel
    /// accelerating right leaves its body behind, to the left, and its stop throws the body forward.
    @Test func theBodyLagsThePanelThatCarriesIt() {
        var acceleration = MercuryPanelAcceleration(at: SIMD2())
        var shape = MercuryBodyShape()
        let target = MercuryBodyShape.Target(length: 140, halfHeight: 9.3, sway: 0, skew: 0, neck: 0)
        let limits = MercuryBodyShape.Limits(maxLength: 168, maxHalfHeight: 13.24, maxSway: 12)
        shape.reset(to: target, limits: limits)
        var position = 0.0
        var velocity = 0.0
        var leastSway = 0.0
        var greatestSway = 0.0
        for substep in 0..<90 {
            // 0.25 s at 4 000 pt/s² to the right, then held still.
            if substep < 30 {
                velocity += 4_000 * MercuryMetrics.substep
            } else {
                velocity = 0
            }
            position += velocity * MercuryMetrics.substep
            let felt = acceleration.advance(to: SIMD2(position, 0), steps: 1)
            let axes = RecordingOverlayLayout.island.bodyAxes.resolve(felt)
            shape.step(
                toward: target,
                limits: limits,
                forcing: MercuryBodyShape.Forcing(tangentialAcceleration: axes.x, normalAcceleration: axes.y),
                reduceMotion: false
            )
            if substep < 30 {
                leastSway = min(leastSway, shape.sway)
            } else {
                greatestSway = max(greatestSway, shape.sway)
            }
        }
        #expect(leastSway < -0.5)
        #expect(greatestSway > 0.5)
    }

    /// A frame that advances nothing measures nothing; a re-frame the body must not feel is
    /// restarted from, and a move it must feel is felt, through the clamp.
    @Test func restartsAreNotFeltAndMovesAre() {
        let motion = MercuryPanelMotion()
        let island = RecordingOverlayLayout.island
        motion.restart(at: CGPoint(x: 100, y: 100))
        motion.move(to: CGPoint(x: 160, y: 100))
        #expect(motion.forcing(advancing: 0, layout: island) == .none)
        let jump = motion.forcing(advancing: 1, layout: island)
        #expect(jump.tangentialAcceleration == MercuryBodyShape.maxFrameAcceleration)
        #expect(jump.normalAcceleration == 0)

        motion.restart(at: CGPoint(x: 900, y: 40))
        #expect(motion.forcing(advancing: 2, layout: island) == .none)
        #expect(motion.forcing(advancing: 2, layout: island) == .none)
    }

    /// Each layout resolves the panel's acceleration onto its own axes: on the collar's bottom run
    /// the normal points down, out of the housing, so a panel accelerating up is a negative normal
    /// acceleration there. The tether's pull adds to it.
    @Test func theForcingIsResolvedOntoTheLayoutsAxes() throws {
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        #expect(collar.bodyAxes == RecordingOverlayLayout.BodyAxes(tangent: SIMD2(1, 0), normal: SIMD2(0, -1)))
        #expect(
            RecordingOverlayLayout.island.bodyAxes
                == RecordingOverlayLayout.BodyAxes(tangent: SIMD2(1, 0), normal: SIMD2(0, 1))
        )

        let motion = MercuryPanelMotion()
        motion.restart(at: .zero)
        let substep = MercuryMetrics.substep
        // 1 000 pt/s² up: half of it travelled in the first substep, all of it by the second.
        motion.move(to: CGPoint(x: 0, y: 500 * substep * substep))
        _ = motion.forcing(advancing: 1, layout: collar)
        motion.move(to: CGPoint(x: 0, y: 2_000 * substep * substep))
        let up = motion.forcing(advancing: 1, layout: collar)
        #expect(abs(up.normalAcceleration + 1_000) < 1e-6)
        #expect(abs(up.tangentialAcceleration) < 1e-9)

        // The tether's pull on a collar 12 pt right and 8 pt down, out of its housing, with the panel
        // accelerating up at 1 000 pt/s² again as it is pulled.
        motion.restart(at: .zero)
        motion.band = RecordingOverlayDrag.bandForcing(pull: collar.bodyAxes.resolve(SIMD2(12, -8)))
        motion.move(to: CGPoint(x: 0, y: 500 * substep * substep))
        _ = motion.forcing(advancing: 1, layout: collar)
        motion.move(to: CGPoint(x: 0, y: 2_000 * substep * substep))
        let pulled = motion.forcing(advancing: 1, layout: collar)
        #expect(abs(pulled.tangentialAcceleration + 10_000) < 1e-6)
        #expect(abs(pulled.normalAcceleration - (-RecordingOverlayDrag.bandStiffness * 8 - 1_000)) < 1e-6)
    }

    /// The tether at the tear-off distance settles a body that has room at the 6 pt of a full lean,
    /// within 0.05 pt after 3 s, and Reduce Motion takes it there without passing it. The speaking
    /// island has 4 pt of track either way and leans to its end, as a full window lean does.
    @Test(arguments: [false, true])
    func theTetherAtTheTearOffSettlesTheLeanAtSixPoints(reduceMotion: Bool) {
        let pull = SIMD2(Double(RecordingOverlayDrag.tearOffDistance), 0)
        for (layout, speaking, settled) in [
            (RecordingOverlayLayout.forDisplay(.fixtureNotch), true, MercuryMetrics.leanSway),
            (RecordingOverlayLayout.island, false, MercuryMetrics.leanSway),
            (RecordingOverlayLayout.island, true, 4.0),
        ] {
            let model = Self.session(on: layout, speaking: speaking)
            let motion = MercuryPanelMotion()
            motion.restart(at: .zero)
            motion.band = RecordingOverlayDrag.bandForcing(pull: layout.bodyAxes.resolve(pull))
            var drive = MercurySimulation.Drive.target(for: model, reduceMotion: reduceMotion)
            let simulation = MercurySimulation(seed: 21, gains: MercuryGains(drive: 1, snake: 0.011))
            simulation.reset(to: drive)
            var furthest = 0.0
            for _ in 0..<360 {
                drive.forcing = motion.forcing(advancing: 1, layout: layout)
                simulation.advance(steps: 1, drive: drive)
                furthest = max(furthest, Double(simulation.geometry.lateralOffset))
            }
            let sway = Double(simulation.geometry.lateralOffset)
            #expect(abs(sway - settled) < 0.05, "\(layout.kind), speaking \(speaking): \(sway)")
            if reduceMotion {
                #expect(furthest <= settled + 1e-9, "\(layout.kind), speaking \(speaking): \(furthest)")
            }
        }
    }

    /// A live session on `layout`, listening, or speaking on the syllable meter.
    private static func session(on layout: RecordingOverlayLayout, speaking: Bool) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.recording)
        model.updateCaptureLive(true)
        if speaking {
            for level in MercurySpeechMeter.syllable {
                model.record(level)
            }
        }
        return model
    }
}
