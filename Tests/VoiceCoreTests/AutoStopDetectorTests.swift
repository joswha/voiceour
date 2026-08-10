import Foundation
import Testing

@testable import VoiceCore

@Suite("AutoStopDetector")
struct AutoStopDetectorTests {
    @Test func silenceWithoutPriorSpeechNeverFires() {
        var detector = AutoStopDetector()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        for milliseconds in stride(from: 0, through: 5_000, by: 40) {
            let fired = detector.observe(
                level: 0.01,
                at: start.addingTimeInterval(TimeInterval(milliseconds) / 1000)
            )
            #expect(!fired)
        }
    }

    @Test func speechThenSilenceFiresExactlyOnceAtDwellBoundary() {
        var detector = AutoStopDetector(minimumSessionMs: 0)
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        let firedDuringSpeech = detector.observe(level: 0.2, at: start)
        #expect(!firedDuringSpeech)
        for milliseconds in stride(from: 40, through: 2_480, by: 40) {
            let firedEarly = detector.observe(
                level: 0.01,
                at: start.addingTimeInterval(TimeInterval(milliseconds) / 1000)
            )
            #expect(!firedEarly)
        }

        let firedAtBoundary = detector.observe(level: 0.01, at: start.addingTimeInterval(2.5))
        let firedAgain = detector.observe(level: 0.01, at: start.addingTimeInterval(2.54))
        #expect(firedAtBoundary)
        #expect(!firedAgain)
    }

    @Test func minimumSessionGateWinsAfterSilenceDwellElapses() {
        var detector = AutoStopDetector(silenceDwellMs: 1_000, minimumSessionMs: 3_000)
        let start = Date(timeIntervalSinceReferenceDate: 4_000)

        let firedDuringSpeech = detector.observe(level: 0.2, at: start)
        let firedAtDwell = detector.observe(level: 0.01, at: start.addingTimeInterval(1.0))
        let firedBeforeMinimum = detector.observe(level: 0.01, at: start.addingTimeInterval(2.999))
        let firedAtMinimum = detector.observe(level: 0.01, at: start.addingTimeInterval(3.0))

        #expect(!firedDuringSpeech)
        #expect(!firedAtDwell)
        #expect(!firedBeforeMinimum)
        #expect(firedAtMinimum)
    }

    @Test func briefLoudBlipResetsSilenceDwell() {
        var detector = AutoStopDetector(silenceDwellMs: 1_000, minimumSessionMs: 0)
        let start = Date(timeIntervalSinceReferenceDate: 3_000)

        let firedDuringSpeech = detector.observe(level: 0.2, at: start)
        #expect(!firedDuringSpeech)
        for milliseconds in stride(from: 40, through: 560, by: 40) {
            let firedEarly = detector.observe(
                level: 0.01,
                at: start.addingTimeInterval(TimeInterval(milliseconds) / 1000)
            )
            #expect(!firedEarly)
        }

        let firedOnBlip = detector.observe(level: 0.1, at: start.addingTimeInterval(0.6))
        let firedBeforeResetDwell = detector.observe(level: 0.01, at: start.addingTimeInterval(1.0))
        let firedAtResetDwell = detector.observe(level: 0.01, at: start.addingTimeInterval(1.6))
        #expect(!firedOnBlip)
        #expect(!firedBeforeResetDwell)
        #expect(firedAtResetDwell)
    }
}
