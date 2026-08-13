import Foundation
import VoiceCore

struct SidecarLaunchConfiguration: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    /// Where this sidecar's stderr is forwarded. Nil everywhere in production,
    /// which forwards to the host's stderr; see `forwardStderrToHost`. Scoped to
    /// one configuration rather than a process-wide override so a test that
    /// installs one cannot swallow a concurrently running suite's diagnostics.
    var stderrSink: (@Sendable (UnsafeRawBufferPointer) -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        stderrSink: (@Sendable (UnsafeRawBufferPointer) -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.stderrSink = stderrSink
    }

    static func uv(projectDirectory: URL, backend: String = "fake") -> SidecarLaunchConfiguration {
        var env = ProcessInfo.processInfo.environment
        env["VOICEOOUR_ASR_BACKEND"] = backend
        env["VOICEOOUR_PRELOAD"] = "1"
        return SidecarLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "uv", "--no-config", "run", "--project", projectDirectory.path, "python", "-m", "voiceoour_asr",
            ],
            environment: env
        )
    }
}

public enum SidecarASRClientError: Error, Equatable {
    case launchFailed(String)
    case noHello
    case incompatibleHello
    case protocolError(ASRErrorMessage)
    case unexpectedMessage(String)
    case timeout
    case processExited(String)
    case writeFailed(String)
}

public final class SidecarASRClient: ASRClienting, @unchecked Sendable {
    private let runtime: SidecarProcessRuntime
    /// The model this client's sidecar must have loaded, echoed on every
    /// transcribe so a stale cache fails as a mismatch instead of quietly
    /// transcribing with other weights. Nil for a backend that pins no model —
    /// the fake sidecar used to be told to expect Parakeet.
    private let expectedModel: ASRExpectedModel?

    init(launch: SidecarLaunchConfiguration, expectedModel: ASRExpectedModel? = nil) {
        self.runtime = SidecarProcessRuntime(launch: launch)
        self.expectedModel = expectedModel
    }

    public convenience init(
        asrDirectory: URL,
        backend: String = ProcessInfo.processInfo.environment["VOICEOOUR_ASR_BACKEND"] ?? "fake",
        expectedModel: ASRExpectedModel? = nil
    ) {
        self.init(launch: .uv(projectDirectory: asrDirectory, backend: backend), expectedModel: expectedModel)
    }

    deinit {
        let runtime = runtime
        Task.detached { await runtime.shutdown() }
    }

