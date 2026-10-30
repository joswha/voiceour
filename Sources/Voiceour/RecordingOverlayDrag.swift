import CoreGraphics
import Foundation

/// One press on the recording body, from the moment it lands to its release: a docked body pulled
/// on its tether until it tears off, or an island carried under the pointer, and where the release
/// leaves it.
///
/// Pure: it is told where the pointer is, in AppKit global coordinates (points, +y up), and the
/// geometry of the display under it, and it answers what the panel must do. It reads no clock, screen
/// or body, so every rule replays exactly as a table of pointer positions.
///
/// - A docked body is on a tether. Pulled less than `tearOffDistance` from where it was grabbed, the
///   panel stays and the pull rubber-bands the body: the controller feeds it to the gel as frame
///   forcing (``bandForcing(pull:)``), and let go there, the body snaps back through the gel.
/// - At `tearOffDistance` the tether breaks. The body becomes a free island under the pointer, held
///   where the hand grabbed it as far as the island's canvas reaches, so it does not jump away from
///   the hand, and the snap kicks it (``snap(pull:)``), except under Reduce Motion. The live body is
///   re-anchored on the island's layout: it is never reset or grown again under the hand.
/// - A free island has no tether. It follows the pointer from the first move.
/// - The carried island keeps inside the padded visible frame of the display under the pointer, the
///   frames a free placement describes, so it never covers the menu bar or the Dock and the island
///   let go of is the island that persists.
/// - Released with its envelope's centre within `dockRadius` of the dock anchor of the display it is
///   on, the island docks (``docking(from:to:reduceMotion:)``). Anywhere else it stays free.
struct RecordingOverlayDrag: Sendable, Equatable {
    /// What the hosting view reports of a press on the body, with the pointer in global coordinates.
    enum Event: Sendable, Equatable {
        case began(CGPoint)
        case moved(CGPoint)
        case ended(CGPoint)
    }

    /// What the press lands on.
    enum Body: Sendable, Equatable {
        /// A docked body, the collar or the island at its default spot: `anchor` is its dock anchor,
        /// `axes` its layout's, which a pull resolves into.
        case docked(anchor: CGPoint, axes: RecordingOverlayLayout.BodyAxes)
        /// A free island, its envelope centred at `centre`.
        case free(centre: CGPoint)
    }

    enum Phase: Sendable, Equatable {
        /// A docked body on its tether, pulled `pull` from where it was grabbed.
        case stretching(pull: CGVector, axes: RecordingOverlayLayout.BodyAxes)
        /// An island under the pointer, its envelope centred at `centre`.
        case carrying(centre: CGPoint)
    }

    /// The one-shot kick of a tear-off, the arrival token's two rates.
    struct Snap: Sendable, Equatable {
        /// pt/s along the docked layout's spine.
        var swayRate: Double
        /// s⁻¹ on the aspect `ln(L/H)`.
        var aspectRate: Double
    }

    /// What the panel does for one move of the pointer.
    enum Step: Sendable, Equatable {
        /// The docked body is pulled `pull` on its tether. The panel stays.
        case stretch(pull: CGVector)
        /// The tether broke: lay the island out with its envelope centred at `centre`, and kick the
        /// body with `snap`, nil under Reduce Motion.
        case tearOff(centre: CGPoint, snap: Snap?)
        /// Move the island so its envelope is centred at `centre`.
        case carry(centre: CGPoint)
    }

    /// How a released island docks.
    enum Docking: Sendable, Equatable {
        /// The island glides from `from` onto its dock at `to` (``RecordingOverlayGlide``).
        case glide(from: CGPoint, to: CGPoint)
        /// Reduce Motion's glide: the island is at its dock at once, and the body feels the jump as
        /// its panel's motion.
        case jump(to: CGPoint)
        /// The body docks by a siphon: it drains, the empty panel re-frames docked, and it emerges
        /// there with a landing squash.
        case siphon
        /// Reduce Motion's siphon: the panel re-frames docked at once, and the live body is
        /// re-anchored on the docked layout.
        case reframe
    }

    /// Where a release leaves the body.
    enum Release: Sendable, Equatable {
        /// A docked body let go before it tore off: it snaps back through the gel, and the panel stays.
        case snapBack
        /// The island docks.
        case dock(Docking)
        /// The island stays free, its envelope centred at `centre`.
        case free(centre: CGPoint)
    }

    /// Points of pull, from where the docked body was grabbed, at which its tether breaks.
    static let tearOffDistance: CGFloat = 24
    /// Points between a released island's envelope centre and its dock anchor within which it docks:
    /// twice the tear-off distance, so an island that has just torn off and is let go of where it is
    /// goes home rather than staying a tear-off's width from it.
    static let dockRadius: CGFloat = 48

