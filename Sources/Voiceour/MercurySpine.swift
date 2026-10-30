import Foundation

/// The curve the mercury body lies along, and the exact curvilinear chart around it.
///
/// The body is one two-edge ribbon wherever it appears: a spine, a signed normal offset
/// `n`, and the two edges `n₋ < n₊` the simulation draws per station. Only the line the
/// ribbon is laid on changes. Without a camera housing it is the island's straight spine.
/// On a display with a notch it is the housing's own outline (ear, concave fillet, wall,
/// convex corner, bottom, then back up the other side), so the body wears the notch as a
/// collar.
///
/// Canvas-local points: origin at the canvas centre, +y up.
///
/// **The inner half lies under the housing.** The collar's spine is the housing's edge, so
/// the half of the ribbon with `n < 0` falls inside the black camera housing, or above the
/// screen along the ears. There ``chart(at:)`` answers nil, and nothing is drawn or hit. The
/// visible body therefore begins exactly at the hardware's edge. The notch's own rim becomes
/// the liquid's contact line, the way a drop meets the wall it wets. Nothing has to draw a
/// rim (rims are banned), and a crest pressed against a hard black edge reads as liquid held
/// by the notch rather than as a shape floating near it.
///
/// **The metric belongs in the normal.** The field is written in chart coordinates,
/// `φ = r(s) − |n − c(s)|`, so its gradient is `φ_s ∇s + φ_n ∇n`, with `∇n = N` and
/// `∇s = T / (1 + κn)`.
/// - Offset curves around a convex corner are longer than the corner (`1 + κn`). A crest
///   wrapped around it is stretched, and its slope along the body falls by exactly that factor.
/// - Around a concave fillet they are shorter (`1 − |κ|n`), and the slope steepens.
///
/// Using `T` alone would tilt every normal on the curved primitives by the wrong amount. With
/// the metric, the normal is the true surface normal, and it is continuous wherever `κ` is.
///
/// **Every bend eases into its turn.** A circular arc's curvature jumps from `±1/ρ` to 0
/// where it meets a straight run. The metric jumps with it, and so does the field's gradient
/// wherever the body's edges slope along it. On a mirror that kink draws a seam down the
/// reflection: up to 10.2 8-bit codes at the chin's ends and 4.5 at an ear's, measured on the
/// fixture housings' speaking bodies. So each bend of arc length `S`, convex corner and
/// concave fillet alike, turns with continuous curvature and continuous curvature slope (G³):
/// - Over its first and last `qS`, `q = 0.15`, a ramp eases `|κ|` up from 0 as
///   `κ_p·sin²(πu/2qS)`, turning the tangent through `θ_q = πq/4(1 − q) = 7.94°`.
/// - Between the ramps it holds the plateau's `κ_p`: an exact circular arc of radius `R_p`.
///
/// The turn `θ(u)` has a closed form throughout. Each bend keeps the housing's footprint: it
/// runs its radius `r` (`ρ` or `ρe`) across and `r` down, so it begins and ends exactly at
/// the circle's tangent points, and the walls, ears and bottom run keep their lengths. That
/// fixes `S = 1.62051r` (a circle's is `1.57080r`) and `κ_p = 1.14038/r`, so
/// `R_p = 0.87690r`, centred `0.12150r` from the circle's centre along each axis, toward the
/// bend's corner. The bend is squarer than the circle, by `0.04873r` at its middle: 0.69 pt
/// at the 185×32 pt housing's `ρ = 14.08`, 0.78 pt at `ρ = 16`, and 0.22 pt on a fillet.
///
/// **The housing keeps its circular corners.** The spine's convex corner stands outside the
/// hardware's rim by up to that much, ``rimGap``. The housing alone decides where the chart is
/// nil, and the rim's antialiasing reads the distance outside it, ``Chart/rimDistance``, not
/// the spine's offset. The sliver between the rim and the spine charts to offsets down to
/// `−rimGap`. The body's inner half covers it, so the liquid still meets the hardware, and its
/// visible lip at each corner's middle is that much thicker.
///
/// **The fillet's plateau bounds the band film.** Offsets of a concave arc converge on its
/// centre and collapse there at `n = R_p`: the metric vanishes, the whole plateau is equally
/// near, and `∇s` diverges. Anything drawn over a fillet must stay thinner than the fillet's
/// `0.87690ρe` to keep a unique nearest point. The taper holds the fillets, the ears and the
/// top of each wall to `bandFilm` below it, so the drawn film's metric never falls below
/// `1 − bandFilm/R_p`, 0.113 for the 3.5 pt film on the 4.5 pt fillet.
struct MercurySpine: Sendable, Equatable {
    /// The camera housing, in canvas-local points.
    ///
    /// The housing is the region between the walls and above the bottom edge, minus the two
    /// rounded bottom corners. It continues up into the bezel past the screen's top edge.
    struct Outline: Sendable, Equatable {
        /// The housing's left wall.
        var minX: Double
        /// The housing's right wall.
        var maxX: Double
        /// The housing's bottom edge.
        var bottom: Double
        /// The screen's top edge, which is also the canvas top.
        var top: Double
        /// ρ, the radius of the housing's circular convex bottom corners, and the footprint of
        /// the spine's eased corners. Use 0.44 × the housing height, clamped to 6…16 pt.
        /// ``MercurySpine/init(collar:)`` clamps it further so no run is negative.
        var cornerRadius: Double
        /// ρe, the footprint of the concave fillet that turns each wall into the screen's top
        /// edge: 4.5 pt.
        var filletRadius: Double
        /// E, how far the collar runs along the top edge beyond each fillet: 56 pt.
        var earLength: Double
        /// The outward thickness cap inside the menu-bar band: 3.5 pt. It must stay below the
        /// fillet's plateau radius, `0.87690 × filletRadius`; see the type's discussion.
        var bandFilm: Double
        /// The deepest half-height the chin may draw below the housing: the collar's ceiling and
        /// its taper's unit. Only the body's outer half shows below the housing, so a collar
        /// ceiling above the island's 17 pt is what lets its chin read as a body.
        var maxHalfHeight: Double
    }

    /// The line the ribbon is laid on.
    enum Kind: Sendable, Equatable {
        /// The island: along `y = 0` from `x = −length/2` to `+length/2`.
        case straight(length: Double)
        /// The collar, laid along the housing outline. The outline carries the corner radius
        /// actually laid, after ``MercurySpine/init(collar:)`` clamps it.
        case collar(Outline)
    }

    /// The arc length of each primitive. The corner, wall, fillet and ear values are per side,
    /// so a collar is `bottom + 2 (corner + wall + fillet + ear)` long. A straight spine is all
    /// bottom. A corner or a fillet is its eased bend's `1.62051` times its radius.
    struct Regions: Sendable, Equatable {
        var bottom: Double
        var corner: Double
        var wall: Double
        var fillet: Double
        var ear: Double
    }

