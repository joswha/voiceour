/// Liquid mercury's colour as an eye or a camera receives it: the exact smooth-conductor
/// Fresnel reflectance integrated over the visible spectrum under daylight.
///
/// A pixel has to reproduce what the observer integrates,
/// `X = ∫ F(λ, μ) S(λ) x̄(λ) dλ / ∫ S(λ) ȳ(λ) dλ` and likewise `Y` and `Z`, with `S` the D65
/// daylight spectrum. The retired oracle held three `n + ik` pairs: Inagaki's data at 610 and
/// 550 nm to every tabulated digit, and at 460 nm within 0.25 %. Those are the dominant
/// wavelengths of the sRGB primaries (611, 549 and 464 nm) rounded to 10 nm, and sampling
/// there treats each primary as a delta function. That is right only while `F` is flat across
/// each colour-matching lobe, and the lobes are broad: 78, 100 and 54 nm at half maximum for
/// `x̄`, `ȳ` and `z̄`. At normal incidence mercury is nearly flat (`F₀` spans 0.772…0.783 over
/// 380–780 nm) and the two oracles agree within 5e-4. Toward the principal angle the spectrum
/// fans out, by 0.15 across the visible at `μ = 0.1`, and three samples misplace a channel by
/// up to 0.013.
///
/// Mercury's neutral `F₀ ≈ 0.78` is preserved: (0.7814, 0.7795, 0.7784) in linear sRGB,
/// against the retired (0.7811, 0.7794, 0.7780).
///
/// Every table holds 81 samples, 380–780 nm at 5 nm, retrieved 2026-10-29:
///
/// - CIE 1931 2° colour-matching functions, CIE 018:2019 Table 6:
///   <https://files.cie.co.at/Publications-datasets/CIE_xyz_1931_2deg.csv>
///   (doi:10.25039/CIE.DS.xvudnb9b). Every fifth 1 nm row, verbatim; identical to CVRL's
///   5 nm `ciexyz31.csv` (<http://cvrl.ucl.ac.uk/>, "CIE 1931 2-deg, XYZ CMFs").
/// - CIE standard illuminant D65, ISO/CIE 11664-2:2022 Table B.1:
///   <https://files.cie.co.at/Publications-datasets/CIE_std_illum_D65.csv>
///   (doi:10.25039/CIE.DS.hjfjmt59). Every fifth 1 nm row, verbatim.
/// - Liquid mercury `n + ik`: Inagaki, Arakawa and Williams, "Optical properties of liquid
///   mercury", Phys. Rev. B 23, 5246 (1981), doi:10.1103/PhysRevB.23.5246, as tabulated by
///   refractiveindex.info (shelf main, book Hg, page Inagaki, CC0):
///   <https://refractiveindex.info/?shelf=main&book=Hg&page=Inagaki>, raw file
///   `database/data/main/Hg/nk/Inagaki.yml`. The source steps 0.2 eV; its samples at 364.66,
///   387.45, …, 774.90 and 885.60 nm are resampled by linear interpolation in wavelength and
///   rounded to the source's five decimals.
enum MercurySpectral {
    // MARK: Grid

    /// First tabulated wavelength, nm.
    static let firstWavelength: Double = 380
    /// Tabulation interval, nm: the CIE's standard 5 nm abridgement.
    static let wavelengthStep: Double = 5
    /// Samples per table: 380 through 780 nm inclusive.
    static let sampleCount = 81

    // MARK: Tables

