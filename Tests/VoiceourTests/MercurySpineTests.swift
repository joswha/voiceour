import Foundation
import Testing

@testable import Voiceour

/// The line the body lies along, held to independent constructions of the same geometry.
///
/// Everything the collar draws, hits and shades reads its position through this chart. So
/// each property is checked against something the spine did not compute: the outline rebuilt
/// here from the housing rect, a brute-force nearest point over a 0.01 pt resampling, and
/// finite differences of the chart itself.
struct MercurySpineTests {
    /// A camera housing as the collar layout hangs it: centred on x = 0 and flush with the top
    /// of a canvas `height + 17 + 3` pt tall.
    private struct Housing {
        var width: Double
        var height: Double
        /// The menu-bar band on that display.
        var band: Double
        var cornerRadius: Double

        var outline: MercurySpine.Outline {
            let top = (height + 17 + 3) / 2
            return MercurySpine.Outline(
                minX: -width / 2,
                maxX: width / 2,
                bottom: top - height,
                top: top,
                cornerRadius: cornerRadius,
                filletRadius: 4.5,
                earLength: 56,
                bandFilm: 3.5
            )
        }
    }

    /// The two notch housings the display fixtures pin, with `ρ = 0.44 × height`.
    private static let realistic = [
        Housing(width: 185, height: 32, band: 33, cornerRadius: 0.44 * 32),
        Housing(width: 220, height: 38, band: 39, cornerRadius: 0.44 * 38),
    ]

    /// Housings whose nominal corner does not fit: one too short for any wall, and one too
    /// narrow for any bottom run.
    private static let clamped = [
        Housing(width: 185, height: 12, band: 13, cornerRadius: 16),
        Housing(width: 20, height: 32, band: 33, cornerRadius: 0.44 * 32),
    ]

    private static var everyHousing: [Housing] { realistic + clamped }

    // MARK: - The island

    /// The island is the canvas x axis: `s = x + L/2` and `n = y` exactly, everywhere. It has
    /// no taper and no housing to border.
    @Test func straightSpineIsTheIslandAxis() {
        let length = 168.0
        let spine = MercurySpine(straightLength: length)
        #expect(spine.kind == .straight(length: length))
        #expect(spine.length == length)
        #expect(spine.restCenter == length / 2)
        #expect(spine.regions == MercurySpine.Regions(bottom: length, corner: 0, wall: 0, fillet: 0, ear: 0))
        #expect(spine.point(at: spine.restCenter) == SIMD2<Double>.zero)

        var mismatches = 0
        for x in stride(from: -130.0, through: 130.0, by: 0.37) {
            for y in stride(from: -40.0, through: 40.0, by: 1.3) {
                let expected = MercurySpine.Chart(
                    arcLength: x + length / 2,
                    normalOffset: y,
                    tangent: SIMD2(1, 0),
                    normal: SIMD2(0, 1),
                    metric: 1,
                    isHorizontal: true,
                    bordersHousing: false
                )
                if spine.chart(at: SIMD2(x, y)) != expected { mismatches += 1 }
            }
            let s = x + length / 2
            let frame = spine.frame(at: s)
            if spine.point(at: s) != SIMD2(s - length / 2, 0) || frame.tangent != SIMD2(1, 0)
                || frame.normal != SIMD2(0, 1) || frame.curvature != 0 || spine.taper(at: s) != 1
                || spine.taperSlope(at: s) != 0 || spine.taperBounds(from: s - 3, to: s) != (1, 1, 0)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - The collar curve

    /// The primitives tile the spine: `bottom + 2 (corner + wall + fillet + ear) = S`, each
    /// at its closed-form arc length.
    @Test func regionsTileTheSpine() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let regions = spine.regions
            let corner = outline.cornerRadius
            let fillet = outline.filletRadius
            let sum = regions.bottom + 2 * (regions.corner + regions.wall + regions.fillet + regions.ear)
            #expect(abs(sum - spine.length) <= 1e-12 * spine.length)
            #expect(spine.restCenter == spine.length / 2)
            #expect(abs(regions.bottom - (outline.maxX - outline.minX - 2 * corner)) <= 1e-12)
            #expect(abs(regions.corner - Double.pi / 2 * corner) <= 1e-12)
            #expect(abs(regions.wall - ((outline.top - fillet) - (outline.bottom + corner))) <= 1e-12)
            #expect(abs(regions.fillet - Double.pi / 2 * fillet) <= 1e-12)
            #expect(regions.ear == outline.earLength)
            #expect(regions.bottom >= 0 && regions.wall >= 0)
        }
        let island = MercurySpine(straightLength: 180)
        #expect(island.regions.bottom == island.length)
    }

    /// A corner too big for its housing shrinks until the wall, or the bottom run, is exactly
    /// zero long. A corner that fits is laid as given.
    @Test func cornerRadiusClampsSoNoRunIsNegative() throws {
        for housing in Self.realistic {
            let laid = try #require(Self.laidOutline(of: MercurySpine(collar: housing.outline)))
            #expect(laid == housing.outline)
        }
        let short = MercurySpine(collar: Self.clamped[0].outline)
        let shortOutline = try #require(Self.laidOutline(of: short))
        #expect(shortOutline.cornerRadius == 12 - 4.5)
        #expect(short.regions.wall == 0)

        let narrow = MercurySpine(collar: Self.clamped[1].outline)
        let narrowOutline = try #require(Self.laidOutline(of: narrow))
        #expect(narrowOutline.cornerRadius == 10)
        #expect(narrow.regions.bottom == 0)
    }

