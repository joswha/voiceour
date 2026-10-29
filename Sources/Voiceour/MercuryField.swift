import CoreGraphics

/// The single evaluator that pixels, the drag predicate and the cursor region all read.
///
/// There is exactly one geometry representation in this app: the `top` and `bottom`
/// arrays the simulation emits. This type lays them on the spine once, and every reader
/// interpolates that one table. Nothing rebuilds the edges and nothing keeps a second
/// description of them, which is what makes "the clickable region is the drawn silhouette"
/// a structural fact rather than something two code paths have to agree on.
///
/// The body is a ribbon in the spine's chart `(s, n)`. Its span runs `L` along the spine,
/// centred on `restCenter + lateralOffset`, and station `j` sits at material coordinate
/// `a = j/96`. Inside the span the field is `φ = r − |n − c|`. Beyond it, it is the exact
/// Euclidean distance to the cap centre, so both ends are full rounds with no cut, no
/// needle, and no separately generated cap to seam. Where the spine has no chart (under the
/// camera housing, or above the screen's top edge) there is no body at all: nothing there is
/// drawn and nothing is hit.
///
/// **The taper is applied where the field is read.** The stations keep the simulation's own
/// half-thickness `r₀` and centre `c₀`. A point at arc length `s` reads `r = T(s)·r₀(a)` and
/// `c = T(s)·c₀(a)`, with `T` the spine's taper at `s` itself, so along the body
/// `r_s = T′·r₀ + T·r₀_a/L`, and likewise for `c`. A convex corner blends from the chin to
/// the band film over about 10 pt of arc, which is only a few stations. A taper sampled at
/// the stations would draw that blend as straight facets and tilt every normal between them.
/// Read continuously, the outline and its normals follow the true taper.
///
/// Coordinates are canvas-local: origin at the canvas centre, +y up, points.
struct MercuryField {
    /// The laid ribbon at one arc length.
    struct StationSample: Equatable {
        /// Half the local thickness, `r = (n₊ − n₋)/2`.
        var radius: Double
        /// The centre line's normal offset from the spine, `c = (n₊ + n₋)/2`.
        var center: Double
        /// `dr/da`, per unit of the material coordinate. The taper's share, `T′·r₀` per point
        /// of arc, rides at the `max(L, 1)` points per unit of `a` that
        /// ``sample(at:chart:station:)`` divides back out, so it reaches the gradient whole.
        var radiusSlope: Double
        /// `dc/da`, per unit of the material coordinate, carried the same way.
        var centerSlope: Double
    }

    /// Everything the shading and the hit test of one point read.
    struct Sample: Equatable {
        /// Signed, positive inside.
        var value: Double
        /// `∇φ`, in canvas axes. Antialiasing reads its length; the surface normal reads all of it.
        var gradient: SIMD2<Double>
        /// The local half-thickness the crown is lifted to.
        var radius: Double
        /// `∇r`. Without it the silhouette's thickness could change along the body while the
        /// reflection stayed mechanically straight. Zero on a cap, which has one radius.
        var radiusGradient: SIMD2<Double>
    }

    /// A box around one piece of the body, and how far past it the coverage ramp reaches.
    ///
    /// The rasterizer covers a pixel of size `h` only where `φ > −½·h·|∇φ|`. Inside the span
    /// `φ` falls by exactly one per point of normal offset past an edge, so a covered centre
    /// lies at most `½·h·|∇φ|` past its piece, along the normal; beyond the span the cap is a
    /// true distance, with `|∇φ| = 1`. Every pixel centre the rasterizer can cover therefore
    /// lies in some extent's box grown by `rampReach · h`, which is what lets it skip every
    /// pixel outside them.
    struct Extent: Equatable {
        /// The box's least corner, canvas-local.
        var lower: SIMD2<Double>
        /// The box's greatest corner, canvas-local.
        var upper: SIMD2<Double>
        /// Half the steepest `|∇φ|` the piece can have: the ramp's reach past the box, in
        /// pixels. Zero for a box that already holds every point its piece can chart.
        var rampReach: Double
    }

    /// One station, untapered. The steps are the finite differences the island always took,
    /// per station index. ``stationSample(at:)`` scales them to `d/da` only after interpolating,
    /// in that order, so the island's pixels keep their exact bits.
    private struct Station {
        var radius: Double
        var center: Double
        var radiusStep: Double
        var centerStep: Double
    }

