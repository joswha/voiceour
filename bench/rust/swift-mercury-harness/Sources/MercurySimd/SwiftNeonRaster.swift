import CoreGraphics
import Foundation
import VoiceCore

/// Bet B6 control arm: `bench/rust/mercury-raster/src/raster_neon.rs` (`rust-neon`) written
/// in Swift with the standard library's SIMD types, so the redesign — column invariants
/// computed once, three short stages per row through column-indexed scratch, two or four
/// pixels per vector — can be timed apart from the language.
///
/// The structure, data layout and every operation follow raster_neon.rs: `SIMD2<Double>`
/// where it uses `float64x2_t`, `SIMD4<Float>` for `float32x4_t`, the same scratch buffers
/// with the same padding, the same stage split, the same lane masks and the same scalar
/// fallbacks. Byte identity with the shipped `MercuryRasterizer` holds by construction, as
/// in Rust: lane arithmetic is IEEE and unfused, conversions round the same way, and every
/// `Swift.max` / `Swift.min` is the same comparison feeding a select. Field construction,
/// column resolution, the scalar fallback and every table formula are the production code
/// itself: this file is compiled together with the verbatim copies under
/// `SwiftMercuryHarness/Production`, which this target reaches through a symlink.
///
/// Where Swift's SIMD library differs from NEON the deviation is local and named:
/// `negated` (the SIMD prefix `-` is `0 - x`, which drops the sign of zero), `magnitude`
/// (no SIMD `abs`), `swiftMax`/`swiftMin` (`pointwiseMax`/`pointwiseMin` are IEEE
/// `maximum`/`minimum`), `truncated` (the library's `init(_:rounding:)` is an out-of-line
/// generic over a resilient enum) and `indexLanes` (no saturating float-to-integer
/// conversion). Stage functions are `@inline(always)`, Rust's `#[inline(always)]`: under
/// `@inline(__always)` the SIL inliner judged them "not profitable" and left `room`
/// out of line in the -O build.
///
/// Built twice from this one file (Package.swift): `MercurySimd` with the package's release
/// settings (-O) for `swift-simd`, and `MercurySimdUnchecked` with `-Ounchecked` for
/// `swift-simd-unchecked`.
@MainActor
public final class SimdRasterEngine {
    private let environment: MercuryEnvironment
    private let response: MercuryDisplayResponse
    /// Level 0 of the room's bordered octahedral table: `SIMD3<Float>` texels, 16 bytes each.
    private let texels: UnsafeRawPointer
    private var context: CGContext?
    private var scale: CGFloat = 0
    private var columns: UnsafeMutablePointer<MercuryField.Column>?
    private var scratch: Scratch?
    private var columnCapacity = 0
    private var responseKey: MercuryDisplayResponse?
    private var responseLookup: MercuryDisplayLookup?
    /// The selected lookup's `[SIMD2<Float>]` table, copied once per response change.
    private let lookupTable = UnsafeMutablePointer<SIMD2<Float>>.allocate(capacity: Tables.lookupCount)

    /// One session's lighting: the Room of Ten for `seed` and the calibrated response.
    public init(
        seed: UInt64,
        exponent: Double,
        halfSaturation: Double,
        ceiling: Double,
        sceneMedian: Double,
        sceneHighlight: Double
    ) {
        environment = MercuryEnvironment(world: .roomOfTen, seed: seed)
        response = MercuryDisplayResponse(
            exponent: exponent,
            halfSaturation: halfSaturation,
            ceiling: ceiling,
            sceneMedian: sceneMedian,
            sceneHighlight: sceneHighlight
        )
        texels = Self.roomTexels(environment)
        lookupTable.initialize(repeating: .zero, count: Tables.lookupCount)
        // Build the process tables and this response's lookup outside any timed call.
        _ = Tables.fresnel
        _ = Tables.opaqueBytes
        _ = lookup(for: response)
    }

    isolated deinit {
        columns?.deallocate()
        scratch?.deallocate()
        lookupTable.deallocate()
    }

    /// One production raster: `MercuryField(geometry:lateralOffset:)`, the pixel fill and
    /// `makeImage()` — the harness's timed unit. Nil for an empty field, like the Swift arm.
    public func image(
        top: [Float],
        bottom: [Float],
        length: CGFloat,
        halfHeight: CGFloat,
        lateralOffset: CGFloat,
        increasedContrast: Bool,
        scale: CGFloat
    ) -> CGImage? {
        let geometry = MercurySimulation.Geometry(
            length: length,
            halfHeight: halfHeight,
            top: top,
            bottom: bottom
        )
        let field = MercuryField(geometry: geometry, lateralOffset: lateralOffset)
        guard field.boundingBox.width > 0, field.boundingBox.height > 0 else { return nil }
        guard let context = context(for: scale) else { return nil }
        render(
            field: field,
            appearance: MercuryAppearance(increasedContrast: increasedContrast),
            context: context
        )
        return context.makeImage()
    }

