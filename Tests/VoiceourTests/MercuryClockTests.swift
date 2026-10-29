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

    @Test func theFirstCallbackAnchorsTheEpochAndPresentsNothing() {
        var clock = MercuryClock()
        #expect(clock.steps(forTargetTimestamp: Self.uptime) == 0)
        #expect(clock.presentedStep == 0)
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
        let running = (1...60).map { Self.uptime + Double($0) * Self.substep }
        #expect(Self.present(running, on: &clock) == Array(repeating: 1, count: 60))

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

    /// A stall that ends on another display re-anchors on that display's first frame, so its
    /// own cadence starts centred in its cells. Sliding the epoch by whole substeps instead
    /// would keep the old display's phase, here half a substep off the new vsync, where its
    /// jitter turns about half the frames into 1s and 3s.
    @Test func aStallOntoAnotherDisplayResumesCentredOnThatDisplaysCadence() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        _ = Self.present((1...60).map { Self.uptime + Double($0) * Self.substep }, on: &clock)
        let resumed = Self.uptime + 0.5 + 0.25 + 0.5 * Self.substep
        #expect(clock.steps(forTargetTimestamp: resumed) == 4)
        // ±20 µs of deterministic vsync jitter on the new display.
        let external = (1...60).map { frame in
            let jitter = Double((frame * 7_919 + 480) % 961 - 480) / 24_000_000
            return resumed + Double(frame) / 60 + jitter
        }
        #expect(Self.present(external, on: &clock) == Array(repeating: 2, count: 60))
        #expect(clock.presentedStep == 184)
    }

    @Test func aDisplayChangeBelowTheCapLosesNoTimeAndCountsNoneTwice() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        let builtIn = (1...60).map { Self.uptime + Double($0) * Self.substep }
        #expect(Self.present(builtIn, on: &clock) == Array(repeating: 1, count: 60))

        // The 60 Hz display's first target falls 1.4 substeps after the built-in's last.
        let switched = Self.uptime + 60 * Self.substep + 1.4 * Self.substep
        let external = (0...60).map { switched + Double($0) / 60 }
        #expect(Self.present(external, on: &clock) == [1] + Array(repeating: 2, count: 60))
        #expect(clock.presentedStep == Int(((external[60] - Self.uptime) / Self.substep).rounded()))
    }

    /// A new link may first target a moment the old one already presented. That frame presents
    /// nothing rather than stepping twice, and the count picks up from the next.
    @Test func aNewLinkThatStartsBehindTheLastFramePresentsNothingThenResumes() {
        var clock = MercuryClock()
        _ = clock.steps(forTargetTimestamp: Self.uptime)
        let external = (1...30).map { Self.uptime + Double($0) / 60 }
        #expect(Self.present(external, on: &clock) == Array(repeating: 2, count: 30))

        let switched = Self.uptime + 0.5 - 0.4 * Self.substep
        let builtIn = (0...120).map { switched + Double($0) * Self.substep }
        #expect(Self.present(builtIn, on: &clock) == [0] + Array(repeating: 1, count: 120))
        #expect(clock.presentedStep == 180)
    }

    @Test func aTimestampThatIsNotFiniteChangesNothing() {
        var clock = MercuryClock()
        #expect(clock.steps(forTargetTimestamp: .nan) == 0)
        #expect(clock == MercuryClock())

        _ = clock.steps(forTargetTimestamp: Self.uptime)
        let anchored = clock
        #expect(clock.steps(forTargetTimestamp: .infinity) == 0)
        #expect(clock.steps(forTargetTimestamp: -.infinity) == 0)
        #expect(clock == anchored)
        #expect(clock.steps(forTargetTimestamp: Self.uptime + Self.substep) == 1)
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
}
