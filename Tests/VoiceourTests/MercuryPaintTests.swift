import Foundation
import Testing
import VoiceCore

@testable import Voiceour

/// The paint table is the only material term the rasterizer evaluates per pixel. Stock must
/// remain the shipped table bit for bit; every other paint must integrate through the stock
/// conductor's observer, track its exact spectral oracle, and read as the metal or coat it
/// names.
struct MercuryPaintTests {
    private static let candyRed = MercuryColor.linearRGB(hue: 355, saturation: 90, brightness: 80)

    /// Rebuilds the shipped Fresnel table: the same 1,024 cosines through the spectral oracle,
    /// each channel rounded to `Float`. The stock oracle is that function itself.
    @Test func stockLookupStoresTheSpectralOracleTableBitForBit() {
        let stock = MercuryPaintLookup.stock
        #expect(MercuryPaintLookup.count == 1_024)
        #expect(MercuryPaintLookup.minimumCosine == 1e-4)
        #expect(stock.paint == .stock)
        var mismatches = 0
        for index in 0..<1_024 {
            let cosine = 1e-4 + (1 - 1e-4) * Double(index) / Double(1_024 - 1)
            let exact = MercuryOptics.exactFresnel(cosine: cosine)
            let expected = SIMD3(Float(exact.x), Float(exact.y), Float(exact.z))
            let stored = stock.entry(index)
            if stored.x.bitPattern != expected.x.bitPattern
                || stored.y.bitPattern != expected.y.bitPattern
                || stored.z.bitPattern != expected.z.bitPattern
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)

        let oracle = MercuryPaint.Oracle(.stock)
        for index in 0...100 {
            let cosine = Double(index) / 100
            #expect(oracle.reflectance(cosine: cosine) == MercuryOptics.exactFresnel(cosine: cosine))
        }
    }

