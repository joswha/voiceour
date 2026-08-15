import Foundation
import Testing
import VoiceCore

/// Drives the real `voiceour-asr` binary over stdio in fake mode.
///
/// These are the protocol-loop behaviours the retired Python `test_sidecar_process.py` owned:
/// the loop keeps running after a malformed frame, answers health mid-life, honours cancel, and
/// never writes anything but protocol JSON to stdout. They run the actual shipped executable,
/// so a regression in argument handling or startup shows up here rather than at first dictation.
// Ten minutes rather than one: the opt-in VOICEOUR_PARAKEET_INTEGRATION cases decode two
// minutes of audio twice and poll a 60 s idle timer. The limit is a hang diagnostic, not a
// performance budget — a hung synchronous call still blocks the binary, but the expired test
// is named with a timeLimitExceeded issue instead of the run dying anonymously.
@Suite("SidecarProcessTests", .serialized, .timeLimit(.minutes(10)))
struct SidecarProcessTests {
    @Test func healthReportsAReadyFakeBackend() throws {
        let session = try Sidecar.run(lines: [request("health", id: "h1")])

        #expect(session.types == ["hello", "health"])
        let health = try #require(session.object(type: "health"))
        #expect(health["ready"] as? Bool == true)
        #expect(health["model_loaded"] as? Bool == true)
        #expect(health["cache_ok"] as? Bool == true)
        #expect(health["request_id"] as? String == "h1")
    }

    @Test func helloAnnouncesTheBackendAndProtocolVersion() throws {
        let session = try Sidecar.run(lines: [])
        let hello = try #require(session.object(type: "hello"))

        #expect(hello["protocol_version"] as? Int == 1)
        #expect(hello["backend_id"] as? String == "fake")
        #expect(hello["backend_status"] as? String == "ready")
        #expect(hello["sidecar_version"] as? String == "1.0.0")
    }

    @Test func aFutureProtocolVersionIsRejectedWithoutClosingTheLoop() throws {
        let session = try Sidecar.run(lines: [
            #"{"type":"health","protocol_version":2,"request_id":"v2"}"#,
            request("health", id: "after"),
        ])

        #expect(session.types == ["hello", "error", "health"])
        let error = try #require(session.object(type: "error"))
        #expect(error["code"] as? String == "incompatible_protocol")
        #expect(error["request_id"] as? String == "v2")
        #expect(error["detail"] as? String == "protocol_version mismatch")
    }

    @Test func anUnknownRequestTypeIsRejectedWithoutClosingTheLoop() throws {
        let session = try Sidecar.run(lines: [
            #"{"type":"wat","protocol_version":1,"request_id":"w1"}"#,
            request("health", id: "after"),
        ])

        #expect(session.types == ["hello", "error", "health"])
        let error = try #require(session.object(type: "error"))
        #expect(error["code"] as? String == "invalid_request")
        #expect(error["request_id"] as? String == "w1")
        #expect((error["detail"] as? String)?.contains("wat") == true)
    }

    @Test func aNonJSONLineIsRejectedWithoutClosingTheLoop() throws {
        let session = try Sidecar.run(lines: ["not-json", request("health", id: "after")])

        #expect(session.types == ["hello", "error", "health"])
        let error = try #require(session.object(type: "error"))
        #expect(error["code"] as? String == "invalid_request")
        #expect(error["request_id"] == nil)
    }

    @Test func anUnknownBackendStillSpeaksTheProtocol() throws {
        let session = try Sidecar.run(
            lines: [request("health", id: "h1")],
            environment: ["VOICEOUR_ASR_BACKEND": "not-a-backend"]
        )

        #expect(session.types == ["hello", "error"])
        let hello = try #require(session.object(type: "hello"))
        #expect(hello["backend_id"] as? String == "unknown")
        #expect(hello["backend_status"] as? String == "backend_unavailable")

        let error = try #require(session.object(type: "error"))
        #expect(error["code"] as? String == "backend_unavailable")
        #expect(error["detail"] as? String == "unknown backend")
        #expect(error["category"] as? String == "setup")
    }

