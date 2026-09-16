import Foundation
import Testing

@testable import VoiceourBench

/// The `external-encoder` route's command line is the only thing that decides which encoder a
/// measurement ran through, so every way of asking for the wrong one is refused before a model
/// loads. The measured run is the route's own proof; these cover the refusals, the dial
/// boundaries, and the artifact digest the conversion manifest is compared against.
struct ExternalEncoderCommandTests {
    private func arguments(
        engine: String,
        extra: [String] = [],
        output: String = "/tmp/voiceour-external-encoder-\(UUID().uuidString).jsonl"
    ) -> [String] {
        [
            "--engine", engine,
            "--input", "/tmp/manifest.jsonl",
            "--output", output,
            "--model", "/tmp/ggml-parakeet.bin",
        ] + extra
    }

    @Test(
        arguments: [
            ["--coreai-model", "/tmp/encoder.aimodel"],
            ["--coreai-compute", "neural-engine"],
            ["--coreai-cache", "persistent"],
        ]
    )
    func coreAIDialsAreRefusedWithTheCoreMLEngine(extra: [String]) throws {
        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.parse(arguments(engine: "coreml", extra: extra))
        }

        let error = try #require(thrown)
        #expect(error.isUsageError)
    }

    @Test func theCoreAIEngineRefusesToRunWithoutItsArtifact() throws {
        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.parse(arguments(engine: "coreai"))
        }

        let error = try #require(thrown)
        #expect(error.isUsageError)
        #expect(error.description.contains("--coreai-model"))
    }

    @Test func theCoreAIDialsReachTheConfiguration() throws {
        let command = try ExternalEncoderCommand.parse(
            arguments(
                engine: "coreai",
                extra: [
                    "--coreai-model", "/tmp/parakeet-encoder-15s.aimodel",
                    "--coreai-compute", "neural-engine",
                    "--coreai-cache", "persistent",
                ]
            )
        )

        let coreAI = try #require(command.coreAI)
        #expect(coreAI.modelURL.lastPathComponent == "parakeet-encoder-15s.aimodel")
        #expect(coreAI.computeUnits == .neuralEngine)
        #expect(coreAI.cachePolicy == .persistent)
    }

    /// An unrecognized dial must not fall back to a default: a run that silently measured
    /// `default` while its command line said `gpu` would be attributed to the wrong device.
    @Test(
        arguments: [
            ["--coreai-compute", "gpu"],
            ["--coreai-compute", "neuralengine"],
            ["--coreai-compute", ""],
            ["--coreai-cache", "ephemeral"],
            ["--coreai-cache", "Default"],
        ]
    )
    func unknownCoreAIDialValuesAreRefused(dial: [String]) throws {
        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.parse(
                arguments(
                    engine: "coreai",
                    extra: ["--coreai-model", "/tmp/encoder.aimodel"] + dial
                )
            )
        }

        let error = try #require(thrown)
        #expect(error.isUsageError)
    }

    @Test(arguments: [[], ["--engine", "mlx"], ["--engine", "coreML"]])
    func theEngineSelectorIsRequiredAndClosed(engine: [String]) throws {
        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.parse(
                engine + [
                    "--input", "/tmp/manifest.jsonl",
                    "--output", "/tmp/voiceour-external-encoder-\(UUID().uuidString).jsonl",
                    "--model", "/tmp/ggml-parakeet.bin",
                ]
            )
        }

        let error = try #require(thrown)
        #expect(error.isUsageError)
    }

    /// The rows are a measurement other artifacts cite by digest, so a second run names a new
    /// file rather than replacing the record — refused before any model loads.
    @Test func anExistingOutputIsRefused() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-external-encoder-\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"row\"}\n".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.parse(arguments(engine: "coreml", output: output.path))
        }

        let error = try #require(thrown)
        #expect(!error.isUsageError)
        #expect(error.description.contains(output.lastPathComponent))
    }

    /// `encoder_meta.model_tree_sha256` is compared against the conversion manifest's
    /// `artifact.tree_sha256`, which `bench/coreai/convert_encoder.py` computes over the same
    /// rule: every regular file, symlinks excluded, sorted by relative POSIX path, one
    /// `"<path> <sha256>\n"` line each, hashed as UTF-8. The expected digest is that rule applied
    /// by hand to the three files below, so a drift on either side is visible.
    @Test func theArtifactDigestFollowsTheSharedTreeRule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-artifact-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("two".utf8).write(to: root.appendingPathComponent("b.bin"))
        try Data("one".utf8).write(to: root.appendingPathComponent("a.bin"))
        try Data("three".utf8).write(to: nested.appendingPathComponent("c.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.bin"),
            withDestinationURL: root.appendingPathComponent("a.bin")
        )

        let digest = try ExternalEncoderCommand.artifactDigest(at: root)

        #expect(digest.fileCount == 3)
        #expect(digest.byteCount == 11)
        #expect(digest.sha256 == "83aa4fbe3ddd80986e1df044be0bb44a8a4213e1420e137113b55ff35a96b148")
    }

    @Test func aLoneArtifactFileIsDigestedUnderItsOwnName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.bin")
        try Data("one".utf8).write(to: file)

        let digest = try ExternalEncoderCommand.artifactDigest(at: file)

        #expect(digest.fileCount == 1)
        #expect(digest.byteCount == 3)
        // The same rule over one line: "a.bin <sha256 of those three bytes>\n".
        #expect(digest.sha256 == "38da42055c216ff47a30beb29b19054b068cece5c843effb9d0714b33e02cef5")
    }

    @Test func aMissingArtifactIsNamedInTheFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-missing-\(UUID().uuidString).aimodel")

        let thrown = #expect(throws: BenchError.self) {
            try ExternalEncoderCommand.artifactDigest(at: missing)
        }

        let error = try #require(thrown)
        #expect(error.description.contains(missing.path))
    }

    @Test func unavailableEncoderMeasurementsRemainExplicitNulls() throws {
        let metadata = ExternalEncoderMeta(
            engine: "coreml", modelPath: "/model.mlmodelc",
            modelTreeSHA256: "digest", modelTreeBytes: 1, modelTreeFiles: 1,
            compute: nil, cachePolicy: nil, deviceArchitecture: nil,
            availableComputeUnits: nil, specializationMs: nil, loadFunctionMs: nil,
            tailThreads: 4, note: "unavailable measurements"
        )
        let encoder = JSONEncoder()
        let fields = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any]
        )
        for key in [
            "compute", "cache_policy", "device_architecture",
            "available_compute_units", "specialization_ms", "load_function_ms",
        ] {
            #expect(fields[key] is NSNull, "Missing measurement must be null, not absent: \(key)")
        }

        let timings = EncoderRowTimings(
            melMs: nil, encodeMs: 1, tailMs: 2, encoderFrames: 1, statesSHA256: "digest"
        )
        let timingFields = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(timings)) as? [String: Any]
        )
        #expect(timingFields["mel_ms"] is NSNull)
    }
}