    /// κ, s⁻²: the tether's stiffness, as the panel acceleration one point of pull stands for.
    ///
    /// The hand's pull on a docked body is felt as the fictitious force of a frame accelerating away
    /// from the pointer, through the very law the panel's own acceleration obeys
    /// (`MercuryBodyShape.Forcing`): a pull `d` along the body's spine axes is the panel acceleration
    /// `−κd`. The body shape's sway answers a tangential acceleration `a` with the force `−0.03 a`,
    /// which holds the sway `f/Ω∞²` from its pose, `Ω∞² = 100` s⁻². A pull `d_t` therefore leans the
    /// body `0.03 κ d_t / Ω∞²` toward the pointer, and
    ///
    ///     κ = Ω∞² · leanSway / (0.03 · tearOffDistance) = 100 · 6 / (0.03 · 24) = 833.3 s⁻²
    ///
    /// makes the 24 pt tear-off pull settle the sway exactly at the 6 pt of a full lean toward the
    /// window (`MercuryMetrics.leanSway`): the body leans a quarter of the pull, and it is never asked
    /// for more lean than it already shows. The same κ along the normal moves the aspect `α = ln(L/H)`
    /// by `1.4e-3 κ d_n / Ω∞,α² = 0.0061 d_n` with `Ω∞,α² = 190.44` s⁻²: a pull out of the collar's
    /// housing, or up from the island, stretches the body, 0.147 at the tear-off, `L` 7.6 % longer
    /// and `H` 7.1 % thinner at constant volume, and a push the other way squashes it. The strongest
    /// pull, 24 pt, is 20 000 pt/s², half the body shape's clamp.
    static let bandStiffness: Double =
        MercuryBodyShape.swayGel.rubberyStiffness * MercuryMetrics.leanSway
        / (-MercuryBodyShape.swayCoupling * Double(tearOffDistance))

    let grab: CGPoint
    /// The grab point's offset from the island envelope's centre, once the body is an island under
    /// the hand. A free island's is exact, so it never jumps; a collar's is held to the island
    /// canvas's half extents, so the smaller island still lies under the hand.
    let handle: CGVector
    let reduceMotion: Bool
    private(set) var phase: Phase
    /// The pointer has moved since the press. A press and release on a free island in one place is a
    /// click, which leaves it where it is.
    private(set) var moved = false

    init(grab: CGPoint, body: Body, reduceMotion: Bool) {
        self.grab = grab
        self.reduceMotion = reduceMotion
        let reference: CGPoint
        switch body {
        case .docked(let anchor, let axes):
            reference = anchor
            phase = .stretching(pull: CGVector(), axes: axes)
        case .free(let centre):
            reference = centre
            phase = .carrying(centre: centre)
        }
        let reach = RecordingOverlayLayout.island.canvasRect.size
        handle = CGVector(
            dx: Swift.min(Swift.max(grab.x - reference.x, -reach.width / 2), reach.width / 2),
            dy: Swift.min(Swift.max(grab.y - reference.y, -reach.height / 2), reach.height / 2)
        )
    }

    /// The pointer moved to `pointer`. `centres` are the island envelope centres the display under the
    /// pointer admits (`RecordingOverlayFramePlacement.islandCentres(on:)`).
    mutating func drag(to pointer: CGPoint, within centres: CGRect) -> Step {
        if pointer != grab {
            moved = true
        }
        switch phase {
        case .stretching(_, let axes):
            let pull = CGVector(dx: pointer.x - grab.x, dy: pointer.y - grab.y)
            guard Self.length(pull) >= Self.tearOffDistance else {
                phase = .stretching(pull: pull, axes: axes)
                return .stretch(pull: pull)
            }
            let centre = carried(to: pointer, within: centres)
            phase = .carrying(centre: centre)
            return .tearOff(
                centre: centre,
                snap: reduceMotion ? nil : Self.snap(pull: axes.resolve(SIMD2(Double(pull.dx), Double(pull.dy))))
            )
        case .carrying:
            let centre = carried(to: pointer, within: centres)
            phase = .carrying(centre: centre)
            return .carry(centre: centre)
        }
    }

    /// The pointer let go at `pointer`, over a display that admits island centres `centres` and docks
    /// at `anchor`.
    func release(at pointer: CGPoint, within centres: CGRect, anchor: RecordingOverlayPlacement.Anchor) -> Release {
        switch phase {
        case .stretching:
            return .snapBack
        case .carrying(let centre):
            guard moved else { return .free(centre: centre) }
            let released = carried(to: pointer, within: centres)
            guard Self.distance(released, anchor.point) <= Self.dockRadius else { return .free(centre: released) }
            return .dock(Self.docking(from: released, to: anchor, reduceMotion: reduceMotion))
        }
    }

    /// How an island centred at `centre` docks at `anchor`. Into the collar it re-lays out, which only a
    /// siphon may do to a visible body. Onto the island's dock it glides when the dock is within
    /// `dockRadius`, as a release always is; from further, which only the "Dock island" action asks, a
    /// glide would sweep a visible body across the screen, so it siphons. Reduce Motion moves it at
    /// once either way.
    static func docking(
        from centre: CGPoint,
        to anchor: RecordingOverlayPlacement.Anchor,
        reduceMotion: Bool
    ) -> Docking {
        switch anchor {
        case .collar:
            return reduceMotion ? .reframe : .siphon
        case .island(let home):
            if reduceMotion { return .jump(to: home) }
            return distance(centre, home) <= dockRadius ? .glide(from: centre, to: home) : .siphon
        }
    }

