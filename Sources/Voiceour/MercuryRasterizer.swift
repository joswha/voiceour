import CoreGraphics
import Foundation

/// Accessibility state the opaque body renders against.
struct MercuryAppearance: Equatable {
    var increasedContrast: Bool

    static let standard = MercuryAppearance(increasedContrast: false)
}

/// CPU rasterizer for the one procedural mercury body.
///
/// The scalar field remains the sole coverage and hit-test oracle. Its sampled radius
/// also lifts a half-elliptic crown, at the field's own aspect, whose exact total gradient
/// supplies the surface normal. A static generated RGB room, the look's paint table and a
/// bounded two-anchor response complete the material; no highlight, rim or gradient is
/// authored.
///
/// Every pixel is charted onto the spine. Pixels with no chart, under the camera housing or
/// above the screen's top edge, stay clear. On a horizontal straight run, which is the whole
/// island and the collar's bottom and ears, the arc length depends on `x` alone, so each pixel
/// column interpolates its station once and the rest of the column reuses it.
///
/// **Only pixels the body can reach are visited.** A collar's canvas is mostly housing, menu
/// bar and empty band, and a full-length body still covers only a fifth of it. Each frame
/// marks, row by row, the blocks of columns that some ``MercuryField/Extent`` reaches, grown by
/// its coverage ramp and one more pixel, and visits only those, in the same row-major order a
/// scan of every pixel takes. The extents hold every pixel the field can cover, so the image,
/// and the order calibration collects its samples in, are exactly what that scan produces.
///
/// **A bend's pixels are charted once.** A chart depends on the spine and the pixel alone,
/// never on the body, so it holds for as long as the spine, the canvas and its scale do. Only
/// the bends' charts are dear: a convex corner's plateau takes an arctangent, and a ramp's foot
/// a few Newton steps. So every pixel around the collar's four bends keeps the chart the first
/// frame to visit it computed, and every other pixel, a few multiplies, is charted afresh.
///
/// **A row is shaded in stages.** A pixel's shading is one chain of dependent square roots,
/// divides and table reads, and the processor overlaps successive pixels' chains only as far
/// as its instruction window reaches, which across one long loop body is barely past the next
/// pixel. So each row takes four short passes instead: cover charts, samples and covers each
/// marked pixel and queues those the body covers; reflect finds where each queued pixel's
/// reflection leaves the crown; light reads the room there through the paint's reflectance;
/// and write takes each through the display response into the bitmap, or hands it to
/// calibration. Within a pass the pixels are independent, so their chains overlap. Every
/// pixel takes exactly the steps of
/// ``sceneRadiance(of:at:epsilon:crownAspect:environment:paint:)``, in the same order, and
/// calibration's samples arrive in the same order.
///
/// **A look adds no per-pixel work.** It reaches a frame as two values taken once per
/// render: the field's crown aspect, a scalar in place of a constant, and the paint's table,
/// whose one lerp per pixel is the reflectance lookup liquid mercury takes too.
@MainActor
final class MercuryRasterizer {
    private var context: CGContext?
    /// Per pixel column, the bit pattern of the last horizontal chart's arc length and the
    /// station sample at it. A cache of ``MercuryField/stationSample(at:)``, never a second
    /// evaluator: a key that does not match is simply recomputed.
    private var stationKeys: UnsafeMutablePointer<UInt64>?
    private var stationSamples: UnsafeMutablePointer<MercuryField.StationSample>?
    /// One row's covered pixels, then their reflections and their scene radiance, as each
    /// stage hands them to the next. A row never queues more pixels than the canvas is wide.
    private var queue: UnsafeMutablePointer<QueuedPixel>?
    private var reflections: UnsafeMutablePointer<Reflection>?
    private var radiances: UnsafeMutablePointer<SIMD3<Double>>?
    /// The canvas width the per-column and per-row storage above holds.
    private var columnCapacity = 0
    /// The sparse mask: per pixel row, one bit per block of ``blockWidth`` columns that an
    /// extent reaches, in `wordsPerRow` words. Rebuilt every frame.
    private var mask: UnsafeMutablePointer<UInt64>?
    private var maskCapacity = 0
    private var responseKey: MercuryDisplayResponse?
    private var responseLookup: MercuryDisplayLookup?
    /// The charts kept for the pixels around a collar's bends, and per pixel whether it is
    /// charted yet: 0 not yet, 1 charted, 2 no chart. Laid out box by box, see ``BendBox``.
    private var bendCharts: UnsafeMutablePointer<MercurySpine.Chart>?
    private var bendChartStates: UnsafeMutablePointer<UInt8>?
    private var bendChartCapacity = 0
    /// What the kept charts were charted on. Any change forgets them all.
    private var bendChartKey: BendChartKey?
    private var bendBoxes: [BendBox] = []