    /// The curve the body is laid on.
    let spine: MercurySpine
    /// The whole canvas in the field's own coordinates: `(−w/2, −h/2, w, h)`.
    let canvasBounds: CGRect
    /// The union of ``extents``, inflated by `MercuryMetrics.bleed` and intersected with the
    /// canvas. Empty when no station has any thickness, because then nothing can ever be drawn.
    let boundingBox: CGRect
    /// The body, piece by piece, as boxes that hold all of it: each station interval split
    /// where the spine changes primitive, the square of every fillet the span reaches, and
    /// both caps. See ``Extent``. Empty, like ``boundingBox``, when nothing can be drawn.
    let extents: [Extent]
    /// The body length `L`, in points of arc length.
    let length: Double
    /// The arc length of the body's leading end: `restCenter + lateralOffset − L/2`.
    let spanStart: Double

    private let stations: [Station]
    /// `restCenter + lateralOffset`, the arc length the span is centred on. The material
    /// coordinate is measured from here, as the island always measured it from its centre,
    /// so on the island's pixel grid every step of it is exact.
    private let middle: Double
    /// The arc length of the body's trailing end, `spanStart + L`.
    private let spanEnd: Double
    /// `L` as the slopes divide by it. A body drained below one point would divide its rates
    /// by almost nothing, so they are taken per point there, as the rasterizer always took them.
    private let slopeLength: Double
    /// `P_e = point(s_e) + c_e N(s_e)`, the centres of the leading and trailing caps.
    private let leadCapCenter: SIMD2<Double>
    private let trailCapCenter: SIMD2<Double>
    /// True on the straight spine, the island.
    ///
    /// Its taper is 1 everywhere, so it reads its stations untouched, in the arithmetic it
    /// always has. Every point and both ends lie on one straight run, so a cap's offset
    /// `(s − s_e, n − c_e)` is exact in the chart itself, which is the island's historical
    /// arithmetic bit for bit. A collar's end can sit on an arc while a point beyond it charts
    /// onto the neighbouring primitive, so there the offset is taken in canvas axes.
    private let isStraight: Bool

    /// - Parameters:
    ///   - geometry: One simulated frame: its length, lateral offset and station edges.
    ///   - spine: The curve to lay the body on.
    ///   - canvas: The canvas size in points. The field's origin is the canvas centre.
    init(geometry: MercurySimulation.Geometry, spine: MercurySpine, canvas: CGSize) {
        self.spine = spine
        canvasBounds = CGRect(
            x: -canvas.width / 2,
            y: -canvas.height / 2,
            width: canvas.width,
            height: canvas.height
        )
        length = Double(geometry.length)
        slopeLength = Swift.max(length, 1)
        middle = spine.restCenter + Double(geometry.lateralOffset)
        spanStart = middle - length / 2
        spanEnd = spanStart + length
        if case .straight = spine.kind {
            isStraight = true
        } else {
            isStraight = false
        }

        let last = geometry.top.count - 1
        var laid = [Station](
            repeating: Station(radius: 0, center: 0, radiusStep: 0, centerStep: 0),
            count: last + 1
        )
        var drawable = false
        for index in 0...last {
            let upper = Double(geometry.top[index])
            let lower = Double(geometry.bottom[index])
            laid[index].radius = (upper - lower) / 2
            laid[index].center = (upper + lower) / 2
            drawable = drawable || laid[index].radius > 0
        }
        for index in 0...last {
            let low = Swift.max(index - 1, 0)
            let high = Swift.min(index + 1, last)
            laid[index].radiusStep = (laid[high].radius - laid[low].radius) / Double(high - low)
            laid[index].centerStep = (laid[high].center - laid[low].center) / Double(high - low)
        }
        stations = laid

        // Each cap keeps its own end's taper, so it rounds off exactly the ribbon it closes.
        let leadTaper = spine.taper(at: spanStart)
        let trailTaper = spine.taper(at: spanEnd)
        leadCapCenter = Self.capCenter(at: spanStart, center: leadTaper * laid[0].center, spine: spine)
        trailCapCenter = Self.capCenter(at: spanEnd, center: trailTaper * laid[last].center, spine: spine)

        // A body with no thickness anywhere can never be drawn, so it has no extent at all.
        guard drawable else {
            extents = []
            boundingBox = .null
            return
        }
        var pieces = Self.pieces(
            of: laid,
            spine: spine,
            spanStart: spanStart,
            length: length,
            slopeLength: slopeLength
        )
        Self.appendCap(at: leadCapCenter, radius: leadTaper * laid[0].radius, to: &pieces)
        Self.appendCap(at: trailCapCenter, radius: trailTaper * laid[last].radius, to: &pieces)
        extents = pieces

        var lowest = SIMD2<Double>(repeating: .greatestFiniteMagnitude)
        var highest = SIMD2<Double>(repeating: -.greatestFiniteMagnitude)
        for extent in pieces {
            lowest = pointwiseMin(lowest, extent.lower)
            highest = pointwiseMax(highest, extent.upper)
        }
        let bleed = Double(MercuryMetrics.bleed)
        let extent = CGRect(
            x: lowest.x - bleed,
            y: lowest.y - bleed,
            width: highest.x - lowest.x + 2 * bleed,
            height: highest.y - lowest.y + 2 * bleed
        )
        // The canvas is the absolute envelope: the bleed exists so the coverage ramp is not
        // cut, never so the body can reach past the canvas.
        boundingBox = extent.intersection(canvasBounds)
    }

