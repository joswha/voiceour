import Testing

@testable import Voiceour

struct MercurySpectralTests {
    /// Every table is the CIE's 5 nm abridgement from 380 to 780 nm. The CIE normalises its
    /// observer so that the equal-energy spectrum is white, `∫x̄ = ∫ȳ = ∫z̄`; the trapezoid
    /// over the embedded rows holds that within 0.014 %.
    @Test func colourMatchingFunctionsIntegrateToEqualEnergyWhite() {
        #expect(MercurySpectral.firstWavelength == 380)
        #expect(MercurySpectral.wavelengthStep == 5)
        #expect(MercurySpectral.sampleCount == 81)
        let tables = [
            MercurySpectral.colorMatchingX,
            MercurySpectral.colorMatchingY,
            MercurySpectral.colorMatchingZ,
            MercurySpectral.illuminantD65,
            MercurySpectral.mercuryRefraction,
            MercurySpectral.mercuryExtinction,
        ]
        for table in tables {
            #expect(table.count == 81)
        }

        let x = Self.integral(MercurySpectral.colorMatchingX)
        let y = Self.integral(MercurySpectral.colorMatchingY)
        let z = Self.integral(MercurySpectral.colorMatchingZ)
        #expect(Swift.max(x, y, z) / Swift.min(x, y, z) - 1 < 0.005)
    }

    /// Integrated over the embedded rows, daylight lands on D65's published chromaticity.
    @Test func daylightWhiteHasTheD65Chromaticity() {
        let white = MercurySpectral.whitePoint
        #expect(abs(white.y - 1) < 1e-12)
        #expect(abs(white.x / white.sum() - 0.3127) < 1e-3)
        #expect(abs(white.y / white.sum() - 0.3290) < 1e-3)
    }

    /// The four-decimal IEC matrix alone leaves D65 within 3e-4 of white, so the per-channel
    /// normalisation corrects rounding and could not hide a wrong matrix. With it, a perfect
    /// reflector is white to rounding.
    @Test func perfectReflectorIsExactlyWhite() {
        let published = MercurySpectral.linearSRGB(xyz: MercurySpectral.whitePoint)
        #expect(Self.largestDeviation(of: published, from: 1) < 3e-4)

        let mirror = MercurySpectral.linearSRGB { _ in 1 }
        #expect(Self.largestDeviation(of: mirror, from: 1) < 1e-12)
    }

    /// The retired constants were Inagaki's data at 610, 550 and 460 nm, the dominant
    /// wavelengths of the sRGB primaries (611, 549 and 464 nm) rounded to 10 nm. Red and green
    /// reproduce to the tabulated digit, blue within 0.25 %.
    @Test func resampledMercuryReproducesTheRetiredThreeWavelengthConstants() {
        let retired: [(wavelength: Double, refraction: Double, extinction: Double)] = [
            (610, 1.85901, 5.0793),
            (550, 1.55229, 4.65101),
            (460, 1.11003, 3.94276),
        ]
        for constant in retired {
            let offset = (constant.wavelength - MercurySpectral.firstWavelength) / MercurySpectral.wavelengthStep
            let index = Int(offset)
            #expect(Double(index) == offset)
            #expect(abs(MercurySpectral.mercuryRefraction[index] / constant.refraction - 1) < 0.03)
            #expect(abs(MercurySpectral.mercuryExtinction[index] / constant.extinction - 1) < 0.03)
        }
    }

    /// Integration keeps mercury's neutral mirror: the spectral `F₀` is (0.7814, 0.7795,
    /// 0.7784), against the retired three-sample (0.7811, 0.7794, 0.7780).
    @Test func spectralNormalIncidenceKeepsMercurysNeutralF0() {
        let normal = MercurySpectral.linearSRGBReflectance(cosine: 1)
        #expect(normal.max() - normal.min() < 0.02)
        #expect(normal.min() >= 0.74)
        #expect(normal.max() <= 0.82)
    }

