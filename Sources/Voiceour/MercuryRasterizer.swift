import CoreGraphics
import Foundation

/// Accessibility state the opaque body renders against.
struct MercuryAppearance: Equatable {
    var increasedContrast: Bool

    static let standard = MercuryAppearance(increasedContrast: false)
}

/// CPU rasterizer for the one procedural mercury body.
///
/// The scalar field remains the sole coverage and hit-test oracle. Its sampled radius
/// also lifts a fixed-aspect half-elliptic crown whose exact total gradient supplies the
/// surface normal. A static generated RGB room, exact conductor Fresnel and a bounded
/// two-anchor response complete the material; no highlight, rim or gradient is authored.
@MainActor
final class MercuryRasterizer {
    private var context: CGContext?
    private var columns: UnsafeMutablePointer<MercuryField.Column>?
    private var columnCapacity = 0
    private var scale: CGFloat = 0

    deinit {
        columns?.deallocate()
    }

    func image(
        field: MercuryField,
        environment: MercuryEnvironment,
        response: MercuryDisplayResponse,
        appearance: MercuryAppearance,
        scale: CGFloat
    ) -> CGImage? {
        guard let context = context(for: scale) else { return nil }
        var samples: [SIMD3<Float>]?
        render(
            field: field,
            environment: environment,
            response: response,
            appearance: appearance,
            context: context,
            samples: &samples
        )
        return context.makeImage()
    }

    /// Linear `environment × conductor Fresnel` samples before the display response.
    /// Calibration pools these over listening and speaking, then solves two anchors once.
    func sampleSceneRadiance(
        field: MercuryField,
        environment: MercuryEnvironment,
        scale: CGFloat
    ) -> [SIMD3<Float>] {
        guard let context = context(for: scale) else { return [] }
        var samples: [SIMD3<Float>]? = []
        render(
            field: field,
            environment: environment,
            response: nil,
            appearance: .standard,
            context: context,
            samples: &samples
        )
        return samples ?? []
    }

    // MARK: - Storage

    private func context(for scale: CGFloat) -> CGContext? {
        if let context, self.scale == scale { return context }
        let width = Int((RecordingOverlayMetrics.islandSize.width * scale).rounded())
        let height = Int((RecordingOverlayMetrics.islandSize.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        guard
            let created = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context = created
        self.scale = scale
        if columnCapacity < width {
            columns?.deallocate()
            columns = UnsafeMutablePointer<MercuryField.Column>.allocate(capacity: width)
            columnCapacity = width
        }
        return created
    }

    // MARK: - Render

    private func render(
        field: MercuryField,
        environment: MercuryEnvironment,
        response: MercuryDisplayResponse?,
        appearance: MercuryAppearance,
        context: CGContext,
        samples: inout [SIMD3<Float>]?
    ) {
        guard let data = context.data, let columns else { return }
        let width = context.width
        let height = context.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        memset(data, 0, context.bytesPerRow * height)

        let box = field.boundingBox
        guard box.width > 0, box.height > 0 else { return }
        let bounds = MercuryField.islandBounds
        let pixelSize = 1 / Double(scale)
        let epsilon = MercuryMetrics.crownFilterFraction * pixelSize
        let firstColumn = Swift.max(
            0,
            Int(((box.minX - bounds.minX) * scale).rounded(.down))
        )
        let lastColumn = Swift.min(
            width - 1,
            Int(((box.maxX - bounds.minX) * scale).rounded(.up))
        )
        let firstRow = Swift.max(
            0,
            Int(((bounds.maxY - box.maxY) * scale).rounded(.down))
        )
        let lastRow = Swift.min(
            height - 1,
            Int(((bounds.maxY - box.minY) * scale).rounded(.up))
        )
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }

        let horizontalOffset = field.lateralOffset
        for column in firstColumn...lastColumn {
            let position = Double(bounds.minX) + (Double(column) + 0.5) * pixelSize
            columns[column] = field.column(atX: position - horizontalOffset)
        }

        let length = Swift.max(field.length, 1)
        let collecting = samples != nil
        let displayResponse = response.map { response in
            guard appearance.increasedContrast else { return response }
            return response.remapped(
                medianTarget: MercuryMetrics.increasedContrastMedian,
                highlightTarget: MercuryMetrics.increasedContrastHighlight
            ) ?? response
        }
        for row in firstRow...lastRow {
            let vertical = Double(bounds.maxY) - (Double(row) + 0.5) * pixelSize
            for columnIndex in firstColumn...lastColumn {
                let column = columns[columnIndex]
                guard column.radius > 0 else { continue }
                let horizontal =
                    Double(bounds.minX)
                    + (Double(columnIndex) + 0.5) * pixelSize
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
                if collecting, coverage <= 0.5 { continue }

                let crown = MercuryCrown.evaluate(
                    field: signedDistance,
                    radius: column.radius,
                    aspect: MercuryMetrics.crownAspect,
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
                    SIMD3(
                        -horizontal,
                        -vertical,
                        MercuryMetrics.eyeDistance - crown.height
                    )
                )
                let incidence = Swift.max((normal * view).sum(), 1e-4)
                let reflected = 2 * incidence * normal - view
                let room = environment.radiance(
                    SIMD3<Float>(
                        Float(reflected.x),
                        Float(reflected.y),
                        Float(reflected.z)
                    ),
                    roughness: Float(MercuryMetrics.baseRoughness)
                )
                let scene =
                    SIMD3<Double>(
                        Double(room.x), Double(room.y), Double(room.z)
                    ) * Self.fresnel(cosine: incidence)

                if collecting {
                    samples?.append(
                        SIMD3<Float>(Float(scene.x), Float(scene.y), Float(scene.z))
                    )
                    continue
                }
                guard let displayResponse else { continue }
                let display = displayResponse.map(scene)
                let index = (row * width + columnIndex) * 4
                bytes[index] = Self.byte(Self.encodeSRGB(display.x) * coverage)
                bytes[index + 1] = Self.byte(Self.encodeSRGB(display.y) * coverage)
                bytes[index + 2] = Self.byte(Self.encodeSRGB(display.z) * coverage)
                bytes[index + 3] = Self.byte(coverage)
            }
        }
    }

    // MARK: - Optics and display

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
        let third =
            cosineSquared * squares
            + SIMD3<Double>(repeating: sineSquared * sineSquared)
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