    private struct BendChartKey: Equatable {
        var spine: MercurySpine
        var canvas: CGRect
        var pixelSize: Double
    }

    /// The pixel rows and columns around one bend, and where its kept charts start.
    private struct BendBox {
        var rows: ClosedRange<Int>
        var columns: ClosedRange<Int>
        var base: Int
    }

    /// A pixel the body covers, as the cover stage leaves it for the stages that shade it.
    private struct QueuedPixel {
        var column: Int
        var point: SIMD2<Double>
        var sample: MercuryField.Sample
        var coverage: Double
    }

    /// Where a covered point's reflection leaves the crown: what the reflect stage hands the
    /// light stage.
    private struct Reflection {
        /// The reflected ray, as the room reads it.
        var direction: SIMD3<Float>
        /// `max(N·V, 1e-4)`, the cosine the paint's reflectance reads.
        var incidence: Double
    }

    /// No chart's arc length has this bit pattern: it is finite for every finite pixel.
    private static let unsetStationKey = Double.nan.bitPattern
    /// Columns per mask bit. A block's spare columns cost a few rejected pixels at each end of
    /// a row's run, against one bit per pixel to clear and scan.
    private static let blockWidth = 8

    isolated deinit {
        stationKeys?.deallocate()
        stationSamples?.deallocate()
        queue?.deallocate()
        reflections?.deallocate()
        radiances?.deallocate()
        mask?.deallocate()
        bendCharts?.deallocate()
        bendChartStates?.deallocate()
    }

    /// `paint` defaults to the shipped liquid mercury, which every stock caller draws.
    func image(
        field: MercuryField,
        environment: MercuryEnvironment,
        response: MercuryDisplayResponse,
        appearance: MercuryAppearance,
        paint: MercuryPaintLookup = .stock,
        scale: CGFloat
    ) -> CGImage? {
        guard let context = context(for: field.canvasBounds, scale: scale) else { return nil }
        var samples: [SIMD3<Float>]?
        render(
            field: field,
            environment: environment,
            response: response,
            appearance: appearance,
            paint: paint,
            context: context,
            scale: scale,
            samples: &samples
        )
        return context.makeImage()
    }

    /// Linear `environment × paint reflectance` samples before the display response.
    /// Calibration pools these over listening and speaking, then solves two anchors once.
    func sampleSceneRadiance(
        field: MercuryField,
        environment: MercuryEnvironment,
        paint: MercuryPaintLookup = .stock,
        scale: CGFloat
    ) -> [SIMD3<Float>] {
        guard let context = context(for: field.canvasBounds, scale: scale) else { return [] }
        var samples: [SIMD3<Float>]? = []
        render(
            field: field,
            environment: environment,
            response: nil,
            appearance: .standard,
            paint: paint,
            context: context,
            scale: scale,
            samples: &samples
        )
        return samples ?? []
    }

    // MARK: - One pixel

    /// The share of a pixel of size `pixelSize`, centred on a charted point, that the body
    /// covers.
    ///
    /// The field's own ramp is `½ + φ/(|∇φ|·h)`, clamped. On the housing's own edge the
    /// hardware takes its share too. The chart ends at the rim, so a pixel whose centre lies
    /// `d` outside it keeps only the `½ + d/h` of itself that lies outside, and the rim is
    /// antialiased rather than drawn by centre. That `d` is the chart's
    /// ``MercurySpine/Chart/rimDistance``, the housing's own distance: on a convex corner the
    /// eased spine stands up to ``MercurySpine/rimGap`` outside the circular rim, so its
    /// offset is not. The ears and fillets meet the screen's top edge, which is the canvas
    /// edge, and the island meets nothing.
    @inline(__always)
    static func coverage(of sample: MercuryField.Sample, chart: MercurySpine.Chart, pixelSize: Double) -> Double {
        let fieldGradient = sample.gradient
        let gradientLength = (fieldGradient * fieldGradient).sum().squareRoot()
        guard gradientLength > 1e-9 else { return 0 }
        let body = ramp(sample.value, width: gradientLength * pixelSize)
        guard chart.bordersHousing else { return body }
        return body * ramp(chart.rimDistance, width: pixelSize)
    }

