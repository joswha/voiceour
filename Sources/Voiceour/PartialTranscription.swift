import Foundation
import VoiceCore

/// Whether a partial may be adopted as the final transcript when auto-stop proves the tail was
/// silence.
///
/// One constant, deliberately: the preview and the adoption are separable. If live use ever
/// shows adopted text drifting from a batch decode of the whole file, setting this false keeps
/// the preview working and reverts only the post-stop saving.
let partialAdoptionEnabled = true

/// Whether the last partial's snapshot is old enough to stand in for the final transcript.
///
/// The snapshot was taken at `snapshotTakenAt`; auto-stop fired because every sample from
/// `silenceStartedAt` onwards stayed below the silence threshold for the full dwell. If the
/// snapshot was taken at or after that moment, every sample the partial did not see was already
/// known to be silence — by the identical criterion that authorized stopping.
func partialAdoptionIsSound(snapshotTakenAt: Date?, silenceStartedAt: Date) -> Bool {
    guard partialAdoptionEnabled, let snapshotTakenAt else { return false }
    return snapshotTakenAt >= silenceStartedAt
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
