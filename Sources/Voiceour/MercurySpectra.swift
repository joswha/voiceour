import Foundation
import VoiceCore

/// Spectral optics behind every non-stock paint and the room's colour temperature.
///
/// All of it runs at bake time, never per pixel: a paint is integrated over
/// `MercurySpectral`'s 81 wavelengths into the same 1,024-entry μ → RGB table the stock
/// material uses, and a colour temperature becomes one RGB multiplier on the room. Three
/// wavelengths would alias: sampled at 610, 550 and 460 nm, a coat misses its spectral
/// integral by up to 0.44 across its thickness range, and bare gold's red by 0.11.
///
/// The island has one observer, `MercurySpectral`'s: the CIE 1931 2° colour-matching
/// functions under D65, projected to linear sRGB by the white-normalised IEC matrix with one
/// trapezoid rule. The stock conductor, every paint and the white balance all integrate
/// through it, so a flat spectrum projects to exactly neutral in each, and mercury under a
/// coat stands on the stock conductor's own data.
enum MercurySpectra {
    /// Wavelength of `MercurySpectral` grid sample `sample`, in nanometres: 380…780 nm every
    /// 5 nm. Against the CIE's 1 nm tables, bare metals and lacquers integrate within 3e-5 on
    /// this grid, and each film coat at its stock thickness within 1e-3 for μ ≥ 0.02. Nearer
    /// grazing, a film over silver resonates too narrowly for 5 nm: 2.5e-3 at μ = 0.01 and
    /// 0.017 at μ ≈ 0.0015.
    static func wavelength(_ sample: Int) -> Double {
        MercurySpectral.firstWavelength + MercurySpectral.wavelengthStep * Double(sample)
    }

    /// Linear sRGB cannot hold every reflectance spectrum: the observer's weights have
    /// negative lobes. A negative channel moves the colour toward neutral along the
    /// luminance-free direction until its lowest channel reaches zero, so Rec.709 luminance
    /// and hue are kept and only saturation is given up. Channels above 1 stay; the display
    /// response's own gamut path bounds them.
    ///
    /// The stock oracle, `MercuryOptics.exactFresnel`, clamps at zero instead. On a saturated
    /// coat a clamp would shift the hue and add luminance; mercury's channels stay above 0.70
    /// at every cosine, so for it neither binds and bare mercury reads the same either way.
    static func gamutFloor(_ color: SIMD3<Double>) -> SIMD3<Double> {
        let lowest = Swift.min(color.x, Swift.min(color.y, color.z))
        guard lowest < 0 else { return color }
        let luminance = MercuryDisplayResponse.luminance(color)
        guard luminance > 0 else { return .zero }
        let neutral = SIMD3<Double>(repeating: luminance)
        let lifted = neutral + (color - neutral) * (luminance / (luminance - lowest))
        // The lowest channel lands on zero only up to rounding; never leave it a hair below.
        return pointwiseMax(lifted, .zero)
    }

    // MARK: Materials

    /// One optical medium of a layered surface.
    enum Material: Hashable, Sendable {
        case metal(IslandMetal)
        /// Titania film, `n² = 1 + 4.07248 λ² / (λ² − 0.23098²)` (λ in µm): a single-oscillator
        /// fit to Siefke et al. 2016 ALD TiO₂ (refractiveindex.info `TiO2/Siefke`) over
        /// 0.40–0.70 µm, within 0.015 in n.
        case titania
        /// Fused silica: the Malitson 1965 three-term Sellmeier formula.
        case silica
        /// A wavelength-independent complex index n + ik.
        case constant(n: Double, k: Double)
    }

    /// A film of `material`, `nanometers` thick.
    struct Layer: Hashable, Sendable {
        var material: Material
        var nanometers: Double
    }

    /// Complex refractive index n + ik of `material` at `MercurySpectral` grid sample
    /// `sample`.
    static func refractiveIndex(
        of material: Material,
        sample: Int
    ) -> (n: Double, k: Double) {
        let micrometers = wavelength(sample) / 1_000
        let square = micrometers * micrometers
        switch material {
        case .metal(let metal):
            guard let measured = rows(metal) else {
                return (
                    MercurySpectral.mercuryRefraction[sample],
                    MercurySpectral.mercuryExtinction[sample]
                )
            }
            return interpolate(measured, micrometers: micrometers)
        case .titania:
            return ((1 + 4.072_48 * square / (square - 0.230_98 * 0.230_98)).squareRoot(), 0)
        case .silica:
            let resonances: Double =
                0.696_166_3 * square / (square - 0.068_404_3 * 0.068_404_3)
                + 0.407_942_6 * square / (square - 0.116_241_4 * 0.116_241_4)
                + 0.897_479_4 * square / (square - 9.896_161 * 9.896_161)
            return ((1 + resonances).squareRoot(), 0)
        case .constant(let n, let k):
            return (n, k)
        }
    }