    // MARK: - Storage

    /// `MercuryRasterizer.context(for:)`, plus the scratch sized with the column buffer.
    private func context(for scale: CGFloat) -> CGContext? {
        if let context, self.scale == scale { return context }
        let width = Int((RecordingOverlayMetrics.islandSize.width * scale).rounded())
        let height = Int((RecordingOverlayMetrics.islandSize.height * scale).rounded())
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
        self.scale = scale
        if columnCapacity < width {
            columns?.deallocate()
            columns = UnsafeMutablePointer<MercuryField.Column>.allocate(capacity: width)
            scratch?.deallocate()
            scratch = Scratch(capacity: width + Scratch.pad)
            columnCapacity = width
        }
        return created
    }

    /// `MercuryRasterizer.lookup(for:)`, keeping a raw copy of the lookup's table for the
    /// vector stage (the production table is a private stored property).
    private func lookup(for response: MercuryDisplayResponse) -> MercuryDisplayLookup {
        if responseKey != response || responseLookup == nil {
            responseKey = response
            let lookup = MercuryDisplayLookup(response: response)
            responseLookup = lookup
            guard
                let table = Mirror(reflecting: lookup).children
                    .first(where: { $0.label == "table" })?.value as? [SIMD2<Float>],
                table.count == Tables.lookupCount
            else { fatalError("MercuryDisplayLookup no longer stores `table` as [SIMD2<Float>]") }
            for index in 0..<Tables.lookupCount {
                lookupTable[index] = table[index]
            }
        }
        return responseLookup!
    }

    /// The room's level-0 texels, read through reflection so the production copy stays
    /// verbatim (`tables` is a private stored property; `Dump.roomTables` reads it the same way).
    private static func roomTexels(_ environment: MercuryEnvironment) -> UnsafeRawPointer {
        var pointer: UnsafeMutablePointer<SIMD3<Float>>?
        var capacity: Int?
        for child in Mirror(reflecting: environment).children {
            switch child.label {
            case "tables": pointer = child.value as? UnsafeMutablePointer<SIMD3<Float>>
            case "capacity": capacity = child.value as? Int
            default: break
            }
        }
        guard
            let pointer,
            capacity == MercuryMetrics.environmentRoughness.count * Tables.storage * Tables.storage,
            MemoryLayout<SIMD3<Float>>.stride == 16
        else { fatalError("MercuryEnvironment no longer stores `tables`/`capacity` as 16-byte texels") }
        return UnsafeRawPointer(pointer)
    }

    // MARK: - Render

    /// `MercuryRasterizer.render` for `image(...)` with raster_neon.rs's row pipeline.
    private func render(field: MercuryField, appearance: MercuryAppearance, context: CGContext) {
        guard let data = context.data, let columns, let scratch else { return }
        let width = context.width
        let height = context.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        memset(data, 0, context.bytesPerRow * height)

        // The production prologue, verbatim: span and column pass.
        let box = field.boundingBox
        guard box.width > 0, box.height > 0 else { return }
        let bounds = MercuryField.islandBounds
        let boundsMinX = Double(bounds.minX)
        let boundsMaxY = Double(bounds.maxY)
        let pixelSize = 1 / Double(scale)
        let epsilon = MercuryMetrics.crownFilterFraction * pixelSize
        let firstColumn = Swift.max(
            0,
            Int(((box.minX - bounds.minX) * scale).rounded(.down))
        )
        let lastColumn = Swift.min(
            width - 1,
            Int(((box.maxX - bounds.minX) * scale).rounded(.up))
        )
        let firstRow = Swift.max(
            0,
            Int(((bounds.maxY - box.maxY) * scale).rounded(.down))
        )
        let lastRow = Swift.min(
            height - 1,
            Int(((bounds.maxY - box.minY) * scale).rounded(.up))
        )
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }

        let horizontalOffset = field.lateralOffset
        for column in firstColumn...lastColumn {
            let position = boundsMinX + (Double(column) + 0.5) * pixelSize
            columns[column] = field.column(atX: position - horizontalOffset)
        }

        let length = Swift.max(field.length, 1)
        let selectedResponse =
            appearance.increasedContrast
            ? response.remapped(
                medianTarget: MercuryMetrics.increasedContrastMedian,
                highlightTarget: MercuryMetrics.increasedContrastHighlight
            ) ?? response
            : response
        let displayLookup = lookup(for: selectedResponse)

