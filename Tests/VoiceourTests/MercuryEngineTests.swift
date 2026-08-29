import CoreGraphics
import Foundation
import Testing

@testable import Voiceour

@MainActor
struct MercuryEngineTests {
    @Test func reseedingRebuildsTheBodyAndLightingTogether() throws {
        let drive = Self.speakingDrive()
        let reused = MercuryEngine(
            seed: 1,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        _ = reused.pinnedFrame(
            step: 600,
            seed: 1,
            world: .roomOfTen,
            drive: drive,
            appearance: .standard
        )
        let reseeded = try #require(
            reused.pinnedFrame(
                step: 600,
                seed: 2,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )

        let fresh = MercuryEngine(
            seed: 2,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let expected = try #require(
            fresh.pinnedFrame(
                step: 600,
                seed: 2,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )

        #expect(Self.bytes(reseeded) == Self.bytes(expected))
    }

    @Test func livePresentationRendersEveryCommittedStepAndCachesDuplicates() throws {
        let drive = Self.speakingDrive()
        let engine = MercuryEngine(
            seed: 7,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let first = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )
        let duplicate = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )
        let next = try #require(
            engine.frame(
                advancing: 1,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )

        #expect(first === duplicate)
        #expect(first !== next)
    }

    @Test func appearanceChangesAlwaysRerasterTheCurrentGeometry() throws {
        let drive = Self.speakingDrive()
        let engine = MercuryEngine(
            seed: 9,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let standard = try #require(
            engine.frame(
                advancing: 0,
                seed: 9,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard
            )
        )
        let increased = try #require(
            engine.frame(
                advancing: 0,
                seed: 9,
                world: .roomOfTen,
                drive: drive,
                appearance: MercuryAppearance(increasedContrast: true)
            )
        )

        #expect(standard !== increased)
    }

    private static func speakingDrive() -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in [
            0.08, 0.19, 0.34, 0.52, 0.71, 0.88,
            0.64, 0.41, 0.27, 0.15, 0.46,
        ] as [Float] {
            model.record(level)
        }
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: false
        )
    }

    private static func bytes(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }
}