    /// Linear in wavelength between the bracketing rows and clamped at the table ends:
    /// refractiveindex.info's own interpolation convention.
    private static func interpolate(
        _ rows: [Double],
        micrometers: Double
    ) -> (n: Double, k: Double) {
        guard micrometers > rows[0] else { return (rows[1], rows[2]) }
        var upper = 3
        while upper < rows.count {
            if micrometers <= rows[upper] {
                let lower = upper - 3
                let fraction = (micrometers - rows[lower]) / (rows[upper] - rows[lower])
                return (
                    rows[lower + 1] + fraction * (rows[upper + 1] - rows[lower + 1]),
                    rows[lower + 2] + fraction * (rows[upper + 2] - rows[lower + 2])
                )
            }
            upper += 3
        }
        return (rows[rows.count - 2], rows[rows.count - 1])
    }

    // MARK: Metal rows

    /// Measured optical constants as (λ µm, n, k) rows bracketing 380–780 nm, from the
    /// refractiveindex.info database (CC0):
    /// - silver, gold, copper: Johnson & Christy, Phys. Rev. B 6, 4370 (1972), `Ag/Johnson`,
    ///   `Au/Johnson`, `Cu/Johnson`;
    /// - aluminum: Rakić, Appl. Opt. 34, 4755 (1995), `Al/Rakic`;
    /// - titanium, chromium: Johnson & Christy, Phys. Rev. B 9, 5056 (1974), `Ti/Johnson`,
    ///   `Cr/Johnson`;
    /// - platinum: the Lorentz–Drude model of Rakić et al., Appl. Opt. 37, 5271 (1998),
    ///   `Pt/Rakic-LD`, resampled at the Johnson & Christy wavelengths.
    ///
    /// `nil` for mercury, whose `n + ik` is `MercurySpectral`'s table on the grid itself: the
    /// stock oracle's data, so mercury under any coat stands on exactly the stock conductor.
    /// The chameleon absorber uses the chromium rows.
    private static func rows(_ metal: IslandMetal) -> [Double]? {
        switch metal {
        case .mercury: nil
        case .silver: silverRows
        case .aluminum: aluminumRows
        case .chromium: chromiumRows
        case .platinum: platinumRows
        case .titanium: titaniumRows
        case .gold: goldRows
        case .copper: copperRows
        }
    }

    private static let silverRows: [Double] = [
        0.3679, 0.07, 1.657,
        0.3815, 0.05, 1.864,
        0.3974, 0.05, 2.07,
        0.4133, 0.05, 2.275,
        0.4305, 0.04, 2.462,
        0.4509, 0.04, 2.657,
        0.4714, 0.05, 2.869,
        0.4959, 0.05, 3.093,
        0.5209, 0.05, 3.324,
        0.5486, 0.06, 3.586,
        0.5821, 0.05, 3.858,
        0.6168, 0.06, 4.152,
        0.6595, 0.05, 4.483,
        0.7045, 0.04, 4.838,
        0.756, 0.03, 5.242,
        0.8211, 0.04, 5.727,
    ]

    private static let goldRows: [Double] = [
        0.3679, 1.48, 1.895,
        0.3815, 1.46, 1.933,
        0.3974, 1.47, 1.952,
        0.4133, 1.46, 1.958,
        0.4305, 1.45, 1.948,
        0.4509, 1.38, 1.914,
        0.4714, 1.31, 1.849,
        0.4959, 1.04, 1.833,
        0.5209, 0.62, 2.081,
        0.5486, 0.43, 2.455,
        0.5821, 0.29, 2.863,
        0.6168, 0.21, 3.272,
        0.6595, 0.14, 3.697,
        0.7045, 0.13, 4.103,
        0.756, 0.14, 4.542,
        0.8211, 0.16, 5.083,
    ]