        // raster_neon.rs `Scratch::prepare`: per-column invariants, the identical expressions.
        // Stage 1 rewrites the span's flags every row; nothing outside it may stay live.
        memset(scratch.live, 0, scratch.capacity)
        for index in firstColumn...lastColumn {
            let column = columns[index]
            // `MercuryField.gradient` for each branch of its sign.
            let (upperSign, lowerSign) = (1.0, -1.0)
            let upperX = (column.radiusSlope + upperSign * column.centerSlope) / length
            let lowerX = (column.radiusSlope + lowerSign * column.centerSlope) / length
            let (upperY, lowerY) = (-upperSign, -lowerSign)
            let upperLength = (upperX * upperX + upperY * upperY).squareRoot()
            let lowerLength = (lowerX * lowerX + lowerY * lowerY).squareRoot()
            scratch.paired[index] =
                column.inSpan && column.radius > 0 && upperLength > 1e-9 && lowerLength > 1e-9
            scratch.center[index] = column.center
            scratch.radius[index] = column.radius
            scratch.gradientUpper[index] = upperX
            scratch.gradientLower[index] = lowerX
            scratch.denominatorUpper[index] = upperLength * pixelSize
            scratch.denominatorLower[index] = lowerLength * pixelSize
            scratch.radiusGradient[index] = column.radiusSlope / length
            scratch.negativeHorizontal[index] = -(boundsMinX + (Double(index) + 0.5) * pixelSize)
        }

        let kernel = Kernel(
            scratch: scratch,
            columns: columns,
            bytes: bytes,
            width: width,
            boundsMinX: boundsMinX,
            pixelSize: pixelSize,
            epsilon: epsilon,
            length: length,
            environment: environment,
            texels: texels,
            fresnel: Tables.fresnel,
            opaqueBytes: Tables.opaqueBytes,
            lookup: displayLookup,
            lookupTable: lookupTable,
            halfSaturation: displayLookup.response.halfSaturation,
            ceiling: displayLookup.response.ceiling
        )
        let fourEpsilonSquared = 4 * epsilon * epsilon
        for row in firstRow...lastRow {
            let vertical = boundsMaxY - (Double(row) + 0.5) * pixelSize
            let rowStart = row * width

            // Stage 1; remembers the live interval so the later stages skip the dead margin.
            var firstLive = Int.max
            var lastLive = 0
            var index = firstColumn
            while index <= lastColumn {
                if index < lastColumn && scratch.paired[index] && scratch.paired[index + 1] {
                    if kernel.geometry(index, vertical: vertical, fourEpsilonSquared: fourEpsilonSquared) {
                        firstLive = Swift.min(firstLive, index)
                        lastLive = index + 1
                    }
                    index += 2
                } else {
                    scratch.live[index] = 0
                    kernel.shade(index, row: row, vertical: vertical)
                    index += 1
                }
            }
            if firstLive > lastLive { continue }

            // Stage 2 reads `index..<index + 4`, at most `lastColumn + 3 < width + pad`.
            index = firstLive
            while index <= lastLive {
                kernel.room(index)
                index += 4
            }

            // Stage 3 writes only live pixels, all inside the span.
            index = firstLive
            while index <= lastLive {
                kernel.respond(index, pixels: bytes + (rowStart + index) * 4)
                index += 2
            }
        }
    }
}

// MARK: - Scratch

/// raster_neon.rs `Scratch`: per-column invariants and per-row stage buffers, all indexed
/// by raster column. Raw storage, as in Rust's stage functions: no bounds checks, no
/// retain traffic, no exclusivity checks on the hot path.
private struct Scratch {
    /// Stage loops read up to three columns past the span; every buffer carries this slack.
    static let pad = 4

    let capacity: Int
    /// In span with a positive radius: eligible for the paired path.
    let paired: UnsafeMutablePointer<Bool>
    let center: UnsafeMutablePointer<Double>
    let radius: UnsafeMutablePointer<Double>
    /// `MercuryField.gradient`'s x component for `offset >= 0` and for `offset < 0`.
    let gradientUpper: UnsafeMutablePointer<Double>
    let gradientLower: UnsafeMutablePointer<Double>
    /// `gradientLength * pixelSize` for either sign.
    let denominatorUpper: UnsafeMutablePointer<Double>
    let denominatorLower: UnsafeMutablePointer<Double>
    /// `radiusSlope / length`.
    let radiusGradient: UnsafeMutablePointer<Double>
    /// `-horizontal`, the finite-eye view's x numerator.
    let negativeHorizontal: UnsafeMutablePointer<Double>

    /// 1 when the pixel continues through stages 2 and 3.
    let live: UnsafeMutablePointer<UInt8>
    let coverage: UnsafeMutablePointer<Double>
    let incidence: UnsafeMutablePointer<Double>
    let reflectedX: UnsafeMutablePointer<Float>
    let reflectedY: UnsafeMutablePointer<Float>
    let reflectedZ: UnsafeMutablePointer<Float>
    /// Linear `room × Fresnel`, four doubles per column (r, g, b, padding).
    let scene: UnsafeMutablePointer<Double>

