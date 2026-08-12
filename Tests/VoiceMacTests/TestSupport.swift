import Darwin
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Test doubles and helpers shared across the `VoiceMac` test target.
///
/// Swift test targets cannot import one another, so each target keeps its own
/// support file. Helpers live here when more than one test file needs them;
/// single-consumer, behaviour-specific doubles stay private to their own file.

// MARK: Async coordination

/// A one-shot async gate: `wait()` suspends until some other task calls
/// `fire()`. Used to hold a fake mid-flight so a test can observe intermediate
/// state. Deliberately ignores task cancellation — the point is to model work
/// that keeps running after its caller gives up.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openState
    }

    func fire() {
        lock.lock()
        openState = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if openState {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Polls `condition` until it holds or `timeout` elapses. Returning on timeout
/// rather than failing is deliberate: the caller asserts the condition after,
/// so the failure message names the state rather than the wait.
func waitUntilTimeoutCondition(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

func makeExecutableScript(_ body: String) throws -> (directory: URL, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceMacOmpTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-omp.sh")
    try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (directory, script)
}

func processIDs(in file: URL) -> [pid_t] {
    guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return
        contents
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { pid_t($0) }
}

/// The scripts below record their pid as their first act, but a loaded test
/// run can spawn slower than the deadline under test. Poll so a launch that
/// lost the race to the (correctly enforced) timeout does not read as an
/// unlaunched process.
func awaitProcessIDs(in file: URL, count: Int = 1) async -> [pid_t] {
    for _ in 0..<100 {
        let pids = processIDs(in: file)
        if pids.count >= count { return pids }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return processIDs(in: file)
}

/// Iteration-counted rather than deadline-based so a descheduled test run
/// still gets its full quota of polls instead of expiring while suspended.
/// A non-positive pid is reported as already exited without asking the kernel:
/// `kill(0, 0)` targets the caller's whole process group, so an unparsed pid
/// would otherwise stay "alive" for the full timeout.
func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
    guard pid > 0 else { return true }
    for _ in 0..<max(1, Int((timeout / 0.05).rounded(.up))) {
        if kill(pid, 0) == -1, errno == ESRCH {
            return true
        }
        if Task.isCancelled {
            return false
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return kill(pid, 0) == -1 && errno == ESRCH
}

func fellBackText(_ outcome: RefineOutcome) -> String? {
    guard case .fellBack(let value, _) = outcome else { return nil }
    return value
}

struct FakePermissions: PermissionsChecking {
    var synth: PermissionState
    var requestSynth = false
    func microphone() -> PermissionState { .granted }
    func synthPaste() -> PermissionState { synth }
    func requestSynthPaste() async -> Bool { requestSynth }
    func accessibility() -> PermissionState { .denied }
}