    /// CIE 1931 2° `x̄(λ)`. The CIE's own table carries float residue such as `0.05795001`;
    /// it is kept rather than rounded, so every entry matches its source row.
    static let colorMatchingX: [Double] = [
        0.001368, 0.002236, 0.004243, 0.00765, 0.01431,  // 380–400 nm
        0.02319, 0.04351, 0.07763, 0.13438, 0.21477,  // 405–425 nm
        0.2839, 0.3285, 0.34828, 0.34806, 0.3362,  // 430–450 nm
        0.3187, 0.2908, 0.2511, 0.19536, 0.1421,  // 455–475 nm
        0.09564, 0.05795001, 0.03201, 0.0147, 0.0049,  // 480–500 nm
        0.0024, 0.0093, 0.0291, 0.06327, 0.1096,  // 505–525 nm
        0.1655, 0.2257499, 0.2904, 0.3597, 0.4334499,  // 530–550 nm
        0.5120501, 0.5945, 0.6784, 0.7621, 0.8425,  // 555–575 nm
        0.9163, 0.9786, 1.0263, 1.0567, 1.0622,  // 580–600 nm
        1.0456, 1.0026, 0.9384, 0.8544499, 0.7514,  // 605–625 nm
        0.6424, 0.5419, 0.4479, 0.3608, 0.2835,  // 630–650 nm
        0.2187, 0.1649, 0.1212, 0.0874, 0.0636,  // 655–675 nm
        0.04677, 0.0329, 0.0227, 0.01584, 0.01135916,  // 680–700 nm
        0.008110916, 0.005790346, 0.004109457, 0.002899327, 0.00204919,  // 705–725 nm
        0.001439971, 0.0009999493, 0.0006900786, 0.0004760213, 0.0003323011,  // 730–750 nm
        0.0002348261, 0.0001661505, 0.000117413, 0.00008307527, 0.00005870652,  // 755–775 nm
        0.00004150994,  // 780 nm
    ]

    /// CIE 1931 2° `ȳ(λ)`, the photopic luminous efficiency.
    static let colorMatchingY: [Double] = [
        0.000039, 0.000064, 0.00012, 0.000217, 0.000396,  // 380–400 nm
        0.00064, 0.00121, 0.00218, 0.004, 0.0073,  // 405–425 nm
        0.0116, 0.01684, 0.023, 0.0298, 0.038,  // 430–450 nm
        0.048, 0.06, 0.0739, 0.09098, 0.1126,  // 455–475 nm
        0.13902, 0.1693, 0.20802, 0.2586, 0.323,  // 480–500 nm
        0.4073, 0.503, 0.6082, 0.71, 0.7932,  // 505–525 nm
        0.862, 0.9148501, 0.954, 0.9803, 0.9949501,  // 530–550 nm
        1.0, 0.995, 0.9786, 0.952, 0.9154,  // 555–575 nm
        0.87, 0.8163, 0.757, 0.6949, 0.631,  // 580–600 nm
        0.5668, 0.503, 0.4412, 0.381, 0.321,  // 605–625 nm
        0.265, 0.217, 0.175, 0.1382, 0.107,  // 630–650 nm
        0.0816, 0.061, 0.04458, 0.032, 0.0232,  // 655–675 nm
        0.017, 0.01192, 0.00821, 0.005723, 0.004102,  // 680–700 nm
        0.002929, 0.002091, 0.001484, 0.001047, 0.00074,  // 705–725 nm
        0.00052, 0.0003611, 0.0002492, 0.0001719, 0.00012,  // 730–750 nm
        0.0000848, 0.00006, 0.0000424, 0.00003, 0.0000212,  // 755–775 nm
        0.00001499,  // 780 nm
    ]