    /// `min(max(½ + d/w, 0), 1)`, the share of a pixel whose centre lies `d` inside an edge
    /// whose ramp is `w` wide.
    ///
    /// From `d = ½w` on it is exactly 1: the quotient rounds to at least ½, and the sum to at
    /// least 1. Most covered pixels lie that deep, so they skip the divide. That holds for any
    /// positive `w` whose half is exact, as every width here is. A `d` that is not a number
    /// fails the test and divides.
    @inline(__always)
    private static func ramp(_ distance: Double, width: Double) -> Double {
        if distance >= 0.5 * width { return 1 }
        return Swift.min(Swift.max(0.5 + distance / width, 0), 1)
    }

    /// The linear scene radiance a covered point reflects: the room, seen off the crown the
    /// sample lifts at `crownAspect` from the finite eye, times the paint's reflectance. The
    /// defaults are the stock look's: the shipped crown and liquid mercury.
    ///
    /// The pixel loop runs its two halves as separate stages:
    /// ``reflection(of:at:epsilon:crownAspect:)`` for every covered pixel of a row, then
    /// ``radiance(of:environment:paint:)``.
    @inline(__always)
    static func sceneRadiance(
        of sample: MercuryField.Sample,
        at point: SIMD2<Double>,
        epsilon: Double,
        crownAspect: Double = MercuryMetrics.crownAspect,
        environment: MercuryEnvironment,
        paint: MercuryPaintLookup = .stock
    ) -> SIMD3<Double> {
        radiance(
            of: reflection(of: sample, at: point, epsilon: epsilon, crownAspect: crownAspect),
            environment: environment,
            paint: paint.table
        )
    }

    /// Where the reflection of the finite eye leaves the crown the sample lifts at `point`: a
    /// crown whose height over the centre line is `crownAspect` times the half-thickness.
    @inline(__always)
    private static func reflection(
        of sample: MercuryField.Sample,
        at point: SIMD2<Double>,
        epsilon: Double,
        crownAspect: Double
    ) -> Reflection {
        let crown = MercuryCrown.evaluate(
            field: sample.value,
            radius: sample.radius,
            aspect: crownAspect,
            epsilon: epsilon
        )
        let crownGradient = crown.gradient(
            fieldGradient: sample.gradient,
            radiusGradient: sample.radiusGradient
        )
        let normal = normalize(
            SIMD3(-crownGradient.x, -crownGradient.y, 1)
        )
        let view = MercuryOptics.viewDirection(
            horizontal: point.x,
            vertical: point.y,
            crownHeight: crown.height
        )
        let incidence = Swift.max((normal * view).sum(), 1e-4)
        let reflected = 2 * incidence * normal - view
        return Reflection(
            direction: SIMD3<Float>(
                Float(reflected.x),
                Float(reflected.y),
                Float(reflected.z)
            ),
            incidence: incidence
        )
    }

    /// The room along a reflection, times the paint's reflectance at its incidence.
    @inline(__always)
    private static func radiance(
        of reflection: Reflection,
        environment: MercuryEnvironment,
        paint: MercuryPaintLookup.Table
    ) -> SIMD3<Double> {
        let room = environment.radiance(reflection.direction)
        return SIMD3<Double>(
            Double(room.x), Double(room.y), Double(room.z)
        ) * paint.fresnel(cosine: reflection.incidence)
    }

    /// The alpha byte of a pixel the body covers by `coverage`. Its colour bytes are
    /// `MercuryOptics.encodedByte`, premultiplied by the same coverage.
    @inline(__always)
    static func alphaByte(_ coverage: Double) -> UInt8 {
        UInt8(Swift.min(255, Swift.max(0, Int(coverage * 255 + 0.5))))
    }

    // MARK: - Storage

