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

    /// Pays the process's first audio start once, off the dictation path.
    ///
    /// Measured on an M4 Pro: the first `play()` in a process takes 170–230 ms
    /// while every later one takes 25–40 ms, and the start cue owns only the
    /// 140 ms window it gets before the muter begins ducking the output device. So
    /// without this the first rise of every launch was the one cue the user could
    /// not hear whole. A silent play absorbs the audio-unit setup, and preparing
    /// each cue here means the first real play is device start alone.
    public func warmUp() async {
        guard !isDisabled else { return }
        // A throwaway player rather than a cue's own: warming must not be able to
        // leave a cue muted or mid-file if this ever grows a branch.
        guard let warmer = try? AVAudioPlayer(data: SessionCueSynth.wavData(for: .listeningStarted)) else {
            isDisabled = true
            return
        }
        warmer.volume = 0
        warmer.prepareToPlay()
        _ = warmer.play()
        warmer.stop()
        for cue in SessionCue.allCases {
            _ = prepared(cue)
        }
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