    /// Every read of liquid mercury — the table a frame takes, the lookup's own and
    /// `MercuryOptics.fresnel(cosine:)` — is the shipped lookup bit for bit: the clamped
    /// cosine's two nodes, mixed in `Float` by its fraction between them. The shipped table and
    /// that arithmetic are rebuilt here from the oracle and compared at every node, between
    /// the nodes, and clamped outside the table at both ends.
    @Test func stockReadsAreTheShippedLerpBitForBit() {
        let count = 1_024
        let minimum = 1e-4
        let nodes = (0..<count).map { index in
            let exact = MercuryOptics.exactFresnel(
                cosine: minimum + (1 - minimum) * Double(index) / Double(count - 1)
            )
            return SIMD3(Float(exact.x), Float(exact.y), Float(exact.z))
        }
        func shipped(_ cosine: Double) -> SIMD3<Double> {
            let clamped = Swift.min(Swift.max(cosine, minimum), 1)
            let scaled = (clamped - minimum) * Double(count - 1) / (1 - minimum)
            let lower = Int(scaled)
            let upper = Swift.min(lower + 1, count - 1)
            let fraction = Float(scaled - Double(lower))
            let value = nodes[lower] + (nodes[upper] - nodes[lower]) * fraction
            return SIMD3(Double(value.x), Double(value.y), Double(value.z))
        }
        func bits(_ value: SIMD3<Double>) -> SIMD3<UInt64> {
            SIMD3(value.x.bitPattern, value.y.bitPattern, value.z.bitPattern)
        }

        let stock = MercuryPaintLookup.stock
        let table = stock.table
        let cosines =
            (0..<count).map(MercuryPaintLookup.cosine(at:))
            + (0...20_000).map { -0.05 + 1.1 * Double($0) / 20_000 }
            + [-1, 0, 1e-4, 1, 2]
        var mismatches = 0
        for cosine in cosines {
            let expected = bits(shipped(cosine))
            for read in [
                table.fresnel(cosine: cosine),
                stock.fresnel(cosine: cosine),
                MercuryOptics.fresnel(cosine: cosine),
            ] where bits(read) != expected {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    /// Paints integrate on the stock conductor's grid through its observer, whose CIE
    /// weights sum to white; a spectrally flat reflector through the paint path is therefore
    /// exactly neutral.
    @Test func paintsShareTheStockObserver() {
        let weights = MercurySpectral.channelWeights
        #expect(weights.count == MercurySpectral.sampleCount)
        let total = weights.reduce(SIMD3<Double>.zero, +)
        #expect(Self.distance(total, SIMD3(repeating: 1)) < 1e-12)
        #expect(MercurySpectra.wavelength(0) == 380)
        #expect(MercurySpectra.wavelength(MercurySpectral.sampleCount - 1) == 780)

        // A dispersionless dielectric reflects ((n − 1)/(n + 1))² = 0.04 at every wavelength.
        let glass = MercuryOpticalStack(films: [], substrate: .constant(n: 1.5, k: 0))
        #expect(Self.distance(glass.rgb(cosine: 1), SIMD3(repeating: 0.04)) < 1e-12)
    }

    /// The tabulated rows are the datasets' own rows, so interpolating them linearly at 610,
    /// 550 and 460 nm reproduces the full refractiveindex.info tables. Platinum's rows
    /// resample a Lorentz–Drude model; its normal-incidence colour is covered elsewhere.
    @Test func tabulatedMetalsReproduceTheirDatasets() {
        let anchors: [IslandMetal: [Double]] = [
            .silver: [0.058040, 4.094386, 0.059582, 3.597367, 0.044439, 2.751107],
            .gold: [0.225677, 3.191850, 0.424149, 2.472051, 1.348927, 1.885146],
            .copper: [0.378386, 3.106821, 1.006627, 2.582307, 1.244439, 2.435176],
            .aluminum: [1.314341, 7.295734, 1.015192, 6.627283, 0.668431, 5.574838],
            .titanium: [2.656000, 3.692000, 2.541818, 3.434545, 2.292500, 3.067000],
            .chromium: [3.180000, 3.300000, 3.181212, 3.329091, 2.411000, 3.185000],
        ]
        let samples = [46, 34, 16]
        #expect(samples.map(MercurySpectra.wavelength) == [610, 550, 460])
        for (metal, values) in anchors {
            for (position, sample) in samples.enumerated() {
                let index = MercurySpectra.refractiveIndex(of: .metal(metal), sample: sample)
                let label = "\(metal) at \(MercurySpectra.wavelength(sample)) nm"
                #expect(abs(index.n - values[2 * position]) < 1e-6, "\(label)")
                #expect(abs(index.k - values[2 * position + 1]) < 1e-6, "\(label)")
            }
        }
    }

    /// Mercury under a coat stands on the stock conductor's own data: `MercurySpectral`'s
    /// table, sample for sample.
    @Test func mercurySubstrateIsTheStockOraclesTable() {
        for sample in 0..<MercurySpectral.sampleCount {
            let index = MercurySpectra.refractiveIndex(of: .metal(.mercury), sample: sample)
            #expect(index.n == MercurySpectral.mercuryRefraction[sample], "sample \(sample)")
            #expect(index.k == MercurySpectral.mercuryExtinction[sample], "sample \(sample)")
        }
    }

    @Test func filmDispersionMatchesThePublishedIndices() {
        let sample = 34
        #expect(MercurySpectra.wavelength(sample) == 550)
        let titania = MercurySpectra.refractiveIndex(of: .titania, sample: sample)
        let silica = MercurySpectra.refractiveIndex(of: .silica, sample: sample)
        #expect(abs(titania.n - 2.438) < 1e-3)
        #expect(titania.k == 0)
        #expect(abs(silica.n - 1.460) < 1e-3)
        #expect(silica.k == 0)
    }

    /// Reduced to one interface, the complex Airy machinery is `MercurySpectral.reflectance`,
    /// the closed-form conductor Fresnel behind the stock oracle: both polarization
    /// conventions agree with it at every sample of every metal.
    @Test(arguments: IslandMetal.allCases)
    func oneInterfaceReproducesTheClosedFormConductor(metal: IslandMetal) {
        let surface = MercuryOpticalStack(films: [], substrate: .metal(metal))
        var worst = 0.0
        for sample in 0..<MercurySpectral.sampleCount {
            let index = MercurySpectra.refractiveIndex(of: .metal(metal), sample: sample)
            for step in 0...200 {
                let cosine = 1e-4 + (1 - 1e-4) * Double(step) / 200
                let closed = MercurySpectral.reflectance(n: index.n, k: index.k, cosine: cosine)
                let airy = surface.reflectance(cosine: cosine, sample: sample)
                worst = Swift.max(worst, abs(airy - closed))
            }
        }
        #expect(worst < 1e-12)
    }

    /// Same data, same observer: bare mercury through the paint path, and mercury under a
    /// vanishing coat through `MercuryPaint.Oracle`, are the stock oracle.
    @Test func bareSpectralMercuryIsTheStockOracle() {
        let bare = MercuryOpticalStack(films: [], substrate: .metal(.mercury))
        let vanishing = MercuryPaint.Oracle(
            MercuryPaint(
                metal: .mercury,
                coat: .pearl,
                filmNanometers: 0,
                candy: SIMD3(repeating: 1)
            )
        )
        var worst = 0.0
        for index in 0...1_000 {
            let cosine = 1e-4 + (1 - 1e-4) * Double(index) / 1_000
            let stock = MercuryOptics.exactFresnel(cosine: cosine)
            worst = Swift.max(
                worst,
                Self.distance(MercurySpectra.gamutFloor(bare.rgb(cosine: cosine)), stock),
                Self.distance(vanishing.reflectance(cosine: cosine), stock)
            )
        }
        #expect(worst < 1e-12)
    }

    /// A film of zero thickness, or of index 1 at any thickness, is no film at all; the
    /// two-film chameleon recursion collapses the same way.
    @Test(arguments: IslandMetal.allCases)
    func vanishingFilmsLeaveTheBareConductor(metal: IslandMetal) {
        let substrate = MercurySpectra.Material.metal(metal)
        let bare = MercuryOpticalStack(films: [], substrate: substrate)
        let stacks = [
            MercuryOpticalStack(
                films: [MercurySpectra.Layer(material: .titania, nanometers: 0)],
                substrate: substrate
            ),
            MercuryOpticalStack(
                films: [MercurySpectra.Layer(material: .constant(n: 1, k: 0), nanometers: 137)],
                substrate: substrate
            ),
            MercuryOpticalStack(
                films: [
                    MercurySpectra.Layer(material: .metal(.chromium), nanometers: 0),
                    MercurySpectra.Layer(material: .silica, nanometers: 0),
                ],
                substrate: substrate
            ),
        ]
        var worst = 0.0
        for index in 0...200 {
            let cosine = 1e-4 + (1 - 1e-4) * Double(index) / 200
            let bareRGB = bare.rgb(cosine: cosine)
            for stack in stacks {
                for sample in 0..<MercurySpectral.sampleCount {
                    let reference = bare.reflectance(cosine: cosine, sample: sample)
                    let layered = stack.reflectance(cosine: cosine, sample: sample)
                    worst = Swift.max(worst, abs(layered - reference))
                }
                let difference = stack.rgb(cosine: cosine) - bareRGB
                worst = Swift.max(worst, abs(difference.x), abs(difference.y), abs(difference.z))
            }
        }
        #expect(worst <= 1e-12)
    }

    /// Every catalogue coat on every metal stays finite, non-negative and within the table's
    /// interpolation bound of its exact oracle over 10,001 cosines. Linear interpolation
    /// across 1,024 nodes resolves what is wider than the 1e-3 node spacing: away from
    /// grazing, every bare metal, single film and lacquer tracks within 1e-4. Chameleon's
    /// cavity colour turns faster with angle, and the gamut floor bends it, so it gets 1e-3.
    /// Below μ = 0.01, a near-perfect reflector under a coat (silver) has a resonance
    /// narrower than one node; that outermost sliver of the silhouette gets 1e-2.
    @Test(arguments: IslandMetal.allCases, IslandCoat.allCases)
    func everyCoatLookupTracksItsSpectralOracle(metal: IslandMetal, coat: IslandCoat) {
        let paint = Self.catalogue(metal, coat)
        let lookup = MercuryPaintLookup.lookup(for: paint)
        let oracle = MercuryPaint.Oracle(paint)
        var body = 0.0
        var grazing = 0.0
        var valid = true
        for index in 0...10_000 {
            let cosine = 1e-4 + (1 - 1e-4) * Double(index) / 10_000
            let sampled = lookup.fresnel(cosine: cosine)
            let difference = sampled - oracle.reflectance(cosine: cosine)
            let error = Swift.max(abs(difference.x), abs(difference.y), abs(difference.z))
            if cosine < 0.01 {
                grazing = Swift.max(grazing, error)
            } else {
                body = Swift.max(body, error)
            }
            valid =
                valid
                && sampled.x.isFinite && sampled.y.isFinite && sampled.z.isFinite
                && sampled.min() >= 0
        }
        #expect(body <= (coat == .chameleon ? 1e-3 : 1e-4))
        #expect(grazing <= 1e-2)
        #expect(valid)
    }

    /// The floor gives up only saturation: inside the gamut it is the identity; outside, it
    /// keeps luminance and moves straight toward the colour's own grey, so its hue stays. On
    /// mercury it never acts, so the stock clamp and the floor agree there.
    @Test func gamutFloorKeepsLuminanceAndHue() {
        let inside = SIMD3<Double>(0.2, 0.5, 0.9)
        #expect(MercurySpectra.gamutFloor(inside) == inside)

        let outside = SIMD3<Double>(1.2, 0.3, -0.1)
        let floored = MercurySpectra.gamutFloor(outside)
        let luminance = MercuryDisplayResponse.luminance(outside)
        #expect(floored.min() >= 0)
        #expect(floored.min() < 1e-15)
        #expect(abs(MercuryDisplayResponse.luminance(floored) - luminance) < 1e-12)
        let grey = SIMD3<Double>(repeating: luminance)
        let scale = (floored.x - grey.x) / (outside.x - grey.x)
        #expect(scale > 0 && scale < 1)
        #expect(Self.distance(floored - grey, scale * (outside - grey)) < 1e-12)

        for index in 0...100 {
            let mercury = MercuryOptics.exactFresnel(cosine: Double(index) / 100)
            #expect(MercurySpectra.gamutFloor(mercury) == mercury)
        }
    }

    /// Warm moves toward red and cool toward blue, monotonically along the slider, and
    /// neither changes room luminance. The reference is the observer's own white: just off
    /// stock, the multiplier is neutral.
    @Test func whiteBalanceLeansWarmOrCoolAtUnitLuminance() throws {
        #expect(MercuryWhiteBalance.multipliers(temperature: 0) == nil)
        let nearStock = try #require(MercuryWhiteBalance.multipliers(temperature: 1e-6))
        #expect(Self.distance(nearStock, SIMD3(repeating: 1)) < 1e-5)
        var cooler: SIMD3<Double>?
        for temperature in [-1.0, -0.5, 0.5, 1.0] {
            let multipliers = try #require(
                MercuryWhiteBalance.multipliers(temperature: temperature)
            )
            #expect(abs(MercuryDisplayResponse.luminance(multipliers) - 1) < 1e-12)
            if temperature > 0 {
                #expect(multipliers.x > multipliers.z, "t = \(temperature)")
            } else {
                #expect(multipliers.z > multipliers.x, "t = \(temperature)")
            }
            if let cooler {
                #expect(multipliers.x > cooler.x, "t = \(temperature)")
                #expect(multipliers.z < cooler.z, "t = \(temperature)")
            }
            cooler = multipliers
        }
    }

    /// Spectral normal incidence reads as each metal: gold yellow-orange, copper rose,
    /// silver the brightest white, chrome a dark neutral.
    @Test func spectralNormalIncidenceReadsAsEachMetal() {
        func face(_ metal: IslandMetal) -> SIMD3<Double> {
            MercuryPaintLookup.lookup(
                for: MercuryPaint(
                    metal: metal,
                    coat: .none,
                    filmNanometers: 0,
                    candy: SIMD3(repeating: 1)
                )
            ).fresnel(cosine: 1)
        }
        let gold = face(.gold)
        #expect(gold.x > gold.y)
        #expect(gold.y > gold.z)
        let copper = face(.copper)
        #expect(copper.x > copper.z)
        #expect(face(.silver).min() > 0.95)
        let chromium = face(.chromium)
        #expect(chromium.min() >= 0.5)
        #expect(chromium.max() <= 0.6)
    }

    /// The metering anchor for stock is the shipped mercury's normal-incidence luminance:
    /// the spectral `F₀` (0.7814, 0.7795, 0.7784) weighs 0.7798.
    @Test func stockAlbedoIsTheShippedMercuryLuminance() {
        let stock = MercuryPaintLookup.stock
        #expect(abs(stock.albedo - 0.7798) <= 1e-4)
        let normal = stock.entry(MercuryPaintLookup.count - 1)
        let luminance = MercuryDisplayResponse.luminance(
            SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))
        )
        #expect(stock.albedo == luminance)
    }