    /// One context per pixel size, so a display hand-off between the island and a collar
    /// reallocates once rather than every frame.
    private func context(for canvas: CGRect, scale: CGFloat) -> CGContext? {
        let width = Int((canvas.width * scale).rounded())
        let height = Int((canvas.height * scale).rounded())
        if let context, context.width == width, context.height == height { return context }
        guard width > 0, height > 0 else { return nil }
        guard
            let created = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context = created
        if columnCapacity < width {
            stationKeys?.deallocate()
            stationSamples?.deallocate()
            queue?.deallocate()
            reflections?.deallocate()
            radiances?.deallocate()
            stationKeys = UnsafeMutablePointer<UInt64>.allocate(capacity: width)
            stationSamples = UnsafeMutablePointer<MercuryField.StationSample>.allocate(capacity: width)
            queue = UnsafeMutablePointer<QueuedPixel>.allocate(capacity: width)
            reflections = UnsafeMutablePointer<Reflection>.allocate(capacity: width)
            radiances = UnsafeMutablePointer<SIMD3<Double>>.allocate(capacity: width)
            columnCapacity = width
        }
        let maskWords = height * Self.wordsPerRow(width: width)
        if maskCapacity < maskWords {
            mask?.deallocate()
            mask = UnsafeMutablePointer<UInt64>.allocate(capacity: maskWords)
            maskCapacity = maskWords
        }
        return created
    }

    private static func wordsPerRow(width: Int) -> Int {
        let blocks = (width + blockWidth - 1) / blockWidth
        return (blocks + UInt64.bitWidth - 1) / UInt64.bitWidth
    }

    // MARK: - Render

    private func render(
        field: MercuryField,
        environment: MercuryEnvironment,
        response: MercuryDisplayResponse?,
        appearance: MercuryAppearance,
        paint: MercuryPaintLookup,
        context: CGContext,
        scale: CGFloat,
        samples: inout [SIMD3<Float>]?
    ) {
        guard let data = context.data, let stationKeys, let stationSamples, let queue, let reflections, let radiances,
            let mask
        else { return }
        let width = context.width
        let height = context.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        memset(data, 0, context.bytesPerRow * height)

        let canvas = field.canvasBounds
        let canvasMinX = Double(canvas.minX)
        let canvasMaxY = Double(canvas.maxY)
        let pixelSize = 1 / Double(scale)
        let epsilon = MercuryMetrics.crownFilterFraction * pixelSize
        let wordsPerRow = Self.wordsPerRow(width: width)
        guard
            let rows = Self.markExtents(
                of: field,
                in: mask,
                width: width,
                height: height,
                wordsPerRow: wordsPerRow,
                pixelSize: pixelSize
            )
        else { return }

        for column in 0..<width {
            stationKeys[column] = Self.unsetStationKey
        }

        let spine = field.spine
        prepareBendCharts(spine: spine, canvas: canvas, pixelSize: pixelSize, width: width, height: height)
        let boxes = bendBoxes
        let keptCharts = bendCharts
        let keptStates = bendChartStates
        let collecting = samples != nil
        let selectedResponse: MercuryDisplayResponse?
        if let response {
            selectedResponse =
                appearance.increasedContrast
                ? response.remapped(
                    medianTarget: MercuryMetrics.increasedContrastMedian,
                    highlightTarget: MercuryMetrics.increasedContrastHighlight
                ) ?? response
                : response
        } else {
            selectedResponse = nil
        }
        let displayLookup = selectedResponse.map { lookup(for: $0) }
        // Taken once: a lazy global would check its initializer at every one of a pixel's reads.
        let optics = MercuryOptics.tables
        // The look's two per-frame inputs, also taken once: the paint's table, read through its
        // address, and the crown's aspect. The table borrows `paint`'s storage, which outlives
        // every row: a parameter is guaranteed alive for the whole call.
        let reflectance = paint.table
        let crownAspect = field.crownAspect
        for row in rows {
            let vertical = canvasMaxY - (Double(row) + 0.5) * pixelSize
            let words = mask + row * wordsPerRow
            // The kept charts' columns on this row: one box on each side of the housing at most,
            // and each `base` already offset so a column indexes it directly.
            var near = (low: 1, high: 0, base: 0)
            var far = (low: 1, high: 0, base: 0)
            for box in boxes where box.rows.contains(row) {
                let entry = (
                    low: box.columns.lowerBound,
                    high: box.columns.upperBound,
                    base: box.base + (row - box.rows.lowerBound) * box.columns.count - box.columns.lowerBound
                )
                if near.low > near.high { near = entry } else { far = entry }
            }
            // Cover: chart, sample and cover each marked pixel, and queue those the body covers.
            var queued = 0
            for word in 0..<wordsPerRow {
                var blocks = words[word]
                while blocks != 0 {
                    let first = (word * UInt64.bitWidth + blocks.trailingZeroBitCount) * Self.blockWidth
                    blocks &= blocks - 1
                    for columnIndex in first..<Swift.min(first + Self.blockWidth, width) {
                        let horizontal =
                            canvasMinX + (Double(columnIndex) + 0.5) * pixelSize
                        let point = SIMD2(horizontal, vertical)
                        let slot =
                            columnIndex >= near.low && columnIndex <= near.high
                            ? near.base + columnIndex
                            : columnIndex >= far.low && columnIndex <= far.high ? far.base + columnIndex : -1
                        let chart: MercurySpine.Chart
                        if slot >= 0, let keptCharts, let keptStates {
                            switch keptStates[slot] {
                            case 1:
                                chart = keptCharts[slot]
                            case 2:
                                continue
                            default:
                                guard let fresh = spine.chart(at: point) else {
                                    keptStates[slot] = 2
                                    continue
                                }
                                (keptCharts + slot).initialize(to: fresh)
                                keptStates[slot] = 1
                                chart = fresh
                            }
                        } else {
                            guard let fresh = spine.chart(at: point) else { continue }
                            chart = fresh
                        }
                        let station: MercuryField.StationSample
                        if chart.isHorizontal {
                            let key = chart.arcLength.bitPattern
                            if stationKeys[columnIndex] != key {
                                stationKeys[columnIndex] = key
                                stationSamples[columnIndex] = field.stationSample(at: chart.arcLength)
                            }
                            station = stationSamples[columnIndex]
                        } else {
                            station = field.stationSample(at: chart.arcLength)
                        }
                        guard station.radius > 0 else { continue }
                        let sample = field.sample(at: point, chart: chart, station: station)
                        let coverage = Self.coverage(of: sample, chart: chart, pixelSize: pixelSize)
                        guard coverage > 0 else { continue }
                        if collecting, coverage <= 0.5 { continue }
                        queue[queued] = QueuedPixel(
                            column: columnIndex, point: point, sample: sample, coverage: coverage)
                        queued += 1
                    }
                }
            }
            // Reflect, then light: each its own pass over the row. See the type's discussion.
            for entry in 0..<queued {
                reflections[entry] = Self.reflection(
                    of: queue[entry].sample,
                    at: queue[entry].point,
                    epsilon: epsilon,
                    crownAspect: crownAspect
                )
            }
            for entry in 0..<queued {
                radiances[entry] = Self.radiance(of: reflections[entry], environment: environment, paint: reflectance)
            }
            // Write.
            if collecting {
                for entry in 0..<queued {
                    let scene = radiances[entry]
                    samples?.append(SIMD3<Float>(Float(scene.x), Float(scene.y), Float(scene.z)))
                }
            } else if let displayLookup {
                for entry in 0..<queued {
                    let display = displayLookup.map(radiances[entry])
                    let coverage = queue[entry].coverage
                    let index = (row * width + queue[entry].column) * 4
                    bytes[index] = optics.encodedByte(display.x, coverage: coverage)
                    bytes[index + 1] = optics.encodedByte(display.y, coverage: coverage)
                    bytes[index + 2] = optics.encodedByte(display.z, coverage: coverage)
                    bytes[index + 3] = Self.alphaByte(coverage)
                }
            }
        }
    }

