import Foundation
import VoiceCore

/// The generated room the mercury reflects.
///
/// Both worlds write into the same three prefiltered linear-RGB tables, so everything
/// downstream — interpolation, conductor Fresnel and display response — is one code
/// path. Both rooms are static after their seed draw; the mercury surface owns all
/// visible motion. Spectral Weather is the debug-only alternate room structure.
///
/// The tables are *x-polar* equirectangular on purpose. An ordinary z-polar
/// parameterization puts its pole exactly where a near-flat crest's reflected direction
/// lives. Rotating the poles onto the body's own long axis moves them to the two caps.
///
/// Neither world reads the desktop or contains an authored highlight path. Room colour is
/// low-saturation, seed-derived, luminance-neutral source variation.
@MainActor
final class MercuryEnvironment {
    private enum Core {
        case room(RoomOfTenWorld)
        case weather(SpectralWeatherWorld)
    }

    private(set) var world: MercuryWorld

    private var core: Core
    /// Three levels of `width * height` linear-RGB texels, contiguous. Raw storage avoids
    /// array bounds and retain traffic in the eight-tap per-pixel sampling path.
    private let tables: UnsafeMutablePointer<SIMD3<Float>>
    private let levelStride: Int
    /// Stored rather than recomputed: `deinit` is not main-actor isolated and may not
    /// read the isolated statics below.
    private let capacity: Int
    private var normalization: Float?

    private static let width = MercuryMetrics.environmentWidth
    private static let height = MercuryMetrics.environmentHeight
    private static let levels = MercuryMetrics.environmentRoughness.count

    init(world: MercuryWorld, seed: UInt64) {
        self.world = world
        levelStride = Self.width * Self.height
        capacity = levelStride * Self.levels
        tables = UnsafeMutablePointer<SIMD3<Float>>.allocate(capacity: capacity)
        tables.initialize(repeating: .zero, count: capacity)
        switch world {
        case .roomOfTen:
            core = .room(RoomOfTenWorld(seed: seed))
        case .spectralWeather:
            core = .weather(SpectralWeatherWorld(seed: seed))
        }
        bake()
    }

    deinit {
        tables.deinitialize(count: capacity)
        tables.deallocate()
    }

    /// Generated rooms are fixed after their seed draw. All visible production and debug
    /// motion belongs to the mercury surface, so an unchanged body has a byte-identical
    /// reflection indefinitely. The arguments remain explicit because the engine owns
    /// when a world would have advanced.
    func advance(steps: Int, frozen: Bool) {
        _ = steps
        _ = frozen
    }

    /// Prefiltered linear-RGB radiance for a reflected direction and roughness.
    func radiance(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
        let axial = Swift.min(Swift.max(direction.x, -1), 1)
        let polar = Foundation.acos(axial)
        let azimuth = Foundation.atan2(direction.z, direction.y)

        var column = (azimuth + .pi) / (2 * .pi) * Float(Self.width) - 0.5
        column = column.truncatingRemainder(dividingBy: Float(Self.width))
        if column < 0 { column += Float(Self.width) }
        let columnIndex = Int(column)
        let columnFraction = column - Float(columnIndex)
        let columnNext = (columnIndex + 1) % Self.width

        let rowRaw = polar / .pi * Float(Self.height) - 0.5
        let rowClamped = Swift.min(Swift.max(rowRaw, 0), Float(Self.height - 1))
        let rowIndex = Swift.min(Int(rowClamped), Self.height - 1)
        let rowFraction = rowClamped - Float(rowIndex)
        let rowNext = Swift.min(rowIndex + 1, Self.height - 1)

        let (lower, upper, blend) = Self.levelBlend(for: roughness)
        let first = sample(
            level: lower,
            columnIndex: columnIndex,
            columnNext: columnNext,
            columnFraction: columnFraction,
            rowIndex: rowIndex,
            rowNext: rowNext,
            rowFraction: rowFraction
        )
        guard blend > 0 else { return first }
        let second = sample(
            level: upper,
            columnIndex: columnIndex,
            columnNext: columnNext,
            columnFraction: columnFraction,
            rowIndex: rowIndex,
            rowNext: rowNext,
            rowFraction: rowFraction
        )
        return first + (second - first) * blend
    }

