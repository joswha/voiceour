import Foundation
import Testing
import VoiceCore

@testable import VoiceourBench

/// Every result row is stamped with the model that produced it, and a comparison trusts that
/// stamp. These pin it per backend, so a Granite run can never be recorded under Parakeet's
/// file and a Parakeet run keeps naming the variant it loaded.
@Suite("Bench model identity")
struct BenchModelIdentityTests {
    @Test func parakeetNamesTheLoadedVariant() {
        let f16 = BenchRunner.modelIdentity(for: "parakeet", variant: .f16)
        #expect(f16.id == ASRModelContract.modelId)
        #expect(f16.revision == ASRModelContract.revision)
        #expect(f16.file == ASRModelVariant.f16.fileName)

        #expect(BenchRunner.modelIdentity(for: "parakeet", variant: .q8).file == ASRModelVariant.q8.fileName)
    }

    @Test(arguments: ASRModelVariant.allCases)
    func graniteNamesItsOwnPinWhateverTheVariant(variant: ASRModelVariant) {
        let identity = BenchRunner.modelIdentity(for: "granite", variant: variant)
        #expect(identity.id == GraniteModelContract.modelId)
        #expect(identity.revision == GraniteModelContract.revision)
        #expect(identity.file == GraniteModelContract.fileName)
    }

    @Test func modelLessAndAbsentBackendsReportTheirOwnName() {
        let fake = BenchRunner.modelIdentity(for: "fake", variant: .f16)
        #expect(fake.id == "fake")
        #expect(fake.revision == "fake")
        #expect(fake.file == nil)

        let none = BenchRunner.modelIdentity(for: nil, variant: .f16)
        #expect(none.id == "none")
        #expect(none.file == nil)
    }

    @Test func pipelineAcceptsGranite() throws {
        let options = try BenchCLI.parse([
            "pipeline", "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl", "--backend", "granite",
        ])
        #expect(options.command == .pipeline)
        #expect(options.backend == "granite")
    }

    /// raw-decode constructs a Parakeet context directly; any other backend is refused before
    /// a row is read, with a sentence that names the backend and the command that runs it.
    @Test(arguments: ["granite", "GRANITE", "fake"])
    func rawDecodeRefusesEveryBackendButParakeet(backend: String) throws {
        let thrown = #expect(throws: BenchError.self) {
            try BenchCLI.parse([
                "raw-decode", "--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl",
                "--model", "/tmp/model.gguf", "--backend", backend,
            ])
        }
        let message = try #require(thrown).description
        let normalized = backend.lowercased()
        #expect(message.contains("raw-decode decodes Parakeet checkpoints only"))
        #expect(message.contains("--backend \(normalized) is not supported"))
        #expect(message.contains("pipeline --backend \(normalized)"))
    }

    /// `pipeline` runs the default recognizer unless told otherwise. The in-process commands
    /// decode only Parakeet, so it stays their default: a `stage-profile --sidecar` subtraction
    /// compares one engine, and `raw-decode` accepts its one backend with or without the flag.
    @Test func eachCommandDefaultsToTheBackendItCanRun() throws {
        let io = ["--input", "/tmp/manifest.jsonl", "--output", "/tmp/results.jsonl"]
        let rawDecode = ["raw-decode"] + io + ["--model", "/tmp/m.bin"]
        #expect(try BenchCLI.parse(["pipeline"] + io).backend == "granite")
        #expect(try BenchCLI.parse(["stage-profile"] + io).backend == "parakeet")
        #expect(try BenchCLI.parse(rawDecode).backend == "parakeet")
        #expect(try BenchCLI.parse(rawDecode + ["--backend", "parakeet"]).backend == "parakeet")
    }
}
