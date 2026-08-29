#if UI_HARNESS

    import Foundation

    /// A static, parameterized SG room for isolated material search.
    ///
    /// Source draws are stratified and bounded. The same seed gives the same source axes,
    /// quantiles and signs for every parameter set, so a contact-sheet sweep changes one
    /// variable at a time rather than comparing unrelated rooms.
    @MainActor
    final class MercuryPrototypeRoom: MercuryRadianceSource {
        struct Parameters: Hashable, Sendable {
            var sourceCount: Int
            var minimumSharpness: Double
            var maximumSharpness: Double
            var intensitySpread: Double
            var bounceFraction: Double
            /// Maximum luminance-free channel excursion around neutral.
            var chromaStrength: Double = 0

            var label: String {
                [
                    "M\(sourceCount)",
                    "λ\(Int(minimumSharpness))-\(Int(maximumSharpness))",
                    "σ\(intensitySpread)",
                    "b\(bounceFraction)",
                    "c\(chromaStrength)",
                ].joined(separator: " ")
            }
        }

        private struct Source {
            var axis: SIMD3<Double>
            var sharpness: Double
            var intensity: Double
            var chromaCoefficient: Double
            var tint: SIMD3<Double>
        }

        let parameters: Parameters
        private let sources: [Source]
        private let bounce: Double
        init(seed: UInt64, parameters: Parameters) {
            self.parameters = parameters
            let noise = MercuryNoise(seed: seed)
            let logMinimum = log(parameters.minimumSharpness)
            let logMaximum = log(parameters.maximumSharpness)
            var sources: [Source] = []
            sources.reserveCapacity(parameters.sourceCount)
            for index in 0..<parameters.sourceCount {
                let counter = UInt64(index)
                // Exact equal-area z strata. Azimuth and scale remain seed-random.
                let band = noise.uniform(stream: MercuryNoiseStream.roomLobes, counter: counter &* 3)
                let azimuthDraw = noise.uniform(
                    stream: MercuryNoiseStream.roomLobes,
                    counter: counter &* 3 &+ 1
                )
                let sharpnessDraw = noise.uniform(
                    stream: MercuryNoiseStream.roomLobes,
                    counter: counter &* 3 &+ 2
                )
                let height = -1 + 2 * (Double(index) + band) / Double(parameters.sourceCount)
                let radius = Swift.max(0, 1 - height * height).squareRoot()
                let azimuth = 2 * Double.pi * azimuthDraw
                // A bounded quantile map, not an unbounded lognormal tail. The exponent
                // keeps all sources positive while limiting the largest to exp(σ).
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
                        axis: SIMD3(radius * cos(azimuth), radius * sin(azimuth), height),
                        sharpness: exp(logMinimum + sharpnessDraw * (logMaximum - logMinimum)),
                        intensity: exp(parameters.intensitySpread * intensityDraw),
                        chromaCoefficient: chromaDraw,
                        tint: .one
                    )
                )
            }
            let sourceMean = sources.reduce(0.0) { total, source in
                total + Self.power(of: source)
            }
            let chromaMean =
                sources.reduce(0.0) { total, source in
                    total + Self.power(of: source) * source.chromaCoefficient
                } / Swift.max(sourceMean, 1e-12)
            let maximumChroma = sources.reduce(0.0) { maximum, source in
                Swift.max(maximum, abs(source.chromaCoefficient - chromaMean))
            }
            let opponent = Self.opponent(noise: noise)
            let sourceShare = 1 - parameters.bounceFraction
            self.sources = sources.map { source in
                let coefficient =
                    (source.chromaCoefficient - chromaMean)
                    / Swift.max(maximumChroma, 1e-12)
                return Source(
                    axis: source.axis,
                    sharpness: source.sharpness,
                    intensity: source.intensity * sourceShare / Swift.max(sourceMean, 1e-12),
                    chromaCoefficient: coefficient,
                    tint: SIMD3<Double>(repeating: 1)
                        + parameters.chromaStrength * coefficient * opponent
                )
            }
            bounce = parameters.bounceFraction
        }

        func radianceRGB(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
            let vector = SIMD3<Double>(
                Double(direction.x),
                Double(direction.y),
                Double(direction.z)
            )
            let alpha = Double(roughness)
            var value = SIMD3<Double>(repeating: bounce)
            for source in sources {
                let filtered = source.sharpness / (1 + source.sharpness * alpha * alpha)
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

        private static func power(of source: Source) -> Double {
            source.intensity * (1 - exp(-2 * source.sharpness))
                / (2 * source.sharpness)
        }

        /// Seed-random opponent projected onto the Rec.709 luminance-null plane.
        private static func opponent(noise: MercuryNoise) -> SIMD3<Double> {
            let random = noise.unitVector(stream: MercuryNoiseStream.roomChroma, counter: 10_000)
            let luminance = SIMD3<Double>(0.2126, 0.7152, 0.0722)
            let projected =
                random
                - luminance * ((random * luminance).sum() / (luminance * luminance).sum())
            let scale = Swift.max(abs(projected.x), Swift.max(abs(projected.y), abs(projected.z)))
            return projected / Swift.max(scale, 1e-12)
        }
    }

#endif