    public func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
        let request = ASRTranscribeRequest(
            requestId: UUID().uuidString,
            audio: audio.meta,
            expectedModel: expectedModel,
            timeoutMs: timeoutMs
        )
        return try await runRequest(requestId: request.requestId, timeoutMs: timeoutMs) {
            try await self.runtime.transcribe(request)
        }
    }

    public func transcribe(_ audio: RecordedAudio, timeoutMs: Int, biasPhrases: [ASRBiasPhrase]) async throws
        -> ASRResult
    {
        // No bias phrases -> keep the wire request byte-identical to the
        // unbiased default path (no bias fields, no snapshot id).
        guard !biasPhrases.isEmpty else {
            return try await transcribe(audio, timeoutMs: timeoutMs)
        }
        let request = ASRTranscribeRequest(
            requestId: UUID().uuidString,
            audio: audio.meta,
            expectedModel: expectedModel,
            timeoutMs: timeoutMs,
            biasPhrases: biasPhrases,
            biasSnapshotId: UUID().uuidString
        )
        return try await runRequest(requestId: request.requestId, timeoutMs: timeoutMs) {
            try await self.runtime.transcribe(request)
        }
    }

    public func health(timeoutMs: Int) async throws -> ASRBackendHealth {
        let request = ASRHealthRequest(requestId: UUID().uuidString)
        return try await runRequest(requestId: request.requestId, timeoutMs: timeoutMs) {
            try await self.runtime.health(request)
        }
    }

    public func warmUp() async {
        try? await runtime.warmUp()
    }

    private func runRequest<T: Sendable>(
        requestId: String,
        timeoutMs: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let requestTask = Task.detached(priority: .userInitiated) {
            try await operation()
        }

        let raceBox = RequestRaceBox<T>()
        let race = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                raceBox.install(continuation)

                Task.detached(priority: .userInitiated) {
                    do {
                        raceBox.resolve(.value(try await requestTask.value))
                    } catch {
                        raceBox.resolve(.failure(error))
                    }
                }

                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(milliseconds: timeoutMs))
                    raceBox.resolve(.timedOut)
                }
            }
        } onCancel: {
            raceBox.resolve(.cancelled)
        }

        switch race {
        case .value(let value):
            return value
        case .failure(let error):
            if error is CancellationError {
                throw CancellationError()
            }
            throw error
        case .timedOut:
            await cleanupInterruptedRequest(requestId: requestId, requestTask: requestTask, interruption: .timeout)
            throw SidecarASRClientError.timeout
        case .cancelled:
            await cleanupInterruptedRequest(requestId: requestId, requestTask: requestTask, interruption: .cancellation)
            throw CancellationError()
        }
    }

    private func cleanupInterruptedRequest<T: Sendable>(
        requestId: String,
        requestTask: Task<T, Error>,
        interruption: RequestInterruption
    ) async {
        let cleanup = Task.detached(priority: .userInitiated) { [runtime] in
            await runtime.sendCancel(requestId: requestId)
            let completed = await Self.waitForCompletion(requestTask, milliseconds: 500)
            if !completed {
                await runtime.terminateUnresponsiveRequest(requestId: requestId, interruption: interruption)
            }
        }
        await cleanup.value
    }

    private static func waitForCompletion<T: Sendable>(_ task: Task<T, Error>, milliseconds: Int) async -> Bool {
        let raceBox = RequestRaceBox<Bool>()
        let race = await withCheckedContinuation { continuation in
            raceBox.install(continuation)

            Task.detached(priority: .userInitiated) {
                _ = try? await task.value
                raceBox.resolve(.value(true))
            }

            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(milliseconds: milliseconds))
                raceBox.resolve(.value(false))
            }
        }

        guard case .value(let completed) = race else { return false }
        return completed
    }

    private static func nanoseconds(milliseconds: Int) -> UInt64 {
        UInt64(max(milliseconds, 1)) * 1_000_000
    }

    private static func messageType(from line: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return object?["type"] as? String ?? ""
    }

    private enum RequestRaceResult<T: Sendable> {
        case value(T)
        case failure(Error)
        case timedOut
        case cancelled
    }

    private final class RequestRaceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RequestRaceResult<T>, Never>?
        private var result: RequestRaceResult<T>?

        func install(_ continuation: CheckedContinuation<RequestRaceResult<T>, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ result: RequestRaceResult<T>) {
            lock.lock()
            if self.result != nil {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    private enum RequestInterruption: Sendable {
        case timeout
        case cancellation

        var requestError: Error {
            switch self {
            case .timeout:
                return SidecarASRClientError.timeout
            case .cancellation:
                return CancellationError()
            }
        }
    }

    private final class StartingSidecar: @unchecked Sendable {
        let id: UUID
        let process: Process
        let stdin: FileHandle
        /// Read ends the readers below own a duplicate of. Kept only to close
        /// at teardown: both descriptions carry `O_NONBLOCK` now, so a read API
        /// here would answer an empty pipe with empty data, which every caller
        /// in this file reads as end of stream.
        let stdout: FileHandle
        let stdoutReader: NDJSONLineReader
        let stderr: FileHandle
        let stderrSource: PipeByteSource
        let helloTask: Task<ASRHello, Error>

        init(
            id: UUID,
            process: Process,
            stdin: FileHandle,
            stdout: FileHandle,
            stdoutReader: NDJSONLineReader,
            stderr: FileHandle,
            stderrSource: PipeByteSource,
            helloTask: Task<ASRHello, Error>
        ) {
            self.id = id
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stdoutReader = stdoutReader
            self.stderr = stderr
            self.stderrSource = stderrSource
            self.helloTask = helloTask
        }
    }

    private final class RunningSidecar: @unchecked Sendable {
        let id: UUID
        let process: Process
        let stdin: FileHandle
        /// Close-only, for the reason spelled out on `StartingSidecar.stdout`.
        let stdout: FileHandle
        let stdoutReader: NDJSONLineReader
        let stderr: FileHandle
        let hello: ASRHello
        let stderrSource: PipeByteSource
        var readerTask: Task<Void, Never>?

        init(starting: StartingSidecar, hello: ASRHello) {
            self.id = starting.id
            self.process = starting.process
            self.stdin = starting.stdin
            self.stdout = starting.stdout
            self.stdoutReader = starting.stdoutReader
            self.stderr = starting.stderr
            self.hello = hello
            self.stderrSource = starting.stderrSource
        }
    }

    private enum PendingRequest {
        case transcribe(CheckedContinuation<ASRResult, Error>)
        case health(CheckedContinuation<ASRBackendHealth, Error>)

        func resumeTranscribe(_ result: ASRResult) {
            switch self {
            case .transcribe(let continuation):
                continuation.resume(returning: result)
            case .health(let continuation):
                continuation.resume(throwing: SidecarASRClientError.unexpectedMessage(result.type))
            }
        }

        func resumeHealth(_ health: ASRBackendHealth) {
            switch self {
            case .transcribe(let continuation):
                continuation.resume(throwing: SidecarASRClientError.unexpectedMessage("health"))
            case .health(let continuation):
                continuation.resume(returning: health)
            }
        }

        func resume(throwing error: Error) {
            switch self {
            case .transcribe(let continuation):
                continuation.resume(throwing: error)
            case .health(let continuation):
                continuation.resume(throwing: error)
            }
        }
    }

    private actor SidecarProcessRuntime {
        private let launch: SidecarLaunchConfiguration
        private var starting: StartingSidecar?
        private var running: RunningSidecar?
        private var pending: [String: PendingRequest] = [:]

        init(launch: SidecarLaunchConfiguration) {
            self.launch = launch
        }

        func warmUp() async throws {
            _ = try await ensureRunning()
        }

        func transcribe(_ request: ASRTranscribeRequest) async throws -> ASRResult {
            let sidecar = try await ensureRunning()
            return try await withCheckedThrowingContinuation { continuation in
                pending[request.requestId] = .transcribe(continuation)
                do {
                    try sidecar.stdin.write(contentsOf: ASRWire.encodeLine(request))
                } catch {
                    pending.removeValue(forKey: request.requestId)
                    failAllAndStop(
                        requestId: nil,
                        requestError: nil,
                        otherError: SidecarASRClientError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                    continuation.resume(throwing: SidecarASRClientError.writeFailed(error.localizedDescription))
                }
            }
        }

        func health(_ request: ASRHealthRequest) async throws -> ASRBackendHealth {
            let sidecar = try await ensureRunning()
            return try await withCheckedThrowingContinuation { continuation in
                pending[request.requestId] = .health(continuation)
                do {
                    try sidecar.stdin.write(contentsOf: ASRWire.encodeLine(request))
                } catch {
                    pending.removeValue(forKey: request.requestId)
                    failAllAndStop(
                        requestId: nil,
                        requestError: nil,
                        otherError: SidecarASRClientError.writeFailed(error.localizedDescription),
                        terminate: true
                    )
                    continuation.resume(throwing: SidecarASRClientError.writeFailed(error.localizedDescription))
                }
            }
        }

        func sendCancel(requestId: String) {
            guard pending[requestId] != nil, let running else { return }
            do {
                try running.stdin.write(contentsOf: ASRWire.encodeLine(ASRCancelRequest(requestId: requestId)))
            } catch {
                // The caller will terminate if the sidecar stays silent after cancellation.
            }
        }

        func terminateUnresponsiveRequest(requestId: String, interruption: RequestInterruption) {
            let reason = "sidecar did not finish request \(requestId) after cancel"
            failAllAndStop(
                requestId: requestId,
                requestError: interruption.requestError,
                otherError: SidecarASRClientError.processExited(reason),
                terminate: true
            )
            terminateStarting()
        }

        func shutdown() {
            failAllAndStop(
                requestId: nil,
                requestError: nil,
                otherError: SidecarASRClientError.processExited("sidecar client shut down"),
                terminate: true
            )
            terminateStarting()
        }

        private func ensureRunning() async throws -> RunningSidecar {
            if let running {
                if running.process.isRunning {
                    return running
                }
                failAllAndStop(
                    requestId: nil,
                    requestError: nil,
                    otherError: SidecarASRClientError.processExited("sidecar process is no longer running"),
                    terminate: false
                )
            }

            if let starting {
                return try await finishStarting(starting)
            }

            let starting = try startProcess()
            self.starting = starting
            return try await finishStarting(starting)
        }

        private func startProcess() throws -> StartingSidecar {
            let id = UUID()
            let process = Process()
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.environment = launch.environment

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] process in
                let status = Int(process.terminationStatus)
                Task { await self?.processTerminated(sidecarId: id, status: status) }
            }

            do {
                try process.run()
            } catch {
                throw SidecarASRClientError.launchFailed(error.localizedDescription)
            }

            let stderrHandle = stderr.fileHandleForReading
            let stderrSource = forwardStderrToHost(from: stderrHandle, sink: launch.stderrSink)

            let stdoutHandle = stdout.fileHandleForReading
            let stdoutReader = NDJSONLineReader(reading: stdoutHandle, label: "voiceoour.sidecar.stdout")
            let helloTask = Task.detached(priority: .userInitiated) { () throws -> ASRHello in
                guard let helloLine = await stdoutReader.nextLine() else {
                    throw SidecarASRClientError.noHello
                }
                let hello = try ASRWire.decode(ASRHello.self, from: Data(helloLine.utf8))
                guard hello.type == "hello" else {
                    throw SidecarASRClientError.noHello
                }
                guard hello.protocolVersion == asrProtocolVersion else {
                    throw SidecarASRClientError.incompatibleHello
                }
                return hello
            }

            return StartingSidecar(
                id: id,
                process: process,
                stdin: stdin.fileHandleForWriting,
                stdout: stdoutHandle,
                stdoutReader: stdoutReader,
                stderr: stderrHandle,
                stderrSource: stderrSource,
                helloTask: helloTask
            )
        }

        private func finishStarting(_ starting: StartingSidecar) async throws -> RunningSidecar {
            do {
                let hello = try await starting.helloTask.value
                if let running, running.id == starting.id {
                    return running
                }
                guard self.starting?.id == starting.id else {
                    closeStarting(starting)
                    throw SidecarASRClientError.processExited("sidecar startup was interrupted")
                }

                let running = RunningSidecar(starting: starting, hello: hello)
                self.starting = nil
                self.running = running
                startReader(for: running)
                return running
            } catch {
                if self.starting?.id == starting.id {
                    self.starting = nil
                }
                closeStarting(starting)
                throw error
            }
        }

        private func startReader(for running: RunningSidecar) {
            let reader = running.stdoutReader
            let sidecarId = running.id
            running.readerTask = Task.detached(priority: .userInitiated) { [weak self] in
                while let line = await reader.nextLine() {
                    await self?.handleLine(line, sidecarId: sidecarId)
                }
                await self?.stdoutClosed(sidecarId: sidecarId)
            }
        }

        private func handleLine(_ line: String, sidecarId: UUID) {
            guard running?.id == sidecarId else { return }
            guard let type = try? SidecarASRClient.messageType(from: line) else { return }
            let data = Data(line.utf8)

            switch type {
            case "result":
                guard let result = try? ASRWire.decode(ASRResult.self, from: data) else { return }
                guard let pending = pending.removeValue(forKey: result.requestId) else { return }
                pending.resumeTranscribe(result)
            case "health":
                guard let response = try? ASRWire.decode(ASRHealthResponse.self, from: data) else { return }
                guard let pending = pending.removeValue(forKey: response.requestId), let running else { return }
                pending.resumeHealth(
                    ASRBackendHealth(
                        backendId: running.hello.backendId,
                        backendStatus: running.hello.backendStatus,
                        ready: response.ready,
                        modelLoaded: response.modelLoaded,
                        cacheOk: response.cacheOk
                    ))
            case "error":
                guard let error = try? ASRWire.decode(ASRErrorMessage.self, from: data) else { return }
                if let requestId = error.requestId {
                    guard let pending = pending.removeValue(forKey: requestId) else { return }
                    pending.resume(throwing: SidecarASRClientError.protocolError(error))
                } else {
                    failAllAndStop(
                        requestId: nil,
                        requestError: nil,
                        otherError: SidecarASRClientError.protocolError(error),
                        terminate: false
                    )
                }
            case "cancelled":
                guard let cancelled = try? ASRWire.decode(ASRCancelledMessage.self, from: data) else { return }
                guard let pending = pending.removeValue(forKey: cancelled.requestId) else { return }
                pending.resume(throwing: CancellationError())
            default:
                return
            }
        }

        private func stdoutClosed(sidecarId: UUID) {
            guard running?.id == sidecarId else { return }
            failAllAndStop(
                requestId: nil,
                requestError: nil,
                otherError: SidecarASRClientError.processExited("sidecar stdout closed"),
                terminate: true
            )
        }

        private func processTerminated(sidecarId: UUID, status: Int) {
            if running?.id == sidecarId {
                failAllAndStop(
                    requestId: nil,
                    requestError: nil,
                    otherError: SidecarASRClientError.processExited("sidecar exited with status \(status)"),
                    terminate: false
                )
            }
        }

        private func failAllAndStop(requestId: String?, requestError: Error?, otherError: Error, terminate: Bool) {
            let sidecar = running
            running = nil

            let pendingRequests = pending
            pending.removeAll()

            if let sidecar {
                if terminate {
                    terminateRunning(sidecar)
                } else {
                    // The sidecar is abandoned rather than signalled, so its
                    // handles stay as they were -- but nothing will read them
                    // again, and a reader left running holds a duplicated
                    // descriptor and a task suspended in `nextLine()`.
                    stopReaders(of: sidecar)
                }
            }

            for (pendingRequestId, continuation) in pendingRequests {
                if pendingRequestId == requestId, let requestError {
                    continuation.resume(throwing: requestError)
                } else {
                    continuation.resume(throwing: otherError)
                }
            }
        }

        private func terminateRunning(_ sidecar: RunningSidecar) {
            stopReaders(of: sidecar)
            try? sidecar.stdin.close()
            try? sidecar.stdout.close()
            try? sidecar.stderr.close()
            if sidecar.process.isRunning {
                sidecar.process.terminate()
            }
        }

        /// Stopping a reader is what ends it: each owns a duplicate of the
        /// descriptor it drains and closes that duplicate from its own cancel
        /// handler, so the closes above no longer race a read -- and no longer
        /// end one either. Cancelling the reader task only releases the pull it
        /// is suspended in; the source stop is what retires the descriptor.
        private func stopReaders(of sidecar: RunningSidecar) {
            sidecar.readerTask?.cancel()
            sidecar.stdoutReader.stop()
            sidecar.stderrSource.stop()
        }

        private func terminateStarting() {
            guard let starting else { return }
            self.starting = nil
            closeStarting(starting)
        }

        private func closeStarting(_ starting: StartingSidecar) {
            // Cancelling the hello task resumes its pull immediately. Without
            // it an abandoned startup left that task waiting on a close that
            // no longer ends the reader at all.
            starting.helloTask.cancel()
            starting.stdoutReader.stop()
            starting.stderrSource.stop()
            try? starting.stdin.close()
            try? starting.stdout.close()
            try? starting.stderr.close()
            if starting.process.isRunning {
                starting.process.terminate()
            }
        }
    }
}
