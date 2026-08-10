import Darwin
import Dispatch
import Foundation

enum OmpProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeoutMs: Int,
        environment: [String: String],
        currentDirectoryURL: URL? = nil
    ) async throws -> String {
        let invocation = OmpProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: OmpEnvironment.augmented(
                environment,
                workingDirectory: currentDirectoryURL
            ),
            currentDirectoryURL: currentDirectoryURL
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try invocation.runBlocking() }
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
    /// The child exited but its stdout could not be drained in full. Reporting
    /// this instead of returning the partial stream keeps a truncated read from
    /// being misdiagnosed downstream as malformed output.
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
    private static let pollMicroseconds: useconds_t = 10_000
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
            usleep(pollMicroseconds)
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

    func snapshot() -> (stdout: Data, stderrBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderrBytes)
    }
}

private final class OmpProcessInvocation: @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
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
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdin = stdin
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

        try? stdin.fileHandleForWriting.close()
        let capture = OmpProcessOutputCapture()
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async { [stdout] in
            defer { drains.leave() }
            do {
                capture.setStdout(try stdout.fileHandleForReading.readToEnd() ?? Data())
            } catch {}
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
            } catch {}
        }

        while process.isRunning {
            if terminationWasRequested() {
                closePipeHandles()
                terminateLaunchedProcessIfNeeded()
                break
            }
            usleep(10_000)
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
        guard drained else {
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

        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private func terminationWasRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }
}
