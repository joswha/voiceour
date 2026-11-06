import Foundation
import Testing
import VoiceCore

@testable import VoiceourBench

/// Every result row is stamped with the model that produced it, and a comparison trusts that
/// stamp. These pin it per backend, so a model-backed run always names its pinned artifact
/// and a model-less run never borrows one.
@Suite("Bench model identity")
struct BenchModelIdentityTests {
    @Test func graniteNamesItsPinnedArtifact() {
        let identity = BenchRunner.modelIdentity(for: "granite")
        #expect(identity.id == GraniteModelContract.modelId)
        #expect(identity.revision == GraniteModelContract.revision)
        #expect(identity.file == GraniteModelContract.fileName)
    }

    @Test func modelLessBackendReportsItsOwnName() {
        let fake = BenchRunner.modelIdentity(for: "fake")
        #expect(fake.id == "fake")
        #expect(fake.revision == "fake")
        #expect(fake.file == nil)
    }

    @Test(arguments: ["granite", "GRANITE", "fake"])
    func pipelineAcceptsEveryRegisteredBackend(backend: String) throws {
        let options = try BenchCLI.parse([
            "pipeline", "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl", "--backend", backend,
        ])
        #expect(options.command == .pipeline)
        #expect(options.backend == backend.lowercased())
    }

    /// `pipeline` runs the registry default recognizer unless told otherwise.
    @Test func pipelineDefaultsToTheRegistryDefault() throws {
        let options = try BenchCLI.parse([
            "pipeline", "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl",
        ])
        #expect(options.backend == "granite")
    }

    @Test(arguments: ["transcribe", "Pipeline", "--input"])
    func unknownSubcommandNamesTheSupportedOnes(command: String) throws {
        let thrown = #expect(throws: BenchError.self) {
            try BenchCLI.parse([command, "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl"])
        }
        #expect(try #require(thrown).description == "expected subcommand: pipeline or repair-verify")
    }

    @Test func unknownBackendIsAUsageError() throws {
        let thrown = #expect(throws: BenchError.self) {
            try BenchCLI.parse([
                "pipeline", "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl",
                "--backend", "whisper",
            ])
        }
        let error = try #require(thrown)
        #expect(error.isUsageError)
        #expect(error.description == "--backend must be one of: fake, granite")
    }
}
