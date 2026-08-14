import Darwin
import Dispatch
import Foundation

private let processPollMicroseconds: useconds_t = 10_000

/// Runs a blocking body on a thread of its own and suspends the caller until it
/// finishes.
///
/// Swift's cooperative pool is a fixed number of threads, so a blocking syscall
/// parked on one of them is never rescheduled elsewhere: park enough and the
/// pool stops running anything, including the sibling `Task.sleep` that
/// enforces this call's own timeout. `OmpProcessInvocation.runBlocking` polls
/// the child for its entire lifetime, so it gets a thread that is ours to park.
/// The continuation is resumed exactly once, by the thread body; cancellation
/// reaches the child through `invocation.terminate()`, which is what ends the
/// poll loop.
private func withDedicatedThread<T: Sendable>(
    name: String,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.name = name
        thread.stackSize = 512 << 10
        thread.start()
    }
}

enum OmpProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeoutMs: Int,
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        shadowCredentials: Bool = true
    ) async throws -> String {
        let invocation = OmpProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: OmpEnvironment.augmented(
                environment,
                workingDirectory: currentDirectoryURL,
                shadowCredentials: shadowCredentials
            ),
            currentDirectoryURL: currentDirectoryURL
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withDedicatedThread(name: "voiceour.omp.run") { try invocation.runBlocking() }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000)
                invocation.terminate()
                throw OmpProcessError.timeout
            }

            defer {
                group.cancelAll()
                invocation.terminate()
            }

            guard let result = try await group.next() else {
                throw OmpProcessError.launchFailed("no result")
            }
            return result
        }
    }
}

enum OmpProcessError: Error, Equatable {
    case launchFailed(String)
    case timeout
    case nonzeroExit(Int32, stderrBytes: Int)
    /// The child exited but stdout or stderr could not be drained in full.
    /// Reporting this instead of returning potentially partial output keeps a
    /// truncated read from being misdiagnosed downstream as malformed output.
    case outputTruncated

    var shortMessage: String {
        switch self {
        case .launchFailed(let message):
            "launch failed: \(message)"
        case .timeout:
            "omp timed out"
        case .nonzeroExit(let status, let stderrBytes):
            stderrBytes == 0
                ? "omp exited with status \(status)"
                : "omp exited with status \(status) (stderr: \(stderrBytes) bytes)"
        case .outputTruncated:
            "omp output truncated"
        }
    }
}

/// Bounded teardown for the launched process and its descendants. The caller
/// closes all owned pipes first; signals are limited to the observed child tree.
enum OmpProcessTermination {
    private static let termGraceNanoseconds: UInt64 = 100_000_000
    private static let killGraceNanoseconds: UInt64 = 300_000_000

