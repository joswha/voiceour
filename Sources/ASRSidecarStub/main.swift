import Darwin
import Foundation
import Synchronization
import VoiceCore

/// Published before the handler is installed and kept alive until `_exit`.
/// A lock-free pointer load keeps the signal handler independent of Swift actors or locks.
private let terminationMarkerPath = Atomic<UInt>(0)

/// A misbehaving NDJSON peer, selected by argv, for exercising `SidecarASRClient`.
///
/// Every case here is a *client* test fixture: a protocol violation, a hang, a crash or an
/// out-of-order reply that the real sidecar must never produce. It exists as a Swift target
/// rather than the inline `python3` scripts it replaces so the test suite needs no interpreter
/// and so these frames are built from the same `ASRWire` types the client decodes.
///
/// Never linked into the app; it is a test-support product only.
enum StubMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let scenario = arguments.first else {
            fail("usage: ASRSidecarStub <scenario> [args...]")
        }
        let rest = Array(arguments.dropFirst())

        if runHandshakeScenario(scenario, rest) { return }
        if runReplyScenario(scenario, rest) { return }
        if runStatefulScenario(scenario, rest) { return }
        fail("unknown scenario \(scenario)")
    }

    // MARK: - Handshake scenarios

    /// Peers that never get as far as answering a request.
    private static func runHandshakeScenario(_ scenario: String, _ rest: [String]) -> Bool {
        switch scenario {
        case "no-hello":
            // Exits without greeting. That, not silence, is what the client reports as
            // `.noHello`: a peer that is merely quiet is indistinguishable from a slow one
            // and correctly ends in `.timeout` instead.
            exit(0)
        case "wrong-version-hello":
            emitRaw(
                """
                {"backend_id":"fake","backend_status":"ready","capabilities":{"final_utterance":true},\
                "protocol_version":2,"sidecar_version":"0.1.0","type":"hello"}
                """
            )
            blockForever()
        case "silent-after-hello":
            silentAfterHello(pidFile: rest.first, terminatedFile: rest.dropFirst().first)
        case "malformed-hello-first-run":
            guard let frame = rest.first, let stateFile = rest.dropFirst().first else {
                fail("malformed-hello-first-run needs a frame kind and state file")
            }
            if markFirstRun(stateFile: stateFile) {
                var batch = malformedFrameData(frame, requestId: "startup")
                guard
                    let validHello = try? ASRWire.encodeLine(
                        ASRHello(
                            sidecarVersion: "0.1.0",
                            backendId: "fake",
                            backendStatus: .ready,
                            capabilities: ASRCapabilities(finalUtterance: true)
                        )
                    )
                else { fail("could not encode hello tail") }
                batch.append(validHello)
                FileHandle.standardOutput.write(batch)
                blockForever()
            }
            serve { _, id, type in
                FileHandle.standardOutput.write(recoveryResponse(requestId: id, type: type, recovered: true))
            }
        default:
            return false
        }
        return true
    }

    // MARK: - One-reply-per-request scenarios

    private static func runReplyScenario(_ scenario: String, _ rest: [String]) -> Bool {
        switch scenario {
        case "echo-turns":
            var turn = 0
            serve { _, id, _ in
                turn += 1
                emit(result(requestId: id, text: "turn-\(turn)"))
            }
        case "fixed-result":
            let text = rest.first ?? "stub text"
            serve { _, id, _ in emit(result(requestId: id, text: text)) }
        case "health":
            serve { _, id, _ in
                emit(ASRHealthResponse(requestId: id, ready: true, modelLoaded: true, cacheOk: true))
            }
        case "echo-result":
            guard let requestFile = rest.first else { fail("echo-result needs a request file") }
            serve { line, id, _ in
                persist(line, to: requestFile)
                emit(result(requestId: id, text: "encoding-ok"))
            }
        case "error-reply":
            serve { _, id, _ in
                emit(
                    ASRErrorMessage(
                        requestId: id,
                        code: .manifestMismatch,
                        category: "model",
                        retryable: false,
                        userMessageKey: "asr.manifest_mismatch",
                        detail: "wrong revision"
                    )
                )
            }
        case "cancelled-reply":
            serve { _, id, _ in emit(ASRCancelledMessage(requestId: id)) }
        case "mismatched-request-id":
            serve { _, id, _ in
                emit(result(requestId: "not-" + id, text: "wrong"))
                Thread.sleep(forTimeInterval: 0.05)
                emit(result(requestId: id, text: "correct"))
            }
        case "stderr-flood":
            serve { _, id, _ in
                FileHandle.standardError.write(Data(repeating: UInt8(ascii: "x"), count: 256 * 1024))
                emit(result(requestId: id, text: "after-stderr-flood"))
            }
        default:
            return false
        }
        return true
    }

    // MARK: - Scenarios that carry state across frames or processes

    private static func runStatefulScenario(_ scenario: String, _ rest: [String]) -> Bool {
        switch scenario {
        case "record-cancel":
            recordCancel(transcribeFile: rest.first, cancelFile: rest.dropFirst().first)
        case "exit-first-run":
            exitOnFirstRun(stateFile: rest.first)
        case "malformed-first-run", "malformed-two-pending-first-run":
            guard let frame = rest.first, let stateFile = rest.dropFirst().first else {
                fail("\(scenario) needs a frame kind and state file")
            }
            malformedOnFirstRun(
                frame: frame,
                stateFile: stateFile,
                waitForBothRequests: scenario == "malformed-two-pending-first-run"
            )
        case "exit-mid-request":
            let target = Int(rest.first ?? "1") ?? 1
            var seen = 0
            serve { _, _, _ in
                seen += 1
                if seen >= target { exit(9) }
            }
        case "out-of-order":
            outOfOrder()
        case "cancel-one":
            cancelOne()
        default:
            return false
        }
        return true
    }

    /// Records its pid, greets, then answers nothing. On SIGTERM it records that it was
    /// signalled, which is how the timeout test proves the client actually killed it.
    private static func silentAfterHello(pidFile: String?, terminatedFile: String?) {
        if let terminatedFile {
            terminationMarkerPath.store(UInt(bitPattern: strdup(terminatedFile)), ordering: .releasing)
            signal(SIGTERM) { _ in
                if let path = UnsafePointer<CChar>(bitPattern: terminationMarkerPath.load(ordering: .acquiring)) {
                    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                    if descriptor >= 0 {
                        _ = "terminated".withCString { write(descriptor, $0, strlen($0)) }
                        close(descriptor)
                    }
                }
                _exit(0)
            }
        }
        if let pidFile { persist(String(getpid()), to: pidFile) }
        serve { _, _, _ in }
        blockForever()
    }

    private static func recordCancel(transcribeFile: String?, cancelFile: String?) {
        guard let transcribeFile, let cancelFile else { fail("record-cancel needs two files") }
        var transcribeId: String?
        serve { line, id, type in
            if type == "cancel" {
                persist(line, to: cancelFile)
                if id == transcribeId { emit(ASRCancelledMessage(requestId: id)) }
                return
            }
            guard transcribeId == nil else { return }
            transcribeId = id
            persist(line, to: transcribeFile)
        }
    }

    /// Exits mid-request the first time this scenario ever runs, and answers normally on every
    /// later run. The marker file is what makes "the client respawned me" observable.
    private static func exitOnFirstRun(stateFile: String?) {
        guard let stateFile else { fail("exit-first-run needs a state file") }
        let firstRun = !FileManager.default.fileExists(atPath: stateFile)
        if firstRun { persist("exited", to: stateFile) }
        serve { _, id, _ in
            if firstRun { exit(7) }
            emit(result(requestId: id, text: "respawned"))
        }
    }

    /// Records the original pid before greeting; a later invocation is observably healthy.
    private static func markFirstRun(stateFile: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: stateFile) else { return false }
        persist(String(getpid()), to: stateFile)
        return true
    }

    /// The fault and all otherwise valid replies share one write. A client must discard the
    /// whole corrupt channel, not accept a valid tail or leave another pending caller behind.
    private static func malformedOnFirstRun(frame: String, stateFile: String, waitForBothRequests: Bool) {
        let firstRun = markFirstRun(stateFile: stateFile)
        var queued: [(id: String, type: String)] = []
        var emittedFault = false
        serve { _, id, type in
            guard type == "transcribe" || type == "health" else { return }
            guard firstRun, !emittedFault else {
                FileHandle.standardOutput.write(recoveryResponse(requestId: id, type: type, recovered: !firstRun))
                return
            }
            queued.append((id, type))
            if waitForBothRequests {
                guard queued.contains(where: { $0.type == "transcribe" }),
                    queued.contains(where: { $0.type == "health" })
                else { return }
            }
            emittedFault = true
            var batch = malformedFrameData(frame, requestId: id)
            for request in queued {
                batch.append(recoveryResponse(requestId: request.id, type: request.type, recovered: false))
            }
            FileHandle.standardOutput.write(batch)
            queued.removeAll()
        }
    }

    private static func malformedFrameData(_ kind: String, requestId: String) -> Data {
        switch kind {
        case "invalid-utf8":
            return invalidUTF8Line(result(requestId: requestId, text: "utf8-placeholder"))
        case "invalid-utf8-hello":
            return invalidUTF8Line(
                ASRHello(
                    sidecarVersion: "utf8-placeholder",
                    backendId: "fake",
                    backendStatus: .ready,
                    capabilities: ASRCapabilities(finalUtterance: true)
                )
            )
        case "utf16-be-bom", "utf16-be-no-bom", "utf32-le-bom":
            return alternateEncodedLine(result(requestId: requestId, text: "wrong-encoding"), encoding: kind)
        case "utf16-be-bom-hello", "utf16-be-no-bom-hello", "utf32-le-bom-hello":
            return alternateEncodedLine(
                ASRHello(
                    sidecarVersion: "0.1.0",
                    backendId: "fake",
                    backendStatus: .ready,
                    capabilities: ASRCapabilities(finalUtterance: true)
                ),
                encoding: kind
            )
        default:
            return Data((malformedFrame(kind, requestId: requestId) + "\n").utf8)
        }
    }

    /// Everything except this byte is a valid encoded frame. Lossy UTF-8 decoding would
    /// repair it into an otherwise acceptable String, hiding the corrupt transport.
    private static func invalidUTF8Line<T: Encodable>(_ message: T) -> Data {
        guard var line = try? ASRWire.encodeLine(message),
            let placeholder = line.range(of: Data("utf8-placeholder".utf8))
        else { fail("could not encode invalid UTF-8 fixture") }
        line.replaceSubrange(placeholder, with: [0xFF])
        return line
    }

    /// Uses ASCII JSON so each code unit can be written explicitly without Foundation
    /// deciding whether to include a BOM. Only the final delimiter is a raw UTF-8 LF.
    private static func alternateEncodedLine<T: Encodable>(_ message: T, encoding: String) -> Data {
        guard let json = try? ASRWire.makeEncoder().encode(message) else {
            fail("could not encode alternate-encoding fixture")
        }
        var line: Data
        let width: Int
        switch encoding {
        case "utf16-be-bom", "utf16-be-bom-hello":
            line = Data([0xFE, 0xFF])
            width = 2
        case "utf16-be-no-bom", "utf16-be-no-bom-hello":
            line = Data()
            width = 2
        case "utf32-le-bom", "utf32-le-bom-hello":
            line = Data([0xFF, 0xFE, 0x00, 0x00])
            width = 4
        default:
            fail("unknown alternate encoding \(encoding)")
        }
        line.reserveCapacity(line.count + json.count * width + 1)
        for byte in json {
            guard byte < 0x80 else { fail("alternate-encoding fixture requires ASCII JSON") }
            if width == 2 { line.append(0) }
            line.append(byte)
            if width == 4 {
                line.append(0)
                line.append(0)
                line.append(0)
            }
        }
        line.append(0x0A)
        return line
    }

    private static func malformedFrame(_ kind: String, requestId: String) -> String {
        switch kind {
        case "invalid-json":
            return "{"
        case "missing-type":
            return #"{"protocol_version":1,"request_id":"\#(requestId)"}"#
        case "non-string-type":
            return #"{"type":42,"protocol_version":1,"request_id":"\#(requestId)"}"#
        case "unknown-type":
            return #"{"type":"future","protocol_version":1,"request_id":"\#(requestId)"}"#
        case "invalid-result":
            return #"{"type":"result","protocol_version":1,"request_id":"\#(requestId)","transcript":false}"#
        case "invalid-health":
            return #"{"type":"health","protocol_version":1,"request_id":"\#(requestId)","ready":"yes"}"#
        case "invalid-error":
            return #"{"type":"error","protocol_version":1,"request_id":"\#(requestId)","code":42}"#
        case "invalid-cancelled":
            return #"{"type":"cancelled","protocol_version":1,"request_id":42}"#
        case "invalid-hello":
            return #"{"type":"hello","protocol_version":1,"capabilities":false}"#
        case "wrong-kind-hello":
            return """
                {"type":"result","protocol_version":1,"sidecar_version":"0.1.0",\
                "backend_id":"fake","backend_status":"ready","capabilities":{"final_utterance":true}}
                """
        default:
            fail("unknown malformed frame kind \(kind)")
        }
    }

    private static func recoveryResponse(requestId: String, type: String, recovered: Bool) -> Data {
        do {
            if type == "health" {
                return try ASRWire.encodeLine(
                    ASRHealthResponse(
                        requestId: requestId, ready: recovered, modelLoaded: recovered, cacheOk: recovered)
                )
            }
            return try ASRWire.encodeLine(
                result(requestId: requestId, text: recovered ? "respawned" : "corrupt-channel")
            )
        } catch {
            fail("could not encode recovery response: \(error)")
        }
    }

    /// Holds the first request until a second arrives, then answers the second one first.
    private static func outOfOrder() {
        var queued: [String] = []
        serve { _, id, _ in
            queued.append(id)
            guard queued.count >= 2 else { return }
            emit(result(requestId: queued[1], text: "second-" + queued[1]))
            emit(result(requestId: queued[0], text: "first-" + queued[0]))
            queued = []
        }
    }

    /// Answers a cancel with `cancelled` for its target and completes every other outstanding
    /// request, which is the behaviour a multiplexing client has to keep straight.
    private static func cancelOne() {
        var outstanding: [String] = []
        serve { _, id, type in
            guard type == "cancel" else {
                outstanding.append(id)
                return
            }
            emit(ASRCancelledMessage(requestId: id))
            for other in outstanding where other != id {
                emit(result(requestId: other, text: "survivor"))
            }
            outstanding = []
        }
    }

    // MARK: - Plumbing

    /// Greets, then calls `body(rawLine, requestId, type)` for every well-formed frame until
    /// stdin ends.
    private static func serve(_ body: (String, String, String) -> Void) {
        emitHello()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let requestId = object["request_id"] as? String
            else { continue }
            body(line, requestId, object["type"] as? String ?? "")
        }
    }

    private static func emitHello() {
        emit(
            ASRHello(
                sidecarVersion: "0.1.0",
                backendId: "fake",
                backendStatus: .ready,
                capabilities: ASRCapabilities(finalUtterance: true)
            )
        )
    }

    private static func result(requestId: String, text: String) -> ASRResult {
        ASRResult(
            requestId: requestId,
            backendId: "fake",
            modelId: "fake",
            modelRevision: "dev",
            transcript: ASRTranscript(text: text, language: "en", segments: nil),
            timingsMs: ASRTimings(load: 0, inference: 0, total: 0)
        )
    }

    private static func emit<T: Encodable>(_ message: T) {
        guard let line = try? ASRWire.encodeLine(message) else { return }
        try? FileHandle.standardOutput.write(contentsOf: line)
    }

    private static func emitRaw(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Atomic, so a test polling the file never reads a half-written frame.
    private static func persist(_ contents: String, to path: String) {
        let temporary = path + ".tmp"
        try? contents.write(toFile: temporary, atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: temporary, toPath: path)
    }

    private static func blockForever() -> Never {
        // `pause` sleeps until a signal arrives, so a peer that must not answer also must not
        // spin: a busy-waiting stub starves the very test binary that spawned it.
        while true { pause() }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

StubMain.main()
