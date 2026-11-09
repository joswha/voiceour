import Darwin
import Dispatch
import Foundation
import Synchronization

/// What one `tern` invocation produced.
enum TernRunOutcome: Equatable, Sendable {
    /// Exit status 0, stdout closed, and no more than the output cap written to it.
    case output(Data)
    /// The launch failed, the child exited non-zero or on a signal, it wrote more
    /// than the output cap, or the awaiting task was cancelled.
    case failed
    /// The deadline passed before the child exited and closed stdout.
    case timedOut
}

/// Runs one short-lived command-line child — Tern's bundled `tern` — and owns it
/// until it is gone (docs/runtime.md › Agent session binding).
///
/// argv only, never a shell; the environment is exactly the given dictionary;
/// stdin and stderr are `/dev/null`; stdout is drained concurrently while the
/// child runs, so a full pipe never stalls it, and a child that writes more than
/// `outputCap` bytes is cut off. Every early end — the deadline, the cap, or the
/// awaiting task being cancelled — is the same bounded teardown: SIGTERM, up to
/// 100 ms for the termination handler, then SIGKILL. `run` returns only once
/// that teardown has finished, so no caller outlives its child unknowingly.
/// Nothing here ever calls `waitUntilExit()`: that join is unbounded.
struct TernCommandRunner: Sendable {
    var deadline: Duration
    var outputCap: Int
    var environment: [String: String]
    /// Told the child's pid right after it launches. Tests use it to prove a
    /// child cut short no longer exists; production passes nil.
    var onLaunch: (@Sendable (pid_t) -> Void)?

    init(
        deadline: Duration = .seconds(1),
        outputCap: Int = 1 << 20,
        environment: [String: String],
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.deadline = deadline
        self.outputCap = outputCap
        self.environment = environment
        self.onLaunch = onLaunch
    }

    func run(executable: URL, arguments: [String]) async -> TernRunOutcome {
        let child = TernChild(outputCap: outputCap)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.start(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    deadline: deadline,
                    onLaunch: onLaunch,
                    continuation: continuation
                )
            }
        } onCancel: {
            child.interrupt(with: .failed)
        }
    }
}

/// One launched child and everything that can end it: its exit, the end of its
/// stdout, the cap, the deadline and cancellation. Each of those runs on its
/// own thread — the termination handler on Foundation's, the drain on the pipe
/// source's queue, the timers on `timers`, cancellation on the canceller's — so
/// all of them meet in `state`, and exactly one of them resolves the run.
///
/// `Sendable` without an escape hatch: the stored properties are immutable and
/// every mutable field lives in the mutex.
private final class TernChild: Sendable {
    private struct State {
        var continuation: CheckedContinuation<TernRunOutcome, Never>?
        var process: Process?
        var source: PipeByteSource?
        var pid: pid_t = 0
        var output = Data()
        var outputEnded = false
        var exited = false
        var exitedCleanly = false
        /// The outcome a run cut short resolves with, set by the first
        /// interruption. A run interrupted before launch never launches.
        var interruption: TernRunOutcome?
        var finished = false

        /// Detaches everything the run held so the caller can release it
        /// outside the lock. Output that is not handed back is zeroed first:
        /// `tern` output names panes, programs and working directories.
        mutating func finish(_ outcome: TernRunOutcome) -> Finish {
            finished = true
            let finish = Finish(continuation: continuation, source: source, outcome: outcome)
            continuation = nil
            source = nil
            process = nil
            if case .output = outcome {
                output = Data()
            } else {
                output.resetBytes(in: 0..<output.count)
                output = Data()
            }
            return finish
        }
    }

    /// What a resolved run still has to release, taken out of the lock.
    /// Nothing here holds the `Process`: once `state` lets go of it, its
    /// termination handler's reference back to this run is no cycle.
    private struct Finish: Sendable {
        var continuation: CheckedContinuation<TernRunOutcome, Never>?
        var source: PipeByteSource?
        var outcome: TernRunOutcome

        /// Stops the drain — every reader teardown MUST stop its source, see
        /// `ProcessLineIO.swift` — and wakes the caller.
        func run() {
            source?.stop()
            continuation?.resume(returning: outcome)
        }
    }

    private enum Interruption {
        case ignored
        case finish(Finish)
        case terminate(Process)
    }

    /// How long SIGTERM gets before SIGKILL.
    private static let terminationGrace: DispatchTimeInterval = .milliseconds(100)

    private let state = Mutex(State())
    private let outputCap: Int
    private let timers = DispatchQueue(label: "voiceour.tern.child", qos: .userInitiated)

