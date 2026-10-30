import Foundation
import Testing
import VoiceCore

@testable import Voiceour

/// The body's shape law, held to its contract: a pose step rings like a jelly and settles, Reduce
/// Motion takes every rung of both ladders straight to its pose, from rest or from wherever the gel's
/// swing has got to, the volume never overshoots, area is exact, no drive can push the body past a
/// bound or slide it off its track, a reset lands where a step holds the pose, an idle target
/// swallows, an empty body emerges in its pose, and batching changes nothing.
struct MercuryBodyShapeTests {
    private typealias Shape = MercuryBodyShape

    /// Fixtures, not the shipping ladder: island-length limits that hold `H` to the 17 pt ceiling
    /// rather than the simulation's 13.24 pt wall, a 160 × 11.5 pt body, as long as the island's
    /// speaking body and as deep as the collar's, and a 130 × 8 pt lip.
    private static let island = Shape.Limits(maxLength: 168, maxHalfHeight: 17, maxSway: 12)
    private static let speaking = target(length: 160, halfHeight: 11.5)
    private static let listening = target(length: 130, halfHeight: 8)
    private static let idle = target(length: 0, halfHeight: 0)

    /// Same volume, new proportions: only `α` moves, and it rings like a jelly before it settles. The
    /// overshoot band is what a pose step loading the arm gives; a step that left the arm alone would
    /// overshoot by a fifth and read as a liquid, not a gel.
    @Test func anAspectStepRingsAndSettles() {
        let start = log(10.0)
        let goal = log(125.0 / 8)
        var shape = Shape()
        shape.reset(to: Self.target(length: 100, halfHeight: 10), limits: Self.island)
        var aspects: [Double] = []
        for _ in 0..<360 {
            shape.step(
                toward: Self.target(length: 125, halfHeight: 8),
                limits: Self.island,
                forcing: .none,
                reduceMotion: false
            )
            aspects.append(Self.aspect(shape))
        }
        let overshoot = ((aspects.max() ?? goal) - goal) / (goal - start)
        let lastOutside = aspects.lastIndex { abs($0 - goal) > 0.02 * (goal - start) } ?? -1
        let settled = Double(lastOutside + 1) * MercuryMetrics.substep

        #expect(overshoot >= 0.3 && overshoot <= 0.7)
        #expect(Self.extremumCount(aspects) >= 2)
        #expect(settled <= 2)
        // The wobble moves area between length and thickness and moves no mass.
        #expect(shape.volume == 1_000)
    }

    /// Reduce Motion moves `L` and `H` themselves, each critically damped toward the pose, so from any
    /// rung of either ladder to any other, emerging from empty and swallowing into it included, each
    /// goes straight to the pose and never past it, as do the sway, skew and neck. Damping the volume
    /// and the aspect instead let a processing body collapsing into the error pose overshoot its length
    /// by 4 pt.
    ///
    /// The same holds when Reduce Motion is turned on partway through the gel's own transition, at any
    /// point of its swing: it takes over only the motion that heads for the pose. Taken over whole at
    /// each substep from 0 to 120, the gel's rates carried the body past its pose in 3,906 of 6,776
    /// island runs and 6,835 of 10,890 collar runs.
    @MainActor
    @Test func reduceMotionTakesEveryRungStraightToItsPose() {
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let ladders = [
            ("island", Self.island, Self.ladder(regions: nil)),
            ("collar", Self.limits(along: collar.spine), Self.ladder(regions: collar.spine.regions)),
        ]
        for (name, limits, rungs) in ladders {
            for from in rungs {
                for to in rungs where to != from {
                    // Gel substeps before Reduce Motion takes over: none, then across the swing.
                    for takeover in [0, 1, 3, 6, 10, 16, 24, 32, 44, 60] {
                        var shape = Shape()
                        shape.reset(to: from, limits: limits)
                        for _ in 0..<takeover {
                            shape.step(toward: to, limits: limits, forcing: .none, reduceMotion: false)
                        }
                        let goal = Self.coordinates(of: to)
                        var previous = Self.coordinates(of: shape)
                        var straight = true
                        for _ in 0..<360 {
                            shape.step(toward: to, limits: limits, forcing: .none, reduceMotion: true)
                            let current = Self.coordinates(of: shape)
                            straight = straight && Self.approaches(goal, from: previous, to: current)
                            previous = current
                        }
                        let pair = "\(from.length)×\(from.halfHeight) → \(to.length)×\(to.halfHeight)"
                        let step = "\(name) \(pair), taken over after \(takeover) substeps"
                        #expect(straight, "\(step)")
                        #expect(zip(previous, goal).allSatisfy { abs($0 - $1) < 1e-6 }, "\(step)")
                    }
                }
            }
        }
    }