    /// At each region boundary, `point(at:)` is the endpoint the two primitives share, read off
    /// the outline, and the tangent is the one they share there.
    @Test func primitiveEndpointsMeetAtRegionBoundaries() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let corner = outline.cornerRadius
            let fillet = outline.filletRadius
            let ear = outline.earLength
            let expected: [(point: SIMD2<Double>, tangent: SIMD2<Double>)] = [
                (SIMD2(outline.minX - fillet - ear, outline.top), SIMD2(1, 0)),
                (SIMD2(outline.minX - fillet, outline.top), SIMD2(1, 0)),
                (SIMD2(outline.minX, outline.top - fillet), SIMD2(0, -1)),
                (SIMD2(outline.minX, outline.bottom + corner), SIMD2(0, -1)),
                (SIMD2(outline.minX + corner, outline.bottom), SIMD2(1, 0)),
                (SIMD2(outline.maxX - corner, outline.bottom), SIMD2(1, 0)),
                (SIMD2(outline.maxX, outline.bottom + corner), SIMD2(0, 1)),
                (SIMD2(outline.maxX, outline.top - fillet), SIMD2(0, 1)),
                (SIMD2(outline.maxX + fillet, outline.top), SIMD2(1, 0)),
                (SIMD2(outline.maxX + fillet + ear, outline.top), SIMD2(1, 0)),
            ]
            let joins = Self.joins(of: spine)
            var worstPoint = 0.0
            var worstTangent = 0.0
            for (s, join) in zip(joins, expected) {
                worstPoint = max(worstPoint, Self.norm(spine.point(at: s) - join.point))
                worstTangent = max(worstTangent, Self.norm(spine.frame(at: s).tangent - join.tangent))
            }
            #expect(worstPoint <= 1e-12, "endpoint off by \(worstPoint) pt")
            #expect(worstTangent <= 1e-12, "tangent off by \(worstTangent)")
            #expect(abs(joins[joins.count - 1] - spine.length) <= 1e-12)
        }
    }

    /// The curve is C¹ at every join, and its frame is the curve's own: `dP/ds = T`,
    /// `dT/ds = −κN` and `dN/ds = κT`, with `N = (T.y, −T.x)` and κ equal to `1/ρ`, `−1/ρe`
    /// or 0, primitive by primitive.
    @Test func collarIsC1WithExactCurvature() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let joins = Self.joins(of: spine)
            let corner = outline.cornerRadius
            let fillet = outline.filletRadius

            // Across each join: no gap, and no more turn than the sharper neighbour allows.
            let step = 1e-7
            let sharpest = 1 / Swift.min(corner, fillet)
            var worstGap = 0.0
            var worstTurn = 0.0
            for join in joins.dropFirst().dropLast() {
                let gap = Self.norm(spine.point(at: join + step) - spine.point(at: join - step))
                let turn = Self.norm(spine.frame(at: join + step).tangent - spine.frame(at: join - step).tangent)
                worstGap = max(worstGap, gap - 2 * step)
                worstTurn = max(worstTurn, turn - 2 * step * sharpest)
            }
            #expect(worstGap <= 1e-12, "join gap \(worstGap) pt beyond the arc between samples")
            #expect(worstTurn <= 1e-12, "join turn \(worstTurn) beyond the curvature bound")

            let curvatures = [0, -1 / fillet, 0, 1 / corner, 0, 1 / corner, 0, -1 / fillet, 0]
            var wrongCurvature = 0
            for (index, curvature) in curvatures.enumerated() where joins[index + 1] > joins[index] {
                if spine.frame(at: (joins[index] + joins[index + 1]) / 2).curvature != curvature {
                    wrongCurvature += 1
                }
            }
            #expect(wrongCurvature == 0)

            let h = 1e-4
            var worstVelocity = 0.0
            var worstTurning = 0.0
            var worstNormalTurning = 0.0
            var worstFrame = 0.0
            for k in 0...4000 {
                let s = spine.length * Double(k) / 4000
                guard joins.allSatisfy({ abs($0 - s) > 2 * h }) else { continue }
                let frame = spine.frame(at: s)
                let before = spine.frame(at: s - h)
                let after = spine.frame(at: s + h)
                let velocity = (spine.point(at: s + h) - spine.point(at: s - h)) / (2 * h)
                let turning = (after.tangent - before.tangent) / (2 * h)
                let normalTurning = (after.normal - before.normal) / (2 * h)
                worstVelocity = max(worstVelocity, Self.norm(velocity - frame.tangent))
                worstTurning = max(worstTurning, Self.norm(turning + frame.curvature * frame.normal))
                worstNormalTurning = max(worstNormalTurning, Self.norm(normalTurning - frame.curvature * frame.tangent))
                let rightNormal = SIMD2(frame.tangent.y, -frame.tangent.x)
                worstFrame = max(worstFrame, abs(Self.norm(frame.tangent) - 1) + Self.norm(frame.normal - rightNormal))
            }
            #expect(worstVelocity <= 1e-7, "dP/ds off T by \(worstVelocity)")
            #expect(worstTurning <= 1e-7, "dT/ds off −κN by \(worstTurning)")
            #expect(worstNormalTurning <= 1e-7, "dN/ds off κT by \(worstNormalTurning)")
            #expect(worstFrame <= 1e-14)
        }
    }

    /// Both sides are one geometry: the curve, its frame, its taper and its chart all mirror
    /// across the housing's axis, with the arc length running back from the far end.
    @Test func collarIsSymmetricAboutTheHousingAxis() throws {
        for (index, housing) in Self.everyHousing.enumerated() {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let joins = Self.joins(of: spine)
            var worstPoint = 0.0
            var worstTangent = 0.0
            var worstTaper = 0.0
            var curvatureBreaks = 0
            for k in 0...2000 {
                let s = spine.length * Double(k) / 2000
                let opposite = spine.length - s
                worstPoint = max(
                    worstPoint, Self.norm(spine.point(at: opposite) - Self.mirror(spine.point(at: s), outline)))
                let frame = spine.frame(at: s)
                let mirrored = spine.frame(at: opposite)
                worstTangent = max(
                    worstTangent, Self.norm(mirrored.tangent - SIMD2(frame.tangent.x, -frame.tangent.y)))
                worstTaper = max(worstTaper, abs(spine.taper(at: s) - spine.taper(at: opposite)))
                if joins.allSatisfy({ abs($0 - s) > 1e-9 }), frame.curvature != mirrored.curvature {
                    curvatureBreaks += 1
                }
            }
            #expect(worstPoint <= 1e-12)
            #expect(worstTangent <= 1e-12)
            #expect(worstTaper <= 1e-12)
            #expect(curvatureBreaks == 0)

            let noise = MercuryNoise(seed: 0x4D49_5252_4F52_0000 | UInt64(index))
            let box = Self.canvasBox(outline)
            var worstChart = 0.0
            var nilMismatches = 0
            for counter in UInt64(0)..<4000 {
                let point = Self.draw(noise, counter: counter, in: box)
                switch (spine.chart(at: point), spine.chart(at: Self.mirror(point, outline))) {
                case (nil, nil):
                    continue
                case (let chart?, let image?):
                    worstChart = max(
                        worstChart,
                        abs(chart.arcLength + image.arcLength - spine.length),
                        abs(chart.normalOffset - image.normalOffset),
                        Self.norm(image.normal - SIMD2(-chart.normal.x, chart.normal.y))
                    )
                default:
                    nilMismatches += 1
                }
            }
            #expect(nilMismatches == 0)
            #expect(worstChart <= 1e-12)
        }
    }

    // MARK: - The chart

    /// Every offset the body can draw, `0 < n ≤ 17·T(s)`, charts back to the `(s, n)` it was
    /// laid at: the drawn film has a unique nearest point everywhere, corners and fillets
    /// included.
    @Test func chartRoundTripsEveryOffsetTheBodyCanDraw() {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            var worstArc = 0.0
            var worstOffset = 0.0
            var misses = 0
            for k in 0...4000 {
                let s = spine.length * Double(k) / 4000
                let reach = MercurySpine.maxHalfHeight * spine.taper(at: s)
                let normal = spine.frame(at: s).normal
                for fraction in [1.0 / 64, 0.25, 0.5, 0.75, 1] {
                    let offset = reach * fraction
                    guard let chart = spine.chart(at: spine.point(at: s) + offset * normal) else {
                        misses += 1
                        continue
                    }
                    worstArc = max(worstArc, abs(chart.arcLength - s))
                    worstOffset = max(worstOffset, abs(chart.normalOffset - offset))
                }
            }
            #expect(misses == 0)
            #expect(worstArc <= 1e-9, "arc length round trip off by \(worstArc)")
            #expect(worstOffset <= 1e-9, "normal offset round trip off by \(worstOffset)")
        }
    }

    /// The closed-form chart is the exact nearest point.
    ///
    /// Random points outside the housing and within 20 pt of the curve, against a brute-force
    /// scan of the outline resampled every 0.01 pt. Distances agree to 1e-6 on straight runs,
    /// where the resampling lies on the curve, and to 1e-4 on arcs, where a chord sags under
    /// 3e-6. On arcs, the foot point and arc length agree to 0.02 pt: projected onto a chord, a
    /// point `n` off the arc lands up to `n·spacing/2ρ` from its true foot.
    @Test func chartIsTheBruteForceNearestPoint() throws {
        let corpora = Self.realistic.map { ($0, 10_000) } + Self.clamped.map { ($0, 2_000) }
        for (index, (housing, count)) in corpora.enumerated() {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let oracle = ResampledOutline(outline: outline, spacing: 0.01)
            let noise = MercuryNoise(seed: 0x4E45_4152_4553_5400 | UInt64(index))
            let box = (
                minX: outline.minX - outline.filletRadius - outline.earLength,
                maxX: outline.maxX + outline.filletRadius + outline.earLength,
                minY: outline.bottom - 20,
                maxY: outline.top
            )
            var accepted = 0
            var misses = 0
            var wrongSide = 0
            var worstStraight = 0.0
            var worstCurved = 0.0
            var worstStraightFoot = 0.0
            var worstCurvedFoot = 0.0
            var counter: UInt64 = 0
            while accepted < count, counter < UInt64(4 * count) {
                let point = Self.draw(noise, counter: counter, in: box)
                counter += 1
                guard !Self.isInsideHousing(point, outline) else { continue }
                let nearest = oracle.nearest(to: point)
                guard nearest.distance <= 20 else { continue }
                accepted += 1
                guard let chart = spine.chart(at: point) else {
                    misses += 1
                    continue
                }
                let distanceError = abs(abs(chart.normalOffset) - nearest.distance)
                let foot = point - chart.normalOffset * chart.normal
                let footError = max(Self.norm(foot - nearest.foot), abs(chart.arcLength - nearest.arcLength))
                if nearest.nearArc {
                    worstCurved = max(worstCurved, distanceError)
                    worstCurvedFoot = max(worstCurvedFoot, footError)
                } else {
                    worstStraight = max(worstStraight, distanceError)
                    worstStraightFoot = max(worstStraightFoot, footError)
                }
                if nearest.distance > 1e-3, (chart.normalOffset > 0) != (nearest.side > 0) {
                    wrongSide += 1
                }
            }
            #expect(accepted == count)
            #expect(misses == 0)
            #expect(wrongSide == 0)
            #expect(worstStraight <= 1e-6, "straight-run distance off by \(worstStraight)")
            #expect(worstCurved <= 1e-4, "arc distance off by \(worstCurved)")
            #expect(worstStraightFoot <= 1e-6, "straight-run foot off by \(worstStraightFoot)")
            #expect(worstCurvedFoot <= 2e-2, "arc foot off by \(worstCurvedFoot)")
        }
    }

    /// `∇s = T/(1 + κn)` and `∇n = N`, by central differences of the chart itself. This is
    /// the curvilinear metric the field's normal relies on.
    @Test func chartGradientIsTheCurvilinearMetric() {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let joins = Self.joins(of: spine)
            let h = 1e-5
            var worstMetric = 0.0
            var worstArcGradient = 0.0
            var worstOffsetGradient = 0.0
            var misses = 0
            for k in 0..<400 {
                let s = spine.length * (Double(k) + 0.5) / 400
                guard joins.allSatisfy({ abs($0 - s) > 0.05 }) else { continue }
                let frame = spine.frame(at: s)
                for offset in [0.5, 1.5, 3.0] {
                    let point = spine.point(at: s) + offset * frame.normal
                    guard let chart = spine.chart(at: point),
                        let east = spine.chart(at: point + SIMD2(h, 0)),
                        let west = spine.chart(at: point - SIMD2(h, 0)),
                        let north = spine.chart(at: point + SIMD2(0, h)),
                        let south = spine.chart(at: point - SIMD2(0, h))
                    else {
                        misses += 1
                        continue
                    }
                    worstMetric = max(worstMetric, abs(chart.metric - (1 + frame.curvature * offset)))
                    let arcGradient =
                        SIMD2(east.arcLength - west.arcLength, north.arcLength - south.arcLength) / (2 * h)
                    let offsetGradient =
                        SIMD2(east.normalOffset - west.normalOffset, north.normalOffset - south.normalOffset) / (2 * h)
                    worstArcGradient = max(worstArcGradient, Self.norm(arcGradient - chart.tangent / chart.metric))
                    worstOffsetGradient = max(worstOffsetGradient, Self.norm(offsetGradient - chart.normal))
                }
            }
            #expect(misses == 0)
            #expect(worstMetric <= 1e-12, "metric off 1 + κn by \(worstMetric)")
            #expect(worstArcGradient <= 1e-6, "∇s off T/metric by \(worstArcGradient)")
            #expect(worstOffsetGradient <= 1e-6, "∇n off N by \(worstOffsetGradient)")
        }
    }

    /// Nil is exactly the rounded housing, extended up into the bezel, plus everything above
    /// the screen's top edge. Every other point below the top edge has a chart.
    @Test func chartIsNilExactlyInsideTheHousingAndAboveTheScreen() throws {
        for (index, housing) in Self.everyHousing.enumerated() {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let noise = MercuryNoise(seed: 0x484F_5553_494E_4700 | UInt64(index))
            var box = Self.canvasBox(outline)
            box.maxY += 10
            var excluded = 0
            var charted = 0
            var wrong = 0
            for counter in UInt64(0)..<20_000 {
                let point = Self.draw(noise, counter: counter, in: box)
                let isExcluded = point.y > outline.top || Self.isInsideHousing(point, outline)
                if isExcluded { excluded += 1 } else { charted += 1 }
                if (spine.chart(at: point) == nil) != isExcluded { wrong += 1 }
            }
            #expect(wrong == 0)
            #expect(excluded > 1000 && charted > 1000)
        }
    }

    /// The inner half of the ribbon falls under the black housing, or above the screen along
    /// the ears. Nothing there is drawn or hit, so the hardware's edge is the visible contact
    /// line. Only the fillets' inner side lies outside the housing, in the crescent against
    /// the hardware's own concave corner.
    @Test func innerHalfLiesUnderTheHousing() {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let joins = Self.joins(of: spine)
            var sampled = 0
            var drawn = 0
            for k in 0...2000 {
                let s = spine.length * Double(k) / 2000
                let onFillet = (joins[1] < s && s < joins[2]) || (joins[7] < s && s < joins[8])
                guard !onFillet else { continue }
                let normal = spine.frame(at: s).normal
                for depth in [0.25, 2, 8] {
                    sampled += 1
                    if spine.chart(at: spine.point(at: s) - depth * normal) != nil { drawn += 1 }
                }
            }
            #expect(sampled > 3000)
            #expect(drawn == 0)
        }
    }

    /// A fillet's offsets toward its centre are unique for every `n < ρe`, where the metric
    /// `1 − n/ρe` is still positive. The centre itself is equidistant from the whole arc and
    /// charts onto one end of it. The band film keeps the drawn body far short of the centre.
    @Test func filletOffsetsAreUniqueInsideTheFilletRadius() throws {
        for housing in Self.realistic {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let regions = spine.regions
            let fillet = outline.filletRadius
            var worstArc = 0.0
            var worstOffset = 0.0
            var worstMetric = 0.0
            var misses = 0
            for k in 1..<64 {
                let along = regions.ear + regions.fillet * Double(k) / 64
                for s in [along, spine.length - along] {
                    let normal = spine.frame(at: s).normal
                    for step in 0..<64 {
                        let offset = fillet * Double(step) / 64
                        guard let chart = spine.chart(at: spine.point(at: s) + offset * normal) else {
                            misses += 1
                            continue
                        }
                        worstArc = max(worstArc, abs(chart.arcLength - s))
                        worstOffset = max(worstOffset, abs(chart.normalOffset - offset))
                        worstMetric = max(worstMetric, abs(chart.metric - (1 - offset / fillet)))
                    }
                }
            }
            #expect(misses == 0)
            #expect(worstArc <= 1e-9, "fillet arc length off by \(worstArc)")
            #expect(worstOffset <= 1e-9)
            #expect(worstMetric <= 1e-12)

            let ends = [
                regions.ear, regions.ear + regions.fillet,
                spine.length - regions.ear - regions.fillet, spine.length - regions.ear,
            ]
            let centres = [
                SIMD2(outline.minX - fillet, outline.top - fillet),
                SIMD2(outline.maxX + fillet, outline.top - fillet),
            ]
            for centre in centres {
                let chart = try #require(spine.chart(at: centre))
                #expect(abs(chart.normalOffset - fillet) <= 1e-12)
                #expect(chart.metric == 1)
                let landsOnAnEnd = ends.contains { abs($0 - chart.arcLength) <= 1e-12 }
                #expect(landsOnAnEnd)
            }

            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            var thickOnFillet = 0
            for k in 0...64 {
                let along = regions.ear + regions.fillet * Double(k) / 64
                if spine.taper(at: along) != film || spine.taper(at: spine.length - along) != film {
                    thickOnFillet += 1
                }
            }
            #expect(thickOnFillet == 0)
            #expect(outline.bandFilm < fillet)
        }
    }

    /// Past either end, the chart continues along the ear line, so `s` runs below 0 and past
    /// `S` and a cap can still be found there.
    @Test func pointsPastTheEarsChartAlongTheEarLine() throws {
        for housing in Self.realistic {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            let start = outline.minX - outline.filletRadius - outline.earLength
            let end = outline.maxX + outline.filletRadius + outline.earLength
            var worst = 0.0
            var wrong = 0
            for beyond in [0.5, 4.0, 12.0] {
                worst = max(worst, Self.norm(spine.point(at: -beyond) - SIMD2(start - beyond, outline.top)))
                worst = max(
                    worst, Self.norm(spine.point(at: spine.length + beyond) - SIMD2(end + beyond, outline.top)))
                if spine.taper(at: -beyond) != film || spine.taper(at: spine.length + beyond) != film {
                    wrong += 1
                }
                for depth in [0.0, 1.5, 9.0] {
                    for (x, s) in [(start - beyond, -beyond), (end + beyond, spine.length + beyond)] {
                        guard let chart = spine.chart(at: SIMD2(x, outline.top - depth)) else {
                            wrong += 1
                            continue
                        }
                        worst = max(worst, abs(chart.arcLength - s), abs(chart.normalOffset - depth))
                        if chart.tangent != SIMD2(1, 0) || chart.normal != SIMD2(0, -1) || chart.metric != 1
                            || !chart.isHorizontal
                        {
                            wrong += 1
                        }
                    }
                }
            }
            #expect(wrong == 0)
            #expect(worst <= 1e-12)
        }
    }

    /// Along the bottom run and the ears, `s` depends on `x` alone, so the rasterizer may share
    /// one station sample per pixel column there. The walls, fillets and corners are not
    /// horizontal.
    @Test func horizontalRunsShareOneStationPerColumn() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let corner = outline.cornerRadius
            let fillet = outline.filletRadius

            func sharesOneStation(_ points: [SIMD2<Double>]) -> Bool {
                let charts = points.compactMap { spine.chart(at: $0) }
                return charts.count == points.count
                    && charts.allSatisfy { $0.isHorizontal && $0.arcLength == charts[0].arcLength }
            }

            var wrong = 0
            // The slab's edge columns lie on the corner's boundary, where both primitives name the
            // same foot; stay a little inside it, and always include the axis.
            let middle = (outline.minX + outline.maxX) / 2
            let inside = stride(from: outline.minX + corner + 0.05, through: outline.maxX - corner - 0.05, by: 0.37)
            for x in [middle] + inside {
                let column = [0.0, 5, 17].map { SIMD2(x, outline.bottom - $0) }
                if !sharesOneStation(column) { wrong += 1 }
            }
            for x in stride(from: outline.minX - fillet - outline.earLength, through: outline.minX - fillet, by: 0.37) {
                for mirrored in [x, outline.minX + outline.maxX - x] {
                    let column = [0.0, 1, outline.bandFilm].map { SIMD2(mirrored, outline.top - $0) }
                    if !sharesOneStation(column) { wrong += 1 }
                }
            }
            #expect(wrong == 0)

            let joins = Self.joins(of: spine)
            var horizontal = 0
            for k in 1..<400 {
                let along = joins[1] + (joins[4] - joins[1]) * Double(k) / 400
                for s in [along, spine.length - along] {
                    let point = spine.point(at: s) + spine.frame(at: s).normal
                    if spine.chart(at: point)?.isHorizontal != false { horizontal += 1 }
                }
            }
            #expect(horizontal == 0)
        }
    }

    /// Only the housing's own edge borders it: the walls, the convex corners and the bottom
    /// run, whose inner side is the hardware. The ears, the fillets and the ear lines past both
    /// ends meet the screen's top edge instead.
    @Test func onlyTheWallsCornersAndBottomBorderTheHousing() {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let joins = Self.joins(of: spine)
            var sampled = 0
            var wrong = 0
            for k in 0...4000 {
                let s = -8 + (spine.length + 16) * Double(k) / 4000
                // At a join two primitives share the foot; stay clear of it.
                guard joins.allSatisfy({ abs($0 - s) > 1e-6 }) else { continue }
                let bordersHousing = min(s, spine.length - s) > joins[2]
                let normal = spine.frame(at: s).normal
                // Offsets within the band film, which every primitive charts back onto itself.
                for offset in [0.25, 1.5, 3] {
                    guard let chart = spine.chart(at: spine.point(at: s) + offset * normal) else {
                        wrong += 1
                        continue
                    }
                    sampled += 1
                    if chart.bordersHousing != bordersHousing { wrong += 1 }
                }
            }
            #expect(wrong == 0)
            #expect(sampled > 10_000)
        }
    }

    // MARK: - The taper

    /// The taper is full along the bottom run, and is the band film on the walls, fillets and
    /// ears. Across each corner it is full through 30° above the bottom, half-way at 50°, and
    /// film from 70°.
    @Test func taperIsFullUnderTheNotchAndAFilmInTheBand() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let joins = Self.joins(of: spine)
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            #expect(spine.taper(at: spine.restCenter) == 1)

            var wrong = 0
            for k in 0...200 {
                let fraction = Double(k) / 200
                if spine.taper(at: joins[4] + (joins[5] - joins[4]) * fraction) != 1 { wrong += 1 }
                let thin = joins[0] + (joins[3] - joins[0]) * fraction
                if spine.taper(at: thin) != film || spine.taper(at: spine.length - thin) != film { wrong += 1 }
            }
            #expect(wrong == 0)

            let blends: [(degrees: Double, taper: Double)] = [
                (0, 1), (15, 1), (30, 1), (50, (1 + film) / 2), (70, film), (85, film), (90, film),
            ]
            for blend in blends {
                let s = joins[3] + outline.cornerRadius * (Double.pi / 2 - blend.degrees * Double.pi / 180)
                #expect(abs(spine.taper(at: s) - blend.taper) <= 1e-12, "left corner at \(blend.degrees)°")
                #expect(
                    abs(spine.taper(at: spine.length - s) - blend.taper) <= 1e-12, "right corner at \(blend.degrees)°")
            }
        }
    }

    /// The taper stays in `[bandFilm/17, 1] ⊂ (0, 1]`. Its first and second differences never
    /// exceed the smoothstep's own slope and bend, so it is C¹ with no kink at any join.
    @Test func taperIsBoundedAndContinuouslyDifferentiable() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            // The 30°…70° blend's arc length, and the smoothstep's largest slope and bend over it.
            let span = 40 * Double.pi / 180 * outline.cornerRadius
            let slope = 1.5 * (1 - film) / span
            let bend = 6 * (1 - film) / (span * span)
            let step = 5e-3
            var outOfBounds = 0
            var worstSlope = 0.0
            var worstBend = 0.0
            for k in 0...Int((spine.length + 10) / step) {
                let s = -5 + Double(k) * step
                let previous = spine.taper(at: s - step)
                let current = spine.taper(at: s)
                let next = spine.taper(at: s + step)
                if !(current > 0 && current >= film - 1e-15 && current <= 1) { outOfBounds += 1 }
                worstSlope = max(worstSlope, abs(next - current) / step)
                worstBend = max(worstBend, abs(next - 2 * current + previous) / (step * step))
            }
            #expect(outOfBounds == 0)
            #expect(worstSlope <= slope * (1 + 1e-6), "taper slope \(worstSlope) beyond \(slope)")
            #expect(worstBend <= bend * (1 + 1e-6) + 1e-6, "taper bend \(worstBend) beyond \(bend)")
        }
    }

    /// `taperSlope` is the taper's own derivative. Central differences of `taper(at:)` agree
    /// with it to their own truncation error everywhere, past both ends included. It is
    /// exactly zero off the two blends, steepest where they are half done, at
    /// `3/2 · (1 − film)` per 40° of corner, and odd about the housing's axis.
    @Test func taperSlopeIsTheTapersDerivative() throws {
        for housing in Self.everyHousing {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let joins = Self.joins(of: spine)
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            // The left blend runs from 70° up the corner, 20° of turn past its wall end, down to 30°.
            let blendStart = joins[3] + outline.cornerRadius * 20 * Double.pi / 180
            let blendEnd = joins[3] + outline.cornerRadius * 60 * Double.pi / 180
            let step = 1e-6
            var worst = 0.0
            var worstMirror = 0.0
            var strayOffTheBlends = 0
            for k in 0...Int((spine.length + 10) / 0.01) {
                let s = -5 + Double(k) * 0.01
                let slope = spine.taperSlope(at: s)
                let numeric = (spine.taper(at: s + step) - spine.taper(at: s - step)) / (2 * step)
                worst = max(worst, abs(slope - numeric))
                worstMirror = max(worstMirror, abs(spine.taperSlope(at: spine.length - s) + slope))
                let local = min(s, spine.length - s)
                if local < blendStart - 1e-9 || local > blendEnd + 1e-9, slope != 0 { strayOffTheBlends += 1 }
            }
            #expect(worst <= 1e-7, "taperSlope off the central difference by \(worst)")
            #expect(worstMirror <= 1e-12, "taperSlope not odd about the axis by \(worstMirror)")
            #expect(strayOffTheBlends == 0)

            let peak = (blendStart + blendEnd) / 2
            let steepest = 1.5 * (1 - film) / (40 * Double.pi / 180 * outline.cornerRadius)
            #expect(abs(spine.taperSlope(at: peak) - steepest) <= 1e-12 * steepest)
            #expect(abs(spine.taperSlope(at: spine.length - peak) + steepest) <= 1e-12 * steepest)
        }
    }

    /// Over any range, `taperBounds` gives the taper's least and greatest values and its
    /// steepest slope there. A dense scan of the range never passes them, and finds each one
    /// to within a step's worth of the taper's slope or bend.
    @Test func taperBoundsAreTheTapersExtremesOverAnyRange() throws {
        for (index, housing) in Self.everyHousing.enumerated() {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            let span = 40 * Double.pi / 180 * outline.cornerRadius
            let steepestSlope = 1.5 * (1 - film) / span
            let sharpestBend = 6 * (1 - film) / (span * span)
            let noise = MercuryNoise(seed: 0x5441_5045_5200_0000 | UInt64(index))
            var passed = 0
            var unreached = 0
            for counter in UInt64(0)..<2_000 {
                let start = -5 + (spine.length + 10) * noise.uniform(stream: 0, counter: counter)
                let reach = 30 * noise.uniform(stream: 1, counter: counter) * noise.uniform(stream: 2, counter: counter)
                let end = start + reach
                let bounds = spine.taperBounds(from: start, to: end)
                var least = Double.infinity
                var greatest = -Double.infinity
                var steepest = 0.0
                for k in 0...400 {
                    let s = k == 400 ? end : start + reach * Double(k) / 400
                    least = min(least, spine.taper(at: s))
                    greatest = max(greatest, spine.taper(at: s))
                    steepest = max(steepest, abs(spine.taperSlope(at: s)))
                }
                if least < bounds.least || greatest > bounds.greatest || steepest > bounds.steepest {
                    passed += 1
                }
                let scanStep = reach / 400
                if greatest < bounds.greatest - scanStep * steepestSlope || least != bounds.least
                    || steepest < bounds.steepest - scanStep * sharpestBend
                {
                    unreached += 1
                }
            }
            #expect(passed == 0, "a scan passed the bounds over \(passed) ranges")
            #expect(unreached == 0, "the bounds were out of reach over \(unreached) ranges")
        }
    }

    /// Beside the notch, the upper half of the menu-bar band, where menu titles and status
    /// items sit, is only ever covered by the band film. Full thickness lives below the corner
    /// centres, which sit below the band's middle on both fixture housings.
    @Test func upperHalfOfTheBandBesideTheNotchOnlyEverHoldsTheFilm() throws {
        for housing in Self.realistic {
            let spine = MercurySpine(collar: housing.outline)
            let outline = try #require(Self.laidOutline(of: spine))
            let film = outline.bandFilm / MercurySpine.maxHalfHeight
            let bandMiddle = outline.top - housing.band / 2
            #expect(outline.bottom + outline.cornerRadius < bandMiddle)

            var sampled = 0
            var thick = 0
            let reach = outline.filletRadius + outline.earLength
            for beside in stride(from: 0.125, through: reach, by: 0.25) {
                for x in [outline.minX - beside, outline.maxX + beside] {
                    for y in stride(from: bandMiddle, through: outline.top, by: 0.25) {
                        sampled += 1
                        if let chart = spine.chart(at: SIMD2(x, y)), spine.taper(at: chart.arcLength) == film {
                            continue
                        }
                        thick += 1
                    }
                }
            }
            #expect(sampled > 10_000)
            #expect(thick == 0)
        }
    }

    // MARK: - Helpers

    private static func laidOutline(of spine: MercurySpine) -> MercurySpine.Outline? {
        guard case .collar(let outline) = spine.kind else { return nil }
        return outline
    }

    /// The ten arc lengths at which one primitive hands over to the next, from the start of
    /// the left ear to the end of the right one.
    private static func joins(of spine: MercurySpine) -> [Double] {
        let regions = spine.regions
        let pieces = [
            regions.ear, regions.fillet, regions.wall, regions.corner, regions.bottom,
            regions.corner, regions.wall, regions.fillet, regions.ear,
        ]
        var joins = [0.0]
        for piece in pieces {
            joins.append(joins[joins.count - 1] + piece)
        }
        return joins
    }

    /// Strictly inside the rounded housing, extended up into the bezel, from the outline alone.
    private static func isInsideHousing(_ point: SIMD2<Double>, _ outline: MercurySpine.Outline) -> Bool {
        guard point.x > outline.minX, point.x < outline.maxX, point.y > outline.bottom else { return false }
        let corner = outline.cornerRadius
        let centreX = Swift.min(Swift.max(point.x, outline.minX + corner), outline.maxX - corner)
        let centreY = Swift.max(point.y, outline.bottom + corner)
        return hypot(point.x - centreX, point.y - centreY) < corner
    }

    private static func mirror(_ point: SIMD2<Double>, _ outline: MercurySpine.Outline) -> SIMD2<Double> {
        SIMD2(outline.minX + outline.maxX - point.x, point.y)
    }

    private static func norm(_ vector: SIMD2<Double>) -> Double {
        hypot(vector.x, vector.y)
    }

    private typealias Box = (minX: Double, maxX: Double, minY: Double, maxY: Double)

    /// The collar's canvas: the ears plus four points each side, and the 17 pt chin plus three.
    private static func canvasBox(_ outline: MercurySpine.Outline) -> Box {
        let reach = outline.filletRadius + outline.earLength + 4
        return (outline.minX - reach, outline.maxX + reach, outline.bottom - 20, outline.top)
    }

    private static func draw(_ noise: MercuryNoise, counter: UInt64, in box: Box) -> SIMD2<Double> {
        SIMD2(
            box.minX + (box.maxX - box.minX) * noise.uniform(stream: 0, counter: counter),
            box.minY + (box.maxY - box.minY) * noise.uniform(stream: 1, counter: counter)
        )
    }
}