    private static let copperRows: [Double] = [
        0.3679, 1.36, 1.975,
        0.3815, 1.33, 2.045,
        0.3974, 1.32, 2.116,
        0.4133, 1.28, 2.207,
        0.4305, 1.25, 2.305,
        0.4509, 1.24, 2.397,
        0.4714, 1.25, 2.483,
        0.4959, 1.22, 2.564,
        0.5209, 1.18, 2.608,
        0.5486, 1.02, 2.577,
        0.5821, 0.7, 2.704,
        0.6168, 0.3, 3.205,
        0.6595, 0.22, 3.747,
        0.7045, 0.21, 4.205,
        0.756, 0.24, 4.665,
        0.8211, 0.26, 5.18,
    ]

    private static let aluminumRows: [Double] = [
        0.36466, 0.39877, 4.3957,
        0.41328, 0.52135, 5.0008,
        0.4428, 0.6079, 5.3676,
        0.47687, 0.7278, 5.7781,
        0.5166, 0.8734, 6.2418,
        0.56357, 1.0728, 6.7839,
        0.61993, 1.366, 7.4052,
        0.65225, 1.5724, 7.7354,
        0.68881, 1.8301, 8.0601,
        0.72932, 2.1606, 8.3565,
        0.77491, 2.6154, 8.4914,
        0.79478, 2.7675, 8.3866,
    ]

    private static let titaniumRows: [Double] = [
        0.368, 1.9, 2.9,
        0.381, 1.99, 2.93,
        0.397, 2.08, 2.95,
        0.413, 2.14, 2.98,
        0.431, 2.21, 3.01,
        0.451, 2.27, 3.04,
        0.471, 2.32, 3.1,
        0.496, 2.36, 3.19,
        0.521, 2.44, 3.3,
        0.549, 2.54, 3.43,
        0.582, 2.6, 3.58,
        0.617, 2.67, 3.72,
        0.659, 2.76, 3.84,
        0.704, 2.86, 3.96,
        0.756, 3.0, 4.01,
        0.821, 3.21, 4.01,
    ]

    private static let chromiumRows: [Double] = [
        0.368, 1.87, 2.69,
        0.381, 1.92, 2.74,
        0.397, 2.0, 2.83,
        0.413, 2.08, 2.93,
        0.431, 2.19, 3.04,
        0.451, 2.33, 3.14,
        0.471, 2.51, 3.24,
        0.496, 2.75, 3.3,
        0.521, 2.94, 3.33,
        0.549, 3.18, 3.33,
        0.582, 3.22, 3.3,
        0.617, 3.17, 3.3,
        0.659, 3.09, 3.34,
        0.704, 3.05, 3.39,
        0.756, 3.08, 3.42,
        0.821, 3.2, 3.48,
    ]

    private static let platinumRows: [Double] = [
        0.368, 1.63687, 2.65496,
        0.381, 1.67258, 2.7372,
        0.397, 1.71608, 2.83463,
        0.413, 1.75844, 2.92875,
        0.431, 1.8044, 3.03219,
        0.451, 1.85353, 3.14541,
        0.471, 1.90118, 3.25785,
        0.496, 1.95998, 3.39855,
        0.521, 2.01933, 3.53968,
        0.549, 2.0883, 3.69795,
        0.582, 2.17432, 3.88358,
        0.617, 2.27209, 4.07677,
        0.659, 2.39751, 4.30075,
        0.704, 2.53923, 4.52819,
        0.756, 2.70779, 4.77302,
        0.821, 2.91774, 5.05341,
    ]
}

/// Ambient | films… | substrate, prepared for repeated evaluation: every layer's
/// permittivity and every film's phase scale are resolved per grid sample once, so a
/// 1,024-cosine table costs only the recursion itself.
///
/// The reflectance is exact (Airy recursion over complex Fresnel amplitudes), absorbing
/// layers included, with s and p polarizations averaged.
struct MercuryOpticalStack {
    private let films: Int
    /// Row-major `MercurySpectral.sampleCount × (films + 1)`: each film top-down, then the
    /// substrate. All relative to the ambient medium, whose own permittivity is therefore
    /// exactly 1.
    private let permittivities: [Complex]
    /// Row-major `MercurySpectral.sampleCount × films`: `4π · d · n_ambient / λ`, the
    /// round-trip phase per unit normalized normal wave number.
    private let phases: [Double]

