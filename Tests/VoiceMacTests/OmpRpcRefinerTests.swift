import Darwin
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Covers OMP RPC refiner startup, turn lifecycle, recovery, and integration.
extension OmpSuites {
    @Suite("RPC Refiner", .serialized)
    struct RpcRefiner {
        /// Every preflight gate, proven at the backend boundary rather than at
        /// `RefinerPolicy`: the refuse decision has to land before OMP is
        /// launched, so the recorded pid list must stay empty. A backend that
        /// spawned first and refused afterwards would still put the transcript
        /// in front of a subprocess.
        @Test func preflightSkipMatrixReturnsReasonsWithoutSpawningOmp() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("preflight.pids")

            func refiner(enabled: Bool, model: String) -> OmpRpcRefiner {
                OmpRpcRefiner(
                    configuration: OmpRpcRefinerConfiguration(
                        enabled: enabled,
                        executableURL: ompRpcStubURL(),
                        argumentPrefix: ["preflight-record", pidFile.path],
                        model: model,
                        timeoutMs: 4000
                    ),
                    environment: [:],
                    deterministicFallback: { "CLEAN:\($0)" }
                )
            }

            #expect(
                await refiner(enabled: false, model: "test")
                    .refine("hello", glossary: [], safety: .normalText, style: .standard)
                    == .skipped(reason: "disabled"))
            #expect(
                await refiner(enabled: true, model: "")
                    .refine("hello", glossary: [], safety: .normalText, style: .standard)
                    == .skipped(reason: "unconfigured"))
            for safety in [TargetSafetyClass.terminal, .codeEditor, .secure] {
                #expect(
                    await refiner(enabled: true, model: "test")
                        .refine("hello", glossary: [], safety: safety, style: .standard)
                        == .skipped(reason: "unsafe_target"))
            }

            #expect(processIDs(in: pidFile).isEmpty)
        }

        /// RPC stub speaking the omp `--mode rpc` JSONL protocol: ready banner, prompt
        /// acknowledgement, terminal agent event, assistant-text response, then reset.

        @Test func ompRpcRefinerReturnsRefinedTextFromRpcSession() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["normal", "Hello world."],
                    model: "test",
                    timeoutMs: 4000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine("helo world", glossary: [], safety: .normalText, style: .standard)
                    == .refined("Hello world."))
        }

        @Test func ompRpcRefinerAnswersRepeatedRefinesFromOneRunningChild() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["normal", "Hello world."],
                    model: "test",
                    timeoutMs: 4000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine("helo world", glossary: [], safety: .normalText, style: .standard)
                    == .refined("Hello world."))
            #expect(
                await refiner.refine("helo world again", glossary: [], safety: .normalText, style: .standard)
                    == .refined("Hello world."))
        }

        @Test func ompRpcRefinerFallsBackWhenGuardRejectsReply() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["normal", "the budget is a lot"],
                    model: "test",
                    timeoutMs: 4000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            // The reason is asserted, not just the text: `guard_rejected` is what
            // distinguishes a refusal the guards made from a backend failure, and
            // it is the string the session trace and the UI report.
            #expect(
                await refiner.refine("the budget is 15000", glossary: [], safety: .normalText, style: .standard)
                    == .fellBack("CLEAN:the budget is 15000", reason: "guard_rejected"))
        }

        /// A reply that carries no usable text must not be delivered as an empty
        /// transcript. Whitespace is the case that gets through a naive nil check.
        @Test func ompRpcRefinerFallsBackWhenReplyIsOnlyWhitespace() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["normal", "   "],
                    model: "test",
                    timeoutMs: 4000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine("raw transcript", glossary: [], safety: .normalText, style: .standard)
                    == .fellBack("CLEAN:raw transcript", reason: "empty_output"))
        }

        @Test func ompRpcRefinerFallsBackWhenLaunchFails() async {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: URL(fileURLWithPath: "/nonexistent/voiceour-missing-omp"),
                    argumentPrefix: [],
                    model: "test",
                    timeoutMs: 500
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                fellBackText(await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard))
                    == "CLEAN:hello")
        }

        @Test func ompRpcRefinerFallsBackWhenProcessDiesMidTurn() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["die-mid-turn"],
                    model: "test",
                    timeoutMs: 4000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                fellBackText(await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard))
                    == "CLEAN:hello")
        }

        @Test func ompRpcRefinerFallsBackOnTimeoutWhileTurnHangs() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("hang.pids")
            let firstRunMarker = directory.appendingPathComponent("hang.first-run")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["hang-first-run", pidFile.path, firstRunMarker.path],
                    model: "test",
                    timeoutMs: 300
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            let outcomeBox = RefineOutcomeBox()
            let started = ContinuousClock.now
            let refineTask = Task {
                let outcome = await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
                outcomeBox.publish(outcome)
            }
            let watchdogDeadline = Date().addingTimeInterval(2)
            while outcomeBox.value == nil, Date() < watchdogDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let elapsed = ContinuousClock.now - started
            guard let outcome = outcomeBox.value else {
                Issue.record("OMP refinement did not honor its configured 300 ms timeout within the 2 s watchdog")
                refineTask.cancel()
                if let directChildPID = processIDs(in: pidFile).first {
                    if kill(directChildPID, SIGTERM) != 0, errno != ESRCH {
                        Issue.record("could not terminate wedged direct RPC child \(directChildPID)")
                    }
                } else {
                    Issue.record("the wedged direct RPC child did not record its PID")
                }
                return
            }

            // The deadline is wall clock, not a token or read budget: a backend
            // that keeps the turn open indefinitely still has to release the
            // caller, with the deterministic text and the timeout reason.
            #expect(outcome == .fellBack("CLEAN:hello", reason: "omp timed out"))
            #expect(elapsed < .seconds(1))
            #expect(FileManager.default.fileExists(atPath: firstRunMarker.path))
            let firstPID = try #require(processIDs(in: pidFile).first)
            guard await waitForProcessExit(firstPID) else {
                Issue.record("the directly launched wedged RPC child did not terminate")
                return
            }

            #expect(
                await refiner.refine("hello after timeout", glossary: [], safety: .normalText, style: .standard)
                    == .refined("Hello after timeout.")
            )
            let processIDs = processIDs(in: pidFile)
            #expect(processIDs.count == 2)
            let respawnedPID = try #require(processIDs.dropFirst().first)
            #expect(respawnedPID != firstPID)
        }

        @Test func ompRpcIgnoresNonterminalAgentEnd() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let terminalMarker = directory.appendingPathComponent("agent-end.terminal")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["nonterminal-events", terminalMarker.path, "agent_end"],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine(
                    "terminal response",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .refined("Terminal response.")
            )
        }

        @Test func ompRpcIgnoresNonterminalPromptResult() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let terminalMarker = directory.appendingPathComponent("prompt-result.terminal")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["nonterminal-events", terminalMarker.path, "prompt_result"],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine(
                    "terminal response",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .refined("Terminal response.")
            )
        }

        @Test func ompRpcColdStartupCannotOutliveConfiguredDeadline() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("cold.pid")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["cold-sleep", pidFile.path],
                    model: "test",
                    timeoutMs: 400
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )
            let outcomeBox = RefineOutcomeBox()
            let started = Date()
            let refineTask = Task {
                outcomeBox.publish(
                    await refiner.refine(
                        "cold startup",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { refineTask.cancel() }

            let watchdog = Date().addingTimeInterval(2)
            while outcomeBox.value == nil, Date() < watchdog {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let outcome = outcomeBox.value else {
                if let pid = processIDs(in: pidFile).first {
                    _ = kill(pid, SIGTERM)
                }
                Issue.record("cold OMP startup exceeded the configured deadline")
                return
            }

            #expect(outcome == .fellBack("CLEAN:cold startup", reason: "omp timed out"))
            #expect(Date().timeIntervalSince(started) < 2)
            let pid = try #require(await awaitProcessIDs(in: pidFile).first)
            #expect(await waitForProcessExit(pid))
        }

        @Test func ompRpcNewColdCallerSupersedesPriorStartupBeforeItsDeadline() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let startedFile = directory.appendingPathComponent("cold.started")
            let pidFile = directory.appendingPathComponent("cold.pids")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["cold-sleep-marked", pidFile.path, startedFile.path],
                    model: "test",
                    timeoutMs: 300
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )
            let firstBox = RefineOutcomeBox()
            let secondBox = RefineOutcomeBox()
            let firstTask = Task {
                firstBox.publish(
                    await refiner.refine(
                        "first cold request",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { firstTask.cancel() }

            let startupDeadline = Date().addingTimeInterval(1)
            while !FileManager.default.fileExists(atPath: startedFile.path), Date() < startupDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard FileManager.default.fileExists(atPath: startedFile.path) else {
                Issue.record("first cold OMP process never launched")
                return
            }

            let secondTask = Task {
                secondBox.publish(
                    await refiner.refine(
                        "second cold request",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { secondTask.cancel() }
            let supersedeDeadline = Date().addingTimeInterval(0.2)
            while firstBox.value == nil, Date() < supersedeDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(
                firstBox.value
                    == .fellBack(
                        "CLEAN:first cold request",
                        reason: "superseded"
                    ))

            let secondDeadline = Date().addingTimeInterval(1)
            while secondBox.value == nil, Date() < secondDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(
                secondBox.value
                    == .fellBack(
                        "CLEAN:second cold request",
                        reason: "omp timed out"
                    ))
            #expect(processIDs(in: pidFile).count == 2)
        }

        @Test func ompRpcColdStartupAndTurnShareOneDeadline() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["combined-deadline"],
                    model: "test",
                    timeoutMs: 400
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine(
                    "combined deadline",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .fellBack("CLEAN:combined deadline", reason: "omp timed out"))
        }

        @Test func ompRpcColdStartupProtectsTheActiveTurnSlot() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("active.pid")
            let startedFile = directory.appendingPathComponent("active.started")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["active-slot", pidFile.path, startedFile.path],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )
            let firstBox = RefineOutcomeBox()
            let secondBox = RefineOutcomeBox()
            let firstTask = Task {
                firstBox.publish(
                    await refiner.refine(
                        "first request",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { firstTask.cancel() }

            let startupWatchdog = Date().addingTimeInterval(1)
            while !FileManager.default.fileExists(atPath: startedFile.path), Date() < startupWatchdog {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard FileManager.default.fileExists(atPath: startedFile.path) else {
                Issue.record("first OMP caller never entered cold startup")
                return
            }

            let secondTask = Task {
                secondBox.publish(
                    await refiner.refine(
                        "second request",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { secondTask.cancel() }
            let completionWatchdog = Date().addingTimeInterval(2)
            while firstBox.value == nil || secondBox.value == nil, Date() < completionWatchdog {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let first = firstBox.value, let second = secondBox.value else {
                if let pid = processIDs(in: pidFile).first {
                    _ = kill(pid, SIGTERM)
                }
                Issue.record("concurrent cold OMP callers did not both complete")
                return
            }

            #expect(first == .fellBack("CLEAN:first request", reason: "superseded"))
            #expect(second == .refined("Second request."))
        }

        @Test func ompRpcSupersessionDiscardsChildBeforeLateTerminalEvent() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("supersede.pids")
            let firstRunMarker = directory.appendingPathComponent("supersede.first-run")
            let promptMarker = directory.appendingPathComponent("supersede.first-prompt")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: [
                        "supersede-late-terminal",
                        pidFile.path,
                        firstRunMarker.path,
                        promptMarker.path,
                    ],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            let firstBox = RefineOutcomeBox()
            let firstTask = Task {
                firstBox.publish(
                    await refiner.refine(
                        "first request",
                        glossary: [],
                        safety: .normalText,
                        style: .standard
                    ))
            }
            defer { firstTask.cancel() }
            let promptDeadline = Date().addingTimeInterval(1)
            while !FileManager.default.fileExists(atPath: promptMarker.path), Date() < promptDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard FileManager.default.fileExists(atPath: promptMarker.path) else {
                Issue.record("first OMP prompt was not accepted")
                return
            }

            let second = await refiner.refine(
                "second request",
                glossary: [],
                safety: .normalText,
                style: .standard
            )
            let firstDeadline = Date().addingTimeInterval(1)
            while firstBox.value == nil, Date() < firstDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(firstBox.value == .fellBack("CLEAN:first request", reason: "superseded"))
            #expect(second == .refined("Second request."))
            let pids = processIDs(in: pidFile)
            #expect(pids.count == 2)
            if let firstPID = pids.first {
                #expect(await waitForProcessExit(firstPID))
            }
        }

        @Test func ompRpcRejectsModelChangeAndRespawns() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("model-change.pids")
            let firstRunMarker = directory.appendingPathComponent("model-change.first-run")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["model-change-first-run", pidFile.path, firstRunMarker.path],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            let changed = await refiner.refine(
                "first request",
                glossary: [],
                safety: .normalText,
                style: .standard
            )
            #expect(fellBackReason(changed)?.contains("model changed during refinement") == true)
            #expect(
                await refiner.refine(
                    "second request",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .refined("Configured model."))
            #expect(processIDs(in: pidFile).count == 2)
        }

        @Test func ompRpcResetFailureReturnsTextAndForcesFreshProcess() async throws {
            let directory = try makeOmpRpcStubDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("reset-failure.pids")
            let firstRunMarker = directory.appendingPathComponent("reset-failure.first-run")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["reset-failure-first-run", pidFile.path, firstRunMarker.path],
                    model: "test",
                    timeoutMs: 2_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            #expect(
                await refiner.refine(
                    "hello world",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .refined("Hello world."))
            let firstPID = try #require(processIDs(in: pidFile).first)
            #expect(await waitForProcessExit(firstPID))

            #expect(
                await refiner.refine(
                    "hello world",
                    glossary: [],
                    safety: .normalText,
                    style: .standard
                ) == .refined("Hello world."))
            let pids = processIDs(in: pidFile)
            #expect(pids.count == 2)
            #expect(pids[1] != firstPID)
        }

        @Test func ompRpcStartupFailureReportsBoundedMetadataWithoutRawStderr() async throws {
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: ompRpcStubURL(),
                    argumentPrefix: ["stderr-exit"],
                    model: "test",
                    timeoutMs: 1_000
                ),
                environment: [:],
                deterministicFallback: { "CLEAN:\($0)" }
            )

            let outcome = await refiner.refine(
                "hello",
                glossary: [],
                safety: .normalText,
                style: .standard
            )
            let reason = fellBackReason(outcome) ?? ""
            #expect(reason.contains("stderr captured:"))
            #expect(!reason.contains("auth-broker-secret-value"))
            #expect(reason.count <= 220)
        }

        @Test func ompRpcRefinerRealIntegration() async throws {
            guard ProcessInfo.processInfo.environment["VOICEOUR_OMP_INTEGRATION"] != nil else { return }

            let profileDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpRpcIntegration-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: profileDirectory) }
            let omp = OmpExecutable.resolve(explicitPath: ProcessInfo.processInfo.environment["VOICEOUR_OMP_BIN"])
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: omp.url,
                    argumentPrefix: omp.prefix,
                    model: ProcessInfo.processInfo.environment["VOICEOUR_OMP_MODEL"] ?? "anthropic/claude-haiku-4-5",
                    timeoutMs: 30000,
                    profileDirectory: profileDirectory
                ),
                deterministicFallback: { $0 }
            )

            // First refine pays RPC child startup; the second must ride the warm session.
            await refiner.warmUp()
            let first = await refiner.refine(
                "helo wrld can you here me", glossary: [], safety: .normalText, style: .standard)
            let warmStart = Date()
            let second = await refiner.refine(
                "lets meet at three no wait four pm", glossary: [], safety: .normalText, style: .standard)
            let warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
            print("omp-rpc integration warm refine: \(warmMs)ms")

            for outcome in [first, second] {
                switch outcome {
                case .refined(let text), .fellBack(let text, _):
                    #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .skipped(let reason):
                    Issue.record("Real omp integration must not skip: \(reason)")
                }
            }
            #expect(warmMs < 10_000)
        }

        private func makeOmpRpcStubDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpRpcStub-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func fellBackReason(_ outcome: RefineOutcome) -> String? {
            guard case .fellBack(_, let reason) = outcome else { return nil }
            return reason
        }
    }

    private final class RefineOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: RefineOutcome?

        var value: RefineOutcome? {
            lock.withLock { storedValue }
        }

        func publish(_ value: RefineOutcome) {
            lock.withLock {
                storedValue = value
            }
        }
    }
}

private func ompRpcStubURL() -> URL {
    testProductsDirectory().appendingPathComponent("OmpRpcStub")
}

private func testProductsDirectory() -> URL {
    Bundle(for: OmpRpcStubTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
}

/// Only exists to give `Bundle(for:)` a class in this test target.
private final class OmpRpcStubTestBundleAnchor {}
