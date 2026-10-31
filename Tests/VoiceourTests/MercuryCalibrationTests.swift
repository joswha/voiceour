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

    /// The bounded response is per room, per look and per layout, so every session lands on
    /// its own look's median, under the island's p98 highlight anchor or the collar's p99. The
    /// look reaches the metering whole: its tuned, body-kitted bodies under its paint, in its
    /// room, to its tone's targets.
    @Test(arguments: IslandLook.allCases)
    func everyLookIsMeteredToItsOwnMedianOnEveryLayout(island: IslandLook) {
        let calibration = MercuryCalibration.shared
        let look = MercuryLook(island: island.appearance)
        let target = MercuryToneAnchors.targets(
            albedo: MercuryPaintLookup.lookup(for: look.paint).albedo,
            tone: look.tone,
            underglowStrength: look.underglowStrength
        ).median
        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            for seed in [UInt64(2), 19, MercuryMetrics.defaultSeed] {
                let environment = MercuryEnvironment(
                    world: look.world,
                    seed: seed,
                    lighting: look.lighting
                )
                let achieved = calibration.displayLuminance(
                    for: environment,
                    bodySeed: seed,
                    layout: layout,
                    look: look
                )
                #expect(
                    abs(achieved - target) <= 0.02,
                    "\(island.rawValue) \(layout.kind) seed \(seed) metered to \(achieved), target \(target)"
                )
            }
        }
    }

    /// A look's response is solved on the look's own scene: its paint and its tuned,
    /// body-kitted bodies move the metered scene anchors, while its tone moves only the
    /// targets those anchors are solved to.
    @Test(arguments: [OverlayDisplay.fixtureNotchless, .fixtureNotch])
    func aLookMetersItsOwnPaintAndBodiesWhileItsToneMovesOnlyTheTargets(display: OverlayDisplay) {
        let calibration = MercuryCalibration.shared
        let layout = RecordingOverlayLayout.forDisplay(display)
        let seed = MercuryMetrics.defaultSeed
        let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
        func response(_ look: MercuryLook) -> MercuryDisplayResponse {
            calibration.displayResponse(for: room, bodySeed: seed, layout: layout, look: look)
        }
        let stock = response(.stock)
        var gold = MercuryLook.stock
        gold.paint.metal = .gold
        var rounder = MercuryLook.stock
        rounder.tune.crownAspect = MercuryTune.crownAspectRange.upperBound
        var smaller = MercuryLook.stock
        smaller.tune.size = MercuryTune.sizeRange.lowerBound
        for (name, look) in [("gold", gold), ("rounder crown", rounder), ("smaller body", smaller)] {
            let metered = response(look)
            let moved = metered.sceneMedian != stock.sceneMedian || metered.sceneHighlight != stock.sceneHighlight
            #expect(moved, "\(display.id) \(name)")
        }

        var brighter = MercuryLook.stock
        brighter.tone.brightness = 0.5
        let toned = response(brighter)
        #expect(toned.sceneMedian == stock.sceneMedian)
        #expect(toned.sceneHighlight == stock.sceneHighlight)
        #expect(toned != stock)
    }

    /// The looks are the per-room coverage: both rooms are user choices and must meter.
    @Test func theLooksCoverEveryRoom() {
        let rooms = Set(IslandLook.allCases.map { MercuryLook(island: $0.appearance).world })
        #expect(rooms == Set(MercuryWorld.allCases))
    }

    /// Stock meters to the shipped constants themselves, so its response and bytes cannot
    /// move.
    @Test func stockAnchorsAreTheShippedTargets() {
        let anchors = MercuryToneAnchors.targets(
            albedo: MercuryPaintLookup.stock.albedo,
            tone: .stock,
            underglowStrength: 0
        )
        #expect(anchors.median == MercuryMetrics.targetDisplayLuminance)
        #expect(anchors.highlight == MercuryMetrics.targetHighlightLuminance)
        #expect(anchors.median == 0.32)
        #expect(anchors.highlight == 0.87)
        #expect(MercuryLook.stock.underglowStrength == 0)
    }

    /// Half the albedo difference, half a stop of brightness, a floor that rises with the
    /// underglow, a ceiling below every highlight, and contrast on the highlight alone.
    @Test func toneAnchorsFollowTheMaterialAndTheTone() {
        let mercury = MercuryPaintLookup.stock.albedo
        func anchors(
            albedo: Double = mercury,
            brightness: Double = 0,
            contrast: Double = 0,
            underglow: Double = 0
        ) -> (median: Double, highlight: Double) {
            MercuryToneAnchors.targets(
                albedo: albedo,
                tone: MercuryTone(brightness: brightness, contrast: contrast),
                underglowStrength: underglow
            )
        }
        #expect(abs(anchors(albedo: 1.21 * mercury).median - 0.32 * 1.1) < 1e-12)
        #expect(abs(anchors(albedo: 0.81 * mercury).median - 0.32 * 0.9) < 1e-12)
        #expect(abs(anchors(brightness: 0.4).median - 0.32 * exp2(0.2)) < 1e-12)
        #expect(anchors(brightness: 1).median == 0.41)
        #expect(anchors(brightness: -1).median == 0.28)
        #expect(abs(anchors(brightness: -1, underglow: 1).median - 0.35) < 1e-12)
        #expect(abs(anchors(contrast: 1).highlight - 0.895) < 1e-12)
        #expect(abs(anchors(contrast: -1).highlight - 0.845) < 1e-12)
        #expect(anchors(contrast: 1).median == anchors().median)
        #expect(anchors(contrast: 5).highlight == anchors(contrast: 1).highlight)
        #expect(anchors(contrast: 5).highlight < MercuryMetrics.displayCeiling)
    }
}