    @inline(__always)
    private func sample(
        level: Int,
        columnIndex: Int,
        columnNext: Int,
        columnFraction: Float,
        rowIndex: Int,
        rowNext: Int,
        rowFraction: Float
    ) -> SIMD3<Float> {
        let base = level * levelStride
        let topLeft = tables[base + rowIndex * Self.width + columnIndex]
        let topRight = tables[base + rowIndex * Self.width + columnNext]
        let bottomLeft = tables[base + rowNext * Self.width + columnIndex]
        let bottomRight = tables[base + rowNext * Self.width + columnNext]
        let top = topLeft + (topRight - topLeft) * columnFraction
        let bottom = bottomLeft + (bottomRight - bottomLeft) * columnFraction
        return top + (bottom - top) * rowFraction
    }

    private static func levelBlend(for roughness: Float) -> (Int, Int, Float) {
        let levels = MercuryMetrics.environmentRoughness
        if roughness <= levels[0] { return (0, 0, 0) }
        if roughness >= levels[levels.count - 1] { return (levels.count - 1, levels.count - 1, 0) }
        var index = 0
        while index < levels.count - 2, roughness > levels[index + 1] { index += 1 }
        let low = Foundation.log(levels[index])
        let high = Foundation.log(levels[index + 1])
        let blend = (Foundation.log(roughness) - low) / (high - low)
        return (index, index + 1, Swift.min(Swift.max(blend, 0), 1))
    }

    // MARK: - Baking

    private func bake() {
        for (level, roughness) in MercuryMetrics.environmentRoughness.enumerated() {
            let destination = tables + level * levelStride
            // Band-limited to the table's own grid as well as to the roughness. A texel
            // subtends 3.75 degrees; without this a lambda-4000 lobe lands inside one of
            // them and the "prefiltered radiance table" contract is simply false — the
            // stored value is an alias of wherever the lobe centre happened to fall.
            let grid = MercuryMetrics.environmentGridRoughness
            let effective = (Double(roughness) * Double(roughness) + grid * grid).squareRoot()
            switch core {
            case .room(let room):
                room.bake(into: destination, directions: Self.directions, roughness: effective)
            case .weather(let weather):
                weather.bake(into: destination, basis: Self.harmonicBasis, roughness: effective)
            }
        }
        equalizePower()
        applyNormalization()
    }

    /// Prefiltering conserves total power, enforced rather than assumed.
    ///
    /// The spherical-Gaussian convolution conserves it analytically, so the room is a
    /// no-op here. A lognormal field does not: `E[L]` is `L0` in expectation over
    /// realisations, but a *single* draw's mean drifts as its log is blurred, measured at
    /// up to 9.6 % between the sharpest and roughest level. A rougher patch of body must
    /// not be a darker one, so the levels are pinned to the sharpest one's mean.
    private func equalizePower() {
        let reference = weightedMean(level: 0)
        guard reference > 1e-12 else { return }
        for level in 1..<Self.levels {
            let mean = weightedMean(level: level)
            guard mean > 1e-12 else { continue }
            let scale = Float(reference / mean)
            let destination = tables + level * levelStride
            for index in 0..<levelStride {
                destination[index] *= scale
            }
        }
    }

    private func weightedMean(level: Int) -> Double {
        let base = level * levelStride
        var total = 0.0
        var weight = 0.0
        for row in 0..<Self.height {
            let polar = (Double(row) + 0.5) / Double(Self.height) * Double.pi
            let solidAngle = sin(polar)
            for column in 0..<Self.width {
                let value = tables[base + row * Self.width + column]
                total +=
                    (0.2126 * Double(value.x)
                        + 0.7152 * Double(value.y)
                        + 0.0722 * Double(value.z)) * solidAngle
                weight += solidAngle
            }
        }
        return weight > 0 ? total / weight : 0
    }
    /// One fixed scalar places the room in a sane numeric range. It is not exposure:
    /// `MercuryDisplayResponse` meters the body's own reflected samples with two anchors.
    /// The same scalar is applied to every prefiltered RGB level, preserving colour and
    /// roughness power.
    private func applyNormalization() {
        if normalization == nil {
            let mean = weightedMean(level: 0)
            normalization = mean > 1e-12 ? Float(1 / mean) : 1
        }
        guard let normalization, normalization != 1 else { return }
        for index in 0..<capacity {
            tables[index] *= normalization
        }
    }