/// The housing outline rebuilt from its own rect and resampled every `spacing` of arc, with a
/// brute-force nearest point over every segment.
///
/// Nothing here reads the spine's evaluators. Arcs come from their centres and angles, and arc
/// length comes from each primitive's own length. Segments of a straight run lie on it, so
/// distances there are exact, while a chord sags at most `spacing²/8ρ` off its arc.
///
/// The scan prunes by bounding boxes, groups of blocks first and then blocks of segments, and
/// skips one only when its box is already farther away than some point of the curve. So it
/// returns exactly what an exhaustive scan would.
private struct ResampledOutline {
    struct Nearest {
        var distance: Double
        var foot: SIMD2<Double>
        var arcLength: Double
        /// The nearest segment, or one beside it, lies on an arc. The oracle is then only as
        /// good as the chord's sag.
        var nearArc: Bool
        /// Positive on the right of the traversal, the side the spine's normal points to.
        var side: Double
    }

    private enum Piece {
        case line(SIMD2<Double>, SIMD2<Double>)
        case arc(center: SIMD2<Double>, radius: Double, from: Double, to: Double)
    }

    private typealias Box = (minX: Double, maxX: Double, minY: Double, maxY: Double)

    /// Segments per block, and blocks per group.
    private static let blockSize = 64
    private static let groupSize = 8

