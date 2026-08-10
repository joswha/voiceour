import Darwin
import Foundation

/// Buffered NDJSON line framer over a pipe FileHandle.
///
/// One instance owns all reads from its handle: it may buffer bytes past a
/// newline, so every consumer of the same pipe must share the same reader.
/// The NDJSON clients use it strictly sequentially (startup task first, then
/// the reader loop after the startup task completes), never concurrently,
/// which is why the unsynchronized buffer is safe (`@unchecked Sendable`).
final class NDJSONLineReader: @unchecked Sendable {
    private let handle: FileHandle
    /// Captured while the handle is open: `fileDescriptor` raises an ObjC
    /// exception once the handle is closed, and teardown can close it while a
    /// read is parked.
    private let descriptor: Int32
    private var buffer = Data()

    init(reading handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    /// Returns the next newline-terminated line (newline stripped), the final
    /// unterminated line at EOF, or nil once the stream is exhausted.
    ///
    /// Reads the descriptor directly rather than through `availableData`: a
    /// teardown on another thread can close this handle mid-read, and
    /// `availableData` answers a failed `read(2)` by raising an ObjC exception
    /// that no Swift `catch` can take, terminating the process. A closed or
    /// broken descriptor reads as end of stream, which is what a vanished child
    /// means to every caller here.
    func nextLine() throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer.subdata(in: buffer.startIndex..<newlineIndex), encoding: .utf8)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return line
            }
            let chunk = readAvailable()
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return line
            }
            buffer.append(chunk)
        }
    }

    /// One blocking `read(2)`, returning whatever the child has written so far.
    /// Empty means end of stream: real EOF, or a descriptor torn down under us.
    private func readAvailable() -> Data {
        var scratch = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = scratch.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(scratch[0..<count]) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            return Data()
        }
    }
}

/// Forwards a child process's stderr to the host stderr until EOF.
func drainStderrToHost(from handle: FileHandle) {
    while true {
        do {
            guard let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty else { return }
            try FileHandle.standardError.write(contentsOf: chunk)
        } catch {
            return
        }
    }
}
