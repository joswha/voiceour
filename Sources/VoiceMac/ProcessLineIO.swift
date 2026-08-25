import Darwin
import Dispatch
import Foundation

// Teardown invariant for every reader in this file: it drains a *duplicate* of
// the caller's descriptor, so closing the caller's `FileHandle` no longer ends
// it. Every teardown path MUST call `stop()` on every source it created.
// Today those paths are `SidecarASRClient.terminateRunning`, `closeStarting`
// and `failAllAndStop`, and nothing else tears a reader down. `deinit`
// closes the duplicate as a backstop for a dropped reader; it is not a
// substitute for stopping one, because a reader is kept alive by the task
// suspended in `nextLine()`.

/// Nonblocking byte pump for one read end of a pipe.
///
/// A dispatch read source signals readability on a private serial queue; the
/// handler drains the descriptor with nonblocking `read(2)` until `EAGAIN` and
/// hands each chunk to `onBytes`. No thread is ever parked on the descriptor,
/// which is the whole point: Swift's cooperative pool has a fixed width, so a
/// blocking read parked on one of its threads is never rescheduled elsewhere
/// and enough of them stop the pool -- including the `Task.sleep` that
/// implements a client's own timeout -- from running at all.
///
/// Descriptor ownership: the source `dup(2)`s the handle's descriptor at init,
/// while the handle is still open (`fileDescriptor` raises an ObjC exception on
/// a closed handle), and closes the duplicate from the source's cancel handler.
/// Callers keep closing their own `FileHandle` exactly as before; the two
/// closes are independent, so teardown can no longer pull a descriptor out from
/// under a read or leave a read aimed at a recycled fd. `FileHandle` read APIs
/// are never used here: `availableData` answers a failed `read(2)` by raising an
/// ObjC exception that no Swift `catch` can take, terminating the process, and
/// teardown on another thread is exactly the case that makes a read fail.
///
/// `O_NONBLOCK` is set on the duplicate, which shares its open file description
/// with the caller's handle, so that handle becomes nonblocking too. Nothing
/// else may read it -- a `read(upToCount:)` there would answer `EAGAIN` with
/// empty data, which every caller in this module reads as end of stream. The
/// pipe's write end is a separate description, so the child is unaffected.
final class PipeByteSource: @unchecked Sendable {
    /// Serial queue that owns the drain. `onBytes`, `onEnd` and
    /// `wantsMoreBytes` always run on it, so a consumer can confine its own
    /// state to this queue instead of taking a second lock.
    let queue: DispatchQueue

    private let state: State
    private let source: DispatchSourceRead?

    private static let liveLock = NSLock()
    private static var liveLabels: [String: Int] = [:]

    /// Sources holding a duplicated descriptor right now, counted by label. A
    /// teardown path that forgets `stop()` shows up here, which is the one
    /// failure mode a leaked reader shares with a leaked thread. Scoped by
    /// label so a test can measure its own sources while other suites run.
    static func liveCount(labelPrefix: String) -> Int {
        liveLock.withLock {
            liveLabels.reduce(0) { $1.key.hasPrefix(labelPrefix) ? $0 + $1.value : $0 }
        }
    }

    private enum DrainOutcome {
        /// The pipe is empty; wait for the next readability event.
        case waiting
        /// End of stream, or a descriptor that can no longer be read.
        case ended
        /// The consumer is holding all it can take; stop reading until it pulls.
        case paused
    }

    /// Touched only on `queue`.
    private final class State: @unchecked Sendable {
        let fd: Int32
        let scratch: UnsafeMutableRawBufferPointer
        let onBytes: @Sendable (UnsafeRawBufferPointer) -> Void
        let onEnd: @Sendable () -> Void
        let wantsMoreBytes: @Sendable () -> Bool
        var ended = false
        var suspended = false
        var stopRequested = false
        var descriptorClosed = false
        var stopWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            fd: Int32,
            capacity: Int,
            onBytes: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
            onEnd: @escaping @Sendable () -> Void,
            wantsMoreBytes: @escaping @Sendable () -> Bool
        ) {
            self.fd = fd
            self.scratch = .allocate(byteCount: capacity, alignment: 16)
            self.onBytes = onBytes
            self.onEnd = onEnd
            self.wantsMoreBytes = wantsMoreBytes
        }

