import Foundation
import Testing

@testable import Voiceour

struct MercuryPresentationPerformanceTests {
    @Test func conductorLookupTracksTheExactMercuryFresnel() {
        var maximumError = 0.0
        for index in 0...10_000 {
            let cosine = 1e-4 + (1 - 1e-4) * Double(index) / 10_000
            let exact = MercuryOptics.exactFresnel(cosine: cosine)
            let sampled = MercuryOptics.fresnel(cosine: cosine)
            maximumError = Swift.max(maximumError, abs(exact.x - sampled.x))
            maximumError = Swift.max(maximumError, abs(exact.y - sampled.y))
            maximumError = Swift.max(maximumError, abs(exact.z - sampled.z))
        }

        #expect(maximumError < 1e-4)
        #expect(MercuryOptics.fresnel(cosine: 1e-4).min() > 0.999)
    }

    @Test func transferLookupNeverMovesAChannelByMoreThanOneCodeValue() {
        for index in 0...100_000 {
            let linear = Double(index) / 100_000
            let exact = Self.byte(MercuryOptics.exactEncodeSRGB(linear))
            let sampled = Self.byte(MercuryOptics.encodeSRGB(linear))
            #expect(abs(Int(exact) - Int(sampled)) <= 1)
            let opaque = MercuryOptics.encodedByte(linear, coverage: 1)
            #expect(abs(Int(exact) - Int(opaque)) <= 1)
        }
    }

    @Test func responseLookupPreservesAnchorsMonotonicityAndCeiling() throws {
        let response = try #require(
            MercuryDisplayResponse.solve(
                sceneMedian: 2,
                sceneHighlight: 80,
                medianTarget: 0.32,
                highlightTarget: 0.87,
                ceiling: 0.94
            )
        )
        let lookup = MercuryDisplayLookup(response: response)
        var previous = 0.0
        var maximumError = 0.0
        for index in 0...20_000 {
            let exponent = -12 + 24 * Double(index) / 20_000
            let scene = Foundation.exp(exponent)
            let mapped = lookup.map(scene)
            maximumError = Swift.max(maximumError, abs(mapped - response.map(scene)))
            #expect(mapped >= previous)
            #expect(mapped < response.ceiling)
            previous = mapped
        }

        #expect(maximumError < 1e-4)
        #expect(abs(lookup.map(response.sceneMedian) - 0.32) < 1e-4)
        #expect(abs(lookup.map(response.sceneHighlight) - 0.87) < 1e-4)

