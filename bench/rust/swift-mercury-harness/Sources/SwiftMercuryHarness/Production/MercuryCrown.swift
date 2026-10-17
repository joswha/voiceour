import Foundation

/// A fixed-aspect half-elliptic crown lifted from the same signed field the body draws.
///
/// Unlike the retired exponential shoulder, curvature is present across the full
/// thickness: the mirror-flat plateau is unrepresentable. `radiusDerivative` is kept
/// separately because the radius changes along the body; omitting it lets the silhouette
/// wiggle while the reflection stays mechanically straight.
struct MercuryCrown {
    struct Sample: Equatable, Sendable {
        var height: Double
        /// Partial derivative `∂z/∂field` at fixed radius.
        var fieldDerivative: Double
        /// Partial derivative `∂z/∂radius` at fixed field.
        var radiusDerivative: Double

        @inline(__always)
        func gradient(
            fieldGradient: SIMD2<Double>,
            radiusGradient: SIMD2<Double>
        ) -> SIMD2<Double> {
            fieldDerivative * fieldGradient + radiusDerivative * radiusGradient
        }
    }

    /// Evaluates `z = aspect * sqrt(2 r φ̃ - φ̃²)`.
    ///
    /// `φ̃ = (φ + sqrt(φ² + 4 ε²))/2` is a smooth positive part over a fraction of one
    /// device pixel. It regularizes the otherwise infinite elliptical limb slope without
    /// inventing a second silhouette: coverage still comes from the original signed field.
    @inline(__always)
    static func evaluate(
        field: Double,
        radius: Double,
        aspect: Double,
        epsilon: Double
    ) -> Sample {
        guard radius > 0, aspect > 0, epsilon > 0 else {
            return Sample(height: 0, fieldDerivative: 0, radiusDerivative: 0)
        }
        let root = (field * field + 4 * epsilon * epsilon).squareRoot()
        let smoothedField = 0.5 * (field + root)
        let fieldRate = 0.5 * (1 + field / root)
        let radicand = Swift.max(smoothedField * (2 * radius - smoothedField), .leastNonzeroMagnitude)
        let crown = radicand.squareRoot()
        return Sample(
            height: aspect * crown,
            fieldDerivative: aspect * (radius - smoothedField) / crown * fieldRate,
            radiusDerivative: aspect * smoothedField / crown
        )
    }
}
