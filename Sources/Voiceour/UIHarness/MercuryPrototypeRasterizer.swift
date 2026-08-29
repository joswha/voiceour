#if UI_HARNESS

    import CoreGraphics
    import Foundation
    @MainActor
    protocol MercuryRadianceSource: AnyObject {
        func radianceRGB(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float>
    }

    extension MercuryEnvironment: MercuryRadianceSource {
        func radianceRGB(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
            radiance(direction, roughness: roughness)
        }
    }

    extension RoomOfTenWorld: MercuryRadianceSource {
        func radianceRGB(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
            radiance(direction, roughness: Double(roughness))
        }
    }

    /// Isolated candidate renderer. It shares the shipping field, simulation,
    /// environment and conductor constants, but none of its shading reaches the app.
    /// `make ui-mercury` compares it beside the shipping rasterizer before any cutover.
    @MainActor
    final class MercuryPrototypeRasterizer {
        private struct Pixel {
            var scene: SIMD3<Double>
            var coverage: Double
            var reflection: SIMD3<Double>
        }

        private var context: CGContext?
        private var scale: CGFloat = 0

        /// One response for a session's room, measured over both live poses.
        func response(
            fields: [MercuryField],
            environment: any MercuryRadianceSource,
            scale: CGFloat
        ) -> MercuryDisplayResponse? {
            var samples: [Double] = []
            for field in fields {
                for pixel in shade(field: field, environment: environment, scale: scale)
                where pixel.coverage > 0.5 {
                    samples.append(MercuryDisplayResponse.luminance(pixel.scene))
                }
            }
            samples.sort()
            guard samples.count > 100 else { return nil }
            let median = samples[samples.count / 2]
            let highlight = samples[Swift.min(samples.count - 1, samples.count * 98 / 100)]
            return MercuryDisplayResponse.solve(
                sceneMedian: median,
                sceneHighlight: highlight,
                medianTarget: MercuryMetrics.targetDisplayLuminance,
                highlightTarget: MercuryMetrics.targetHighlightLuminance,
                ceiling: MercuryMetrics.displayCeiling
            )
        }

        func image(
            field: MercuryField,
            environment: any MercuryRadianceSource,
            response: MercuryDisplayResponse,
            scale: CGFloat
        ) -> CGImage? {
            guard let context = context(for: scale), let data = context.data else { return nil }
            let width = context.width
            let height = context.height
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            memset(data, 0, context.bytesPerRow * height)
            let pixels = shade(field: field, environment: environment, scale: scale)
            guard pixels.count == width * height else { return nil }
            for index in 0..<pixels.count {
                let pixel = pixels[index]
                guard pixel.coverage > 0 else { continue }
                let display = response.map(pixel.scene)
                let alpha = pixel.coverage
                let offset = index * 4
                bytes[offset] = Self.byte(Self.encodeSRGB(display.x) * alpha)
                bytes[offset + 1] = Self.byte(Self.encodeSRGB(display.y) * alpha)
                bytes[offset + 2] = Self.byte(Self.encodeSRGB(display.z) * alpha)
                bytes[offset + 3] = Self.byte(alpha)
            }
            return context.makeImage()
        }

        func luminance(
            field: MercuryField,
            environment: any MercuryRadianceSource,
            response: MercuryDisplayResponse,
            scale: CGFloat
        ) -> [Double] {
            shade(field: field, environment: environment, scale: scale)
                .filter { $0.coverage > 0.5 }
                .map { MercuryDisplayResponse.luminance(response.map($0.scene)) }
        }

        func displaySamples(
            field: MercuryField,
            environment: any MercuryRadianceSource,
            response: MercuryDisplayResponse,
            scale: CGFloat
        ) -> [SIMD3<Double>] {
            shade(field: field, environment: environment, scale: scale)
                .filter { $0.coverage > 0.5 }
                .map { response.map($0.scene) }
        }

        func reflectedDirections(
            field: MercuryField,
            scale: CGFloat
        ) -> [SIMD3<Double>] {
            shade(field: field, environment: MercuryBlackRoom(), scale: scale)
                .filter { $0.coverage > 0.5 }
                .map(\.reflection)
        }

        // MARK: - Candidate shading

        private func shade(
            field: MercuryField,
            environment: any MercuryRadianceSource,
            scale: CGFloat
        ) -> [Pixel] {
            let width = Int((RecordingOverlayMetrics.islandSize.width * scale).rounded())
            let height = Int((RecordingOverlayMetrics.islandSize.height * scale).rounded())
            let bounds = MercuryField.islandBounds
            let pixelSize = 1 / Double(scale)
            let epsilon = 0.25 * pixelSize
            let length = Swift.max(field.length, 1)
            var result = [Pixel](
                repeating: Pixel(scene: .zero, coverage: 0, reflection: .zero),
                count: width * height
            )

            for row in 0..<height {
                let vertical = Double(bounds.maxY) - (Double(row) + 0.5) * pixelSize
                for columnIndex in 0..<width {
                    let horizontal = Double(bounds.minX) + (Double(columnIndex) + 0.5) * pixelSize
                    let bodyX = horizontal - field.lateralOffset
                    let column = field.column(atX: bodyX)
                    guard column.radius > 0 else { continue }
                    let offset = vertical - column.center
                    let distance =
                        column.inSpan
                        ? abs(offset)
                        : (column.capOffset * column.capOffset + offset * offset).squareRoot()
                    let signedDistance = column.radius - distance
                    let (fieldX, fieldY) = MercuryField.gradient(
                        column: column,
                        vertical: offset,
                        length: length
                    )
                    let fieldGradient = SIMD2<Double>(fieldX, fieldY)
                    let gradientLength = (fieldGradient * fieldGradient).sum().squareRoot()
                    guard gradientLength > 1e-9 else { continue }
                    let coverage = Swift.min(
                        Swift.max(0.5 + signedDistance / (gradientLength * pixelSize), 0),
                        1
                    )
                    guard coverage > 0 else { continue }

                    let crown = MercuryCrown.evaluate(
                        field: signedDistance,
                        radius: column.radius,
                        aspect: 0.78,
                        epsilon: epsilon
                    )
                    let radiusGradient =
                        column.inSpan
                        ? SIMD2<Double>(column.radiusSlope / length, 0)
                        : .zero
                    let crownGradient = crown.gradient(
                        fieldGradient: fieldGradient,
                        radiusGradient: radiusGradient
                    )
                    let normal = Self.normalize(
                        SIMD3(-crownGradient.x, -crownGradient.y, 1)
                    )
                    let view = Self.normalize(
                        SIMD3(-horizontal, -vertical, MercuryMetrics.eyeDistance - crown.height)
                    )
                    let incidence = Swift.max((normal * view).sum(), 1e-4)
                    let reflected = 2 * incidence * normal - view
                    let direction = SIMD3<Float>(
                        Float(reflected.x),
                        Float(reflected.y),
                        Float(reflected.z)
                    )
                    // Smooth mercury. The table's own band limit supplies the pixel
                    // footprint; no independently animated plate or outline branch.
                    let room = environment.radianceRGB(
                        direction,
                        roughness: Float(MercuryMetrics.baseRoughness)
                    )
                    let roomRGB = SIMD3<Double>(
                        Double(room.x), Double(room.y), Double(room.z)
                    )
                    result[row * width + columnIndex] = Pixel(
                        scene: roomRGB * Self.fresnel(cosine: incidence),
                        coverage: coverage,
                        reflection: reflected
                    )
                }
            }
            return result
        }

        // MARK: - Storage and optics

        private func context(for scale: CGFloat) -> CGContext? {
            if let context, self.scale == scale { return context }
            let width = Int((RecordingOverlayMetrics.islandSize.width * scale).rounded())
            let height = Int((RecordingOverlayMetrics.islandSize.height * scale).rounded())
            guard
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            self.context = context
            self.scale = scale
            return context
        }

        @inline(__always)
        private static func fresnel(cosine: Double) -> SIMD3<Double> {
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
            let third = cosineSquared * squares + SIMD3<Double>(repeating: sineSquared * sineSquared)
            let fourth = second * sineSquared
            let parallel = perpendicular * (third - fourth) / (third + fourth)
            return (perpendicular + parallel) / 2
        }

        @inline(__always)
        private static func normalize(_ value: SIMD3<Double>) -> SIMD3<Double> {
            let length = (value * value).sum().squareRoot()
            return length > 1e-12 ? value / length : SIMD3(0, 0, 1)
        }

        @inline(__always)
        private static func encodeSRGB(_ value: Double) -> Double {
            let clamped = Swift.min(Swift.max(value, 0), 1)
            return clamped <= 0.003_130_8
                ? 12.92 * clamped
                : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }

        @inline(__always)
        private static func byte(_ value: Double) -> UInt8 {
            UInt8(Swift.min(255, Swift.max(0, (value * 255).rounded())))
        }
    }

    @MainActor
    private final class MercuryBlackRoom: MercuryRadianceSource {
        func radianceRGB(_ direction: SIMD3<Float>, roughness: Float) -> SIMD3<Float> {
            .zero
        }
    }

#endif
