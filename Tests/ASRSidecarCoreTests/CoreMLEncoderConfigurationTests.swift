import Foundation
import Testing

@testable import ASRSidecarCore

@Suite("CoreMLEncoderConfigurationTests")
struct CoreMLEncoderConfigurationTests {
    @Test func absentEncodersKeepTheNativePath() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(environment: [:])

        #expect(configurations.standard == nil)
        #expect(configurations.short == nil)
        #expect(configurations.tiny == nil)
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

    @Test func tinyEncoderTakesPrecedenceAtItsInclusiveBoundary() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlmodelc",
                "VOICEOUR_COREML_ENCODER_TINY": "/tmp/parakeet_encoder_6s.mlmodelc",
            ]
        )
        let tiny = try #require(configurations.tiny)

        #expect(tiny.bucket == .tiny)
        #expect(tiny.maximumDurationSeconds == 6.0)
        #expect(tiny.maximumSampleCount == 96_000)
        #expect(tiny.melFrameCapacity == 601)
        #expect(tiny.encoderFrameCapacity == 76)
        #expect(configurations.selectedConfiguration(sampleCount: 96_000)?.bucket == .tiny)
        #expect(configurations.selectedConfiguration(sampleCount: 96_001)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 128_000)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 128_001)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 240_000)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 240_001) == nil)
    }

    @Test func tinyEncoderCanRouteWithoutLargerArtifacts() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER_TINY": "/tmp/parakeet_encoder_6s.mlmodelc",
            ]
        )

        #expect(configurations.standard == nil)
        #expect(configurations.short == nil)
        #expect(configurations.selectedConfiguration(sampleCount: 96_000)?.bucket == .tiny)
        #expect(configurations.selectedConfiguration(sampleCount: 96_001) == nil)
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

    @Test func customMaximumDurationsControlAllInclusiveBoundaries() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlpackage",
                "VOICEOUR_COREML_MAX_S": "12.5",
                "VOICEOUR_COREML_ENCODER_SHORT": "/tmp/parakeet_encoder_8s.mlpackage",
                "VOICEOUR_COREML_SHORT_MAX_S": "7.5",
                "VOICEOUR_COREML_ENCODER_TINY": "/tmp/parakeet_encoder_6s.mlpackage",
                "VOICEOUR_COREML_TINY_MAX_S": "5.5",
            ]
        )

        #expect(configurations.tiny?.maximumSampleCount == 88_000)
        #expect(configurations.short?.maximumSampleCount == 120_000)
        #expect(configurations.standard?.maximumSampleCount == 200_000)
        #expect(configurations.selectedConfiguration(sampleCount: 88_000)?.bucket == .tiny)
        #expect(configurations.selectedConfiguration(sampleCount: 88_001)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 120_000)?.bucket == .short)
        #expect(configurations.selectedConfiguration(sampleCount: 120_001)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 200_000)?.bucket == .standard)
        #expect(configurations.selectedConfiguration(sampleCount: 200_001) == nil)
    }

    @Test func orphanedSmallerMaximumsDoNotChangeStandardResolution() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER": "/tmp/parakeet_encoder.mlmodelc",
                "VOICEOUR_COREML_SHORT_MAX_S": "invalid-but-unused",
                "VOICEOUR_COREML_TINY_MAX_S": "also-invalid-but-unused",
            ]
        )

        #expect(configurations.short == nil)
        #expect(configurations.tiny == nil)
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

    @Test(arguments: ["", "zero", "0", "-1", "nan", "inf", "6.1"])
    func invalidTinyMaximumDurationFailsClosed(value: String) {
        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderConfigurationSet.resolve(
                environment: [
                    "VOICEOUR_COREML_ENCODER_TINY": "/tmp/parakeet_encoder_6s.mlmodelc",
                    "VOICEOUR_COREML_TINY_MAX_S": value,
                ]
            )
        }
    }

    @Test func configuredArtifactPathIsValidatedWithoutLoadingTheModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-coreml-lazy-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("parakeet_encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: ["VOICEOUR_COREML_ENCODER": model.path]
        )

        let encoders = try CoreMLEncoderSet(configurations: configurations)
        #expect(!encoders.isEmpty)
    }

    @Test func configuredUnsupportedArtifactFailsClosedBeforeLoading() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-coreml-\(UUID().uuidString).bin")
        try Data().write(to: model)
        defer { try? FileManager.default.removeItem(at: model) }

        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: ["VOICEOUR_COREML_ENCODER": model.path]
        )

        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderSet(configurations: configurations)
        }
    }

    @Test func lazyCoreMLResourceLoadsOnlyOnce() throws {
        let expected = NSObject()
        var loadCount = 0
        let resource = LazyCoreMLResource {
            loadCount += 1
            return expected
        }

        #expect(loadCount == 0)
        #expect(try resource.value() === expected)
        #expect(try resource.value() === expected)
        #expect(loadCount == 1)
    }

    @Test func routedLazyLoadFailureIsLogged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-coreml-failure-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("parakeet_encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: ["VOICEOUR_COREML_ENCODER": model.path]
        )
        var messages: [String] = []
        let encoders = try CoreMLEncoderSet(
            configurations: configurations,
            log: { messages.append($0) }
        )

        #expect(messages.isEmpty)
        #expect(throws: CoreMLEncoderError.self) {
            try encoders.encoder(sampleCount: 1)
        }
        #expect(messages.count == 1)
        #expect(messages[0].hasPrefix("VOICEOUR_COREML_ENCODER lazy load failed:"))
    }

    @Test func configuredMissingStandardArtifactFailsClosed() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER":
                    "/definitely/missing/parakeet_encoder.mlmodelc",
            ]
        )

        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderSet(configurations: configurations)
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

    @Test func configuredMissingTinyArtifactFailsClosed() throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(
            environment: [
                "VOICEOUR_COREML_ENCODER_TINY":
                    "/definitely/missing/parakeet_encoder_6s.mlmodelc",
            ]
        )

        #expect(throws: CoreMLEncoderError.self) {
            try CoreMLEncoderSet(configurations: configurations)
        }
    }
}
