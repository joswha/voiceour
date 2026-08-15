import Foundation
import VoiceCore

/// Whether a partial may be adopted as the final transcript when auto-stop proves the tail was
/// silence.
///
/// **Off, and measured off.** The argument for adoption was that every sample after the
/// snapshot had already been shown to be below the silence threshold, so re-decoding could not
/// change the words. That reasoning ignores that the encoder is not causal over the utterance:
/// trailing frames change its representation of earlier ones, and the decoder's punctuation,
/// casing and word-joining shift with them.
///
/// Measured 2026-08-15 on 32 LibriSpeech rows through the shipped sidecar, comparing a decode of
/// the audio up to silence onset against a decode of the same audio plus the 2.5 s auto-stop
/// dwell: **25 of 32 transcripts differ verbatim** with a digitally silent tail and 21 of 32
/// with a sub-threshold noise tail. Scored with the repo's own jiwer + whisper-normalizer, the
/// normalized divergence is **0.493% U-WER** (quiet) and **0.583%** (noisy) — against a pinned
/// model at 2.81% and a regression gate of 0.35 pp, so adopting spends more than the entire gate
/// budget to save ~347 ms at the median. Examples: `here, and however` → `here. And however`,
/// `new born` → `newborn`, `ou best, When I was certain` → `you best when I was certain`.
///
/// The preview itself is unaffected and stays on. Re-enabling this requires a measurement that
/// clears the gate, not an argument.
let partialAdoptionEnabled = false

/// Whether the last partial's snapshot covers everything but the trailing silence.
///
/// The timing rule alone, independent of whether adoption is switched on: the snapshot was taken
/// at `snapshotTakenAt`, and auto-stop fired because every sample from `silenceStartedAt`
/// onwards stayed below the threshold for the full dwell.
func partialSnapshotCoversSpeech(snapshotTakenAt: Date?, silenceStartedAt: Date) -> Bool {
    guard let snapshotTakenAt else { return false }
    return snapshotTakenAt >= silenceStartedAt
}

/// Whether the stop path may use the last preview instead of decoding the WAV.
func partialAdoptionIsSound(snapshotTakenAt: Date?, silenceStartedAt: Date) -> Bool {
    partialAdoptionEnabled
        && partialSnapshotCoversSpeech(snapshotTakenAt: snapshotTakenAt, silenceStartedAt: silenceStartedAt)
}

/// Drives preview-only re-decodes of the growing capture buffer.
///
/// It never inserts and never mutates the session's transcript. The one place its output can
/// become the final text is `TranscriptProcessingPipeline`, and only under
/// `partialAdoptionIsSound`.
@MainActor
final class PartialPreviewEngine {
    /// First preview at 1.5 s of audio: below that the model has too little to say.
    nonisolated static let firstSnapshotSamples = 24_000
    /// At least a second of new audio between previews. The decode is a whole re-decode of the
    /// buffer, so cadence is the only thing keeping its cost bounded.
    nonisolated static let snapshotStrideSamples = 16_000
    nonisolated static let timeoutMs = 5_000

    private(set) var lastResult: ASRResult?
    private(set) var lastSnapshotSampleCount = 0
    private(set) var lastSnapshotTakenAt: Date?
    private(set) var inFlight: Task<Void, Never>?
    /// Set by the first failure of the session. Backends without a partial path throw once and
    /// are then left alone, which is the entire opt-in mechanism.
    private(set) var disabledForSession = false

    /// Called from the recorder's existing metering poll. Cheap and total: it decides whether
    /// this tick has earned a preview, and starts at most one decode.
    func tick(
        recorder: any AudioRecording,
        asr: any ASRClienting,
        now: Date,
        publish: @escaping (String) -> Void
    ) {
        guard !disabledForSession, inFlight == nil else { return }
        guard let provider = recorder as? PartialAudioProviding else { return }
        guard let snapshot = provider.partialAudio() else { return }
        guard Self.shouldSnapshot(sampleCount: snapshot.sampleCount, lastSampleCount: lastSnapshotSampleCount)
        else { return }

        let pcmURL = snapshot.pcmURL
        let sampleCount = snapshot.sampleCount
        inFlight = Task { [weak self] in
            do {
                let result = try await asr.transcribePartial(
                    pcmURL: pcmURL,
                    sampleCount: sampleCount,
                    timeoutMs: Self.timeoutMs
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.inFlight = nil
                    let text = result.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    self.lastResult = result
                    self.lastSnapshotSampleCount = sampleCount
                    self.lastSnapshotTakenAt = now
                    publish(text)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.inFlight = nil
                    self.disabledForSession = true
                }
            }
        }
    }

    /// The cadence rule, as a pure function so it can be tested without a recorder.
    nonisolated static func shouldSnapshot(sampleCount: Int, lastSampleCount: Int) -> Bool {
        sampleCount >= max(firstSnapshotSamples, lastSampleCount + snapshotStrideSamples)
    }

    func cancelAndReset() {
        inFlight?.cancel()
        inFlight = nil
        lastResult = nil
        lastSnapshotSampleCount = 0
        lastSnapshotTakenAt = nil
        disabledForSession = false
    }

    /// Cancels the decode in flight without discarding what it already produced: the stop path
    /// wants the decode queue free for the final, and the last good partial still adoptable.
    func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }
}