    /// One point's curvilinear coordinates and the frame of its nearest spine point.
    struct Chart: Sendable, Equatable {
        /// `s`, the arc length of the nearest spine point.
        ///
        /// Past either end the chart continues along the straight end run, so `s` leaves
        /// `[0, length]` there. The field still finds either a span or a cap.
        var arcLength: Double
        /// `n`, the signed distance from that point, positive on the side ``normal`` points to.
        var normalOffset: Double
        /// The unit tangent of the left-to-right traversal.
        var tangent: SIMD2<Double>
        /// The unit normal.
        ///
        /// On the collar it is `(T.y, −T.x)`, the right-hand normal of the left-to-right
        /// traversal, which points out of the housing everywhere: down along the ears and the
        /// bottom, outward on the walls. The straight spine keeps the island's +y, so the
        /// island's top edge stays its top edge.
        var normal: SIMD2<Double>
        /// `1 + κn`, always positive here: `∇s = tangent / metric` and `∇n = normal`.
        var metric: Double
        /// The nearest primitive is a horizontal straight run: the bottom, an ear or the
        /// straight spine. There `s` depends on `x` alone, so one pixel column can share one
        /// station sample.
        var isHorizontal: Bool
        /// The nearest primitive is the camera housing's own edge: a wall, a convex corner or
        /// the bottom run.
        ///
        /// Its inner side is the black housing, which has no chart, so a pixel straddling the
        /// hardware's rim is only partly the body's, by ``rimDistance``. The ears and the
        /// fillets meet the screen's top edge instead, which is the canvas edge, and the
        /// straight spine meets nothing.
        var bordersHousing: Bool
        /// The signed distance outside the camera housing's rounded outline, positive outside.
        ///
        /// A pixel centred this far outside the rim keeps only the share of itself that lies
        /// outside, so the rim's antialiasing reads this. On the walls and the bottom run it is
        /// ``normalOffset``. On a convex corner it is the distance outside the housing's own
        /// circular corner, which the eased spine stands up to ``MercurySpine/rimGap``
        /// outside. Infinite exactly where the chart does not border the housing, since no rim
        /// clips a pixel there.
        var rimDistance: Double
    }

    /// The foot of a point on a bend's curvature ramp, in the ramp's own frame.
    ///
    /// Every ramp is one curve, the left corner's wall-end ramp, reflected and scaled. Its
    /// frame starts at the straight run the ramp eases out of: `across` runs out along that
    /// run's normal, to the side the bend turns away from, and `along` runs on along the run's
    /// own direction, past its end.
    struct RampFoot: Sendable, Equatable {
        /// `τ ∈ [0, 1]`, how far along the ramp the foot lies, from its straight end.
        var fraction: Double
        /// The point's signed distance from the foot, positive on the `across` side.
        var normalOffset: Double
        /// `(sin θ, cos θ)` of the ramp's turn at the foot.
        var turn: SIMD2<Double>
        /// `|κ|` at the foot.
        var curvature: Double
        /// The Newton steps the foot took, the last being the step under 1e-10 pt. Nil when
        /// four did not converge and the safeguarded bisection found it instead.
        var newtonSteps: Int?
    }

    let kind: Kind
    /// The total arc length `S`.
    let length: Double
    /// The arc length on which a body with zero sway centres: the middle of the bottom run,
    /// or the middle of the straight spine.
    let restCenter: Double
    let regions: Regions
    /// How far the spine's convex corners stand outside the housing's circular rim at most,
    /// `√2·c_p + R_p − ρ = 0.04873ρ`, at the middle of each corner. A corner's chart reaches
    /// this far below the spine, into the sliver between the two. Zero on the island.
    let rimGap: Double
    /// The least metric `1 + κn` a convex corner's chart reaches: its offsets go down to
    /// `−rimGap`, where `κ` is at most the plateau's `1/R_p`, so `1 − rimGap/R_p = 0.94443` at
    /// every radius. 1 on the island, which has no corners.
    let leastCornerMetric: Double
    /// The laid convex corners and concave fillets. All zero on the island.
    private let corners: Bend
    private let fillets: Bend

    /// The taper's unit: the largest half-height a station may draw. On the island it is the
    /// 17 pt the 34 pt envelope holds; on the collar it is the outline's own chin ceiling. The
    /// simulation's containment gauge proves the same bound, so a taper of 1 is exactly the full
    /// body.
    let maxHalfHeight: Double

    /// How far down each wall the taper swells from the band film to the full body, from the
    /// fillet's end.
    ///
    /// The collar frames the notch, so its sides are the full body: a film there read as no frame
    /// at all, a lozenge under the notch. Only where the walls meet the screen's top edge must
    /// the body thin, to the film a fillet's plateau can hold, and to stay nearer its wall than
    /// the top edge: a wall's offsets chart onto the wall only up to the bisector of the two,
    /// as far out as the point lies below the edge. The blend therefore runs over the top 12 pt
    /// of each wall, a smoothstep in arc length, slow enough that the deepest live wall keeps
    /// inside that bisector. A wall shorter than that hands the rest of the blend to its corner.
    private static let taperBlendLength = 12.0

    /// The ramps' Newton step limit, and the step under which the foot has converged.
    private static let newtonStepLimit = 4
    private static let footTolerance = 1e-10

    /// The island: along `y = 0` from `x = −length/2` to `+length/2`, with `N = +y`.
    init(straightLength: Double) {
        kind = .straight(length: straightLength)
        length = straightLength
        restCenter = straightLength / 2
        regions = Regions(bottom: straightLength, corner: 0, wall: 0, fillet: 0, ear: 0)
        rimGap = 0
        leastCornerMetric = 1
        maxHalfHeight = Double(MercuryMetrics.maxHalfHeight)
        corners = .none
        fillets = .none
    }

    /// The collar laid along a housing outline.
    ///
    /// The corner radius is clamped to `min(ρ, (top − bottom) − ρe, (maxX − minX)/2)`. Then
    /// the wall `(top − ρe) − (bottom + ρ)` and the bottom `width − 2ρ` are never negative. A
    /// housing too short or too narrow for its nominal corner gets the roundest corner that
    /// still meets its fillet and its twin, and the curve stays G³.
    ///
    /// Traps unless the housing has width, stands taller than its fillet, has a positive
    /// corner, and carries a band film thinner than the fillet's plateau radius and no thicker
    /// than its chin ceiling. The layout must only lay a collar on such a housing.
    init(collar outline: Outline) {
        let width = outline.maxX - outline.minX
        let height = outline.top - outline.bottom
        precondition(
            width > 0 && height > outline.filletRadius && outline.cornerRadius > 0
                && outline.earLength >= 0 && outline.bandFilm > 0
                && outline.bandFilm < BendShape.plateauRadius * outline.filletRadius
                && outline.bandFilm <= outline.maxHalfHeight,
            "a collar needs a housing taller than its fillet and a band film thinner than the fillet's plateau"
        )
        // The height left for the wall and the corner once the fillet has turned.
        let wallSpan = height - outline.filletRadius
        var laid = outline
        laid.cornerRadius = Swift.min(outline.cornerRadius, wallSpan, width / 2)
        let corners = Bend(radius: laid.cornerRadius)
        let fillets = Bend(radius: outline.filletRadius)
        let rimGap = 2.0.squareRoot() * corners.plateauInset + corners.plateauRadius - laid.cornerRadius
        self.corners = corners
        self.fillets = fillets
        self.rimGap = rimGap
        leastCornerMetric = 1 - rimGap / corners.plateauRadius
        maxHalfHeight = outline.maxHalfHeight
        let regions = Regions(
            bottom: width - 2 * laid.cornerRadius,
            corner: corners.arc,
            wall: wallSpan - laid.cornerRadius,
            fillet: fillets.arc,
            ear: outline.earLength
        )
        kind = .collar(laid)
        self.regions = regions
        restCenter = regions.ear + regions.fillet + regions.wall + regions.corner + regions.bottom / 2
        length = 2 * restCenter
    }

