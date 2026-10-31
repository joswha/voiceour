import Foundation
import VoiceCore

/// Octahedral sphere chart with no per-sample trigonometry.
///
/// The map is continuous across its internal folds. `MercuryEnvironment` bakes one
/// analytic texel beyond every edge, supplying the square's spherical identification
/// while the runtime remains one ordinary bilinear lookup.
enum MercuryOctahedralMap {
    @inline(__always)
    static func encode(_ direction: SIMD3<Float>) -> SIMD2<Float> {
        let denominator =
            abs(direction.x) + abs(direction.y) + abs(direction.z)
        guard denominator > 1e-12 else { return .zero }
        let projected = direction / denominator
        guard projected.z < 0 else { return SIMD2(projected.x, projected.y) }
        return SIMD2(
            (1 - abs(projected.y)) * signNotZero(projected.x),
            (1 - abs(projected.x)) * signNotZero(projected.y)
        )
    }

    @inline(__always)
    static func decode(_ point: SIMD2<Float>) -> SIMD3<Float> {
        var direction = SIMD3(
            point.x,
            point.y,
            1 - abs(point.x) - abs(point.y)
        )
        let fold = Swift.max(-direction.z, 0)
        direction.x += direction.x >= 0 ? -fold : fold
        direction.y += direction.y >= 0 ? -fold : fold
        let length = (direction * direction).sum().squareRoot()
        return length > 1e-12 ? direction / length : SIMD3(0, 0, 1)
    }

    @inline(__always)
    private static func signNotZero(_ value: Float) -> Float {
        value < 0 ? -1 : 1
    }
}

/// A coloured light below the island: one static spherical Gaussian in the room.
///
/// It is light the mercury reflects, not paint on the body, so it follows every ripple
/// exactly as the rest of the room does and falls away where the body faces up.
struct MercuryUnderglow: Equatable, Sendable {
    /// Linear Rec.709 colour at Rec.709 luminance 1, so `strength` alone sets the power
    /// and every hue at one strength is equally bright.
    var color: SIMD3<Double>
    /// `0...1`. The lobe peaks at `peak * strength` normalized room means.
    var strength: Double

    /// Below the island and tilted toward the viewer, `(0, -sin 65°, cos 65°)`. Its
    /// reflection centres on the lower half of the crown, which reads as lit from below;
    /// a steeper axis lit only the bottom edge, which reads as an authored rim.
    static let axis = SIMD3<Double>(0, -0.906308, 0.422618)
    /// Half brightness 34° off axis: a broad fill, never a hotspot.
    static let sharpness: Double = 4
    /// Full-strength peak in normalized room means. Room of Ten lamps peak at 1.3–6.7
    /// room means, so even full strength stays a fill: the sphere mean gains
    /// `peak * strength * (1 - e^-8) / 8`, at most ten percent.
    static let peak: Double = 0.8
}

/// Everything a look changes about the light the mercury reflects, all applied once at
/// bake time so per-pixel sampling never changes.
///
/// `stock` is the shipped room byte for byte: each option is either skipped or fed
/// exactly the values the room was baked with before these options existed.
struct MercuryRoomLighting: Equatable, Sendable {
    /// Material roughness of the smooth level; ``levelRoughness`` clamps it into the table
    /// range `0.03...0.25`. The stock liquid is `0.03`.
    var finish: Float
    /// Linear-RGB room multipliers with Rec.709 luminance 1; nil is the stock room.
    var whiteBalance: SIMD3<Double>?
    /// The coloured fill below the island; nil is off.
    var underglow: MercuryUnderglow?

    static let stock = MercuryRoomLighting(
        finish: MercuryMetrics.environmentRoughness[0],
        whiteBalance: nil,
        underglow: nil
    )

    /// The roughness each prefiltered level represents, ascending. For the clamped finish
    /// `r` it is `[r, max(r, 0.09), max(r, 0.25)]`, the shipped layout at the stock
    /// finish: the finish replaces the smooth level and floors the rougher two, so no
    /// level is smoother than the material.
    var levelRoughness: [Float] {
        let shipped = MercuryMetrics.environmentRoughness
        let clamped = Swift.min(Swift.max(finish, shipped[0]), shipped[shipped.count - 1])
        return shipped.map { Swift.max(clamped, $0) }
    }
}

