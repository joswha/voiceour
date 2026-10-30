import Foundation

/// A live microphone with nobody at it: the model `MercuryRibbon` reads, fed one meter level per
/// 40 ms of simulated time, and the drive the ribbon builds from it on its layout's ladder.
///
/// `MercuryCalibration` solves the drive gain on a speaking meter, and the chrome benchmark holds
/// every speaking body to its bounds under one, so the speech the gain is solved against is the
/// speech the gates measure.
///
/// A speaking meter hears ``Speech``, never one buffer held still, because the live meter never
/// holds still. The voice is the buffer's spectrum, advected at `L / bufferPeriod` and recomputed
/// whenever the buffer changes. Between two 40 ms shifts the advection turns every mode through
/// exactly the phase the next shift applies, so a live body carries the last 440 ms of speech. A
/// buffer held still goes on advecting, and its band-limited extension is periodic in `2L`: for
/// half of every 0.88 s the body carries the buffer, thick and busy, and for the other half the
/// extension's trough, thin and smooth. The gel answers the voice quasi-statically and draws both
/// halves upright, so whatever is measured on a buffer held still is an alias of the input, not a
/// property of the material or the room.
///
/// A quiet meter hears ``quietRoom`` held still. Refreshed, it would hold the same pose, every level
/// at or below the release level either way, and its voice is a few percent of speech's.
@MainActor
final class MercurySpeechMeter {
    /// One syllable and the onset of the next, oldest first, as the live meter buffers it.
    nonisolated static let syllable: [Float] = [
        0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46,
    ]

    /// A live microphone in a quiet room, oldest first: every level at or below the release level,
    /// so the voice-activity hysteresis never starts and the pose is the listening one.
    nonisolated static let quietRoom: [Float] = [
        0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02,
    ]

    private let model: RecordingOverlayModel
    private let reduceMotion: Bool
    private var speech: Speech?
    /// Substeps since the body was placed on the first drive.
    private var substeps = 0
    /// Levels recorded since the placement. The body is placed on the buffer's newest level, so the
    /// first falls due 40 ms later.
    private var recorded = 0
    /// What the next substep runs on.
    private(set) var drive: MercurySimulation.Drive

    /// A meter on `layout` that hears `seed`'s speech when `speaking`, and the quiet room when not.
    init(speaking: Bool, seed: UInt64, layout: RecordingOverlayLayout, reduceMotion: Bool = false) {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.recording)
        model.updateCaptureLive(true)
        if speaking {
            var speech = Speech(seed: seed)
            // A full buffer that the model has heard as speech. The attack wants two levels at or
            // above 0.10, and a seed may open by lingering on the 0.08 floor.
            var heard = 0
            while heard < model.samples.count || !model.isSpeaking {
                model.record(speech.next())
                heard += 1
            }
            self.speech = speech
        } else {
            for level in Self.quietRoom { model.record(level) }
        }
        self.model = model
        self.reduceMotion = reduceMotion
        drive = .target(for: model, reduceMotion: reduceMotion)
    }

    /// `steps` substeps of `simulation`, which the caller placed on ``drive``, each run on the
    /// buffer of its moment, as the display link hands the engine the model's buffer every frame.
    /// The substeps between two levels run as one advance: the simulation is batch-independent, and
    /// its voice refreshes only when the buffer changes.
    func advance(_ simulation: MercurySimulation, steps: Int) {
        var remaining = steps
        while remaining > 0 {
            var run = remaining
            if speech != nil {
                run = Swift.min(run, Self.substep(ofLevel: recorded + 1) - substeps)
            }
            simulation.advance(steps: run, drive: drive)
            elapse(run)
            remaining -= run
        }
    }

    /// Moves the meter's clock on by `steps` substeps and records every level due by then.
    func elapse(_ steps: Int) {
        substeps += steps
        let due = Self.levelsDue(by: substeps)
        guard var speech, due > recorded else { return }
        while recorded < due {
            model.record(speech.next())
            recorded += 1
        }
        self.speech = speech
        drive = .target(for: model, reduceMotion: reduceMotion)
    }

    /// `RecordingSessionDriver` polls the meter every 40 ms, 24/5 of a 1/120 s substep, so level
    /// `level` falls due at substep `24 level / 5` and reaches the body in the first substep that
    /// starts at or after it.
    private static func substep(ofLevel level: Int) -> Int {
        (24 * level + 4) / 5
    }

    /// How many levels are due by substep `substep`: the inverse of ``substep(ofLevel:)``.
    private static func levelsDue(by substep: Int) -> Int {
        5 * substep / 24
    }

    /// Live-like speech, one level per meter tick, keyed by a seed.
    ///
    /// The meter speaks ``MercurySpeechMeter/syllable`` on a loop from a seeded first level, and
    /// after each level moves on by zero, one or two, uniformly: a speaker who lingers on one level
    /// and hurries past another, at the buffer's own rate on average. Every level is one of the
    /// syllable's, and in the long run each is spoken equally often, so the meter keeps the
    /// syllable's range, 0.08…0.88, its mean and its spread, and the syllable's rise and fall is its
    /// envelope. It never settles into a period, and seeds do not speak in step. Its floor is above
    /// the release level, so a body that has heard speech holds the speaking pose.
    private struct Speech {
        private let noise: MercuryNoise
        private var position: Int
        /// Levels spoken so far. Counter 0 draws the first level, and counter `n` the move after the
        /// `n`th.
        private var spoken: UInt64 = 0

        init(seed: UInt64) {
            noise = MercuryNoise(seed: seed)
            let draw = noise.uniform(stream: MercuryNoiseStream.speechMeter, counter: 0)
            position = Int(Double(MercurySpeechMeter.syllable.count) * draw)
        }

        mutating func next() -> Float {
            let level = MercurySpeechMeter.syllable[position]
            spoken += 1
            let draw = noise.uniform(stream: MercuryNoiseStream.speechMeter, counter: spoken)
            position = (position + Int(3 * draw)) % MercurySpeechMeter.syllable.count
            return level
        }
    }
}

extension MercuryNoiseStream {
    /// ``MercurySpeechMeter``'s speech. Numbered past the streams the body and the room draw, so the
    /// speech a body hears shares no draw with its own kicks or rest shape under the same seed.
    static let speechMeter: UInt32 = 9
}