    /// CIE 1931 2° `z̄(λ)`. The CIE tabulates it as exactly 0 from 650 nm.
    static let colorMatchingZ: [Double] = [
        0.006450001, 0.01054999, 0.02005001, 0.03621, 0.06785001,  // 380–400 nm
        0.1102, 0.2074, 0.3713, 0.6456, 1.0390501,  // 405–425 nm
        1.3856, 1.62296, 1.74706, 1.7826, 1.77211,  // 430–450 nm
        1.7441, 1.6692, 1.5281, 1.28764, 1.0419,  // 455–475 nm
        0.8129501, 0.6162, 0.46518, 0.3533, 0.272,  // 480–500 nm
        0.2123, 0.1582, 0.1117, 0.07824999, 0.05725001,  // 505–525 nm
        0.04216, 0.02984, 0.0203, 0.0134, 0.008749999,  // 530–550 nm
        0.005749999, 0.0039, 0.002749999, 0.0021, 0.0018,  // 555–575 nm
        0.001650001, 0.0014, 0.0011, 0.001, 0.0008,  // 580–600 nm
        0.0006, 0.00034, 0.00024, 0.00019, 0.0001,  // 605–625 nm
        0.00004999999, 0.00003, 0.00002, 0.00001, 0.0,  // 630–650 nm
        0.0, 0.0, 0.0, 0.0, 0.0,  // 655–675 nm
        0.0, 0.0, 0.0, 0.0, 0.0,  // 680–700 nm
        0.0, 0.0, 0.0, 0.0, 0.0,  // 705–725 nm
        0.0, 0.0, 0.0, 0.0, 0.0,  // 730–750 nm
        0.0, 0.0, 0.0, 0.0, 0.0,  // 755–775 nm
        0.0,  // 780 nm
    ]

    /// CIE standard illuminant D65, relative spectral power normalised to 100 at 560 nm.
    static let illuminantD65: [Double] = [
        49.9755, 52.3118, 54.6482, 68.7015, 82.7549,  // 380–400 nm
        87.1204, 91.486, 92.4589, 93.4318, 90.057,  // 405–425 nm
        86.6823, 95.7736, 104.865, 110.936, 117.008,  // 430–450 nm
        117.41, 117.812, 116.336, 114.861, 115.392,  // 455–475 nm
        115.923, 112.367, 108.811, 109.082, 109.354,  // 480–500 nm
        108.578, 107.802, 106.296, 104.79, 106.239,  // 505–525 nm
        107.689, 106.047, 104.405, 104.225, 104.046,  // 530–550 nm
        102.023, 100.0, 98.1671, 96.3342, 96.0611,  // 555–575 nm
        95.788, 92.2368, 88.6856, 89.3459, 90.0062,  // 580–600 nm
        89.8026, 89.5991, 88.6489, 87.6987, 85.4936,  // 605–625 nm
        83.2886, 83.4939, 83.6992, 81.863, 80.0268,  // 630–650 nm
        80.1207, 80.2146, 81.2462, 82.2778, 80.281,  // 655–675 nm
        78.2842, 74.0027, 69.7213, 70.6652, 71.6091,  // 680–700 nm
        72.979, 74.349, 67.9765, 61.604, 65.7448,  // 705–725 nm
        69.8856, 72.4863, 75.087, 69.3398, 63.5927,  // 730–750 nm
        55.0054, 46.4182, 56.6118, 66.8054, 65.0941,  // 755–775 nm
        63.3828,  // 780 nm
    ]

    /// Liquid mercury's refractive index `n(λ)`, Inagaki resampled.
    static let mercuryRefraction: [Double] = [
        0.77039, 0.78908, 0.80809, 0.82740, 0.84671,  // 380–400 nm
        0.86602, 0.88533, 0.90552, 0.92736, 0.94921,  // 405–425 nm
        0.97105, 0.99290, 1.01475, 1.03725, 1.06060,  // 430–450 nm
        1.08394, 1.10728, 1.13063, 1.15397, 1.17732,  // 455–475 nm
        1.20159, 1.22642, 1.25124, 1.27607, 1.30090,  // 480–500 nm
        1.32572, 1.35055, 1.37538, 1.40052, 1.42581,  // 505–525 nm
        1.45111, 1.47640, 1.50170, 1.52699, 1.55228,  // 530–550 nm
        1.57758, 1.60287, 1.62826, 1.65390, 1.67954,  // 555–575 nm
        1.70518, 1.73082, 1.75646, 1.78210, 1.80774,  // 580–600 nm
        1.83337, 1.85901, 1.88465, 1.91031, 1.93748,  // 605–625 nm
        1.96465, 1.99182, 2.01899, 2.04616, 2.07333,  // 630–650 nm
        2.10050, 2.12767, 2.15484, 2.18201, 2.20918,  // 655–675 nm
        2.23635, 2.26352, 2.29061, 2.31743, 2.34426,  // 680–700 nm
        2.37109, 2.39791, 2.42474, 2.45156, 2.47839,  // 705–725 nm
        2.50521, 2.53204, 2.55887, 2.58569, 2.61252,  // 730–750 nm
        2.63934, 2.66617, 2.69299, 2.71982, 2.74663,  // 755–775 nm
        2.77272,  // 780 nm
    ]

