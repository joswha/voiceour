import Darwin
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("SidecarClientTests", .serialized)
struct SidecarClientTests {
    @Test func twoTranscribesReuseOneProcess() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            count = 0
            for line in sys.stdin:
                request = json.loads(line)
                count += 1
                emit({
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request["request_id"],
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": f"turn-{count}", "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                })
            """,
            in: temp
        )

        do {
            let client = SidecarASRClient(launch: launchConfiguration(for: script))
            // 15 s, not 2 s: this is the only budget CI proved too tight. The
            // subject here is that two turns reuse one process, not how long a
            // turn may take, and the first spawn on a cold 3-core runner pays
            // python startup with an unwarmed filesystem cache. Every other
            // budget in this file is left alone -- most of them are what ends
            // their own test, and inflating those just makes a serialized suite
            // wait out its own deadlines.
            let first = try await client.transcribe(sampleAudio(), timeoutMs: 15_000)
            let second = try await client.transcribe(sampleAudio(), timeoutMs: 15_000)

            #expect(first.transcript.text == "turn-1")
            #expect(second.transcript.text == "turn-2")
        }
    }

    @Test func timeoutAfterHelloTerminatesSilentProcessPromptly() async throws {
        let temp = try makeTemporaryDirectory()
        let pidFile = temp.appendingPathComponent("pid.txt")
        let terminatedFile = temp.appendingPathComponent("terminated.txt")
        let script = try writePythonScript(
            """
            import json, os, signal, sys, time

            def record_termination(signum, frame):
                with open(\(pythonLiteral(terminatedFile.path)), "w", encoding="utf-8") as handle:
                    handle.write("terminated")
                sys.exit(0)

            signal.signal(signal.SIGTERM, record_termination)

