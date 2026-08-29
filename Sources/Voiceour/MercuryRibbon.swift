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

/// Owns the body's state and turns wall-clock time into fixed simulation substeps.
///
/// An `ObservableObject` with no `@Published` member, deliberately: `TimelineView` is
/// already re-rendering every frame, so anything published here would invalidate the
/// overlay twice per frame for no new information.
@MainActor
final class MercuryEngine: ObservableObject {
    /// Everything a pinned frame is a function of. When none of it has moved, the frame
    /// has already been computed — without this the harness re-ran 600 substeps and a
    /// hundred table bakes on every one of the hundreds of renders a flow performs.
    private struct PinnedFrame: Equatable {
        var step: Int
        var seed: UInt64
        var world: MercuryWorld
        var drive: MercurySimulation.Drive
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
    private var accumulated: Double = 0
    private var lastTick: Date?
    private var started = false
    private var pinned: PinnedFrame?
    private var pinnedImage: CGImage?
    private var lastRenderedAt: Date?
    private var cachedImage: CGImage?
    private var cachedAppearance: MercuryAppearance?

    init(seed: UInt64, world: MercuryWorld, hitRegion: MercuryHitRegion) {
        self.hitRegion = hitRegion
        self.seed = seed
        simulation = MercurySimulation(seed: seed, gains: MercuryCalibration.shared.gains)
        lighting = Self.makeLighting(world: world, seed: seed)
    }

    /// One frame. `date` is the `TimelineView` tick; `step` pins the harness to an exact
    /// substep index instead.
    func frame(
        at date: Date,
        step: Int?,
        seed: UInt64,
        world: MercuryWorld,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance
    ) -> CGImage? {
        if let step {
            let key = PinnedFrame(step: step, seed: seed, world: world, drive: drive, appearance: appearance)
            if key != pinned {
                pinned = key
                // Rebuilt rather than advanced: a pinned frame is the state after exactly
                // `step` substeps from rest, not after however many the last one left.
                self.seed = seed
                simulation = MercurySimulation(
                    seed: seed,
                    gains: MercuryCalibration.shared.gains
                )
                lighting = Self.makeLighting(world: world, seed: seed)
                simulation.reset(to: drive)
                simulation.advance(steps: step, drive: drive)
                pinnedImage = image(drive: drive, appearance: appearance)
            }
            return pinnedImage
        }

        reseedIfNeeded(seed: seed, world: world)
        advance(to: date, drive: drive)
        if let cachedImage, let lastRenderedAt,
            cachedAppearance == appearance,
            date.timeIntervalSince(lastRenderedAt) < MercuryMetrics.presentationInterval
        {
            return cachedImage
        }
        let rendered = image(drive: drive, appearance: appearance)
        lastRenderedAt = date
        cachedImage = rendered
        cachedAppearance = appearance
        return rendered
    }

    private func image(drive: MercurySimulation.Drive, appearance: MercuryAppearance) -> CGImage? {
        let field = MercuryField(geometry: simulation.geometry, lateralOffset: drive.pose.lateralOffset)
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

    private func advance(to date: Date, drive: MercurySimulation.Drive) {
        defer { lastTick = date }
        guard let lastTick else {
            // First frame of a session: place the body at rest in this pose rather than
            // growing it out of whatever the previous session left behind.
            if !started {
                simulation.reset(to: drive)
                started = true
            }
            return
        }
        accumulated += Swift.max(0, date.timeIntervalSince(lastTick))
        let available = Int(accumulated / MercuryMetrics.substep)
        // A stalled frame must not fast-forward the body: it resumes from where it was.
        let steps = Swift.min(available, MercuryMetrics.maxSubstepsPerFrame)
        accumulated -= Double(available) * MercuryMetrics.substep
        guard steps > 0 else { return }
        simulation.advance(steps: steps, drive: drive)
    }

    /// A new session installs a new world; the debug picker installs a new room. Both
    /// are read per frame and compared, so neither needs a notification path.
    private func reseedIfNeeded(seed: UInt64, world: MercuryWorld) {
        guard seed != self.seed || world != lighting.environment.world else { return }
        self.seed = seed
        simulation = MercurySimulation(
            seed: seed,
            gains: MercuryCalibration.shared.gains
        )
        lighting = Self.makeLighting(world: world, seed: seed)
        lastTick = nil
        accumulated = 0
        started = false
        lastRenderedAt = nil
        cachedImage = nil
        cachedAppearance = nil
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
/// There is no capsule, no control disc, no waveform, no work mark, and no painted word
/// or symbol. What a reader sees is one compact organism whose size, motion and gesture
/// carry the session state; what an assistive technology reads is the status element
/// `RecordingOverlayView` puts over it, whose label, value and named actions are the
/// unchanged contract.
struct MercuryRibbon: View {
    @ObservedObject var model: RecordingOverlayModel
    let hitRegion: MercuryHitRegion
    /// Read per frame, so the debug world picker needs no notification path.
    let world: @MainActor () -> MercuryWorld
    /// Read per frame, so a new session's world arrives the same way.
    let seed: @MainActor () -> UInt64

    @StateObject private var engine: MercuryEngine
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
        _engine = StateObject(
            wrappedValue: MercuryEngine(
                seed: seed(),
                world: world(),
                hitRegion: hitRegion
            )
        )
    }

    var body: some View {
        Group {
            if let step = RenderOverrides.mercuryStep {
                body(step: step)
            } else {
                TimelineView(.animation) { context in
                    body(step: nil, date: context.date)
                }
            }
        }
        .frame(
            width: RecordingOverlayMetrics.islandSize.width,
            height: RecordingOverlayMetrics.islandSize.height
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func body(step: Int?, date: Date = .distantPast) -> some View {
        if let image = engine.frame(
            at: date,
            step: step,
            seed: seed(),
            world: world(),
            drive: drive,
            appearance: appearance
        ) {
            Image(decorative: image, scale: MercuryMetrics.rasterScale)
        } else {
            Color.clear
        }
    }

    private var drive: MercurySimulation.Drive {
        MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: a11y.reduceMotion
        )
    }

    private var appearance: MercuryAppearance {
        MercuryAppearance(increasedContrast: a11y.contrast == .increased)
    }
}