/// The generated room the mercury reflects.
///
/// Both worlds write into the same prefiltered linear-RGB octahedral tables, so
/// interpolation, conductor Fresnel and display response remain one code path. Both
/// rooms are static after their seed draw; the mercury surface owns all visible motion.
/// Neither world reads the desktop or contains an authored highlight path. Stock room
/// colour is low-saturation, seed-derived, luminance-neutral source variation; a look's
/// ``MercuryRoomLighting`` re-tints, roughens or adds light at bake time only.
@MainActor
final class MercuryEnvironment {
    private enum Core {
        case room(RoomOfTenWorld)
        case weather(SpectralWeatherWorld)
    }

    private(set) var world: MercuryWorld
    /// Kept verbatim, an out-of-range finish included, so a caller can compare it with
    /// the lighting it wants without rebaking.
    let lighting: MercuryRoomLighting
    /// `lighting.levelRoughness`, resolved once for the bake and the level search.
    private let levelRoughness: [Float]

    private var core: Core
    /// Three bordered octahedral linear-RGB levels. Raw storage avoids array bounds and
    /// retain traffic in the four-tap per-pixel sampling path.
    private let tables: UnsafeMutablePointer<SIMD3<Float>>
    private let levelStride: Int
    private let capacity: Int
    private var normalization: Float?

    private static let resolution = MercuryMetrics.environmentResolution
    private static let storageResolution = resolution + 2
    private static let levels = MercuryMetrics.environmentRoughness.count