    /// The spine point at arc length `s`. Past either end it continues along the end run.
    func point(at s: Double) -> SIMD2<Double> {
        guard case .collar(let outline) = kind else {
            return SIMD2(s - length / 2, 0)
        }
        let mirrored = s > restCenter
        let half = halfPoint(at: mirrored ? length - s : s, outline: outline)
        return SIMD2(mirrored ? outline.maxX + half.outside : outline.minX - half.outside, half.y)
    }

    /// The unit tangent and normal at `s`, and the signed curvature `κ`: the rate at which the
    /// tangent turns counter-clockwise.
    ///
    /// `dT/ds = −κN` and `dN/ds = κT`, so the offset curve at `n` runs at speed `1 + κn`.
    /// Across a convex corner `κ` rises from 0 along its first ramp to the plateau's `1/R_p`,
    /// holds it, and falls back to 0 along its last ramp; across a concave fillet it does the
    /// same below zero. It is 0 on straight runs.
    func frame(at s: Double) -> (tangent: SIMD2<Double>, normal: SIMD2<Double>, curvature: Double) {
        guard case .collar(let outline) = kind else {
            return (SIMD2(1, 0), SIMD2(0, 1), 0)
        }
        let mirrored = s > restCenter
        let (tangent, curvature) = halfFrame(at: mirrored ? length - s : s, outline: outline)
        let oriented = mirrored ? SIMD2(tangent.x, -tangent.y) : tangent
        return (oriented, SIMD2(oriented.y, -oriented.x), curvature)
    }

    /// The exact nearest spine point to `p`.
    ///
    /// Each primitive owns a normal domain: a slab for a straight run, or for a bend the
    /// quadrant between the normals at its two ends, which meet at its circle's centre. A
    /// bend's plateau has its own wedge, between the normals at its two ends, which meet at
    /// its centre; its foot is radial there. The curve is G³, and the ears continue straight
    /// past their ends, so it has no free endpoint. Therefore the nearest point always lies in
    /// the domain of the primitive that owns it.
    ///
    /// A point only needs the primitives whose domains contain it, and the nearest of those.
    /// At most two ever compete: an ear against the wall or the lower corner beside it. Every
    /// other case is decided by its slab or wedge alone, in closed form, except where the foot
    /// lies on a bend's ramp; there ``rampFoot(across:along:concave:)`` finds it. The right
    /// half is folded onto the left, so both sides run the same arithmetic.
    ///
    /// Returns nil strictly inside the housing (including its circular corners, and extending
    /// up into the bezel) and above the screen's top edge. A fillet's offsets are unique below
    /// its plateau's radius. Deeper, toward the circle's centre, the nearest point is still
    /// found, even where it is not unique. The straight spine never answers nil.
    func chart(at p: SIMD2<Double>) -> Chart? {
        guard case .collar(let outline) = kind else {
            return Chart(
                arcLength: p.x + length / 2,
                normalOffset: p.y,
                tangent: SIMD2(1, 0),
                normal: SIMD2(0, 1),
                metric: 1,
                isHorizontal: true,
                bordersHousing: false,
                rimDistance: .infinity
            )
        }
        guard p.y <= outline.top else { return nil }
        let depth = outline.top - p.y
        let rise = p.y - outline.bottom
        let leftOutside = outline.minX - p.x
        let rightOutside = p.x - outline.maxX
        guard rightOutside > leftOutside else {
            return halfChart(outside: leftOutside, depth: depth, rise: rise, outline: outline)
        }
        guard let half = halfChart(outside: rightOutside, depth: depth, rise: rise, outline: outline) else {
            return nil
        }
        return reflected(half)
    }

    /// The foot of a point on a convex corner's ramp, or with `concave`, a fillet's, in the
    /// ramp's own frame. See ``RampFoot``.
    ///
    /// Newton's method on the tangent-orthogonality `f(u) = (p − C(u))·T(u)`, whose rate along
    /// the arc is `−(1 + κn)`, so each step is `f/(1 + κn)`. It starts from the foot itself,
    /// tabulated over the ramp's region, and stops at the first step under 1e-10 pt, within
    /// four. The foot is the point that step reaches, with its frame carried along the step to
    /// first order, which is exact to rounding at that size. On the dense grids of the tests,
    /// every corner's ramp, and a fillet's anywhere in the drawn film, needs at most four.
    ///
    /// Otherwise a safeguarded bisection on `f` finishes it, from where Newton stopped.
    /// `f(0) = along ≥ 0`, and `f(1)` is the point's side of the plateau's end normal, which
    /// is negative on the ramp's own side, so `[0, 1]` brackets the foot.
    func rampFoot(across: Double, along: Double, concave: Bool) -> RampFoot {
        Self.rampFoot(across: across, along: along, bend: concave ? fillets : corners)
    }

    /// Kept out of line: a few hundred pixels a frame reach a ramp, and inlined into
    /// ``chart(at:)`` its loop would weigh on the closed-form path every other pixel takes.
    @inline(never)
    private static func rampFoot(across: Double, along: Double, bend: Bend) -> RampFoot {
        let seed = BendShape.seed(across: across * bend.inverseRamp, along: along * bend.inverseRamp)
        return solveRamp(across: across, along: along, bend: bend, from: seed)
    }

    /// Newton from `seed`, then the safeguarded bisection if four steps do not converge.
    private static func solveRamp(across: Double, along: Double, bend: Bend, from seed: Double) -> RampFoot {
        var fraction = seed
        for step in 1...Self.newtonStepLimit {
            let probe = Self.probeRamp(at: fraction, across: across, along: along, bend: bend)
            let rate = 1 + probe.curvature * probe.normalOffset
            // Past the ramp's centre of curvature `f` rises again, and Newton points away.
            guard rate > 0 else { break }
            let next = Swift.min(Swift.max(fraction + probe.orthogonality / rate * bend.inverseRamp, 0), 1)
            let moved = (next - fraction) * bend.ramp
            guard abs(moved) > Self.footTolerance else {
                let turned = probe.curvature * moved
                return RampFoot(
                    fraction: next,
                    normalOffset: probe.normalOffset,
                    turn: SIMD2(probe.turn.x + turned * probe.turn.y, probe.turn.y - turned * probe.turn.x),
                    curvature: probe.curvature + probe.curvatureSlope * moved,
                    newtonSteps: step
                )
            }
            fraction = next
        }
        return Self.bracketedRampFoot(across: across, along: along, bend: bend, from: fraction)
    }