    init(capacity: Int) {
        func doubles(_ count: Int) -> UnsafeMutablePointer<Double> {
            let values = UnsafeMutablePointer<Double>.allocate(capacity: count)
            values.initialize(repeating: 0, count: count)
            return values
        }
        func floats() -> UnsafeMutablePointer<Float> {
            let values = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            values.initialize(repeating: 0, count: capacity)
            return values
        }
        self.capacity = capacity
        paired = .allocate(capacity: capacity)
        paired.initialize(repeating: false, count: capacity)
        center = doubles(capacity)
        radius = doubles(capacity)
        gradientUpper = doubles(capacity)
        gradientLower = doubles(capacity)
        denominatorUpper = doubles(capacity)
        denominatorLower = doubles(capacity)
        radiusGradient = doubles(capacity)
        negativeHorizontal = doubles(capacity)
        live = .allocate(capacity: capacity)
        live.initialize(repeating: 0, count: capacity)
        coverage = doubles(capacity)
        incidence = doubles(capacity)
        reflectedX = floats()
        reflectedY = floats()
        reflectedZ = floats()
        scene = doubles(capacity * 4)
    }

    func deallocate() {
        paired.deallocate()
        for values in [
            center, radius, gradientUpper, gradientLower, denominatorUpper, denominatorLower,
            radiusGradient, negativeHorizontal, coverage, incidence, scene,
        ] {
            values.deallocate()
        }
        live.deallocate()
        reflectedX.deallocate()
        reflectedY.deallocate()
        reflectedZ.deallocate()
    }
}

// MARK: - Process tables

/// `MercuryOptics`'s Fresnel and opaque-byte tables, rebuilt from the production
/// formulas (its tables are private) into raw storage the vector stages index directly.
/// Process-wide like the production `static let`s and Rust's `OPTICS`.
@MainActor
private enum Tables {
    /// `MercuryOptics.fresnelMinimum`, `.fresnelCount`, `.opaqueTransferCount`;
    /// `MercuryDisplayLookup.count`.
    nonisolated static let fresnelMinimum = 1e-4
    nonisolated static let fresnelCount = 1_024
    nonisolated static let opaqueTransferCount = 16_384
    nonisolated static let lookupCount = 2_048
    /// `MercuryEnvironment.resolution` and its bordered storage resolution.
    nonisolated static let resolution = MercuryMetrics.environmentResolution
    nonisolated static let storage = resolution + 2

    /// `MercuryOptics.fresnelTable` with a zero fourth lane, 16 bytes per node.
    static let fresnel: UnsafeMutablePointer<SIMD4<Float>> = {
        let table = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: fresnelCount)
        for index in 0..<fresnelCount {
            let cosine =
                fresnelMinimum
                + (1 - fresnelMinimum) * Double(index) / Double(fresnelCount - 1)
            let value = MercuryOptics.exactFresnel(cosine: cosine)
            table.advanced(by: index).initialize(
                to: SIMD4(Float(value.x), Float(value.y), Float(value.z), 0)
            )
        }
        return table
    }()

    /// `MercuryOptics.opaqueTransferTable`.
    static let opaqueBytes: UnsafeMutablePointer<UInt8> = {
        let table = UnsafeMutablePointer<UInt8>.allocate(capacity: opaqueTransferCount)
        for index in 0..<opaqueTransferCount {
            let encoded = MercuryOptics.exactEncodeSRGB(Double(index) / Double(opaqueTransferCount - 1))
            table.advanced(by: index).initialize(
                to: UInt8(Swift.min(255, Swift.max(0, Int(encoded * 255 + 0.5))))
            )
        }
        return table
    }()
}

// MARK: - Lane helpers

private typealias Pair = SIMD2<Double>
private typealias Quad = SIMD4<Float>

@inline(always)
private func splat(_ value: Double) -> Pair {
    Pair(repeating: value)
}

@inline(always)
private func splat32(_ value: Float) -> Quad {
    Quad(repeating: value)
}

/// `Swift.max(x, y)` lane-wise: `y >= x ? y : x`. (`pointwiseMax` is IEEE `maximum`, which
/// differs on NaN and on the sign of a zero result.)
@inline(always)
private func swiftMax(_ x: Pair, _ y: Pair) -> Pair {
    x.replacing(with: y, where: y .>= x)
}

/// `Swift.min(x, y)` lane-wise: `y < x ? y : x`.
@inline(always)
private func swiftMin(_ x: Pair, _ y: Pair) -> Pair {
    x.replacing(with: y, where: y .< x)
}

/// IEEE negation per lane (NEON `FNEG`). The SIMD prefix `-` is defined as `0 - x`, which
/// returns +0 for +0 where a sign flip gives -0; the scalar `-` the production code
/// applies is a sign flip.
@inline(always)
private func negated(_ value: Pair) -> Pair {
    Pair(-value.x, -value.y)
}

/// `abs` per lane (NEON `FABS`); the standard library has no SIMD `abs`.
@inline(always)
private func magnitude(_ value: Pair) -> Pair {
    Pair(value.x.magnitude, value.y.magnitude)
}

