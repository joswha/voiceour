import Foundation

/// Process-built optical transfer tables. Their source functions remain here as the
/// numerical oracle; dense tests bound every lookup before the rasterizer uses it.
///
/// Liquid mercury's own reflectance table is the stock paint's, `MercuryPaintLookup.stock`:
/// the one table of its kind, which ``fresnel(cosine:)`` reads.
enum MercuryOptics {
    private static let transferCount = 4_096
    private static let opaqueTransferCount = 16_384

    /// The two transfer tables a pixel's colour bytes read, built once on first use and never
    /// written again.
    ///
    /// Raw storage, as the room's texels are: a pixel makes up to six reads here, and an
    /// array would check its bounds and a lazy global its initializer on every one. The
    /// rasterizer takes ``tables`` once per frame and reads through it; every other reader
    /// goes through `MercuryOptics`'s static functions, which read the same value.
    ///
    /// `@unchecked Sendable`: the storage is filled before the value exists and is never
    /// written or freed after, so every thread reads the same immutable bytes.
    struct Tables: @unchecked Sendable {
        private let transferTable: UnsafePointer<Float>
        private let opaqueTransferTable: UnsafePointer<UInt8>

        fileprivate init() {
            transferTable = Self.tabulate(count: transferCount) { index in
                Float(exactEncodeSRGB(Double(index) / Double(transferCount - 1)))
            }
            opaqueTransferTable = Self.tabulate(count: opaqueTransferCount) { index in
                let encoded = exactEncodeSRGB(Double(index) / Double(opaqueTransferCount - 1))
                return UInt8(Swift.min(255, Swift.max(0, Int(encoded * 255 + 0.5))))
            }
        }

        /// `entry(i)` for every `i` in `0..<count`, in storage the process keeps.
        private static func tabulate<Entry>(count: Int, _ entry: (Int) -> Entry) -> UnsafePointer<Entry> {
            let storage = UnsafeMutablePointer<Entry>.allocate(capacity: count)
            for index in 0..<count {
                (storage + index).initialize(to: entry(index))
            }
            return UnsafePointer(storage)
        }

        @inline(__always)
        func encodeSRGB(_ value: Double) -> Double {
            let clamped = Swift.min(Swift.max(value, 0), 1)
            let scaled = clamped * Double(transferCount - 1)
            let lower = Int(scaled)
            let upper = Swift.min(lower + 1, transferCount - 1)
            let fraction = Float(scaled - Double(lower))
            return Double(
                transferTable[lower]
                    + (transferTable[upper] - transferTable[lower]) * fraction
            )
        }

        @inline(__always)
        func encodedByte(_ value: Double, coverage: Double) -> UInt8 {
            let clamped = Swift.min(Swift.max(value, 0), 1)
            if coverage >= 1 {
                let index = Int(clamped * Double(opaqueTransferCount - 1) + 0.5)
                return opaqueTransferTable[index]
            }
            let encoded = encodeSRGB(clamped) * coverage
            return UInt8(Swift.min(255, Swift.max(0, Int(encoded * 255 + 0.5))))
        }
    }

    /// The tables, built on first use.
    static let tables = Tables()

    /// Liquid mercury's conductor response: one lerp of the stock paint's table.
    @inline(__always)
    static func fresnel(cosine: Double) -> SIMD3<Double> {
        MercuryPaintLookup.stock.fresnel(cosine: cosine)
    }

    /// The stock look's conductor oracle, which `MercuryPaintLookup.stock` tabulates and is
    /// tested against: mercury's exact Fresnel reflectance integrated over the CIE observer
    /// under D65, in linear sRGB (`MercurySpectral`). The clamp at 0 is the gamut boundary,
    /// since the XYZ → sRGB matrix has negative lobes and an arbitrary physical spectrum can
    /// land outside it. It never binds for mercury, whose channels stay above 0.70 at every
    /// cosine.
    static func exactFresnel(cosine: Double) -> SIMD3<Double> {
        pointwiseMax(MercurySpectral.linearSRGBReflectance(cosine: cosine), .zero)
    }

    @inline(__always)
    static func encodeSRGB(_ value: Double) -> Double {
        tables.encodeSRGB(value)
    }

    @inline(__always)
    static func encodedByte(_ value: Double, coverage: Double) -> UInt8 {
        tables.encodedByte(value, coverage: coverage)
    }

    static func exactViewDirection(
        horizontal: Double,
        vertical: Double,
        crownHeight: Double
    ) -> SIMD3<Double> {
        let value = SIMD3(
            -horizontal,
            -vertical,
            MercuryMetrics.eyeDistance - crownHeight
        )
        return value * (1 / (value * value).sum().squareRoot())
    }