    /// `ambientIndex` is the real index of the medium light arrives from; cosines passed to
    /// `reflectance` are measured in it.
    init(
        films: [MercurySpectra.Layer],
        substrate: MercurySpectra.Material,
        ambientIndex: Double = 1
    ) {
        let ambient = ambientIndex * ambientIndex
        var permittivities: [Complex] = []
        var phases: [Double] = []
        permittivities.reserveCapacity(MercurySpectral.sampleCount * (films.count + 1))
        phases.reserveCapacity(MercurySpectral.sampleCount * films.count)
        for sample in 0..<MercurySpectral.sampleCount {
            let nanometers = MercurySpectra.wavelength(sample)
            for film in films {
                permittivities.append(
                    Self.permittivity(of: film.material, sample: sample, ambient: ambient)
                )
                phases.append(4 * Double.pi * film.nanometers * ambientIndex / nanometers)
            }
            permittivities.append(
                Self.permittivity(of: substrate, sample: sample, ambient: ambient)
            )
        }
        self.films = films.count
        self.permittivities = permittivities
        self.phases = phases
    }

    /// Unpolarized reflectance at `cosine` for grid sample `sample`.
    ///
    /// Each layer's normalized normal wave number is `q = √(ε − sin²θ)`, the root with
    /// `Im q ≥ 0` so transmitted waves decay; the ambient's is the cosine itself. It is
    /// evaluated as `√((ε − 1) + cos²θ)`: identical in exact arithmetic, but a film of index
    /// 1 then has `q` equal to the cosine bit for bit instead of losing digits near grazing.
    /// Interfaces use `r_s = (q_i − q_j) / (q_i + q_j)` and
    /// `r_p = (ε_j q_i − ε_i q_j) / (ε_j q_i + ε_i q_j)`; from the substrate up, each film
    /// wraps what lies beneath it as `Γ ← (r + Γ E) / (1 + r Γ E)` with the round-trip
    /// factor `E = exp(i · 4π d q / λ)`.
    func reflectance(cosine: Double, sample: Int) -> Double {
        let cosineSquared = cosine * cosine
        let row = sample * (films + 1)
        var lower = permittivities[row + films]
        var lowerWave = Self.wave(lower, cosineSquared)
        var upper = films > 0 ? permittivities[row + films - 1] : Complex(1)
        var upperWave = films > 0 ? Self.wave(upper, cosineSquared) : Complex(cosine)
        var (gammaS, gammaP) = Self.interface(upper, upperWave, lower, lowerWave)
        for film in stride(from: films - 1, through: 0, by: -1) {
            lower = upper
            lowerWave = upperWave
            upper = film > 0 ? permittivities[row + film - 1] : Complex(1)
            upperWave = film > 0 ? Self.wave(upper, cosineSquared) : Complex(cosine)
            let roundTrip = Complex.expi(lowerWave * phases[sample * films + film])
            let (fresnelS, fresnelP) = Self.interface(upper, upperWave, lower, lowerWave)
            gammaS = Self.wrap(fresnelS, beneath: gammaS * roundTrip)
            gammaP = Self.wrap(fresnelP, beneath: gammaP * roundTrip)
        }
        return (gammaS.magnitudeSquared + gammaP.magnitudeSquared) / 2
    }

    /// The reflectance spectrum through the shared observer, `MercurySpectral`: linear sRGB
    /// before the gamut floor.
    func rgb(cosine: Double) -> SIMD3<Double> {
        MercurySpectral.linearSRGB { sample in reflectance(cosine: cosine, sample: sample) }
    }

    private static func permittivity(
        of material: MercurySpectra.Material,
        sample: Int,
        ambient: Double
    ) -> Complex {
        let index = MercurySpectra.refractiveIndex(of: material, sample: sample)
        return Complex(
            (index.n * index.n - index.k * index.k) / ambient,
            2 * index.n * index.k / ambient
        )
    }

    private static func wave(_ permittivity: Complex, _ cosineSquared: Double) -> Complex {
        Complex(permittivity.re - 1 + cosineSquared, permittivity.im).squareRoot()
    }

    private static func interface(
        _ upper: Complex,
        _ upperWave: Complex,
        _ lower: Complex,
        _ lowerWave: Complex
    ) -> (s: Complex, p: Complex) {
        let s = (upperWave - lowerWave) / (upperWave + lowerWave)
        let lowerOnUpperWave = lower * upperWave
        let upperOnLowerWave = upper * lowerWave
        let p = (lowerOnUpperWave - upperOnLowerWave) / (lowerOnUpperWave + upperOnLowerWave)
        return (s, p)
    }