@inline(always)
private func magnitude(_ value: Quad) -> Quad {
    Quad(value.x.magnitude, value.y.magnitude, value.z.magnitude, value.w.magnitude)
}

/// NEON `FCVTZS` on four `Float` lanes for in-range values: `Int32(_:)` truncates per lane.
/// The library's `SIMD4<Int32>(value, rounding: .towardZero)` is an out-of-line generic over
/// the resilient `FloatingPointRoundingRule`: a metadata call, then per lane a case-tag
/// switch and a generic `_convert(from:)` call. Each `Int32(_:)` keeps its range checks
/// under -O; -Ounchecked drops them.
@inline(always)
private func truncated(_ value: Quad) -> SIMD4<Int32> {
    SIMD4(Int32(value.x), Int32(value.y), Int32(value.z), Int32(value.w))
}

/// raster_neon.rs `index_lanes`: `Int(value)` per lane, clamped to `0...last` so garbage
/// lanes stay in bounds. NEON truncates with saturation (NaN to 0) and clamps afterwards;
/// Swift's conversion traps outside `Int64`, so the same clamp runs first, in the floating
/// domain, with NaN to 0. The result is identical for every input, and valid lanes are
/// already inside, where the clamp is the identity.
@inline(always)
private func indexLanes(_ value: Pair, _ last: Int) -> SIMD2<Int64> {
    let upper = Double(last)
    let bounded = splat(0).replacing(with: value, where: value .>= splat(0))
        .replacing(with: upper, where: value .> splat(upper))
    return SIMD2(Int64(bounded.x), Int64(bounded.y))
}

@inline(always)
private func load(_ values: UnsafeMutablePointer<Double>, _ index: Int) -> Pair {
    UnsafeRawPointer(values + index).loadUnaligned(as: Pair.self)
}

@inline(always)
private func store(_ values: UnsafeMutablePointer<Double>, _ index: Int, _ value: Pair) {
    UnsafeMutableRawPointer(values + index).storeBytes(of: value, as: Pair.self)
}

@inline(always)
private func load(_ values: UnsafeMutablePointer<Float>, _ index: Int) -> Quad {
    UnsafeRawPointer(values + index).loadUnaligned(as: Quad.self)
}

@inline(always)
private func store(_ values: UnsafeMutablePointer<Float>, _ index: Int, _ value: SIMD2<Float>) {
    UnsafeMutableRawPointer(values + index).storeBytes(of: value, as: SIMD2<Float>.self)
}

/// `MercuryRasterizer.normalize`.
@inline(always)
private func normalize(_ value: SIMD3<Double>) -> SIMD3<Double> {
    let squaredLength = (value * value).sum()
    guard squaredLength > 1e-24 else { return SIMD3(0, 0, 1) }
    return value * (1 / squaredLength.squareRoot())
}

/// `MercuryRasterizer.byte`.
@inline(always)
private func byte(_ value: Double) -> UInt8 {
    UInt8(Swift.min(255, Swift.max(0, Int(value * 255 + 0.5))))
}

// MARK: - Stages

/// One render's constants and storage; the stage bodies of raster_neon.rs.
@MainActor
private struct Kernel {
    let scratch: Scratch
    let columns: UnsafeMutablePointer<MercuryField.Column>
    let bytes: UnsafeMutablePointer<UInt8>
    let width: Int
    let boundsMinX: Double
    let pixelSize: Double
    let epsilon: Double
    /// `Swift.max(field.length, 1)`.
    let length: Double
    let environment: MercuryEnvironment
    let texels: UnsafeRawPointer
    let fresnel: UnsafeMutablePointer<SIMD4<Float>>
    let opaqueBytes: UnsafeMutablePointer<UInt8>
    let lookup: MercuryDisplayLookup
    let lookupTable: UnsafeMutablePointer<SIMD2<Float>>
    let halfSaturation: Double
    let ceiling: Double

