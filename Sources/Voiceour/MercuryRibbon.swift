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
    /// The field last drawn and the layout it was drawn in. They travel together because the
    /// field is written in that layout's canvas: a point converted through any other canvas
    /// would ask the right field about the wrong place.
    private var drawn: (field: MercuryField, layout: RecordingOverlayLayout)?

    /// Empty: every click passes straight through to whatever is underneath.
    func clear() {
        drawn = nil
    }

    func update(_ field: MercuryField, layout: RecordingOverlayLayout) {
        drawn = (field, layout)
    }

    /// `point` is in the hosting view's own flipped, panel-local space, the space
    /// `RecordingOverlayLayout.canvasRect` is written in.
    ///
    /// A point in the menu-bar band is never the body's, whatever the field says there. Menus,
    /// menu titles and status items own that strip, and the collar keeps only a film in it
    /// beside the housing, which is drawn but never claimed. The island's band is empty.
    func contains(_ point: CGPoint, slop: CGFloat) -> Bool {
        guard let drawn, point.y >= drawn.layout.bandHeight else { return false }
        let canvas = drawn.layout.canvasRect
        let local = CGPoint(x: point.x - canvas.midX, y: canvas.midY - point.y)
        return drawn.field.value(at: local) >= -slop
    }
}

/// Owns the exact 120 Hz body simulation, static room and process-built optical tables.
/// The display-link view supplies an integer substep count and the layout to draw in, and
/// consumes the returned `CGImage` directly; no animation tick is published through SwiftUI.
@MainActor
final class MercuryEngine {
    private struct PinnedFrame: Equatable {
        var step: Int
        var seed: UInt64
        var world: MercuryWorld
        var drive: MercurySimulation.Drive
        var appearance: MercuryAppearance
        var layout: RecordingOverlayLayout
    }

    private struct RenderedFrame: Equatable {
        var geometry: MercurySimulation.Geometry
        var seed: UInt64
        var world: MercuryWorld
        var appearance: MercuryAppearance
        var layout: RecordingOverlayLayout
    }

    /// The session's room and the response it is shown through, metered on the bodies
    /// `layout` draws.
    private struct Lighting {
        var environment: MercuryEnvironment
        var response: MercuryDisplayResponse
        var layout: RecordingOverlayLayout
    }

    private let hitRegion: MercuryHitRegion
    private var simulation: MercurySimulation
    private let rasterizer = MercuryRasterizer()
    private var seed: UInt64
    private var world: MercuryWorld
    /// Built for the first layout a session draws, so a session that starts on a collar
    /// never meters the island's bodies. See ``lighting(for:)``.
    private var lighting: Lighting?
    private var started = false
    private var pinned: PinnedFrame?
    private var pinnedImage: CGImage?
    private var rendered: RenderedFrame?
    private var renderedImage: CGImage?

    /// How many responses this engine has metered. Each settles two bodies and rasters them,
    /// so it is paid once for each seed, world and layout a session draws and never per
    /// frame; the tests hold the engine to that.
    private(set) var meteredResponses = 0

    /// `L·H` of the body the last live frame drew, pt²: how much mercury it shows, and what a
    /// hand-off drains before the panel may move to another display.
    private(set) var liveVolume = 0.0

    init(seed: UInt64, world: MercuryWorld, hitRegion: MercuryHitRegion) {
        self.hitRegion = hitRegion
        self.seed = seed
        self.world = world
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
    }

    /// Harness frame after exactly `step` closed-form substeps from rest.
    func pinnedFrame(
        step: Int,
        seed: UInt64,
        world: MercuryWorld,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) -> CGImage? {
        let key = PinnedFrame(
            step: step,
            seed: seed,
            world: world,
            drive: drive,
            appearance: appearance,
            layout: layout
        )
        guard key != pinned else { return pinnedImage }
        pinned = key
        if seed != self.seed || world != self.world {
            self.seed = seed
            self.world = world
            lighting = nil
        }
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        simulation.reset(to: drive)
        simulation.advance(steps: step, drive: drive)
        pinnedImage = image(
            geometry: simulation.geometry,
            appearance: appearance,
            layout: layout
        )
        return pinnedImage
    }

