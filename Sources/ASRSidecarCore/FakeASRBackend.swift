import Foundation
import VoiceCore

/// Deterministic backend used by tests, smoke runs and fake development.
///
/// It needs no model, no microphone and no network, which is why it is the registry default.
/// Its transcript text is asserted verbatim by Swift tests, the bench harness and
/// `scripts/run_dev.sh --self-test`, so the strings below are a contract, not a placeholder.
public final class FakeASRBackend: SidecarBackend {
    public let backendId = "fake"

    /// `VOICEOUR_FAKE_DELAY_MS` stretches a fake transcribe so cancellation is observable.
    public let delayMs: Int

    public init(delayMs: Int) {
        self.delayMs = delayMs
    }

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(delayMs: Int(environment["VOICEOUR_FAKE_DELAY_MS"] ?? "0") ?? 0)
    }

    public func startupStatus() -> BackendStatus { .ready }

    public func health() -> ASRBackendHealth {
        ASRBackendHealth(
            backendId: backendId,
            backendStatus: .ready,
            ready: true,
            modelLoaded: true,
            cacheOk: true
        )
    }

    public func transcribe(
        _ request: ASRTranscribeRequest,
        isCancelled: @escaping () -> Bool
    ) -> SidecarTerminal {
        if delayMs > 0 {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(delayMs) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if isCancelled() { return .cancelled }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        if isCancelled() { return .cancelled }
        if request.timeoutMs <= 0 {
            return .failure(code: .timeout, detail: "fake timeout", fatal: false)
        }

        let text = "fake transcript duration_ms=\(request.audio.durationMs)"
        let tokens = text.split(separator: " ").map(String.init)
        let durationMs = max(request.audio.durationMs, tokens.count)
        let per = durationMs / tokens.count
        let words = tokens.enumerated().map { index, token in
            ASRWord(
                text: token,
                startMs: index * per,
                endMs: index + 1 < tokens.count ? (index + 1) * per : durationMs,
                confidence: 1.0
            )
        }
        let transcript = ASRTranscript(
            text: text,
            language: "en",
            segments: [ASRSegment(startMs: 0, endMs: durationMs, text: text, words: words)],
            confidence: 1.0,
            confidenceMode: ASRConfidenceMode.none
        )
        return .result(
            transcript: transcript,
            backendId: backendId,
            modelId: "fake",
            modelRevision: "dev",
            timings: ASRTimings(load: 0, inference: 0, total: 0)
        )
    }

    /// Answers with the sample count it was handed, so a process test can assert that the
    /// request's byte accounting survived the wire without owning any audio.
    public func transcribePartial(
        _ request: ASRTranscribeRequest,
        isCancelled: @escaping () -> Bool
    ) -> SidecarTerminal {
        if isCancelled() { return .cancelled }
        return .result(
            transcript: ASRTranscript(
                text: "fake partial samples=\(request.audio.byteCount / 2)",
                language: "en",
                segments: nil,
                confidence: nil,
                confidenceMode: nil
            ),
            backendId: backendId,
            modelId: "fake",
            modelRevision: "dev",
            timings: ASRTimings(load: 0, inference: 0, total: 0)
        )
    }
}