    private var xs: [Double] = []
    private var ys: [Double] = []
    private var arcLengths: [Double] = []
    /// One entry per segment.
    private var onArc: [Bool] = []
    private var blocks: [Box] = []
    private var groups: [Box] = []

    init(outline: MercurySpine.Outline, spacing: Double) {
        let corner = outline.cornerRadius
        let fillet = outline.filletRadius
        let (left, right, top, bottom) = (outline.minX, outline.maxX, outline.top, outline.bottom)
        let pieces: [Piece] = [
            .line(SIMD2(left - fillet - outline.earLength, top), SIMD2(left - fillet, top)),
            .arc(center: SIMD2(left - fillet, top - fillet), radius: fillet, from: .pi / 2, to: 0),
            .line(SIMD2(left, top - fillet), SIMD2(left, bottom + corner)),
            .arc(center: SIMD2(left + corner, bottom + corner), radius: corner, from: .pi, to: 1.5 * .pi),
            .line(SIMD2(left + corner, bottom), SIMD2(right - corner, bottom)),
            .arc(center: SIMD2(right - corner, bottom + corner), radius: corner, from: 1.5 * .pi, to: 2 * .pi),
            .line(SIMD2(right, bottom + corner), SIMD2(right, top - fillet)),
            .arc(center: SIMD2(right + fillet, top - fillet), radius: fillet, from: .pi, to: .pi / 2),
            .line(SIMD2(right + fillet, top), SIMD2(right + fillet + outline.earLength, top)),
        ]
        var start = 0.0
        for piece in pieces {
            let pieceLength: Double
            let isArc: Bool
            switch piece {
            case .line(let from, let to):
                pieceLength = hypot(to.x - from.x, to.y - from.y)
                isArc = false
            case .arc(_, let radius, let from, let to):
                pieceLength = radius * abs(to - from)
                isArc = true
            }
            guard pieceLength > 0 else { continue }
            let count = Int((pieceLength / spacing).rounded(.up))
            for index in (xs.isEmpty ? 0 : 1)...count {
                let fraction = Double(index) / Double(count)
                let point: SIMD2<Double>
                switch piece {
                case .line(let from, let to):
                    point = from + fraction * (to - from)
                case .arc(let center, let radius, let from, let to):
                    let angle = from + fraction * (to - from)
                    point = center + radius * SIMD2(cos(angle), sin(angle))
                }
                xs.append(point.x)
                ys.append(point.y)
                arcLengths.append(start + fraction * pieceLength)
                if index > 0 { onArc.append(isArc) }
            }
            start += pieceLength
        }
        blocks = boxes(spanning: Self.blockSize)
        groups = boxes(spanning: Self.blockSize * Self.groupSize)
    }