    /// The fraction of ``maxHalfHeight`` that the body may draw at arc length `s`, in `(0, 1]`.
    ///
    /// - It is 1 along the bottom run, which is the chin under the notch, around both corners
    ///   and up each wall, and along the whole straight spine.
    /// - It is `bandFilm/maxHalfHeight` on the fillets and the ears, which turn into the screen's
    ///   top edge.
    /// - Across the top ``taperBlendLength`` of each wall it is a smoothstep in arc length from
    ///   the film to the full body, flat at both ends, so the taper is C¹ and the edge has no
    ///   kink.
    ///
    /// So the body frames the notch on three sides and thins only where it meets the bezel.
    func taper(at s: Double) -> Double {
        guard case .collar(let outline) = kind else { return 1 }
        let local = s > restCenter ? length - s : s
        let film = outline.bandFilm / outline.maxHalfHeight
        let fraction = (local - leftJoins.wall) / taperBlendSpan
        if fraction <= 0 { return film }
        if fraction >= 1 { return 1 }
        let blend = fraction * fraction * (3 - 2 * fraction)
        // A convex combination keeps both plateaus exact: the film itself above the blend, 1 below.
        return (1 - blend) * film + blend
    }

    /// `dT/ds`, the taper's exact rate along the spine.
    ///
    /// It is zero everywhere but across each wall's blend, where it is the smoothstep's
    /// derivative in arc length, `(1 − film) · 6f(1 − f) / ℓ` over the blend's length `ℓ`. So
    /// the taper rises toward the bottom run on the left half and falls away from it on the
    /// right.
    ///
    /// The field tapers the body at the very arc length it evaluates, never at its stations
    /// alone, and this is the slope its normals read. A blend is only 12 pt long, so a taper
    /// sampled every few points of arc would draw it as facets.
    func taperSlope(at s: Double) -> Double {
        guard case .collar(let outline) = kind else { return 0 }
        let mirrored = s > restCenter
        let local = mirrored ? length - s : s
        let span = taperBlendSpan
        let fraction = (local - leftJoins.wall) / span
        guard fraction > 0, fraction < 1 else { return 0 }
        let film = outline.bandFilm / outline.maxHalfHeight
        let rate = (1 - film) * 6 * fraction * (1 - fraction) / span
        return mirrored ? -rate : rate
    }

    /// The taper's least and greatest values over the arc lengths `start…end`, and its
    /// steepest `|dT/ds|` there. `start` must not exceed `end`.
    ///
    /// The taper only ever rises toward the bottom run. Over any range it is least at one end
    /// and greatest at the point nearest ``restCenter``. Its slope is one smoothstep bump per
    /// wall, steepest where the blend is half done, and falling away to either side. Over any
    /// range it is steepest at the point nearest a bump's peak. So these are exact extremes,
    /// and the field bounds each piece of the body by them without sampling the taper.
    func taperBounds(from start: Double, to end: Double) -> (least: Double, greatest: Double, steepest: Double) {
        guard case .collar = kind else { return (1, 1, 0) }
        func nearest(_ s: Double) -> Double { Swift.min(Swift.max(s, start), end) }
        let peak = leftJoins.wall + taperBlendSpan / 2
        return (
            Swift.min(taper(at: start), taper(at: end)),
            taper(at: nearest(restCenter)),
            Swift.max(abs(taperSlope(at: nearest(peak))), abs(taperSlope(at: nearest(length - peak))))
        )
    }

    /// The length of each wall's blend: ``taperBlendLength``, or less where the half reaches its
    /// middle sooner, so the body's centre is always full.
    private var taperBlendSpan: Double {
        Swift.min(Self.taperBlendLength, restCenter - leftJoins.wall)
    }

    /// The largest untapered edge the body may lay at arc length `s` under `ceiling`: the
    /// ceiling itself, except beside a wall or a corner.
    ///
    /// There the screen's top edge, which the ears lie along, competes for every point. An
    /// offset `d` out from a foot `h` below the edge stays nearer that foot only while
    /// `d(1 − |N_y|) < h`: past the bisector it charts onto the bezel, where the body is film, and
    /// a side that reached it would be cut off there. So the drawn edge, the taper times this
    /// reach, stops ``bisectorMargin`` short of the bisector, which also covers the rise of the
    /// edge between two of the body's stations. The simulation's containment gauge holds every
    /// station to the reach at the arc length the field lays it, so this is a proof, as the
    /// ceiling is.
    func reach(at s: Double, under ceiling: Double) -> Double {
        guard case .collar(let outline) = kind else { return ceiling }
        let local = s > restCenter ? length - s : s
        let joins = leftJoins
        guard local >= joins.wall, local < joins.bottom else { return ceiling }
        let rise = 1 - abs(frame(at: s).normal.y)
        guard rise > 0 else { return ceiling }
        let bisector = (outline.top - point(at: s).y) / rise
        return Swift.min(ceiling, (bisector - Self.bisectorMargin) / taper(at: s))
    }

    /// Points the drawn edge keeps short of a wall's bisector. One point covers the edge's rise
    /// between two stations across the steepest blend, and the coverage ramp beyond it.
    private static let bisectorMargin = 1.0

    // MARK: - The left half

    /// The arc lengths at which the left half's fillet, wall, corner and bottom begin. The
    /// right half is the mirror image at `length − s`.
    private var leftJoins: (fillet: Double, wall: Double, corner: Double, bottom: Double) {
        let wall = regions.ear + regions.fillet
        let corner = wall + regions.wall
        return (regions.ear, wall, corner, corner + regions.corner)
    }

    /// The left half's point at arc length `s ≤ restCenter`. Returns its distance outside
    /// the left wall (negative under the housing) and its canvas `y`.
    ///
    /// Each bend is laid from its ends: a ramp from the straight run it eases out of, the
    /// plateau from its own centre, so every piece meets its neighbours.
    private func halfPoint(at s: Double, outline: Outline) -> (outside: Double, y: Double) {
        let joins = leftJoins
        let fillet = outline.filletRadius
        let corner = outline.cornerRadius
        if s < joins.fillet {
            return (fillet + (joins.fillet - s), outline.top)
        }
        if s < joins.wall {
            // From the ear's end: the ear-end ramp, the plateau, then the wall-end ramp.
            let along = s - joins.fillet
            if along < fillets.ramp {
                let position = Self.rampPoint(at: along, of: fillets)
                return (fillet - position.y, outline.top - position.x)
            }
            let back = joins.wall - s
            if back < fillets.ramp {
                let position = Self.rampPoint(at: back, of: fillets)
                return (position.x, outline.top - fillet + position.y)
            }
            let turn = BendShape.rampAngle + (along - fillets.ramp) / fillets.plateauRadius
            let inset = fillets.plateauInset
            return (
                fillet - inset - fillets.plateauRadius * sin(turn),
                outline.top - fillet + inset + fillets.plateauRadius * cos(turn)
            )
        }
        if s < joins.corner {
            return (0, outline.top - fillet - (s - joins.wall))
        }
        if s < joins.bottom {
            // From the wall's end: the wall-end ramp, the plateau, then the bottom-end ramp.
            let along = s - joins.corner
            if along < corners.ramp {
                let position = Self.rampPoint(at: along, of: corners)
                return (-position.x, outline.bottom + corner - position.y)
            }
            let back = joins.bottom - s
            if back < corners.ramp {
                let position = Self.rampPoint(at: back, of: corners)
                return (position.y - corner, outline.bottom + position.x)
            }
            let turn = BendShape.rampAngle + (along - corners.ramp) / corners.plateauRadius
            let inset = corners.plateauInset
            return (
                inset + corners.plateauRadius * cos(turn) - corner,
                outline.bottom + corner - inset - corners.plateauRadius * sin(turn)
            )
        }
        return (-corner - (s - joins.bottom), outline.bottom)
    }