        deinit { scratch.deallocate() }

        /// Drains until the pipe is empty, the stream ends, or the consumer is
        /// full. Never blocks.
        func drain() -> DrainOutcome {
            while true {
                if ended { return .ended }
                guard wantsMoreBytes() else { return .paused }
                let count = Darwin.read(fd, scratch.baseAddress, scratch.count)
                if count > 0 {
                    onBytes(UnsafeRawBufferPointer(start: scratch.baseAddress, count: count))
                    continue
                }
                if count == 0 {
                    end()
                    return .ended
                }
                if errno == EINTR { continue }
                // EWOULDBLOCK is EAGAIN on Darwin: the pipe is empty.
                if errno == EAGAIN { return .waiting }
                // EBADF/EIO and friends read as end of stream, which is what a
                // vanished child means to every caller here.
                end()
                return .ended
            }
        }

        func end() {
            guard !ended else { return }
            ended = true
            onEnd()
        }

        func releaseStopWaiters() {
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// - Parameter wantsMoreBytes: asked before every `read(2)`. Answering
    ///   false pauses the source, which leaves the bytes in the kernel pipe and
    ///   back-pressures the child; `resumeDeliveryFromQueue()` re-arms it.
    init(
        reading handle: FileHandle,
        qos: DispatchQoS,
        label: String,
        capacity: Int = 8192,
        onBytes: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onEnd: @escaping @Sendable () -> Void,
        wantsMoreBytes: @escaping @Sendable () -> Bool = { true }
    ) {
        queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
        let duplicate = dup(handle.fileDescriptor)
        let state = State(
            fd: duplicate,
            capacity: capacity,
            onBytes: onBytes,
            onEnd: onEnd,
            wantsMoreBytes: wantsMoreBytes
        )
        self.state = state
        Self.changeLiveCount(of: label, by: 1)

        guard duplicate >= 0 else {
            // Out of descriptors: behave exactly like an exhausted stream, so a
            // caller sees what a child that wrote nothing would give it.
            source = nil
            queue.async {
                state.end()
                state.descriptorClosed = true
                state.releaseStopWaiters()
                Self.changeLiveCount(of: label, by: -1)
            }
            return
        }

        _ = fcntl(duplicate, F_SETFL, fcntl(duplicate, F_GETFL, 0) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: duplicate, queue: queue)
        self.source = source
        // The handlers capture `state` and `source` but never `self`, so no
        // retain cycle keeps this object alive and `deinit` stays reachable as
        // the backstop that closes the duplicate. Cancellation is what releases
        // the handlers, and with them the source's reference to itself.
        source.setEventHandler { [state] in
            switch state.drain() {
            case .waiting:
                return
            case .ended:
                source.cancel()
            case .paused:
                // A stop already in flight must not be parked behind a
                // suspension: a suspended source never runs its cancel handler.
                guard !state.stopRequested else { return }
                state.suspended = true
                source.suspend()
            }
        }
        source.setCancelHandler { [state] in
            state.end()
            Darwin.close(duplicate)
            state.descriptorClosed = true
            state.releaseStopWaiters()
            Self.changeLiveCount(of: label, by: -1)
        }
        source.resume()
    }

    deinit {
        guard let source else { return }
        Self.requestStop(source: source, state: state, on: queue)
    }

    /// Ends delivery. Idempotent, never blocks, safe from inside an actor.
    /// Dispatch guarantees the cancel handler runs exactly once, after any
    /// in-flight event handler, and that no event handler runs after it.
    func stop() {
        guard let source else { return }
        Self.requestStop(source: source, state: state, on: queue)
    }

    /// Resumes once the source has ended and released its descriptor.
    /// Cancelling the awaiting task stops the source.
    func stopped() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [state] in
                    if state.descriptorClosed {
                        continuation.resume()
                    } else {
                        state.stopWaiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// `stopped()` with a deadline. End of stream is not guaranteed to arrive:
    /// a surviving grandchild can hold the child's write end open forever, so
    /// nothing in the product may wait on this unbounded. Giving up stops the
    /// source, since the only reason to wait is to use what it collected.
    func stopped(withinMilliseconds milliseconds: Int) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.stopped() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(milliseconds, 1)) * 1_000_000)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Re-arms a source that backpressure paused. Cheap and safe to call on
    /// every pull: it does nothing unless the drain actually stopped.
    func resumeDeliveryFromQueue() {
        guard let source else { return }
        dispatchPrecondition(condition: .onQueue(queue))
        guard state.suspended, !state.stopRequested, !state.ended, state.wantsMoreBytes() else { return }
        state.suspended = false
        source.resume()
    }

