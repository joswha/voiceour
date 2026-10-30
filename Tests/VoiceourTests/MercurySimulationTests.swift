import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// The body's law, held to the properties the design depends on: it replays, it cannot
/// leave the island, nor lose its shape against its own height wall, its two edges are not
/// mirrors of each other, Reduce Motion stops the shimmer without stopping the information,
/// and the gel body emerges, wobbles, leans, lopsides and pinches the way the pose ladder
/// asks — on the collar's ladder too.
@MainActor
struct MercurySimulationTests {
    /// The balance the calibration solves for this law, rounded, and fixed here so the law's
    /// own tests do not wait on the solve.
    private static let gains = MercuryGains(drive: 0.79, snake: 0.025)

    private static func model(_ levels: [Float], live: Bool = true) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(live)
        for level in levels {
            model.record(level)
        }
        return model
    }

    private static func drive(
        _ levels: [Float],
        live: Bool = true,
        reduceMotion: Bool = false
    ) -> MercurySimulation.Drive {
        let model = model(levels, live: live)
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: reduceMotion
        )
    }

    /// A model holding the outcome `state` presents, as the controller latches it.
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

    private static let speaking = MercurySpeechMeter.syllable
    private static let quiet = MercurySpeechMeter.quietRoom
    private static let silence = [Float](repeating: 0, count: 11)

    /// Counter-based noise means the state after N substeps cannot depend on how those
    /// substeps were batched. That is what lets a harness frame be pinned to a step index
    /// and a 24 Hz machine draw the same body a 120 Hz one does. Everything the body shape
    /// reads — an emergence, a lean, a moving panel and an arrival kick — is held to it too.
    @Test func advancingIsReplayableAndBatchIndependent() {
        var drive = Self.drive(Self.speaking)
        drive.lean = 0.5
        drive.forcing = MercuryBodyShape.Forcing(tangentialAcceleration: 1_500, normalAcceleration: -800)
        drive.arrival = MercuryArrival(id: 1, swayRate: 60, aspectRate: -1.2)

        let first = MercurySimulation(seed: 7, gains: Self.gains)
        let second = MercurySimulation(seed: 7, gains: Self.gains)
        let batched = MercurySimulation(seed: 7, gains: Self.gains)
        for simulation in [first, second, batched] {
            simulation.reset(to: drive, emerging: true)
        }

        first.advance(steps: 600, drive: drive)
        second.advance(steps: 600, drive: drive)
        for _ in 0..<6 {
            batched.advance(steps: 100, drive: drive)
        }

        #expect(first.geometry == second.geometry)
        #expect(first.geometry == batched.geometry)
    }

    /// A different world is a different body. Without this the "new world per session"
    /// decision would be decoration.
    @Test func differentSeedsProduceDifferentBodies() {
        let drive = Self.drive(Self.speaking)
        let first = MercurySimulation(seed: 7, gains: Self.gains)
        let second = MercurySimulation(seed: 8, gains: Self.gains)
        first.reset(to: drive)
        second.reset(to: drive)
        first.advance(steps: 300, drive: drive)
        second.advance(steps: 300, drive: drive)

        #expect(first.geometry.top != second.geometry.top)
    }

    /// The containment gauge is a proof, not a hope: `Theta` bounds `|theta|` exactly, so
    /// no drive can push the drawn body past the island. Adversarial inputs included,
    /// because a meter buffer is whatever the room hands it.
    @Test(arguments: [
        [Float](repeating: 0, count: 11),
        [Float](repeating: 1, count: 11),
        [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
        [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0],
        [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    ])
    func theBodyNeverLeavesTheIsland(levels: [Float]) {
        let drive = Self.drive(levels)
        for seed in [UInt64(1), 7, 0x5155_4943_4B53_4C56] {
            let simulation = MercurySimulation(seed: seed, gains: Self.gains)
            simulation.reset(to: drive)
            for _ in 0..<900 {
                simulation.advance(steps: 1, drive: drive)
                let geometry = simulation.geometry
                #expect(geometry.length <= MercuryMetrics.maxLength)
                #expect(Double(geometry.top.max() ?? 0) <= Double(MercuryMetrics.maxHalfHeight))
                #expect(Double(geometry.bottom.min() ?? 0) >= -Double(MercuryMetrics.maxHalfHeight))
            }
        }
    }

    /// A skew lifts the envelope's thick end above its centre, and a mean envelope past the
    /// ceiling is beyond anything the gauge can scale back. The deepest body the body shape
    /// allows, at the widest skew either way and under the loudest voice, still draws inside
    /// the island: the crest headroom covers the lift.
    @Test func theWidestSkewOnTheDeepestBodyStaysInsideTheIsland() {
        var drive = Self.drive([Float](repeating: 1, count: 11))
        for skew: CGFloat in [0.6, -0.6] {
            drive.pose = MercuryPose(
                length: MercuryMetrics.maxLength,
                halfHeight: MercuryMetrics.maxHalfHeight,
                lateralOffset: 0,
                skew: skew,
                driveScale: 1,
                gesture: nil
            )
            let simulation = MercurySimulation(seed: 1, gains: Self.gains)
            simulation.reset(to: drive)
            var highest = Double(simulation.geometry.top.max() ?? 0)
            var lowest = Double(simulation.geometry.bottom.min() ?? 0)
            for _ in 0..<240 {
                simulation.advance(steps: 1, drive: drive)
                highest = Swift.max(highest, Double(simulation.geometry.top.max() ?? 0))
                lowest = Swift.min(lowest, Double(simulation.geometry.bottom.min() ?? 0))
            }
            #expect(highest <= Double(MercuryMetrics.maxHalfHeight), "skew \(skew)")
            #expect(lowest >= -Double(MercuryMetrics.maxHalfHeight), "skew \(skew)")
        }
    }

    /// A speaking body collapsing into processing overshoots its aspect into its height wall,
    /// which stands a crest headroom under the ceiling, so the body meets it with its crests.
    /// Held to the ceiling itself, the budget at its centre reached zero and the containment
    /// gauge erased every mode: the edges fell onto the bare capsule `H0·G(a)` and grew their
    /// shape back a substep later.
    ///
    /// Over three seconds of speaking, processing and the error collapse, the edges' departure
    /// from that capsule never halves in a substep while the pose holds, and the body reaches
    /// its wall without passing it. The departure counts the collapse's pinch along with the
    /// crests, since both are shape the capsule lacks. The mirror asymmetry `top + bottom` would
    /// be the wrong measure: a free body takes it near zero whenever a crest crosses the spine.
    @Test func aBodyAtItsHeightWallKeepsItsShape() {
        let model = Self.model(Self.speaking)
        let speaking = MercurySimulation.Drive.target(for: model, reduceMotion: false)
        model.update(.transcribing)
        let processing = MercurySimulation.Drive.target(for: model, reduceMotion: false)
        let collapse = MercurySimulation.Drive.target(for: Self.outcome(.error(.inferenceFailed)), reduceMotion: false)

        let simulation = MercurySimulation(seed: 7, gains: Self.gains)
        simulation.reset(to: speaking)
        var deepest = 0.0
        var sharpestFall = (share: 1.0, at: "")
        for (name, drive) in [("speaking", speaking), ("processing", processing), ("collapse", collapse)] {
            var previous: Double?
            for step in 1...120 {
                simulation.advance(steps: 1, drive: drive)
                let geometry = simulation.geometry
                deepest = Swift.max(deepest, Double(geometry.halfHeight))
                let departure = Self.capsuleDeparture(geometry)
                if let previous, departure / previous < sharpestFall.share {
                    sharpestFall = (departure / previous, "\(name) +\(step)")
                }
                previous = departure
            }
        }
        #expect(sharpestFall.share >= 0.5, "the shape fell to \(sharpestFall.share) of itself at \(sharpestFall.at)")
        let wall = MercurySimulation.maxBodyHalfHeight
        #expect(deepest <= wall, "the body drew \(deepest) pt deep against its \(wall) pt wall")
        #expect(deepest > wall - 1e-9, "the overshoot stopped at \(deepest) pt, short of the \(wall) pt wall")
    }

    /// A pill is exactly +1. The two edges must be independent, which is what the
    /// contact-line family entering them with opposite sign is for.
    ///
    /// One frame of a moving body is one sample of a random shape, and single frames land
    /// anywhere from −0.9 to +0.9, so the property is the average over five seconds of
    /// motion. Speech's smooth envelope puts most of its energy in the fundamental, whose
    /// thickness wave reaches both edges nearly in phase, so the speaking body averages
    /// about 0.4 and the listening body about zero; a mirrored body averages near 1. Without
    /// the contact line the speaking body is more mirrored still.
    @Test func theTwoEdgesAreNotMirrors() {
        for levels in [Self.speaking, Self.quiet] {
            let drive = Self.drive(levels)
            for seed in [UInt64(7), 11, 13] {
                let averaged = Self.averagedMirrorCorrelation(drive, seed: seed, gains: Self.gains)
                #expect(averaged < 0.6, "seed \(seed): \(averaged)")
            }
        }
        let speaking = Self.drive(Self.speaking)
        let unsnaked = MercuryGains(drive: Self.gains.drive, snake: 0)
        #expect(
            Self.averagedMirrorCorrelation(speaking, seed: 11, gains: Self.gains)
                < Self.averagedMirrorCorrelation(speaking, seed: 11, gains: unsnaked)
        )
    }

    /// Warming and working disconnect the voice entirely, so only the body's own
    /// autonomous life is left. Even there it must not fit an ellipse: the two families'
    /// shimmer is equal, so averaged over its motion the correlation sits near zero.
    @Test func theStillPosesAreNotMirrorsEither() {
        let warming = MercurySimulation.Drive(
            pose: MercuryPose.target(for: Self.model(Self.speaking, live: false)),
            samples: Self.speaking,
            reduceMotion: false
        )
        let working = MercurySimulation.Drive(
            pose: MercuryPose.target(
                for: { () -> RecordingOverlayModel in
                    let model = RecordingOverlayModel()
                    model.update(.transcribing)
                    return model
                }()),
            samples: Self.silence,
            reduceMotion: false
        )
        for drive in [warming, working] {
            for seed in [UInt64(13), 7, 11] {
                let averaged = Self.averagedMirrorCorrelation(drive, seed: seed, gains: Self.gains)
                #expect(averaged < 0.6, "seed \(seed): \(averaged)")
            }
        }
    }

    /// Reduce Motion stops the shimmer and nothing else. A silent drive holds the body
    /// perfectly still — including the rest asymmetry, which must not decay to the
    /// mirror-symmetric capsule — and speech still moves it.
    @Test func reduceMotionStopsDecorationButNotInformation() {
        let silent = Self.drive(Self.silence, reduceMotion: true)
        let still = MercurySimulation(seed: 17, gains: Self.gains)
        still.reset(to: silent)
        let start = still.geometry
        still.advance(steps: 300, drive: silent)
        #expect(still.geometry.top == start.top)
        #expect(still.geometry.bottom == start.bottom)
        #expect(still.geometry.lateralOffset == start.lateralOffset)
        // Never zero: zero is the mirror-symmetric minimiser, which is a capsule.
        #expect(Self.mirrorCorrelation(still.geometry) < 0.8)

        let speaking = Self.drive(Self.speaking, reduceMotion: true)
        let moving = MercurySimulation(seed: 17, gains: Self.gains)
        moving.reset(to: speaking)
        let before = moving.geometry
        moving.advance(steps: 60, drive: speaking)
        #expect(moving.geometry.top != before.top)
    }

    /// Lurch and collapse are transition gestures, not merely different settled poses.
    /// Start two bodies from the same pose with no gesture; only the one whose gesture
    /// latches may receive the one-shot mode impulse.
    @Test func outcomeImpulsesFireOnGestureEntry() {
        for state in [
            SessionState.insertFailed(reason: "no focused element"),
            .error(.inferenceFailed),
        ] {
            let model = Self.outcome(state)
            let transition = MercurySimulation.Drive(
                pose: MercuryPose.target(for: model),
                samples: model.samples,
                reduceMotion: true
            )
            var neutralPose = transition.pose
            neutralPose.gesture = nil
            let neutral = MercurySimulation.Drive(
                pose: neutralPose,
                samples: transition.samples,
                reduceMotion: true
            )
            let impulsed = MercurySimulation(seed: 23, gains: Self.gains)
            let control = MercurySimulation(seed: 23, gains: Self.gains)
            impulsed.reset(to: neutral)
            control.reset(to: neutral)
            impulsed.advance(steps: 2, drive: transition)
            control.advance(steps: 2, drive: neutral)

            #expect(impulsed.geometry.top != control.geometry.top)
            #expect(impulsed.geometry.bottom != control.geometry.bottom)
        }
    }

    /// The pose ladder is the only sighted channel between session states, so warm-up
    /// must differ from silent listening in kind — a compact bead versus a long lens —
    /// rather than by a few points of length, and speech must widen the listening lip in
    /// both directions: a longer body and a deeper one, not merely a busier one.
    @Test func eachPoseIsADistinctBody() {
        let poses = [
            MercuryPose.target(for: Self.model(Self.speaking, live: false)),
            MercuryPose.target(for: Self.model(Self.quiet)),
            MercuryPose.target(for: Self.model(Self.speaking)),
        ]
        let lengths = poses.map(\.length)
        #expect(Set(lengths).count == lengths.count)
        #expect(poses[1].length - poses[0].length >= 60)
        #expect(poses[0].length / (2 * poses[0].halfHeight) <= 4.5)
        #expect(poses[1].length / (2 * poses[1].halfHeight) >= 7.5)
        #expect(poses[2].length > poses[1].length)
        #expect(poses[2].halfHeight > poses[1].halfHeight)
        for pose in poses {
            #expect(pose.length <= MercuryMetrics.maxLength)
            #expect(pose.halfHeight <= MercuryMetrics.maxHalfHeight)
        }
    }

    /// A body shown afresh grows out of the notch or the top edge: from nothing to its pose
    /// within 0.6 s. Its volume is mercury flowing out through the notch, so it rises
    /// steadily and never past the pose, where an overshoot would be mercury flowing back.
    @Test func anEmergingBodyGrowsFromNothingIntoItsPose() {
        let drive = Self.drive(Self.speaking)
        let filled = Double(drive.pose.length * drive.pose.halfHeight)
        let simulation = MercurySimulation(seed: 3, gains: Self.gains)
        simulation.reset(to: drive, emerging: true)
        #expect(simulation.geometry.length == 0)
        #expect(simulation.geometry.top.allSatisfy { $0 == 0 })

        var previous = 0.0
        var steady = true
        for _ in 0..<72 {
            simulation.advance(steps: 1, drive: drive)
            let geometry = simulation.geometry
            let volume = Double(geometry.length * geometry.halfHeight)
            steady = steady && volume >= previous && volume <= filled
            previous = volume
        }
        #expect(steady)
        let length = Double(simulation.geometry.length)
        #expect(abs(length - Double(drive.pose.length)) <= 0.02 * Double(drive.pose.length), "\(length) pt")
    }

    /// An outcome gesture lands like a knock on a jelly: its kick sets the body's
    /// proportions ringing, turning back at least twice before they settle on the pose.
    /// Reduce Motion takes the same body to the same pose once, without turning back.
    @Test func anOutcomeGestureWobblesLikeAJelly() {
        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        for state in [
            SessionState.copiedOnly(reason: "target_terminal"),
            .insertFailed(reason: "no focused element"),
            .error(.inferenceFailed),
        ] {
            let model = Self.outcome(state)
            for reduceMotion in [false, true] {
                let before = MercurySimulation.Drive(
                    pose: MercuryPose.target(for: processing),
                    samples: processing.samples,
                    reduceMotion: reduceMotion
                )
                let after = MercurySimulation.Drive(
                    pose: MercuryPose.target(for: model),
                    samples: model.samples,
                    reduceMotion: reduceMotion
                )
                let simulation = MercurySimulation(seed: 5, gains: Self.gains)
                simulation.reset(to: before)
                var aspects: [Double] = []
                for _ in 0..<240 {
                    simulation.advance(steps: 1, drive: after)
                    let geometry = simulation.geometry
                    aspects.append(log(Double(geometry.length / geometry.halfHeight)))
                }
                let turns = Self.extremumCount(aspects)
                if reduceMotion {
                    #expect(turns == 0, "\(state) under Reduce Motion turned \(turns) times")
                } else {
                    #expect(turns >= 2, "\(state) turned \(turns) times")
                }
            }
        }
    }

    /// The insert-failed lurch's skew 0.4 is a lopsided body: more than 60 % of what it
    /// draws lies on one side of its middle. The drawn area is the span's thickness,
    /// `top − bottom`, integrated along the body, plus the round ends the field closes it
    /// with: half-discs across the end stations' thickness. The body's own rest asymmetry
    /// leans a percent or two either way, so each body is measured skewed both ways round
    /// and the two shares averaged, which leaves the skew's own.
    @Test func aSkewLeansTheBodysAreaToOneEnd() {
        let lurch = MercuryPose.target(for: Self.outcome(.insertFailed(reason: "no focused element")))
        #expect(lurch.skew == 0.4)
        for seed in [UInt64(1), 4, 7] {
            var shares: [Double] = []
            for skew in [lurch.skew, -lurch.skew] {
                var pose = lurch
                pose.skew = skew
                let drive = MercurySimulation.Drive(pose: pose, samples: Self.silence, reduceMotion: true)
                let simulation = MercurySimulation(seed: seed, gains: Self.gains)
                simulation.reset(to: drive)
                simulation.advance(steps: 120, drive: drive)
                let halves = Self.drawnHalves(simulation.geometry)
                shares.append((skew > 0 ? halves.trailing : halves.leading) / (halves.leading + halves.trailing))
            }
            let share = (shares[0] + shares[1]) / 2
            #expect(share > 0.6, "seed \(seed): \(share)")
        }
    }

    /// The error collapse's neck 0.7 pinches the waist to under 40 % of the shoulders'
    /// thickness and never through it: two drips joined by a thread, never two bodies.
    @Test func aNeckPinchesTheWaistWithoutCuttingIt() {
        let collapse = MercuryPose.target(for: Self.outcome(.error(.inferenceFailed)))
        #expect(collapse.neck == 0.7)
        let middle = MercuryMetrics.columns / 2
        for reduceMotion in [false, true] {
            let drive = MercurySimulation.Drive(pose: collapse, samples: Self.silence, reduceMotion: reduceMotion)
            let simulation = MercurySimulation(seed: 19, gains: Self.gains)
            simulation.reset(to: drive)
            var widestWaist = 0.0
            var thinnestWaist = Double.infinity
            for _ in 0..<60 {
                simulation.advance(steps: 4, drive: drive)
                let geometry = simulation.geometry
                let thickness = zip(geometry.top, geometry.bottom).map { Double($0 - $1) }
                let waist = thickness[middle]
                widestWaist = Swift.max(widestWaist, waist / (thickness.max() ?? 1))
                thinnestWaist = Swift.min(thinnestWaist, waist)
            }
            #expect(widestWaist < 0.4, "Reduce Motion \(reduceMotion): \(widestWaist)")
            #expect(thinnestWaist > 0, "Reduce Motion \(reduceMotion)")
        }
    }

    /// A lean of ±1 settles a listening body `leanSway` along its spine, with the jelly's wobble on
    /// the way there, and a lean far past the range stops it at the sway wall, never beyond it. A
    /// speaking body, 160 of the island's 168 pt track, stops where its end meets the track's.
    @Test func aLeanSettlesTheSwayInsideItsWall() {
        let listening = Self.drive(Self.quiet)
        let speaking = Self.drive(Self.speaking)
        let trackEnd = Double(MercuryMetrics.maxLength) / 2
        for (base, lean, settled) in [
            (listening, 1.0, MercuryMetrics.leanSway),
            (listening, -1.0, -MercuryMetrics.leanSway),
            (listening, 4.0, MercuryMetrics.maxSway),
            (speaking, 1.0, trackEnd - Double(speaking.pose.length) / 2),
        ] {
            var drive = base
            drive.lean = lean
            let simulation = MercurySimulation(seed: 9, gains: Self.gains)
            simulation.reset(to: base)
            var furthest = 0.0
            var furthestEnd = 0.0
            for _ in 0..<600 {
                simulation.advance(steps: 1, drive: drive)
                let geometry = simulation.geometry
                let offset = abs(Double(geometry.lateralOffset))
                furthest = Swift.max(furthest, offset)
                furthestEnd = Swift.max(furthestEnd, offset + Double(geometry.length) / 2)
            }
            let sway = Double(simulation.geometry.lateralOffset)
            #expect(abs(sway - settled) < 0.01, "lean \(lean) settled at \(sway) pt")
            #expect(furthest <= MercuryMetrics.maxSway, "lean \(lean) reached \(furthest) pt")
            #expect(furthestEnd <= trackEnd, "lean \(lean) put an end \(furthestEnd) pt from the middle")
        }
    }

    /// An arrival kicks once per token. The conductor hands over the same token with every
    /// frame of an emergence, which must be one kick; only a new token kicks again.
    @Test func anArrivalKicksOncePerToken() {
        let speaking = Self.drive(Self.speaking)
        var arriving = speaking
        arriving.arrival = MercuryArrival(id: 1, swayRate: 60, aspectRate: -1.2)
        let resent = MercurySimulation(seed: 31, gains: Self.gains)
        let once = MercurySimulation(seed: 31, gains: Self.gains)
        let never = MercurySimulation(seed: 31, gains: Self.gains)
        for simulation in [resent, once, never] {
            simulation.reset(to: speaking)
        }
        resent.advance(steps: 1, drive: arriving)
        once.advance(steps: 1, drive: arriving)
        never.advance(steps: 1, drive: speaking)
        for _ in 0..<60 {
            resent.advance(steps: 1, drive: arriving)
            once.advance(steps: 1, drive: speaking)
            never.advance(steps: 1, drive: speaking)
        }
        #expect(resent.geometry == once.geometry)
        #expect(once.geometry.lateralOffset != never.geometry.lateralOffset)

        var next = arriving
        next.arrival?.id = 2
        resent.advance(steps: 1, drive: next)
        once.advance(steps: 1, drive: arriving)
        #expect(resent.geometry.lateralOffset != once.geometry.lateralOffset)
    }

    /// Tokens only grow, so the body keeps the highest it has applied rather than the last it
    /// saw: a hand-over that interleaves an older token after a newer one, 1, 2, 1, is two
    /// kicks, not three. A reset forgets them, and the body takes its next token afresh.
    @Test func anOlderArrivalTokenNeverKicksAgain() {
        let speaking = Self.drive(Self.speaking)
        func hand(_ ids: [Int?], to simulation: MercurySimulation) {
            for id in ids {
                var drive = speaking
                drive.arrival = id.map { MercuryArrival(id: $0, swayRate: 60, aspectRate: -1.2) }
                simulation.advance(steps: 1, drive: drive)
            }
            simulation.advance(steps: 60, drive: speaking)
        }
        func body(handedOver ids: [Int?]) -> MercurySimulation {
            let simulation = MercurySimulation(seed: 31, gains: Self.gains)
            simulation.reset(to: speaking)
            hand(ids, to: simulation)
            return simulation
        }
        let twice = body(handedOver: [1, 2, nil])
        #expect(body(handedOver: [1, 2, 1]).geometry == twice.geometry)
        #expect(body(handedOver: [1, 2, 3]).geometry != twice.geometry)

        let renewed = body(handedOver: [2])
        renewed.reset(to: speaking)
        hand([1], to: renewed)
        #expect(renewed.geometry == body(handedOver: [1]).geometry)
        #expect(renewed.geometry != body(handedOver: [nil]).geometry)
    }

    /// The collar's ladder climbs the housing. Speaking reaches nine tenths up both walls
    /// unless the pointer is in the menu-bar band; over a full-screen app it also runs out
    /// along the ears; and no pose is longer than the spine. The drive the ribbon builds
    /// lets a collar body grow as long as its spine, and keeps the island's at 168 pt.
    @Test func theCollarLadderClimbsTheHousing() throws {
        let layout = try #require(
            RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32), bandHeight: 33)
        )
        let regions = layout.spine.regions
        let speaking = Self.model(Self.speaking)
        func length(_ context: MercuryPoseContext) -> Double {
            Double(MercuryPose.target(for: speaking, regions: regions, context: context).length)
        }
        let chin = regions.bottom + 2 * regions.corner
        let open = length(MercuryPoseContext())
        let retracted = length(MercuryPoseContext(pointerInBand: true))
        let spread = length(MercuryPoseContext(fullScreen: true))
        #expect(abs(open - (chin + 1.8 * regions.wall)) < 1e-9)
        #expect(open > chin)
        #expect(abs(retracted - chin) < 1e-9)
        #expect(abs(spread - (open + 2 * regions.fillet + 1.4 * regions.ear)) < 1e-9)
        #expect(length(MercuryPoseContext(pointerInBand: true, fullScreen: true)) == retracted)

        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        let models = [
            Self.model(Self.speaking, live: false), Self.model(Self.quiet), speaking, processing,
            Self.outcome(.copiedOnly(reason: "target_terminal")),
            Self.outcome(.insertFailed(reason: "no focused element")),
            Self.outcome(.error(.inferenceFailed)),
        ]
        for model in models {
            for context in [
                MercuryPoseContext(), MercuryPoseContext(pointerInBand: true),
                MercuryPoseContext(fullScreen: true), MercuryPoseContext(pointerInBand: true, fullScreen: true),
            ] {
                let pose = MercuryPose.target(for: model, regions: regions, context: context)
                #expect(pose.length > 0)
                #expect(Double(pose.length) <= layout.spine.length)
            }
        }

        speaking.update(layout: layout)
        let collared = MercurySimulation.Drive.target(for: speaking, reduceMotion: false)
        #expect(Double(collared.pose.length) == open)
        #expect(collared.maxLength == layout.spine.length)
        let island = MercurySimulation.Drive.target(for: Self.model(Self.speaking), reduceMotion: false)
        #expect(island.pose == MercuryPose.target(for: Self.model(Self.speaking)))
        #expect(island.maxLength == Double(MercuryMetrics.maxLength))
    }

    /// Pearson correlation of the top edge against the negated bottom edge, with the
    /// shared even envelope removed. Exactly what a capsule scores +1 on.
    static func mirrorCorrelation(_ geometry: MercurySimulation.Geometry) -> Double {
        let columns = MercuryMetrics.columns
        var upper: [Double] = []
        var lower: [Double] = []
        upper.reserveCapacity(columns + 1)
        lower.reserveCapacity(columns + 1)
        for station in 0...columns {
            let position = 2 * Double(station) / Double(columns) - 1
            let envelope =
                Double(geometry.halfHeight) * (1 - (1 - MercuryMetrics.gEnd) * position * position)
            upper.append(Double(geometry.top[station]) - envelope)
            lower.append(-Double(geometry.bottom[station]) - envelope)
        }
        return MercuryCalibration.correlation(upper, lower)
    }

    /// How far the drawn edges depart from the bare capsule `H0·G(a)`, in nats: `ln(top / H0 G)`
    /// and `ln(−bottom / H0 G)`, rms over both edges and every station. An unshaped body with
    /// every mode erased scores nothing, to the edges' float precision.
    private static func capsuleDeparture(_ geometry: MercurySimulation.Geometry) -> Double {
        let columns = MercuryMetrics.columns
        var total = 0.0
        for station in 0...columns {
            let position = 2 * Double(station) / Double(columns) - 1
            let capsule = Double(geometry.halfHeight) * (1 - (1 - MercuryMetrics.gEnd) * position * position)
            let upper = log(Double(geometry.top[station]) / capsule)
            let lower = log(-Double(geometry.bottom[station]) / capsule)
            total += upper * upper + lower * lower
        }
        return (total / Double(2 * (columns + 1))).squareRoot()
    }

    /// ``mirrorCorrelation(_:)`` averaged over 150 frames, five seconds, of a body settled
    /// for five seconds at rest on the drive's pose.
    private static func averagedMirrorCorrelation(
        _ drive: MercurySimulation.Drive,
        seed: UInt64,
        gains: MercuryGains
    ) -> Double {
        let simulation = MercurySimulation(seed: seed, gains: gains)
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        var total = 0.0
        for _ in 0..<150 {
            simulation.advance(steps: 4, drive: drive)
            total += mirrorCorrelation(simulation.geometry)
        }
        return total / 150
    }

    /// The area the field draws on each side of the body's middle: the trapezoid integral of
    /// `top − bottom` along the span, and each end's half-disc across its end thickness.
    private static func drawnHalves(_ geometry: MercurySimulation.Geometry) -> (leading: Double, trailing: Double) {
        let columns = MercuryMetrics.columns
        let spacing = Double(geometry.length) / Double(columns)
        let thickness = zip(geometry.top, geometry.bottom).map { Double($0 - $1) }
        var leading = Double.pi / 8 * thickness[0] * thickness[0]
        var trailing = Double.pi / 8 * thickness[columns] * thickness[columns]
        for station in 0..<columns {
            let piece = (thickness[station] + thickness[station + 1]) / 2 * spacing
            if station < columns / 2 {
                leading += piece
            } else {
                trailing += piece
            }
        }
        return (leading, trailing)
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
}