    /// Signed, positive inside, and `−greatestFiniteMagnitude` where the spine has no chart.
    func value(at point: CGPoint) -> CGFloat {
        guard let sample = sample(at: SIMD2(Double(point.x), Double(point.y))) else {
            return -.greatestFiniteMagnitude
        }
        return CGFloat(sample.value)
    }

    /// Analytic gradient of ``value(at:)``, used for antialiasing and for the surface normal.
    /// Zero where the spine has no chart.
    func gradient(at point: CGPoint) -> CGVector {
        guard let sample = sample(at: SIMD2(Double(point.x), Double(point.y))) else {
            return CGVector(dx: 0, dy: 0)
        }
        return CGVector(dx: sample.gradient.x, dy: sample.gradient.y)
    }

    /// The field at `point`, or nil where the spine has no chart: under the housing, or above
    /// the screen's top edge.
    func sample(at point: SIMD2<Double>) -> Sample? {
        guard let chart = spine.chart(at: point) else { return nil }
        return sample(at: point, chart: chart, station: stationSample(at: chart.arcLength))
    }

    /// The field at `point`, from its chart and the station sample at the chart's arc length.
    ///
    /// ``sample(at:)`` and the rasterizer both end here. The rasterizer hands in the sample it
    /// memoized for a pixel column, which is the value ``stationSample(at:)`` returns for that
    /// arc length, so the drawn pixel and the hit test still evaluate one function.
    ///
    /// In the span the gradient is `φ_s ∇s + φ_n ∇n` with `∇s = T / metric` and `∇n = N`: the
    /// metric scales only the rate along the body, so a crest wrapped around a convex corner
    /// leans less and one pressed into a concave fillet leans more.
    @inline(__always)
    func sample(at point: SIMD2<Double>, chart: MercurySpine.Chart, station: StationSample) -> Sample {
        let half = length / 2
        let along = chart.arcLength - middle
        let offset = chart.normalOffset - station.center
        guard along < -half || along > half else {
            let sign: Double = offset >= 0 ? 1 : -1
            // One product, so the straight spine's unit metric divides exactly as the island did.
            let rateLength = slopeLength * chart.metric
            return Sample(
                value: station.radius - abs(offset),
                gradient: (station.radiusSlope + sign * station.centerSlope) / rateLength * chart.tangent
                    - sign * chart.normal,
                radius: station.radius,
                radiusGradient: station.radiusSlope / rateLength * chart.tangent
            )
        }
        let leading = along < -half
        let delta: SIMD2<Double>
        if isStraight {
            delta = (along - (leading ? -half : half)) * chart.tangent + offset * chart.normal
        } else {
            delta = point - (leading ? leadCapCenter : trailCapCenter)
        }
        let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        return Sample(
            value: station.radius - distance,
            gradient: distance > 1e-9 ? -delta / distance : SIMD2(0, -1),
            radius: station.radius,
            radiusGradient: .zero
        )
    }

