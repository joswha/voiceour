import Testing

@testable import Voiceour

struct MercuryDisplayResponseTests {
    @Test func theTwoAnchorsAreSolvedExactly() throws {
        let response = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 2,
                sceneHighlight: 80,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            )
        )

        #expect(abs(response.map(2) - 0.32) < 1e-12)
        #expect(abs(response.map(80) - 0.86) < 1e-12)
    }

    @Test func theCeilingCannotBeReachedByFiniteRadiance() throws {
        let response = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 0.1,
                sceneHighlight: 100,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            )
        )

        for radiance in [0.0, Double.leastNonzeroMagnitude, 1e-12, 1, 1e12, Double.greatestFiniteMagnitude] {
            let mapped = response.map(radiance)
            #expect(mapped.isFinite)
            #expect(mapped >= 0)
            #expect(mapped < response.ceiling || radiance == 0)
        }
    }

    @Test func mappingIsStrictlyMonotoneAndStartsAtBlack() throws {
        let response = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 1,
                sceneHighlight: 20,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            )
        )
        let inputs = [0.0, 1e-8, 0.01, 0.1, 1, 10, 100, 1e6]
        let outputs = inputs.map(response.map)

        #expect(outputs[0] == 0)
        for index in 1..<outputs.count {
            #expect(outputs[index] > outputs[index - 1])
        }
    }

    @Test func rgbMappingPreservesLuminanceAndBoundsEveryChannel() throws {
        let response = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 1,
                sceneHighlight: 20,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            )
        )
        let scene = SIMD3<Double>(1.8, 0.9, 0.4)
        let mapped = response.map(scene)
        let expectedLuminance = response.map(MercuryDisplayResponse.luminance(scene))
        let measuredLuminance = MercuryDisplayResponse.luminance(mapped)

        #expect(abs(measuredLuminance - expectedLuminance) < 1e-12)
        #expect(mapped.min() >= 0)
        #expect(mapped.max() <= response.ceiling)
    }

    @Test func anUnsolvableDistributionIsRejectedRatherThanClamped() {
        #expect(
            MercuryDisplayResponse.solve(
                sceneMedian: 1,
                sceneHighlight: 1,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            ) == nil
        )
    }

    @Test func increasedContrastUsesAnotherBoundedResponseInsteadOfClipping() throws {
        let standard = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 1,
                sceneHighlight: 20,
                medianTarget: 0.32,
                highlightTarget: 0.86,
                ceiling: 0.94
            )
        )
        let increased = try #require(
            standard.remapped(
                medianTarget: 0.30,
                highlightTarget: 0.90
            )
        )

        #expect(abs(increased.map(standard.sceneMedian) - 0.30) < 1e-12)
        #expect(abs(increased.map(standard.sceneHighlight) - 0.90) < 1e-12)
        for value in stride(from: 0.0, through: 100.0, by: 0.1) {
            #expect(increased.map(value) < increased.ceiling)
        }
    }
}