        let tints = [
            SIMD3<Double>(1, 1, 1),
            SIMD3<Double>(1.4, 0.8, 0.5),
            SIMD3<Double>(0.5, 1.3, 0.9),
            SIMD3<Double>(2.4, 0.3, 0.1),
        ]
        for index in 0...2_000 {
            let radiance = exp(-4 + 10 * Double(index) / 2_000)
            for tint in tints {
                let exact = response.map(radiance * tint)
                let sampled = lookup.map(radiance * tint)
                for channel in 0..<3 {
                    let exactByte = Self.byte(MercuryOptics.exactEncodeSRGB(exact[channel]))
                    let sampledByte = Self.byte(MercuryOptics.exactEncodeSRGB(sampled[channel]))
                    #expect(abs(Int(exactByte) - Int(sampledByte)) <= 1)
                }
            }
        }
    }
    @Test func finiteEyeApproximationIsSubpixelExactAcrossTheIsland() {
        for horizontal in stride(from: -90.0, through: 90.0, by: 1.0) {
            for vertical in stride(from: -17.0, through: 17.0, by: 1.0) {
                for crownHeight in stride(from: 0.0, through: 14.0, by: 1.0) {
                    let exact = MercuryOptics.exactViewDirection(
                        horizontal: horizontal,
                        vertical: vertical,
                        crownHeight: crownHeight
                    )
                    let approximate = MercuryOptics.viewDirection(
                        horizontal: horizontal,
                        vertical: vertical,
                        crownHeight: crownHeight
                    )
                    let difference = exact - approximate
                    #expect(abs(difference.x) < 1e-8)
                    #expect(abs(difference.y) < 1e-8)
                    #expect(abs(difference.z) < 1e-8)
                }
            }
        }
    }

    @Test func octahedralRoomMapRoundTripsTheSphereAndExtendsItsBorder() {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for index in 0..<20_000 {
            let z = 1 - 2 * (Double(index) + 0.5) / 20_000
            let radius = Swift.max(0, 1 - z * z).squareRoot()
            let angle = golden * Double(index)
            let direction = SIMD3<Float>(
                Float(radius * cos(angle)),
                Float(radius * sin(angle)),
                Float(z)
            )
            let decoded = MercuryOctahedralMap.decode(MercuryOctahedralMap.encode(direction))
            #expect(abs(1 - (direction * decoded).sum()) < 2e-6)
        }

        for point in [
            SIMD2<Float>(-1.02, -0.4),
            SIMD2<Float>(1.02, 0.4),
            SIMD2<Float>(0.4, -1.02),
            SIMD2<Float>(-0.4, 1.02),
        ] {
            let direction = MercuryOctahedralMap.decode(point)
            #expect(direction.x.isFinite)
            #expect(direction.y.isFinite)
            #expect(direction.z.isFinite)
            #expect(abs(1 - (direction * direction).sum()) < 2e-6)
        }
    }

    @Test func displayCadenceUsesTheAttachedScreensNativeRateUpTo120Hz() {
        #expect(MercuryFramePacer.presentationFramesPerSecond(screenMaximum: 120) == 120)
        #expect(MercuryFramePacer.presentationFramesPerSecond(screenMaximum: 60) == 60)
        #expect(MercuryFramePacer.presentationFramesPerSecond(screenMaximum: 75) == 75)
        #expect(MercuryFramePacer.presentationFramesPerSecond(screenMaximum: 144) == 120)
        #expect(MercuryFramePacer.presentationFramesPerSecond(screenMaximum: 0) == 60)
        let promotion = MercuryFramePacer.preferredFrameRateRange(screenMaximum: 120)
        #expect(promotion.minimum == 120)
        #expect(promotion.maximum == 120)
        let standard = MercuryFramePacer.preferredFrameRateRange(screenMaximum: 60)
        #expect(standard.minimum == 60)
        #expect(standard.maximum == 60)
        let capped = MercuryFramePacer.preferredFrameRateRange(screenMaximum: 144)
        #expect(capped.minimum == 120)
        #expect(capped.maximum == 120)
        #expect(capped.preferred == 120)
    }
    @Test func callbackTargetIntervalOutranksTheHardwareRefreshDuration() {
        let interval = MercuryFramePacer.callbackInterval(
            timestamp: 10,
            targetTimestamp: 10 + 1.0 / 120.0,
            reportedDuration: 1.0 / 144.0,
            fallback: 1.0 / 60.0
        )
        #expect(abs(interval - 1.0 / 120.0) < 1e-12)

        var pacer = MercuryFramePacer()
        let steps = (0..<120).reduce(0) { total, _ in
            total + pacer.simulationSteps(frameDuration: interval)
        }
        #expect(steps == 120)
    }

    @Test func displayCadenceAdvancesThe120HzPhysicsWithoutChangingItsClock() {
        var promotion = MercuryFramePacer()
        #expect(
            (0..<120).map { _ in promotion.simulationSteps(frameDuration: 1.0 / 120.0) }
                == Array(repeating: 1, count: 120))

        var standard = MercuryFramePacer()
        #expect(
            (0..<60).map { _ in standard.simulationSteps(frameDuration: 1.0 / 60.0) }
                == Array(repeating: 2, count: 60))

        var seventyFive = MercuryFramePacer()
        let steps = (0..<75).reduce(0) { total, _ in
            total + seventyFive.simulationSteps(frameDuration: 1.0 / 75.0)
        }
        #expect(steps == 120)
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(Swift.min(255, Swift.max(0, Int((value * 255).rounded()))))
    }
}