    /// Clear coat is candy with a colourless dye, to the last bit.
    @Test(arguments: IslandMetal.allCases)
    func colourlessCandyIsExactlyClearCoat(metal: IslandMetal) {
        let colourless = SIMD3<Double>(repeating: 1)
        let clear = MercuryPaintLookup.lookup(
            for: MercuryPaint(metal: metal, coat: .clear, filmNanometers: 0, candy: colourless)
        )
        let candy = MercuryPaintLookup.lookup(
            for: MercuryPaint(metal: metal, coat: .candy, filmNanometers: 0, candy: colourless)
        )
        let mismatches = (0..<MercuryPaintLookup.count).filter {
            clear.entry($0) != candy.entry($0)
        }
        #expect(mismatches.isEmpty)
    }

    /// Candy red over any metal faces the viewer red: the dye absorbs green and blue on the
    /// round trip, leaving only the lacquer's own sheen in those channels.
    @Test func candyRedLacquerTransmitsRedAndAbsorbsBlue() {
        for metal in IslandMetal.allCases {
            let paint = MercuryPaint(
                metal: metal,
                coat: .candy,
                filmNanometers: 0,
                candy: Self.candyRed
            )
            let face = MercuryPaintLookup.lookup(for: paint).fresnel(cosine: 1)
            #expect(face.x > 4 * face.z, "\(metal)")
            #expect(face.x > 4 * face.y, "\(metal)")
        }
    }

