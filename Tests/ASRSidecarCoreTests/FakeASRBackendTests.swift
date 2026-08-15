import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("FakeASRBackendTests")
struct FakeASRBackendTests {
    private func request(durationMs: Int = 1234, timeoutMs: Int = 30000) -> ASRTranscribeRequest {
        ASRTranscribeRequest(
            requestId: "r1",
            audio: ASRAudioMeta(
                path: "/tmp/does-not-need-to-exist.wav",
                format: "wav",
                sampleRateHz: 16000,
                channels: 1,
                durationMs: durationMs,
                byteCount: 0
            ),
            expectedModel: nil,
            timeoutMs: timeoutMs
        )
    }

    private func result(_ terminal: SidecarTerminal) -> (ASRTranscript, ASRTimings)? {
        guard case .result(let transcript, _, _, _, let timings) = terminal else { return nil }
        return (transcript, timings)
    }

    @Test func transcriptTextAndWordSpansAreTheDocumentedContract() throws {
        let terminal = FakeASRBackend(delayMs: 0).transcribe(request(durationMs: 321), isCancelled: { false })
        let (transcript, timings) = try #require(result(terminal))

        #expect(transcript.text == "fake transcript duration_ms=321")
        #expect(transcript.language == "en")
        #expect(transcript.confidence == 1.0)
        #expect(transcript.confidenceMode == ASRConfidenceMode.none)
        #expect(timings == ASRTimings(load: 0, inference: 0, total: 0))

        let segments = try #require(transcript.segments)
        #expect(segments.count == 1)
        #expect(segments[0].startMs == 0)
        #expect(segments[0].endMs == 321)

        let words = try #require(segments[0].words)
        #expect(words.map(\.text) == ["fake", "transcript", "duration_ms=321"])
        // per = 321 / 3 = 107; the last word is stretched to the declared duration.
        #expect(words.map(\.startMs) == [0, 107, 214])
        #expect(words.map(\.endMs) == [107, 214, 321])
        #expect(words.allSatisfy { $0.confidence == 1.0 })
    }

    @Test func aDurationShorterThanTheWordCountStillProducesMonotonicSpans() throws {
        let terminal = FakeASRBackend(delayMs: 0).transcribe(request(durationMs: 0), isCancelled: { false })
        let (transcript, _) = try #require(result(terminal))
        let words = try #require(transcript.segments?.first?.words)

        #expect(words.map(\.startMs) == [0, 1, 2])
        #expect(words.map(\.endMs) == [1, 2, 3])
    }

    @Test func aNonPositiveTimeoutIsReportedAsATimeout() {
        let terminal = FakeASRBackend(delayMs: 0).transcribe(request(timeoutMs: 0), isCancelled: { false })

        guard case .failure(let code, let detail, _) = terminal else {
            Issue.record("expected a failure, got \(terminal)")
            return
        }
        #expect(code == .timeout)
        #expect(detail == "fake timeout")
    }

    @Test func cancellationIsObservedDuringTheDelayLoop() {
        let started = Date()
        let backend = FakeASRBackend(delayMs: 5000)

        let terminal = backend.transcribe(request(), isCancelled: { Date().timeIntervalSince(started) > 0.05 })

        guard case .cancelled = terminal else {
            Issue.record("expected cancellation, got \(terminal)")
            return
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func aPreCancelledRequestNeverProducesATranscript() {
        let terminal = FakeASRBackend(delayMs: 0).transcribe(request(), isCancelled: { true })

        guard case .cancelled = terminal else {
            Issue.record("expected cancellation, got \(terminal)")
            return
        }
    }

    @Test func delayComesFromTheEnvironment() {
        #expect(FakeASRBackend(environment: ["VOICEOUR_FAKE_DELAY_MS": "250"]).delayMs == 250)
        #expect(FakeASRBackend(environment: [:]).delayMs == 0)
        #expect(FakeASRBackend(environment: ["VOICEOUR_FAKE_DELAY_MS": "nonsense"]).delayMs == 0)
    }

    @Test func healthIsAlwaysReady() {
        let health = FakeASRBackend(delayMs: 0).health()

        #expect(health.backendId == "fake")
        #expect(health.ready)
        #expect(health.modelLoaded)
        #expect(health.cacheOk)
    }
}
