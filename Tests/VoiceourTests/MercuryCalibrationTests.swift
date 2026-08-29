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
    @Test func theDrivenCrestReachesItsTargetProminence() {
        let achieved = MercuryCalibration.shared.crestProminence
        let target = MercuryMetrics.targetCrestProminence
        #expect(abs(achieved - target) <= 0.1 * target, "solved prominence \(achieved) pt")
        #expect(MercuryCalibration.shared.gains.drive > 0)
    }

    /// The gate the design states, met as a consequence of solving for independent edges
    /// rather than solved against directly — see `MercuryCalibration.solveSnakeGain`.
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
            let achieved = calibration.displayLuminance(for: environment, bodySeed: seed)
            let response = calibration.displayResponse(for: environment, bodySeed: seed)
            #expect(
                abs(achieved - MercuryMetrics.targetDisplayLuminance) <= 0.02,
                "\(world.rawValue) seed \(seed) metered to \(achieved)"
            )
            #expect(response.exponent > 0)
            #expect(response.ceiling == MercuryMetrics.displayCeiling)
        }
    }
}
