import CoreGraphics

/// The acceleration of the panel the body is drawn in, read off where the panel is at each presented
/// frame.
///
/// The body feels its panel's motion as a fictitious force (`MercuryBodyShape.Forcing`): carried, it
/// lags and sloshes, and when the panel stops it wobbles. The controller moves the panel at event
/// rate, between frames, so the acceleration is taken from where each frame finds the panel, on the
/// substep clock. Over a frame of `n` substeps the panel moved at the mean velocity `Δx / (n h)`; the
/// change between two consecutive frames' velocities, over the time between their midpoints,
/// `(n₁ + n₂) h / 2`, is the acceleration. That central difference is exact for any constant
/// acceleration at any cadence, and zero for a panel moving at a constant velocity however the frames
/// divide the substeps.
///
/// Its sign is the panel's own, which is what the body shape's couplings are written against: they
/// turn an acceleration `a` into the force `−0.03 a` on the sway and `−1.4e-3 a` on the aspect, the
/// fictitious force `−a` scaled, so the body lags the way its panel accelerates.
///
/// A panel that jumps has no finite acceleration, so each component is held to
/// `MercuryBodyShape.maxFrameAcceleration`, the clamp the body shape applies itself: a jump sloshes
/// the mercury rather than flinging it.
struct MercuryPanelAcceleration: Sendable, Equatable {
    private var position: SIMD2<Double>
    /// pt/s over the last frame that advanced; zero at rest.
    private var velocity = SIMD2<Double>()
    /// Substeps of the last frame that advanced, or nil at rest: the next frame's velocity is then
    /// measured against rest over a span as long as its own.
    private var span: Int?

    /// At rest at `position`.
    init(at position: SIMD2<Double>) {
        self.position = position
    }

    /// At rest at `position`: what came before is not motion the body feels.
    mutating func restart(at position: SIMD2<Double>) {
        self.position = position
        velocity = SIMD2()
        span = nil
    }

    /// The acceleration, pt/s², over a frame that advances `steps` substeps and finds the panel at
    /// `position`. A frame that advances nothing reads nothing: the body does not move in it, and the
    /// next frame that does measures the motion over all the time since.
    mutating func advance(to position: SIMD2<Double>, steps: Int) -> SIMD2<Double> {
        guard steps > 0 else { return SIMD2() }
        let substep = MercuryMetrics.substep
        let current = (position - self.position) / (Double(steps) * substep)
        let midpoints = Double(steps + (span ?? steps)) * substep / 2
        let acceleration = (current - velocity) / midpoints
        self.position = position
        velocity = current
        span = steps
        let limit = MercuryBodyShape.maxFrameAcceleration
        return SIMD2(
            Swift.min(Swift.max(acceleration.x, -limit), limit),
            Swift.min(Swift.max(acceleration.y, -limit), limit)
        )
    }
}

/// What the body feels of its panel: the tether's pull while the hand stretches a docked body, and the
/// panel's acceleration while the controller carries or glides it.
///
/// Shared by the controller and the surface outside SwiftUI, as `MercuryHitRegion` is. The controller
/// writes it at event rate and the surface reads it once per live frame, where it replaces the drive's
/// forcing, so a value that changes every frame never passes through published state: no frame clock
/// enters the view graph. Pinned harness frames never read it.
@MainActor
final class MercuryPanelMotion {
    /// The tether's pull on a docked body, as forcing along its layout's axes
    /// (`RecordingOverlayDrag.bandForcing(pull:)`); none while nothing pulls.
    var band = MercuryBodyShape.Forcing.none
    /// Where the controller last put the body's centre, global: a point fixed to the panel, so its
    /// motion is the panel's.
    private var position = SIMD2<Double>()
    private var acceleration = MercuryPanelAcceleration(at: SIMD2())

    /// The panel was laid out with the body centred at `point` by a jump the body must not feel: a
    /// session's start, a re-frame while the body is empty, a body re-anchored on a new layout.
    func restart(at point: CGPoint) {
        position = SIMD2(Double(point.x), Double(point.y))
        acceleration.restart(at: position)
    }

    /// The controller moved the panel so the body is centred at `point`, a move the body feels.
    func move(to point: CGPoint) {
        position = SIMD2(Double(point.x), Double(point.y))
    }

    /// The forcing for a live frame that advances `steps` substeps on `layout`: the tether's pull and
    /// the panel's acceleration, resolved onto the layout's body axes.
    func forcing(advancing steps: Int, layout: RecordingOverlayLayout) -> MercuryBodyShape.Forcing {
        let felt = layout.bodyAxes.resolve(acceleration.advance(to: position, steps: steps))
        return MercuryBodyShape.Forcing(
            tangentialAcceleration: band.tangentialAcceleration + felt.x,
            normalAcceleration: band.normalAcceleration + felt.y
        )
    }
}