    /// Unit direction of every texel centre, x-polar. Depends only on constants.
    private static let directions: [SIMD3<Float>] = {
        var result = [SIMD3<Float>]()
        result.reserveCapacity(width * height)
        for row in 0..<height {
            let polar = (Double(row) + 0.5) / Double(height) * Double.pi
            let axial = cos(polar)
            let radius = sin(polar)
            for column in 0..<width {
                let azimuth = (Double(column) + 0.5) / Double(width) * 2 * Double.pi - Double.pi
                result.append(
                    SIMD3<Float>(
                        Float(axial),
                        Float(radius * cos(azimuth)),
                        Float(radius * sin(azimuth))
                    )
                )
            }
        }
        return result
    }()

    /// The real spherical-harmonic basis at every texel, `l = 1...12`, row-major by
    /// texel. Roughly 3.1 MB, built once and only when Spectral Weather is selected.
    private static let harmonicBasis: [Float] = {
        let count = SpectralWeatherWorld.coefficientCount
        var result = [Float](repeating: 0, count: directions.count * count)
        var scratch = [Double](repeating: 0, count: count)
        for (index, direction) in directions.enumerated() {
            SpectralWeatherWorld.evaluateBasis(
                SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z)),
                into: &scratch
            )
            for coefficient in 0..<count {
                result[index * count + coefficient] = Float(scratch[coefficient])
            }
        }
        return result
    }()
}

// MARK: - Room of Ten

/// A static seed-drawn room: bounded spherical-Gaussian area sources over a neutral
/// bounce. The product name stays Room of Ten; the implementation uses enough source
/// samples to make every random room resolve as the same polished material.
@MainActor
final class RoomOfTenWorld {
    private struct Source {
        var sharpness: Double
        var intensity: Double
        var axis: SIMD3<Double>
        var chromaCoefficient: Double
        var tint: SIMD3<Double>
    }

    private let sources: [Source]

    /// The drawn sharpnesses, in draw order. The marginal is a declared contract.
    var sharpnesses: [Double] { sources.map(\.sharpness) }

    init(seed: UInt64) {
        let noise = MercuryNoise(seed: seed)
        let count = MercuryMetrics.roomLobeCount
        let logMinimum = log(MercuryMetrics.roomLambdaMin)
        let logMaximum = log(MercuryMetrics.roomLambdaMax)
        var sources: [Source] = []
        sources.reserveCapacity(count)
        for index in 0..<count {
            let counter = UInt64(index)
            let band = noise.uniform(
                stream: MercuryNoiseStream.roomLobes,
                counter: counter &* 3
            )
            let azimuthDraw = noise.uniform(
                stream: MercuryNoiseStream.roomLobes,
                counter: counter &* 3 &+ 1
            )
            let sharpnessDraw = noise.uniform(
                stream: MercuryNoiseStream.roomLobes,
                counter: counter &* 3 &+ 2
            )
            let height = -1 + 2 * (Double(index) + band) / Double(count)
            let radius = Swift.max(0, 1 - height * height).squareRoot()
            let azimuth = 2 * Double.pi * azimuthDraw
            let intensityDraw =
                2
                * noise.uniform(
                    stream: MercuryNoiseStream.roomIntensity,
                    counter: counter
                ) - 1
            let chromaDraw =
                2
                * noise.uniform(
                    stream: MercuryNoiseStream.roomChroma,
                    counter: counter
                ) - 1
            sources.append(
                Source(
                    sharpness: exp(
                        logMinimum + sharpnessDraw * (logMaximum - logMinimum)
                    ),
                    intensity: exp(MercuryMetrics.roomLogIntensityRange * intensityDraw),
                    axis: SIMD3(
                        radius * cos(azimuth),
                        radius * sin(azimuth),
                        height
                    ),
                    chromaCoefficient: chromaDraw,
                    tint: .one
                )
            )
        }

        let sourceMean = sources.reduce(0.0) { $0 + Self.power(of: $1) }
        let chromaMean =
            sources.reduce(0.0) {
                $0 + Self.power(of: $1) * $1.chromaCoefficient
            } / Swift.max(sourceMean, 1e-12)
        let maximumChroma = sources.reduce(0.0) {
            Swift.max($0, abs($1.chromaCoefficient - chromaMean))
        }
        let opponent = Self.opponent(noise: noise)
        let sourceShare = 1 - MercuryMetrics.roomBounceFraction
        self.sources = sources.map { source in
            let coefficient =
                (source.chromaCoefficient - chromaMean)
                / Swift.max(maximumChroma, 1e-12)
            return Source(
                sharpness: source.sharpness,
                intensity: source.intensity * sourceShare
                    / Swift.max(sourceMean, 1e-12),
                axis: source.axis,
                chromaCoefficient: coefficient,
                tint: SIMD3<Double>(repeating: 1)
                    + MercuryMetrics.roomChromaStrength * coefficient * opponent
            )
        }
    }

