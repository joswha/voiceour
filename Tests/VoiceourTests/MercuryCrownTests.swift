import CoreGraphics
import Testing

@testable import Voiceour

/// The aspects and radii every crown property is held at: both ends of the crown range a look
/// can choose and the shipped aspect, on the island-sized body each property was first measured
/// on and at the collar's 24 pt ceiling, the thickest a layout allows.
private enum CrownSweep {
    static let aspects = [
        MercuryTune.crownAspectRange.lowerBound,
        MercuryMetrics.crownAspect,
        MercuryTune.crownAspectRange.upperBound,
    ]
    static let collarCeiling = RecordingOverlayLayout.forDisplay(.fixtureNotch).spine.maxHalfHeight
}

/// The crown is a runtime scalar and a collar's crown is deeper than the island's, so every
/// property below must hold for any aspect the tune can reach and any radius a ceiling allows.
struct MercuryCrownTests {
    private let epsilon = 0.125

    @Test(arguments: CrownSweep.aspects, [11.5, CrownSweep.collarCeiling])
    func analyticPartialsMatchFiniteDifferences(aspect: Double, radius: Double) {
        let field = 4.3 / 11.5 * radius
        let step = 1e-5
        let sample = MercuryCrown.evaluate(
            field: field, radius: radius, aspect: aspect, epsilon: epsilon
        )
        let fieldDifference =
            (MercuryCrown.evaluate(
                field: field + step, radius: radius, aspect: aspect, epsilon: epsilon
            ).height
                - MercuryCrown.evaluate(
                    field: field - step, radius: radius, aspect: aspect, epsilon: epsilon
                ).height) / (2 * step)
        let radiusDifference =
            (MercuryCrown.evaluate(
                field: field, radius: radius + step, aspect: aspect, epsilon: epsilon
            ).height
                - MercuryCrown.evaluate(
                    field: field, radius: radius - step, aspect: aspect, epsilon: epsilon
                ).height) / (2 * step)

        #expect(abs(sample.fieldDerivative - fieldDifference) < 1e-8)
        #expect(abs(sample.radiusDerivative - radiusDifference) < 1e-8)
    }

    @Test(arguments: CrownSweep.aspects, [10.2, CrownSweep.collarCeiling])
    func totalGradientIncludesTheChangingRadius(aspect: Double, radius: Double) {
        let field = 6.1 / 10.2 * radius
        let fieldGradient = SIMD2<Double>(0.18, -1)
        let radiusGradient = SIMD2<Double>(0.09, 0)
        let step = 1e-5
        let sample = MercuryCrown.evaluate(
            field: field, radius: radius, aspect: aspect, epsilon: epsilon
        )
        let analytic = sample.gradient(
            fieldGradient: fieldGradient,
            radiusGradient: radiusGradient
        )
        let horizontalDifference =
            (MercuryCrown.evaluate(
                field: field + step * fieldGradient.x,
                radius: radius + step * radiusGradient.x,
                aspect: aspect,
                epsilon: epsilon
            ).height
                - MercuryCrown.evaluate(
                    field: field - step * fieldGradient.x,
                    radius: radius - step * radiusGradient.x,
                    aspect: aspect,
                    epsilon: epsilon
                ).height) / (2 * step)
        let verticalDifference =
            (MercuryCrown.evaluate(
                field: field + step * fieldGradient.y,
                radius: radius,
                aspect: aspect,
                epsilon: epsilon
            ).height
                - MercuryCrown.evaluate(
                    field: field - step * fieldGradient.y,
                    radius: radius,
                    aspect: aspect,
                    epsilon: epsilon
                ).height) / (2 * step)

        #expect(abs(analytic.x - horizontalDifference) < 1e-8)
        #expect(abs(analytic.y - verticalDifference) < 1e-8)
        #expect(abs(sample.radiusDerivative * radiusGradient.x) > 0.01)
    }

    @Test(arguments: CrownSweep.aspects, [11.5, CrownSweep.collarCeiling])
    func theFullCapHasNoInteriorPlateau(aspect: Double, radius: Double) {
        let quarter = MercuryCrown.evaluate(
            field: radius * 0.25,
            radius: radius,
            aspect: aspect,
            epsilon: epsilon
        )
        let middle = MercuryCrown.evaluate(
            field: radius * 0.5,
            radius: radius,
            aspect: aspect,
            epsilon: epsilon
        )
        let spine = MercuryCrown.evaluate(
            field: radius,
            radius: radius,
            aspect: aspect,
            epsilon: epsilon
        )

        #expect(quarter.height < middle.height)
        #expect(middle.height < spine.height)
        #expect(abs(quarter.fieldDerivative) > abs(middle.fieldDerivative))
        #expect(abs(middle.fieldDerivative) > abs(spine.fieldDerivative))
        #expect(spine.height > aspect * radius * 0.99)
    }

    @Test(arguments: CrownSweep.aspects, [8, CrownSweep.collarCeiling])
    func limbRegularizationKeepsHeightAndGradientFinite(aspect: Double, radius: Double) {
        for field in [-1.0, 0.0, 1e-12, 0.1] {
            let sample = MercuryCrown.evaluate(
                field: field,
                radius: radius,
                aspect: aspect,
                epsilon: epsilon
            )
            #expect(sample.height.isFinite)
            #expect(sample.fieldDerivative.isFinite)
            #expect(sample.radiusDerivative.isFinite)
            #expect(sample.height >= 0)
        }
    }
}
