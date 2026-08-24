import AVFoundation
import Foundation
import Testing
import VoiceCore

@testable import VoiceMac

/// The one failure `SessionCuePlayer` cannot report is `AVAudioPlayer` refusing
/// the synthesized bytes: the actor latches itself off for the process and the app
/// goes quiet with nothing to say, because a missing cue is not a dictation
/// failure. So the header the synth writes is pinned against the real decoder
/// rather than trusted.
@Suite("Session cue player")
struct SessionCuePlayerTests {
    @Test func avAudioPlayerAcceptsEveryCueAtItsDeclaredLength() throws {
        for cue in SessionCue.allCases {
            let player = try AVAudioPlayer(data: SessionCueSynth.wavData(for: cue))
            #expect(abs(player.duration - cue.totalSeconds) < 0.001)
            #expect(player.numberOfChannels == 1)
            #expect(player.prepareToPlay())
        }
    }
}