    /// Volume is mass through the notch: emerging from empty, growing or shrinking, it moves straight
    /// to its target and never past it.
    @Test func volumeNeverOvershoots() {
        var shape = Shape()
        for (pose, volume) in [(Self.speaking, 1_840.0), (Self.listening, 1_040.0), (Self.speaking, 1_840.0)] {
            var previous = shape.volume
            var monotone = true
            for _ in 0..<360 {
                shape.step(toward: pose, limits: Self.island, forcing: .none, reduceMotion: false)
                monotone = monotone && Self.approaches(volume, from: previous, to: shape.volume)
                previous = shape.volume
            }
            #expect(monotone, "toward \(volume) pt²")
        }
    }

    /// `L·H = V` by construction, through a wobble, a kick, frame forcing and a swallow.
    @Test func areaIsLengthTimesHalfHeight() {
        var shape = Shape()
        shape.reset(to: Self.speaking, limits: Self.island)
        #expect(shape.length * shape.halfHeight == shape.volume)

        var worst = 0.0
        var emptyIsFlat = true
        for index in 0..<600 {
            if index == 100 {
                shape.apply(Shape.Impulse(aspectRate: 3, swayRate: -40, volumeRate: 500))
            }
            let pose = index < 300 ? Self.target(length: 90, halfHeight: 14) : Self.idle
            let forcing = Shape.Forcing(
                tangentialAcceleration: 3_000 * sin(Double(index) / 7),
                normalAcceleration: 9_000 * cos(Double(index) / 5)
            )
            shape.step(toward: pose, limits: Self.island, forcing: forcing, reduceMotion: false)
            if shape.volume > 0 {
                worst = max(worst, abs(shape.length * shape.halfHeight - shape.volume) / shape.volume)
            } else {
                emptyIsFlat = emptyIsFlat && shape.length == 0 && shape.halfHeight == 0
            }
        }

        #expect(worst <= 1e-12)
        #expect(emptyIsFlat)
        #expect(shape.volume == 0)
    }

    /// No target, kick or frame acceleration can push the body past a bound or slide it off its track.
    /// The inputs are adversarial on purpose — negative and enormous poses, kicks far beyond any
    /// gesture, frame accelerations past the clamp, Reduce Motion toggling — on the island and on a
    /// collar spine.
    @Test(arguments: [
        MercuryBodyShape.Limits(maxLength: 168, maxHalfHeight: 17, maxSway: 12),
        MercuryBodyShape.Limits(maxLength: 354, maxHalfHeight: 17, maxSway: 12),
    ])
    func noDriveLeavesTheLimits(limits: MercuryBodyShape.Limits) {
        let noise = MercuryNoise(seed: 0x5EED_5EED)
        var draw: UInt64 = 0
        func uniform(_ low: Double, _ high: Double) -> Double {
            defer { draw += 1 }
            return low + (high - low) * noise.uniform(stream: 900, counter: draw)
        }

        var shape = Shape()
        var pose = Self.speaking
        var forcing = Shape.Forcing.none
        var reduceMotion = false
        var excess = -Double.infinity
        var finite = true
        for index in 0..<20_000 {
            if index % 12 == 0 {
                let empty = uniform(0, 1) < 0.15
                pose = Shape.Target(
                    length: empty ? 0 : uniform(-100, 600),
                    halfHeight: empty ? 0 : uniform(-10, 60),
                    sway: uniform(-50, 50),
                    skew: uniform(-3, 3),
                    neck: uniform(-2, 3)
                )
                forcing = Shape.Forcing(
                    tangentialAcceleration: uniform(-1e6, 1e6),
                    normalAcceleration: uniform(-1e6, 1e6)
                )
                reduceMotion = uniform(0, 1) < 0.2
                shape.apply(
                    Shape.Impulse(
                        aspectRate: uniform(-20, 20),
                        swayRate: uniform(-600, 600),
                        volumeRate: uniform(-2e4, 2e4)
                    )
                )
            }
            shape.step(toward: pose, limits: limits, forcing: forcing, reduceMotion: reduceMotion)
            excess = max(
                excess,
                -shape.volume,
                shape.volume - limits.maxLength * limits.maxHalfHeight,
                -shape.length,
                shape.length - limits.maxLength,
                -shape.halfHeight,
                shape.halfHeight - limits.maxHalfHeight,
                abs(shape.sway) - min(limits.maxSway, (limits.maxLength - shape.length) / 2),
                abs(shape.skew) - 0.6,
                -shape.neck,
                shape.neck - 0.85
            )
            finite = finite && [shape.volume, shape.length, shape.halfHeight, shape.sway].allSatisfy(\.isFinite)
        }

        #expect(excess <= 0)
        #expect(finite)
    }