    @Test func cancelInterruptsAnInFlightTranscribeWellBeforeItWouldFinish() throws {
        let audio = try TemporaryWAV()
        defer { audio.remove() }

        let started = Date()
        let session = try Sidecar.run(
            lines: [
                transcribeRequest(id: "t1", audio: audio.meta),
                request("cancel", id: "t1"),
            ],
            environment: ["VOICEOUR_FAKE_DELAY_MS": "1000"],
            timeout: 10
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(session.types == ["hello", "cancelled"])
        let cancelled = try #require(session.object(type: "cancelled"))
        #expect(cancelled["request_id"] as? String == "t1")
        #expect(elapsed < 1.0, "cancel must not wait out the full fake delay")
    }

    @Test func twoTranscribesRunInOneProcessAndProduceTheContractedTranscript() throws {
        let audio = try TemporaryWAV()
        defer { audio.remove() }

        let session = try Sidecar.run(lines: [
            transcribeRequest(id: "t1", audio: audio.meta, durationMs: 321),
            transcribeRequest(id: "t2", audio: audio.meta, durationMs: 321),
        ])

        #expect(session.types == ["hello", "result", "result"])
        let results = session.objects.filter { $0["type"] as? String == "result" }
        #expect(results.compactMap { $0["request_id"] as? String } == ["t1", "t2"])
        for result in results {
            let transcript = try #require(result["transcript"] as? [String: Any])
            #expect(transcript["text"] as? String == "fake transcript duration_ms=321")
        }
    }

    /// Preload and the first transcribe race for the model, and the parakeet context owns ggml's
    /// Metal device. When both sides could build a context, the loser's deallocation tore the
    /// device down under the winner and every later encode failed with "command buffer failed
    /// with status 1" — 256 of 256 benchmark rows, while `--prove` and a hand-driven dictation
    /// both passed because preload always won those. Needs the model cache; opt in with
    /// `VOICEOUR_PARAKEET_INTEGRATION=1`.
    @Test func preloadAndAnImmediateTranscribeShareOneModel() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }
        let audio = try RealAudioFixture()

        let session = try Sidecar.run(
            lines: [
                transcribeRequest(id: "t1", audio: audio.meta),
                transcribeRequest(id: "t2", audio: audio.meta),
                transcribeRequest(id: "t3", audio: audio.meta),
            ],
            environment: ["VOICEOUR_ASR_BACKEND": "parakeet", "VOICEOUR_PRELOAD": "1"],
            timeout: 300
        )