    private static func wrap(_ fresnel: Complex, beneath: Complex) -> Complex {
        (fresnel + beneath) / (Complex(1) + fresnel * beneath)
    }
}

/// Clear or candy lacquer (n = 1.50) over a metal: an incoherent layer whose dye transmits
/// `T₀` per channel on a normal-incidence round trip and `T = T₀^(1/μ_t)` along the slanted
/// path at the refracted cosine `μ_t = √(1 − (1 − μ²)/n²)`. With `R_t` the lacquer's own
/// dielectric Fresnel and `F` the metal's spectral Fresnel seen from inside the lacquer,
/// the interreflection sum is `R = R_t + (1 − R_t)² F T / (1 − R_t F T)`.
///
/// The sum runs per wavelength and is then projected onto each channel's weights in the
/// shared observer (`MercurySpectral.channelWeights`), with the dye acting as a neutral
/// filter of that channel's strength inside its band. Summing after projecting would put
/// linear-sRGB `F` into the denominator: gold's red there exceeds 1 (a negative-lobe gamut
/// effect), and `1 − R_t F` crosses zero near grazing. Per wavelength, `F ≤ 1` and the sum
/// stays bounded. A clear coat is the same lacquer with `T₀ = 1`.
struct MercuryLacquer {
    static let index = 1.5
    /// Dye transmittance is kept in [0.02, 1]: an opaque dye would leave only the lacquer's
    /// own sheen, which no longer reads as the chosen colour.
    static let transmittanceRange: ClosedRange<Double> = 0.02...1

    private let metal: MercuryOpticalStack
    private let transmittance: SIMD3<Double>

    init(metal: IslandMetal, transmittance: SIMD3<Double>) {
        self.metal = MercuryOpticalStack(
            films: [],
            substrate: .metal(metal),
            ambientIndex: Self.index
        )
        let range = Self.transmittanceRange
        self.transmittance = pointwiseMin(
            pointwiseMax(transmittance, SIMD3(repeating: range.lowerBound)),
            SIMD3(repeating: range.upperBound)
        )
    }

    /// Linear sRGB before the gamut floor.
    func rgb(cosine: Double) -> SIMD3<Double> {
        let permittivity = Self.index * Self.index
        let wave = (permittivity - 1 + cosine * cosine).squareRoot()
        let s = (cosine - wave) / (cosine + wave)
        let p = (permittivity * cosine - wave) / (permittivity * cosine + wave)
        let surface = (s * s + p * p) / 2
        let refracted = wave / Self.index
        let path = 1 / refracted
        let dye = SIMD3(
            pow(transmittance.x, path),
            pow(transmittance.y, path),
            pow(transmittance.z, path)
        )
        let weights = MercurySpectral.channelWeights
        var sum = SIMD3<Double>.zero
        for sample in 0..<MercurySpectral.sampleCount {
            let base = metal.reflectance(cosine: refracted, sample: sample)
            let weight = weights[sample]
            sum.x += weight.x * Self.interreflect(surface: surface, through: dye.x * base)
            sum.y += weight.y * Self.interreflect(surface: surface, through: dye.y * base)
            sum.z += weight.z * Self.interreflect(surface: surface, through: dye.z * base)
        }
        return sum
    }

    private static func interreflect(surface: Double, through: Double) -> Double {
        surface + (1 - surface) * (1 - surface) * through / (1 - surface * through)
    }
}

/// Room colour temperature as one RGB multiplier on the room.
///
/// The slider moves in mired, `M = 153.75 + 60t` for t ∈ [−1, 1] (10,667 K … 6,504 K …
/// 4,678 K): Δu′v′ is nearly linear in mired, so equal steps read as equal shifts either
/// side of stock. The room is lit by the observer's D65; a temperature multiplies that light
/// by the Planckian ratio `B(λ, T(t)) / B(λ, T(0))`, whose colour through the paints' own
/// observer (`MercurySpectral`) is the multiplier, scaled to unit Rec.709 luminance. The
/// room's normalization then restores its mean.
enum MercuryWhiteBalance {
    /// Second radiation constant c₂ = hc/k, in µm·K.
    private static let secondRadiation: Double = 14_387.768_775