    /// Stage 1 for pixels `index` and `index + 1`: coverage, crown, normal, view, incidence
    /// and the `Float` mirror direction. Returns whether either pixel is covered.
    @inline(always)
    func geometry(_ index: Int, vertical: Double, fourEpsilonSquared: Double) -> Bool {
        let s = scratch
        let zero = splat(0)
        let one = splat(1)
        let two = splat(2)
        let half = splat(0.5)
        let aspect = splat(MercuryMetrics.crownAspect)

        // Signed field, gradient and coverage.
        let center = load(s.center, index)
        let radius = load(s.radius, index)
        let offset = splat(vertical) - center
        let signedDistance = radius - magnitude(offset)
        let upper = offset .>= zero
        let fieldX = load(s.gradientLower, index).replacing(with: load(s.gradientUpper, index), where: upper)
        let fieldY = one.replacing(with: splat(-1), where: upper)
        let denominator = load(s.denominatorLower, index)
            .replacing(with: load(s.denominatorUpper, index), where: upper)
        let coverage = swiftMin(swiftMax(half + signedDistance / denominator, zero), one)
        let covered = coverage .> zero
        let live: (UInt8, UInt8) = (covered[0] ? 1 : 0, covered[1] ? 1 : 0)
        s.live[index] = live.0
        s.live[index + 1] = live.1
        if live.0 | live.1 == 0 { return false }
        store(s.coverage, index, coverage)

        // Half-elliptic crown and its two partials.
        let root = (signedDistance * signedDistance + splat(fourEpsilonSquared)).squareRoot()
        let smoothed = half * (signedDistance + root)
        let rate = half * (one + signedDistance / root)
        let radicand = swiftMax(
            smoothed * (two * radius - smoothed),
            splat(.leastNonzeroMagnitude)
        )
        let crown = radicand.squareRoot()
        let height = aspect * crown
        let fieldDerivative = aspect * (radius - smoothed) / crown * rate
        let radiusDerivative = aspect * smoothed / crown

        // Total crown gradient; the in-span radius gradient is (radiusSlope / length, 0).
        let radiusGradient = load(s.radiusGradient, index)
        let crownX = fieldDerivative * fieldX + radiusDerivative * radiusGradient
        let crownY = fieldDerivative * fieldY + radiusDerivative * zero

        // `normalize((-crownX, -crownY, 1))`, including its degenerate guard.
        let flippedX = negated(crownX)
        let flippedY = negated(crownY)
        let squared = (flippedX * flippedX + flippedY * flippedY) + one * one
        let normalValid = squared .> splat(1e-24)
        let inverse = one / squared.squareRoot()
        let normalX = zero.replacing(with: flippedX * inverse, where: normalValid)
        let normalY = zero.replacing(with: flippedY * inverse, where: normalValid)
        let normalZ = one.replacing(with: one * inverse, where: normalValid)

        // Finite-eye view with the binomial normalization.
        let inverseDepth = one / (splat(MercuryMetrics.eyeDistance) - height)
        let horizontalUnit = load(s.negativeHorizontal, index) * inverseDepth
        let verticalUnit = splat(-vertical) * inverseDepth
        let squaredOffset = horizontalUnit * horizontalUnit + verticalUnit * verticalUnit
        let normalization =
            one
            + squaredOffset * (splat(-0.5) + squaredOffset * (splat(0.375) - splat(0.3125) * squaredOffset))
        let viewX = horizontalUnit * normalization
        let viewY = verticalUnit * normalization
        let viewZ = normalization

        // Incidence and the mirror direction, rounded to `Float` for the room lookup.
        let incidence = swiftMax(
            (normalX * viewX + normalY * viewY) + normalZ * viewZ,
            splat(1e-4)
        )
        store(s.incidence, index, incidence)
        let twice = two * incidence
        store(s.reflectedX, index, SIMD2<Float>(twice * normalX - viewX))
        store(s.reflectedY, index, SIMD2<Float>(twice * normalY - viewY))
        store(s.reflectedZ, index, SIMD2<Float>(twice * normalZ - viewZ))
        return true
    }