    func nearest(to point: SIMD2<Double>) -> Nearest {
        let groupSpan = Self.blockSize * Self.groupSize
        // Every group's and block's first vertex lies on the curve, so each one bounds the answer.
        var bound = Double.infinity
        for group in groups.indices {
            bound = Swift.min(bound, squaredDistance(from: point, toVertex: group * groupSpan))
        }
        let reachable = groups.indices.filter { squaredDistance(from: point, to: groups[$0]) <= bound }
        for group in reachable {
            for block in blockIndices(of: group) {
                bound = Swift.min(bound, squaredDistance(from: point, toVertex: block * Self.blockSize))
            }
        }
        var closest = (squared: Double.infinity, segment: 0, fraction: 0.0)
        for group in reachable where squaredDistance(from: point, to: groups[group]) <= bound {
            for block in blockIndices(of: group) where squaredDistance(from: point, to: blocks[block]) <= bound {
                let first = block * Self.blockSize
                for index in first..<Swift.min(first + Self.blockSize, onArc.count) {
                    let ax = xs[index]
                    let ay = ys[index]
                    let ex = xs[index + 1] - ax
                    let ey = ys[index + 1] - ay
                    let along = ((point.x - ax) * ex + (point.y - ay) * ey) / (ex * ex + ey * ey)
                    let clamped = Swift.min(Swift.max(along, 0), 1)
                    let fx = ax + clamped * ex - point.x
                    let fy = ay + clamped * ey - point.y
                    let squared = fx * fx + fy * fy
                    if squared < closest.squared {
                        closest = (squared, index, clamped)
                        bound = Swift.min(bound, squared)
                    }
                }
            }
        }
        let segment = closest.segment
        let start = SIMD2(xs[segment], ys[segment])
        let edge = SIMD2(xs[segment + 1], ys[segment + 1]) - start
        let foot = start + closest.fraction * edge
        let neighbours = Swift.max(segment - 1, 0)...Swift.min(segment + 1, onArc.count - 1)
        return Nearest(
            distance: closest.squared.squareRoot(),
            foot: foot,
            arcLength: arcLengths[segment] + closest.fraction * (arcLengths[segment + 1] - arcLengths[segment]),
            nearArc: onArc[neighbours].contains(true),
            side: (point.x - foot.x) * edge.y - (point.y - foot.y) * edge.x
        )
    }