    func radiance(_ direction: SIMD3<Float>, roughness: Double) -> SIMD3<Float> {
        let vector = SIMD3<Double>(
            Double(direction.x), Double(direction.y), Double(direction.z)
        )
        var value = SIMD3<Double>(repeating: MercuryMetrics.roomBounceFraction)
        for source in sources {
            let filtered =
                source.sharpness
                / (1 + source.sharpness * roughness * roughness)
            let powerScale =
                (filtered / source.sharpness)
                * (1 - exp(-2 * source.sharpness))
                / Swift.max(1 - exp(-2 * filtered), 1e-12)
            let contribution =
                source.intensity * powerScale
                * exp(filtered * ((vector * source.axis).sum() - 1))
            value += contribution * source.tint
        }
        return SIMD3<Float>(
            Float(Swift.max(value.x, Double.leastNonzeroMagnitude)),
            Float(Swift.max(value.y, Double.leastNonzeroMagnitude)),
            Float(Swift.max(value.z, Double.leastNonzeroMagnitude))
        )
    }

    /// Exact spherical-Gaussian convolution with finite-sphere power preservation.
    func bake(
        into destination: UnsafeMutablePointer<SIMD3<Float>>,
        directions: [SIMD3<Float>],
        roughness: Double
    ) {
        for index in directions.indices {
            destination[index] = radiance(directions[index], roughness: roughness)
        }
    }

    private static func power(of source: Source) -> Double {
        source.intensity * (1 - exp(-2 * source.sharpness))
            / (2 * source.sharpness)
    }

    /// Seed-random opponent projected onto the Rec.709 luminance-null plane.
    private static func opponent(noise: MercuryNoise) -> SIMD3<Double> {
        let random = noise.unitVector(
            stream: MercuryNoiseStream.roomChroma,
            counter: 10_000
        )
        let luminance = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        let projected =
            random
            - luminance * ((random * luminance).sum() / (luminance * luminance).sum())
        let scale = Swift.max(
            abs(projected.x), Swift.max(abs(projected.y), abs(projected.z))
        )
        return projected / Swift.max(scale, 1e-12)
    }
}

// MARK: - Spectral Weather

/// A lognormal spherical-harmonic field whose every degree relaxes on its own exact
/// Ornstein-Uhlenbeck transition.
///
/// `a00` is identically zero, so the field carries no mean term of its own and the mean
/// radiance is exactly the constant the exposure solve pins. The radiance is
/// `L0 * exp(g - var(g) / 2)`, which is strictly positive and has mean `L0` at every
/// roughness — the variance correction is per level, because blurring a log field lowers
/// its variance and an uncorrected exponential would brighten as it got smoother.
@MainActor
final class SpectralWeatherWorld {
    static let maxDegree = MercuryMetrics.weatherMaxDegree
    /// `sum over l = 1...L of (2l + 1)`.
    static let coefficientCount = (maxDegree + 1) * (maxDegree + 1) - 1

    private let coefficients: [Double]
    /// Declared power spectrum, one entry per coefficient.
    private let power: [Double]
    private let degrees: [Int]

    init(seed: UInt64) {
        let generator = MercuryNoise(seed: seed)
        var degrees = [Int]()
        degrees.reserveCapacity(Self.coefficientCount)
        for degree in 1...Self.maxDegree {
            for _ in -degree...degree {
                degrees.append(degree)
            }
        }
        self.degrees = degrees

        // `A` is solved so the pointwise variance is exactly `sigma^2`: by the addition
        // theorem the variance of an isotropic field is `sum_l C_l (2l + 1) / (4 pi)`.
        var shape = 0.0
        for degree in 1...Self.maxDegree {
            shape += Self.spectrum(degree: degree) * Double(2 * degree + 1) / (4 * Double.pi)
        }
        let amplitude = MercuryMetrics.weatherSigma * MercuryMetrics.weatherSigma / shape
        let spectrum = degrees.map { amplitude * Self.spectrum(degree: $0) }
        power = spectrum

        // Draw once on the stationary measure, then keep the generated room fixed.
        coefficients = (0..<Self.coefficientCount).map { index in
            let draw = generator.gaussianPair(
                stream: MercuryNoiseStream.weatherCoefficients,
                counter: UInt64(index)
            )
            return spectrum[index].squareRoot() * draw.x
        }
    }

