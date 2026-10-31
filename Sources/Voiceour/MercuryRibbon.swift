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

/// Owns the exact 120 Hz body simulation and its look's light: the static room, the paint
/// table and the metered response. The display-link view supplies an integer substep count
/// and the layout to draw in, and consumes the returned `CGImage` directly; no animation tick
/// is published through SwiftUI.
///
/// A look change rebuilds only what it reaches. The room is rebaked only for a new seed,
/// world or room lighting. The response is metered again for any change of look and for a
/// new layout, because every member of a look moves either the scene it is solved against
/// or the targets it is solved to, and every layout draws its own bodies. The body never
/// restarts for a look: a new tune retunes the moving body, and only a new seed is a new
/// body, grown afresh.
@MainActor
final class MercuryEngine {
    private struct PinnedFrame: Equatable {
        var step: Int
        var seed: UInt64
        var look: MercuryLook
        var drive: MercurySimulation.Drive
        var appearance: MercuryAppearance
        var layout: RecordingOverlayLayout
    }

    private struct RenderedFrame: Equatable {
        var geometry: MercurySimulation.Geometry
        var seed: UInt64
        var look: MercuryLook
        var appearance: MercuryAppearance
        var layout: RecordingOverlayLayout
    }

    /// What the rasterizer reads besides the body and the room: the paint table and the
    /// response, metered for `lightingSeed` and `lightingLook` on the bodies `layout` draws.
    private struct Lighting {
        var paint: MercuryPaintLookup
        var response: MercuryDisplayResponse
        var layout: RecordingOverlayLayout
    }

    /// A requested replay no advancing frame has applied yet.
    private struct Replay {
        var source: MercuryPose?
    }

    private let hitRegion: MercuryHitRegion
    private var simulation: MercurySimulation
    private let rasterizer = MercuryRasterizer()
    /// Baked for `lightingSeed` and `lightingLook`'s world and room lighting.
    private var room: MercuryEnvironment
    /// Metered for the first layout a frame draws a body on, so a session that starts on a
    /// collar never meters the island's bodies, and dropped by any change of seed or look. See
    /// ``lighting(for:)``.
    private var lighting: Lighting?
    private var lightingSeed: UInt64
    private var lightingLook: MercuryLook
    /// What `simulation` runs.
    private var seed: UInt64
    private var tune: MercuryTune
    private var started = false
    private var pendingReplay: Replay?
    private var pinned: PinnedFrame?
    private var pinnedImage: CGImage?
    private var rendered: RenderedFrame?
    private var renderedImage: CGImage?

    /// How many responses this engine has metered. Each settles two bodies and rasters them,
    /// so it is paid once for each seed, look and layout a session draws and never per frame;
    /// the tests hold the engine to that.
    private(set) var meteredResponses = 0

    /// `L·H` of the body the last live frame drew, pt²: how much mercury it shows, and what a
    /// hand-off drains before the panel may move to another display.
    private(set) var liveVolume = 0.0

    init(seed: UInt64, look: MercuryLook, hitRegion: MercuryHitRegion) {
        self.hitRegion = hitRegion
        self.seed = seed
        tune = look.tune
        simulation = Self.makeSimulation(seed: seed, tune: look.tune)
        room = Self.makeEnvironment(seed: seed, look: look)
        lightingSeed = seed
        lightingLook = look
    }

    /// The room the body currently reflects. Read by the tests that hold a look change to
    /// rebaking only what it reaches.
    var environment: MercuryEnvironment {
        room
    }