    /// `nil` at t = 0: stock skips the step entirely.
    static func multipliers(temperature t: Double) -> SIMD3<Double>? {
        guard t != 0 else { return nil }
        let target = kelvin(temperature: t)
        let reference = kelvin(temperature: 0)
        let tint = MercurySpectral.linearSRGB { sample in
            planckRatio(
                nanometers: MercurySpectra.wavelength(sample),
                kelvin: target,
                reference: reference
            )
        }
        return tint / MercuryDisplayResponse.luminance(tint)
    }

    /// Planckian temperature for slider position `t`, clamped to [−1, 1] so the mired
    /// value stays positive.
    static func kelvin(temperature t: Double) -> Double {
        1_000_000 / (153.75 + 60 * Swift.min(Swift.max(t, -1), 1))
    }

    /// `B(λ, T) / B(λ, T₀)` for Planck's law `B = λ⁻⁵ / (exp(c₂/λT) − 1)`, λ in µm: the
    /// `λ⁻⁵` cancels.
    private static func planckRatio(
        nanometers: Double,
        kelvin: Double,
        reference: Double
    ) -> Double {
        let micrometers = nanometers / 1_000
        return expm1(secondRadiation / (micrometers * reference))
            / expm1(secondRadiation / (micrometers * kelvin))
    }
}

/// User-chosen colours: HSB on the sRGB primaries, decoded to linear light.
enum MercuryColor {
    /// `hue` in degrees, `saturation` and `brightness` in percent; IEC 61966-2-1 decoding.
    static func linearRGB(hue: Int, saturation: Int, brightness: Int) -> SIMD3<Double> {
        let sector = Double((hue % 360 + 360) % 360) / 60
        let value = Double(Swift.min(Swift.max(brightness, 0), 100)) / 100
        let chroma = value * Double(Swift.min(Swift.max(saturation, 0), 100)) / 100
        let middle = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let encoded: SIMD3<Double>
        switch Int(sector) {
        case 0: encoded = SIMD3(chroma, middle, 0)
        case 1: encoded = SIMD3(middle, chroma, 0)
        case 2: encoded = SIMD3(0, chroma, middle)
        case 3: encoded = SIMD3(0, middle, chroma)
        case 4: encoded = SIMD3(middle, 0, chroma)
        default: encoded = SIMD3(chroma, 0, middle)
        }
        let offset = value - chroma
        return SIMD3(
            decode(encoded.x + offset),
            decode(encoded.y + offset),
            decode(encoded.z + offset)
        )
    }

    /// `color` scaled to unit Rec.709 luminance. Black has no hue to keep and becomes
    /// neutral.
    static func luminanceNormalized(_ color: SIMD3<Double>) -> SIMD3<Double> {
        let luminance = MercuryDisplayResponse.luminance(color)
        guard luminance > 0 else { return SIMD3(repeating: 1) }
        return color / luminance
    }

    private static func decode(_ encoded: Double) -> Double {
        encoded <= 0.040_45 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
}

/// Just enough complex arithmetic for the Airy recursion.
private struct Complex {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    var magnitudeSquared: Double { re * re + im * im }

    static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.re + rhs.re, lhs.im + rhs.im)
    }

    static func - (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.re - rhs.re, lhs.im - rhs.im)
    }

    static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.re * rhs.re - lhs.im * rhs.im, lhs.re * rhs.im + lhs.im * rhs.re)
    }

    static func * (lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.re * rhs, lhs.im * rhs)
    }

    static func / (lhs: Complex, rhs: Complex) -> Complex {
        let scale = 1 / (rhs.re * rhs.re + rhs.im * rhs.im)
        return Complex(
            (lhs.re * rhs.re + lhs.im * rhs.im) * scale,
            (lhs.im * rhs.re - lhs.re * rhs.im) * scale
        )
    }

    /// The square root with non-negative imaginary part for every passive medium here
    /// (`Im ≥ 0`), where it is also the principal root. Each branch takes the
    /// cancellation-free component first.
    func squareRoot() -> Complex {
        let modulus = (re * re + im * im).squareRoot()
        if re >= 0 {
            let real = ((modulus + re) / 2).squareRoot()
            return real > 0 ? Complex(real, im / (2 * real)) : Complex(0)
        }
        let imaginary = ((modulus - re) / 2).squareRoot()
        return Complex(im / (2 * imaginary), imaginary)
    }

    /// `exp(i z)`; a positive imaginary part attenuates.
    static func expi(_ z: Complex) -> Complex {
        let attenuation = exp(-z.im)
        return Complex(attenuation * cos(z.re), attenuation * sin(z.re))
    }
}