    static func terminateAndReap(_ process: Process) {
        guard process.isRunning else { return }
        let rootPID = process.processIdentifier
        var descendants = Set(descendantPIDs(of: rootPID))
        signal(SIGTERM, rootPID: rootPID, descendants: descendants)
        if waitUntilStopped(
            process,
            descendants: descendants,
            for: termGraceNanoseconds
        ) {
            process.waitUntilExit()
            return
        }

        descendants.formUnion(descendantPIDs(of: rootPID))
        signalDescendants(SIGKILL, descendants: descendants)
        // A waiting shell normally exits as soon as its killed helper is
        // reaped. Give it that chance before killing the parent; otherwise the
        // helper becomes an orphaned zombie and can outlive this deadline.
        if waitUntilStopped(
            process,
            descendants: descendants,
            for: termGraceNanoseconds
        ) {
            process.waitUntilExit()
            return
        }
        _ = Darwin.kill(rootPID, SIGKILL)
        _ = waitUntilStopped(
            process,
            descendants: descendants,
            for: killGraceNanoseconds
        )
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private static func signal(
        _ signal: Int32,
        rootPID: pid_t,
        descendants: Set<pid_t>
    ) {
        signalDescendants(signal, descendants: descendants)
        _ = Darwin.kill(rootPID, signal)
    }

    private static func signalDescendants(_ signal: Int32, descendants: Set<pid_t>) {
        for pid in descendants.sorted(by: >) {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func waitUntilStopped(
        _ process: Process,
        descendants: Set<pid_t>,
        for duration: UInt64
    ) -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while process.isRunning || descendants.contains(where: isAlive) {
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- start >= duration {
                return false
            }
            usleep(processPollMicroseconds)
        }
        return true
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var discovered = Set<pid_t>()
        var pending = [rootPID]
        while let parent = pending.popLast() {
            for child in childPIDs(of: parent)
            where child > 0 && discovered.insert(child).inserted {
                pending.append(child)
            }
        }
        return Array(discovered)
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4_096 {
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return [] }
            // Unlike proc_pidinfo, proc_listchildpids returns a pid count, not
            // a byte count.
            if count < capacity {
                return Array(children.prefix(Int(count)))
            }
            capacity *= 2
        }
        return []
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

private final class OmpProcessOutputCapture: @unchecked Sendable {
    private static let stderrByteLimit = 8_192
    private let lock = NSLock()
    private var stdout = Data()
    private var stderrBytes = 0
    private var drainFailed = false

    func setStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func addStderrBytes(_ count: Int) {
        lock.lock()
        stderrBytes = min(stderrBytes + count, Self.stderrByteLimit)
        lock.unlock()
    }

    func recordDrainFailure() {
        lock.lock()
        drainFailed = true
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderrBytes: Int, drainFailed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderrBytes, drainFailed)
    }
}

private final class OmpProcessInvocation: @unchecked Sendable {
    private let process: Process
    private let stdout: Pipe
    private let stderr: Pipe
    private let lock = NSLock()
    private var terminationRequested = false
    private var pipesClosed = false
    private var teardownStarted = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?
    ) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        // `omp` blocks until stdin reaches EOF: measured, `omp models --json`
        // answers in 0.8 s from `/dev/null` and never returns at all behind a
        // pipe nobody closes. A `Pipe` whose write end this process closes
        // right after spawn is the narrower version of the same hazard —
        // `posix_spawn` hands every descriptor open at that instant to any
        // sibling child launched in the window before the close, and that
        // sibling then holds this child's stdin open for its own lifetime. The
        // two probes behind the Refinement pane now run concurrently, so that
        // window is real. `nullDevice` is at EOF from the first read and has no
        // write end for anyone to inherit.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func runBlocking() throws -> String {
        guard !terminationWasRequested() else {
            throw OmpProcessError.timeout
        }

        do {
            try process.run()
        } catch {
            throw terminationWasRequested()
                ? OmpProcessError.timeout
                : OmpProcessError.launchFailed(error.localizedDescription)
        }

        if terminationWasRequested() {
            closePipeHandles()
            terminateLaunchedProcessIfNeeded()
            throw OmpProcessError.timeout
        }

        let capture = OmpProcessOutputCapture()
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async { [stdout] in
            defer { drains.leave() }
            do {
                capture.setStdout(try stdout.fileHandleForReading.readToEnd() ?? Data())
            } catch {
                capture.recordDrainFailure()
            }
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async { [stderr] in
            defer { drains.leave() }
            do {
                while let chunk = try stderr.fileHandleForReading.read(upToCount: 8_192),
                    !chunk.isEmpty
                {
                    capture.addStderrBytes(chunk.count)
                }
            } catch {
                capture.recordDrainFailure()
            }
        }

        while process.isRunning {
            if terminationWasRequested() {
                closePipeHandles()
                terminateLaunchedProcessIfNeeded()
                break
            }
            usleep(processPollMicroseconds)
        }

        // The child has exited, so the only thing that can still stall a drain is
        // a surviving descendant holding the write end open. That case is why the
        // wait stays bounded — but 250 ms was short enough that a loaded machine
        // could miss a `.utility` scheduling slot and hand back an empty stdout
        // that downstream then misreported as malformed output.
        let drained = drains.wait(timeout: .now() + .seconds(2)) == .success
        let result = capture.snapshot()
        if terminationWasRequested() {
            throw OmpProcessError.timeout
        }
        guard process.terminationStatus == 0 else {
            throw OmpProcessError.nonzeroExit(
                process.terminationStatus,
                stderrBytes: result.stderrBytes
            )
        }
        // Keep the timeout check above this guard: timeout/cancellation closes the read handles
        // concurrently and can surface as EBADF/EIO. Reaching here without a termination request
        // makes a recorded drain failure a real I/O error rather than teardown noise.
        guard drained, !result.drainFailed else {
            // Unblock the stuck reader before giving up on it.
            closePipeHandles()
            throw OmpProcessError.outputTruncated
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func terminate() {
        lock.lock()
        let firstRequest = !terminationRequested
        terminationRequested = true
        lock.unlock()
        guard firstRequest else { return }

        closePipeHandles()
        terminateLaunchedProcessIfNeeded()
    }

    private func terminateLaunchedProcessIfNeeded() {
        lock.lock()
        let shouldTerminate = !teardownStarted && process.isRunning
        if shouldTerminate {
            teardownStarted = true
        }
        lock.unlock()
        if shouldTerminate {
            OmpProcessTermination.terminateAndReap(process)
        }
    }

    private func closePipeHandles() {
        lock.lock()
        let shouldClose = !pipesClosed
        pipesClosed = true
        lock.unlock()
        guard shouldClose else { return }

        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private func terminationWasRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }
}
