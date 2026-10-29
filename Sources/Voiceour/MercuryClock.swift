/// The fixed 120 Hz physics clock, read against the timestamps a display presents at.
///
/// Physics never changes step size; presentation follows whatever display the panel is on.
/// Each display-link callback asks how many substeps separate the frame it is about to present
/// from the frames already presented. The answer is counted from one epoch, never accumulated
/// from frame durations: an accumulated remainder rounds a little on every frame and had to be
/// thrown away whenever the link was rebuilt for a new display, so every hand-off lost part of
/// a substep. Counted from an epoch, each wall-clock second is exactly 120 substeps at any
/// cadence — one a frame at 120 Hz, two at 60 Hz, a 2,1,2,1,2 cycle at 75 Hz, two or three at
/// 48 Hz, never more than one at 144 Hz — and a cadence change mid-run neither loses time nor
/// counts any of it twice.
///
/// A frame shows the substep *nearest* its target timestamp, `n = ⌊(t − epoch)·120 + ½⌋`, not
/// the last one before it. The epoch is the first frame's own target, so at an integer cadence
/// every later frame lands exactly on a substep, where a floor has no margin at all. The
/// rounding of `CACurrentMediaTime` alone turns two 120 Hz frames in three into 0s and 2s three
/// and a half days after boot, and microseconds of vsync jitter do the same at any uptime.
/// Rounding centres those frames in a ±4.17 ms cell instead, and the body on glass is never
/// more than half a substep from the moment it is shown.
///
/// More than `maxSubstepsPerFrame` due at once means the link stalled, the panel was hidden, or
/// a new display's link started late. The clock presents the cap and slides its epoch so this
/// frame sits exactly on the substep it presents: an old body resumes instead of fast-forwarding
/// through the gap, and the new cadence starts centred in its cells. It never resets, so
/// `presentedStep` only ever grows.
struct MercuryClock: Sendable, Equatable {
    /// The first frame's target timestamp, slid forward past every stall since. Nil until a
    /// display link has called.
    private var epoch: Double?
    /// Substeps presented since the first frame.
    private(set) var presentedStep = 0

    /// Substeps to advance for a display-link callback whose `targetTimestamp` is `t`, in
    /// `CACurrentMediaTime` seconds. The first call anchors the epoch and presents nothing. A
    /// timestamp that is not finite presents nothing and changes nothing: one bad callback must
    /// not poison the epoch every later frame is counted from.
    mutating func steps(forTargetTimestamp t: Double) -> Int {
        guard t.isFinite else { return 0 }
        guard let epoch else {
            self.epoch = t
            return 0
        }
        let nearest = ((t - epoch) / MercuryMetrics.substep + 0.5).rounded(.down)
        let due = nearest - Double(presentedStep)
        guard due > 0 else { return 0 }
        let cap = MercuryMetrics.maxSubstepsPerFrame
        guard due <= Double(cap) else {
            presentedStep += cap
            self.epoch = t - Double(presentedStep) * MercuryMetrics.substep
            return cap
        }
        let steps = Int(due)
        presentedStep += steps
        return steps
    }
}
