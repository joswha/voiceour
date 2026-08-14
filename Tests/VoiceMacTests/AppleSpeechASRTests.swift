import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Covers Apple Speech ASR availability, batch transcription, and live capture.
///
/// `.serialized` because the live-capture tests each open a capture session on the
/// one physical microphone this machine has. Run in parallel under
/// `VOICEOUR_APPLE_SPEECH_INTEGRATION` they deadlock: the run sat idle for 30
/// minutes with every thread parked in `CFRunLoopRun` and no frame of this code on
/// any stack, waiting on continuations that never resolved. Serialized, the same
/// seven tests finish in 4.7 seconds. The default gate is unaffected either way —
/// without the environment variable the integration tests return immediately.
@Suite("Apple Speech ASR", .serialized)
struct AppleSpeechASRTests {
    @Test func unsupportedASRClientReportsBackendUnavailable() async throws {
        let client = UnsupportedASRClient(backendId: "apple-speech", detail: "Apple Speech backend requires macOS 26")
        let audio = RecordedAudio(
            url: URL(fileURLWithPath: "/tmp/none.wav"),
            meta: ASRAudioMeta(
                path: "/tmp/none.wav", format: "wav", sampleRateHz: 16000, channels: 1, durationMs: 100, byteCount: 10))

        do {
            _ = try await client.transcribe(audio, timeoutMs: 1000)
            Issue.record("transcribe must throw")
        } catch let error as ASRErrorMessage {
            #expect(error.code == .backendUnavailable)
            #expect(error.category == "setup")
            #expect(!error.retryable)
        }

        let health = try await client.health(timeoutMs: 1000)
        #expect(health.backendStatus == .backendUnavailable)
        #expect(!health.ready)
    }

    @Test func appleSpeechASRClientRealIntegration() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let client = AppleSpeechASRClient()
        let health = try await client.health(timeoutMs: 5000)
        guard health.ready else {
            Issue.record("Apple speech assets not installed; run once with network to download")
            return
        }

        let audio = helloFixtureAudio()
        let started = Date()
        let result = try await client.transcribe(audio, timeoutMs: 15_000)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("apple speech integration: \(ms)ms -> \(result.transcript.text)")

        #expect(result.backendId == "apple-speech")
        #expect(result.transcript.text.lowercased().contains("hello"))
        #expect(ms < 5000)
    }

    @Test func appleSpeechEngineForeignFileUsesBatchPath() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let engine = AppleSpeechDictationEngine()
        let audio = helloFixtureAudio()
        let fixture = audio.url
        let result = try await engine.transcribe(audio, timeoutMs: 15_000)
        #expect(result.backendId == "apple-speech")
        #expect(result.transcript.text.lowercased().contains("hello"))
        // The batch path must never delete a caller-owned file.
        #expect(FileManager.default.fileExists(atPath: fixture.path))
    }

    @Test func appleSpeechASRClientEmitsSegmentWordEvidence() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let client = AppleSpeechASRClient()
        let health = try await client.health(timeoutMs: 5000)
        guard health.ready else {
            Issue.record("Apple speech assets not installed; run once with network to download")
            return
        }

        let audio = helloFixtureAudio()
        let result = try await client.transcribe(audio, timeoutMs: 15_000)

        // The fixture reliably transcribes "hello", so requesting audio-time-range
        // and confidence attributes must yield real segment/word evidence.
        let segments = try #require(result.transcript.segments, "attributeOptions must yield segment evidence")
        #expect(!segments.isEmpty)
        let words = segments.flatMap { $0.words ?? [] }
        #expect(!words.isEmpty)
        for word in words {
            #expect(!word.text.isEmpty)
            #expect(word.startMs >= 0)
            #expect(word.endMs >= word.startMs)
            if let confidence = word.confidence {
                #expect(confidence >= 0)
            }
        }
        // Apple exposes no documented confidence scale: the aggregate is present
        // but the mode is never a fabricated greedy/beam label.
        #expect(result.transcript.confidenceMode != .greedyEntropy)
        #expect(result.transcript.confidenceMode != .beamLogprob)
        if result.transcript.confidence != nil {
            #expect(result.transcript.confidenceMode == ASRConfidenceMode.none)
        }
    }

    @Test func appleSpeechEngineStreamedResultCarriesEvidence() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let engine = AppleSpeechDictationEngine()
        await engine.warmUp()
        try engine.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let audio = try await engine.stop()

        // Streamed capture owns the WAV, so this exercises the live
        // StreamingSession.collectTask reduction (not the batch fallback).
        let result = try await engine.transcribe(audio, timeoutMs: 15_000)
        #expect(result.backendId == "apple-speech")
        // Ambient audio may transcribe to nothing; the contract is that whenever
        // text is produced its evidence is well-formed and honestly labeled.
        if !result.transcript.text.isEmpty, let segments = result.transcript.segments {
            #expect(segments.contains { !($0.words ?? []).isEmpty })
            for word in segments.flatMap({ $0.words ?? [] }) {
                #expect(word.endMs >= word.startMs)
            }
            #expect(result.transcript.confidenceMode != .greedyEntropy)
            #expect(result.transcript.confidenceMode != .beamLogprob)
        }

        try? FileManager.default.removeItem(at: audio.url)
    }

    @Test func appleSpeechEngineStreamsLiveCaptureLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let engine = AppleSpeechDictationEngine()
        await engine.warmUp()
        try engine.start()
        #expect(engine.currentInputLevel() != nil)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let audio = try await engine.stop()
        #expect(FileManager.default.fileExists(atPath: audio.url.path))
        #expect(audio.meta.sampleRateHz == 16000)
        #expect(audio.meta.byteCount > 0)

        let started = Date()
        let result = try await engine.transcribe(audio, timeoutMs: 15_000)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("apple streaming integration: stop->result \(ms)ms text=\(result.transcript.text)")
        #expect(result.backendId == "apple-speech")
        // Ambient audio may legitimately transcribe to nothing; the contract is
        // lifecycle + latency, not content.
        #expect(ms < 5000)

        try? FileManager.default.removeItem(at: audio.url)
    }

    @Test func appleSpeechEngineDiscardIsIdempotent() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_APPLE_SPEECH_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }

        let engine = AppleSpeechDictationEngine()
        try engine.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await engine.discardRecording()
        await engine.discardRecording()
        #expect(engine.currentInputLevel() == nil)
        // A fresh session must start cleanly after a discard.
        try engine.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await engine.discardRecording()
    }

    private func helloFixtureAudio() -> RecordedAudio {
        let fixture = URL(fileURLWithPath: "fixtures/audio/hello_16k_mono.wav")
        return RecordedAudio(
            url: fixture,
            meta: ASRAudioMeta(
                path: fixture.path, format: "wav", sampleRateHz: 16000, channels: 1, durationMs: 3242,
                byteCount: 103_760)
        )
    }

}
