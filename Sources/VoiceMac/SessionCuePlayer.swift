import AVFoundation
import Foundation
import VoiceCore

/// Plays the two session cues through the default output device.
///
/// Each cue is synthesized once into an in-memory WAV and kept as a prepared
/// `AVAudioPlayer`, so a replay costs a `currentTime` reset rather than a decode.
public actor SessionCuePlayer: SessionCuePlaying {
    private var players: [SessionCue: AVAudioPlayer] = [:]
    /// A device that refuses to build a player refuses for the process, not for
    /// one cue. Never surfaced: a missing sound is not a dictation failure and has
    /// no `UserFacingDictationFailure` case.
    private var isDisabled = false

    public init() {}

    public func play(_ cue: SessionCue) async {
        guard !isDisabled, let player = prepared(cue) else { return }
        player.currentTime = 0
        _ = player.play()
    }

    private func prepared(_ cue: SessionCue) -> AVAudioPlayer? {
        if let existing = players[cue] {
            return existing
        }
        do {
            let player = try AVAudioPlayer(data: SessionCueSynth.wavData(for: cue))
            player.prepareToPlay()
            players[cue] = player
            return player
        } catch {
            isDisabled = true
            return nil
        }
    }
}
