import Foundation
import Testing

@testable import VoiceCore

@Suite("Session cues")
struct SessionCueTests {
    @Test func aCueIsExactlyTheDeclaredLength() {
        #expect(SessionCueSynth.samples(for: SessionCue.listeningStarted.voice).count == 6720)
        #expect(SessionCueSynth.samples(for: SessionCue.listeningEnded.voice).count == 6720)
        #expect(SessionCue.durationNanoseconds == 140_000_000)
    }

    @Test func bothEdgesLeaveAndReturnToSilence() {
        for cue in SessionCue.allCases {
            let samples = SessionCueSynth.samples(for: cue.voice)
            #expect(abs(samples.first ?? 1) < 1e-4)
            #expect(abs(samples.last ?? 1) < 1e-4)
        }
    }

    @Test func noSampleExceedsTheDeclaredPeakAndTheCueIsNotSilent() {
        for cue in SessionCue.allCases {
            let loudest = SessionCueSynth.samples(for: cue.voice).map(abs).max() ?? 0
            #expect(loudest <= Float(cue.voice.peak) + 1e-6)
            #expect(loudest > 0.12)
        }
    }

    @Test func neighbouringSamplesNeverStep() {
        for cue in SessionCue.allCases {
            let samples = SessionCueSynth.samples(for: cue.voice)
            var largest: Float = 0
            for index in 1..<samples.count {
                largest = max(largest, abs(samples[index] - samples[index - 1]))
            }
            // A click is a discontinuity, not a slope: 0.05 is ~1.6x the steepest
            // slope this voice can reach at its overshoot frequency.
            #expect(largest < 0.05)
        }
    }

    @Test func theRisingCueClimbsPastItsEndToneAndSettlesOnIt() {
        let voice = SessionCue.listeningStarted.voice
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
        let falling = SessionCue.listeningEnded.voice
        #expect(abs(SessionCueSynth.frequency(at: 0, voice: falling) - 1240) < 1e-6)
        #expect(abs(SessionCueSynth.frequency(at: 1, voice: falling) - 620) < 1e-6)

        var previous = Double.infinity
        for step in 0...80 {
            let value = SessionCueSynth.frequency(at: Double(step) / 100, voice: falling)
            #expect(value < previous)
            previous = value
        }

        let rising = SessionCueSynth.samples(for: SessionCue.listeningStarted.voice)
        #expect(SessionCueSynth.samples(for: falling) != Array(rising.reversed()))
    }

    @Test func theWavIsAMonoSixteenBitRiffOfTheRightLength() {
        let data = SessionCueSynth.wavData(for: .listeningStarted)
        #expect(data.count == 44 + 6720 * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(data[22] == 1 && data[23] == 0)  // one channel
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) } == 48_000)
        #expect(data[34] == 16 && data[35] == 0)  // bits per sample
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