    /// A pose past a wall is the pose at the wall: the sway's own, which holds a listening body, and the
    /// track's end, which holds a speaking one. Were the spring anchored beyond either, the arm would
    /// wind up while the body waited there and fling it back by the whole anchor displacement on return.
    @Test func aPosePastAWallIsThePoseAtTheWall() {
        func swingPastCentre(of pose: Shape.Target, afterHolding sway: Double) -> Double {
            var held = pose
            held.sway = sway
            var shape = Shape()
            shape.reset(to: pose, limits: Self.island)
            for _ in 0..<120 {
                shape.step(toward: held, limits: Self.island, forcing: .none, reduceMotion: false)
            }
            var lowest = 0.0
            for _ in 0..<240 {
                shape.step(toward: pose, limits: Self.island, forcing: .none, reduceMotion: false)
                lowest = min(lowest, shape.sway)
            }
            return lowest
        }
        let trackEnd = (Self.island.maxLength - Self.speaking.length) / 2
        for (pose, wall) in [(Self.listening, Self.island.maxSway), (Self.speaking, trackEnd)] {
            let atTheWall = swingPastCentre(of: pose, afterHolding: wall)

            #expect(swingPastCentre(of: pose, afterHolding: 30) == atTheWall, "\(pose.length) pt")
            #expect(atTheWall > -wall, "\(pose.length) pt")
        }
    }

    /// Every body on the island rides the same 168 pt track, and no sway slides one off it: a speaking
    /// body, 160 pt of it, leaning either way stops with its end on the track's, 84 pt from the middle,
    /// through the gel's overshoot and through an emergence. On the collar the spine is the track, and
    /// it is long enough that every speaking body keeps the whole ±12 pt wall.
    @MainActor
    @Test func theSwayStopsAtTheTrackEnds() {
        let trackEnd = Self.island.maxLength / 2
        for lean in [-1.0, 1.0] {
            let leaning = Self.target(length: 160, halfHeight: 11.5, sway: lean * MercuryMetrics.leanSway)
            let settled = lean * (trackEnd - leaning.length / 2)
            for emerging in [false, true] {
                var shape = Shape()
                if !emerging {
                    shape.reset(to: Self.speaking, limits: Self.island)
                }
                var furthest = 0.0
                for _ in 0..<1_200 {
                    shape.step(toward: leaning, limits: Self.island, forcing: .none, reduceMotion: false)
                    furthest = max(furthest, abs(shape.sway) + shape.length / 2)
                }

                #expect(furthest <= trackEnd, "lean \(lean), emerging \(emerging)")
                #expect(abs(shape.sway - settled) < 1e-6, "lean \(lean), emerging \(emerging)")
            }
        }

        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let limits = Self.limits(along: collar.spine)
        let speaking = Self.live(levels: [0.5, 0.5])
        let contexts = [
            MercuryPoseContext(), MercuryPoseContext(pointerInBand: true), MercuryPoseContext(fullScreen: true),
        ]
        for context in contexts {
            let pose = MercuryPose.target(for: speaking, regions: collar.spine.regions, context: context)
            let still = Self.target(length: Double(pose.length), halfHeight: Double(pose.halfHeight))
            for sway in [-MercuryMetrics.maxSway, MercuryMetrics.maxSway] {
                var swayed = still
                swayed.sway = sway
                var shape = Shape()
                shape.reset(to: still, limits: limits)
                for _ in 0..<1_200 {
                    shape.step(toward: swayed, limits: limits, forcing: .none, reduceMotion: false)
                }

                #expect(abs(shape.sway - sway) < 1e-6, "\(pose.length) pt")
            }
        }
    }