    /// Stage 2 for pixels `index..<index + 4`: octahedral fold four at a time, then each
    /// live pixel's bilinear room taps and Fresnel lookup, stored as linear scene radiance.
    @inline(always)
    func room(_ index: Int) {
        let s = scratch
        let live = UnsafeRawPointer(s.live + index).loadUnaligned(as: UInt32.self)
        if live == 0 { return }
        let zero = splat32(0)
        let one = splat32(1)
        let reflectedX = load(s.reflectedX, index)
        let reflectedY = load(s.reflectedY, index)
        let reflectedZ = load(s.reflectedZ, index)

        // `MercuryOctahedralMap.encode`.
        let denominator = (magnitude(reflectedX) + magnitude(reflectedY)) + magnitude(reflectedZ)
        let encodable = denominator .> splat32(1e-12)
        let projectedX = reflectedX / denominator
        let projectedY = reflectedY / denominator
        let projectedZ = reflectedZ / denominator
        let folded = projectedZ .< zero
        let signX = one.replacing(with: splat32(-1), where: projectedX .< zero)
        let signY = one.replacing(with: splat32(-1), where: projectedY .< zero)
        let foldX = (one - magnitude(projectedY)) * signX
        let foldY = (one - magnitude(projectedX)) * signY
        let pointX = zero.replacing(with: projectedX.replacing(with: foldX, where: folded), where: encodable)
        let pointY = zero.replacing(with: projectedY.replacing(with: foldY, where: folded), where: encodable)

        // Bilinear coordinates in the bordered chart.
        let halfResolution = splat32(0.5 * Float(Tables.resolution))
        let coordinateX = (pointX + one) * halfResolution + splat32(0.5)
        let coordinateY = (pointY + one) * halfResolution + splat32(0.5)
        let limit = SIMD4<Int32>(repeating: Int32(Tables.resolution))
        let column = pointwiseMin(pointwiseMax(truncated(coordinateX), .zero), limit)
        let row = pointwiseMin(pointwiseMax(truncated(coordinateY), .zero), limit)
        let columnFraction = coordinateX - Quad(column)
        let rowFraction = coordinateY - Quad(row)
        let base = row &* SIMD4<Int32>(repeating: Int32(Tables.storage)) &+ column

        // `MercuryOptics.fresnel(cosine:)` indices and fractions, two lanes at a time.
        let minimum = splat(Tables.fresnelMinimum)
        @inline(always)
        func fresnelIndex(_ incidence: Pair) -> (SIMD2<Int64>, SIMD2<Float>) {
            let clamped = swiftMin(swiftMax(incidence, minimum), splat(1))
            let scaled =
                (clamped - minimum) * splat(Double(Tables.fresnelCount - 1))
                / splat(1 - Tables.fresnelMinimum)
            let lower = indexLanes(scaled, Tables.fresnelCount - 1)
            return (lower, SIMD2<Float>(scaled - Pair(lower)))
        }
        let (firstLower, firstFraction) = fresnelIndex(load(s.incidence, index))
        let (secondLower, secondFraction) = fresnelIndex(load(s.incidence, index + 2))
        let fresnelLower = SIMD4<Int64>(lowHalf: firstLower, highHalf: secondLower)
        let fresnelFraction = Quad(lowHalf: firstFraction, highHalf: secondFraction)

        let stride = Tables.storage * MemoryLayout<SIMD4<Float>>.stride
        for lane in 0..<4 {
            if (live >> UInt32(lane * 8)) & 0xFF == 0 { continue }
            // `MercuryEnvironment.sample(level: 0, ...)`: four taps, two lerps.
            let taps = texels + Int(base[lane]) * MemoryLayout<SIMD4<Float>>.stride
            let topLeft = taps.load(as: Quad.self)
            let topRight = taps.load(fromByteOffset: MemoryLayout<SIMD4<Float>>.stride, as: Quad.self)
            let bottomLeft = taps.load(fromByteOffset: stride, as: Quad.self)
            let bottomRight = taps.load(
                fromByteOffset: stride + MemoryLayout<SIMD4<Float>>.stride,
                as: Quad.self
            )
            let across = splat32(columnFraction[lane])
            let top = topLeft + (topRight - topLeft) * across
            let bottom = bottomLeft + (bottomRight - bottomLeft) * across
            let radiance = top + (bottom - top) * splat32(rowFraction[lane])

            // Fresnel: `table[lower] + (table[upper] - table[lower]) * fraction`.
            let lower = Int(fresnelLower[lane])
            let upper = Swift.min(lower + 1, Tables.fresnelCount - 1)
            let low = fresnel[lower]
            let high = fresnel[upper]
            let reflectance = low + (high - low) * splat32(fresnelFraction[lane])

            // Linear scene radiance in `Double`, (r, g) and (b, padding).
            let scene = UnsafeMutableRawPointer(s.scene + (index + lane) * 4)
            scene.storeBytes(
                of: Pair(radiance.lowHalf) * Pair(reflectance.lowHalf),
                as: Pair.self
            )
            scene.storeBytes(
                of: Pair(radiance.highHalf) * Pair(reflectance.highHalf),
                toByteOffset: MemoryLayout<Pair>.stride,
                as: Pair.self
            )
        }
    }

