import Dispatch
import Foundation
import VoiceCore

/// Owns the RPC child process and the newline-delimited JSON conversation with it.
///
/// Request lifecycle per refine:
///   prompt -> (agent_end | prompt_result) -> get_last_assistant_text -> new_session
/// The `new_session` reset is awaited so every successful refine starts from an
/// empty conversation. Superseded or timed-out turns discard the entire child
/// because terminal session events are not correlated to prompt ids.
private final class OmpProcessDiagnostics: @unchecked Sendable {
    private static let byteLimit = 8_192
    private let lock = NSLock()
    private var stderrBytes = 0
    private var stderrWasTruncated = false
    private var exitStatus: Int32?

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(Self.byteLimit - stderrBytes, 0)
        stderrBytes += min(chunk.count, remaining)
        if chunk.count > remaining {
            stderrWasTruncated = true
        }
    }

    func recordExit(status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let bytes = stderrBytes
        let truncated = stderrWasTruncated
        let status = exitStatus
        lock.unlock()

        var parts: [String] = []
        if let status {
            parts.append("status \(status)")
        }
        if bytes > 0 {
            parts.append("stderr captured: \(bytes)\(truncated ? "+" : "") bytes")
        }
        return parts.joined(separator: "; ")
    }
}

private func captureOmpStderr(from handle: FileHandle, diagnostics: OmpProcessDiagnostics) {
    while true {
        do {
            guard let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty else { return }
            diagnostics.append(chunk)
        } catch {
            return
        }
    }
}
actor OmpRpcRuntime {
    private struct RunningChild {
        let id: UUID
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stdoutReader: NDJSONLineReader
        let stderr: FileHandle
        let stderrTask: Task<Void, Never>
        let diagnostics: OmpProcessDiagnostics
        var readerTask: Task<Void, Never>?
    }

    private final class StartingChild: @unchecked Sendable {
        let id: UUID
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stdoutReader: NDJSONLineReader
        let stderr: FileHandle
        let stderrTask: Task<Void, Never>
        let diagnostics: OmpProcessDiagnostics
        let readyTask: Task<Void, Error>

        init(
            id: UUID,
            process: Process,
            stdin: FileHandle,
            stdout: FileHandle,
            stdoutReader: NDJSONLineReader,
            stderr: FileHandle,
            stderrTask: Task<Void, Never>,
            diagnostics: OmpProcessDiagnostics,
            readyTask: Task<Void, Error>
        ) {
            self.id = id
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stdoutReader = stdoutReader
            self.stderr = stderr
            self.stderrTask = stderrTask
            self.diagnostics = diagnostics
            self.readyTask = readyTask
        }
    }

    private enum TurnStage {
        case awaitingEnd
        case awaitingText(textId: String)
        case awaitingReset(resetId: String, text: String)
    }

    private struct ActiveTurn {
        let promptId: String
        var stage: TurnStage
        let continuation: CheckedContinuation<String, Error>
        let deadline: Task<Void, Never>
    }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let profileDirectory: URL?

    private var starting: StartingChild?
    private var running: RunningChild?
    private var activeTurn: ActiveTurn?
    private var pendingTurnId: String?

    init(executableURL: URL, arguments: [String], environment: [String: String], profileDirectory: URL?) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.profileDirectory = profileDirectory
    }

    func warmUp(timeoutMs: Int) async throws {
        if starting != nil {
            terminateStarting()
        }
        let deadline = Self.deadline(timeoutMs: timeoutMs)
        _ = try await ensureRunning(before: deadline)
    }

    func shutdown() {
        failActiveTurn(with: OmpRpcError.processExited("refiner client shut down"))
        stopRunning(terminate: true)
        terminateStarting()
        pendingTurnId = nil
    }

    func complete(_ message: String, timeoutMs: Int) async throws -> String {
        // The newest caller owns the slot. A caller suspended in cold startup
        // rechecks this token before it can install an active continuation.
        if activeTurn != nil {
            failActiveTurn(with: OmpRpcError.superseded)
            stopRunning(terminate: true)
        }
        if starting != nil {
            // A ready event has no request correlation. Discard a cold child
            // claimed by an older caller instead of sharing its deadline.
            terminateStarting()
        }

        let promptId = UUID().uuidString
        let deadline = Self.deadline(timeoutMs: timeoutMs)
        pendingTurnId = promptId

        let child: RunningChild
        do {
            child = try await ensureRunning(before: deadline)
        } catch {
            guard pendingTurnId == promptId else {
                throw OmpRpcError.superseded
            }
            pendingTurnId = nil
            throw error
        }

        guard pendingTurnId == promptId else {
            throw OmpRpcError.superseded
        }
        guard activeTurn == nil else {
            pendingTurnId = nil
            throw OmpRpcError.superseded
        }
        guard !Task.isCancelled else {
            pendingTurnId = nil
            throw CancellationError()
        }

        let remaining = Self.remainingNanoseconds(until: deadline)
        guard remaining > 0 else {
            pendingTurnId = nil
            stopRunning(terminate: true)
            throw OmpRpcError.timeout
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            let deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: remaining)
                guard !Task.isCancelled else { return }
                await self?.timeOutTurn(promptId: promptId)
            }
            activeTurn = ActiveTurn(
                promptId: promptId,
                stage: .awaitingEnd,
                continuation: continuation,
                deadline: deadlineTask
            )
            pendingTurnId = nil
            do {
                try write(["id": promptId, "type": "prompt", "message": message], to: child)
            } catch {
                failActiveTurn(
                    with: OmpRpcError.processExited(
                        "stdin write failed: \(error.localizedDescription)\(diagnosticSuffix(child.diagnostics))"
                    ))
                stopRunning(terminate: true)
            }
        }
        return text
    }

    private static func deadline(timeoutMs: Int) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(max(timeoutMs, 1)) * 1_000_000
        let (deadline, overflow) = now.addingReportingOverflow(duration)
        return overflow ? UInt64.max : deadline
    }

    private static func remainingNanoseconds(until deadline: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }

    // MARK: - Turn state machine

    private func handleLine(_ line: String, childId: UUID) {
        guard running?.id == childId else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "agent_end", "prompt_result":
            guard object["isTerminal"] as? Bool != false else { return }
            guard var turn = activeTurn, case .awaitingEnd = turn.stage, let running else { return }
            let textId = "\(turn.promptId)-text"
            turn.stage = .awaitingText(textId: textId)
            activeTurn = turn
            sendOrFailTurn(["id": textId, "type": "get_last_assistant_text"], to: running)
        case "model_changed":
            failActiveTurn(with: OmpRpcError.protocolError("model changed during refinement"))
            stopRunning(terminate: true)
        case "response":
            handleResponse(object)
        default:
            return
        }
    }

    private func handleResponse(_ object: [String: Any]) {
        guard var turn = activeTurn, let id = object["id"] as? String else { return }
        let success = object["success"] as? Bool ?? false

        switch turn.stage {
        case .awaitingEnd:
            // The prompt acknowledgment (`command: "prompt"`) arrives here; only a
            // rejected prompt is terminal.
            guard id == turn.promptId, !success else { return }
            let detail = object["error"] as? String ?? "prompt rejected"
            failActiveTurn(with: OmpRpcError.protocolError(detail))
            stopRunning(terminate: true)
        case .awaitingText(let textId):
            guard id == textId, let running else { return }
            guard success, let data = object["data"] as? [String: Any], let text = data["text"] as? String else {
                failActiveTurn(with: OmpRpcError.protocolError(object["error"] as? String ?? "missing assistant text"))
                stopRunning(terminate: true)
                return
            }
            let resetId = "\(turn.promptId)-reset"
            turn.stage = .awaitingReset(resetId: resetId, text: text)
            activeTurn = turn
            sendOrFailTurn(["id": resetId, "type": "new_session"], to: running)
        case .awaitingReset(let resetId, let text):
            guard id == resetId else { return }
            finishActiveTurn(returning: text)
            if !success {
                // The text is still valid, but a failed reset leaves unknown
                // conversation state. Never reuse that process.
                stopRunning(terminate: true)
            }
        }
    }

    private func timeOutTurn(promptId: String) {
        guard let turn = activeTurn, turn.promptId == promptId else { return }
        failActiveTurn(with: OmpRpcError.timeout)
        stopRunning(terminate: true)
    }

    private func finishActiveTurn(returning text: String) {
        guard let turn = activeTurn else { return }
        activeTurn = nil
        turn.deadline.cancel()
        turn.continuation.resume(returning: text)
    }

    private func failActiveTurn(with error: Error) {
        guard let turn = activeTurn else { return }
        activeTurn = nil
        turn.deadline.cancel()
        turn.continuation.resume(throwing: error)
    }

    private func sendOrFailTurn(_ frame: [String: Any], to child: RunningChild) {
        do {
            try write(frame, to: child)
        } catch {
            failActiveTurn(
                with: OmpRpcError.processExited(
                    "stdin write failed: \(error.localizedDescription)\(diagnosticSuffix(child.diagnostics))"
                ))
            stopRunning(terminate: true)
        }
    }

    private func diagnosticSuffix(_ diagnostics: OmpProcessDiagnostics) -> String {
        let summary = diagnostics.summary()
        return summary.isEmpty ? "" : " [\(summary)]"
    }

    private func write(_ frame: [String: Any], to child: RunningChild) throws {
        let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        try child.stdin.write(contentsOf: data + Data("\n".utf8))
    }

    // MARK: - Process lifecycle

    private func ensureRunning(before deadline: UInt64) async throws -> RunningChild {
        guard Self.remainingNanoseconds(until: deadline) > 0 else {
            throw OmpRpcError.timeout
        }
        if let running {
            if running.process.isRunning {
                return running
            }
            stopRunning(terminate: false)
        }

        let starting: StartingChild
        if let current = self.starting {
            starting = current
        } else {
            let created = try startProcess()
            self.starting = created
            starting = created
        }
        scheduleStartupTimeout(childId: starting.id, deadline: deadline)

        do {
            let child = try await finishStarting(starting)
            guard Self.remainingNanoseconds(until: deadline) > 0 else {
                stopRunning(terminate: true)
                throw OmpRpcError.timeout
            }
            return child
        } catch {
            if Self.remainingNanoseconds(until: deadline) == 0 {
                throw OmpRpcError.timeout
            }
            throw error
        }
    }

    private func scheduleStartupTimeout(childId: UUID, deadline: UInt64) {
        let remaining = Self.remainingNanoseconds(until: deadline)
        Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: remaining)
            }
            guard !Task.isCancelled else { return }
            await self?.startupTimedOut(childId: childId)
        }
    }

    private func startupTimedOut(childId: UUID) {
        guard let starting, starting.id == childId else { return }
        terminateStarting()
    }

    private func startProcess() throws -> StartingChild {
        if let profileDirectory {
            do {
                try OmpRpcProfile.provision(
                    at: profileDirectory,
                    environment: environment
                )
            } catch let error as OmpRpcError {
                throw OmpRpcError.launchFailed(
                    "profile provisioning failed: \(error.shortMessage)"
                )
            } catch {
                throw OmpRpcError.launchFailed(
                    "profile provisioning failed: \(error.localizedDescription)"
                )
            }
        }

        let id = UUID()
        let diagnostics = OmpProcessDiagnostics()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let profileDirectory {
            process.currentDirectoryURL = profileDirectory
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            diagnostics.recordExit(status: status)
            Task { await self?.processTerminated(childId: id, status: status) }
        }

        do {
            try process.run()
        } catch {
            throw OmpRpcError.launchFailed(error.localizedDescription)
        }

        let stderrHandle = stderr.fileHandleForReading
        let stderrTask = Task.detached(priority: .utility) {
            captureOmpStderr(from: stderrHandle, diagnostics: diagnostics)
        }

        let stdoutHandle = stdout.fileHandleForReading
        let stdoutReader = NDJSONLineReader(reading: stdoutHandle)
        let readyTask = Task.detached(priority: .userInitiated) { () throws -> Void in
            while let line = try stdoutReader.nextLine() {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let type = object["type"] as? String
                else { continue }
                if type == "ready" {
                    return
                }
            }
            await stderrTask.value
            let detail = diagnostics.summary()
            throw OmpRpcError.notReady(
                detail.isEmpty ? "stdout closed before ready" : "stdout closed before ready [\(detail)]"
            )
        }

        return StartingChild(
            id: id,
            process: process,
            stdin: stdin.fileHandleForWriting,
            stdout: stdoutHandle,
            stdoutReader: stdoutReader,
            stderr: stderrHandle,
            stderrTask: stderrTask,
            diagnostics: diagnostics,
            readyTask: readyTask
        )
    }

    private func finishStarting(_ starting: StartingChild) async throws -> RunningChild {
        do {
            try await starting.readyTask.value
            if let running, running.id == starting.id {
                return running
            }
            guard self.starting?.id == starting.id else {
                closeChild(starting)
                throw OmpRpcError.processExited(
                    "refiner startup was interrupted\(diagnosticSuffix(starting.diagnostics))"
                )
            }

            var child = RunningChild(
                id: starting.id,
                process: starting.process,
                stdin: starting.stdin,
                stdout: starting.stdout,
                stdoutReader: starting.stdoutReader,
                stderr: starting.stderr,
                stderrTask: starting.stderrTask,
                diagnostics: starting.diagnostics,
                readerTask: nil
            )
            let reader = starting.stdoutReader
            let childId = starting.id
            child.readerTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    while let line = try reader.nextLine() {
                        await self?.handleLine(line, childId: childId)
                    }
                    await self?.stdoutClosed(childId: childId)
                } catch {
                    await self?.stdoutFailed(childId: childId, error: error)
                }
            }
            self.starting = nil
            self.running = child
            return child
        } catch {
            if self.starting?.id == starting.id {
                self.starting = nil
            }
            closeChild(starting)
            throw error
        }
    }

    private func stdoutClosed(childId: UUID) {
        guard let child = running, child.id == childId else { return }
        failActiveTurn(
            with: OmpRpcError.processExited(
                "refiner stdout closed\(diagnosticSuffix(child.diagnostics))"
            ))
        stopRunning(terminate: true)
    }

    private func stdoutFailed(childId: UUID, error: Error) {
        guard let child = running, child.id == childId else { return }
        failActiveTurn(
            with: OmpRpcError.processExited(
                "refiner stdout read failed: \(error.localizedDescription)\(diagnosticSuffix(child.diagnostics))"
            ))
        stopRunning(terminate: true)
    }

    private func processTerminated(childId: UUID, status: Int32) {
        guard let child = running, child.id == childId else { return }
        failActiveTurn(
            with: OmpRpcError.processExited(
                "refiner exited with status \(status)\(diagnosticSuffix(child.diagnostics))"
            ))
        stopRunning(terminate: false)
    }

    private func stopRunning(terminate: Bool) {
        guard let child = running else { return }
        running = nil
        child.readerTask?.cancel()
        child.stderrTask.cancel()
        // Closing stdin asks a well-behaved child to exit. The child's death is
        // what unblocks a reader parked in `read(2)`, so it must happen before
        // we close our read ends: a handle closed under a blocked read leaves
        // the reader on a dead or recycled descriptor.
        try? child.stdin.close()
        if terminate {
            OmpProcessTermination.terminateAndReap(child.process)
        }
        try? child.stdout.close()
        try? child.stderr.close()
    }

    private func terminateStarting() {
        guard let starting else { return }
        self.starting = nil
        closeChild(starting)
    }

    private func closeChild(_ starting: StartingChild) {
        starting.stderrTask.cancel()
        starting.readyTask.cancel()
        try? starting.stdin.close()
        OmpProcessTermination.terminateAndReap(starting.process)
        try? starting.stdout.close()
        try? starting.stderr.close()
    }
}
