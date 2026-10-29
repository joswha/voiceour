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
/// also lifts a fixed-aspect half-elliptic crown whose exact total gradient supplies the
/// surface normal. A static generated RGB room, exact conductor Fresnel and a bounded
/// two-anchor response complete the material; no highlight, rim or gradient is authored.
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
@MainActor
final class MercuryRasterizer {
    private var context: CGContext?
    /// Per pixel column, the bit pattern of the last horizontal chart's arc length and the
    /// station sample at it. A cache of ``MercuryField/stationSample(at:)``, never a second
    /// evaluator: a key that does not match is simply recomputed.
    private var stationKeys: UnsafeMutablePointer<UInt64>?
    private var stationSamples: UnsafeMutablePointer<MercuryField.StationSample>?
    private var stationCapacity = 0
    /// The sparse mask: per pixel row, one bit per block of ``blockWidth`` columns that an
    /// extent reaches, in `wordsPerRow` words. Rebuilt every frame.
    private var mask: UnsafeMutablePointer<UInt64>?
    private var maskCapacity = 0
    private var responseKey: MercuryDisplayResponse?
    private var responseLookup: MercuryDisplayLookup?

    /// No chart's arc length has this bit pattern: it is finite for every finite pixel.
    private static let unsetStationKey = Double.nan.bitPattern
    /// Columns per mask bit. A block's spare columns cost a few rejected pixels at each end of
    /// a row's run, against one bit per pixel to clear and scan.
    private static let blockWidth = 8

    isolated deinit {
        stationKeys?.deallocate()
        stationSamples?.deallocate()
        mask?.deallocate()
    }

    func image(
        field: MercuryField,
        environment: MercuryEnvironment,
        response: MercuryDisplayResponse,
        appearance: MercuryAppearance,
        scale: CGFloat
    ) -> CGImage? {
        guard let context = context(for: field.canvasBounds, scale: scale) else { return nil }
        var samples: [SIMD3<Float>]?
        render(
            field: field,
            environment: environment,
            response: response,
            appearance: appearance,
            context: context,
            scale: scale,
            samples: &samples
        )
        return context.makeImage()
    }

    /// Linear `environment × conductor Fresnel` samples before the display response.
    /// Calibration pools these over listening and speaking, then solves two anchors once.
    func sampleSceneRadiance(
        field: MercuryField,
        environment: MercuryEnvironment,
        scale: CGFloat
    ) -> [SIMD3<Float>] {
        guard let context = context(for: field.canvasBounds, scale: scale) else { return [] }
        var samples: [SIMD3<Float>]? = []
        render(
            field: field,
            environment: environment,
            response: nil,
            appearance: .standard,
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
    /// `n` outside it keeps only the `½ + n/h` of itself that lies outside, and the rim is
    /// antialiased rather than drawn by centre. The ears and fillets meet the screen's top
    /// edge, which is the canvas edge, and the island meets nothing.
    @inline(__always)
    static func coverage(of sample: MercuryField.Sample, chart: MercurySpine.Chart, pixelSize: Double) -> Double {
        let fieldGradient = sample.gradient
        let gradientLength = (fieldGradient * fieldGradient).sum().squareRoot()
        guard gradientLength > 1e-9 else { return 0 }
        let body = Swift.min(Swift.max(0.5 + sample.value / (gradientLength * pixelSize), 0), 1)
        guard chart.bordersHousing else { return body }
        return body * Swift.min(Swift.max(0.5 + chart.normalOffset / pixelSize, 0), 1)
    }

    /// The linear scene radiance a covered point reflects: the room, seen off the crown the
    /// sample lifts from the finite eye, times the conductor's Fresnel.
    @inline(__always)
    static func sceneRadiance(
        of sample: MercuryField.Sample,
        at point: SIMD2<Double>,
        epsilon: Double,
        environment: MercuryEnvironment
    ) -> SIMD3<Double> {
        let crown = MercuryCrown.evaluate(
            field: sample.value,
            radius: sample.radius,
            aspect: MercuryMetrics.crownAspect,
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
        let room = environment.radiance(
            SIMD3<Float>(
                Float(reflected.x),
                Float(reflected.y),
                Float(reflected.z)
            )
        )
        return SIMD3<Double>(
            Double(room.x), Double(room.y), Double(room.z)
        ) * MercuryOptics.fresnel(cosine: incidence)
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
        if stationCapacity < width {
            stationKeys?.deallocate()
            stationSamples?.deallocate()
            stationKeys = UnsafeMutablePointer<UInt64>.allocate(capacity: width)
            stationSamples = UnsafeMutablePointer<MercuryField.StationSample>.allocate(capacity: width)
            stationCapacity = width
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
        context: CGContext,
        scale: CGFloat,
        samples: inout [SIMD3<Float>]?
    ) {
        guard let data = context.data, let stationKeys, let stationSamples, let mask else { return }
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
        for row in rows {
            let vertical = canvasMaxY - (Double(row) + 0.5) * pixelSize
            let words = mask + row * wordsPerRow
            for word in 0..<wordsPerRow {
                var blocks = words[word]
                while blocks != 0 {
                    let first = (word * UInt64.bitWidth + blocks.trailingZeroBitCount) * Self.blockWidth
                    blocks &= blocks - 1
                    for columnIndex in first..<Swift.min(first + Self.blockWidth, width) {
                        let horizontal =
                            canvasMinX + (Double(columnIndex) + 0.5) * pixelSize
                        let point = SIMD2(horizontal, vertical)
                        guard let chart = spine.chart(at: point) else { continue }
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

                        let scene = Self.sceneRadiance(
                            of: sample,
                            at: point,
                            epsilon: epsilon,
                            environment: environment
                        )
                        if collecting {
                            samples?.append(
                                SIMD3<Float>(Float(scene.x), Float(scene.y), Float(scene.z))
                            )
                            continue
                        }
                        guard let displayLookup else { continue }
                        let display = displayLookup.map(scene)
                        let index = (row * width + columnIndex) * 4
                        bytes[index] = MercuryOptics.encodedByte(display.x, coverage: coverage)
                        bytes[index + 1] = MercuryOptics.encodedByte(display.y, coverage: coverage)
                        bytes[index + 2] = MercuryOptics.encodedByte(display.z, coverage: coverage)
                        bytes[index + 3] = Self.alphaByte(coverage)
                    }
                }
            }
        }
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