        #expect(session.types == ["hello", "result", "result", "result"])
        for result in session.objects where result["type"] as? String == "result" {
            let transcript = try #require(result["transcript"] as? [String: Any])
            let text = try #require(transcript["text"] as? String)
            #expect(text.lowercased().contains("hello world"))
            #expect(transcript["confidence_mode"] as? String == "greedy_token_prob")
        }
        #expect(!session.stderrText.contains("command buffer"), "the Metal device must survive the load race")
    }

    @Test func stdoutCarriesProtocolJSONAndNothingElse() throws {
        let audio = try TemporaryWAV()
        defer { audio.remove() }

        let session = try Sidecar.run(lines: [
            request("health", id: "h1"),
            transcribeRequest(id: "t1", audio: audio.meta),
        ])

        #expect(session.types == ["hello", "health", "result"])
        for object in session.objects {
            #expect(object["protocol_version"] as? Int == 1)
        }
    }

    @Test func aDuplicateInFlightRequestIdIsRejected() throws {
        let audio = try TemporaryWAV()
        defer { audio.remove() }

        let session = try Sidecar.run(
            lines: [
                transcribeRequest(id: "same", audio: audio.meta),
                transcribeRequest(id: "same", audio: audio.meta),
            ],
            environment: ["VOICEOUR_FAKE_DELAY_MS": "300"],
            timeout: 10
        )

        #expect(session.types.contains("error"))
        let error = try #require(session.object(type: "error"))
        #expect(error["code"] as? String == "invalid_request")
        #expect(error["detail"] as? String == "request_id already in flight")
    }

    @Test func aFakePartialAnswersAndLeavesTheProcessServing() throws {
        let pcm = try TemporaryPCM(sampleCount: 16_000)
        defer { pcm.remove() }
        let audio = try TemporaryWAV()
        defer { audio.remove() }

        let session = try Sidecar.run(lines: [
            partialRequest(id: "p1", pcm: pcm.meta),
            transcribeRequest(id: "t1", audio: audio.meta),
        ])

        #expect(session.types == ["hello", "result", "result"])
        let partial = try #require(session.objects.first { $0["request_id"] as? String == "p1" })
        let transcript = try #require(partial["transcript"] as? [String: Any])
        #expect(transcript["text"] as? String == "fake partial samples=16000")
    }

    /// The preview path decoding real audio. Opt in with `VOICEOUR_PARAKEET_INTEGRATION=1`.
    @Test func aRealPartialDecodesThePrefixOfALiveCapture() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }
        let samples = try RealAudioFixture().pcmPayload()
        let pcm = try TemporaryPCM(bytes: samples + samples + samples)
        defer { pcm.remove() }

        let session = try Sidecar.run(
            lines: [partialRequest(id: "p1", pcm: pcm.meta)],
            environment: ["VOICEOUR_ASR_BACKEND": "parakeet", "VOICEOUR_PRELOAD": "1"],
            timeout: 300
        )

        #expect(session.types == ["hello", "result"])
        let result = try #require(session.object(type: "result"))
        let transcript = try #require(result["transcript"] as? [String: Any])
        let text = try #require(transcript["text"] as? String)
        #expect(text.lowercased().contains("hello"))
    }

    /// The first exercise of parakeet.cpp's dynamic-encoder path: past 5000 mel frames the
    /// runtime rebuilds its graph rather than using the static one, and nothing in this
    /// repository had ever decoded audio long enough to reach it.
    @Test func twoMinutesOfAudioDecodesAndLeavesTheProcessAlive() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }
        let long = try TemporaryWAV(pcm: RealAudioFixture().tiledPayload(seconds: 120))
        defer { long.remove() }

        let session = try Sidecar.run(
            lines: [
                transcribeRequest(id: "long", audio: long.meta, durationMs: 120_000),
                request("health", id: "after"),
            ],
            environment: ["VOICEOUR_ASR_BACKEND": "parakeet", "VOICEOUR_PRELOAD": "1"],
            timeout: 900
        )

        // Health is answered by the reader thread while the decode runs, so it legitimately
        // arrives first. The promise is one terminal per request, not an ordering across them.
        #expect(Set(session.types) == ["hello", "result", "health"])
        #expect(session.types.filter { $0 == "result" }.count == 1)
        let result = try #require(session.object(type: "result"))
        let transcript = try #require(result["transcript"] as? [String: Any])
        #expect((transcript["text"] as? String)?.lowercased().contains("hello") == true)
    }

    /// Cancel must reach a running decode, and the answer must be `cancelled` rather than the
    /// `inference_failed` that parakeet.cpp's abort callback used to be reported as.
    @Test func cancellingATwoMinuteDecodeAnswersCancelledQuickly() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }
        let long = try TemporaryWAV(pcm: RealAudioFixture().tiledPayload(seconds: 120))
        defer { long.remove() }

        let session = try Sidecar.run(
            lines: [
                transcribeRequest(id: "long", audio: long.meta, durationMs: 120_000),
                request("cancel", id: "long"),
            ],
            environment: ["VOICEOUR_ASR_BACKEND": "parakeet", "VOICEOUR_PRELOAD": "1"],
            timeout: 900,
            pauses: [1: 0.1]
        )

        #expect(session.types == ["hello", "cancelled"])
        let latency = try #require(session.lastOutputAt).timeIntervalSince(session.firstWriteAt)
        FileHandle.standardError.write(Data("cancel latency: \(Int(latency * 1000)) ms\n".utf8))
        #expect(latency < 5)
    }

    /// The idle unload, end to end in one process: transcribe, wait past the deadline, watch
    /// `model_loaded` go false, then transcribe again and still get the right words.
    @Test func anIdleModelUnloadsAndTheNextTranscribeReloadsIt() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_PARAKEET_INTEGRATION"] != nil else { return }
        let audio = try RealAudioFixture()
        // The timer ticks once a minute, so the observable deadline is the tick, not the 2 s.
        var lines = [transcribeRequest(id: "t1", audio: audio.meta)]
        var pauses: [Int: TimeInterval] = [:]
        for probe in 0..<9 {
            lines.append(request("health", id: "h\(probe)"))
            pauses[lines.count - 1] = 10
        }
        lines.append(transcribeRequest(id: "t2", audio: audio.meta))

        let session = try Sidecar.run(
            lines: lines,
            environment: [
                "VOICEOUR_ASR_BACKEND": "parakeet",
                "VOICEOUR_PRELOAD": "1",
                "VOICEOUR_IDLE_UNLOAD_MS": "2000",
            ],
            timeout: 900,
            pauses: pauses
        )

        let healths = session.objects.filter { $0["type"] as? String == "health" }
        #expect(healths.contains { $0["model_loaded"] as? Bool == false }, "the model must unload while idle")
        let results = session.objects.filter { $0["type"] as? String == "result" }
        #expect(results.count == 2)
        for result in results {
            let transcript = try #require(result["transcript"] as? [String: Any])
            #expect((transcript["text"] as? String)?.lowercased().contains("hello world") == true)
        }
    }

    // MARK: - Request builders

    private func request(_ type: String, id: String) -> String {
        #"{"type":"\#(type)","protocol_version":1,"request_id":"\#(id)"}"#
    }

    private func transcribeRequest(id: String, audio: AudioFixture, durationMs: Int = 321) -> String {
        """
        {"type":"transcribe","protocol_version":1,"request_id":"\(id)",\
        "audio":{"path":"\(audio.url.path)","format":"wav","sample_rate_hz":16000,\
        "channels":1,"duration_ms":\(durationMs),"byte_count":\(audio.byteCount)},"timeout_ms":30000}
        """
    }

    private func partialRequest(id: String, pcm: AudioFixture) -> String {
        """
        {"type":"transcribe_partial","protocol_version":1,"request_id":"\(id)",\
        "audio":{"path":"\(pcm.url.path)","format":"pcm_s16le","sample_rate_hz":16000,\
        "channels":1,"duration_ms":\(pcm.byteCount / 32),"byte_count":\(pcm.byteCount)},"timeout_ms":5000}
        """
    }
}