    private static func requestStop(source: DispatchSourceRead, state: State, on queue: DispatchQueue) {
        source.cancel()
        queue.async {
            state.stopRequested = true
            if state.suspended {
                state.suspended = false
                source.resume()
            }
        }
    }

    private static func changeLiveCount(of label: String, by delta: Int) {
        liveLock.withLock {
            let live = (liveLabels[label] ?? 0) + delta
            if live == 0 {
                liveLabels.removeValue(forKey: label)
            } else {
                liveLabels[label] = live
            }
        }
    }
}

/// Pure NDJSON line framing over a byte buffer: no I/O, no synchronization, no
/// continuations. Its owner confines it to one queue, which is also what makes
/// the byte logic testable without a pipe.
struct NDJSONLineFramer {
    /// A child that never emits a newline must not grow the app's heap without
    /// bound. Past this the partial line is dropped and the stream reads as
    /// ended, which every caller here treats as a child worth discarding.
    static let maxPendingBytes = 16 << 20

    private var buffer: [UInt8] = []
    /// First unconsumed byte.
    private var start = 0
    /// First byte not yet searched for a newline.
    private var scanned = 0
    private(set) var ended = false

    /// Bytes framed but not yet handed to a consumer.
    var pendingBytes: Int { buffer.count - start }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
        if firstNewline() == nil, pendingBytes >= Self.maxPendingBytes {
            reset()
            ended = true
        }
    }

    mutating func end() {
        ended = true
    }

    /// A newline-terminated line (newline stripped), the trailing unterminated
    /// line once the stream has ended, or nil while more bytes may still
    /// arrive.
    ///
    /// Decodes with UTF-8 replacement rather than failing: a malformed line is
    /// delivered, fails JSON decode and is ignored, where returning nil would
    /// have meant end of stream and torn down a healthy child over one bad
    /// byte.
    mutating func takeLine() -> String? {
        if let newline = firstNewline() {
            let line = String(decoding: buffer[start..<newline], as: UTF8.self)
            start = newline + 1
            scanned = start
            compact()
            return line
        }
        guard ended, start < buffer.count else { return nil }
        let line = String(decoding: buffer[start...], as: UTF8.self)
        reset()
        return line
    }

    /// Index of the next newline, advancing the scan cursor past the bytes it
    /// ruled out so growing buffers are searched once.
    private mutating func firstNewline() -> Int? {
        if let newline = buffer[scanned...].firstIndex(of: 0x0A) { return newline }
        scanned = buffer.count
        return nil
    }

    private mutating func compact() {
        guard start >= 8192, start * 2 >= buffer.count else { return }
        buffer.removeFirst(start)
        scanned -= start
        start = 0
    }

    private mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        start = 0
        scanned = 0
    }
}

