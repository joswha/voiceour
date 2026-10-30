import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// The three solved constants, asserted rather than trusted.
///
/// A bisection that quietly walks into a flat region, or a bracket that never contained
/// the root, returns a number that looks exactly like a converged answer. The whole point
/// of solving these instead of typing them is lost unless something checks what was
/// actually achieved.
@MainActor
struct MercuryCalibrationTests {
    /// Measured as the drive was solved: under live speech from `MercurySpeechMeter`, a new
    /// level every 40 ms, and with the contact line on, which moves the top edge too.
    @Test func theDrivenCrestReachesItsTargetProminence() {
        let achieved = MercuryCalibration.shared.crestProminence
        let target = MercuryMetrics.targetCrestProminence
        #expect(abs(achieved - target) <= 0.1 * target, "solved prominence \(achieved) pt")
        #expect(MercuryCalibration.shared.gains.drive > 0)
    }

    /// The gate the design states, met as a consequence of solving for independent edges
    /// rather than solved against directly — see `MercuryCalibration.solveSnakeGain`. Measured
    /// in the quiet room held still, where a loop of it would leave the solve no root.
    @Test func theVoiceDrivenEdgesAreIndependent() {
        let achieved = MercuryCalibration.shared.mirrorCorrelation
        #expect(achieved <= MercuryMetrics.targetMirrorCorrelation, "solved correlation \(achieved)")
        // A degenerate zero would delete the contact-line family from the voice response
        // entirely, which is the failure the solve exists to avoid.
        #expect(MercuryCalibration.shared.gains.snake > 0)
    }

    /// The bounded response is per room, so every session lands on the same median
    /// without letting any finite radiance reach white.
    @Test(arguments: MercuryWorld.allCases)
    func everyRoomIsMeteredToTheSameMedian(world: MercuryWorld) {
        let calibration = MercuryCalibration.shared
        for seed in [UInt64(2), 19, MercuryMetrics.defaultSeed] {
            let environment = MercuryEnvironment(world: world, seed: seed)
            environment.advance(steps: 120, frozen: false)
            let achieved = calibration.displayLuminance(for: environment, bodySeed: seed, layout: .island)
            let response = calibration.displayResponse(for: environment, bodySeed: seed, layout: .island)
            #expect(
                abs(achieved - MercuryMetrics.targetDisplayLuminance) <= 0.02,
                "\(world.rawValue) seed \(seed) metered to \(achieved)"
            )
            #expect(response.exponent > 0)
            #expect(response.ceiling == MercuryMetrics.displayCeiling)
        }
    }

    /// A collar is metered on its own bodies: the listening and speaking collars of the
    /// housing it is worn on, which show only the outer half of a chin and walls and so sweep
    /// a different part of the room than the island's whole crown. Their pooled median lands
    /// on the target as the island's does, and the response that puts it there is not the
    /// island's.
    @Test(arguments: [OverlayDisplay.fixtureNotch, .fixtureWideNotch])
    func everyCollarIsMeteredOnItsOwnBodies(display: OverlayDisplay) {
        let calibration = MercuryCalibration.shared
        let collar = RecordingOverlayLayout.forDisplay(display)
        #expect(collar.kind == .collar)
        for world in MercuryWorld.allCases {
            for seed in [UInt64(2), 19, MercuryMetrics.defaultSeed] {
                let environment = MercuryEnvironment(world: world, seed: seed)
                let achieved = calibration.displayLuminance(for: environment, bodySeed: seed, layout: collar)
                #expect(
                    abs(achieved - MercuryMetrics.targetDisplayLuminance) <= 0.01,
                    "\(display.id) \(world.rawValue) seed \(seed) metered to \(achieved)"
                )
                let response = calibration.displayResponse(for: environment, bodySeed: seed, layout: collar)
                #expect(response != calibration.displayResponse(for: environment, bodySeed: seed, layout: .island))
                #expect(response.ceiling == MercuryMetrics.displayCeiling)
            }
        }
    }
}