    /// The tether's pull `pull`, resolved along the body's spine axes, as the panel acceleration it
    /// stands for: `−κ · pull`. See ``bandStiffness``.
    static func bandForcing(pull: SIMD2<Double>) -> MercuryBodyShape.Forcing {
        MercuryBodyShape.Forcing(
            tangentialAcceleration: -bandStiffness * pull.x,
            normalAcceleration: -bandStiffness * pull.y
        )
    }

    /// The kick of a tear-off whose pull resolves to `pull` along the docked body's spine axes.
    ///
    /// At the tear-off the tether holds the body leaned `q* = d_t / 4` along its spine and stretched
    /// `Δα* = 0.0061 d_n` (``bandStiffness``): equilibrium shifts its rubbery springs hold, each storing
    /// `½ Ω∞² x²`. The tether breaks and the panel jumps to put the island under the hand, faster than
    /// any substep can show, and the snap hands that energy back as one velocity of the same energy,
    /// `Ω∞ x`:
    ///
    /// - The lean goes with the body to the hand, so it keeps its direction: `swayRate = Ω∞,δ q* =
    ///   2.5 d_t`, along the pull. The body arrives travelling toward the hand, as a handed-off body
    ///   arrives travelling away from its source, and a sideways tear-off's 60 pt/s is a hand-off
    ///   arrival's own.
    /// - The stretch is the tether's, and it lets go: `aspectRate = −Ω∞,α Δα* = −0.085 d_n`, the
    ///   stretch recoiling into a squash. A pull straight out of the collar's housing gives −2.03 s⁻¹,
    ///   about the copy-only bead's −2.0.
    ///
    /// The pull is taken at the tear-off distance in its own direction, whatever event crossed it, so
    /// a flick kicks no harder than a pull.
    static func snap(pull: SIMD2<Double>) -> Snap {
        let length = (pull * pull).sum().squareRoot()
        guard length > 0 else { return Snap(swayRate: 0, aspectRate: 0) }
        let held = bandForcing(pull: pull * (Double(tearOffDistance) / length))
        let swayStiffness = MercuryBodyShape.swayGel.rubberyStiffness
        let aspectStiffness = MercuryBodyShape.aspectGel.rubberyStiffness
        let lean = MercuryBodyShape.swayCoupling * held.tangentialAcceleration / swayStiffness
        let stretch = MercuryBodyShape.aspectCoupling * held.normalAcceleration / aspectStiffness
        return Snap(
            swayRate: swayStiffness.squareRoot() * lean,
            aspectRate: -aspectStiffness.squareRoot() * stretch
        )
    }

    /// The island envelope centre that holds the grab point under `pointer`, inside `centres`.
    private func carried(to pointer: CGPoint, within centres: CGRect) -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(pointer.x - handle.dx, centres.minX), centres.maxX),
            y: Swift.min(Swift.max(pointer.y - handle.dy, centres.minY), centres.maxY)
        )
    }

    private static func length(_ vector: CGVector) -> CGFloat {
        (vector.dx * vector.dx + vector.dy * vector.dy).squareRoot()
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        length(CGVector(dx: a.x - b.x, dy: a.y - b.y))
    }
}

/// A docking island's glide onto its dock, on the substep clock.
///
/// Critically damped from rest: `x(t) = to + (from − to)(1 + ωt) e^(−ωt)` with ω = 35 rad/s, the
/// fastest approach that cannot overshoot the dock. Its `length`, 24 substeps or 0.2 s, carries a
/// full 48 pt glide to within half a point, and on the 24th substep, with 0.35 pt of the curve still
/// to go, the island lands on the dock exactly. The panel's acceleration is
/// largest at the start, `ω² (to − from)`, 58 800 pt/s² for the full 48 pt, which the body feels
/// through the body shape's clamp as a lag; it reverses at `t = 1/ω`, 29 ms in, into the deceleration
/// that sloshes the body forward as the island settles.
struct RecordingOverlayGlide: Sendable, Equatable {
    /// ω, rad/s.
    static let frequency = 35.0
    /// Substeps from the glide's start to its landing.
    static let length = 24

    let from: CGPoint
    let to: CGPoint
    /// The last substep presented before the glide began.
    let startStep: Int

    /// The island envelope's centre at substep `step`.
    func centre(atStep step: Int) -> CGPoint {
        guard !isOver(atStep: step) else { return to }
        let time = Double(Swift.max(0, step - startStep)) * MercuryMetrics.substep
        let remaining = CGFloat((1 + Self.frequency * time) * exp(-Self.frequency * time))
        return CGPoint(x: to.x + (from.x - to.x) * remaining, y: to.y + (from.y - to.y) * remaining)
    }

    func isOver(atStep step: Int) -> Bool {
        step - startStep >= Self.length
    }
}
