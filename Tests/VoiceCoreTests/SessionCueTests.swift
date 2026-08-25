import Foundation
import Testing

@testable import VoiceCore

@Suite("Session cues")
struct SessionCueTests {
    /// `totalNanoseconds` rounds rather than truncates, and the cancel cue is the
    /// only case that proves it: its 0.182 s accumulates to 181_999_999.99… in
    /// binary floating point, so a floor would name the cue shorter than it is.
    @Test func cueNanosecondsNameTheirDurationRatherThanFloorIt() {
        for cue in SessionCue.allCases {
            #expect(abs(Double(cue.totalNanoseconds) - cue.totalSeconds * 1_000_000_000) <= 0.5)
        }
    }

    @Test func bothEdgesLeaveAndReturnToSilence() {
        for cue in SessionCue.allCases {
            let samples = SessionCueSynth.samples(for: cue)
            #expect(abs(samples.first ?? 1) < 1e-4)
            #expect(abs(samples.last ?? 1) < 1e-4)
        }
    }

    @Test func noSampleExceedsTheDeclaredPeakAndNoCueIsSilent() {
        for cue in SessionCue.allCases {
            let ceiling = cue.phrase.map(\.peak).max() ?? 0
            let loudest = SessionCueSynth.samples(for: cue).map(abs).max() ?? 0
            #expect(loudest <= Float(ceiling) + 1e-6)
            // Every cue reaches the same ceiling, so no cue is heard as the quiet one.
            #expect(loudest > 0.12)
        }
    }

    @Test func neighbouringSamplesNeverStep() {
        for cue in SessionCue.allCases {
            let samples = SessionCueSynth.samples(for: cue)
            var largest: Float = 0
            for index in 1..<samples.count {
                largest = max(largest, abs(samples[index] - samples[index - 1]))
            }
            // A click is a discontinuity, not a slope: 0.05 is ~1.6x the steepest
            // slope this voice can reach at its overshoot frequency. It also covers
            // the cancel cue's two joins, where a tone must enter and leave the
            // interior silence from zero.
            #expect(largest < 0.05)
        }
    }

    @Test func theRisingCueClimbsPastItsEndToneAndSettlesOnIt() {
        let voice = SessionCue.listeningStarted.phrase[0]
        #expect(abs(SessionCueSynth.frequency(at: 0, voice: voice) - 620) < 1e-6)
        #expect(abs(SessionCueSynth.frequency(at: 0.8, voice: voice) - 1302) < 1e-6)
        #expect(abs(SessionCueSynth.frequency(at: 1, voice: voice) - 1240) < 1e-6)

        var previous = 0.0
        for step in 0...80 {
            let value = SessionCueSynth.frequency(at: Double(step) / 100, voice: voice)
            #expect(value > previous)
            previous = value
        }
    }

    @Test func theFallingCueMirrorsPitchAndIsNotTimeReversed() {
        let falling = SessionCue.listeningEnded.phrase[0]
        #expect(abs(SessionCueSynth.frequency(at: 0, voice: falling) - 1240) < 1e-6)
        #expect(abs(SessionCueSynth.frequency(at: 1, voice: falling) - 620) < 1e-6)

        var previous = Double.infinity
        for step in 0...80 {
            let value = SessionCueSynth.frequency(at: Double(step) / 100, voice: falling)
            #expect(value < previous)
            previous = value
        }

        let rising = SessionCueSynth.samples(for: .listeningStarted)
        #expect(SessionCueSynth.samples(for: .listeningEnded) != Array(rising.reversed()))
    }

    /// Cancel has to be recognisable against a falling cue the ear already knows,
    /// so it differs in texture and not only in pitch: two clipped tones with a
    /// real silence between them, the second longer than the first.
    @Test func theCancelCueIsTwoClippedTonesSeparatedBySilence() {
        let phrase = SessionCue.listeningCancelled.phrase
        let opening = phrase[0]
        let landing = phrase[1]

        #expect(opening.leadingGapSeconds == 0)
        #expect(landing.leadingGapSeconds > 0.015)
        #expect(landing.durationSeconds > opening.durationSeconds)
        // A falling perfect fourth, E♭5 to B♭4, so the gesture lands below both glides.
        #expect(abs(opening.startHz / landing.startHz - 4.0 / 3.0) < 0.02)
        #expect(landing.endHz < SessionCue.listeningEnded.phrase[0].endHz)

        let gap = Int((landing.leadingGapSeconds * SessionCueSynth.sampleRate).rounded())
        #expect(quietestRun(in: SessionCueSynth.samples(for: .listeningCancelled)) >= gap)
    }

    @Test func neitherGlideCarriesAnInteriorSilence() {
        // The property that keeps the three cues apart: only cancel has a hole in
        // the middle, so a glide retuned to cancel's pitches would fail here.
        #expect(quietestRun(in: SessionCueSynth.samples(for: .listeningStarted)) < 4)
        #expect(quietestRun(in: SessionCueSynth.samples(for: .listeningEnded)) < 4)
    }

    @Test func theWavIsAMonoSixteenBitRiffOfTheRightLength() {
        let data = SessionCueSynth.wavData(for: .listeningStarted)
        for cue in SessionCue.allCases {
            // 44-byte canonical header, then one 16-bit sample per rendered frame.
            #expect(SessionCueSynth.wavData(for: cue).count == 44 + SessionCueSynth.samples(for: cue).count * 2)
        }
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(data[22] == 1 && data[23] == 0)  // one channel
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) } == 48_000)
        #expect(data[34] == 16 && data[35] == 0)  // bits per sample
    }

    /// Longest run of near-silent samples away from the edges, where every cue is
    /// quiet because its envelope opens and closes there.
    private func quietestRun(in samples: [Float]) -> Int {
        let margin = samples.count / 20
        var longest = 0
        var current = 0
        for sample in samples[margin..<(samples.count - margin)] {
            if abs(sample) < 1e-5 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

@Suite("Session cue setting")
struct SessionCueSettingTests {
    @Test func theCueIsOnByDefault() {
        #expect(Settings().sessionSoundsEnabled)
    }

    @Test func aSettingsFileWithoutTheKeyKeepsTheDefault() throws {
        let json = Data(#"{"cleanup_enabled": true}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: json)
        #expect(decoded.sessionSoundsEnabled)
    }

    @Test func theKeyRoundTrips() throws {
        var settings = Settings()
        settings.sessionSoundsEnabled = false
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains("session_sounds_enabled"))
        #expect(try JSONDecoder().decode(Settings.self, from: data).sessionSoundsEnabled == false)
    }
}
