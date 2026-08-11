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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" >> "$0.pids"
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do :; done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let pidFile = fixture.url.appendingPathExtension("pids")

            func refiner(enabled: Bool, model: String) -> OmpRpcRefiner {
                OmpRpcRefiner(
                    configuration: OmpRpcRefinerConfiguration(
                        enabled: enabled,
                        executableURL: fixture.url,
                        argumentPrefix: [],
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
        private func makeRpcStubScript(reply: String, extraStartup: String = "") throws -> (directory: URL, url: URL) {
            try makeExecutableScript(
                """
                \(extraStartup)
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"\(reply)"}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true,"data":{"cancelled":false}}\\n' "$id"
                      ;;
                  esac
                done
                """)
        }

        @Test func ompRpcRefinerReturnsRefinedTextFromRpcSession() async throws {
            let fixture = try makeRpcStubScript(reply: "Hello world.")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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
            let fixture = try makeRpcStubScript(reply: "Hello world.")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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
            let fixture = try makeRpcStubScript(reply: "the budget is a lot")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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
            let fixture = try makeRpcStubScript(reply: "   ")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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
                    executableURL: URL(fileURLWithPath: "/nonexistent/voiceoour-missing-omp"),
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' '{"type":"ready"}'
                IFS= read -r line
                exit 3
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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
            let fixture = try makeExecutableScript(
                """
                pid_file="$0.pids"
                first_run_marker="$0.first-run"
                printf '%s\\n' "$$" >> "$pid_file"
                if [ ! -e "$first_run_marker" ]; then
                  : > "$first_run_marker"
                  printf '%s\\n' '{"type":"ready"}'
                  IFS= read -r line
                  trap '' TERM
                  while :; do :; done
                fi
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      printf '%s\\n' '{"type":"agent_end"}'
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Hello after timeout."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true,"data":{"cancelled":false}}\\n' "$id"
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let pidFile = fixture.url.appendingPathExtension("pids")
            let firstRunMarker = fixture.url.appendingPathExtension("first-run")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
                    argumentPrefix: [],
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

        private func makeNonterminalRpcStub(eventType: String) throws -> (directory: URL, url: URL) {
            try makeExecutableScript(
                """
                terminal_marker="$0.terminal"
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      printf '%s\\n' '{"type":"\(eventType)","isTerminal":false}'
                      (
                        /bin/sleep 0.15
                        : > "$terminal_marker"
                        printf '%s\\n' '{"type":"\(eventType)","isTerminal":true}'
                      ) &
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      if [ -e "$terminal_marker" ]; then
                        reply='Terminal response.'
                      else
                        reply='Premature response.'
                      fi
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"%s"}}\\n' "$id" "$reply"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      ;;
                  esac
                done
                """)
        }

        @Test func ompRpcIgnoresNonterminalAgentEnd() async throws {
            let fixture = try makeNonterminalRpcStub(eventType: "agent_end")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeNonterminalRpcStub(eventType: "prompt_result")
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" > "$0.pid"
                exec /bin/sleep 5
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let pidFile = fixture.url.appendingPathExtension("pid")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" >> "$0.pids"
                : > "$0.started"
                exec /bin/sleep 5
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let startedFile = fixture.url.appendingPathExtension("started")
            let pidFile = fixture.url.appendingPathExtension("pids")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                /bin/sleep 0.3
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      (
                        /bin/sleep 0.25
                        printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      ) &
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Combined deadline."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')
                      if [ -n "$id" ]; then
                        printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      fi
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" > "$0.pid"
                : > "$0.started"
                /bin/sleep 0.2
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Second request."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let startedFile = fixture.url.appendingPathExtension("started")
            let pidFile = fixture.url.appendingPathExtension("pid")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" >> "$0.pids"
                if [ -e "$0.first-run" ]; then
                  first_run=false
                else
                  : > "$0.first-run"
                  first_run=true
                fi
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      if [ "$first_run" = true ]; then
                        : > "$0.first-prompt"
                        ( /bin/sleep 0.12; printf '%s\\n' '{"type":"agent_end","isTerminal":true}' ) &
                      else
                        ( /bin/sleep 0.3; printf '%s\\n' '{"type":"agent_end","isTerminal":true}' ) &
                      fi
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Second request."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let promptMarker = fixture.url.appendingPathExtension("first-prompt")
            let pidFile = fixture.url.appendingPathExtension("pids")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" >> "$0.pids"
                if [ -e "$0.first-run" ]; then
                  changed=false
                else
                  : > "$0.first-run"
                  changed=true
                fi
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      if [ "$changed" = true ]; then
                        printf '%s\\n' '{"type":"model_changed","model":"other/provider"}'
                        printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      else
                        printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      fi
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Configured model."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let pidFile = fixture.url.appendingPathExtension("pids")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' "$$" >> "$0.pids"
                if [ -e "$0.first-run" ]; then
                  fail_reset=false
                else
                  : > "$0.first-run"
                  fail_reset=true
                fi
                printf '%s\\n' '{"type":"ready"}'
                while IFS= read -r line; do
                  case "$line" in
                    *'"type":"prompt"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\\n' "$id"
                      printf '%s\\n' '{"type":"agent_end","isTerminal":true}'
                      ;;
                    *'"type":"get_last_assistant_text"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      printf '{"id":"%s","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Hello world."}}\\n' "$id"
                      ;;
                    *'"type":"new_session"'*)
                      id=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
                      if [ "$fail_reset" = true ]; then
                        printf '{"id":"%s","type":"response","command":"new_session","success":false,"error":"reset failed"}\\n' "$id"
                      else
                        printf '{"id":"%s","type":"response","command":"new_session","success":true}\\n' "$id"
                      fi
                      ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let pidFile = fixture.url.appendingPathExtension("pids")
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            let fixture = try makeExecutableScript(
                """
                printf '%s\\n' 'auth-broker-secret-value' >&2
                /bin/sleep 0.05
                exit 23
                """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: fixture.url,
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
            guard ProcessInfo.processInfo.environment["VOICEOOUR_OMP_INTEGRATION"] != nil else { return }

            let profileDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceMacOmpRpcIntegration-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: profileDirectory) }
            let omp = OmpExecutable.resolve(explicitPath: ProcessInfo.processInfo.environment["VOICEOOUR_OMP_BIN"])
            let refiner = OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: true,
                    executableURL: omp.url,
                    argumentPrefix: omp.prefix,
                    model: ProcessInfo.processInfo.environment["VOICEOOUR_OMP_MODEL"] ?? "anthropic/claude-haiku-4-5",
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