    /// Lays out the kept charts for `spine` on this canvas, forgetting the old ones, unless
    /// they were charted on exactly these.
    ///
    /// Each bend gets the box of pixels around it: a convex corner's quadrant, out to the
    /// farthest the body can reach past it, the spine's ceiling and its ramp; a fillet's square.
    /// A pixel outside every box is simply charted afresh, so the boxes decide only what is kept.
    private func prepareBendCharts(spine: MercurySpine, canvas: CGRect, pixelSize: Double, width: Int, height: Int) {
        let key = BendChartKey(spine: spine, canvas: canvas, pixelSize: pixelSize)
        guard key != bendChartKey else { return }
        bendChartKey = key
        bendBoxes = []
        guard case .collar(let outline) = spine.kind else { return }
        let canvasMinX = Double(canvas.minX)
        let canvasMaxY = Double(canvas.maxY)
        let reach = spine.maxHalfHeight + 5
        let corner = outline.cornerRadius
        let fillet = outline.filletRadius
        let regions = [
            (outline.minX - reach, outline.minX + corner, outline.bottom - reach, outline.bottom + corner),
            (outline.maxX - corner, outline.maxX + reach, outline.bottom - reach, outline.bottom + corner),
            (outline.minX - fillet, outline.minX, outline.top - fillet, outline.top),
            (outline.maxX, outline.maxX + fillet, outline.top - fillet, outline.top),
        ]
        var total = 0
        for (minX, maxX, minY, maxY) in regions {
            guard
                let columns = Self.centres(
                    from: (minX - canvasMinX) / pixelSize,
                    through: (maxX - canvasMinX) / pixelSize,
                    count: width
                ),
                let rows = Self.centres(
                    from: (canvasMaxY - maxY) / pixelSize,
                    through: (canvasMaxY - minY) / pixelSize,
                    count: height
                )
            else { continue }
            bendBoxes.append(BendBox(rows: rows, columns: columns, base: total))
            total += rows.count * columns.count
        }
        if bendChartCapacity < total {
            bendCharts?.deallocate()
            bendChartStates?.deallocate()
            bendCharts = UnsafeMutablePointer<MercurySpine.Chart>.allocate(capacity: total)
            bendChartStates = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
            bendChartCapacity = total
        }
        bendChartStates?.update(repeating: 0, count: total)
    }