    /// Harness frame after exactly `step` closed-form substeps from rest. The body is always
    /// new, so the frame depends on its arguments alone; the light is rebuilt only where
    /// they changed it. A pinned frame never replays, so a pending replay is dropped here
    /// rather than left to fire on some later live frame.
    func pinnedFrame(
        step: Int,
        seed: UInt64,
        look: MercuryLook,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) -> CGImage? {
        pendingReplay = nil
        let key = PinnedFrame(
            step: step,
            seed: seed,
            look: look,
            drive: drive,
            appearance: appearance,
            layout: layout
        )
        guard key != pinned else { return pinnedImage }
        pinned = key
        self.seed = seed
        tune = look.tune
        simulation = Self.makeSimulation(seed: seed, tune: look.tune)
        relight(seed: seed, look: look)
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
        look: MercuryLook,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) -> CGImage? {
        adopt(seed: seed, look: look)
        if !started {
            // A live body grows out of the notch or the top edge. Reduce Motion shows it at rest on
            // its pose instead: an emergence is motion that carries no information.
            simulation.reset(to: drive, emerging: !drive.reduceMotion)
            started = true
        } else {
            if steps > 0, let replay = pendingReplay {
                pendingReplay = nil
                // A live pose has no gesture to fire, and its source pose would only make the
                // body jump.
                if drive.pose.gesture != nil {
                    simulation.rearmGesture(from: replay.source)
                }
            }
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
            look: look,
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

    /// Fires the current outcome gesture again on the next frame that advances the body.
    /// With `source` — the processing pose — the body also relaxes into the outcome from
    /// it, exactly as the live processing-to-outcome transition does.
    ///
    /// Pending rather than immediate, so the reset that starts a body on its first frame
    /// cannot swallow it; dropped if that frame drives a live pose, which has no gesture.
    func replayGesture(from source: MercuryPose?) {
        pendingReplay = Replay(source: source)
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
            environment: room,
            response: lighting.response,
            appearance: appearance,
            paint: lighting.paint,
            scale: MercuryMetrics.rasterScale
        )
    }

    /// The look's paint, and a response metered in the current room on the bodies `layout`
    /// draws.
    ///
    /// A room is metered against the body it will light, and a collar, which shows only the
    /// outer half of a chin and walls, sweeps a different part of the room than the island's
    /// whole crown. So the first layout a session draws is metered, and a frame on another
    /// layout meters again, in the same room. A session's layout changes only when the body
    /// moves to another display, and its look only between sessions, so that is paid once per
    /// hand-off and never per frame.
    private func lighting(for layout: RecordingOverlayLayout) -> Lighting {
        if let lighting, lighting.layout == layout { return lighting }
        let metered = Self.makeLighting(
            seed: lightingSeed,
            look: lightingLook,
            environment: room,
            layout: layout
        )
        lighting = metered
        meteredResponses += 1
        return metered
    }

    /// Brings the body and its light to `seed` and `look`. A new seed is a new session: a new
    /// body, grown afresh by the next frame. A new tune retunes the moving body, so a look
    /// never restarts it.
    private func adopt(seed: UInt64, look: MercuryLook) {
        if seed != self.seed {
            self.seed = seed
            tune = look.tune
            simulation = Self.makeSimulation(seed: seed, tune: look.tune)
            started = false
            rendered = nil
            renderedImage = nil
        } else if look.tune != tune {
            tune = look.tune
            simulation.retune(look.tune)
        }
        relight(seed: seed, look: look)
    }

    /// Rebakes the room only for a new seed, world or room lighting, and drops the response
    /// for any change, a new paint, tone or tune over the same room included, so the next
    /// frame that draws a body meters it again.
    private func relight(seed: UInt64, look: MercuryLook) {
        guard seed != lightingSeed || look != lightingLook else { return }
        let rebake =
            seed != lightingSeed
            || look.world != lightingLook.world
            || look.lighting != lightingLook.lighting
        if rebake {
            room = Self.makeEnvironment(seed: seed, look: look)
        }
        lighting = nil
        lightingSeed = seed
        lightingLook = look
    }

    private static func makeSimulation(seed: UInt64, tune: MercuryTune) -> MercurySimulation {
        MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains, tune: tune)
    }

    private static func makeEnvironment(seed: UInt64, look: MercuryLook) -> MercuryEnvironment {
        MercuryEnvironment(world: look.world, seed: seed, lighting: look.lighting)
    }

    /// `environment` is the room `seed` and `look` bake.
    private static func makeLighting(
        seed: UInt64,
        look: MercuryLook,
        environment: MercuryEnvironment,
        layout: RecordingOverlayLayout
    ) -> Lighting {
        Lighting(
            paint: MercuryPaintLookup.lookup(for: look.paint),
            response: MercuryCalibration.shared.displayResponse(
                for: environment,
                bodySeed: seed,
                layout: layout,
                look: look
            ),
            layout: layout
        )
    }
}

/// The body's whole visible surface: one procedural mercury body on the layout's canvas,
/// the island's 196×34 or the collar around the camera housing.
///
/// The body renders below SwiftUI on a view-bound display link: 120 fps on ProMotion,
/// 60 fps on a 60 Hz screen, and no callbacks while hidden or off-display. `island` is the
/// session's latched appearance, resolved here into the renderer's look.
struct MercuryRibbon: View {
    @ObservedObject var model: RecordingOverlayModel
    let hitRegion: MercuryHitRegion
    /// What the body feels of its panel; see `MercurySurfaceView.Configuration.panelMotion`.
    let panelMotion: MercuryPanelMotion?
    let island: @MainActor () -> IslandAppearance
    let seed: @MainActor () -> UInt64
    /// Told what each live frame shows; see `MercurySurfaceView.Configuration.onFrame`.
    let onFrame: (@MainActor (MercuryFrameReport) -> Void)?
    private var a11y = A11y()

    @MainActor
    init(
        model: RecordingOverlayModel,
        hitRegion: MercuryHitRegion,
        panelMotion: MercuryPanelMotion?,
        island: @escaping @MainActor () -> IslandAppearance,
        seed: @escaping @MainActor () -> UInt64,
        onFrame: (@MainActor (MercuryFrameReport) -> Void)?
    ) {
        self.model = model
        self.hitRegion = hitRegion
        self.panelMotion = panelMotion
        self.island = island
        self.seed = seed
        self.onFrame = onFrame
    }

    var body: some View {
        let layout = model.layout
        MercurySurface(
            configuration: MercurySurfaceView.Configuration(
                seed: seed(),
                look: MercuryLook(island: island()),
                drive: MercurySimulation.Drive.target(for: model, reduceMotion: a11y.reduceMotion),
                appearance: MercuryAppearance(
                    increasedContrast: a11y.contrast == .increased
                ),
                layout: layout,
                pinnedStep: RenderOverrides.mercuryStep,
                onFrame: onFrame,
                panelMotion: panelMotion
            ),
            hitRegion: hitRegion
        )
        .frame(width: layout.canvasRect.width, height: layout.canvasRect.height)
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