    /// The one station interpolation: the laid ribbon at arc length `s`, with `a` clamped to
    /// `[0, 1]`, so beyond either end it is that end's station, at that end's taper. Linear
    /// between stations; the slopes are the stations' finite differences, interpolated the
    /// same way, and then the taper at `s` scales the whole of it.
    @inline(__always)
    func stationSample(at arcLength: Double) -> StationSample {
        let half = length / 2
        let along = arcLength - middle
        let clamped = Swift.min(Swift.max(along, -half), half)
        let material = length > 0 ? (clamped + half) / length : 0
        let last = stations.count - 1
        let position = material * Double(last)
        let index = Swift.min(Int(position), last)
        let fraction = position - Double(index)
        let next = Swift.min(index + 1, last)
        let low = stations[index]
        let high = stations[next]
        let scale = Double(last)
        let radius = Self.mix(low.radius, high.radius, fraction)
        let center = Self.mix(low.center, high.center, fraction)
        let radiusSlope = Self.mix(low.radiusStep, high.radiusStep, fraction) * scale
        let centerSlope = Self.mix(low.centerStep, high.centerStep, fraction) * scale
        guard !isStraight else {
            return StationSample(radius: radius, center: center, radiusSlope: radiusSlope, centerSlope: centerSlope)
        }
        let laidAt = along < -half ? spanStart : along > half ? spanEnd : arcLength
        let taper = spine.taper(at: laidAt)
        // `dT/da`, at the same points per unit of `a` the slopes are divided by.
        let taperRate = spine.taperSlope(at: laidAt) * slopeLength
        return StationSample(
            radius: taper * radius,
            center: taper * center,
            radiusSlope: taper * radiusSlope + taperRate * radius,
            centerSlope: taper * centerSlope + taperRate * center
        )
    }

    // MARK: - Extents

    /// The span's extents: each station interval, split wherever the spine hands over from one
    /// primitive to the next.
    ///
    /// Over a piece the edges are `T·e₊` and `T·e₋`. The untapered edges `e±` are linear
    /// between the piece's two stations, and the taper is bounded by its own exact extremes
    /// there, so one normal range `n₋…n₊` holds both edges. A piece lies on one primitive, so
    /// the region `P(s) + n·N(s)` over its arc lengths and that range is a rectangle on a
    /// straight run, or an annular sector inside one quadrant of a corner's centre. Either
    /// way its extremes in `x` and in `y` lie at its four corners, and their box holds all of
    /// it, with no sampling and no margin.
    ///
    /// On a collar the inner half lies under the housing or above the screen. Only a fillet
    /// charts an offset below zero, into the crescent against the hardware's concave corner.
    /// So elsewhere a piece's range starts at the spine, and a piece on a fillet gives way to
    /// the fillet's whole square, which holds every point the fillet charts. That includes the
    /// points near the fillet's centre, where the metric vanishes and no bound on `|∇φ|`
    /// exists.
    ///
    /// The ramp's reach comes from the steepest climb the edges can make along the piece,
    /// `|φ_s| ≤ T·|e_a|/max(L, 1) + |T′|·|e|`. Off the fillets the metric is at least 1, so
    /// `|∇φ| = √(1 + (φ_s/metric)²)` is never steeper than `√(1 + φ_s²)`.
    private static func pieces(
        of stations: [Station],
        spine: MercurySpine,
        spanStart: Double,
        length: Double,
        slopeLength: Double
    ) -> [Extent] {
        let last = stations.count - 1
        let joins = Self.joins(of: spine)
        let outline: MercurySpine.Outline?
        if case .collar(let laid) = spine.kind {
            outline = laid
        } else {
            outline = nil
        }
        var extents: [Extent] = []
        extents.reserveCapacity(last + joins.count + 4)
        var reachesLeftFillet = false
        var reachesRightFillet = false
        var join = 0
        var end = spanStart
        var endFoot = Self.foot(at: end, on: spine)
        for index in 0..<last {
            let low = stations[index]
            let high = stations[index + 1]
            // The untapered edges, their sizes and their rates are linear between the two
            // stations, so the stations' own values bound them over the whole interval.
            let outerEdge = Swift.max(low.center + low.radius, high.center + high.radius)
            let innerEdge = Swift.min(low.center - low.radius, high.center - high.radius)
            let size = Swift.max(abs(low.center) + abs(low.radius), abs(high.center) + abs(high.radius))
            let rate =
                Swift.max(abs(low.centerStep) + abs(low.radiusStep), abs(high.centerStep) + abs(high.radiusStep))
                * Double(last) / slopeLength

            /// Lays the piece from `start` to `finish`, which lie on one primitive.
            func lay(from start: Double, _ startFoot: Foot, to finish: Double, _ finishFoot: Foot) {
                let halfway = (start + finish) / 2
                if outline != nil, spine.frame(at: halfway).curvature < 0 {
                    if halfway < spine.restCenter {
                        reachesLeftFillet = true
                    } else {
                        reachesRightFillet = true
                    }
                    return
                }
                let taper = spine.taperBounds(from: start, to: finish)
                var outer = outerEdge >= 0 ? taper.greatest * outerEdge : taper.least * outerEdge
                var inner = innerEdge >= 0 ? taper.least * innerEdge : taper.greatest * innerEdge
                if outline != nil {
                    outer = Swift.max(outer, 0)
                    inner = Swift.max(inner, 0)
                }
                let corners = (
                    startFoot.point + inner * startFoot.normal,
                    startFoot.point + outer * startFoot.normal,
                    finishFoot.point + inner * finishFoot.normal,
                    finishFoot.point + outer * finishFoot.normal
                )
                let climb = taper.greatest * rate + taper.steepest * size
                extents.append(
                    Extent(
                        lower: pointwiseMin(pointwiseMin(corners.0, corners.1), pointwiseMin(corners.2, corners.3)),
                        upper: pointwiseMax(pointwiseMax(corners.0, corners.1), pointwiseMax(corners.2, corners.3)),
                        rampReach: 0.5 * (1 + climb * climb).squareRoot()
                    )
                )
            }

            var start = end
            var startFoot = endFoot
            end = spanStart + length * Double(index + 1) / Double(last)
            endFoot = Self.foot(at: end, on: spine)
            while join < joins.count, joins[join] < end {
                if joins[join] > start {
                    let joinFoot = Self.foot(at: joins[join], on: spine)
                    lay(from: start, startFoot, to: joins[join], joinFoot)
                    start = joins[join]
                    startFoot = joinFoot
                }
                join += 1
            }
            lay(from: start, startFoot, to: end, endFoot)
        }

        if let outline {
            let fillet = outline.filletRadius
            if reachesLeftFillet {
                extents.append(
                    Extent(
                        lower: SIMD2(outline.minX - fillet, outline.top - fillet),
                        upper: SIMD2(outline.minX, outline.top),
                        rampReach: 0
                    )
                )
            }
            if reachesRightFillet {
                extents.append(
                    Extent(
                        lower: SIMD2(outline.maxX, outline.top - fillet),
                        upper: SIMD2(outline.maxX + fillet, outline.top),
                        rampReach: 0
                    )
                )
            }
        }
        return extents
    }