    /// The left half's tangent, in canvas axes, and signed curvature at `s ≤ restCenter`.
    private func halfFrame(at s: Double, outline: Outline) -> (tangent: SIMD2<Double>, curvature: Double) {
        let joins = leftJoins
        if s < joins.fillet { return (SIMD2(1, 0), 0) }
        if s < joins.wall {
            let along = s - joins.fillet
            if along < fillets.ramp {
                let ramp = Self.rampFrame(at: along, of: fillets)
                return (SIMD2(ramp.turn.y, -ramp.turn.x), -ramp.curvature)
            }
            let back = joins.wall - s
            if back < fillets.ramp {
                let ramp = Self.rampFrame(at: back, of: fillets)
                return (SIMD2(ramp.turn.x, -ramp.turn.y), -ramp.curvature)
            }
            let turn = BendShape.rampAngle + (along - fillets.ramp) / fillets.plateauRadius
            return (SIMD2(cos(turn), -sin(turn)), -1 / fillets.plateauRadius)
        }
        if s < joins.corner { return (SIMD2(0, -1), 0) }
        if s < joins.bottom {
            let along = s - joins.corner
            if along < corners.ramp {
                let ramp = Self.rampFrame(at: along, of: corners)
                return (SIMD2(ramp.turn.x, -ramp.turn.y), ramp.curvature)
            }
            let back = joins.bottom - s
            if back < corners.ramp {
                let ramp = Self.rampFrame(at: back, of: corners)
                return (SIMD2(ramp.turn.y, -ramp.turn.x), ramp.curvature)
            }
            let turn = BendShape.rampAngle + (along - corners.ramp) / corners.plateauRadius
            return (SIMD2(sin(turn), -cos(turn)), 1 / corners.plateauRadius)
        }
        return (SIMD2(1, 0), 0)
    }

    /// The left half's chart, decided by slabs and wedges.
    ///
    /// - Parameters:
    ///   - outside: The distance beyond the nearer wall, negative between the walls.
    ///   - depth: The distance below the screen's top edge, never negative here.
    ///   - rise: The height above the housing's bottom edge, negative below it.
    private func halfChart(outside: Double, depth: Double, rise: Double, outline: Outline) -> Chart? {
        let joins = leftJoins
        let fillet = outline.filletRadius
        let corner = outline.cornerRadius
        if outside <= -corner {
            // Between the corner centres, only the bottom run faces the screen.
            guard rise <= 0 else { return nil }
            return Self.horizontalRun(
                arcLength: joins.bottom - corner - outside,
                normalOffset: -rise,
                bordersHousing: true
            )
        }
        if outside >= 0, outside < fillet, depth < fillet {
            // Up and toward the wall from the fillet's circle centre, which is excluded, only
            // the fillet's quadrant reaches. It is laid from the wall's end, toward the ear, and
            // its offsets run toward its centre, against its frame's.
            let foot = Self.bendFoot(lateral: fillet - outside, vertical: fillet - depth, radius: fillet, bend: fillets)
            return Chart(
                arcLength: joins.wall - foot.along,
                normalOffset: -foot.offset,
                tangent: foot.tangent,
                normal: SIMD2(foot.tangent.y, -foot.tangent.x),
                metric: foot.metric,
                isHorizontal: false,
                bordersHousing: false,
                rimDistance: .infinity
            )
        }
        // Past the fillet centre's column only the ear's slab reaches. It competes with
        // whichever of the corner and the wall owns this height.
        let earDistance = outside >= fillet ? depth : Double.infinity
        if rise < corner {
            // Below the corner centre lies the corner's quadrant.
            let lateral = outside + corner
            let vertical = corner - rise
            let distance = (lateral * lateral + vertical * vertical).squareRoot()
            // Inside the housing's circular corner, which only a point between the walls can reach.
            guard distance >= corner else { return nil }
            let rim = distance - corner
            // The spine never stands more than `rimGap` outside the rim, so an ear nearer than
            // that is decided before the corner's own foot is sought.
            if earDistance > rim - rimGap {
                let foot = Self.bendFoot(lateral: lateral, vertical: vertical, radius: corner, bend: corners)
                if earDistance > foot.offset {
                    return Chart(
                        arcLength: joins.corner + foot.along,
                        normalOffset: foot.offset,
                        tangent: foot.tangent,
                        normal: SIMD2(foot.tangent.y, -foot.tangent.x),
                        metric: foot.metric,
                        isHorizontal: false,
                        bordersHousing: true,
                        rimDistance: rim
                    )
                }
            }
            return Self.horizontalRun(
                arcLength: joins.fillet + (fillet - outside),
                normalOffset: depth,
                bordersHousing: false
            )
        }
        // At or above the corner centre, between the walls is the housing; beside them is the
        // wall's slab.
        guard outside >= 0 else { return nil }
        guard depth >= fillet, outside < earDistance else {
            return Self.horizontalRun(
                arcLength: joins.fillet + (fillet - outside),
                normalOffset: depth,
                bordersHousing: false
            )
        }
        return Chart(
            arcLength: joins.wall + (depth - fillet),
            normalOffset: outside,
            tangent: SIMD2(0, -1),
            normal: SIMD2(-1, 0),
            metric: 1,
            isHorizontal: false,
            bordersHousing: true,
            rimDistance: outside
        )
    }

    /// An ear or the bottom run: tangent +x, normal −y, and `s` a function of `x` alone. Only
    /// the bottom run borders the housing.
    private static func horizontalRun(arcLength: Double, normalOffset: Double, bordersHousing: Bool) -> Chart {
        Chart(
            arcLength: arcLength,
            normalOffset: normalOffset,
            tangent: SIMD2(1, 0),
            normal: SIMD2(0, -1),
            metric: 1,
            isHorizontal: true,
            bordersHousing: bordersHousing,
            rimDistance: bordersHousing ? normalOffset : .infinity
        )
    }