    init(world: MercuryWorld, seed: UInt64, lighting: MercuryRoomLighting = .stock) {
        self.world = world
        self.lighting = lighting
        levelRoughness = lighting.levelRoughness
        levelStride = Self.storageResolution * Self.storageResolution
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

    isolated deinit {
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

    /// Production's fixed smooth-mercury level. Separate so the raster hot path never
    /// performs a roughness search that can only return level zero.
    @inline(__always)
    func radiance(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        sample(level: 0, direction: direction)
    }

    /// Prefiltered linear-RGB radiance for tests and the debug roughness levels, blended
    /// across ``MercuryRoomLighting/levelRoughness`` of this room's lighting.
    func radiance(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
        let (lower, upper, blend) = levelBlend(for: roughness)
        let first = sample(level: lower, direction: direction)
        guard blend > 0 else { return first }
        let second = sample(level: upper, direction: direction)
        return first + (second - first) * blend
    }

    @inline(__always)
    private func sample(level: Int, direction: SIMD3<Float>) -> SIMD3<Float> {
        let point = MercuryOctahedralMap.encode(direction)
        let coordinate =
            (point + SIMD2<Float>(repeating: 1))
            * (0.5 * Float(Self.resolution))
            + SIMD2<Float>(repeating: 0.5)
        let column = Swift.min(Swift.max(Int(coordinate.x), 0), Self.resolution)
        let row = Swift.min(Swift.max(Int(coordinate.y), 0), Self.resolution)
        let columnFraction = coordinate.x - Float(column)
        let rowFraction = coordinate.y - Float(row)
        let stride = Self.storageResolution
        let base = level * levelStride + row * stride + column
        let topLeft = tables[base]
        let topRight = tables[base + 1]
        let bottomLeft = tables[base + stride]
        let bottomRight = tables[base + stride + 1]
        let top = topLeft + (topRight - topLeft) * columnFraction
        let bottom = bottomLeft + (bottomRight - bottomLeft) * columnFraction
        return top + (bottom - top) * rowFraction
    }

    /// Equal neighbouring levels, which a rough finish produces, are safe: past the end
    /// branches the search only stops on a pair that strictly brackets the roughness, so
    /// the log interval is never empty.
    private func levelBlend(for roughness: Float) -> (Int, Int, Float) {
        let levels = levelRoughness
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
        var effectiveRoughness: [Double] = []
        effectiveRoughness.reserveCapacity(Self.levels)
        for (level, roughness) in levelRoughness.enumerated() {
            let destination = tables + level * levelStride
            // The octahedral grid is finer than the fixed 0.019 band limit even at its
            // widest corner footprint. Adding that footprint in quadrature keeps every
            // generated lobe band-limited before any bilinear sampling occurs.
            let grid = MercuryMetrics.environmentGridRoughness
            let effective = (Double(roughness) * Double(roughness) + grid * grid).squareRoot()
            effectiveRoughness.append(effective)
            switch core {
            case .room(let room):
                room.bake(into: destination, directions: Self.directions, roughness: effective)
            case .weather(let weather):
                weather.bake(
                    into: destination,
                    basis: Self.harmonicBasis,
                    roughness: Self.weatherRoughness(roughness, level: level, effective: effective)
                )
            }
        }
        if let whiteBalance = lighting.whiteBalance {
            applyWhiteBalance(whiteBalance)
        }
        equalizePower()
        applyNormalization()
        if let underglow = lighting.underglow, underglow.strength > 0 {
            addUnderglow(underglow, effectiveRoughness: effectiveRoughness)
        }
    }

    /// Spectral Weather prefilters with the spherical heat semigroup at time `α²/4`; a
    /// Room of Ten lobe widened by the same `α` is close to time `α²/2`, twice the blur.
    /// Each stock level keeps its accepted blur, and a finish rougher than that level's
    /// stock value adds its extra variance at the Room of Ten rate,
    /// `ρ² = α_s² + 2(α² − α_s²)`, so one finish reads about equally rough in both rooms.
    private static func weatherRoughness(
        _ roughness: Float,
        level: Int,
        effective: Double
    ) -> Double {
        let stock = MercuryMetrics.environmentRoughness[level]
        guard roughness != stock else { return effective }
        let grid = MercuryMetrics.environmentGridRoughness
        let stockSquared = Double(stock) * Double(stock) + grid * grid
        return (stockSquared + 2 * (effective * effective - stockSquared)).squareRoot()
    }

    /// Colour temperature is a room multiplier, applied before the power and
    /// normalization passes so it re-tints the light without re-exposing it:
    /// normalization restores the same mean luminance afterwards. Against spectral
    /// relighting the RGB product is off by at most 0.043, for gold at the warm limit.
    private func applyWhiteBalance(_ multipliers: SIMD3<Double>) {
        let scale = SIMD3<Float>(
            Float(multipliers.x), Float(multipliers.y), Float(multipliers.z)
        )
        for index in 0..<capacity {
            tables[index] *= scale
        }
    }

    /// The underglow joins after normalization, so the room's own scalar, and with it
    /// every stock texel, never sees it, and its peak is the same fraction of the room
    /// mean in every room. Each level prefilters it exactly like a Room of Ten source:
    /// the sharpness widens to `λ / (1 + λα²)` and the finite-sphere power scale keeps
    /// its power, so every level gains the same mean. It is its own light source, so the
    /// white balance never tints it.
    private func addUnderglow(_ underglow: MercuryUnderglow, effectiveRoughness: [Double]) {
        let sharpness = MercuryUnderglow.sharpness
        let axis = MercuryUnderglow.axis
        let peak = MercuryUnderglow.peak * underglow.strength
        for (level, roughness) in effectiveRoughness.enumerated() {
            let filtered = sharpness / (1 + sharpness * roughness * roughness)
            let powerScale =
                (filtered / sharpness)
                * (1 - exp(-2 * sharpness))
                / Swift.max(1 - exp(-2 * filtered), 1e-12)
            let destination = tables + level * levelStride
            for (index, direction) in Self.directions.enumerated() {
                let vector = SIMD3<Double>(
                    Double(direction.x), Double(direction.y), Double(direction.z)
                )
                let lobe = peak * powerScale * exp(filtered * ((vector * axis).sum() - 1))
                let light = lobe * underglow.color
                destination[index] += SIMD3<Float>(
                    Float(light.x), Float(light.y), Float(light.z)
                )
            }
        }
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
        var total = 0.0
        for direction in Self.integrationDirections {
            let value = sample(level: level, direction: direction)
            total +=
                0.2126 * Double(value.x)
                + 0.7152 * Double(value.y)
                + 0.0722 * Double(value.z)
        }
        return total / Double(Self.integrationDirections.count)
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

    /// Unit direction of every bordered octahedral texel. The outer ring evaluates the
    /// analytic room just across the square's identified edge, eliminating runtime wrap.
    private static let directions: [SIMD3<Float>] = {
        var result = [SIMD3<Float>]()
        result.reserveCapacity(storageResolution * storageResolution)
        let scale = 2 / Float(resolution)
        for row in 0..<storageResolution {
            let vertical = (Float(row) - 0.5) * scale - 1
            for column in 0..<storageResolution {
                let horizontal = (Float(column) - 0.5) * scale - 1
                result.append(MercuryOctahedralMap.decode(SIMD2(horizontal, vertical)))
            }
        }
        return result
    }()

    /// Fixed uniform integration lattice for table normalization. Unlike a chart-space
    /// average, this assigns equal solid angle to every sample.
    private static let integrationDirections: [SIMD3<Float>] = {
        let count = 4_096
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { index in
            let height = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let radius = Swift.max(0, 1 - height * height).squareRoot()
            let angle = golden * Double(index)
            return SIMD3(
                Float(radius * cos(angle)),
                Float(radius * sin(angle)),
                Float(height)
            )
        }
    }()

    /// The real spherical-harmonic basis at every bordered texel, `l = 1...12`.
    /// Built once and only when Spectral Weather is selected.
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