    /// The declared power spectrum shape, `(kappa^2 + l(l + 1))^-s`.
    private static func spectrum(degree: Int) -> Double {
        pow(
            MercuryMetrics.weatherKappaSquared + Double(degree * (degree + 1)),
            -MercuryMetrics.weatherSlope
        )
    }

    /// Prefiltering is exact multiplication by the spherical heat semigroup
    /// `T_l = exp(-l (l + 1) alpha^2 / 4)`, so the three levels are three coefficient
    /// vectors against one basis and each bake is a matrix-vector product.
    func bake(
        into destination: UnsafeMutablePointer<SIMD3<Float>>,
        basis: [Float],
        roughness: Double
    ) {
        let count = Self.coefficientCount
        var filtered = [Float](repeating: 0, count: count)
        var variance = 0.0
        for index in 0..<count {
            let degree = Double(degrees[index])
            let transfer = Foundation.exp(-degree * (degree + 1) * roughness * roughness / 4)
            filtered[index] = Float(coefficients[index] * transfer)
            variance += power[index] * transfer * transfer
        }
        // `variance` above sums the per-coefficient contributions, which by the addition
        // theorem is `4 pi` times the pointwise variance of the blurred field.
        let offset = Float(variance / (4 * Double.pi) / 2)

        let texels = basis.count / count
        basis.withUnsafeBufferPointer { rows in
            filtered.withUnsafeBufferPointer { weights in
                for texel in 0..<texels {
                    var total: Float = 0
                    let base = texel * count
                    for index in 0..<count {
                        total += rows[base + index] * weights[index]
                    }
                    destination[texel] = SIMD3<Float>(
                        repeating: Foundation.exp(total - offset)
                    )
                }
            }
        }
    }

    /// Real spherical harmonics for `l = 1...maxDegree`, in the same order as
    /// ``coefficientCount`` enumerates them.
    static func evaluateBasis(_ direction: SIMD3<Double>, into result: inout [Double]) {
        let axial = Swift.min(Swift.max(direction.z, -1), 1)
        let azimuth = atan2(direction.y, direction.x)
        var cursor = 0
        for degree in 1...maxDegree {
            for order in -degree...degree {
                let magnitude = abs(order)
                let legendre = associatedLegendre(degree: degree, order: magnitude, argument: axial)
                let scale = normalization(degree: degree, order: magnitude)
                if order == 0 {
                    result[cursor] = scale * legendre
                } else if order > 0 {
                    result[cursor] = 2.0.squareRoot() * scale * cos(Double(order) * azimuth) * legendre
                } else {
                    result[cursor] = 2.0.squareRoot() * scale * sin(Double(magnitude) * azimuth) * legendre
                }
                cursor += 1
            }
        }
    }

    private static func normalization(degree: Int, order: Int) -> Double {
        var ratio = 1.0
        if order > 0 {
            for step in (degree - order + 1)...(degree + order) {
                ratio /= Double(step)
            }
        }
        return (Double(2 * degree + 1) / (4 * Double.pi) * ratio).squareRoot()
    }

    private static func associatedLegendre(degree: Int, order: Int, argument: Double) -> Double {
        var current = 1.0
        if order > 0 {
            let offAxis = Swift.max(0, (1 - argument) * (1 + argument)).squareRoot()
            var factor = 1.0
            for _ in 1...order {
                current *= -factor * offAxis
                factor += 2
            }
        }
        if degree == order { return current }
        var next = argument * Double(2 * order + 1) * current
        if degree == order + 1 { return next }
        for level in (order + 2)...degree {
            let value =
                (Double(2 * level - 1) * argument * next - Double(level + order - 1) * current)
                / Double(level - order)
            current = next
            next = value
        }
        return next
    }
}