    /// A cap's extent: it is one exact round, so its box is its disc's and `|∇φ| = 1`. A cap
    /// with no radius draws nothing.
    private static func appendCap(at center: SIMD2<Double>, radius: Double, to extents: inout [Extent]) {
        guard radius > 0 else { return }
        let reach = SIMD2<Double>(repeating: radius)
        extents.append(Extent(lower: center - reach, upper: center + reach, rampReach: 0.5))
    }

    /// A spine point and its unit normal.
    private typealias Foot = (point: SIMD2<Double>, normal: SIMD2<Double>)

    private static func foot(at arcLength: Double, on spine: MercurySpine) -> Foot {
        (spine.point(at: arcLength), spine.frame(at: arcLength).normal)
    }

    /// The arc lengths at which a collar hands over from one primitive to the next, ascending:
    /// ear, fillet, wall, corner and bottom, then back up the other side. The ears run on
    /// straight past both ends, so the ends are not joins. The straight spine has none.
    private static func joins(of spine: MercurySpine) -> [Double] {
        guard case .collar = spine.kind else { return [] }
        let regions = spine.regions
        let fillet = regions.ear
        let wall = fillet + regions.fillet
        let corner = wall + regions.wall
        let bottom = corner + regions.corner
        return [
            fillet, wall, corner, bottom,
            spine.length - bottom, spine.length - corner, spine.length - wall, spine.length - fillet,
        ]
    }

    // MARK: - Helpers

    private static func capCenter(at arcLength: Double, center: Double, spine: MercurySpine) -> SIMD2<Double> {
        spine.point(at: arcLength) + center * spine.frame(at: arcLength).normal
    }

    @inline(__always)
    private static func mix(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}
