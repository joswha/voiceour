import Foundation
import Testing

@testable import ASRSidecarCore

@Suite("CoreMLEncoderConfigurationTests")
struct CoreMLEncoderConfigurationTests {
    @Test func absentEncodersKeepTheNativePath() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(environment: [:])

        #expect(configurations.standard == nil)
        #expect(configurations.short == nil)
        #expect(configurations.selectedConfiguration(sampleCount: 1) == nil)
    }

    @Test func enabledStandardEncoderKeepsTheFifteenSecondDefault() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: ["VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc"]
        )
        let configuration = try #require(configurations.standard)

        #expect(configuration.bucket == .standard)
        #expect(configuration.modelURL.path == "/tmp/parakeet_encoder.mlmodelc")
        #expect(configuration.maximumDurationSeconds == 15.0)
        #expect(configuration.maximumSampleCount == 240_000)
        #expect(configuration.melFrameCapacity == 1_501)
        #expect(configuration.encoderFrameCapacity == 188)
        #expect(configurations.selectedConfiguration(sampleCount: 240_000)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 240_001) == nil)
    }

    @Test func shortEncoderTakesPrecedenceAtItsInclusiveBoundary() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlmodelc",
            ]
        )
        let short = try #require(configurations.short)

        #expect(short.bucket == .short)
        #expect(short.maximumDurationSeconds == 8.0)
        #expect(short.maximumSampleCount == 128_000)
        #expect(short.melFrameCapacity == 801)
        #expect(short.encoderFrameCapacity == 101)
        #expect(configurations.selectedConfiguration(sampleCount: 128_000)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 128_001)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 240_000)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 240_001) == nil)
    }

    @Test func shortEncoderCanRouteWithoutAStandardArtifact() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlmodelc",
            ]
        )

        #expect(configurations.standard == nil)
        #expect(configurations.selectedConfiguration(sampleCount: 128_000)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 128_001) == nil)
    }

    @Test func customMaximumDurationsControlBothInclusiveBoundaries() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlpackage",
                "VOICEOUR_COREML_MAX_S": "12.5",
                "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlpackage",
                "VOICEOUR_COREML_SHORT_MAX_S": "7.5",
            ]
        )

        #expect(configurations.short?.maximumSampleCount == 120_000)
        #expect(configurations.standard?.maximumSampleCount == 200_000)
        #expect(configurations.selectedConfiguration(sampleCount: 120_000)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 120_001)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 200_000)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 200_001) == nil)
    }

    @Test func orphanedShortMaximumDoesNotChangeStandardResolution() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                "VOICEOUR_COREML_SHORT_MAX_S": "invalid-but-unused",
            ]
        )

        #expect(configurations.short == nil)
        #expect(configurations.standard?.maximumDurationSeconds == 15.0)
    }

    @Test(arguments: ["", "zero", "0", "-1", "nan", "inf", "15.1"])
    func invalidStandardMaximumDurationFailsClosed(value: String) {
        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderConfigurationSet.resolve(
                environment: [
                    "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                    "VOICEOUR_COREML_MAX_S": value,
                ]
            )
        }
    }

    @Test(arguments: ["", "zero", "0", "-1", "nan", "inf", "8.1"])
    func invalidShortMaximumDurationFailsClosed(value: String) {
        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderConfigurationSet.resolve(
                environment: [
                    "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlmodelc",
                    "VOICEOUR_COREML_SHORT_MAX_S": value,
                ]
            )
        }
    }

    @Test func configuredMissingShortArtifactFailsClosed() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER_SHORT":
                    "/definitely/missing/parakeet_encoder_8s.mlmodelc",
            ]
        )

        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderSet(configurations: configurations)
        }
    }
}
