import CoreGraphics

/// The siphon that hands the recording body from one display to the next, on the substep clock.
///
/// The panel is a single window, and re-framing it onto another display while it shows mercury
/// would teleport a visible body. So a hand-off empties the body first: it drains into the edge it
/// is leaving, leaning toward its destination, and the panel moves only once there is nothing left
/// to see. On the destination it grows back out of the notch or the top edge, travelling away from
/// the side it came from, and lands with a squash.
///
/// Pure: the conductor reads no clock, screen or body. It is told every presented frame's volume
/// and substep, and every retarget the move policy decides, and it answers with what the panel must
/// do. Every rule therefore replays exactly as a table of substeps.
///
/// - A retarget back to the source while the body drains grows it again where it is: the panel
///   never left, so there is nothing to re-frame.
/// - A retarget to a third display re-aims the drain that is already running.
/// - A retarget while the body emerges drains it again, from the display it is emerging on.
/// - An instant move — Reduce Motion, or the move policy's storm — re-frames at once, with no drain
///   and no arrival kick. The live body is re-anchored on the destination's layout, and its pose
///   flows there through the gel: the siphon is motion that carries no information, and a user
///   moving faster than a siphon can read is better served by a body that is simply there.
/// - A relayout is a hand-off to the display the body is already on: a torn-off island docking
///   back into the collar changes its layout, and only an empty panel may be re-framed. It drains
///   straight up, with no lean, and emerges with the landing squash and no sway.
struct RecordingOverlayConductor: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// The body is on `display`, in whatever pose the session asks for.
        case resting(display: UInt32)
        /// The body has been draining into `from`'s edge since `startStep`, on its way to `to`.
        /// `exitSign` is the side `to` lies on, the lean the drain takes toward it.
        case draining(from: UInt32, to: UInt32, startStep: Int, exitSign: Double)
        /// The body has been growing out of `display`'s edge since `startStep`.
        case emerging(display: UInt32, startStep: Int)
    }

    enum Action: Sendable, Equatable {
        /// Re-frame the panel on `to` now. `arrivalSign` is the direction the body arrives
        /// travelling, ±1 along the destination's spine or 0 between stacked displays, for an
        /// arrival kick; nil re-frames without one.
        case reframe(to: UInt32, arrivalSign: Double?)
        /// The emergence is over and the body rests on its display.
        case settled
    }

    /// pt². The idle pose's outflow stops a swallowed body at exactly zero, so a drain that waits for
    /// the body to empty sees it pass this; the panel may then move with nothing left to see.
    static let emptyVolume = 1.0
    /// Substeps, 0.4 s: as long as the idle pose's outflow takes to empty a 168 × 17 pt island body,
    /// and longer than a speaking island takes. The panel moves on whichever comes first, so a larger
    /// body re-frames with the sliver it has left rather than hold the hand-off.
    static let drainLimit = 48
    /// Substeps, 0.5 s: the volume's critically damped rise at 10 rad/s has covered 96 % of its way
    /// to the pose, so the body is all there by the time the click-through it emerged under ends.
    static let emergenceLength = 60
    /// Points per second along the destination's spine, away from the side the body came from.
    static let arrivalSwayRate = 60.0
    /// s⁻¹ on the aspect `ln(L/H)`: a landing squash.
    static let arrivalAspectRate = -1.2

    private(set) var phase: Phase

    init(display: UInt32) {
        phase = .resting(display: display)
    }

    /// The display the body is on, or on its way to. The move policy measures a candidate against
    /// this, so a drain already heading somewhere is never asked to go there twice, and focus
    /// returning to the source reads as the move back that it is.
    var destination: UInt32 {
        switch phase {
        case .resting(let display): display
        case .draining(_, let to, _, _): to
        case .emerging(let display, _): display
        }
    }

    var isResting: Bool {
        if case .resting = phase { return true }
        return false
    }

    /// The side the draining body leans toward, or nil while it is not draining.
    var drainSign: Double? {
        if case .draining(_, _, _, let exitSign) = phase { return exitSign }
        return nil
    }

    /// Hands the body to `display`. `exitSign` is the side `display` lies on as seen from the
    /// display the body is on now: +1 to the right, −1 to the left. `step` is the last substep
    /// presented. `instant` re-frames at once with no drain and no arrival kick.
    mutating func retarget(to display: UInt32, exitSign: Double, step: Int, instant: Bool) -> Action? {
        switch phase {
        case .resting(let current):
            guard display != current else { return nil }
            return begin(from: current, to: display, exitSign: exitSign, step: step, instant: instant)
        case .draining(let source, let target, let startStep, _):
            if display == target {
                return nil
            }
            if display == source {
                // The panel never left: the body grows again where it is.
                phase = instant ? .resting(display: source) : .emerging(display: source, startStep: step)
                return nil
            }
            if instant {
                phase = .resting(display: display)
                return .reframe(to: display, arrivalSign: nil)
            }
            // Re-aimed, not restarted: the drain keeps its start, so `drainLimit` still bounds how
            // long the body is held empty.
            phase = .draining(from: source, to: display, startStep: startStep, exitSign: exitSign)
            return nil
        case .emerging(let current, _):
            guard display != current else { return nil }
            return begin(from: current, to: display, exitSign: exitSign, step: step, instant: instant)
        }
    }

    /// Re-lays the resting body out on its own display by the siphon: it drains, the empty panel
    /// re-frames, and it emerges docked. `step` is the last substep presented. A body already on its
    /// way somewhere is left to that hand-off, whose re-frame lays it out afresh anyway.
    mutating func relayout(step: Int) {
        guard case .resting(let display) = phase else { return }
        phase = .draining(from: display, to: display, startStep: step, exitSign: 0)
    }

    /// One presented frame: the body's volume `L·H`, in pt², at substep `step`.
    mutating func frame(volume: Double, step: Int) -> Action? {
        switch phase {
        case .resting:
            return nil
        case .draining(_, let target, let startStep, let exitSign):
            guard volume < Self.emptyVolume || step - startStep >= Self.drainLimit else { return nil }
            phase = .emerging(display: target, startStep: step)
            // The body left travelling toward the destination and arrives travelling the same way,
            // out of the side that faces the display it came from.
            return .reframe(to: target, arrivalSign: exitSign)
        case .emerging(let display, let startStep):
            guard step - startStep >= Self.emergenceLength else { return nil }
            phase = .resting(display: display)
            return .settled
        }
    }

    /// The side `destination` lies on as seen from `source`, by the order of their frames' centres:
    /// +1 to the right, −1 to the left, and 0 for displays stacked one above the other.
    static func exitSign(from source: CGRect, to destination: CGRect) -> Double {
        if destination.midX > source.midX { return 1 }
        if destination.midX < source.midX { return -1 }
        return 0
    }

    /// The arrival kick for a re-frame whose `arrivalSign` is `sign`, as token `id`.
    static func arrival(id: Int, sign: Double) -> MercuryArrival {
        MercuryArrival(id: id, swayRate: arrivalSwayRate * sign, aspectRate: arrivalAspectRate)
    }

    private mutating func begin(from source: UInt32, to display: UInt32, exitSign: Double, step: Int, instant: Bool)
        -> Action?
    {
        if instant {
            phase = .resting(display: display)
            return .reframe(to: display, arrivalSign: nil)
        }
        phase = .draining(from: source, to: display, startStep: step, exitSign: exitSign)
        return nil
    }
}