    /// A reset is at rest exactly where `step` holds the pose, walls included, so no first substep
    /// snaps the body back. A speaking island body leaning its full 6 pt starts at the track's end, 4 pt
    /// out, with its own extent to the bit. A sway past its wall starts on the wall, a pose longer or
    /// deeper than the bounds at its projection, and an empty pose's sway within an empty body's reach.
    @Test func aResetLandsWhereAStepHoldsThePose() {
        let leaning = Self.target(length: 160, halfHeight: 11.5, sway: MercuryMetrics.leanSway)
        var shape = Shape()
        shape.reset(to: leaning, limits: Self.island)

        #expect(shape.sway == (Self.island.maxLength - leaning.length) / 2)
        #expect(shape.length == leaning.length && shape.halfHeight == leaning.halfHeight)

        let poses = [
            leaning,
            Self.target(length: 130, halfHeight: 8, sway: -30),
            Self.target(length: 400, halfHeight: 11.5, sway: 12),
            Self.target(length: 160, halfHeight: 40, skew: 2, neck: -1),
            Self.target(length: 0, halfHeight: 0, sway: 50),
        ]
        for pose in poses {
            var placed = Shape()
            placed.reset(to: pose, limits: Self.island)
            var stepped = placed
            stepped.step(toward: pose, limits: Self.island, forcing: .none, reduceMotion: true)

            #expect(Self.coordinates(of: stepped) == Self.coordinates(of: placed), "\(pose)")
        }
    }

    /// An idle target is an outflow through the notch: the body empties — not merely approaches
    /// empty — well inside 0.6 s, monotonically, holding its proportions while it drains, its length
    /// and thickness each shrinking straight to zero. The cases are the 160 × 11.5 pt fixture and a
    /// 400 × 17 pt fixture, past the largest body the 13.24 pt height wall lets a collar hold.
    @Test(arguments: [false, true])
    func theIdleTargetSwallows(reduceMotion: Bool) {
        let collar = Shape.Limits(maxLength: 400, maxHalfHeight: 17, maxSway: 12)
        for (pose, limits) in [(Self.speaking, Self.island), (Self.target(length: 400, halfHeight: 17), collar)] {
            var shape = Shape()
            shape.reset(to: pose, limits: limits)
            let proportion = shape.length / shape.halfHeight
            var previous = shape
            var monotone = true
            var worstProportion = 0.0
            var belowOne = false
            for _ in 0..<72 {
                shape.step(toward: Self.idle, limits: limits, forcing: .none, reduceMotion: reduceMotion)
                monotone =
                    monotone && shape.volume <= previous.volume
                    && Self.approaches(0, from: previous.length, to: shape.length)
                    && Self.approaches(0, from: previous.halfHeight, to: shape.halfHeight)
                previous = shape
                belowOne = belowOne || shape.volume < 1
                if shape.volume > 0 {
                    worstProportion = max(worstProportion, abs(shape.length / shape.halfHeight / proportion - 1))
                }
            }

            #expect(belowOne, "\(pose.length) pt")
            #expect(shape.volume == 0, "\(pose.length) pt")
            #expect(monotone, "\(pose.length) pt")
            #expect(worstProportion <= 1e-12, "\(pose.length) pt")
        }
    }

    /// An empty body has no shape to remember: it grows out of the notch already in its pose, and an
    /// arrival kick handed to it while empty becomes the first motion of the mercury that emerges.
    @Test func anEmptyBodyEmergesInItsPose() {
        let proportion = log(160 / 11.5)
        var plain = Shape()
        plain.step(toward: Self.speaking, limits: Self.island, forcing: .none, reduceMotion: false)

        var kicked = Shape()
        kicked.apply(Shape.Impulse(aspectRate: -1.2, swayRate: 60))
        var lowest = Double.infinity
        var furthest = 0.0
        for _ in 0..<360 {
            kicked.step(toward: Self.speaking, limits: Self.island, forcing: .none, reduceMotion: false)
            lowest = min(lowest, Self.aspect(kicked))
            furthest = max(furthest, kicked.sway)
        }

        #expect(plain.volume > 0)
        #expect(abs(Self.aspect(plain) - proportion) <= 1e-12)
        #expect(lowest < proportion - 0.02)
        #expect(furthest > 2)
        #expect(abs(Self.aspect(kicked) - proportion) < 0.01)
        #expect(abs(kicked.sway) < 0.1)
    }