    /// One display-linked frame. `steps` is already expressed in the immutable 120 Hz
    /// physics clock by `MercuryClock`; no wall clock enters the simulation.
    func frame(
        advancing steps: Int,
        seed: UInt64,
        world: MercuryWorld,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) -> CGImage? {
        reseedIfNeeded(seed: seed, world: world)
        if !started {
            // A live body grows out of the notch or the top edge. Reduce Motion shows it at rest on
            // its pose instead: an emergence is motion that carries no information.
            simulation.reset(to: drive, emerging: !drive.reduceMotion)
            started = true
        } else {
            simulation.advance(
                steps: Swift.min(steps, MercuryMetrics.maxSubstepsPerFrame),
                drive: drive
            )
        }

        let geometry = simulation.geometry
        liveVolume = Double(geometry.length) * Double(geometry.halfHeight)
        let key = RenderedFrame(
            geometry: geometry,
            seed: seed,
            world: world,
            appearance: appearance,
            layout: layout
        )
        guard key != rendered else { return renderedImage }
        rendered = key
        renderedImage = image(
            geometry: geometry,
            appearance: appearance,
            layout: layout
        )
        return renderedImage
    }

    private func image(
        geometry: MercurySimulation.Geometry,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) -> CGImage? {
        let field = MercuryField(
            geometry: geometry,
            spine: layout.spine,
            canvas: layout.canvasRect.size
        )
        guard field.boundingBox.width > 0, field.boundingBox.height > 0 else {
            hitRegion.clear()
            return nil
        }
        hitRegion.update(field, layout: layout)
        let lighting = self.lighting(for: layout)
        return rasterizer.image(
            field: field,
            environment: lighting.environment,
            response: lighting.response,
            appearance: appearance,
            scale: MercuryMetrics.rasterScale
        )
    }

    /// The session's room, shown through a response metered on the bodies `layout` draws.
    ///
    /// A room is metered against the body it will light, and a collar, which shows only the
    /// outer half of a chin and walls, sweeps a different part of the room than the island's
    /// whole crown. So the first layout a session draws is metered, and a frame on another
    /// layout meters again, in the same room. A session's layout changes only when the body
    /// moves to another display, so that is paid once per hand-off and never per frame.
    private func lighting(for layout: RecordingOverlayLayout) -> Lighting {
        if let lighting, lighting.layout == layout { return lighting }
        let environment = lighting?.environment ?? MercuryEnvironment(world: world, seed: seed)
        let metered = Lighting(
            environment: environment,
            response: MercuryCalibration.shared.displayResponse(
                for: environment,
                bodySeed: seed,
                layout: layout
            ),
            layout: layout
        )
        lighting = metered
        meteredResponses += 1
        return metered
    }

    /// A new seed or world is a new session: a new body, grown afresh, in a room that has not
    /// been metered yet.
    private func reseedIfNeeded(seed: UInt64, world: MercuryWorld) {
        guard seed != self.seed || world != self.world else { return }
        self.seed = seed
        self.world = world
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        lighting = nil
        started = false
        rendered = nil
        renderedImage = nil
    }
}

/// The body's whole visible surface: one procedural mercury body on the layout's canvas,
/// the island's 196×34 or the collar around the camera housing.
///
/// The body renders below SwiftUI on a view-bound display link: 120 fps on ProMotion,
/// 60 fps on a 60 Hz screen, and no callbacks while hidden or off-display.
struct MercuryRibbon: View {
    @ObservedObject var model: RecordingOverlayModel
    let hitRegion: MercuryHitRegion
    let world: @MainActor () -> MercuryWorld
    let seed: @MainActor () -> UInt64
    /// Told what each live frame shows; see `MercurySurfaceView.Configuration.onFrame`.
    let onFrame: (@MainActor (MercuryFrameReport) -> Void)?
    private var a11y = A11y()

    @MainActor
    init(
        model: RecordingOverlayModel,
        hitRegion: MercuryHitRegion,
        world: @escaping @MainActor () -> MercuryWorld,
        seed: @escaping @MainActor () -> UInt64,
        onFrame: (@MainActor (MercuryFrameReport) -> Void)?
    ) {
        self.model = model
        self.hitRegion = hitRegion
        self.world = world
        self.seed = seed
        self.onFrame = onFrame
    }

    var body: some View {
        let layout = model.layout
        MercurySurface(
            configuration: MercurySurfaceView.Configuration(
                seed: seed(),
                world: world(),
                drive: MercurySimulation.Drive.target(for: model, reduceMotion: a11y.reduceMotion),
                appearance: MercuryAppearance(
                    increasedContrast: a11y.contrast == .increased
                ),
                layout: layout,
                pinnedStep: RenderOverrides.mercuryStep,
                onFrame: onFrame
            ),
            hitRegion: hitRegion
        )
        .frame(width: layout.canvasRect.width, height: layout.canvasRect.height)
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
