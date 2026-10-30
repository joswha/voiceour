import Foundation

/// Process-built optical transfer tables. Their source functions remain here as the
/// numerical oracle; dense tests bound every lookup before the rasterizer uses it.
enum MercuryOptics {
    private static let fresnelMinimum = 1e-4
    private static let fresnelCount = 1_024
    private static let transferCount = 4_096
    private static let opaqueTransferCount = 16_384

    /// Mercury's conductor response over `μ ∈ [1e-4, 1]`, built once on first use from the
    /// spectral oracle: 1,024 × 81 exact Fresnel evaluations, about a millisecond in a release
    /// build. A pixel still pays one lerp.
    private static let fresnelTable: [SIMD3<Float>] = (0..<fresnelCount).map { index in
        let cosine =
            fresnelMinimum
            + (1 - fresnelMinimum) * Double(index) / Double(fresnelCount - 1)
        let value = exactFresnel(cosine: cosine)
        return SIMD3(Float(value.x), Float(value.y), Float(value.z))
    }

    private static let transferTable: [Float] = (0..<transferCount).map { index in
        Float(exactEncodeSRGB(Double(index) / Double(transferCount - 1)))
    }

    private static let opaqueTransferTable: [UInt8] = (0..<opaqueTransferCount).map { index in
        let encoded = exactEncodeSRGB(Double(index) / Double(opaqueTransferCount - 1))
        return UInt8(Swift.min(255, Swift.max(0, Int(encoded * 255 + 0.5))))
    }

    @inline(__always)
    static func fresnel(cosine: Double) -> SIMD3<Double> {
        let clamped = Swift.min(Swift.max(cosine, fresnelMinimum), 1)
        let scaled =
            (clamped - fresnelMinimum)
            * Double(fresnelCount - 1)
            / (1 - fresnelMinimum)
        let lower = Int(scaled)
        let upper = Swift.min(lower + 1, fresnelCount - 1)
        let fraction = Float(scaled - Double(lower))
        let value = fresnelTable[lower] + (fresnelTable[upper] - fresnelTable[lower]) * fraction
        return SIMD3(Double(value.x), Double(value.y), Double(value.z))
    }

    /// The conductor oracle the table is built from and tested against: mercury's exact
    /// Fresnel reflectance integrated over the CIE observer under D65, in linear sRGB
    /// (`MercurySpectral`). The clamp at 0 is the gamut boundary, since the XYZ → sRGB matrix
    /// has negative lobes and an arbitrary physical spectrum can land outside it. It never
    /// binds for mercury, whose channels stay above 0.70 at every cosine.
    static func exactFresnel(cosine: Double) -> SIMD3<Double> {
        pointwiseMax(MercurySpectral.linearSRGBReflectance(cosine: cosine), .zero)
    }

    @inline(__always)
    static func encodeSRGB(_ value: Double) -> Double {
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
    static func encodedByte(_ value: Double, coverage: Double) -> UInt8 {
        let clamped = Swift.min(Swift.max(value, 0), 1)
        if coverage >= 1 {
            let index = Int(clamped * Double(opaqueTransferCount - 1) + 0.5)
            return opaqueTransferTable[index]
        }
        let encoded = encodeSRGB(clamped) * coverage
        return UInt8(Swift.min(255, Swift.max(0, Int(encoded * 255 + 0.5))))
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
    /// across the widest collar canvas, 349×58 pt, `q < 0.0163` and it is 1.9e-8. Retaining
    /// the cubic term replaces one square root and three divides with one scalar divide.
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
    private let table: [SIMD2<Float>]

    init(response: MercuryDisplayResponse) {
        self.response = response
        table = (0..<Self.count).map { index in
            guard index > 0 else { return .zero }
            guard index < Self.count - 1 else {
                return SIMD2(Float(response.ceiling.nextDown), 0)
            }
            let unit = Double(index) / Double(Self.count - 1)
            let scene = response.halfSaturation * unit / (1 - unit)
            let mapped = response.map(scene)
            return SIMD2(Float(mapped), Float(mapped / scene))
        }
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