/// What a transcribe request needs to name a WAV on disk.
private struct AudioFixture {
    let url: URL
    let byteCount: Int
}

/// The committed spoken fixture, for the tests that need a real transcript rather than a
/// synthetic one. Not temporary: it lives in the repository and must not be removed.
private struct RealAudioFixture {
    let meta: AudioFixture

    init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/audio/hello_16k_mono.wav")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        meta = AudioFixture(url: url, byteCount: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// The fixture's `data` chunk, located rather than assumed at offset 44: a WAV writer is
    /// free to put other chunks first, and a wrong offset would silently shift every sample.
    func pcmPayload() throws -> Data {
        let data = try Data(contentsOf: meta.url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            let body = offset + 8
            if id == "data" { return data.subdata(in: body..<min(body + size, data.count)) }
            offset = body + size + (size % 2)
        }
        throw SidecarTestError.timedOut
    }

    /// The fixture repeated until it covers at least `seconds` of 16 kHz mono audio.
    func tiledPayload(seconds: Int) throws -> Data {
        let one = try pcmPayload()
        let wanted = seconds * 16_000 * 2
        var tiled = Data(capacity: wanted + one.count)
        while tiled.count < wanted { tiled.append(one) }
        return tiled
    }
}

/// A headerless raw s16le buffer, the format the recorder's live preview tee writes.
private struct TemporaryPCM {
    let url: URL
    let byteCount: Int

    var meta: AudioFixture { AudioFixture(url: url, byteCount: byteCount) }