    /// The right half's chart, from its mirror image on the left.
    ///
    /// The arc length runs back from the far end. Mirroring flips x, and walking the curve
    /// backwards flips the tangent again. So the tangent keeps its x and negates its y, and
    /// the normal, still pointing out of the housing, negates its x.
    private func reflected(_ chart: Chart) -> Chart {
        Chart(
            arcLength: length - chart.arcLength,
            normalOffset: chart.normalOffset,
            tangent: SIMD2(chart.tangent.x, -chart.tangent.y),
            normal: SIMD2(-chart.normal.x, chart.normal.y),
            metric: chart.metric,
            isHorizontal: chart.isHorizontal,
            bordersHousing: chart.bordersHousing,
            rimDistance: chart.rimDistance
        )
    }

    // MARK: - Bends

    /// An eased bend as laid: the convex corners at `ρ`, or the concave fillets at `ρe`.
    ///
    /// In its own frame a bend runs from `(r, 0)` to `(0, r)`, bulging toward `(r, r)`, with
    /// its circle's centre at the origin. A corner's frame measures `(lateral, vertical)` out
    /// of the housing from the corner's circle centre, a fillet's into the screen's corner
    /// from its own, so the one shape serves both.
    private struct Bend: Sendable, Equatable {
        /// `S`, the bend's whole arc length.
        var arc: Double
        /// `L = qS`, each curvature ramp's arc length.
        var ramp: Double
        /// `R_p`, the plateau arc's radius.
        var plateauRadius: Double
        /// `c`, how far the plateau's centre sits from the circle's centre along each axis,
        /// toward the bend's corner.
        var plateauInset: Double
        /// `(sin θ_q, cos θ_q)`, where each ramp hands over to the plateau. The same for every
        /// bend; kept here so the chart's wedge test reads no global.
        var edge: SIMD2<Double>
        /// `1/L`, which every Newton step divides by.
        var inverseRamp: Double
        /// `1/2R_p`: a ramp's `|κ|` is this times `1 − cos πτ`.
        var rampCurvature: Double

        /// The island's, which has no bends.
        static let none = Bend(
            arc: 0,
            ramp: 0,
            plateauRadius: 0,
            plateauInset: 0,
            edge: .zero,
            inverseRamp: 0,
            rampCurvature: 0
        )

        init(
            arc: Double,
            ramp: Double,
            plateauRadius: Double,
            plateauInset: Double,
            edge: SIMD2<Double>,
            inverseRamp: Double,
            rampCurvature: Double
        ) {
            self.arc = arc
            self.ramp = ramp
            self.plateauRadius = plateauRadius
            self.plateauInset = plateauInset
            self.edge = edge
            self.inverseRamp = inverseRamp
            self.rampCurvature = rampCurvature
        }

        /// The bend that keeps a circle of radius `radius`'s footprint.
        ///
        /// The wall-end ramp ends `L·â(1)` across and `L·b̂(1)` down, and the plateau's centre
        /// lies `R_p` back along its normal there. The plateau then reaches the bottom-end
        /// ramp, the same curve mirrored across the diagonal, exactly when the footprint holds.
        init(radius: Double) {
            let arc = radius / BendShape.footprint
            let ramp = BendShape.rampShare * arc
            let plateauRadius = arc / BendShape.plateauTurnRate
            let end = BendShape.rampTable[BendShape.rampIntervals]
            self.init(
                arc: arc,
                ramp: ramp,
                plateauRadius: plateauRadius,
                plateauInset: radius - ramp * end.position.x - plateauRadius * end.tangent.y,
                edge: end.tangent,
                inverseRamp: 1 / ramp,
                rampCurvature: 1 / (2 * plateauRadius)
            )
        }
    }

    /// A point's nearest point on a bend, in the bend's own frame, mapped back to canvas axes.
    private struct BendFoot {
        /// The foot's arc length from the bend's `(r, 0)` end.
        var along: Double
        /// The signed distance, positive toward the bend's corner `(r, r)`.
        var offset: Double
        /// The canvas tangent of the left half's traversal. A corner's frame is the canvas
        /// turned half round and walked from `(r, 0)`; a fillet's is the canvas itself, walked
        /// toward `(r, 0)`. Either way it is the frame's tangent reversed.
        var tangent: SIMD2<Double>
        /// `1 + κn`, the same in either orientation.
        var metric: Double
    }

    /// The foot on `bend` of the point `(lateral, vertical)` in its frame, which must lie in
    /// the bend's quadrant.
    ///
    /// The plateau's end normals meet at its centre and split the quadrant. Between them its
    /// foot is radial. Beyond either lies that ramp's region; a point behind the centre lies
    /// beyond both, and the nearer of the two ramps' feet is its own. The bottom-end ramp is
    /// the wall-end one reflected across the diagonal, so its frame swaps the axes.
    private static func bendFoot(lateral: Double, vertical: Double, radius: Double, bend: Bend) -> BendFoot {
        let fromCentre = SIMD2(lateral - bend.plateauInset, vertical - bend.plateauInset)
        // Each side's value is `(p − C)·T` at that end of the plateau: negative past it.
        let wallSide = bend.edge.y * fromCentre.y - bend.edge.x * fromCentre.x
        let bottomSide = bend.edge.y * fromCentre.x - bend.edge.x * fromCentre.y
        guard wallSide < 0 || bottomSide < 0 else {
            let distance = (fromCentre * fromCentre).sum().squareRoot()
            // The centre itself is equally near the whole plateau; it takes the middle.
            let direction = distance > 0 ? fromCentre / distance : SIMD2(1, 1) / 2.0.squareRoot()
            return BendFoot(
                along: bend.ramp
                    + bend.plateauRadius * (atan2(direction.y, direction.x) - BendShape.rampAngle),
                offset: distance - bend.plateauRadius,
                tangent: SIMD2(direction.y, -direction.x),
                metric: distance / bend.plateauRadius
            )
        }
        var nearest: BendFoot?
        if wallSide < 0 {
            let foot = Self.rampFoot(across: lateral - radius, along: vertical, bend: bend)
            nearest = BendFoot(
                along: bend.ramp * foot.fraction,
                offset: foot.normalOffset,
                tangent: SIMD2(foot.turn.x, -foot.turn.y),
                metric: 1 + foot.curvature * foot.normalOffset
            )
        }
        if bottomSide < 0 {
            let foot = Self.rampFoot(across: vertical - radius, along: lateral, bend: bend)
            if nearest.map({ abs(foot.normalOffset) < abs($0.offset) }) ?? true {
                nearest = BendFoot(
                    along: bend.arc - bend.ramp * foot.fraction,
                    offset: foot.normalOffset,
                    tangent: SIMD2(foot.turn.y, -foot.turn.x),
                    metric: 1 + foot.curvature * foot.normalOffset
                )
            }
        }
        // One side is negative, so one ramp was solved.
        return nearest!
    }

    /// The wall-end ramp's point `arc` along it from its straight end, in points: inward
    /// and on along the run, in the ramp's own frame.
    private static func rampPoint(at arc: Double, of bend: Bend) -> SIMD2<Double> {
        BendShape.ramp(at: arc / bend.ramp).position * bend.ramp
    }

