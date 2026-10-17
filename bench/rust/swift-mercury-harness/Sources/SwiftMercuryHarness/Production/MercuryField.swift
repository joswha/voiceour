import CoreGraphics

/// The single evaluator that pixels, the drag predicate and the cursor region all read.
///
/// There is exactly one geometry representation in this app: the `top` and `bottom`
/// arrays the simulation emits. This type interpolates them; it never rebuilds them and
/// never keeps a second copy, which is what makes "the clickable region is the drawn
/// silhouette" a structural fact rather than something two code paths have to agree on.
///
/// Coordinates are island-local: origin at the island's centre, +y up, points.
struct MercuryField {
    /// Everything the shading of one pixel column needs, resolved once.
    struct Column {
        /// False beyond either end of the span, where the body is a full round cap.
        var inSpan: Bool
        /// `x - x_c`, zero inside the span.
        var capOffset: Double
        var radius: Double
        var center: Double
        /// Derivatives with respect to the material coordinate `a`.
        var radiusSlope: Double
        var centerSlope: Double
    }

    private let top: [Float]
    private let bottom: [Float]
    /// Read by the rasterizer's column pass, which needs the same two numbers the
    /// evaluator does and must not re-derive them.
    let length: Double
    let lateralOffset: Double
    /// Body extent inflated by `MercuryMetrics.bleed`, intersected with the island.
    let boundingBox: CGRect

    init(geometry: MercurySimulation.Geometry, lateralOffset: CGFloat) {
        top = geometry.top
        bottom = geometry.bottom
        length = Double(geometry.length)
        self.lateralOffset = Double(lateralOffset)

        var highest = -Double.greatestFiniteMagnitude
        var lowest = Double.greatestFiniteMagnitude
        for index in 0..<top.count {
            highest = Swift.max(highest, Double(top[index]))
            lowest = Swift.min(lowest, Double(bottom[index]))
        }
        let leadCap = (Double(top[0]) - Double(bottom[0])) / 2
        let trailCap = (Double(top[top.count - 1]) - Double(bottom[bottom.count - 1])) / 2
        let bleed = Double(MercuryMetrics.bleed)
        let extent = CGRect(
            x: self.lateralOffset - length / 2 - leadCap - bleed,
            y: lowest - bleed,
            width: length + leadCap + trailCap + 2 * bleed,
            height: highest - lowest + 2 * bleed
        )
        // The island is the absolute envelope: the bleed exists so the coverage ramp is
        // not cut, never so the body can reach past 180x34.
        boundingBox = extent.intersection(Self.islandBounds)
    }

    /// The island rect in the field's own coordinates.
    static let islandBounds = CGRect(
        x: -RecordingOverlayMetrics.islandSize.width / 2,
        y: -RecordingOverlayMetrics.islandSize.height / 2,
        width: RecordingOverlayMetrics.islandSize.width,
        height: RecordingOverlayMetrics.islandSize.height
    )

    /// Signed, positive inside.
    ///
    /// Inside the span this is `r(a) - |y - c(a)|`; beyond it, the exact distance to the
    /// cap centre, so both ends are full rounds of radius `r(0)` with no vertical cut, no
    /// needle, and no separately generated cap to seam.
    func value(at point: CGPoint) -> CGFloat {
        let horizontal = Double(point.x) - lateralOffset
        let column = column(atX: horizontal)
        let vertical = Double(point.y) - column.center
        guard column.inSpan else {
            let offset = column.capOffset
            return CGFloat(column.radius - (offset * offset + vertical * vertical).squareRoot())
        }
        return CGFloat(column.radius - abs(vertical))
    }

    /// Analytic gradient of ``value(at:)``, used for antialiasing and for the surface normal.
    func gradient(at point: CGPoint) -> CGVector {
        let horizontal = Double(point.x) - lateralOffset
        let column = column(atX: horizontal)
        let vertical = Double(point.y) - column.center
        let (horizontalRate, verticalRate) = Self.gradient(column: column, vertical: vertical, length: length)
        return CGVector(dx: horizontalRate, dy: verticalRate)
    }

    /// The gradient in one place, so the per-pixel rasterizer and the public accessor
    /// cannot diverge.
    @inline(__always)
    static func gradient(column: Column, vertical: Double, length: Double) -> (Double, Double) {
        guard column.inSpan else {
            let offset = column.capOffset
            let distance = (offset * offset + vertical * vertical).squareRoot()
            guard distance > 1e-9 else { return (0, -1) }
            return (-offset / distance, -vertical / distance)
        }
        let sign: Double = vertical >= 0 ? 1 : -1
        return ((column.radiusSlope + sign * column.centerSlope) / length, -sign)
    }

    /// Resolves one pixel column. `x` is already relative to the body's own centre, so
    /// the lateral offset is applied exactly once, by the caller.
    func column(atX horizontal: Double) -> Column {
        let half = length / 2
        let clamped = Swift.min(Swift.max(horizontal, -half), half)
        let material = length > 0 ? (clamped + half) / length : 0
        let stations = top.count - 1
        let position = material * Double(stations)
        let index = Swift.min(Int(position), stations)
        let fraction = position - Double(index)
        let next = Swift.min(index + 1, stations)

        let radius = mix(radius(index), radius(next), fraction)
        let center = mix(center(index), center(next), fraction)
        let scale = Double(stations)
        return Column(
            inSpan: horizontal >= -half && horizontal <= half,
            capOffset: horizontal - clamped,
            radius: radius,
            center: center,
            radiusSlope: mix(radiusSlope(index), radiusSlope(next), fraction) * scale,
            centerSlope: mix(centerSlope(index), centerSlope(next), fraction) * scale
        )
    }

    // MARK: - Sampled quantities

    /// Half the local thickness. Strictly positive for every finite amplitude, because
    /// it is `H0 * G(a) * cosh(...) * exp(...)`, so a detached speck is unrepresentable
    /// rather than merely disallowed.
    @inline(__always)
    private func radius(_ index: Int) -> Double {
        (Double(top[index]) - Double(bottom[index])) / 2
    }

    @inline(__always)
    private func center(_ index: Int) -> Double {
        (Double(top[index]) + Double(bottom[index])) / 2
    }

    @inline(__always)
    private func radiusSlope(_ index: Int) -> Double {
        let low = Swift.max(index - 1, 0)
        let high = Swift.min(index + 1, top.count - 1)
        return (radius(high) - radius(low)) / Double(high - low)
    }

    @inline(__always)
    private func centerSlope(_ index: Int) -> Double {
        let low = Swift.max(index - 1, 0)
        let high = Swift.min(index + 1, top.count - 1)
        return (center(high) - center(low)) / Double(high - low)
    }

    @inline(__always)
    private func mix(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}
