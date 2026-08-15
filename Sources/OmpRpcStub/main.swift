import Darwin
import Foundation

/// A deliberately small `omp --mode rpc` peer for process-boundary tests.
///
/// Each scenario preserves one of the former inline shell stubs, including its timing,
/// process exit, and filesystem side effects. Requests are decoded as JSON so every response
/// can echo the caller's exact `id` without launching a parser subprocess.
enum StubMain {
    private struct Request {
        let rawLine: String
        let id: String
        let type: String
    }

    private static let outputLock = NSLock()

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let scenario = arguments.first else {
            fail("usage: OmpRpcStub <scenario> [args...]")
        }
        let rest = Array(arguments.dropFirst())

        switch scenario {
        case "preflight-record":
            preflightRecord(arguments: rest)
        case "normal":
            normal(arguments: rest)
        case "die-mid-turn":
            dieMidTurn()
        case "hang-first-run":
            hangFirstRun(arguments: rest)
        case "nonterminal-events":
            nonterminalEvents(arguments: rest)
        case "cold-sleep":
            coldSleep(arguments: rest)
        case "cold-sleep-marked":
            coldSleepMarked(arguments: rest)
        case "combined-deadline":
            combinedDeadline()
        case "active-slot":
            activeSlot(arguments: rest)
        case "supersede-late-terminal":
            supersedeLateTerminal(arguments: rest)
        case "model-change-first-run":
            modelChangeFirstRun(arguments: rest)
        case "reset-failure-first-run":
            resetFailureFirstRun(arguments: rest)
        case "stderr-exit":
            stderrExit()
        case "capture-requests":
            captureRequests(arguments: rest)
        case "_emit-after":
            emitAfter(arguments: rest)
        default:
            fail("unknown scenario \(scenario)")
        }
    }

    private static func preflightRecord(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "preflight-record")
        appendLine(String(getpid()), to: pidFile)
        emitReady()
        while readLine(strippingNewline: true) != nil {}
    }

    private static func normal(arguments: [String]) {
        let reply = requiredArgument(arguments, at: 0, scenario: "normal")
        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                emitRaw(#"{"type":"agent_end","isTerminal":true}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: reply)
            case "new_session":
                emitResetSuccess(id: request.id, cancelled: false)
            default:
                break
            }
        }
    }

    private static func dieMidTurn() -> Never {
        emitReady()
        _ = readLine(strippingNewline: true)
        exit(3)
    }

    private static func hangFirstRun(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "hang-first-run")
        let firstRunMarker = requiredArgument(arguments, at: 1, scenario: "hang-first-run")
        appendLine(String(getpid()), to: pidFile)

        if !FileManager.default.fileExists(atPath: firstRunMarker) {
            truncateFile(at: firstRunMarker)
            emitReady()
            _ = readLine(strippingNewline: true)
            signal(SIGTERM, SIG_IGN)
            blockForever()
        }

        serve { request in
            switch request.type {
            case "prompt":
                emitRaw(#"{"type":"agent_end"}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Hello after timeout.")
            case "new_session":
                emitResetSuccess(id: request.id, cancelled: false)
            default:
                break
            }
        }
    }

    private static func nonterminalEvents(arguments: [String]) {
        let terminalMarker = requiredArgument(arguments, at: 0, scenario: "nonterminal-events")
        let eventType = requiredArgument(arguments, at: 1, scenario: "nonterminal-events")

        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                emitRaw(#"{"type":\#(quoted(eventType)),"isTerminal":false}"#)
                spawnDelayedLine(
                    seconds: 0.15,
                    line: #"{"type":\#(quoted(eventType)),"isTerminal":true}"#,
                    markerPath: terminalMarker
                )
            case "get_last_assistant_text":
                let reply =
                    FileManager.default.fileExists(atPath: terminalMarker)
                    ? "Terminal response."
                    : "Premature response."
                emitAssistantResponse(id: request.id, text: reply)
            case "new_session":
                emitResetSuccess(id: request.id)
            default:
                break
            }
        }
    }

    private static func coldSleep(arguments: [String]) -> Never {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "cold-sleep")
        overwriteLine(String(getpid()), at: pidFile)
        Thread.sleep(forTimeInterval: 5)
        exit(0)
    }

    private static func coldSleepMarked(arguments: [String]) -> Never {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "cold-sleep-marked")
        let startedMarker = requiredArgument(arguments, at: 1, scenario: "cold-sleep-marked")
        appendLine(String(getpid()), to: pidFile)
        truncateFile(at: startedMarker)
        Thread.sleep(forTimeInterval: 5)
        exit(0)
    }

    private static func combinedDeadline() {
        Thread.sleep(forTimeInterval: 0.3)
        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                spawnDelayedLine(
                    seconds: 0.25,
                    line: #"{"type":"agent_end","isTerminal":true}"#
                )
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Combined deadline.")
            case "new_session":
                emitResetSuccess(id: request.id)
            default:
                break
            }
        }
    }

    private static func activeSlot(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "active-slot")
        let startedMarker = requiredArgument(arguments, at: 1, scenario: "active-slot")
        overwriteLine(String(getpid()), at: pidFile)
        truncateFile(at: startedMarker)
        Thread.sleep(forTimeInterval: 0.2)

        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                emitRaw(#"{"type":"agent_end","isTerminal":true}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Second request.")
            case "new_session":
                emitResetSuccess(id: request.id)
            default:
                break
            }
        }
    }

    private static func supersedeLateTerminal(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "supersede-late-terminal")
        let firstRunMarker = requiredArgument(arguments, at: 1, scenario: "supersede-late-terminal")
        let firstPromptMarker = requiredArgument(arguments, at: 2, scenario: "supersede-late-terminal")
        appendLine(String(getpid()), to: pidFile)

        let firstRun = !FileManager.default.fileExists(atPath: firstRunMarker)
        if firstRun {
            truncateFile(at: firstRunMarker)
        }

        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                spawnDelayedLine(
                    seconds: firstRun ? 0.12 : 0.3,
                    line: #"{"type":"agent_end","isTerminal":true}"#
                )
                if firstRun {
                    truncateFile(at: firstPromptMarker)
                }
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Second request.")
            case "new_session":
                emitResetSuccess(id: request.id)
            default:
                break
            }
        }
    }

    private static func modelChangeFirstRun(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "model-change-first-run")
        let firstRunMarker = requiredArgument(arguments, at: 1, scenario: "model-change-first-run")
        appendLine(String(getpid()), to: pidFile)

        let changed = !FileManager.default.fileExists(atPath: firstRunMarker)
        if changed {
            truncateFile(at: firstRunMarker)
        }

        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                if changed {
                    emitRaw(#"{"type":"model_changed","model":"other/provider"}"#)
                }
                emitRaw(#"{"type":"agent_end","isTerminal":true}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Configured model.")
            case "new_session":
                emitResetSuccess(id: request.id)
            default:
                break
            }
        }
    }

    private static func resetFailureFirstRun(arguments: [String]) {
        let pidFile = requiredArgument(arguments, at: 0, scenario: "reset-failure-first-run")
        let firstRunMarker = requiredArgument(arguments, at: 1, scenario: "reset-failure-first-run")
        appendLine(String(getpid()), to: pidFile)

        let failReset = !FileManager.default.fileExists(atPath: firstRunMarker)
        if failReset {
            truncateFile(at: firstRunMarker)
        }

        serve { request in
            switch request.type {
            case "prompt":
                emitPromptResponse(id: request.id)
                emitRaw(#"{"type":"agent_end","isTerminal":true}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: "Hello world.")
            case "new_session":
                if failReset {
                    emitResetFailure(id: request.id)
                } else {
                    emitResetSuccess(id: request.id)
                }
            default:
                break
            }
        }
    }

    private static func stderrExit() -> Never {
        write(Data("auth-broker-secret-value\n".utf8), to: FileHandle.standardError)
        Thread.sleep(forTimeInterval: 0.05)
        exit(23)
    }

    private static func captureRequests(arguments: [String]) {
        let requestsFile = requiredArgument(arguments, at: 0, scenario: "capture-requests")
        let reply = requiredArgument(arguments, at: 1, scenario: "capture-requests")

        serve { request in
            appendLine(request.rawLine, to: requestsFile)
            switch request.type {
            case "prompt":
                emitRaw(#"{"type":"agent_end"}"#)
            case "get_last_assistant_text":
                emitAssistantResponse(id: request.id, text: reply)
            case "new_session":
                emitResetSuccess(id: request.id, cancelled: false)
            default:
                break
            }
        }
    }

    // MARK: - Protocol plumbing

    private static func serve(_ body: (Request) -> Void) {
        emitReady()
        while let line = readLine(strippingNewline: true) {
            guard let request = parseRequest(line) else { continue }
            body(request)
        }
    }

    private static func parseRequest(_ line: String) -> Request? {
        guard !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let id = object["id"] as? String,
            let type = object["type"] as? String
        else {
            return nil
        }
        return Request(rawLine: line, id: id, type: type)
    }

    private static func emitReady() {
        emitRaw(#"{"type":"ready"}"#)
    }

    private static func emitPromptResponse(id: String) {
        emitRaw(
            #"{"id":\#(quoted(id)),"type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}"#
        )
    }

    private static func emitAssistantResponse(id: String, text: String) {
        emitRaw(
            #"{"id":\#(quoted(id)),"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":\#(quoted(text))}}"#
        )
    }

    private static func emitResetSuccess(id: String, cancelled: Bool? = nil) {
        if let cancelled {
            emitRaw(
                #"{"id":\#(quoted(id)),"type":"response","command":"new_session","success":true,"data":{"cancelled":\#(cancelled)}}"#
            )
        } else {
            emitRaw(#"{"id":\#(quoted(id)),"type":"response","command":"new_session","success":true}"#)
        }
    }

    private static func emitResetFailure(id: String) {
        emitRaw(
            #"{"id":\#(quoted(id)),"type":"response","command":"new_session","success":false,"error":"reset failed"}"#
        )
    }

    private static func emitRaw(_ line: String) {
        outputLock.withLock {
            write(Data((line + "\n").utf8), to: FileHandle.standardOutput)
        }
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
            let array = String(data: data, encoding: .utf8)
        else {
            fail("could not encode JSON string")
        }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Process and filesystem plumbing

    /// Launches a second copy of this compiled stub so its delayed write survives termination
    /// of the direct RPC child, just like the background subshell in the fixture it replaces.
    private static func spawnDelayedLine(
        seconds: TimeInterval,
        line: String,
        markerPath: String? = nil
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["_emit-after", String(seconds), line] + (markerPath.map { [$0] } ?? [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            fail("could not launch delayed emitter: \(error)")
        }
    }

    private static func emitAfter(arguments: [String]) -> Never {
        let secondsArgument = requiredArgument(arguments, at: 0, scenario: "_emit-after")
        let line = requiredArgument(arguments, at: 1, scenario: "_emit-after")
        guard let seconds = TimeInterval(secondsArgument) else {
            fail("_emit-after received an invalid delay")
        }
        Thread.sleep(forTimeInterval: seconds)
        if arguments.indices.contains(2) {
            truncateFile(at: arguments[2])
        }
        emitRaw(line)
        exit(0)
    }

    private static func appendLine(_ line: String, to path: String) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            fail("could not open \(path) for append")
        }
        defer { close(descriptor) }

        let data = Data((line + "\n").utf8)
        let wroteAllBytes = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAllBytes else {
            fail("could not append \(path)")
        }
    }

    private static func overwriteLine(_ line: String, at path: String) {
        do {
            try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not write \(path): \(error)")
        }
    }

    private static func truncateFile(at path: String) {
        do {
            try Data().write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not create marker \(path): \(error)")
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail("could not write output: \(error)")
        }
    }

    private static func requiredArgument(_ arguments: [String], at index: Int, scenario: String) -> String {
        guard arguments.indices.contains(index) else {
            fail("\(scenario) missing argument \(index + 1)")
        }
        return arguments[index]
    }

    private static func blockForever() -> Never {
        while true { pause() }
    }

    private static func fail(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        exit(2)
    }
}

StubMain.main()
