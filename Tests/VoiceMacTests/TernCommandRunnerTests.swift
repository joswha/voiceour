import Darwin
import Foundation
import Synchronization
import Testing

@testable import VoiceMac

/// Drives `TernCommandRunner` with system binaries only: no test depends on Tern
/// being installed, and none runs a `tern` command.
@Suite("TernCommandRunner")
struct TernCommandRunnerTests {
    /// The pid `onLaunch` reported, readable from the test after the run.
    private final class LaunchedPid: Sendable {
        private let pid = Mutex<pid_t>(0)

        var value: pid_t { pid.withLock { $0 } }

        func record(_ launched: pid_t) {
            pid.withLock { $0 = launched }
        }
    }

    private static let shell = URL(fileURLWithPath: "/bin/sh")
    private static let environment = ["HOME": "/tmp", "PATH": "/usr/bin:/bin"]

    @Test func exitZeroReturnsItsOutput() async {
        let runner = TernCommandRunner(environment: Self.environment)
        let outcome = await runner.run(executable: Self.shell, arguments: ["-c", "printf 'hello tern'"])
        #expect(outcome == .output(Data("hello tern".utf8)))
    }

    /// More than a pipe buffer: only a drain running alongside the child lets it
    /// finish writing before the deadline.
    @Test func outputLargerThanAPipeBufferIsDrainedWhileTheChildRuns() async {
        let runner = TernCommandRunner(environment: Self.environment)
        let outcome = await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "200000", "/dev/zero"]
        )
        #expect(outcome == .output(Data(count: 200_000)))
    }

    @Test func nonZeroExitFails() async {
        let runner = TernCommandRunner(environment: Self.environment)
        let outcome = await runner.run(executable: Self.shell, arguments: ["-c", "printf partial; exit 3"])
        #expect(outcome == .failed)
    }

    @Test func outputOverTheCapFailsAndEndsTheChild() async {
        let launched = LaunchedPid()
        let runner = TernCommandRunner(
            outputCap: 16,
            environment: Self.environment,
            onLaunch: { launched.record($0) }
        )
        let outcome = await runner.run(
            executable: Self.shell,
            arguments: ["-c", "printf 0123456789abcdefXYZ; exec /bin/sleep 5"]
        )
        #expect(outcome == .failed)
        #expect(await waitForProcessExit(launched.value, timeout: 2))
    }

    @Test func outputExactlyAtTheCapIsKept() async {
        let runner = TernCommandRunner(outputCap: 16, environment: Self.environment)
        let outcome = await runner.run(executable: Self.shell, arguments: ["-c", "printf 0123456789abcdef"])
        #expect(outcome == .output(Data("0123456789abcdef".utf8)))
    }

    @Test func deadlineTimesOutAndTheChildIsGone() async {
        let launched = LaunchedPid()
        let runner = TernCommandRunner(
            deadline: .milliseconds(200),
            environment: Self.environment,
            onLaunch: { launched.record($0) }
        )
        let started = ContinuousClock.now
        let outcome = await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        #expect(outcome == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(launched.value > 0)
        #expect(await waitForProcessExit(launched.value, timeout: 2))
    }

    /// A child that ignores SIGTERM still ends: SIGKILL follows the grace period.
    @Test func childIgnoringSIGTERMIsKilled() async {
        let launched = LaunchedPid()
        let runner = TernCommandRunner(
            deadline: .milliseconds(200),
            environment: Self.environment,
            onLaunch: { launched.record($0) }
        )
        let started = ContinuousClock.now
        let outcome = await runner.run(
            executable: Self.shell,
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"]
        )
        #expect(outcome == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await waitForProcessExit(launched.value, timeout: 2))
    }

    @Test func cancellingTheAwaitingTaskTerminatesTheChild() async {
        let launched = LaunchedPid()
        let runner = TernCommandRunner(
            deadline: .seconds(30),
            environment: Self.environment,
            onLaunch: { launched.record($0) }
        )
        let started = ContinuousClock.now
        let task = Task {
            await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        await waitUntilTimeoutCondition(timeout: .seconds(2)) { launched.value > 0 }
        #expect(launched.value > 0)
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .failed)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(await waitForProcessExit(launched.value, timeout: 2))
    }

    @Test func alreadyCancelledTaskNeverLaunches() async {
        let launched = LaunchedPid()
        let runner = TernCommandRunner(environment: Self.environment, onLaunch: { launched.record($0) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        #expect(await task.value == .failed)
        #expect(launched.value == 0)
    }

    /// `/usr/bin/env` with no arguments prints exactly the environment it got;
    /// a shell would add `PWD`, `SHLVL` and `_` of its own.
    @Test func environmentIsExactlyTheGivenDictionary() async throws {
        let environment = ["HOME": "/tmp/tern-home", "PATH": "/usr/bin:/bin", "VOICEOUR_TERN_PROBE": "1"]
        let runner = TernCommandRunner(environment: environment)
        let outcome = await runner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        guard case .output(let data) = outcome else {
            Issue.record("expected output, got \(outcome)")
            return
        }
        let text = try #require(String(data: data, encoding: .utf8))
        let lines = Set(text.split(separator: "\n").map(String.init))
        #expect(lines == ["HOME=/tmp/tern-home", "PATH=/usr/bin:/bin", "VOICEOUR_TERN_PROBE=1"])
    }

    @Test func nonexistentExecutableFails() async {
        let runner = TernCommandRunner(environment: Self.environment)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TernCommandRunnerTests-\(UUID().uuidString)", isDirectory: false)
        let outcome = await runner.run(executable: missing, arguments: ["--json"])
        #expect(outcome == .failed)
    }

    @Test func stdinIsEmpty() async {
        let runner = TernCommandRunner(environment: Self.environment)
        let outcome = await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        #expect(outcome == .output(Data()))
    }
}

@Suite("TernSignature")
struct TernSignatureTests {
    /// Neither this test process nor `/bin/ls` is Tern's code.
    @Test func rejectsCodeThatIsNotTern() {
        #expect(!TernSignature.isGenuine(pid: getpid(), executable: URL(fileURLWithPath: "/bin/ls")))
        #expect(!TernSignature.isGenuine(pid: 0, executable: URL(fileURLWithPath: "/bin/ls")))
    }
}