    /// The two ways an equilibrium moves. A pose step is a new reference configuration that loads the
    /// arm, so it snaps past; a force reaching the same equilibrium leaves the arm alone, so it creeps.
    /// On the listening body, whose track leaves the sway its whole wall.
    @Test func aPoseStepSnapsWhereAForceCreeps() {
        var posed = Shape()
        posed.reset(to: Self.listening, limits: Self.island)
        var pushed = Shape()
        pushed.reset(to: Self.listening, limits: Self.island)
        // `−0.03 · (−10 000) / Ω∞²` with `Ω∞² = 100`: the same 3 pt the pose asks for.
        let push = Shape.Forcing(tangentialAcceleration: -10_000)
        var posedPeak = 0.0
        var pushedPeak = 0.0
        for _ in 0..<480 {
            posed.step(
                toward: Self.target(length: 130, halfHeight: 8, sway: 3),
                limits: Self.island,
                forcing: .none,
                reduceMotion: false
            )
            pushed.step(toward: Self.listening, limits: Self.island, forcing: push, reduceMotion: false)
            posedPeak = max(posedPeak, posed.sway)
            pushedPeak = max(pushedPeak, pushed.sway)
        }

        #expect(posedPeak >= 1.4 * 3)
        #expect(pushedPeak <= 1.3 * 3)
        #expect(abs(posed.sway - 3) < 1e-2)
        #expect(abs(pushed.sway - 3) < 1e-2)
    }

    /// A frame acceleration shifts the rubbery equilibrium by exactly `f / Ω∞²`, is clamped beyond
    /// ±40 000 pt/s², moves no mass, and leaves nothing behind once it stops. The track and the wall
    /// are far enough away that only the forcing places the body.
    @Test func frameForcingIsAnExactEquilibriumShift() {
        let roomy = Shape.Limits(maxLength: 400, maxHalfHeight: 17, maxSway: 100)
        let proportion = log(160 / 11.5)
        // Sway `−0.03 a / Ω∞²` with `Ω∞² = 10²`; aspect `−1.4e-3 a / Ω∞²` with `Ω∞² = 13.8²`.
        let swayShift = -0.03 * 10_000 / 100
        let aspectShift = -1.4e-3 * 10_000 / (13.8 * 13.8)
        let clampedSwayShift = -0.03 * 40_000 / 100
        var shape = Shape()
        shape.reset(to: Self.speaking, limits: roomy)

        let push = Shape.Forcing(tangentialAcceleration: 10_000, normalAcceleration: 10_000)
        for _ in 0..<1_200 {
            shape.step(toward: Self.speaking, limits: roomy, forcing: push, reduceMotion: false)
        }
        #expect(abs(shape.sway - swayShift) <= 1e-6)
        #expect(abs(Self.aspect(shape) - (proportion + aspectShift)) <= 1e-6)
        #expect(shape.volume == 1_840)

        let shove = Shape.Forcing(tangentialAcceleration: 1e6)
        for _ in 0..<1_200 {
            shape.step(toward: Self.speaking, limits: roomy, forcing: shove, reduceMotion: false)
        }
        #expect(abs(shape.sway - clampedSwayShift) <= 1e-6)

        for _ in 0..<1_200 {
            shape.step(toward: Self.speaking, limits: roomy, forcing: .none, reduceMotion: false)
        }
        #expect(abs(shape.sway) <= 1e-6)
        #expect(abs(Self.aspect(shape) - proportion) <= 1e-6)
    }

    /// No clock and no hidden state: a body that took 600 substeps is the same body whether they ran
    /// in one loop or in six batches of 100, with targets, kicks and forcing keyed to the substep.
    @Test func steppingIsBatchIndependent() {
        var single = Shape()
        for index in 0..<600 {
            Self.scripted(&single, at: index)
        }
        var batched = Shape()
        for batch in 0..<6 {
            batched = Self.advanced(batched, from: batch * 100, count: 100)
        }

        #expect(single == batched)
    }

    // MARK: - Helpers

    private static func target(
        length: Double,
        halfHeight: Double,
        sway: Double = 0,
        skew: Double = 0,
        neck: Double = 0
    ) -> Shape.Target {
        Shape.Target(length: length, halfHeight: halfHeight, sway: sway, skew: skew, neck: neck)
    }

    private static func aspect(_ shape: Shape) -> Double {
        log(shape.length / shape.halfHeight)
    }

