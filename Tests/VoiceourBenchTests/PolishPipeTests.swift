import Foundation
import Testing

@testable import VoiceourBench

@Suite("Polish benchmark pipe")
struct PolishPipeTests {
    @Test func refusesConflictingBatchOptions() throws {
        let args = ["--model", "model.gguf", "--stdio"]
        let cmd = try PolishCommand.parse(args + ["--draft-text-m", "24"])
        guard case .standard = cmd.io else {
            Issue.record("the benchmark pipe was not selected")
            return
        }
        for flags in [
            ["--input", "rows"], ["--output", "dir"], ["--reps", "2"], ["--guided"], ["--guided-stepwise"],
            ["--trace"], ["--config", "tag"], ["--model-repo", "repo"], ["--model-revision", "revision"],
        ] {
            #expect(throws: BenchError.self) { try PolishCommand.parse(args + flags) }
        }
    }

    @Test(arguments: [
        Data([0xFF, 0x0A]), Data([0, 0x0A]), Data("\n".utf8), Data("{\"private\":true}\n".utf8),
        Data(#"{"id":"x","input":"private\u0000text"}"#.utf8),
        Data(#"{"id":"private\u0000id","input":"text"}"#.utf8),
    ])
    func invalidFramesDoNotReachInferenceOrLeakText(_ frame: Data) throws {
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForWriting.write(contentsOf: frame)
        try input.fileHandleForWriting.close()
        do {
            try PolishPipe.serve(
                input: input.fileHandleForReading, output: output.fileHandleForWriting, readsDraft: true
            ) { _ in
                Issue.record("Inference received an invalid request")
                throw BenchError.io("unexpected request")
            }
            Issue.record("An invalid request must end the session")
        } catch let error as BenchError {
            #expect(!String(describing: error).contains("private"))
        }
    }

    @Test func borrowedReaderBoundsEachLineNotItsReadChunk() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("12345\nabc\n123456\n".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = JSONLLineReader(borrowing: pipe.fileHandleForReading, maxLineBytes: 5)
        #expect(try reader.nextLine() == "12345")
        #expect(try reader.nextLine() == "abc")
        #expect(throws: BenchError.self) { try reader.nextLine() }
    }

    @Test func borrowedReaderRefusesOversizedUnterminatedLine() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("123456".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = JSONLLineReader(borrowing: pipe.fileHandleForReading, maxLineBytes: 5)
        #expect(throws: BenchError.self) { try reader.nextLine() }
    }
}