    init(outputCap: Int) {
        self.outputCap = outputCap
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        deadline: Duration,
        onLaunch: (@Sendable (pid_t) -> Void)?,
        continuation: CheckedContinuation<TernRunOutcome, Never>
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.terminationHandler = { [self] process in
            exited(cleanly: process.terminationReason == .exit && process.terminationStatus == 0)
        }

        // Launching under the lock means a cancellation either lands first and
        // prevents the launch, or finds a launched process to signal: it can
        // never meet a `Process` that is half started, whose `terminate()`
        // raises. The termination handler cannot run before the run is stored.
        let pid: pid_t? = state.withLock { state in
            guard state.interruption == nil else { return nil }
            guard (try? process.run()) != nil else { return nil }
            state.continuation = continuation
            state.process = process
            state.pid = process.processIdentifier
            return state.pid
        }
        guard let pid else {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            continuation.resume(returning: .failed)
            return
        }
        onLaunch?(pid)

        let source = PipeByteSource(
            reading: outputPipe.fileHandleForReading,
            qos: .userInitiated,
            label: "voiceour.tern.stdout",
            onBytes: { [self] bytes in received(bytes) },
            onEnd: { [self] in outputEnded() }
        )
        // The source drains its own duplicate of the read end; nothing reads
        // the original, so it closes now rather than at every exit below.
        try? outputPipe.fileHandleForReading.close()
        let alreadyFinished = state.withLock { state in
            if state.finished { return true }
            state.source = source
            return false
        }
        if alreadyFinished {
            source.stop()
        }

        timers.asyncAfter(deadline: .now() + Self.interval(deadline)) { [self] in
            interrupt(with: .timedOut)
        }
    }

    /// Cuts the run short with `outcome` unless something already resolved it.
    /// Never blocks: the grace period before SIGKILL is a timer.
    func interrupt(with outcome: TernRunOutcome) {
        let step = state.withLock { state -> Interruption in
            guard !state.finished, state.interruption == nil else { return .ignored }
            state.interruption = outcome
            // Not launched yet: `start` sees the interruption and never launches.
            guard let process = state.process else { return .ignored }
            if state.exited { return .finish(state.finish(outcome)) }
            return .terminate(process)
        }
        switch step {
        case .ignored:
            return
        case .finish(let finish):
            finish.run()
        case .terminate(let process):
            process.terminate()
            timers.asyncAfter(deadline: .now() + Self.terminationGrace) { [self] in
                escalate()
            }
        }
    }

    /// The grace period ran out. SIGKILL goes only to a child whose termination
    /// handler has not run. Foundation reaps a child just before it calls that
    /// handler, so the pid could only have been recycled if the kernel wrapped
    /// its whole pid space inside that instant. The run resolves now either
    /// way: SIGKILL cannot be ignored, and Foundation reaps the child when it
    /// dies.
    private func escalate() {
        let finish = state.withLock { state -> Finish? in
            guard !state.finished else { return nil }
            if !state.exited {
                kill(state.pid, SIGKILL)
            }
            return state.finish(state.interruption ?? .failed)
        }
        finish?.run()
    }

    private func received(_ bytes: UnsafeRawBufferPointer) {
        let overflowed = state.withLock { state in
            guard !state.finished, state.interruption == nil else { return false }
            guard state.output.count + bytes.count <= outputCap else { return true }
            state.output.append(bytes.assumingMemoryBound(to: UInt8.self))
            return false
        }
        if overflowed {
            interrupt(with: .failed)
        }
    }

    private func outputEnded() {
        let finish = state.withLock { state -> Finish? in
            state.outputEnded = true
            guard !state.finished, state.interruption == nil, state.exited else { return nil }
            return state.finish(state.exitedCleanly ? .output(state.output) : .failed)
        }
        finish?.run()
    }

    /// A clean exit still waits for end of stream, which follows at once unless
    /// a surviving grandchild holds the pipe open; the deadline bounds that wait.
    private func exited(cleanly: Bool) {
        let finish = state.withLock { state -> Finish? in
            state.exited = true
            state.exitedCleanly = cleanly
            guard !state.finished else { return nil }
            if let interruption = state.interruption { return state.finish(interruption) }
            guard cleanly else { return state.finish(.failed) }
            guard state.outputEnded else { return nil }
            return state.finish(.output(state.output))
        }
        finish?.run()
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let wholeSeconds = min(max(seconds, 0), 86_400)
        let nanoseconds = wholeSeconds * 1_000_000_000 + max(attoseconds, 0) / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}
