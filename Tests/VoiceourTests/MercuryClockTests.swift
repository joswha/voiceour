import Testing

@testable import Voiceour

/// The clock is arithmetic on target timestamps, so every series here is synthetic and exact:
/// no display link, no sleep and no wall clock.
struct MercuryClockTests {
    /// `CACurrentMediaTime()` on the Mac these series were checked against, three and a half
    /// days after boot. Large on purpose: real timestamps are, and their rounding is part of
    /// what an epoch-relative clock has to survive.
    private static let uptime = 304_477.708_560_166_7
    private static let substep = MercuryMetrics.substep
    /// Half a second of the 120 Hz built-in after the anchoring frame, which leaves exactly 60
    /// substeps presented: the display every hand-off here starts from.
    private static let builtInFrames = (1...60).map { uptime + Double($0) * substep }

    @Test func theFirstCallbackAnchorsTheEpochAndPresentsNothing() {
        var clock = MercuryClock()
        #expect(clock.steps(forTargetTimestamp: Self.uptime) == 0)
        #expect(clock.presentedStep == 0)
        var rephased = MercuryClock()
        #expect(rephased.rephase(forTargetTimestamp: Self.uptime) == 0)
        #expect(rephased == clock)
        #expect(clock.steps(forTargetTimestamp: Self.uptime + Self.substep) == 1)
        #expect(clock.presentedStep == 1)
    }

    @Test(arguments: [120, 60, 75, 144, 48])
    func everyCadenceAdvancesExactly120SubstepsPerSecond(rate: Int) {
        let counts = Self.counts(rate: rate, seconds: 3)
        for second in 0..<3 {
            #expect(counts[second * rate..<(second + 1) * rate].reduce(0, +) == 120)
        }
    }

    @Test func eachFrameCarriesItsCadencesShareOfTheSubsteps() {
        #expect(Self.counts(rate: 120, seconds: 1) == Array(repeating: 1, count: 120))
        #expect(Self.counts(rate: 60, seconds: 1) == Array(repeating: 2, count: 60))
        #expect(Self.counts(rate: 75, seconds: 1) == Array(repeating: [2, 1, 2, 1, 2], count: 15).flatMap { $0 })
        #expect(Self.counts(rate: 144, seconds: 1).allSatisfy { $0 <= 1 })
        // 2.5 substeps a frame: every other 48 Hz frame sits exactly between two substeps, so
        // which of the pair takes the third is the timestamp's rounding. The pair is exact.
        let slow = Self.counts(rate: 48, seconds: 1)
        #expect(slow.allSatisfy { $0 == 2 || $0 == 3 })
        #expect(stride(from: 0, to: slow.count, by: 2).allSatisfy { slow[$0] + slow[$0 + 1] == 5 })
    }

    /// Real target timestamps are 24 MHz mach ticks scaled to seconds, with microseconds of
    /// vsync jitter either side of the anchoring frame. At 120 and 60 Hz every frame falls on a
    /// substep boundary, where a floor puts nearly half of these frames a substep early or late.
    /// The nearest substep keeps every one exact, a few days or a month after boot.
    @Test(arguments: [120, 60], [304_477.708_560_166_7, 2_592_000])
    func integerCadencesSurviveTimestampRoundingAndVsyncJitter(rate: Int, uptime: Double) {
        let ticksPerSecond = 24_000_000
        let secondsPerTick = 125.0 / 3.0 * 1e-9
        let first = Int(uptime * Double(ticksPerSecond))
        let period = ticksPerSecond / rate
        // A deterministic ±20 µs spread, zero on the anchoring frame: no generator, so the
        // series replays exactly.
        let timestamps = (0...2_400).map { frame in
            Double(first + frame * period + (frame * 7_919 + 480) % 961 - 480) * secondsPerTick
        }
        var clock = MercuryClock()
        #expect(clock.steps(forTargetTimestamp: timestamps[0]) == 0)
        #expect(Self.present(timestamps.dropFirst(), on: &clock) == Array(repeating: 120 / rate, count: 2_400))
    }

    @Test func aStallPresentsTheCapThenCountsOnWithoutCatchingUp() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        #expect(Self.present(Self.builtInFrames, on: &clock) == Array(repeating: 1, count: 60))

