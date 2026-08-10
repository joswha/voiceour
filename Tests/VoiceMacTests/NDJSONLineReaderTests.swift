import Darwin
import Foundation
import Testing

@testable import VoiceMac

@Suite("NDJSONLineReader")
struct NDJSONLineReaderTests {
    @Test func returnsTwoLinesFromOneChunk() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nsecond\n".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.chunk")

        #expect(await reader.nextLine() == "first")
        #expect(await reader.nextLine() == "second")
        #expect(await reader.nextLine() == nil)
    }

    @Test func framesLineLargerThanReadChunk() async throws {
        let pipe = Pipe()
        let expected = String(repeating: "x", count: 65_537)
        let bytes = Data((expected + "\n").utf8)
        // A real thread, not a task: this write is larger than the kernel pipe
        // buffer, so it parks until the reader drains it, and a cooperative
        // thread parked here is the deadlock this reader exists to remove.
        let writer = Thread {
            try? pipe.fileHandleForWriting.write(contentsOf: bytes)
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.large")

        #expect(await reader.nextLine() == expected)
        #expect(await reader.nextLine() == nil)
    }

    @Test func returnsTrailingUnterminatedLineAtEOF() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("trailing".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.trailing")

        #expect(await reader.nextLine() == "trailing")
        #expect(await reader.nextLine() == nil)
    }

    @Test func returnsNilForEmptyStream() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.empty")

        #expect(await reader.nextLine() == nil)
    }

    @Test func deliversMalformedUTF8InsteadOfEndingTheStream() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([0x61, 0xFF, 0x0A]) + Data("next\n".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.malformed")

        // One bad byte must not read as end of stream: the line is delivered,
        // fails JSON decode upstream, and the stream keeps going.
        #expect(await reader.nextLine() == "a\u{FFFD}")
        #expect(await reader.nextLine() == "next")
        #expect(await reader.nextLine() == nil)
    }

    @Test func stopReleasesAWaiterOnASilentPipe() async throws {
        let pipe = Pipe()  // write end stays open and silent
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.silent")
        let pull = Task { await reader.nextLine() }
        reader.stop()

        #expect(await pull.value == nil)
        try? pipe.fileHandleForWriting.close()
    }

    @Test func cancellingOneConsumerLeavesTheReaderUsable() async throws {
        let pipe = Pipe()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.cancelled")
        let pull = Task { await reader.nextLine() }
        pull.cancel()
        #expect(await pull.value == nil)

        // A cancelled consumer must not latch the reader into end of stream for
        // everyone who comes after it.
        try pipe.fileHandleForWriting.write(contentsOf: Data("after-cancel\n".utf8))
        #expect(await reader.nextLine() == "after-cancel")

        reader.stop()
        try? pipe.fileHandleForWriting.close()
    }

    @Test func pausesReadingUntilAConsumerPulls() async throws {
        let pipe = Pipe()
        let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.backpressure")
        let payload = Data(repeating: 0x61, count: 512 << 10)  // no newline anywhere
        let wroteEverything = TestFlag()
        let writer = Thread {
            try? pipe.fileHandleForWriting.write(contentsOf: payload)
            wroteEverything.raise()
        }
        writer.start()

        // With nobody pulling, the framer stops draining at its high-water mark
        // and the rest stays in the kernel pipe, back-pressuring the writer
        // exactly as a blocking reader used to.
        await waitUntilTimeoutCondition(timeout: .seconds(5)) { reader.pendingBytesForTesting >= 64 << 10 }
        let paused = reader.pendingBytesForTesting
        #expect(paused >= 64 << 10)
        #expect(paused < 256 << 10)
        #expect(!wroteEverything.isRaised)

        // A pull outranks the mark: the drain re-arms, the write completes, and
        // end of stream delivers the unterminated payload as one line.
        let pull = Task { await reader.nextLine() }
        await waitUntilTimeoutCondition(timeout: .seconds(5)) { wroteEverything.isRaised }
        #expect(wroteEverything.isRaised)
        try? pipe.fileHandleForWriting.close()
        #expect(await pull.value == String(repeating: "a", count: payload.count))
        reader.stop()
    }

    @Test func stopReleasesTheDuplicatedDescriptor() async throws {
        for _ in 0..<32 {
            let pipe = Pipe()
            let reader = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.fd-release")
            reader.stop()
            await reader.stopped()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        // Label-scoped so a sidecar or refiner test running in parallel cannot
        // move the number.
        #expect(PipeByteSource.liveCount(labelPrefix: "test.fd-release") == 0)
    }

    @Test func droppedReaderReleasesItsDescriptorWithoutAStop() async throws {
        // The write end stays open for the whole test, so end of stream cannot
        // retire the source: only `deinit` can, which is the backstop for a
        // teardown path that forgets `stop()`.
        let pipe = Pipe()
        do {
            _ = NDJSONLineReader(reading: pipe.fileHandleForReading, label: "test.dropped")
        }

        await waitUntilTimeoutCondition { PipeByteSource.liveCount(labelPrefix: "test.dropped") == 0 }
        #expect(PipeByteSource.liveCount(labelPrefix: "test.dropped") == 0)
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }
}

@Suite("NDJSONLineFramer")
struct NDJSONLineFramerTests {
    @Test func framesLinesAcrossChunkBoundaries() {
        var framer = NDJSONLineFramer()
        framer.appendBytes(Data("fir".utf8))
        #expect(framer.takeLine() == nil)
        framer.appendBytes(Data("st\nsecond\nthi".utf8))

        #expect(framer.takeLine() == "first")
        #expect(framer.takeLine() == "second")
        #expect(framer.takeLine() == nil)
        #expect(framer.pendingBytes == 3)
    }

    @Test func endDeliversTheTrailingUnterminatedLineOnce() {
        var framer = NDJSONLineFramer()
        framer.appendBytes(Data("trailing".utf8))
        framer.end()

        #expect(framer.takeLine() == "trailing")
        #expect(framer.takeLine() == nil)
        #expect(framer.pendingBytes == 0)
    }

    @Test func endOnAnEmptyBufferHasNoLine() {
        var framer = NDJSONLineFramer()
        framer.end()

        #expect(framer.takeLine() == nil)
    }

    @Test func newlineOnlyInputFramesEmptyLines() {
        var framer = NDJSONLineFramer()
        framer.appendBytes(Data("\n\n".utf8))

        #expect(framer.takeLine() == "")
        #expect(framer.takeLine() == "")
        #expect(framer.takeLine() == nil)
    }

    @Test func aPartialLineBeyondTheCapEndsTheStream() {
        var framer = NDJSONLineFramer()
        framer.appendBytes(Data(repeating: 0x61, count: NDJSONLineFramer.maxPendingBytes))

        // A child that never emits a newline must not grow the heap without
        // bound; the stream reads as ended instead.
        #expect(framer.ended)
        #expect(framer.pendingBytes == 0)
        #expect(framer.takeLine() == nil)
    }
}

extension NDJSONLineFramer {
    /// Test-only convenience: the production sink hands over raw buffers.
    fileprivate mutating func appendBytes(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }
}

/// `Thread` is not `Sendable`, so a test observes its progress through this
/// instead of `Thread.isFinished`.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() { lock.withLock { raised = true } }
}
