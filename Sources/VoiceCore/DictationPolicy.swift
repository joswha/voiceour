import Foundation

public enum DictationPolicy {}

extension DictationPolicy {
    public static func shouldSkipTranscript(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Floor on `CaptureTelemetry.snrDB` below which a capture is treated as
    /// containing no speech.
    ///
    /// Measured 2026-08-14 with the real `CaptureTelemetryAnalyzer` statistics.
    /// `snrDB` is the gap between the 90th and 10th percentile of 10 ms buffer RMS,
    /// so flat noise collapses toward zero while speech — however quiet — keeps a
    /// wide gap because it alternates with its own pauses:
    ///
    /// | capture | snrDB |
    /// | --- | ---: |
    /// | 8 s of digital zeros | 0.0 |
    /// | 8 s of quiet dither | 0.8 |
    /// | 8 s of hiss | 0.8 |
    /// | nine real speech clips | 20.4 – 52.8 |
    ///
    /// 6 dB sits 7.5x above the loudest noise sample and 3.4x below the quietest
    /// speech sample. Peak level is deliberately NOT used: three of those real
    /// clips peak at −44 to −49 dBFS, quieter than the hiss, so a peak gate would
    /// discard genuine quiet speech. `activeSpeechRatio` is likewise unusable —
    /// it reads 0.000 for those same clips because they never cross −40 dBFS.
    public static let minimumCaptureSNRDB = 6.0

    /// Whether a capture carries no speech and its transcript must be discarded.
    ///
    /// This exists because ASR models invent text from noise rather than returning
    /// nothing. Measured on this machine, 8 s of quiet dither through the shipping
    /// default backend produced `"Esta mañana está en su mayor mayor mayor."` —
    /// fabricated text in a language the user was not speaking, which
    /// `shouldSkipTranscript` cannot catch because it is not whitespace. A
    /// dictation app pastes that into the user's document.
    ///
    /// Fails open in both directions that matter. Absent telemetry proceeds, because
    /// suppressing a real dictation on no evidence is worse than passing noise
    /// through. Synthetic capture proceeds, because the fake recorder writes literal
    /// silence and its synthesised transcript is its contract, not a defect.
    public static func capturedSpeechIsAbsent(
        telemetry: CaptureTelemetry?,
        isSynthetic: Bool
    ) -> Bool {
        guard !isSynthetic, let telemetry else { return false }
        return telemetry.snrDB < minimumCaptureSNRDB
    }
}