    /// Liquid mercury's extinction coefficient `k(λ)`, Inagaki resampled.
    static let mercuryExtinction: [Double] = [
        3.22159, 3.26986, 3.31763, 3.36493, 3.41223,  // 380–400 nm
        3.45952, 3.50682, 3.55324, 3.59797, 3.64269,  // 405–425 nm
        3.68742, 3.73215, 3.77688, 3.82052, 3.86279,  // 430–450 nm
        3.90505, 3.94731, 3.98957, 4.03183, 4.07409,  // 455–475 nm
        4.11480, 4.15459, 4.19438, 4.23418, 4.27397,  // 480–500 nm
        4.31376, 4.35355, 4.39335, 4.43102, 4.46769,  // 505–525 nm
        4.50436, 4.54103, 4.57770, 4.61437, 4.65105,  // 530–550 nm
        4.68772, 4.72439, 4.76070, 4.79610, 4.83150,  // 555–575 nm
        4.86690, 4.90230, 4.93770, 4.97310, 5.00850,  // 580–600 nm
        5.04390, 5.07930, 5.11470, 5.15003, 5.18142,  // 605–625 nm
        5.21280, 5.24419, 5.27557, 5.30696, 5.33834,  // 630–650 nm
        5.36973, 5.40111, 5.43250, 5.46388, 5.49527,  // 655–675 nm
        5.52665, 5.55804, 5.58847, 5.61589, 5.64331,  // 680–700 nm
        5.67072, 5.69814, 5.72556, 5.75298, 5.78039,  // 705–725 nm
        5.80781, 5.83523, 5.86265, 5.89006, 5.91748,  // 730–750 nm
        5.94490, 5.97232, 5.99973, 6.02715, 6.05447,  // 755–775 nm
        6.07720,  // 780 nm
    ]

    // MARK: Colorimetry

    /// IEC 61966-2-1:1999 XYZ → linear sRGB, rows R, G, B, exactly as published to four
    /// decimals.
    static let xyzToLinearSRGB: [SIMD3<Double>] = [
        SIMD3(3.2406, -1.5372, -0.4986),
        SIMD3(-0.9689, 1.8758, 0.0415),
        SIMD3(0.0557, -0.2040, 1.0570),
    ]

    /// Trapezoid-rule weight of sample `index`, nm: half a step at either end, a full step
    /// inside. Every colour is divided by an integral built from the same weights, so the
    /// rule's own error cancels exactly for a spectrally flat reflector.
    static func trapezoidWeight(_ index: Int) -> Double {
        index == 0 || index == sampleCount - 1 ? wavelengthStep / 2 : wavelengthStep
    }

    /// Per-sample tristimulus weights `w_i S_i (x̄_i, ȳ_i, z̄_i) / Σ_j w_j S_j ȳ_j` under D65
    /// `S`. A sampled reflectance `R_i` has tristimulus `Σ_i R_i weight_i`.
    private static let tristimulusWeights: [SIMD3<Double>] = {
        let luminance = (0..<sampleCount).reduce(0.0) { sum, index in
            sum + trapezoidWeight(index) * illuminantD65[index] * colorMatchingY[index]
        }
        return (0..<sampleCount).map { index in
            let weight = trapezoidWeight(index) * illuminantD65[index] / luminance
            return weight * SIMD3(colorMatchingX[index], colorMatchingY[index], colorMatchingZ[index])
        }
    }()

