import Foundation

/// Process-built optical transfer tables. Their source functions remain here as the
/// numerical oracle; dense tests bound every lookup before the rasterizer uses it.
enum MercuryOptics {
    private static let fresnelMinimum = 1e-4
    private static let fresnelCount = 1_024
    private static let transferCount = 4_096
    private static let opaqueTransferCount = 16_384

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

    static func exactFresnel(cosine: Double) -> SIMD3<Double> {
        let cosineSquared = cosine * cosine
        let sineSquared = Swift.max(0, 1 - cosineSquared)
        let refraction = SIMD3(
            MercuryMetrics.mercuryN.r,
            MercuryMetrics.mercuryN.g,
            MercuryMetrics.mercuryN.b
        )
        let extinction = SIMD3(
            MercuryMetrics.mercuryK.r,
            MercuryMetrics.mercuryK.g,
            MercuryMetrics.mercuryK.b
        )
        let base =
            refraction * refraction
            - extinction * extinction
            - SIMD3<Double>(repeating: sineSquared)
        let squares = SIMD3(
            (base.x * base.x + 4 * refraction.x * refraction.x * extinction.x * extinction.x)
                .squareRoot(),
            (base.y * base.y + 4 * refraction.y * refraction.y * extinction.y * extinction.y)
                .squareRoot(),
            (base.z * base.z + 4 * refraction.z * refraction.z * extinction.z * extinction.z)
                .squareRoot()
        )
        let real = SIMD3(
            Swift.max(0, (squares.x + base.x) / 2).squareRoot(),
            Swift.max(0, (squares.y + base.y) / 2).squareRoot(),
            Swift.max(0, (squares.z + base.z) / 2).squareRoot()
        )
        let first = squares + SIMD3<Double>(repeating: cosineSquared)
        let second = 2 * real * cosine
        let perpendicular = (first - second) / (first + second)
        let third =
            cosineSquared * squares
            + SIMD3<Double>(repeating: sineSquared * sineSquared)
        let fourth = second * sineSquared
        let parallel = perpendicular * (third - fourth) / (third + fourth)
        return (perpendicular + parallel) / 2
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

    /// Binomial normalization around the finite eye axis. Across the complete island
    /// `q = (x² + y²) / depth² < 0.0044`; retaining the cubic term bounds the omitted
    /// direction error below 1e-8 while replacing one square root and three divides with
    /// one scalar divide.
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