    /// The wall-end ramp's turn and `|κ|`, `arc` along it from its straight end.
    private static func rampFrame(at arc: Double, of bend: Bend) -> (turn: SIMD2<Double>, curvature: Double) {
        let state = BendShape.state(at: arc / bend.ramp)
        return (state.turn, rampCurvature(of: state, bend: bend).curvature)
    }

    /// A ramp's `|κ|` and `d|κ|/du` from its phase: `|κ| = (1 − cos πτ)/2R_p`, the
    /// `κ_p·sin²(πτ/2)` that turns it through `θ_q(τ − sin(πτ)/π)`.
    @inline(__always)
    private static func rampCurvature(
        of state: BendShape.RampState,
        bend: Bend
    ) -> (curvature: Double, slope: Double) {
        ((1 - state.phase.y) * bend.rampCurvature, Double.pi * state.phase.x * bend.rampCurvature * bend.inverseRamp)
    }

    /// Everything one Newton step reads at `τ`: `f`, the point's offset from the ramp
    /// there, and the ramp's frame.
    private struct RampProbe {
        var orthogonality: Double
        var normalOffset: Double
        var turn: SIMD2<Double>
        var curvature: Double
        var curvatureSlope: Double
    }

    @inline(__always)
    private static func probeRamp(at fraction: Double, across: Double, along: Double, bend: Bend) -> RampProbe {
        let sample = BendShape.ramp(at: fraction)
        let curvature = rampCurvature(of: sample.state, bend: bend)
        let turn = sample.state.turn
        let position = sample.position * bend.ramp
        // `p − C(τ)`, with the ramp curling away from `across` and running on along `along`.
        let offset = SIMD2(across + position.x, along - position.y)
        return RampProbe(
            orthogonality: offset.y * turn.y - offset.x * turn.x,
            normalOffset: offset.x * turn.y + offset.y * turn.x,
            turn: turn,
            curvature: curvature.curvature,
            curvatureSlope: curvature.slope
        )
    }

    /// The foot by safeguarded bisection, from where Newton stopped: a Newton step whenever
    /// it stays inside the bracket and at least halves the step before it, and a bisection
    /// otherwise, so the bracket always closes.
    @inline(never)
    private static func bracketedRampFoot(across: Double, along: Double, bend: Bend, from start: Double) -> RampFoot {
        var low = 0.0
        var high = 1.0
        var fraction = start
        var previousStep = 1.0
        for _ in 0..<64 {
            let probe = probeRamp(at: fraction, across: across, along: along, bend: bend)
            if probe.orthogonality > 0 { low = fraction } else { high = fraction }
            let rate = (1 + probe.curvature * probe.normalOffset) * bend.ramp
            let newton = rate > 0 ? probe.orthogonality / rate : .infinity
            let step: Double
            if abs(2 * newton) <= previousStep, fraction + newton > low, fraction + newton < high {
                step = newton
            } else {
                step = (low + high) / 2 - fraction
            }
            previousStep = abs(step)
            fraction += step
            guard abs(step) * bend.ramp > footTolerance else { break }
        }
        let probe = probeRamp(at: fraction, across: across, along: along, bend: bend)
        return RampFoot(
            fraction: fraction,
            normalOffset: probe.normalOffset,
            turn: probe.turn,
            curvature: probe.curvature,
            newtonSteps: nil
        )
    }

    /// The eased bend, the same shape at every radius.
    private enum BendShape {
        /// `q`, each curvature ramp's share of the bend's arc length.
        static let rampShare = 0.15
        /// `κ̂ = π/2(1 − q)`, the plateau's turn per unit of the bend's arc length. Each ramp
        /// turns as much as half its length of plateau would, so the plateau turns a quarter
        /// turn's worth over `(1 − q)` of the arc.
        static let plateauTurnRate = Double.pi / (2 * (1 - rampShare))
        /// `θ_q = κ̂q/2 = 7.94°`, each ramp's whole turn.
        static let rampAngle = plateauTurnRate * rampShare / 2
        /// Intervals in ``rampTable``.
        static let rampIntervals = 256

        /// The wall-end ramp at one table node `τ = k/256`.
        struct RampNode {
            /// `(â, b̂)`, the ramp's position from the wall's end, in towards the bend's centre
            /// and on along the wall, in units of the ramp's length.
            var position: SIMD2<Double>
            /// `(sin θ, cos θ)` of its turn, which is also `d(â, b̂)/dτ`.
            var tangent: SIMD2<Double>
            /// `(sin πτ, cos πτ)`, which the turn and the curvature are made of.
            var phase: SIMD2<Double>
        }

        /// The wall-end ramp, node by node.
        ///
        /// Integrated once, by eight-point Gauss–Legendre on each interval, which is exact to
        /// rounding at this spacing. Cubic Hermite on the exact tangents then interpolates it
        /// to 3e-12 pt on the largest corner, `ρ = 16`.
        static let rampTable: [RampNode] = {
            // Gauss–Legendre on [−1, 1], by symmetric pairs.
            let abscissae = [
                0.183_434_642_495_649_8, 0.525_532_409_916_329_0, 0.796_666_477_413_626_7, 0.960_289_856_497_536_3,
            ]
            let weights = [
                0.362_683_783_378_362_0, 0.313_706_645_877_887_3, 0.222_381_034_453_374_5, 0.101_228_536_290_376_3,
            ]
            let width = 1 / Double(rampIntervals)
            var table: [RampNode] = []
            table.reserveCapacity(rampIntervals + 1)
            var position = SIMD2<Double>.zero
            for index in 0...rampIntervals {
                let start = Double(index) * width
                let turn = turnAngle(at: start)
                table.append(
                    RampNode(
                        position: position,
                        tangent: SIMD2(sin(turn), cos(turn)),
                        phase: SIMD2(sin(Double.pi * start), cos(Double.pi * start))
                    )
                )
                guard index < rampIntervals else { break }
                var step = SIMD2<Double>.zero
                for (abscissa, weight) in zip(abscissae, weights) {
                    for side in [-1.0, 1.0] {
                        let turn = turnAngle(at: start + width * (1 + side * abscissa) / 2)
                        step += weight * SIMD2(sin(turn), cos(turn))
                    }
                }
                position += step * (width / 2)
            }
            return table
        }()
        /// `r/S = 0.61709`, a bend's footprint per unit of its arc length. The wall-end ramp
        /// runs `L·â(1)` across and `L·b̂(1)` down, the plateau `R_p(cos θ_q − sin θ_q)` each
        /// way, and the bottom-end ramp mirrors the wall-end one.
        static let footprint: Double = {
            let end = rampTable[rampIntervals]
            return rampShare * (end.position.x + end.position.y) + (end.tangent.y - end.tangent.x) / plateauTurnRate
        }()
        /// `R_p/r = 0.87690`.
        static let plateauRadius = 1 / (footprint * plateauTurnRate)