    /// Stage 3 for pixels `index` and `index + 1`: display response and sRGB bytes.
    @inline(always)
    func respond(_ index: Int, pixels: UnsafeMutablePointer<UInt8>) {
        let s = scratch
        let live = (s.live[index], s.live[index + 1])
        if live.0 | live.1 == 0 { return }
        let zero = splat(0)
        let one = splat(1)
        let scene = UnsafeRawPointer(s.scene + index * 4)
        let firstRG = scene.loadUnaligned(as: Pair.self)
        let firstB = scene.loadUnaligned(fromByteOffset: 16, as: Pair.self)
        let secondRG = scene.loadUnaligned(fromByteOffset: 32, as: Pair.self)
        let secondB = scene.loadUnaligned(fromByteOffset: 48, as: Pair.self)
        let red = Pair(firstRG.x, secondRG.x)
        let green = Pair(firstRG.y, secondRG.y)
        let blue = Pair(firstB.x, secondB.x)
        let coverage = load(s.coverage, index)

        // `MercuryDisplayLookup.map(scene)`: luminance, bounded coordinate, table, ratio.
        let luminance = (splat(0.2126) * red + splat(0.7152) * green) + splat(0.0722) * blue
        let luminanceValid = (luminance .> zero) .& (luminance .< splat(.infinity))
        let unit = luminance / (luminance + splat(halfSaturation))
        let scaled = unit * splat(Double(Tables.lookupCount - 1))
        let lower = indexLanes(scaled, Tables.lookupCount - 1)
        let fraction = SIMD2<Float>(scaled - Pair(lower))
        @inline(always)
        func sample(_ lower: Int, _ fraction: Float) -> SIMD2<Float> {
            let low = lookupTable[lower]
            let high = lookupTable[Swift.min(lower + 1, Tables.lookupCount - 1)]
            return low + (high - low) * SIMD2<Float>(repeating: fraction)
        }
        let first = sample(Int(lower.x), fraction.x)
        let second = sample(Int(lower.y), fraction.y)
        let gain = Pair(SIMD2<Float>(first.y, second.y))
        let rawRed = red * gain
        let rawGreen = green * gain
        let rawBlue = blue * gain
        let smallest = swiftMin(rawRed, swiftMin(rawGreen, rawBlue))
        let largest = swiftMax(rawRed, swiftMax(rawGreen, rawBlue))
        let fast = luminanceValid .& ((smallest .>= zero) .& (largest .<= splat(ceiling)))
        let opaque = fast .& (coverage .>= one)

        // `encodedByte` on the opaque table, `Int(clamped * 16383 + 0.5)`.
        let last = splat(Double(Tables.opaqueTransferCount - 1))
        @inline(always)
        func opaqueIndex(_ value: Pair) -> SIMD2<Int64> {
            let clamped = swiftMin(swiftMax(value, zero), one)
            return indexLanes(clamped * last + splat(0.5), Tables.opaqueTransferCount - 1)
        }
        let redIndex = opaqueIndex(rawRed)
        let greenIndex = opaqueIndex(rawGreen)
        let blueIndex = opaqueIndex(rawBlue)
        for lane in 0..<2 {
            if (lane == 0 ? live.0 : live.1) == 0 { continue }
            let pixel = pixels + lane * 4
            let coverage = s.coverage[index + lane]
            if opaque[lane] {
                pixel[0] = opaqueBytes[Int(redIndex[lane])]
                pixel[1] = opaqueBytes[Int(greenIndex[lane])]
                pixel[2] = opaqueBytes[Int(blueIndex[lane])]
            } else {
                let values = s.scene + (index + lane) * 4
                let scene = SIMD3<Double>(values[0], values[1], values[2])
                let display = fast[lane] ? scene * gain[lane] : lookup.map(scene)
                pixel[0] = MercuryOptics.encodedByte(display.x, coverage: coverage)
                pixel[1] = MercuryOptics.encodedByte(display.y, coverage: coverage)
                pixel[2] = MercuryOptics.encodedByte(display.z, coverage: coverage)
            }
            pixel[3] = byte(coverage)
        }
    }

    /// One pixel of `MercuryRasterizer.render`'s inner loop, verbatim; leaves uncovered
    /// pixels alone. Cap columns and unpaired columns go through here whole.
    @inline(always)
    func shade(_ columnIndex: Int, row: Int, vertical: Double) {
        let column = columns[columnIndex]
        guard column.radius > 0 else { return }
        let horizontal = boundsMinX + (Double(columnIndex) + 0.5) * pixelSize
        let offset = vertical - column.center
        let distance =
            column.inSpan
            ? abs(offset)
            : (column.capOffset * column.capOffset + offset * offset).squareRoot()
        let signedDistance = column.radius - distance
        let (fieldX, fieldY) = MercuryField.gradient(
            column: column,
            vertical: offset,
            length: length
        )
        let fieldGradient = SIMD2<Double>(fieldX, fieldY)
        let gradientLength = (fieldGradient * fieldGradient).sum().squareRoot()
        guard gradientLength > 1e-9 else { return }
        let coverage = Swift.min(
            Swift.max(0.5 + signedDistance / (gradientLength * pixelSize), 0),
            1
        )
        guard coverage > 0 else { return }

        let crown = MercuryCrown.evaluate(
            field: signedDistance,
            radius: column.radius,
            aspect: MercuryMetrics.crownAspect,
            epsilon: epsilon
        )
        let radiusGradient =
            column.inSpan
            ? SIMD2<Double>(column.radiusSlope / length, 0)
            : .zero
        let crownGradient = crown.gradient(
            fieldGradient: fieldGradient,
            radiusGradient: radiusGradient
        )
        let normal = normalize(
            SIMD3(-crownGradient.x, -crownGradient.y, 1)
        )
        let view = MercuryOptics.viewDirection(
            horizontal: horizontal,
            vertical: vertical,
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
        let scene =
            SIMD3<Double>(
                Double(room.x), Double(room.y), Double(room.z)
            ) * MercuryOptics.fresnel(cosine: incidence)
        let display = lookup.map(scene)
        let index = (row * width + columnIndex) * 4
        bytes[index] = MercuryOptics.encodedByte(display.x, coverage: coverage)
        bytes[index + 1] = MercuryOptics.encodedByte(display.y, coverage: coverage)
        bytes[index + 2] = MercuryOptics.encodedByte(display.z, coverage: coverage)
        bytes[index + 3] = byte(coverage)
    }
}
