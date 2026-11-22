import Foundation

/// Local request/reply transport for the bench. It owns no files, timers, sockets, or child processes.
/// The caller owns the loaded runner. Each complete input line gets one reply before another line is read.
enum PolishPipe {
    static let maxLineBytes = 64 * 1024

    private struct Reply: Encodable {
        let id: String
        let output: String
        let ms: Double
        let drafted: Int
        let accepted: Int
    }

    static func serve(
        input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
        readsDraft: Bool, process: (PolishCase) throws -> PolishResult
    ) throws {
        let reader = JSONLLineReader(borrowing: input, maxLineBytes: maxLineBytes)
        let decoder = JSONDecoder()
        decoder.userInfo[PolishCase.readDraftText] = readsDraft
        let encoder = JSONEncoder()
        try output.write(contentsOf: Data("{\"event\":\"ready\",\"version\":1}\n".utf8))
        var number = 0
        while let line = try reader.nextLine() {
            number += 1
            guard !line.utf8.contains(0),
                let request = try? decoder.decode(PolishCase.self, from: Data(line.utf8)),
                !request.id.isEmpty, !request.input.isEmpty,
                !request.id.utf8.contains(0), !request.input.utf8.contains(0)
            else {
                // The text is private. Do not echo the line, id or a decoding error with its contents.
                throw BenchError.malformedInput(line: number, detail: "expected a UTF-8 polish request")
            }
            let result = try process(request)
            let reply = Reply(
                id: request.id, output: result.output, ms: result.ms,
                drafted: result.generation.drafted, accepted: result.generation.accepted)
            var data = try encoder.encode(reply)
            data.append(0x0A)
            try output.write(contentsOf: data)
        }
    }
}
