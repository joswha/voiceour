import Foundation
import Testing

@testable import ASRSidecarCore

@Suite("CoreMLEncoderConfigurationTests")
struct CoreMLEncoderConfigurationTests {
    @Test func absentEncoderKeepsTheNativePath() throws {
        #expect(try CoreMLEncoderConfiguration.resolve(environment: [:]) == nil)
    }

    @Test func enabledEncoderUsesTheFifteenSecondDefault() throws {
        let resolved = try CoreMLEncoderConfiguration.resolve(
            environment: ["VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc"]
        )
        let configuration = try #require(resolved)

        #expect(configuration.modelURL.path == "/tmp/parakeet_encoder.mlmodelc")
        #expect(configuration.maximumDurationSeconds == 15.0)
        #expect(configuration.maximumSampleCount == 240_000)
        #expect(configuration.routesThroughCoreML(sampleCount: 240_000))
        #expect(!configuration.routesThroughCoreML(sampleCount: 240_001))
    }

    @Test func customMaximumDurationControlsTheInclusiveBoundary() throws {
        let resolved = try CoreMLEncoderConfiguration.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlpackage",
                "VOICEOUR_COREML_MAX_S": "2.5",
            ]
        )
        let configuration = try #require(resolved)

        #expect(configuration.maximumDurationSeconds == 2.5)
        #expect(configuration.maximumSampleCount == 40_000)
        #expect(configuration.routesThroughCoreML(sampleCount: 40_000))
        #expect(!configuration.routesThroughCoreML(sampleCount: 40_001))
    }

    @Test(arguments: ["", "zero", "0", "-1", "nan", "inf"])
    func invalidMaximumDurationFailsClosed(value: String) {
        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderConfiguration.resolve(
                environment: [
                    "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                    "VOICEOUR_COREML_MAX_S": value,
                ]
            )
        }
    }
}
