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
/// - Offset curves around a convex corner are longer than the corner (`1 + n/ρ`). A crest
///   wrapped around it is stretched, and its slope along the body falls by exactly that factor.
/// - Around a concave fillet they are shorter (`1 − n/ρe`), and the slope steepens.
///
/// Using `T` alone would tilt every normal on the curved primitives by the wrong amount and
/// kink the reflection at each join. With the metric, the normal is the true surface normal
/// and stays continuous along the C¹ curve.
///
/// **The fillet radius bounds the band film.** Offsets of a concave arc converge on its
/// centre and collapse there at `n = ρe`: the metric vanishes, the whole arc is equally near,
/// and `∇s` diverges. Anything drawn over a fillet must stay thinner than `ρe` to keep a
/// unique nearest point. The taper holds walls, fillets and ears to `bandFilm < ρe`, so the
/// drawn film's metric never falls below `1 − bandFilm/ρe`.
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
        /// ρ, the housing's convex bottom corners. Use 0.44 × the housing height, clamped to
        /// 6…16 pt. ``MercurySpine/init(collar:)`` clamps it further so no run is negative.
        var cornerRadius: Double
        /// ρe, the concave fillet that turns each wall into the screen's top edge: 4.5 pt.
        var filletRadius: Double
        /// E, how far the collar runs along the top edge beyond each fillet: 56 pt.
        var earLength: Double
        /// The outward thickness cap inside the menu-bar band: 3.5 pt. It must stay below
        /// `filletRadius`; see the type's discussion.
        var bandFilm: Double
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
    /// bottom.
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
        /// Its inner side is the black housing, which has no chart, so ``normalOffset`` is
        /// the distance outside the hardware's rim, and a pixel straddling that rim is only
        /// partly the body's. The ears and the fillets meet the screen's top edge instead, which
        /// is the canvas edge, and the straight spine meets nothing.
        var bordersHousing: Bool
    }

    let kind: Kind
    /// The total arc length `S`.
    let length: Double
    /// The arc length on which a body with zero sway centres: the middle of the bottom run,
    /// or the middle of the straight spine.
    let restCenter: Double
    let regions: Regions

    /// The taper's unit: the largest half-height a station may draw. On the collar it is the
    /// chin's 17 pt below the notch. The simulation's containment gauge proves the same bound,
    /// so a taper of 1 is exactly the full body.
    static let maxHalfHeight = Double(MercuryMetrics.maxHalfHeight)

    /// Where the corner taper starts and finishes thinning, as the corner angle measured up
    /// from the bottom.
    ///
    /// Through the lowest 30° the corner is still the chin's shoulder, so it keeps full
    /// thickness and the chin stays one round piece. By 70° it is the foot of the wall, in the
    /// band beside the notch, so it is already film.
    private static let taperStartAngle = Double.pi / 6
    private static let taperEndAngle = 7 * Double.pi / 18

    /// The island: along `y = 0` from `x = −length/2` to `+length/2`, with `N = +y`.
    init(straightLength: Double) {
        kind = .straight(length: straightLength)
        length = straightLength
        restCenter = straightLength / 2
        regions = Regions(bottom: straightLength, corner: 0, wall: 0, fillet: 0, ear: 0)
    }

    /// The collar laid along a housing outline.
    ///
    /// The corner radius is clamped to `min(ρ, (top − bottom) − ρe, (maxX − minX)/2)`. Then
    /// the wall `(top − ρe) − (bottom + ρ)` and the bottom `width − 2ρ` are never negative. A
    /// housing too short or too narrow for its nominal corner gets the roundest corner that
    /// still meets its fillet and its twin, and the curve stays C¹.
    ///
    /// Traps unless the housing has width, stands taller than its fillet, has a positive
    /// corner, and carries a band film thinner than the fillet and no thicker than
    /// ``maxHalfHeight``. The layout must only lay a collar on such a housing.
    init(collar outline: Outline) {
        let width = outline.maxX - outline.minX
        let height = outline.top - outline.bottom
        precondition(
            width > 0 && height > outline.filletRadius && outline.cornerRadius > 0
                && outline.earLength >= 0 && outline.bandFilm > 0
                && outline.bandFilm < outline.filletRadius && outline.bandFilm <= Self.maxHalfHeight,
            "a collar needs a housing taller than its fillet and a band film thinner than the fillet"
        )
        // The height left for the wall and the corner once the fillet has turned.
        let wallSpan = height - outline.filletRadius
        var laid = outline
        laid.cornerRadius = Swift.min(outline.cornerRadius, wallSpan, width / 2)
        let quarterTurn = Double.pi / 2
        let regions = Regions(
            bottom: width - 2 * laid.cornerRadius,
            corner: quarterTurn * laid.cornerRadius,
            wall: wallSpan - laid.cornerRadius,
            fillet: quarterTurn * outline.filletRadius,
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
    /// `κ` is `1/ρ` on the convex corners, `−1/ρe` on the concave fillets and 0 on straight
    /// runs.
    func frame(at s: Double) -> (tangent: SIMD2<Double>, normal: SIMD2<Double>, curvature: Double) {
        guard case .collar(let outline) = kind else {
            return (SIMD2(1, 0), SIMD2(0, 1), 0)
        }
        let mirrored = s > restCenter
        let (tangent, curvature) = halfFrame(at: mirrored ? length - s : s, outline: outline)
        let oriented = mirrored ? SIMD2(tangent.x, -tangent.y) : tangent
        return (oriented, SIMD2(oriented.y, -oriented.x), curvature)
    }

    /// The exact nearest spine point to `p`, in closed form.
    ///
    /// Each primitive owns a normal domain: a slab for a straight run, or a quarter-plane
    /// wedge from the centre for an arc. The curve is C¹, and the ears continue straight past
    /// their ends, so it has no free endpoint. Therefore the nearest point always lies in the
    /// domain of the primitive that owns it.
    ///
    /// A point only needs the primitives whose domains contain it, and the nearest of those.
    /// At most two ever compete: an ear against the wall or the lower corner beside it. Every
    /// other case is decided by its slab or wedge alone, with no iteration and no sampling.
    /// The right half is folded onto the left, so both sides run the same arithmetic.
    ///
    /// Returns nil strictly inside the housing (including its rounded corners, and extending
    /// up into the bezel) and above the screen's top edge. A fillet's offsets are unique for
    /// `|n| < ρe`. The fillet centre is `ρe` from every point of the arc, and charts onto one
    /// end of the arc at `n = ρe`. The straight spine never answers nil.
    func chart(at p: SIMD2<Double>) -> Chart? {
        guard case .collar(let outline) = kind else {
            return Chart(
                arcLength: p.x + length / 2,
                normalOffset: p.y,
                tangent: SIMD2(1, 0),
                normal: SIMD2(0, 1),
                metric: 1,
                isHorizontal: true,
                bordersHousing: false
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

    /// The fraction of ``maxHalfHeight`` that the body may draw at arc length `s`, in `(0, 1]`.
    ///
    /// - It is 1 along the bottom run, which is the chin under the notch, and along the whole
    ///   straight spine.
    /// - It is `bandFilm/maxHalfHeight` on the walls, the fillets and the ears, which lie in
    ///   the menu-bar band beside the notch.
    /// - Across each convex corner it is a smoothstep in the corner angle. It is full at 30°
    ///   above the bottom and film at 70°, and flat at both ends, so the taper is C¹ and the
    ///   edge has no kink.
    ///
    /// So beside the notch, nothing thicker than the film rises above the corner centres.
    func taper(at s: Double) -> Double {
        guard case .collar(let outline) = kind else { return 1 }
        let joins = leftJoins
        let local = s > restCenter ? length - s : s
        let film = outline.bandFilm / Self.maxHalfHeight
        if local < joins.corner { return film }
        if local >= joins.bottom { return 1 }
        let fraction = blendFraction(atLocal: local, cornerStart: joins.corner, outline: outline)
        let clamped = Swift.min(Swift.max(fraction, 0), 1)
        let blend = clamped * clamped * (3 - 2 * clamped)
        // A convex combination keeps both plateaus exact: 1 through 30°, the film itself from 70°.
        return (1 - blend) + blend * film
    }

    /// `dT/ds`, the taper's exact rate along the spine.
    ///
    /// It is zero along every straight run, on the fillets, on both plateaus of each corner
    /// and along the whole straight spine. Across a corner's blend it is the smoothstep's
    /// derivative in the corner angle, `(film − 1) · 6f(1 − f) / (70° − 30°)`, times the
    /// angle's own rate along the spine, `∓1/ρ`. So the taper rises toward the bottom run on
    /// the left half and falls away from it on the right.
    ///
    /// The field tapers the body at the very arc length it evaluates, never at its stations
    /// alone, and this is the slope its normals read. A corner's blend is only about 10 pt
    /// long, so a taper sampled every few points of arc would draw it as facets.
    func taperSlope(at s: Double) -> Double {
        guard case .collar(let outline) = kind else { return 0 }
        let joins = leftJoins
        let mirrored = s > restCenter
        let local = mirrored ? length - s : s
        guard local >= joins.corner, local < joins.bottom else { return 0 }
        let fraction = blendFraction(atLocal: local, cornerStart: joins.corner, outline: outline)
        guard fraction > 0, fraction < 1 else { return 0 }
        let film = outline.bandFilm / Self.maxHalfHeight
        // On the left half, where the arc length is `local` itself, the blend runs against the
        // angle and the angle against the arc length, so the two signs cancel.
        let rate =
            (1 - film) * 6 * fraction * (1 - fraction)
            / ((Self.taperEndAngle - Self.taperStartAngle) * outline.cornerRadius)
        return mirrored ? -rate : rate
    }

    /// The taper's least and greatest values over the arc lengths `start…end`, and its
    /// steepest `|dT/ds|` there. `start` must not exceed `end`.
    ///
    /// The taper only ever rises toward the bottom run. Over any range it is least at one end
    /// and greatest at the point nearest ``restCenter``. Its slope is one smoothstep bump per
    /// corner, steepest where the blend is half done, 50° up the corner, and falling away to
    /// either side. Over any range it is steepest at the point nearest a bump's peak. So
    /// these are exact extremes, and the field bounds each piece of the body by them without
    /// sampling the taper.
    func taperBounds(from start: Double, to end: Double) -> (least: Double, greatest: Double, steepest: Double) {
        guard case .collar(let outline) = kind else { return (1, 1, 0) }
        func nearest(_ s: Double) -> Double { Swift.min(Swift.max(s, start), end) }
        let peak =
            leftJoins.corner
            + outline.cornerRadius * (Double.pi / 2 - (Self.taperStartAngle + Self.taperEndAngle) / 2)
        return (
            Swift.min(taper(at: start), taper(at: end)),
            taper(at: nearest(restCenter)),
            Swift.max(abs(taperSlope(at: nearest(peak))), abs(taperSlope(at: nearest(length - peak))))
        )
    }

    /// The smoothstep's argument at the left-half arc length `local`, unclamped: 0 at 30°
    /// above the bottom, where the taper is still full, and 1 at 70°, where it is the film.
    private func blendFraction(atLocal local: Double, cornerStart: Double, outline: Outline) -> Double {
        // The corner is laid wall first: its angle from the bottom falls from π/2 to 0.
        let angle = Double.pi / 2 - (local - cornerStart) / outline.cornerRadius
        return (angle - Self.taperStartAngle) / (Self.taperEndAngle - Self.taperStartAngle)
    }

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
    /// Arcs turn from their own start, so each primitive meets its predecessor's end.
    private func halfPoint(at s: Double, outline: Outline) -> (outside: Double, y: Double) {
        let joins = leftJoins
        let fillet = outline.filletRadius
        let corner = outline.cornerRadius
        if s < joins.fillet {
            return (fillet + (joins.fillet - s), outline.top)
        }
        if s < joins.wall {
            let turn = (s - joins.fillet) / fillet
            return (fillet * (1 - sin(turn)), outline.top - fillet * (1 - cos(turn)))
        }
        if s < joins.corner {
            return (0, outline.top - fillet - (s - joins.wall))
        }
        if s < joins.bottom {
            let turn = (s - joins.corner) / corner
            return (-corner * (1 - cos(turn)), outline.bottom + corner * (1 - sin(turn)))
        }
        return (-corner - (s - joins.bottom), outline.bottom)
    }

    /// The left half's tangent, in canvas axes, and signed curvature at `s ≤ restCenter`.
    private func halfFrame(at s: Double, outline: Outline) -> (tangent: SIMD2<Double>, curvature: Double) {
        let joins = leftJoins
        if s < joins.fillet { return (SIMD2(1, 0), 0) }
        if s < joins.wall {
            let turn = (s - joins.fillet) / outline.filletRadius
            return (SIMD2(cos(turn), -sin(turn)), -1 / outline.filletRadius)
        }
        if s < joins.corner { return (SIMD2(0, -1), 0) }
        if s < joins.bottom {
            let turn = (s - joins.corner) / outline.cornerRadius
            return (SIMD2(sin(turn), -cos(turn)), 1 / outline.cornerRadius)
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
            // Up and toward the wall from the fillet centre, which is excluded, only the
            // fillet's wedge reaches, so its foot is unique.
            let lateral = fillet - outside
            let vertical = fillet - depth
            let distance = (lateral * lateral + vertical * vertical).squareRoot()
            return Self.quarterArc(
                arcLength: joins.fillet + fillet * atan2(lateral, vertical),
                normalOffset: fillet - distance,
                lateral: lateral,
                vertical: vertical,
                distance: distance,
                radius: fillet,
                bordersHousing: false
            )
        }
        // Past the fillet centre's column only the ear's slab reaches. It competes with
        // whichever of the corner and the wall owns this height.
        let earDistance = outside >= fillet ? depth : Double.infinity
        if rise < corner {
            // Below the corner centre lies the corner's wedge.
            let lateral = outside + corner
            let vertical = corner - rise
            let distance = (lateral * lateral + vertical * vertical).squareRoot()
            // Inside the rounded corner, which only a point between the walls can reach.
            guard distance >= corner else { return nil }
            guard earDistance > distance - corner else {
                return Self.horizontalRun(
                    arcLength: joins.fillet + (fillet - outside),
                    normalOffset: depth,
                    bordersHousing: false
                )
            }
            return Self.quarterArc(
                arcLength: joins.corner + corner * atan2(vertical, lateral),
                normalOffset: distance - corner,
                lateral: lateral,
                vertical: vertical,
                distance: distance,
                radius: corner,
                bordersHousing: true
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
            bordersHousing: true
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
            bordersHousing: bordersHousing
        )
    }

    /// A left-half quarter arc, from the point's non-negative offsets from the arc centre in
    /// its own wedge. For a corner these run outward and down; for a fillet they run toward
    /// the wall and up. Either way the tangent is `(vertical, −lateral)/distance`, and the
    /// metric is `distance/radius`, which is `1 + κn` without the cancellation. Only a corner
    /// borders the housing.
    private static func quarterArc(
        arcLength: Double,
        normalOffset: Double,
        lateral: Double,
        vertical: Double,
        distance: Double,
        radius: Double,
        bordersHousing: Bool
    ) -> Chart {
        let tangent = SIMD2(vertical, -lateral) / distance
        return Chart(
            arcLength: arcLength,
            normalOffset: normalOffset,
            tangent: tangent,
            normal: SIMD2(tangent.y, -tangent.x),
            metric: distance / radius,
            isHorizontal: false,
            bordersHousing: bordersHousing
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
            bordersHousing: chart.bordersHousing
        )
    }
}