    /// Binomial normalization around the finite eye axis, with `q = (x² + y²) / depth²`.
    /// The series alternates, so its first omitted term, `35q⁴/128`, bounds the direction
    /// error. Across the island's 196×34 pt canvas `q < 0.0052` and the error is about 2e-10;
    /// across the widest collar canvas, 349×65 pt under the tallest crown its 24 pt ceiling
    /// allows at the roundest aspect a look can choose, 1.0, `q < 0.0167` and it is 2.1e-8.
    /// Retaining the cubic term replaces one square root and three divides with one scalar
    /// divide.
    @inline(__always)
    static func viewDirection(
        horizontal: Double,
        vertical: Double,
        crownHeight: Double
    ) -> SIMD3<Double> {
        let inverseDepth = 1 / (MercuryMetrics.eyeDistance - crownHeight)
        let horizontalUnit = -horizontal * inverseDepth
        let verticalUnit = -vertical * inverseDepth
        let squaredOffset =
            horizontalUnit * horizontalUnit + verticalUnit * verticalUnit
        let normalization =
            1
            + squaredOffset
            * (-0.5 + squaredOffset * (0.375 - 0.3125 * squaredOffset))
        return SIMD3(
            horizontalUnit * normalization,
            verticalUnit * normalization,
            normalization
        )
    }

    static func exactEncodeSRGB(_ value: Double) -> Double {
        let clamped = Swift.min(Swift.max(value, 0), 1)
        return clamped <= 0.003_130_8
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

/// One display response compiled into the bounded coordinate
/// `u = scene / (scene + halfSaturation)`. The finite scene domain maps to `[0, 1)`,
/// so every per-pixel logarithm and exponential becomes one divide and one lerp.
final class MercuryDisplayLookup {
    private static let count = 2_048

    let response: MercuryDisplayResponse
    /// Raw storage, as the room's texels are: every covered pixel reads two entries, and an
    /// array would check bounds and hold a reference on each.
    private let table: UnsafeMutablePointer<SIMD2<Float>>

    init(response: MercuryDisplayResponse) {
        self.response = response
        table = UnsafeMutablePointer<SIMD2<Float>>.allocate(capacity: Self.count)
        for index in 0..<Self.count {
            (table + index).initialize(to: Self.entry(index, of: response))
        }
    }

    deinit {
        table.deallocate()
    }

    private static func entry(_ index: Int, of response: MercuryDisplayResponse) -> SIMD2<Float> {
        guard index > 0 else { return .zero }
        guard index < count - 1 else {
            return SIMD2(Float(response.ceiling.nextDown), 0)
        }
        let unit = Double(index) / Double(count - 1)
        let scene = response.halfSaturation * unit / (1 - unit)
        let mapped = response.map(scene)
        return SIMD2(Float(mapped), Float(mapped / scene))
    }

    @inline(__always)
    func map(_ sceneLuminance: Double) -> Double {
        sample(sceneLuminance).x
    }

    @inline(__always)
    private func sample(_ sceneLuminance: Double) -> SIMD2<Double> {
        guard sceneLuminance > 0 else { return .zero }
        guard sceneLuminance.isFinite else {
            return SIMD2(response.ceiling.nextDown, 0)
        }
        let unit = sceneLuminance / (sceneLuminance + response.halfSaturation)
        let scaled = unit * Double(Self.count - 1)
        let lower = Swift.min(Int(scaled), Self.count - 1)
        let upper = Swift.min(lower + 1, Self.count - 1)
        let fraction = Float(scaled - Double(lower))
        let value = table[lower] + (table[upper] - table[lower]) * fraction
        return SIMD2(Double(value.x), Double(value.y))
    }

    @inline(__always)
    func map(_ scene: SIMD3<Double>) -> SIMD3<Double> {
        let sceneLuminance = MercuryDisplayResponse.luminance(scene)
        guard sceneLuminance > 0, sceneLuminance.isFinite else { return .zero }
        let responseSample = sample(sceneLuminance)
        let mappedLuminance = responseSample.x
        let raw = scene * responseSample.y
        if Swift.min(raw.x, Swift.min(raw.y, raw.z)) >= 0,
            Swift.max(raw.x, Swift.max(raw.y, raw.z)) <= response.ceiling
        {
            return raw
        }
        return desaturated(raw, toward: mappedLuminance)
    }

    /// `raw` pulled toward its neutral `mappedLuminance` until every channel lies within
    /// `0…ceiling`. Kept out of line: almost no pixel leaves the gamut, and inlined, this would
    /// weigh on every pixel's path through ``map(_:)-(SIMD3<Double>)``.
    @inline(never)
    private func desaturated(_ raw: SIMD3<Double>, toward mappedLuminance: Double) -> SIMD3<Double> {
        let neutral = SIMD3<Double>(repeating: mappedLuminance)
        let difference = raw - neutral
        let upper = response.ceiling - mappedLuminance

        @inline(__always)
        func limit(_ delta: Double) -> Double {
            if delta > 0 { return upper / delta }
            if delta < 0 { return mappedLuminance / -delta }
            return 1
        }

        let amount = Swift.max(
            0,
            Swift.min(
                Swift.min(1, limit(difference.x)),
                Swift.min(limit(difference.y), limit(difference.z))
            )
        )
        return neutral + amount * difference
    }
}