    /// Past the principal angle, where `R_p` bottoms out (`μ` ≈ 0.20 for red, 0.32 for blue),
    /// the reflectance climbs monotonically toward grazing and reaches exactly 1 at `μ = 0`.
    @Test func grazingReflectanceRisesMonotonicallyToOne() {
        let cosines = [0.15, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 1e-4]
        let values = cosines.map { MercurySpectral.linearSRGBReflectance(cosine: $0) }
        for (nearer, farther) in zip(values.dropFirst(), values) {
            #expect((nearer - farther).min() > 0)
        }
        #expect(MercurySpectral.linearSRGBReflectance(cosine: 1e-4).min() > 0.999)

        let grazing = MercurySpectral.linearSRGBReflectance(cosine: 0)
        #expect(Self.largestDeviation(of: grazing, from: 1) < 1e-12)
    }

    /// The real-valued algebra is the complex amplitude form `r_s = (μ − w)/(μ + w)`,
    /// `r_p = (η²μ − w)/(η²μ + w)`, `w = √(η² − s²)`, evaluated here independently in complex
    /// arithmetic for weakly, mercury-like and strongly absorbing indices.
    @Test func fresnelAlgebraIsTheComplexAmplitudeForm() {
        for n in [0.2, 0.77, 1.5, 2.8] {
            for k in [0.5, 3.2, 6.1] {
                for cosine in [1, 0.7, 0.3, 0.1, 0.01] {
                    let algebra = MercurySpectral.reflectance(n: n, k: k, cosine: cosine)
                    let amplitudes = Self.complexFresnel(n: n, k: k, cosine: cosine)
                    #expect(abs(algebra - amplitudes) < 1e-12)
                }
            }
        }
    }

    /// `MercuryOptics` tables exactly this integral, and its gamut clamp never binds for
    /// mercury, so the 10,001-cosine lookup bound in `MercuryPresentationPerformanceTests`
    /// is a bound against the spectrum.
    @Test func opticsOracleIsTheSpectralIntegral() {
        for index in 0...100 {
            let cosine = Double(index) / 100
            let spectral = MercurySpectral.linearSRGBReflectance(cosine: cosine)
            #expect(MercuryOptics.exactFresnel(cosine: cosine) == spectral)
        }
    }

    private static func integral(_ samples: [Double]) -> Double {
        samples.indices.reduce(0.0) { sum, index in
            sum + MercurySpectral.trapezoidWeight(index) * samples[index]
        }
    }

    private static func largestDeviation(of value: SIMD3<Double>, from target: Double) -> Double {
        let difference = value - SIMD3(repeating: target)
        return Swift.max(abs(difference.x), abs(difference.y), abs(difference.z))
    }

    private static func complexFresnel(n: Double, k: Double, cosine: Double) -> Double {
        let eta = Complex(real: n, imaginary: k)
        let etaSquared = eta * eta
        let incidence = Complex(real: cosine, imaginary: 0)
        let root = (etaSquared - Complex(real: 1 - cosine * cosine, imaginary: 0)).squareRoot()
        let perpendicular = (incidence - root) / (incidence + root)
        let parallel = (etaSquared * incidence - root) / (etaSquared * incidence + root)
        return (perpendicular.magnitudeSquared + parallel.magnitudeSquared) / 2
    }

    private struct Complex {
        var real: Double
        var imaginary: Double

        var magnitudeSquared: Double { real * real + imaginary * imaginary }

        /// Principal branch, written so neither component is a difference of near-equal terms.
        func squareRoot() -> Complex {
            let modulus = magnitudeSquared.squareRoot()
            if real >= 0 {
                let root = ((modulus + real) / 2).squareRoot()
                return Complex(real: root, imaginary: imaginary / (2 * root))
            }
            let root = ((modulus - real) / 2).squareRoot()
            return Complex(real: abs(imaginary) / (2 * root), imaginary: imaginary < 0 ? -root : root)
        }

        static func + (lhs: Complex, rhs: Complex) -> Complex {
            Complex(real: lhs.real + rhs.real, imaginary: lhs.imaginary + rhs.imaginary)
        }

        static func - (lhs: Complex, rhs: Complex) -> Complex {
            Complex(real: lhs.real - rhs.real, imaginary: lhs.imaginary - rhs.imaginary)
        }

        static func * (lhs: Complex, rhs: Complex) -> Complex {
            Complex(
                real: lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
                imaginary: lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
            )
        }

        static func / (lhs: Complex, rhs: Complex) -> Complex {
            let denominator = rhs.magnitudeSquared
            return Complex(
                real: (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
                imaginary: (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
            )
        }
    }
}