        // Three dropped frames leave exactly the cap due, and all of it is presented.
        #expect(clock.steps(forTargetTimestamp: Self.uptime + 64 * Self.substep) == 4)
        #expect(clock.presentedStep == 64)

        // Half a second hidden leaves 60 substeps due; the body resumes with only the cap.
        let resumed = Self.uptime + 64 * Self.substep + 0.5
        #expect(clock.steps(forTargetTimestamp: resumed) == 4)
        #expect(clock.presentedStep == 68)
        let after = (1...120).map { resumed + Double($0) * Self.substep }
        #expect(Self.present(after, on: &clock) == Array(repeating: 1, count: 120))
        #expect(clock.presentedStep == 188)
    }

    /// A stall that ends on another display re-anchors on that display's first frame, whether
    /// that frame reaches the clock through `steps` or a new link's `rephase`, so its own
    /// cadence starts centred in its cells. Sliding the epoch by whole substeps instead would
    /// keep the old display's phase, here half a substep off the new vsync, where its jitter
    /// turns about half the frames into 1s and 3s.
    @Test(arguments: [false, true])
    func aStallOntoAnotherDisplayResumesCentredOnThatDisplaysCadence(onANewLink: Bool) {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        _ = Self.present(Self.builtInFrames, on: &clock)
        let resumed = Self.uptime + 0.5 + 0.25 + 0.5 * Self.substep
        let resuming =
            onANewLink
            ? clock.rephase(forTargetTimestamp: resumed)
            : clock.steps(forTargetTimestamp: resumed)
        #expect(resuming == 4)
        let external = (1...60).map { frame in
            resumed + Double(frame) / 60 + Jitter.spread.seconds(atFrame: frame)
        }
        #expect(Self.present(external, on: &clock) == Array(repeating: 2, count: 60))
        #expect(clock.presentedStep == 184)
    }

    @Test func aDisplayChangeBelowTheCapLosesNoTimeAndCountsNoneTwice() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        #expect(Self.present(Self.builtInFrames, on: &clock) == Array(repeating: 1, count: 60))

        // The 60 Hz display's first target falls 1.4 substeps after the built-in's last.
        let switched = Self.uptime + 60 * Self.substep + 1.4 * Self.substep
        let external = (0...60).map { switched + Double($0) / 60 }
        #expect(Self.presentOnNewLink(external, on: &clock) == [1] + Array(repeating: 2, count: 60))
        #expect(clock.presentedStep == Int(((external[60] - Self.uptime) / Self.substep).rounded()))
    }

    /// The probe that found the hand-off's flaw: a 60 Hz display whose first target falls 1.5
    /// substeps after the built-in's last, with ±20 µs of alternating jitter. Counted on the
    /// built-in's grid, every frame sits on a rounding boundary and the jitter splits the
    /// cadence into 1, 3, 1, 3 for as long as the panel stays there. Re-phased on the new
    /// link's first frame, every later frame carries exactly two.
    @Test func aHandOffHalfASubstepOffTheGridKeepsTheNewCadenceEven() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        _ = Self.present(Self.builtInFrames, on: &clock)
        let switched = Self.uptime + 61.5 * Self.substep
        let external = (0...120).map { frame in
            switched + Double(frame) / 60 + Jitter.alternatingFromEarly.seconds(atFrame: frame)
        }
        #expect(Self.presentOnNewLink(external, on: &clock) == [1] + Array(repeating: 2, count: 120))
    }

    /// Every phase a new display's vsync can take against the built-in's grid, a thousandth of
    /// a substep apart, under each kind of ±20 µs jitter. The re-phasing frame presents exactly
    /// what `steps` would; every later frame carries the share its cadence gives a clock
    /// anchored on that display; and the total across the hand-off stays within a substep of
    /// the time that elapsed.
    @Test(arguments: [120, 60, 75])
    func aHandOffAtAnyPhaseStartsTheNewDisplaysOwnCadence(rate: Int) {
        let cadence = Self.counts(rate: rate, seconds: 1)
        var handingOff = MercuryClock()
        _ = handingOff.steps(forTargetTimestamp: Self.uptime)
        _ = Self.present(Self.builtInFrames, on: &handingOff)
        var failures: [String] = []
        for thousandths in 0..<1_000 {
            let switched = Self.uptime + (61 + Double(thousandths) / 1_000) * Self.substep
            for jitter in Jitter.allCases {
                let external = (0...rate).map { frame in
                    switched + Double(frame) / Double(rate) + jitter.seconds(atFrame: frame)
                }
                var counted = handingOff
                let first = counted.steps(forTargetTimestamp: external[0])
                var clock = handingOff
                let counts = Self.presentOnNewLink(external, on: &clock)
                let elapsed = (external[rate] - Self.uptime) / Self.substep
                if counts != [first] + cadence || abs(Double(clock.presentedStep) - elapsed) >= 1 {
                    failures.append("\(thousandths)/1000 of a substep, \(jitter): \(counts)")
                }
            }
        }
        #expect(failures.isEmpty)
    }

    /// A new link may first target a moment the old one already presented. It re-phases onto
    /// the substep that moment rounds to, not the last one presented, so it and any frame still
    /// behind present nothing, and the count picks up once time catches up: nothing is
    /// presented twice, and the total is the substep nearest the time that elapsed.
    @Test(arguments: [(0.4, 1), (1.4, 2)])
    func aNewLinkThatStartsBehindTheLastFramePresentsNothingThenResumes(behind: Double, idleFrames: Int) {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        let external = (1...30).map { Self.uptime + Double($0) / 60 }
        #expect(Self.present(external, on: &clock) == Array(repeating: 2, count: 30))

        let switched = Self.uptime + 0.5 - behind * Self.substep
        let builtIn = (0...120).map { switched + Double($0) * Self.substep }
        let resumed = Array(repeating: 0, count: idleFrames) + Array(repeating: 1, count: 121 - idleFrames)
        #expect(Self.presentOnNewLink(builtIn, on: &clock) == resumed)
        #expect(clock.presentedStep == Int(((builtIn[120] - Self.uptime) / Self.substep).rounded()))
    }

    @Test func aTimestampThatIsNotFiniteChangesNothing() {
        let unusable = [Double.nan, .infinity, -.infinity]
        var clock = MercuryClock()
        for timestamp in unusable {
            #expect(clock.steps(forTargetTimestamp: timestamp) == 0)
            #expect(clock.rephase(forTargetTimestamp: timestamp) == 0)
        }
        #expect(clock == MercuryClock())

        _ = clock.steps(forTargetTimestamp: Self.uptime)
        let anchored = clock
        for timestamp in unusable {
            #expect(clock.steps(forTargetTimestamp: timestamp) == 0)
            #expect(clock.rephase(forTargetTimestamp: timestamp) == 0)
        }
        #expect(clock == anchored)
        #expect(clock.steps(forTargetTimestamp: Self.uptime + Self.substep) == 1)
    }

    /// ±20 µs of vsync jitter on a display's frames, by frame index from its first.
    private enum Jitter: CaseIterable {
        /// Early on the first frame, then alternating: the probe's.
        case alternatingFromEarly
        /// Late on the first frame, then alternating.
        case alternatingFromLate
        /// A deterministic spread, zero on the first frame: no generator, so it replays exactly.
        case spread

        func seconds(atFrame frame: Int) -> Double {
            switch self {
            case .alternatingFromEarly: frame.isMultiple(of: 2) ? -20e-6 : 20e-6
            case .alternatingFromLate: frame.isMultiple(of: 2) ? 20e-6 : -20e-6
            case .spread: Double((frame * 7_919 + 480) % 961 - 480) / 24_000_000
            }
        }
    }

    /// Per-frame substeps for `seconds` of callbacks at `rate`, after the anchoring frame.
    private static func counts(rate: Int, seconds: Int) -> [Int] {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: uptime)
        let timestamps = (1...rate * seconds).map { uptime + Double($0) / Double(rate) }
        return present(timestamps, on: &clock)
    }

    private static func present(_ timestamps: some Sequence<Double>, on clock: inout MercuryClock) -> [Int] {
        timestamps.map { clock.steps(forTargetTimestamp: $0) }
    }

    /// A new link's frames as `MercurySurfaceView` presents them: the first re-phases the
    /// clock, and the rest count on from it.
    private static func presentOnNewLink(_ timestamps: [Double], on clock: inout MercuryClock) -> [Int] {
        let first = clock.rephase(forTargetTimestamp: timestamps[0])
        return [first] + present(timestamps.dropFirst(), on: &clock)
    }
}