    /// The D65 white point: the tristimulus of a perfect reflector, with `Y = 1`. The 5 nm
    /// trapezoid gives (0.95041, 1, 1.08873), chromaticity (0.31273, 0.32904).
    static let whitePoint: SIMD3<Double> = tristimulusWeights.reduce(.zero, +)

    /// Per-sample linear-sRGB weights, white-normalised. The four-decimal IEC matrix maps
    /// `whitePoint` to (0.99987, 1.00013, 0.99972) rather than (1, 1, 1). Dividing each
    /// channel by that response, a gain within 2.8e-4 of 1, makes a perfect reflector exactly
    /// neutral instead of tinting it with the matrix's rounding.
    private static let channelWeights: [SIMD3<Double>] = {
        let white = linearSRGB(xyz: whitePoint)
        return tristimulusWeights.map { linearSRGB(xyz: $0) / white }
    }()

    /// The IEC matrix alone, without the white normalisation.
    static func linearSRGB(xyz: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            (xyzToLinearSRGB[0] * xyz).sum(),
            (xyzToLinearSRGB[1] * xyz).sum(),
            (xyzToLinearSRGB[2] * xyz).sum()
        )
    }

    /// White-normalised linear-sRGB colour, under D65, of a surface whose reflectance at
    /// sample `index` is `spectrum(index)`. A perfect reflector maps to (1, 1, 1).
    static func linearSRGB(spectrum: (Int) -> Double) -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        for index in 0..<sampleCount {
            sum += spectrum(index) * channelWeights[index]
        }
        return sum
    }

    // MARK: Conductor

    /// Mercury's linear-sRGB reflectance at incidence cosine `μ`: the exact Fresnel
    /// reflectance at all 81 wavelengths, integrated against the observer. `MercuryOptics`
    /// builds its lookup table from this once, so the per-pixel cost is unchanged.
    static func linearSRGBReflectance(cosine: Double) -> SIMD3<Double> {
        linearSRGB { index in
            reflectance(n: mercuryRefraction[index], k: mercuryExtinction[index], cosine: cosine)
        }
    }

    /// Exact unpolarized reflectance of a smooth interface from air into a conductor of
    /// complex index `n + ik`, at incidence cosine `μ`: Born and Wolf's amplitudes in the
    /// real-valued form of Lagarde's memo, as used by PBRT. With `s² = 1 − μ²`,
    /// `t₀ = n² − k² − s²`, `a² + b² = √(t₀² + 4n²k²)` and `a = √((a² + b² + t₀)/2)`,
    ///
    ///     R_s = (a² + b² + μ² − 2aμ) / (a² + b² + μ² + 2aμ)
    ///     R_p = R_s (μ²(a² + b²) + s⁴ − 2aμs²) / (μ²(a² + b²) + s⁴ + 2aμs²)
    ///     F   = (R_s + R_p) / 2
    ///
    /// so `F(1) = ((n − 1)² + k²) / ((n + 1)² + k²)` and `F(0) = 1` exactly. In between,
    /// `R_p` dips through the principal angle, so `F` is not monotone in `μ`.
    static func reflectance(n: Double, k: Double, cosine: Double) -> Double {
        let cosineSquared = cosine * cosine
        let sineSquared = Swift.max(0, 1 - cosineSquared)
        let base = n * n - k * k - sineSquared
        let squares = (base * base + 4 * n * n * k * k).squareRoot()
        let real = Swift.max(0, (squares + base) / 2).squareRoot()
        let first = squares + cosineSquared
        let second = 2 * real * cosine
        let perpendicular = (first - second) / (first + second)
        let third = cosineSquared * squares + sineSquared * sineSquared
        let fourth = second * sineSquared
        let parallel = perpendicular * (third - fourth) / (third + fourth)
        return (perpendicular + parallel) / 2
    }
}