    /// Fields a coat ignores never split its table, and uncoated mercury is stock itself.
    @Test func equivalentPaintsShareOneTable() {
        let uncoated = MercuryPaint(
            metal: .mercury,
            coat: .none,
            filmNanometers: 90,
            candy: Self.candyRed
        )
        #expect(uncoated.canonical == .stock)
        #expect(MercuryPaintLookup.lookup(for: uncoated) === MercuryPaintLookup.stock)
        let pearl = MercuryPaint(
            metal: .gold,
            coat: .pearl,
            filmNanometers: 90,
            candy: Self.candyRed
        )
        let expected = MercuryPaint(
            metal: .gold,
            coat: .pearl,
            filmNanometers: 90,
            candy: SIMD3(repeating: 1)
        )
        #expect(pearl.canonical == expected)
        #expect(MercuryPaintLookup.lookup(for: pearl).paint == expected)
    }

    /// User colours are HSB on the sRGB primaries, decoded to linear light.
    @Test func userColoursDecodeToLinearLight() {
        let white = MercuryColor.linearRGB(hue: 0, saturation: 0, brightness: 100)
        let red = MercuryColor.linearRGB(hue: 0, saturation: 100, brightness: 100)
        let green = MercuryColor.linearRGB(hue: 120, saturation: 100, brightness: 100)
        let blue = MercuryColor.linearRGB(hue: 240, saturation: 100, brightness: 100)
        let grey = MercuryColor.linearRGB(hue: 0, saturation: 0, brightness: 50)
        #expect(Self.distance(white, SIMD3(1, 1, 1)) < 1e-12)
        #expect(Self.distance(red, SIMD3(1, 0, 0)) < 1e-12)
        #expect(Self.distance(green, SIMD3(0, 1, 0)) < 1e-12)
        #expect(Self.distance(blue, SIMD3(0, 0, 1)) < 1e-12)
        #expect(Self.distance(grey, SIMD3(repeating: 0.214_041)) < 1e-6)
        let glow = MercuryColor.luminanceNormalized(
            MercuryColor.linearRGB(hue: 190, saturation: 80, brightness: 100)
        )
        #expect(abs(MercuryDisplayResponse.luminance(glow) - 1) < 1e-12)
    }

    /// The catalogue paint for one metal and coat: candy red, and each film coat at its
    /// stock thickness.
    private static func catalogue(_ metal: IslandMetal, _ coat: IslandCoat) -> MercuryPaint {
        let film: Int
        switch coat {
        case .none, .clear, .candy: film = 0
        case .pearl: film = 70
        case .anodized: film = 50
        case .oilSlick: film = 450
        case .chameleon: film = 350
        }
        return MercuryPaint(
            metal: metal,
            coat: coat,
            filmNanometers: film,
            candy: coat == .candy ? candyRed : SIMD3(repeating: 1)
        )
    }

    /// Largest channel difference.
    private static func distance(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>) -> Double {
        let difference = actual - expected
        return Swift.max(abs(difference.x), abs(difference.y), abs(difference.z))
    }
}