    /// The five coordinates a reader sees: length, half-height, sway, skew and neck.
    private static func coordinates(of target: Shape.Target) -> [Double] {
        [target.length, target.halfHeight, target.sway, target.skew, target.neck]
    }

    private static func coordinates(of shape: Shape) -> [Double] {
        [shape.length, shape.halfHeight, shape.sway, shape.skew, shape.neck]
    }

    /// Whether a substep from `previous` to `current` came no further from `goal` and stayed on its
    /// side of it.
    private static func approaches(_ goal: Double, from previous: Double, to current: Double) -> Bool {
        abs(goal - current) <= abs(goal - previous) && (goal - current) * (goal - previous) >= 0
    }

    /// Whether every coordinate of a substep from `previous` to `current` approaches its `goal`.
    private static func approaches(_ goal: [Double], from previous: [Double], to current: [Double]) -> Bool {
        goal.indices.allSatisfy { approaches(goal[$0], from: previous[$0], to: current[$0]) }
    }

    /// Turning points of a sampled trajectory.
    private static func extremumCount(_ values: [Double]) -> Int {
        var count = 0
        for index in 1..<(values.count - 1)
        where (values[index] - values[index - 1]) * (values[index + 1] - values[index]) < 0 {
            count += 1
        }
        return count
    }

    /// Emerge into speech, lurch with a kick at 1.25 s, then swallow, under a swinging frame.
    private static func scripted(_ shape: inout Shape, at index: Int) {
        if index == 150 {
            shape.apply(Shape.Impulse(swayRate: 60))
        }
        let pose: Shape.Target =
            switch index {
            case ..<150: speaking
            case ..<400: target(length: 78, halfHeight: 11, sway: 8, skew: 0.4)
            default: idle
            }
        let forcing = Shape.Forcing(tangentialAcceleration: 2_000 * sin(Double(index) / 9))
        shape.step(toward: pose, limits: island, forcing: forcing, reduceMotion: false)
    }

    private static func advanced(_ shape: Shape, from start: Int, count: Int) -> Shape {
        var copy = shape
        for index in start..<(start + count) {
            scripted(&copy, at: index)
        }
        return copy
    }

    /// A body on `spine` may grow as long as the spine, as the ribbon's drive lets it.
    private static func limits(along spine: MercurySpine) -> Shape.Limits {
        Shape.Limits(
            maxLength: spine.length,
            maxHalfHeight: Double(MercuryMetrics.maxHalfHeight),
            maxSway: MercuryMetrics.maxSway
        )
    }

    /// Every rung of the pose ladder as the simulation hands it to the body shape: idle, warming,
    /// listening, speaking, processing and the three outcome gestures. On the collar `regions`
    /// describe, speaking also comes with the pointer in the menu-bar band and over a full-screen app.
    @MainActor
    private static func ladder(regions: MercurySpine.Regions?) -> [Shape.Target] {
        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        let speaking = live(levels: [0.5, 0.5])
        var poses = [
            RecordingOverlayModel(), live(levels: [], capturing: false), live(levels: []), speaking, processing,
            outcome(.copiedOnly(reason: "target_terminal")), outcome(.insertFailed(reason: "no focused element")),
            outcome(.error(.inferenceFailed)),
        ].map { MercuryPose.target(for: $0, regions: regions) }
        if let regions {
            poses += [MercuryPoseContext(pointerInBand: true), MercuryPoseContext(fullScreen: true)].map {
                MercuryPose.target(for: speaking, regions: regions, context: $0)
            }
        }
        return poses.map { pose in
            Shape.Target(
                length: Double(pose.length),
                halfHeight: Double(pose.halfHeight),
                sway: Double(pose.lateralOffset),
                skew: Double(pose.skew),
                neck: Double(pose.neck)
            )
        }
    }

    /// A recording session's model, live once `capturing`, with `levels` recorded.
    @MainActor
    private static func live(levels: [Float], capturing: Bool = true) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(capturing)
        for level in levels {
            model.record(level)
        }
        return model
    }

    /// A model holding the outcome `state` presents, as the controller latches it.
    @MainActor
    private static func outcome(_ state: SessionState) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(state)
        if let outcome = RecordingOverlayOutcome(state: state) {
            model.present(outcome)
        } else {
            Issue.record("terminal state must produce an overlay outcome")
        }
        return model
    }
}