    /// Marks, row by row, the blocks of columns any of `field`'s extents reaches, and returns
    /// the rows marked, or nil when none is.
    ///
    /// A pixel is marked when its centre lies in an extent's box grown by the extent's ramp
    /// reach and one more pixel. The spare pixel absorbs the rounding in the boxes themselves.
    private static func markExtents(
        of field: MercuryField,
        in mask: UnsafeMutablePointer<UInt64>,
        width: Int,
        height: Int,
        wordsPerRow: Int,
        pixelSize: Double
    ) -> ClosedRange<Int>? {
        mask.update(repeating: 0, count: height * wordsPerRow)
        let canvas = field.canvasBounds
        let canvasMinX = Double(canvas.minX)
        let canvasMaxY = Double(canvas.maxY)
        var firstRow = height
        var lastRow = -1
        for extent in field.extents {
            let reach = (extent.rampReach + 1) * pixelSize
            guard
                let columns = centres(
                    from: (extent.lower.x - reach - canvasMinX) / pixelSize,
                    through: (extent.upper.x + reach - canvasMinX) / pixelSize,
                    count: width
                ),
                let rows = centres(
                    from: (canvasMaxY - extent.upper.y - reach) / pixelSize,
                    through: (canvasMaxY - extent.lower.y + reach) / pixelSize,
                    count: height
                )
            else { continue }
            let firstBlock = columns.lowerBound / blockWidth
            let lastBlock = columns.upperBound / blockWidth
            for row in rows {
                let words = mask + row * wordsPerRow
                for word in firstBlock / UInt64.bitWidth...lastBlock / UInt64.bitWidth {
                    let low = Swift.max(firstBlock - word * UInt64.bitWidth, 0)
                    let high = Swift.min(lastBlock - word * UInt64.bitWidth, UInt64.bitWidth - 1)
                    // Bits `low` through `high`, without ever shifting a word by its own width.
                    words[word] |= (UInt64.max &>> (UInt64.bitWidth - 1 - (high - low))) &<< low
                }
            }
            firstRow = Swift.min(firstRow, rows.lowerBound)
            lastRow = Swift.max(lastRow, rows.upperBound)
        }
        return firstRow <= lastRow ? firstRow...lastRow : nil
    }

    /// The indices `i` in `0..<count` whose centres `i + ½` lie within `lower…upper`, in
    /// pixels, or nil when there are none, or the bounds are not numbers.
    @inline(__always)
    private static func centres(from lower: Double, through upper: Double, count: Int) -> ClosedRange<Int>? {
        let first = (lower - 0.5).rounded(.up)
        let last = (upper - 0.5).rounded(.down)
        guard first <= last, last >= 0, first <= Double(count - 1) else { return nil }
        return Int(Swift.max(first, 0))...Int(Swift.min(last, Double(count - 1)))
    }

    private func lookup(for response: MercuryDisplayResponse) -> MercuryDisplayLookup {
        if responseKey != response || responseLookup == nil {
            responseKey = response
            responseLookup = MercuryDisplayLookup(response: response)
        }
        return responseLookup!
    }

    @inline(__always)
    private static func normalize(_ value: SIMD3<Double>) -> SIMD3<Double> {
        let squaredLength = (value * value).sum()
        guard squaredLength > 1e-24 else { return SIMD3(0, 0, 1) }
        return value * (1 / squaredLength.squareRoot())
    }

}