    init(bytes: Data) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-process-tests-" + UUID().uuidString)
            .appendingPathExtension("pcm")
        try bytes.write(to: url)
        byteCount = bytes.count
    }

    init(sampleCount: Int) throws {
        try self.init(bytes: Data(count: sampleCount * 2))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A 16 kHz mono 16-bit WAV, the one format the sidecar accepts.
private struct TemporaryWAV {
    let url: URL
    let byteCount: Int

    var meta: AudioFixture { AudioFixture(url: url, byteCount: byteCount) }

    init(sampleCount: Int = 1600) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payloadBytes = UInt32(sampleCount * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + payloadBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(payloadBytes)
        data.append(Data(count: sampleCount * 2))

        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-process-tests-" + UUID().uuidString)
            .appendingPathExtension("wav")
        try data.write(to: url)
        byteCount = data.count
    }

    /// A WAV wrapping an existing raw s16le payload, for audio too long to synthesize inline.
    init(pcm: Data) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payloadBytes = UInt32(pcm.count)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + payloadBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(payloadBytes)
        data.append(pcm)

        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-process-tests-" + UUID().uuidString)
            .appendingPathExtension("wav")
        try data.write(to: url)
        byteCount = data.count
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// One `voiceour-asr` process: writes the given lines to stdin, closes it, and parses stdout.
private enum Sidecar {
    struct Session {
        let objects: [[String: Any]]
        let stderrText: String
        /// When the first request line was written, and when the last stdout byte arrived.
        /// Enough to measure a terminal's latency without timestamping every line: the tests
        /// that read these send one request and expect one answer.
        let firstWriteAt: Date
        let lastOutputAt: Date?

        var types: [String] { objects.compactMap { $0["type"] as? String } }

        func object(type: String) -> [String: Any]? {
            objects.first { $0["type"] as? String == type }
        }
    }

    /// `pauses` maps a line index to seconds to wait before writing it, which is how a test
    /// puts a cancel inside a running decode rather than inside the same read.
    static func run(
        lines: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 30,
        pauses: [Int: TimeInterval] = [:]
    ) throws -> Session {
        let process = Process()
        process.executableURL = productsDirectory().appendingPathComponent("voiceour-asr")
        var environmentToUse = ProcessInfo.processInfo.environment
        environmentToUse["VOICEOUR_ASR_BACKEND"] = "fake"
        environmentToUse.removeValue(forKey: "VOICEOUR_PRELOAD")
        environmentToUse.removeValue(forKey: "VOICEOUR_FAKE_DELAY_MS")
        for (key, value) in environment { environmentToUse[key] = value }
        process.environment = environmentToUse

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Read both pipes on background threads: a child that fills either buffer while the
        // parent waits on the other deadlocks, and the sidecar is deliberately loud on stderr.
        let stdoutData = Drain(handle: output.fileHandleForReading)
        let stderrData = Drain(handle: errors.fileHandleForReading)

        let firstWriteAt = Date()
        for (index, line) in lines.enumerated() {
            if let pause = pauses[index] { Thread.sleep(forTimeInterval: pause) }
            try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw SidecarTestError.timedOut
        }
        process.waitUntilExit()

        let objects =
            String(data: stdoutData.wait(), encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            } ?? []

        return Session(
            objects: objects,
            stderrText: String(data: stderrData.wait(), encoding: .utf8) ?? "",
            firstWriteAt: firstWriteAt,
            lastOutputAt: stdoutData.lastChunkAt()
        )
    }

    private final class Drain: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var data = Data()
        private var lastChunk: Date?

        init(handle: FileHandle) {
            Thread.detachNewThread { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    lastChunk = Date()
                }
                semaphore.signal()
            }
        }

        func wait() -> Data {
            semaphore.wait()
            return data
        }

        /// Valid only after `wait()`: the reader thread owns both fields until it signals.
        func lastChunkAt() -> Date? { lastChunk }
    }

    /// The directory SwiftPM built this test bundle into, which also holds `voiceour-asr`.
    private static func productsDirectory() -> URL {
        Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent()
    }
}

private enum SidecarTestError: Error {
    case timedOut
}

private final class TestBundleAnchor {}
