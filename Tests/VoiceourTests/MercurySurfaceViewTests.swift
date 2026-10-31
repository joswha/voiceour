import CoreGraphics
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// A surface without a window has no display link, so these drive it the way SwiftUI and the
/// link do: configurations through `update(_:)`, link callbacks through `renderLive(steps:)`.
///
/// The drives hold Reduce Motion on, so a surface's first live frame places the body at rest on
/// its pose, as a fresh engine's does, instead of growing it out of nothing.
@MainActor
struct MercurySurfaceViewTests {
    // MARK: - Suspension

    /// No later look, pinned step or link callback draws over the image a surface kept when
    /// it was suspended.
    @Test func aSuspendedSurfaceKeepsItsLastImage() throws {
        let view = MercurySurfaceView(seed: 40, look: .stock, hitRegion: MercuryHitRegion())
        var configuration = Self.stockConfiguration(seed: 40, drive: Self.speakingDrive())
        view.update(configuration)
        view.renderLive(steps: 2)
        let kept = try #require(view.currentImage)

        configuration.isSuspended = true
        view.update(configuration)
        view.renderLive(steps: 2)
        #expect(view.currentImage === kept)

        configuration.look = MercuryLook(island: IslandLook.neonKit.appearance)
        view.update(configuration)
        view.renderLive(steps: 2)
        #expect(view.currentImage === kept)

        configuration.pinnedStep = 600
        view.update(configuration)
        #expect(view.currentImage === kept)
    }

    /// The update that clears suspension under a pinned step draws the current look's still
    /// at once, the bytes a fresh engine pins.
    @Test func resumingAPinnedSurfaceDrawsTheCurrentLookAtOnce() throws {
        let drive = Self.speakingDrive()
        let neon = MercuryLook(island: IslandLook.neonKit.appearance)
        let view = MercurySurfaceView(seed: 41, look: .stock, hitRegion: MercuryHitRegion())
        var configuration = Self.stockConfiguration(seed: 41, drive: drive)
        configuration.pinnedStep = 600
        view.update(configuration)
        configuration.isSuspended = true
        view.update(configuration)
        configuration.look = neon
        view.update(configuration)

        configuration.isSuspended = false
        view.update(configuration)

        let image = try #require(view.currentImage)
        let fresh = MercuryEngine(seed: 41, look: neon, hitRegion: MercuryHitRegion())
        let expected = try #require(
            fresh.pinnedFrame(
                step: 600,
                seed: 41,
                look: neon,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        #expect(Self.bytes(image) == Self.bytes(expected))
    }

    /// The update that clears suspension on a live surface draws the current look at once,
    /// with no link callback: on a surface that started out of view and never drew, and over
    /// the image of an earlier look. Either way the bytes are a fresh engine's first frame.
    @Test func resumingALiveSurfaceDrawsTheCurrentLookAtOnce() throws {
        let drive = Self.speakingDrive()
        // Under the stock tune the resting body is the one a fresh engine settles, so only the
        // light differs from the look drawn before.
        var neon = MercuryLook(island: IslandLook.neonKit.appearance)
        neon.tune = .stock
        let view = MercurySurfaceView(seed: 42, look: .stock, hitRegion: MercuryHitRegion())
        var configuration = Self.stockConfiguration(seed: 42, drive: drive)
        configuration.isSuspended = true
        view.update(configuration)
        #expect(view.currentImage == nil)

        configuration.isSuspended = false
        view.update(configuration)
        let first = try #require(view.currentImage)
        let firstExpected = try Self.firstFrame(seed: 42, look: .stock, drive: drive)
        #expect(Self.bytes(first) == firstExpected)

        configuration.isSuspended = true
        view.update(configuration)
        configuration.look = neon
        view.update(configuration)
        configuration.isSuspended = false
        view.update(configuration)
        let resumed = try #require(view.currentImage)
        let resumedExpected = try Self.firstFrame(seed: 42, look: neon, drive: drive)
        #expect(Self.bytes(resumed) == resumedExpected)
    }

    // MARK: - Fixtures

    /// Seen and stock with no step pinned on the island: the showroom's stage in view before
    /// any control moves.
    private static func stockConfiguration(
        seed: UInt64,
        drive: MercurySimulation.Drive
    ) -> MercurySurfaceView.Configuration {
        MercurySurfaceView.Configuration(
            seed: seed,
            look: .stock,
            drive: drive,
            appearance: .standard,
            layout: .island,
            pinnedStep: nil
        )
    }

    /// What a fresh engine draws first: the body at rest in `drive`, under `look`.
    private static func firstFrame(
        seed: UInt64,
        look: MercuryLook,
        drive: MercurySimulation.Drive
    ) throws -> Data {
        let engine = MercuryEngine(seed: seed, look: look, hitRegion: MercuryHitRegion())
        let image = try #require(
            engine.frame(
                advancing: 0,
                seed: seed,
                look: look,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        return bytes(image)
    }

    /// The speaking island under Reduce Motion, from the model the island's own drive reads.
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
        return .target(for: model, reduceMotion: true)
    }

    private static func bytes(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }
}
