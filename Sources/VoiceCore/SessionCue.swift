import Foundation

/// The two boundaries of listening, and the only two sounds the app makes.
///
/// Synthesized rather than shipped: no target declares `resources:`, so an asset
/// would add resource handling to `Package.swift` and to `scripts/bundle_app.sh`
/// for two tones whose parameters fit in a table.
public enum SessionCue: String, Sendable, CaseIterable {
    /// Capture has opened: a rising glide.
    case listeningStarted
    /// Capture has closed: the same glide, mirrored in pitch.
    case listeningEnded

    /// Length of every cue. Matches `VoiceourMotion.quickDuration` (0.14 s) so a
    /// cue finishes just before the recording island's 0.18 s entrance settles.
    /// `VoiceCore` cannot import the token itself; keep the two in step.
    public static let duration: TimeInterval = 0.14

    public static let durationNanoseconds = UInt64(duration * 1_000_000_000)

    public var voice: SessionCueVoice {
        switch self {
        case .listeningStarted:
            SessionCueVoice(startHz: 620, endHz: 1240, overshoot: 0.05)
        case .listeningEnded:
            SessionCueVoice(startHz: 1240, endHz: 620, overshoot: -0.05)
        }
    }
}

/// One cue's synthesis parameters: an exponential pitch glide with a small
/// overshoot that settles onto the end tone, a quiet second harmonic for body,
/// and a raised-cosine envelope at both edges so neither edge clicks.
///
/// The falling cue mirrors the pitch contour and keeps a forward envelope. A
/// time-reversed cue — slow swell, abrupt cut — reads as a backwards sound.
public struct SessionCueVoice: Equatable, Sendable {
    public var durationSeconds: TimeInterval
    public var startHz: Double
    public var endHz: Double
    /// Fraction past `endHz` the pitch reaches at `overshootAt` before settling
    /// back onto `endHz`. Negative for a falling cue, which undershoots.
    public var overshoot: Double
    public var overshootAt: Double
    /// Second-harmonic amplitude relative to the fundamental. 0.18 is −15 dB.
    public var secondHarmonic: Double
    public var attackSeconds: TimeInterval
    public var releaseSeconds: TimeInterval
    /// Ceiling on the summed partials, so `peak` is the real sample ceiling.
    public var peak: Double

    public init(
        durationSeconds: TimeInterval = SessionCue.duration,
        startHz: Double,
        endHz: Double,
        overshoot: Double,
        overshootAt: Double = 0.8,
        secondHarmonic: Double = 0.18,
        attackSeconds: TimeInterval = 0.007,
        releaseSeconds: TimeInterval = 0.055,
        peak: Double = 0.16
    ) {
        self.durationSeconds = durationSeconds
        self.startHz = startHz
        self.endHz = endHz
        self.overshoot = overshoot
        self.overshootAt = overshootAt
        self.secondHarmonic = secondHarmonic
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        self.peak = peak
    }
}

/// Deterministic cue synthesis. Same parameters in, same samples out, so the
/// sound design is a test subject rather than a binary nobody can diff.
public enum SessionCueSynth {
    public static let sampleRate: Double = 48_000

    public static func samples(for voice: SessionCueVoice, sampleRate: Double = sampleRate) -> [Float] {
        let count = Int((voice.durationSeconds * sampleRate).rounded())
        guard count > 0, sampleRate > 0 else { return [] }
        // Normalizing by the summed partials keeps `peak` the true ceiling
        // instead of a ceiling the second harmonic can exceed.
        let normalize = voice.peak / (1 + voice.secondHarmonic)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let progress = Double(index) / Double(count)
            var value = sin(phase)
            if voice.secondHarmonic != 0 {
                value += voice.secondHarmonic * sin(2 * phase)
            }
            let shaped = value * envelope(at: index, count: count, voice: voice, sampleRate: sampleRate)
            samples[index] = Float(shaped * normalize)
            phase += 2 * .pi * frequency(at: progress, voice: voice) / sampleRate
        }
        return samples
    }

    /// Instantaneous frequency. Exponential in pitch, so the glide reads as one
    /// musical interval rather than as a linear ramp that crawls at the top.
    public static func frequency(at progress: Double, voice: SessionCueVoice) -> Double {
        guard voice.overshoot != 0, voice.overshootAt > 0, voice.overshootAt < 1 else {
            return voice.startHz * pow(voice.endHz / voice.startHz, progress)
        }
        let overshootHz = voice.endHz * (1 + voice.overshoot)
        if progress < voice.overshootAt {
            return voice.startHz * pow(overshootHz / voice.startHz, progress / voice.overshootAt)
        }
        let settle = (progress - voice.overshootAt) / (1 - voice.overshootAt)
        return overshootHz * pow(1 / (1 + voice.overshoot), settle)
    }

    public static func envelope(
        at index: Int,
        count: Int,
        voice: SessionCueVoice,
        sampleRate: Double = sampleRate
    ) -> Double {
        let attack = max(1, Int((voice.attackSeconds * sampleRate).rounded()))
        let release = max(1, Int((voice.releaseSeconds * sampleRate).rounded()))
        if index < attack {
            return 0.5 - 0.5 * cos(.pi * Double(index) / Double(attack))
        }
        let fromEnd = count - index
        if fromEnd < release {
            return 0.5 - 0.5 * cos(.pi * Double(fromEnd) / Double(release))
        }
        return 1
    }

    /// A complete mono 16-bit PCM WAV in memory. `AVAudioPlayer(data:)` is the
    /// consumer; nothing is ever written to disk.
    public static func wavData(for cue: SessionCue, sampleRate: Double = sampleRate) -> Data {
        wavData(samples: samples(for: cue.voice, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    public static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let byteCount = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)  // PCM
        append(UInt16(1), to: &data)  // mono
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate) * 2, to: &data)  // byte rate
        append(UInt16(2), to: &data)  // block align
        append(UInt16(16), to: &data)  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount, to: &data)
        for sample in samples {
            let scaled = (Double(sample) * 32_767).rounded()
            append(UInt16(bitPattern: Int16(max(-32_767, min(32_767, scaled)))), to: &data)
        }
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