            with open(\(pythonLiteral(pidFile.path)), "w", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))

            print(json.dumps({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            }), flush=True)

            for line in sys.stdin:
                time.sleep(10)
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        await client.warmUp()
        let pidText = try await waitForFile(pidFile, timeout: 1.0)
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let start = Date()
        let outcome = await resultWithin(timeout: 2.0) {
            try await client.transcribe(sampleAudio(), timeoutMs: 200)
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let outcome else {
            Issue.record("Expected timeout to complete within 2 seconds")
            Darwin.kill(pid, SIGTERM)
            _ = await waitForProcessExit(pid, timeout: 1.5)
            return
        }
        guard case .failure(let error) = outcome, let sidecarError = error as? SidecarASRClientError else {
            Issue.record("Expected SidecarASRClientError.timeout, got \(outcome)")
            return
        }
        #expect(sidecarError == .timeout)
        #expect(elapsed < 2.0)

        #expect(try await waitForFile(terminatedFile, timeout: 1.5) == "terminated")
        #expect(await waitForProcessExit(pid, timeout: 1.5))
    }

    @Test func stderrFloodBeforeReplyStillSucceeds() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            for line in sys.stdin:
                request = json.loads(line)
                sys.stderr.buffer.write(b"x" * (256 * 1024))
                sys.stderr.flush()
                emit({
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request["request_id"],
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": "after-stderr-flood", "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                })
            """,
            in: temp
        )

        // The flood is captured, not forwarded. 256 KiB as one line with no
        // newline stalls a CI log consumer; the stall backpressures through
        // swiftpm's 64 KiB capture pipe and wedges the whole test binary, which
        // is how this test used to take CI down -- measured: under a stalled
        // consumer the run hung for a full 180 s and exactly 65,536 bytes
        // escaped. Counting here is also stronger than spraying at fd 2: the
        // drain is asserted to have kept up, not merely to have survived.
        let forwarded = FloodCounter()
        var launch = launchConfiguration(for: script)
        launch.stderrSink = { [forwarded] bytes in forwarded.add(bytes.count) }

        let client = SidecarASRClient(launch: launch)
        let result = try await client.transcribe(sampleAudio(), timeoutMs: 15_000)

        #expect(result.transcript.text == "after-stderr-flood")
        // More than one 64 KiB pipe buffer, which is the point: the drain kept
        // draining while the child wrote, so the child never blocked and the
        // reply arrived. Not the full 256 KiB -- the reply ends the session and
        // teardown stops the source mid-flood by design, so an exact total would
        // assert a race rather than the behaviour.
        #expect(forwarded.total > 64 * 1024)
    }

    /// The stderr sink is called from the byte source's private queue, so the
    /// count it accumulates needs a lock rather than a bare `var`.
    private final class FloodCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var total: Int { lock.withLock { count } }

        func add(_ bytes: Int) { lock.withLock { count += bytes } }
    }

    @Test func transcribeRequestEncodingCarriesProtocolModelTimeoutAndSnakeCaseAudio() async throws {
        let temp = try makeTemporaryDirectory()
        let requestFile = temp.appendingPathComponent("request.json")
        let script = try writePythonScript(
            """
            import json, sys

            REQUEST_FILE = \(pythonLiteral(requestFile.path))

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            for line in sys.stdin:
                with open(REQUEST_FILE, "w", encoding="utf-8") as handle:
                    handle.write(line)
                request = json.loads(line)
                emit({
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request["request_id"],
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": "encoding-ok", "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                })
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let result = try await client.transcribe(sampleAudio(), timeoutMs: 1_234)
        #expect(result.transcript.text == "encoding-ok")

        let requestData = try Data(contentsOf: requestFile)
        let decoded = try ASRWire.decode(ASRTranscribeRequest.self, from: requestData)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.type == "transcribe")
        #expect(!decoded.requestId.isEmpty)
        #expect(decoded.expectedModel?.modelId == ASRModelContract.modelId)
        #expect(decoded.expectedModel?.revision == ASRModelContract.revision)
        #expect(decoded.timeoutMs == 1_234)

        guard let raw = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
            let audio = raw["audio"] as? [String: Any],
            let expectedModel = raw["expected_model"] as? [String: Any]
        else {
            Issue.record("Expected transcribe request object with audio and expected_model")
            return
        }
        #expect(raw["protocol_version"] as? Int == 1)
        #expect(raw["type"] as? String == "transcribe")
        #expect((raw["request_id"] as? String)?.isEmpty == false)
        #expect(expectedModel["model_id"] as? String == ASRModelContract.modelId)
        #expect(expectedModel["revision"] as? String == ASRModelContract.revision)
        #expect(raw["timeout_ms"] as? Int == 1_234)
        #expect(audio["path"] as? String == "/tmp/sidecar-client-test.wav")
        #expect(audio["format"] as? String == "wav")
        #expect(audio["sample_rate_hz"] as? Int == 16_000)
        #expect(audio["channels"] as? Int == 1)
        #expect(audio["duration_ms"] as? Int == 42)
        #expect(audio["byte_count"] as? Int == 84)
        #expect(audio["sampleRateHz"] == nil)
        #expect(audio["durationMs"] == nil)
        #expect(audio["byteCount"] == nil)
    }

    @Test func sidecarErrorMessageMapsToProtocolError() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            for line in sys.stdin:
                request = json.loads(line)
                emit({
                    "type": "error",
                    "protocol_version": 1,
                    "request_id": request["request_id"],
                    "code": "manifest_mismatch",
                    "category": "model",
                    "retryable": False,
                    "user_message_key": "asr.manifest_mismatch",
                    "detail": "wrong revision",
                })
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let error = await thrownError {
            try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        }

        guard let sidecarError = error as? SidecarASRClientError else {
            Issue.record("Expected protocolError, got \(String(describing: error))")
            return
        }
        guard case .protocolError(let message) = sidecarError else {
            Issue.record("Expected protocolError, got \(sidecarError)")
            return
        }
        #expect(message.code == ASRErrorCode.manifestMismatch)
        #expect(message.category == "model")
        #expect(message.retryable == false)
        #expect(message.userMessageKey == "asr.manifest_mismatch")
        #expect(message.detail == "wrong revision")
    }

    @Test func mismatchedRequestIdResultIsIgnoredUntilCorrectResultArrives() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys, time

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            def result(request_id, text):
                return {
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request_id,
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": text, "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                }

            for line in sys.stdin:
                request = json.loads(line)
                emit(result("not-" + request["request_id"], "wrong"))
                time.sleep(0.05)
                emit(result(request["request_id"], "correct"))
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let result = try await client.transcribe(sampleAudio(), timeoutMs: 2_000)

        #expect(result.transcript.text == "correct")
    }

    @Test func cancelledTerminalMessageThrowsCancellationError() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            for line in sys.stdin:
                request = json.loads(line)
                emit({"type": "cancelled", "protocol_version": 1, "request_id": request["request_id"]})
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let error = await thrownError {
            try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        }

        #expect(error is CancellationError)
    }

    @Test func callerCancellationSendsMatchingCancelRequest() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let transcribeFile = temp.appendingPathComponent("transcribe.json")
        let cancelFile = temp.appendingPathComponent("cancel.json")
        let script = try writePythonScript(
            """
            import json, os, sys

            TRANSCRIBE_FILE = \(pythonLiteral(transcribeFile.path))
            CANCEL_FILE = \(pythonLiteral(cancelFile.path))

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            def persist(path, line):
                temporary_path = path + ".tmp"
                with open(temporary_path, "w", encoding="utf-8") as handle:
                    handle.write(line)
                os.replace(temporary_path, path)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            transcribe_line = sys.stdin.readline()
            if not transcribe_line:
                sys.exit(0)
            persist(TRANSCRIBE_FILE, transcribe_line)
            transcribe = json.loads(transcribe_line)

            for line in sys.stdin:
                frame = json.loads(line)
                if frame.get("type") != "cancel":
                    continue
                persist(CANCEL_FILE, line)
                if frame.get("request_id") == transcribe.get("request_id"):
                    emit({
                        "type": "cancelled",
                        "protocol_version": 1,
                        "request_id": frame["request_id"],
                    })
                    break
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let transcription = Task {
            try await client.transcribe(sampleAudio(), timeoutMs: 10_000)
        }

        let transcribeLine = try await waitForFile(transcribeFile, timeout: 1.0)
        try #require(!transcribeLine.isEmpty, "Expected the sidecar to persist the transcribe frame")
        transcription.cancel()

        let outcome = await resultWithin(timeout: 2.0) {
            try await transcription.value
        }
        guard let outcome else {
            Issue.record("Expected caller cancellation to complete within 2 seconds")
            return
        }
        guard case .failure(let error) = outcome else {
            Issue.record("Expected caller cancellation to throw, got \(outcome)")
            return
        }
        #expect(error is CancellationError)

        let cancelLine = try await waitForFile(cancelFile, timeout: 1.0)
        try #require(!cancelLine.isEmpty, "Expected the sidecar to persist the cancel frame")
        let transcribe = try ASRWire.decode(ASRTranscribeRequest.self, from: Data(transcribeLine.utf8))
        let cancel = try ASRWire.decode(ASRCancelRequest.self, from: Data(cancelLine.utf8))

        #expect(transcribe.protocolVersion == 1)
        #expect(transcribe.type == "transcribe")
        #expect(cancel.protocolVersion == 1)
        #expect(cancel.type == "cancel")
        #expect(!transcribe.requestId.isEmpty)
        #expect(cancel.requestId == transcribe.requestId)
    }

    @Test func noHelloThrowsNoHello() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript("", in: temp)
        let client = SidecarASRClient(launch: launchConfiguration(for: script))

        let error = await thrownError {
            try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        }

        guard let sidecarError = error as? SidecarASRClientError else {
            Issue.record("Expected SidecarASRClientError.noHello, got \(String(describing: error))")
            return
        }
        #expect(sidecarError == .noHello)
    }

    @Test func incompatibleHelloVersionThrowsIncompatibleHello() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json
            print(json.dumps({
                "type": "hello",
                "protocol_version": 2,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            }), flush=True)
            """,
            in: temp
        )
        let client = SidecarASRClient(launch: launchConfiguration(for: script))

        let error = await thrownError {
            try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        }

        guard let sidecarError = error as? SidecarASRClientError else {
            Issue.record("Expected SidecarASRClientError.incompatibleHello, got \(String(describing: error))")
            return
        }
        #expect(sidecarError == .incompatibleHello)
    }

    @Test func processExitMidRequestErrorsAndNextTranscribeRespawns() async throws {
        let temp = try makeTemporaryDirectory()
        let stateFile = temp.appendingPathComponent("already-exited.txt")
        let script = try writePythonScript(
            """
            import json, os, sys

            STATE_FILE = \(pythonLiteral(stateFile.path))

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            first_run = not os.path.exists(STATE_FILE)
            if first_run:
                with open(STATE_FILE, "w", encoding="utf-8") as handle:
                    handle.write("exited")

            for line in sys.stdin:
                request = json.loads(line)
                if first_run:
                    sys.exit(7)
                emit({
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request["request_id"],
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": "respawned", "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                })
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let firstError = await thrownError {
            try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        }
        guard let firstSidecarError = firstError as? SidecarASRClientError else {
            Issue.record("Expected processExited SidecarASRClientError, got \(String(describing: firstError))")
            return
        }
        guard case .processExited(let reason) = firstSidecarError else {
            Issue.record("Expected processExited SidecarASRClientError, got \(firstSidecarError)")
            return
        }
        #expect(reason.contains("sidecar"))

        let second = try await client.transcribe(sampleAudio(), timeoutMs: 2_000)
        #expect(second.transcript.text == "respawned")
    }
    @Test func sidecarFramingAgainstStubProcess() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let script = temp.appendingPathComponent("stub.sh")
        let body = """
            printf '%s\\n' '{"type":"hello","protocol_version":1,"sidecar_version":"0.1.0","backend_id":"fake","backend_status":"ready","capabilities":{"final_utterance":true}}'
            while IFS= read -r line; do
              req=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
              printf '{"type":"result","protocol_version":1,"request_id":"%s","backend_id":"fake","model_id":"fake","model_revision":"dev","transcript":{"text":"stub text","language":"en","segments":null},"timings_ms":{"load":0,"inference":0,"total":0}}\\n' "$req"
            done
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let client = SidecarASRClient(
            launch: SidecarLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
        )
        let audio = RecordedAudio(
            url: URL(fileURLWithPath: "/tmp/fake.wav"),
            meta: ASRAudioMeta(
                path: "/tmp/fake.wav", format: "wav", sampleRateHz: 16000, channels: 1, durationMs: 42, byteCount: 84))
        let result = try await client.transcribe(audio, timeoutMs: 2000)
        #expect(result.transcript.text == "stub text")
    }

    @Test func sidecarHealthAgainstStubProcess() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let script = temp.appendingPathComponent("stub-health.sh")
        let body = """
            printf '%s\\n' '{"type":"hello","protocol_version":1,"sidecar_version":"0.1.0","backend_id":"fake","backend_status":"ready","capabilities":{"final_utterance":true}}'
            while IFS= read -r line; do
              req=$(printf '%s' "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
              printf '{"type":"health","protocol_version":1,"request_id":"%s","ready":true,"model_loaded":true,"cache_ok":true}\\n' "$req"
            done
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let client = SidecarASRClient(
            launch: SidecarLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
        )

        let health = try await client.health(timeoutMs: 2000)

        #expect(health.backendId == "fake")
        #expect(health.backendStatus == .ready)
        #expect(health.ready)
        #expect(health.modelLoaded)
        #expect(health.cacheOk)
    }

    // MARK: Request multiplexing
    //
    // The client keys pending requests by `request_id` so several can be in
    // flight on one stdio pair. Until now only sequential reuse was proven, so
    // the multiplexing itself -- the part a shared NDJSON runtime would have to
    // preserve -- was untested.

    /// Answers the SECOND request first. A client that assumed FIFO would hand
    /// each caller the other's transcript.
    @Test func twoOutstandingRequestsAnsweredOutOfOrderEachGetTheirOwnResult() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            def result(request_id, text):
                return {
                    "type": "result",
                    "protocol_version": 1,
                    "request_id": request_id,
                    "backend_id": "fake",
                    "model_id": "fake",
                    "model_revision": "dev",
                    "transcript": {"text": text, "language": "en", "segments": None},
                    "timings_ms": {"load": 0, "inference": 0, "total": 0},
                }

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            # Hold the first request until the second arrives, then reply in
            # reverse order.
            queued = []
            for line in sys.stdin:
                queued.append(json.loads(line)["request_id"])
                if len(queued) < 2:
                    continue
                emit(result(queued[1], "second-" + queued[1]))
                emit(result(queued[0], "first-" + queued[0]))
                queued = []
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        async let first = client.transcribe(sampleAudio(), timeoutMs: 5_000)
        async let second = client.transcribe(sampleAudio(), timeoutMs: 5_000)
        let results = try await [first, second]

        // Each caller's transcript carries the id the sidecar echoed back, so a
        // crossed pairing shows up as the wrong prefix.
        #expect(results.filter { $0.transcript.text.hasPrefix("first-") }.count == 1)
        #expect(results.filter { $0.transcript.text.hasPrefix("second-") }.count == 1)
        #expect(Set(results.map(\.requestId)).count == 2)
        for result in results {
            #expect(result.transcript.text.hasSuffix(result.requestId))
        }
    }

    /// Cancelling one in-flight request must not disturb the other: the sidecar
    /// answers the cancelled one with `cancelled` and still returns a result for
    /// the survivor on the same stdio pair.
    @Test func cancellingOneRequestLetsTheOtherComplete() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            outstanding = []
            for line in sys.stdin:
                request = json.loads(line)
                if request["type"] == "cancel":
                    target = request["request_id"]
                    emit({
                        "type": "cancelled",
                        "protocol_version": 1,
                        "request_id": target,
                    })
                    for other in outstanding:
                        if other == target:
                            continue
                        emit({
                            "type": "result",
                            "protocol_version": 1,
                            "request_id": other,
                            "backend_id": "fake",
                            "model_id": "fake",
                            "model_revision": "dev",
                            "transcript": {"text": "survivor", "language": "en", "segments": None},
                            "timings_ms": {"load": 0, "inference": 0, "total": 0},
                        })
                    outstanding = []
                else:
                    outstanding.append(request["request_id"])
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let cancelled = Task { try await client.transcribe(sampleAudio(), timeoutMs: 5_000) }
        let survivor = Task { try await client.transcribe(sampleAudio(), timeoutMs: 5_000) }

        // Both requests have to be on the wire before either can be cancelled,
        // and only the sidecar knows that; give the writes a bounded moment.
        try? await Task.sleep(for: .milliseconds(300))
        cancelled.cancel()

        var cancelledFailed = false
        do {
            _ = try await cancelled.value
        } catch {
            cancelledFailed = true
        }

        #expect(cancelledFailed, "the cancelled request must not return a transcript")
        #expect(try await survivor.value.transcript.text == "survivor")
    }

    /// A sidecar that exits with several requests outstanding must fail every one
    /// of them rather than leaving a caller suspended forever.
    @Test func processExitFailsEveryPendingRequest() async throws {
        let temp = try makeTemporaryDirectory()
        let script = try writePythonScript(
            """
            import json, sys

            def emit(message):
                print(json.dumps(message, separators=(",", ":")), flush=True)

            emit({
                "type": "hello",
                "protocol_version": 1,
                "sidecar_version": "0.1.0",
                "backend_id": "fake",
                "backend_status": "ready",
                "capabilities": {"final_utterance": True},
            })

            # Read both requests, answer neither, then die.
            seen = 0
            for line in sys.stdin:
                seen += 1
                if seen >= 2:
                    break
            sys.exit(9)
            """,
            in: temp
        )

        let client = SidecarASRClient(launch: launchConfiguration(for: script))
        let first = Task { try await client.transcribe(sampleAudio(), timeoutMs: 5_000) }
        let second = Task { try await client.transcribe(sampleAudio(), timeoutMs: 5_000) }

        var failures = 0
        for task in [first, second] {
            do {
                _ = try await task.value
            } catch {
                failures += 1
            }
        }

        #expect(failures == 2, "a dead sidecar must fail every outstanding request")
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidecarClientTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writePythonScript(_ body: String, in directory: URL, name: String = "sidecar.py") throws -> URL {
    let script = directory.appendingPathComponent(name)
    try body.write(to: script, atomically: true, encoding: .utf8)
    return script
}

private func launchConfiguration(for script: URL) -> SidecarLaunchConfiguration {
    SidecarLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [script.path]
    )
}

private func sampleAudio() -> RecordedAudio {
    RecordedAudio(
        url: URL(fileURLWithPath: "/tmp/sidecar-client-test.wav"),
        meta: ASRAudioMeta(
            path: "/tmp/sidecar-client-test.wav",
            format: "wav",
            sampleRateHz: 16_000,
            channels: 1,
            durationMs: 42,
            byteCount: 84
        )
    )
}

private func pythonLiteral(_ value: String) -> String {
    let escaped =
        value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func thrownError<T>(from operation: () async throws -> T) async -> Error? {
    do {
        _ = try await operation()
        Issue.record("Expected operation to throw")
        return nil
    } catch {
        return error
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return }
        stored = result
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func resultWithin<T>(timeout: TimeInterval, operation: @escaping () async throws -> T) async -> Result<
    T, Error
>? {
    let result = LockedResult<T>()
    let task = Task {
        do {
            result.set(.success(try await operation()))
        } catch {
            result.set(.failure(error))
        }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let completed = result.get() {
            return completed
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    task.cancel()
    return result.get()
}

private func waitForFile(_ file: URL, timeout: TimeInterval) async throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: file.path) {
            return try String(contentsOf: file, encoding: .utf8)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return FileManager.default.fileExists(atPath: file.path)
        ? try String(contentsOf: file, encoding: .utf8)
        : ""
}