    /// Bounding boxes of consecutive runs of `span` segments, each including its closing vertex.
    private func boxes(spanning span: Int) -> [Box] {
        stride(from: 0, to: onArc.count, by: span).map { first in
            var box = (minX: xs[first], maxX: xs[first], minY: ys[first], maxY: ys[first])
            for vertex in first...Swift.min(first + span, onArc.count) {
                box.minX = Swift.min(box.minX, xs[vertex])
                box.maxX = Swift.max(box.maxX, xs[vertex])
                box.minY = Swift.min(box.minY, ys[vertex])
                box.maxY = Swift.max(box.maxY, ys[vertex])
            }
            return box
        }
    }

    private func blockIndices(of group: Int) -> Range<Int> {
        group * Self.groupSize..<Swift.min((group + 1) * Self.groupSize, blocks.count)
    }

    private func squaredDistance(from point: SIMD2<Double>, toVertex vertex: Int) -> Double {
        let dx = xs[vertex] - point.x
        let dy = ys[vertex] - point.y
        return dx * dx + dy * dy
    }

    /// Zero inside the box, and a lower bound for every segment the box holds.
    private func squaredDistance(from point: SIMD2<Double>, to box: Box) -> Double {
        let dx = Swift.max(Swift.max(box.minX - point.x, point.x - box.maxX), 0)
        let dy = Swift.max(Swift.max(box.minY - point.y, point.y - box.maxY), 0)
        return dx * dx + dy * dy
    }
}