/// Buffered NDJSON line reader over a pipe.
///
/// Bytes arrive continuously from a `PipeByteSource` and are framed as they
/// land, so a consumer that stops pulling does not lose what the child already
/// wrote. One instance owns every read from its handle, so all consumers of
/// that pipe must share it. The NDJSON clients use it strictly sequentially --
/// the startup task first, then the reader loop once startup completes -- and
/// that is the contract: at most one `nextLine()` outstanding at a time.
final class NDJSONLineReader: @unchecked Sendable {
    private let deliveries: Deliveries
    private let source: PipeByteSource
    private let ticketLock = NSLock()
    private var lastTicket: UInt64 = 0

    /// Framing plus the pull that is waiting for it. Touched only on
    /// `source.queue`.
    private final class Deliveries: @unchecked Sendable {
        /// Stop reading once this much is framed and unclaimed, so the ceiling
        /// stays the kernel pipe buffer -- which back-pressures the child --
        /// instead of this process's heap. A pull always overrides it, so a
        /// line longer than the mark can never deadlock the reader.
        private static let highWaterBytes = 64 << 10

        private var framer = NDJSONLineFramer()
        private var waiters: [(ticket: UInt64, continuation: CheckedContinuation<String?, Never>)] = []
        /// Pulls cancelled before they reached this queue.
        private var cancelledTickets: Set<UInt64> = []
        private var highestInstalledTicket: UInt64 = 0

        var pendingBytes: Int { framer.pendingBytes }

        func wantsMoreBytes() -> Bool {
            !waiters.isEmpty || framer.pendingBytes < Self.highWaterBytes
        }

        func append(_ bytes: UnsafeRawBufferPointer) {
            framer.append(bytes)
            deliver()
        }

        func end() {
            framer.end()
            deliver()
        }

        func install(_ ticket: UInt64, _ continuation: CheckedContinuation<String?, Never>) {
            highestInstalledTicket = max(highestInstalledTicket, ticket)
            if cancelledTickets.remove(ticket) != nil {
                // The cancellation handler beat the pull to this queue.
                continuation.resume(returning: nil)
                return
            }
            if !waiters.isEmpty {
                // Loud in debug, harmless in release: a second pull is served
                // the next line rather than a nil that every call site here
                // would read as end of stream and answer by killing the child.
                assertionFailure("NDJSONLineReader.nextLine() must not be called concurrently")
            }
            waiters.append((ticket, continuation))
            deliver()
        }

        /// The awaiting task was cancelled. Releases just that pull: the reader
        /// stays usable, because ending it here would turn one cancelled
        /// consumer into permanent end of stream for every later caller.
        func cancel(_ ticket: UInt64) {
            if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(returning: nil)
                return
            }
            // A cancellation handler runs before its own pull when the task was
            // already cancelled, so an unknown ticket above the watermark is a
            // pull still on its way here. Tickets are issued in order and, with
            // one pull outstanding at a time, installed in that order, so a
            // ticket at or below the watermark is one that already resumed.
            guard ticket > highestInstalledTicket else { return }
            cancelledTickets.insert(ticket)
        }

