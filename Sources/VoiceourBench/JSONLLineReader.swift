import Darwin
import Foundation

final class JSONLLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    private let ownsHandle: Bool
    private let maxLineBytes: Int?
    init(url: URL) throws {
        ownsHandle = true
        maxLineBytes = nil
        do {
            self.handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BenchError.io("cannot open input \(url.path): \(BenchError.describe(error))")
        }
    }

    /// Borrow a blocking pipe, without closing the caller's descriptor when this reader is released.
    init(borrowing handle: FileHandle, maxLineBytes: Int) {
        self.handle = handle
        self.maxLineBytes = maxLineBytes
        ownsHandle = false
    }

    deinit {
        if ownsHandle { try? handle.close() }
    }

    func nextLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                try checkLength(buffer.distance(from: buffer.startIndex, to: newline))
                let lineData = buffer[..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try decodeLine(Data(lineData))
            }
            try checkLength(buffer.count)
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: true)
                return try decodeLine(lineData)
            }
            if maxLineBytes != nil {
                // One read(2) returns as soon as bytes arrive. A producer may wait for its reply before EOF.
                let count = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8192) { scratch in
                    let size = Darwin.read(handle.fileDescriptor, scratch.baseAddress!, scratch.count)
                    if size > 0 { buffer.append(scratch.baseAddress!, count: size) }
                    return size
                }
                if count == 0 { reachedEOF = true }
                if count < 0 && errno != EINTR { throw BenchError.io("cannot read standard input") }
                continue
            }
            do {
                if let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    reachedEOF = true
                }
            } catch {
                throw BenchError.io("cannot read input: \(BenchError.describe(error))")
            }
        }
    }

    private func checkLength(_ count: Int) throws {
        if let maxLineBytes, count > maxLineBytes { throw BenchError.io("input line exceeds byte limit") }
    }

    private func decodeLine(_ data: Data) throws -> String {
        var line = data
        if line.last == 0x0D {
            line.removeLast()
        }
        guard let string = String(data: line, encoding: .utf8) else {
            throw BenchError.io("input is not valid UTF-8")
        }
        return string
    }
}
