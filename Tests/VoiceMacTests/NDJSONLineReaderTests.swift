import Foundation
import Testing

@testable import VoiceMac

@Suite("NDJSONLineReader")
struct NDJSONLineReaderTests {
    @Test func returnsTwoLinesFromOneChunk() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nsecond\n".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading)

        #expect(try reader.nextLine() == "first")
        #expect(try reader.nextLine() == "second")
        #expect(try reader.nextLine() == nil)
    }

    @Test func framesLineLargerThanReadChunk() async throws {
        let pipe = Pipe()
        let expected = String(repeating: "x", count: 65_537)
        let bytes = Data((expected + "\n").utf8)
        let writer = Task.detached {
            try pipe.fileHandleForWriting.write(contentsOf: bytes)
            try pipe.fileHandleForWriting.close()
        }
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading)

        #expect(try reader.nextLine() == expected)
        try await writer.value
        #expect(try reader.nextLine() == nil)
    }

    @Test func returnsTrailingUnterminatedLineAtEOF() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("trailing".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading)

        #expect(try reader.nextLine() == "trailing")
        #expect(try reader.nextLine() == nil)
    }

    @Test func returnsNilForEmptyStream() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading)

        #expect(try reader.nextLine() == nil)
    }
}
