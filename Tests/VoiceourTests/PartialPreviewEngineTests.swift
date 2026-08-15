import Foundation
import Testing
import VoiceCore

@testable import Voiceour

/// A recorder that offers a fixed amount of partial audio and nothing else.
private struct StubPartialRecorder: AudioRecording, PartialAudioProviding {
    let sampleCount: Int?

    func start() throws {}
    func stop() async throws -> RecordedAudio {
        RecordedAudio(
            url: URL(fileURLWithPath: "/tmp/partial-preview-tests.wav"),
            meta: ASRAudioMeta(
                path: "/tmp/partial-preview-tests.wav",
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 0,
                byteCount: 0
            )
        )
    }

    func partialAudio() -> PartialAudioSnapshot? {
        guard let sampleCount else { return nil }
        return PartialAudioSnapshot(
            pcmURL: URL(fileURLWithPath: "/tmp/partial-preview-tests.pcm"),
            sampleCount: sampleCount
        )
    }
}

/// A recorder with no partial path at all, which is every fake and Apple-Speech fixture.
private struct StubPlainRecorder: AudioRecording {
    func start() throws {}
    func stop() async throws -> RecordedAudio {
        RecordedAudio(
            url: URL(fileURLWithPath: "/tmp/partial-preview-tests.wav"),
            meta: ASRAudioMeta(
                path: "/tmp/partial-preview-tests.wav",
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 0,
                byteCount: 0
            )
        )
    }
}

private actor PartialCallLog {
    private(set) var calls = 0
    func record() { calls += 1 }
}

/// Answers previews, counting how many were asked for.
private struct StubPartialASR: ASRClienting {
    let log: PartialCallLog
    let text: String
    let failing: Bool

    func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
        throw ASRErrorMessage(code: .internalError, requestId: nil, detail: "not used")
    }

    func health(timeoutMs: Int) async throws -> ASRBackendHealth {
        ASRBackendHealth(backendId: "stub", backendStatus: .ready, ready: true, modelLoaded: true, cacheOk: true)
    }

    func transcribePartial(pcmURL: URL, sampleCount: Int, timeoutMs: Int) async throws -> ASRResult {
        await log.record()
        if failing {
            throw ASRErrorMessage(code: .backendUnavailable, requestId: nil, detail: "no partials here")
        }
        return ASRResult(
            requestId: "partial",
            backendId: "stub",
            modelId: "stub",
            modelRevision: "dev",
            transcript: ASRTranscript(text: text, language: "en", segments: nil, confidence: nil, confidenceMode: nil),
            timingsMs: ASRTimings(load: 0, inference: 0, total: 0)
        )
    }
}

@Suite("PartialPreviewEngineTests")
struct PartialPreviewEngineTests {
    // MARK: - Cadence

    @Test func theFirstPreviewWaitsForAnUtteranceWorthShowing() {
        #expect(!PartialPreviewEngine.shouldSnapshot(sampleCount: 23_999, lastSampleCount: 0))
        #expect(PartialPreviewEngine.shouldSnapshot(sampleCount: 24_000, lastSampleCount: 0))
    }

    @Test func laterPreviewsNeedASecondOfNewAudio() {
        // 1 s of new audio short of the stride: the 40 ms poll must not re-decode the same
        // buffer forty times between two words.
        #expect(!PartialPreviewEngine.shouldSnapshot(sampleCount: 39_999, lastSampleCount: 24_000))
        #expect(PartialPreviewEngine.shouldSnapshot(sampleCount: 40_000, lastSampleCount: 24_000))
    }

    // MARK: - Adoption predicate

    @Test func adoptionNeedsASnapshotTakenAtOrAfterSilenceBegan() {
        let silenceStartedAt = Date(timeIntervalSince1970: 1_000)

        #expect(!partialAdoptionIsSound(snapshotTakenAt: nil, silenceStartedAt: silenceStartedAt))
        #expect(
            !partialAdoptionIsSound(
                snapshotTakenAt: silenceStartedAt.addingTimeInterval(-0.001),
                silenceStartedAt: silenceStartedAt
            )
        )
        #expect(partialAdoptionIsSound(snapshotTakenAt: silenceStartedAt, silenceStartedAt: silenceStartedAt))
        #expect(
            partialAdoptionIsSound(
                snapshotTakenAt: silenceStartedAt.addingTimeInterval(2),
                silenceStartedAt: silenceStartedAt
            )
        )
    }

    // MARK: - Tick behaviour

    @MainActor
    @Test func aRecorderWithoutPartialAudioIsNeverAsked() async {
        let log = PartialCallLog()
        let engine = PartialPreviewEngine()

        engine.tick(
            recorder: StubPlainRecorder(),
            asr: StubPartialASR(log: log, text: "unused", failing: false),
            now: Date()
        ) { _ in }

        #expect(engine.inFlight == nil)
        #expect(await log.calls == 0)
    }

    @MainActor
    @Test func aPreviewPublishesItsTextAndAdvancesTheSnapshot() async {
        let log = PartialCallLog()
        let engine = PartialPreviewEngine()
        let now = Date(timeIntervalSince1970: 500)
        var published: [String] = []

        engine.tick(
            recorder: StubPartialRecorder(sampleCount: 24_000),
            asr: StubPartialASR(log: log, text: "hello there", failing: false),
            now: now
        ) { published.append($0) }
        await engine.inFlight?.value

        #expect(published == ["hello there"])
        #expect(engine.lastSnapshotSampleCount == 24_000)
        #expect(engine.lastSnapshotTakenAt == now)
        #expect(engine.lastResult?.transcript.text == "hello there")
        #expect(await log.calls == 1)
    }

    @MainActor
    @Test func aSecondTickWithoutNewAudioAsksForNothing() async {
        let log = PartialCallLog()
        let engine = PartialPreviewEngine()
        let asr = StubPartialASR(log: log, text: "hello there", failing: false)
        let recorder = StubPartialRecorder(sampleCount: 24_000)

        engine.tick(recorder: recorder, asr: asr, now: Date()) { _ in }
        await engine.inFlight?.value
        engine.tick(recorder: recorder, asr: asr, now: Date()) { _ in }
        await engine.inFlight?.value

        #expect(await log.calls == 1)
    }

    /// The whole opt-in mechanism: a backend without a partial path throws once, and the
    /// session stops asking rather than failing forty times a second.
    @MainActor
    @Test func oneFailureDisablesPreviewsForTheSession() async {
        let log = PartialCallLog()
        let engine = PartialPreviewEngine()
        let asr = StubPartialASR(log: log, text: "unused", failing: true)
        var published: [String] = []

        engine.tick(recorder: StubPartialRecorder(sampleCount: 24_000), asr: asr, now: Date()) {
            published.append($0)
        }
        await engine.inFlight?.value
        engine.tick(recorder: StubPartialRecorder(sampleCount: 80_000), asr: asr, now: Date()) {
            published.append($0)
        }
        await engine.inFlight?.value

        #expect(published.isEmpty)
        #expect(await log.calls == 1)
    }

    @MainActor
    @Test func resetClearsEverythingTheNextSessionMustNotInherit() async {
        let log = PartialCallLog()
        let engine = PartialPreviewEngine()

        engine.tick(
            recorder: StubPartialRecorder(sampleCount: 24_000),
            asr: StubPartialASR(log: log, text: "hello there", failing: false),
            now: Date()
        ) { _ in }
        await engine.inFlight?.value
        engine.cancelAndReset()

        #expect(engine.lastResult == nil)
        #expect(engine.lastSnapshotTakenAt == nil)
        #expect(engine.lastSnapshotSampleCount == 0)
    }
}