        /// The wall-end ramp's own foot `τ` over its region, in units of the ramp's length:
        /// the Newton seed. Every ramp is this one curve at some scale, so one grid serves all.
        struct SeedGrid {
            /// `τ`, column by column of `across` and row by row of how far along the region.
            var feet: [Double]
            /// `(b̂(1) + â(1)·tan θ_q, tan θ_q)`: the plateau's start normal, where the region
            /// ends, runs along `edge.x + across·edge.y`.
            var edge: SIMD2<Double>
        }

        /// The grid's columns run `across` from −3.5 to 16.5 in halves, which holds a fillet's
        /// drawn film inside its turn and a corner's chin out to the ears. Its rows run in
        /// sixteenths from the straight run's end normal, `along = 0`, to the plateau's start
        /// normal.
        static let seedColumns = 41
        static let seedRows = 17
        static let seedAcrossStart = -3.5
        static let seedAcrossStep = 0.5

        /// Solved once, column by column, each foot seeded by the one before it, from `τ = 0`
        /// on the end normal. Bilinear between them the seed lands close enough that Newton's
        /// quadratic steps converge within four.
        static let seeds: SeedGrid = {
            let end = rampTable[rampIntervals]
            let slope = end.tangent.x / end.tangent.y
            let edge = SIMD2(end.position.y + end.position.x * slope, slope)
            let plateauRadius = 1 / (plateauTurnRate * rampShare)
            let unit = Bend(
                arc: 1 / rampShare,
                ramp: 1,
                plateauRadius: plateauRadius,
                plateauInset: 0,
                edge: end.tangent,
                inverseRamp: 1,
                rampCurvature: 1 / (2 * plateauRadius)
            )
            var feet = [Double](repeating: 0, count: seedColumns * seedRows)
            for column in 0..<seedColumns {
                let across = seedAcrossStart + Double(column) * seedAcrossStep
                let reach = edge.x + across * edge.y
                var fraction = 0.0
                for row in 0..<seedRows {
                    let along = reach * Double(row) / Double(seedRows - 1)
                    fraction = solveRamp(across: across, along: along, bend: unit, from: fraction).fraction
                    feet[column * seedRows + row] = fraction
                }
            }
            return SeedGrid(feet: feet, edge: edge)
        }()

        /// The seed for a point `across` and `along` in units of the ramp's length: the grid's
        /// feet, bilinear, clamped to its edges.
        @inline(__always)
        static func seed(across: Double, along: Double) -> Double {
            let grid = seeds
            let reach = Swift.max(grid.edge.x + across * grid.edge.y, 1e-9)
            let column = Swift.min(
                Swift.max((across - seedAcrossStart) / seedAcrossStep, 0),
                Double(seedColumns - 1)
            )
            let row = Swift.min(Swift.max(along / reach * Double(seedRows - 1), 0), Double(seedRows - 1))
            let left = Swift.min(Int(column), seedColumns - 2)
            let low = Swift.min(Int(row), seedRows - 2)
            let sideways = column - Double(left)
            let upward = row - Double(low)
            let base = left * seedRows + low
            let lower = grid.feet[base] + (grid.feet[base + seedRows] - grid.feet[base]) * sideways
            let upper = grid.feet[base + 1] + (grid.feet[base + seedRows + 1] - grid.feet[base + 1]) * sideways
            return lower + (upper - lower) * upward
        }

        /// A ramp's turn at `τ`: `θ_q(τ − sin(πτ)/π)`, whose rate is `θ_q(1 − cos πτ)`.
        static func turnAngle(at fraction: Double) -> Double {
            rampAngle * (fraction - sin(Double.pi * fraction) / Double.pi)
        }

        /// The wall-end ramp's phase `(sin πτ, cos πτ)` and turn `(sin θ, cos θ)` at one `τ`.
        struct RampState {
            var phase: SIMD2<Double>
            var turn: SIMD2<Double>
        }

        /// The wall-end ramp at `τ ∈ [0, 1]`: its position in units of its length, by cubic
        /// Hermite between the table's nodes on their exact tangents, exact at both ends; and
        /// its phase and turn.
        @inline(__always)
        static func ramp(at fraction: Double) -> (position: SIMD2<Double>, state: RampState) {
            let (index, offset) = node(at: fraction)
            let start = rampTable[index]
            let end = rampTable[index + 1]
            let squared = offset * offset
            let cubed = squared * offset
            let tangentScale = 1 / Double(rampIntervals)
            let startWeight = 2 * cubed - 3 * squared + 1
            let endWeight = 3 * squared - 2 * cubed
            let startTangent = (cubed - 2 * squared + offset) * tangentScale
            let endTangent = (cubed - squared) * tangentScale
            return (
                startWeight * start.position + endWeight * end.position + startTangent * start.tangent
                    + endTangent * end.tangent,
                state(from: start, offset: offset)
            )
        }

        /// The ramp's phase and turn at `τ ∈ [0, 1]`.
        @inline(__always)
        static func state(at fraction: Double) -> RampState {
            let (index, offset) = node(at: fraction)
            return state(from: rampTable[index], offset: offset)
        }

        /// The table node at or below `τ ∈ [0, 1]`, and how far past it `τ` lies, in intervals.
        @inline(__always)
        private static func node(at fraction: Double) -> (index: Int, offset: Double) {
            let scaled = fraction * Double(rampIntervals)
            let index = Swift.min(Int(scaled), rampIntervals - 1)
            return (index, scaled - Double(index))
        }

        /// The phase and turn `offset` of an interval past `node`, each the node's own turned
        /// on by a small angle, so neither needs a transcendental call.
        ///
        /// The phase turns by `δ = π·offset/256 ≤ 0.0123`, whose sine and `cos δ − 1` Taylor
        /// gives to under 1e-17 by `δ⁵` and `δ⁶`. That also gives `sin πτ − sin πτ_k` without
        /// cancelling, so the turn's own step, `θ_q((τ − τ_k) − (sin πτ − sin πτ_k)/π)`, at
        /// most `2θ_q/256 = 1.1e-3`, is exact too; its sine and `cos − 1` need only its cube
        /// and fourth power.
        @inline(__always)
        private static func state(from node: RampNode, offset: Double) -> RampState {
            let delta = Double.pi / Double(rampIntervals) * offset
            let deltaSquared = delta * delta
            let deltaSine = delta * (1 - deltaSquared / 6 * (1 - deltaSquared / 20))
            let deltaDrop = -deltaSquared / 2 * (1 - deltaSquared / 12 * (1 - deltaSquared / 30))
            let rise = node.phase.x * deltaDrop + node.phase.y * deltaSine
            let phase = SIMD2(node.phase.x + rise, node.phase.y + node.phase.y * deltaDrop - node.phase.x * deltaSine)
            let step = rampAngle * (offset / Double(rampIntervals) - rise * (1 / Double.pi))
            let stepSquared = step * step
            let stepSine = step * (1 - stepSquared / 6)
            let stepDrop = -stepSquared / 2 * (1 - stepSquared / 12)
            let turn = SIMD2(
                node.tangent.x + node.tangent.x * stepDrop + node.tangent.y * stepSine,
                node.tangent.y + node.tangent.y * stepDrop - node.tangent.x * stepSine
            )
            return RampState(phase: phase, turn: turn)
        }
    }
}
