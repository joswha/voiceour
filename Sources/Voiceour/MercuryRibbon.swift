import AppKit
import SwiftUI
import VoiceCore

/// The drawn silhouette, published to the AppKit panel.
///
/// The only object shared between the SwiftUI view and `RecordingOverlayHostingView`.
/// It exists because the panel routes the mouse and the view draws the pixels, and those
/// two must agree on where the body is to the pixel — so they read the same field, built
/// from the same geometry, rather than two descriptions of it.
@MainActor
final class MercuryHitRegion {
    private var field: MercuryField?

    /// Empty: every click passes straight through to whatever is underneath.
    func clear() {
        field = nil
    }

    func update(_ field: MercuryField) {
        self.field = field
    }

    /// `point` is in the hosting view's own flipped, panel-local space — the space
    /// `RecordingOverlayMetrics.islandRect(in:)` is written in.
    func contains(_ point: CGPoint, in bounds: CGRect, slop: CGFloat) -> Bool {
        guard let field else { return false }
        let island = RecordingOverlayMetrics.islandRect(in: bounds)
        let local = CGPoint(x: point.x - island.midX, y: island.midY - point.y)
        return field.value(at: local) >= -slop
    }
}

/// Owns the exact 120 Hz body simulation, static room and process-built optical tables.
/// The display-link view supplies an integer substep count and consumes the returned
/// `CGImage` directly; no animation tick is published through SwiftUI.
@MainActor
final class MercuryEngine {
    private struct PinnedFrame: Equatable {
        var step: Int
        var seed: UInt64
        var world: MercuryWorld
        var drive: MercurySimulation.Drive
        var appearance: MercuryAppearance
    }

    private struct RenderedFrame: Equatable {
        var geometry: MercurySimulation.Geometry
        var lateralOffset: CGFloat
        var seed: UInt64
        var world: MercuryWorld
        var appearance: MercuryAppearance
    }

    private struct Lighting {
        var environment: MercuryEnvironment
        var response: MercuryDisplayResponse
    }

    private let hitRegion: MercuryHitRegion
    private var simulation: MercurySimulation
    private let rasterizer = MercuryRasterizer()
    private var lighting: Lighting
    private var seed: UInt64
    private var started = false
    private var pinned: PinnedFrame?
    private var pinnedImage: CGImage?
    private var rendered: RenderedFrame?
    private var renderedImage: CGImage?

    init(seed: UInt64, world: MercuryWorld, hitRegion: MercuryHitRegion) {
        self.hitRegion = hitRegion
        self.seed = seed
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        lighting = Self.makeLighting(world: world, seed: seed)
    }

    /// Harness frame after exactly `step` closed-form substeps from rest.
    func pinnedFrame(
        step: Int,
        seed: UInt64,
        world: MercuryWorld,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance
    ) -> CGImage? {
        let key = PinnedFrame(
            step: step,
            seed: seed,
            world: world,
            drive: drive,
            appearance: appearance
        )
        guard key != pinned else { return pinnedImage }
        pinned = key
        self.seed = seed
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        lighting = Self.makeLighting(world: world, seed: seed)
        simulation.reset(to: drive)
        simulation.advance(steps: step, drive: drive)
        pinnedImage = image(
            geometry: simulation.geometry,
            lateralOffset: drive.pose.lateralOffset,
            appearance: appearance
        )
        return pinnedImage
    }

    /// One display-linked frame. `steps` is already expressed in the immutable 120 Hz
    /// physics clock by `MercuryFramePacer`; no wall clock enters the simulation.
    func frame(
        advancing steps: Int,
        seed: UInt64,
        world: MercuryWorld,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance
    ) -> CGImage? {
        reseedIfNeeded(seed: seed, world: world)
        if !started {
            simulation.reset(to: drive)
            started = true
        } else if steps > 0 {
            simulation.advance(
                steps: Swift.min(steps, MercuryMetrics.maxSubstepsPerFrame),
                drive: drive
            )
        }

        let geometry = simulation.geometry
        let key = RenderedFrame(
            geometry: geometry,
            lateralOffset: drive.pose.lateralOffset,
            seed: seed,
            world: world,
            appearance: appearance
        )
        guard key != rendered else { return renderedImage }
        rendered = key
        renderedImage = image(
            geometry: geometry,
            lateralOffset: drive.pose.lateralOffset,
            appearance: appearance
        )
        return renderedImage
    }

    private func image(
        geometry: MercurySimulation.Geometry,
        lateralOffset: CGFloat,
        appearance: MercuryAppearance
    ) -> CGImage? {
        let field = MercuryField(geometry: geometry, lateralOffset: lateralOffset)
        guard field.boundingBox.width > 0, field.boundingBox.height > 0 else {
            hitRegion.clear()
            return nil
        }
        hitRegion.update(field)
        return rasterizer.image(
            field: field,
            environment: lighting.environment,
            response: lighting.response,
            appearance: appearance,
            scale: MercuryMetrics.rasterScale
        )
    }

    private func reseedIfNeeded(seed: UInt64, world: MercuryWorld) {
        guard seed != self.seed || world != lighting.environment.world else { return }
        self.seed = seed
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        lighting = Self.makeLighting(world: world, seed: seed)
        started = false
        rendered = nil
        renderedImage = nil
    }

    private static func makeLighting(world: MercuryWorld, seed: UInt64) -> Lighting {
        let environment = MercuryEnvironment(world: world, seed: seed)
        return Lighting(
            environment: environment,
            response: MercuryCalibration.shared.displayResponse(
                for: environment,
                bodySeed: seed
            )
        )
    }
}

/// The recording island's whole visible surface: one procedural mercury body.
///
/// The body renders below SwiftUI on a view-bound display link: 120 fps on ProMotion,
/// 60 fps on a 60 Hz screen, and no callbacks while hidden or off-display.
struct MercuryRibbon: View {
    @ObservedObject var model: RecordingOverlayModel
    let hitRegion: MercuryHitRegion
    let world: @MainActor () -> MercuryWorld
    let seed: @MainActor () -> UInt64
    private var a11y = A11y()

    @MainActor
    init(
        model: RecordingOverlayModel,
        hitRegion: MercuryHitRegion,
        world: @escaping @MainActor () -> MercuryWorld,
        seed: @escaping @MainActor () -> UInt64
    ) {
        self.model = model
        self.hitRegion = hitRegion
        self.world = world
        self.seed = seed
    }

    var body: some View {
        MercurySurface(
            configuration: MercurySurfaceView.Configuration(
                seed: seed(),
                world: world(),
                drive: MercurySimulation.Drive(
                    pose: MercuryPose.target(for: model),
                    samples: model.samples,
                    reduceMotion: a11y.reduceMotion
                ),
                appearance: MercuryAppearance(
                    increasedContrast: a11y.contrast == .increased
                ),
                pinnedStep: RenderOverrides.mercuryStep
            ),
            hitRegion: hitRegion
        )
        .frame(
            width: RecordingOverlayMetrics.islandSize.width,
            height: RecordingOverlayMetrics.islandSize.height
        )
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