        private func deliver() {
            while !waiters.isEmpty {
                if let line = framer.takeLine() {
                    waiters.removeFirst().continuation.resume(returning: line)
                } else if framer.ended {
                    waiters.removeFirst().continuation.resume(returning: nil)
                } else {
                    return
                }
            }
        }
    }

    init(reading handle: FileHandle, label: String, qos: DispatchQoS = .userInitiated) {
        let deliveries = Deliveries()
        self.deliveries = deliveries
        source = PipeByteSource(
            reading: handle,
            qos: qos,
            label: label,
            onBytes: { deliveries.append($0) },
            onEnd: { deliveries.end() },
            wantsMoreBytes: { deliveries.wantsMoreBytes() }
        )
    }

    /// The next line, the final unterminated line at end of stream, or nil once
    /// the stream is exhausted, the reader was stopped, or the awaiting task was
    /// cancelled. Suspends on a continuation; never occupies a thread.
    func nextLine() async -> String? {
        let ticket = issueTicket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                source.queue.async { [deliveries, source] in
                    deliveries.install(ticket, continuation)
                    // A pull outranks the high-water mark, so re-arm a drain
                    // that backpressure paused.
                    source.resumeDeliveryFromQueue()
                }
            }
        } onCancel: {
            source.queue.async { [deliveries] in deliveries.cancel(ticket) }
        }
    }

    /// Ends the stream: any waiter resumes with the trailing line and then nil,
    /// the source is cancelled, the duplicated descriptor is closed. Idempotent,
    /// never blocks, safe to call from inside an actor.
    func stop() { source.stop() }

    /// Resumes once the reader has stopped and released its descriptor.
    func stopped() async { await source.stopped() }

    /// Bytes framed but not yet consumed. Exists for the backpressure test:
    /// pausing the drain is invisible from outside the queue.
    var pendingBytesForTesting: Int {
        source.queue.sync { deliveries.pendingBytes }
    }

    private func issueTicket() -> UInt64 {
        ticketLock.withLock {
            lastTicket += 1
            return lastTicket
        }
    }
}

/// Forwards a child process's stderr onward until end of stream.
/// The caller owns the returned source and stops it at teardown.
///
/// `sink` is a value seam in the shape AGENTS.md already sanctions for
/// `GeneralPasteboard.writeOverride`: nil on every shipping path, so production
/// forwards to the host's stderr exactly as before. It exists because a test
/// that deliberately floods stderr must not put those bytes on the real
/// descriptor. A single 256 KiB line with no newline stalls a CI log consumer,
/// the stall backpressures through swiftpm's 64 KiB capture pipe, and the whole
/// test binary wedges — measured: under a stalled consumer the run hung for the
/// full 180 s and exactly 65,536 bytes escaped.
func forwardStderrToHost(
    from handle: FileHandle,
    sink: (@Sendable (UnsafeRawBufferPointer) -> Void)? = nil
) -> PipeByteSource {
    PipeByteSource(
        reading: handle,
        qos: .utility,
        label: "voiceour.child.stderr",
        onBytes: sink ?? { writeToHostStderr($0) },
        onEnd: {}
    )
}

/// How long a chunk waits for room in the host's stderr before it is dropped.
private let hostStderrWriteTimeoutMilliseconds: Int32 = 100

/// Writes to the host's stderr without parking on it.
///
/// `write(2)` rather than `FileHandle.standardError.write(_:)`: Foundation
/// answers a failed write on a shared handle with an uncatchable ObjC
/// exception. `fd 2` is process-wide, so it cannot be made nonblocking either --
/// the flag lives on the open file description and would change every other
/// writer in the process. Instead each slice waits for `POLLOUT`, which a pipe
/// raises only when at least `PIPE_BUF` bytes of room exist, and then writes at
/// most `PIPE_BUF` bytes, so the write itself cannot block.
///
/// A host that stops reading for longer than the timeout loses the rest of the
/// chunk. That is deliberate: this runs on the queue that drains the child's
/// stderr pipe, so waiting here fills that pipe and back-pressures the child's
/// protocol stream -- and the bytes would be going to a reader that is not
/// reading anyway.
private func writeToHostStderr(_ bytes: UnsafeRawBufferPointer) {
    guard var base = bytes.baseAddress else { return }
    var remaining = bytes.count
    while remaining > 0 {
        var poller = pollfd(fd: STDERR_FILENO, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, hostStderrWriteTimeoutMilliseconds)
        if ready < 0 {
            if errno == EINTR { continue }
            return
        }
        guard ready > 0, poller.revents & Int16(POLLOUT) != 0 else { return }
        let written = Darwin.write(STDERR_FILENO, base, min(remaining, Int(PIPE_BUF)))
        if written > 0 {
            base = base.advanced(by: written)
            remaining -= written
            continue
        }
        if written < 0 && errno == EINTR { continue }
        return  // host stderr is gone; drop the rest, as before
    }
}
