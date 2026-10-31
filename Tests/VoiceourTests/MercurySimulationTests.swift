import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Shared extremes: each stresses a different part of the body kit or motion law.
enum MercuryTuneCorner: String, CaseIterable, Sendable {
    case stock, kitMin, kitRound, slowWild, fastWild, calm, thinWild

    static let tuned = allCases.filter { $0 != .stock }

    var tune: MercuryTune {
        switch self {
        case .stock:
            return .stock
        case .kitMin:
            return MercuryTune(size: 0.85, build: 0.80, endTaper: 0.30, crownAspect: 0.60)
        case .kitRound:
            return MercuryTune(crownAspect: 1.00)
        case .slowWild:
            return MercuryTune(
                tempo: 0.70, viscosity: 0.50, shimmer: 2, reactivity: 1.50,
                slither: 2.50, morph: 0.60, drama: 3
            )
        case .fastWild:
            var tune = MercuryTuneCorner.slowWild.tune
            tune.tempo = 1.50
            tune.viscosity = 2.00
            return tune
        case .calm:
            return MercuryTune(
                tempo: 0.70, viscosity: 2.00, shimmer: 0, reactivity: 0.50,
                slither: 0.75, morph: 1.60, drama: 0.50
            )
        case .thinWild:
            var tune = MercuryTuneCorner.fastWild.tune
            tune.size = 0.85
            tune.build = 0.80
            tune.endTaper = 0.30
            tune.crownAspect = 0.60
            return tune
        }
    }
}

/// Every extreme a tune can reach: each knob alone at both ends of its range; the 16 corners of
/// the four knobs that shape the motion's course — Tempo, Viscosity, Morph and Drama — at full
/// Shimmer, Reactivity and Slither on the thinnest kit; and the shared corners.
private enum MercuryTuneExtremes {
    static let all: [MercuryTune] = alone + course + MercuryTuneCorner.tuned.map(\.tune)

    private static let alone: [MercuryTune] = {
        let knobs: [(WritableKeyPath<MercuryTune, Double>, ClosedRange<Double>)] = [
            (\.size, MercuryTune.sizeRange), (\.build, MercuryTune.buildRange),
            (\.endTaper, MercuryTune.endTaperRange), (\.crownAspect, MercuryTune.crownAspectRange),
            (\.tempo, MercuryTune.tempoRange), (\.viscosity, MercuryTune.viscosityRange),
            (\.shimmer, MercuryTune.shimmerRange), (\.reactivity, MercuryTune.reactivityRange),
            (\.slither, MercuryTune.slitherRange), (\.morph, MercuryTune.morphRange),
            (\.drama, MercuryTune.dramaRange),
        ]
        var tunes: [MercuryTune] = []
        for (knob, range) in knobs {
            for end in [range.lowerBound, range.upperBound] {
                var tune = MercuryTune.stock
                tune[keyPath: knob] = end
                if tune != .stock {
                    tunes.append(tune)
                }
            }
        }
        return tunes
    }()

    private static let course: [MercuryTune] = {
        func ends(_ range: ClosedRange<Double>) -> [Double] { [range.lowerBound, range.upperBound] }
        var tunes: [MercuryTune] = []
        for tempo in ends(MercuryTune.tempoRange) {
            for viscosity in ends(MercuryTune.viscosityRange) {
                for morph in ends(MercuryTune.morphRange) {
                    for drama in ends(MercuryTune.dramaRange) {
                        tunes.append(
                            MercuryTune(
                                size: MercuryTune.sizeRange.lowerBound,
                                build: MercuryTune.buildRange.lowerBound,
                                endTaper: MercuryTune.endTaperRange.lowerBound,
                                crownAspect: MercuryTune.crownAspectRange.lowerBound,
                                tempo: tempo,
                                viscosity: viscosity,
                                shimmer: MercuryTune.shimmerRange.upperBound,
                                reactivity: MercuryTune.reactivityRange.upperBound,
                                slither: MercuryTune.slitherRange.upperBound,
                                morph: morph,
                                drama: drama
                            )
                        )
                    }
                }
            }
        }
        return tunes
    }()
}

/// The body's law, held to the properties the design depends on: it replays, it cannot
/// leave the island, nor lose its shape against its own height wall, its two edges are not
/// mirrors of each other, Reduce Motion stops the shimmer without stopping the information,
/// and the gel body emerges, wobbles, leans, lopsides and pinches the way the pose ladder
/// asks — on the collar's ladder too. Every tune keeps those properties, and the stock tune
/// is the shipped law to the bit.
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

    /// A collar draws under its own ceiling, its spine's: no meter pushes its edges past it, and
    /// its speaking chin hangs deeper than the island's ceiling lets any body draw.
    @Test func theCollarDrawsUnderItsOwnCeiling() throws {
        let layout = try #require(
            RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32), bandHeight: 33)
        )
        let ceiling = layout.spine.maxHalfHeight
        #expect(ceiling > Double(MercuryMetrics.maxHalfHeight))
        let meters: [[Float]] = [
            Self.speaking, [Float](repeating: 1, count: 11), [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], Self.quiet,
        ]
        for levels in meters {
            let model = Self.model(levels)
            model.update(layout: layout)
            let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
            #expect(drive.maxHalfHeight == ceiling)
            let simulation = MercurySimulation(seed: 7, gains: Self.gains)
            simulation.reset(to: drive)
            var deepest = 0.0
            for _ in 0..<600 {
                simulation.advance(steps: 1, drive: drive)
                let geometry = simulation.geometry
                let top = Double(geometry.top.max() ?? 0)
                #expect(top <= ceiling)
                #expect(Double(geometry.bottom.min() ?? 0) >= -ceiling)
                deepest = Swift.max(deepest, top)
            }
            if levels == Self.speaking {
                #expect(deepest > Double(MercuryMetrics.maxHalfHeight), "the speaking chin reached \(deepest) pt")
            }
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
        let wall = MercurySimulation.maxBodyHalfHeight(ceiling: Double(MercuryMetrics.maxHalfHeight))
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

    /// The collar's ladder frames the housing. Listening and speaking both take the bottom, the
    /// corners, the walls and the fillets unless the pointer is in the menu-bar band, where they
    /// keep the chin; over a full-screen app speaking also runs out along the ears; and no pose
    /// is longer than the spine. Every rung is the island-ceiling rung deepened by the collar's
    /// ceiling over the island's, and none is held by the height wall at rest. The drive the
    /// ribbon builds lets a collar body grow as long as its spine and as deep as its ceiling, and
    /// keeps the island's at 168 × 17 pt.
    @Test func theCollarLadderClimbsTheHousing() throws {
        let layout = try #require(
            RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32), bandHeight: 33)
        )
        let regions = layout.spine.regions
        let speaking = Self.model(Self.speaking)
        let listening = Self.model(Self.quiet)
        func length(_ context: MercuryPoseContext, of model: RecordingOverlayModel? = nil) -> Double {
            Double(MercuryPose.target(for: model ?? speaking, collar: layout.spine, context: context).length)
        }
        let chin = regions.bottom + 2 * regions.corner
        let frame = chin + 2 * regions.wall + 2 * regions.fillet
        let open = length(MercuryPoseContext())
        let retracted = length(MercuryPoseContext(pointerInBand: true))
        let spread = length(MercuryPoseContext(fullScreen: true))
        #expect(abs(open - frame) < 1e-9)
        #expect(abs(length(MercuryPoseContext(), of: listening) - frame) < 1e-9)
        #expect(abs(length(MercuryPoseContext(fullScreen: true), of: listening) - frame) < 1e-9)
        #expect(abs(retracted - chin) < 1e-9)
        #expect(abs(length(MercuryPoseContext(pointerInBand: true), of: listening) - chin) < 1e-9)
        #expect(abs(spread - (frame + 1.4 * regions.ear)) < 1e-9)
        #expect(length(MercuryPoseContext(pointerInBand: true, fullScreen: true)) == retracted)

        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        let models = [
            Self.model(Self.speaking, live: false), Self.model(Self.quiet), speaking, processing,
            Self.outcome(.copiedOnly(reason: "target_terminal")),
            Self.outcome(.insertFailed(reason: "no focused element")),
            Self.outcome(.error(.inferenceFailed)),
        ]
        let wall = MercurySimulation.maxBodyHalfHeight(ceiling: layout.spine.maxHalfHeight)
        for model in models {
            for context in [
                MercuryPoseContext(), MercuryPoseContext(pointerInBand: true),
                MercuryPoseContext(fullScreen: true), MercuryPoseContext(pointerInBand: true, fullScreen: true),
            ] {
                let pose = MercuryPose.target(for: model, collar: layout.spine, context: context)
                #expect(pose.length > 0)
                #expect(Double(pose.length) <= layout.spine.length)
                #expect(Double(pose.halfHeight) <= wall)
            }
        }
        // Warming, processing and the lurch keep the island's lengths, so their depths show the
        // deepening alone.
        let deepening = CGFloat(layout.spine.maxHalfHeight) / MercuryMetrics.maxHalfHeight
        for model in [Self.model(Self.speaking, live: false), processing, models[5]] {
            let island = MercuryPose.target(for: model)
            let collared = MercuryPose.target(for: model, collar: layout.spine)
            #expect(collared.length == island.length)
            #expect(abs(collared.halfHeight - island.halfHeight * deepening) < 1e-9)
        }

        speaking.update(layout: layout)
        let collared = MercurySimulation.Drive.target(for: speaking, reduceMotion: false)
        #expect(Double(collared.pose.length) == open)
        #expect(collared.maxLength == layout.spine.length)
        #expect(collared.maxHalfHeight == layout.spine.maxHalfHeight)
        let island = MercurySimulation.Drive.target(for: Self.model(Self.speaking), reduceMotion: false)
        #expect(island.pose == MercuryPose.target(for: Self.model(Self.speaking)))
        #expect(island.maxLength == Double(MercuryMetrics.maxLength))
        #expect(island.maxHalfHeight == Double(MercuryMetrics.maxHalfHeight))
    }

    /// A body handed to another display drains before the panel moves, and one whose panel fades
    /// out swallows: both ladders ask for nothing, whatever the session holds — an outcome's
    /// gesture included — and a speaking island leaning toward its destination empties through the
    /// outflow, monotonely, before the hand-off's drain limit.
    @Test func drainingAndDismissingAskBothLaddersForNothing() throws {
        let layout = try #require(
            RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32), bandHeight: 33)
        )
        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        let models = [
            Self.model(Self.speaking, live: false), Self.model(Self.quiet), Self.model(Self.speaking), processing,
            Self.outcome(.copiedOnly(reason: "target_terminal")),
            Self.outcome(.insertFailed(reason: "no focused element")),
            Self.outcome(.error(.inferenceFailed)),
        ]
        let ladders: [MercurySpine?] = [nil, layout.spine]
        let drains = [
            MercuryPoseContext(draining: true),
            MercuryPoseContext(pointerInBand: true, fullScreen: true, draining: true),
        ]
        for model in models {
            for collar in ladders {
                #expect(MercuryPose.target(for: model, collar: collar) != .idle)
                for context in drains {
                    #expect(MercuryPose.target(for: model, collar: collar, context: context) == .idle)
                }
                model.beginDismissal()
                #expect(MercuryPose.target(for: model, collar: collar) == .idle)
                model.endDismissal()
                #expect(MercuryPose.target(for: model, collar: collar) != .idle)
            }
        }

        let island = Self.model(Self.speaking)
        let resting = MercurySimulation.Drive.target(for: island, reduceMotion: false)
        island.update(poseContext: MercuryPoseContext(draining: true))
        island.update(lean: -1)
        let draining = MercurySimulation.Drive.target(for: island, reduceMotion: false)
        #expect(draining.pose == .idle)
        #expect(draining.lean == -1)
        let simulation = MercurySimulation(seed: 7, gains: Self.gains)
        simulation.reset(to: resting)
        var volume = Double(simulation.geometry.length * simulation.geometry.halfHeight)
        var substeps = 0
        while volume > 0, substeps < RecordingOverlayConductor.drainLimit {
            simulation.advance(steps: 1, drive: draining)
            let next = Double(simulation.geometry.length * simulation.geometry.halfHeight)
            #expect(next <= volume, "substep \(substeps)")
            volume = next
            substeps += 1
        }
        #expect(volume == 0)
    }

    /// The drive the ribbon builds carries everything the controller tells the model: the pose
    /// context its ladder reads, the lean and the arrival kick. A reset ends the session's arrival
    /// and dismissal and keeps what describes the screen.
    @Test func theDriveCarriesTheControllersContextLeanAndArrival() throws {
        let layout = try #require(
            RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32), bandHeight: 33)
        )
        let model = Self.model(Self.speaking)
        model.update(layout: layout)
        let fullScreen = MercuryPoseContext(fullScreen: true)
        model.update(poseContext: fullScreen)
        model.update(lean: -0.5)
        let arrival = MercuryArrival(id: 3, swayRate: -60, aspectRate: -1.2)
        model.present(arrival: arrival)

        let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
        let spread = MercuryPose.target(for: model, collar: layout.spine, context: fullScreen)
        #expect(drive.pose == spread)
        #expect(drive.pose.length > MercuryPose.target(for: model, collar: layout.spine).length)
        #expect(drive.lean == -0.5)
        #expect(drive.arrival == arrival)

        model.beginDismissal()
        model.reset()
        #expect(model.arrival == nil)
        #expect(!model.isDismissing)
        #expect(model.layout == layout)
        #expect(model.poseContext == fullScreen)
        #expect(model.lean == -0.5)
        #expect(MercurySimulation.Drive.target(for: model, reduceMotion: false).arrival == nil)
    }

    // MARK: - The tune

    /// A body built without a tune, one built at stock, and one retuned to stock from any corner
    /// draw the shipped law to the bit. The retune rebuilds every per-instance constant — the modes'
    /// gel and their following compensation, the kick scales, the body shape's laws and the kit —
    /// and leaves none over from the corner the body ran. The corner's body first runs the pressing
    /// session under its own law, is retuned and reset, and from there draws what the plain body
    /// draws at every check of the same session — every meter, a shoved and leaning panel, Reduce
    /// Motion, every gesture, a replay, the swallow and an emergence — in uneven batches, on the
    /// island and on the collar.
    @Test(arguments: MercuryTuneCorner.tuned)
    func retuningBackToStockRunsTheStockLawBitForBit(corner: MercuryTuneCorner) {
        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            let session = Self.pressingSession(on: layout)
            let plain = MercurySimulation(seed: 31, gains: Self.gains)
            let declared = MercurySimulation(seed: 31, gains: Self.gains, tune: .stock)
            let retuned = MercurySimulation(seed: 31, gains: Self.gains, tune: corner.tune)
            Self.run(session, on: retuned)
            retuned.retune(.stock)
            let bodies = [plain, declared, retuned]
            for body in bodies {
                body.reset(to: session[0].drive)
            }
            var identical =
                Self.bits(declared.geometry) == Self.bits(plain.geometry)
                && Self.bits(retuned.geometry) == Self.bits(plain.geometry)
            for segment in session {
                if let source = segment.replay {
                    for body in bodies {
                        body.rearmGesture(from: source)
                    }
                }
                for batch in Self.unevenBatches(segment.steps) {
                    for body in bodies {
                        body.advance(steps: batch, drive: segment.drive)
                    }
                    let reference = Self.bits(plain.geometry)
                    identical =
                        identical && Self.bits(declared.geometry) == reference
                        && Self.bits(retuned.geometry) == reference
                }
            }
            #expect(identical, "\(layout.kind)")
        }
    }

    /// No tune moves a drawn edge past what its layout allows. Every extreme a tune can reach runs
    /// the pressing session on the island and on the fixture collar, and at every substep every
    /// station of the drawn body stays inside its ceiling and, on the collar, inside the reach its
    /// wall leaves it at the arc length the field lays it; its ends stay on the track every body
    /// rides; and a live body never thins below 0.3 pt anywhere, nor below 0.6 pt under the
    /// syllable.
    @Test(arguments: MercuryTuneExtremes.all)
    func everyTuneStaysInsideTheIslandAndTheCollar(tune: MercuryTune) {
        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            let session = Self.pressingSession(on: layout)
            let simulation = MercurySimulation(seed: 29, gains: Self.gains, tune: tune)
            simulation.reset(to: session[0].drive)
            var worst = -Double.infinity
            var thinnest = Double.infinity
            var finite = true
            for segment in session {
                if let source = segment.replay {
                    simulation.rearmGesture(from: source)
                }
                for _ in 0..<segment.steps {
                    simulation.advance(steps: 1, drive: segment.drive)
                    let geometry = simulation.geometry
                    finite = finite && Self.isFinite(geometry)
                    worst = Swift.max(worst, Self.breach(geometry, drive: segment.drive))
                    if let floor = segment.floor {
                        thinnest = Swift.min(thinnest, Self.thinnest(geometry) - floor)
                    }
                }
            }
            #expect(finite, "\(layout.kind)")
            #expect(worst <= 1e-5, "\(layout.kind): an edge reached \(worst) pt past its bound")
            #expect(thinnest >= 0, "\(layout.kind): the live body thinned \(-thinnest) pt below its floor")
        }
    }

    /// Tempo and Viscosity move how fully each mode follows the voice it carries, and the
    /// following compensation hands every mode its stock following back. A speaking island body
    /// carrying a still buffer under Reduce Motion takes each mode round a circle about its rest
    /// draw. Read off the drawn edges, every circle of both families has the stock body's radius
    /// at every tempo and viscosity corner, to the 0.5 % that holding the voice for each substep
    /// leaves, where uncompensated they would lie from 2 % to 73 % off. At stock tempo and
    /// viscosity no compensation enters: Reactivity scales every circle by exactly its own factor.
    @Test func followingCompensationHandsEveryModeItsStockFollowing() {
        let stock = Self.followingRadii(tune: .stock)
        for tune in [
            MercuryTune(tempo: 0.7), MercuryTune(tempo: 1.5), MercuryTune(viscosity: 0.5),
            MercuryTune(viscosity: 2), MercuryTune(tempo: 0.7, viscosity: 0.5), MercuryTune(tempo: 1.5, viscosity: 2),
        ] {
            let tuned = Self.followingRadii(tune: tune)
            for index in 0..<MercuryMetrics.modeCount {
                let varicose = tuned.varicose[index] / stock.varicose[index]
                let snake = tuned.snake[index] / stock.snake[index]
                #expect(abs(varicose - 1) <= 0.005, "\(tune): varicose mode \(index + 1) follows at \(varicose)")
                #expect(abs(snake - 1) <= 0.005, "\(tune): contact-line mode \(index + 1) follows at \(snake)")
            }
        }
        let louder = Self.followingRadii(tune: MercuryTune(reactivity: 1.5))
        for index in 0..<MercuryMetrics.modeCount {
            #expect(abs(louder.varicose[index] / stock.varicose[index] - 1.5) <= 1e-4, "mode \(index + 1)")
            #expect(abs(louder.snake[index] / stock.snake[index] - 1.5) <= 1e-4, "mode \(index + 1)")
        }
    }

    /// Without shimmer no kick is drawn: a silent body holds perfectly still once it stands on its
    /// pose, whatever its slither, and keeps its seed's rest asymmetry rather than settling into
    /// the capsule.
    @Test func noShimmerHoldsASilentBodyStillOffTheCapsule() {
        let silent = Self.drive(Self.silence)
        let simulation = MercurySimulation(
            seed: 17, gains: Self.gains, tune: MercuryTune(shimmer: 0, slither: 2.5)
        )
        simulation.reset(to: silent)
        simulation.advance(steps: 1, drive: silent)
        let start = Self.bits(simulation.geometry)
        var still = true
        for _ in 0..<120 {
            simulation.advance(steps: 1, drive: silent)
            still = still && Self.bits(simulation.geometry) == start
        }
        #expect(still)
        #expect(Self.mirrorCorrelation(simulation.geometry) < 0.8)
    }

    /// Reduce Motion removes the autonomous shimmer and the contact line's own slither whatever
    /// the tune asks for: a silent body holds still at every shimmer under the widest slither, and
    /// speech still moves it.
    @Test(arguments: [0.0, 1.0, 2.0])
    func reduceMotionRemovesShimmerWhateverTheTune(shimmer: Double) {
        let tune = MercuryTune(shimmer: shimmer, slither: 2.5)
        let silent = Self.drive(Self.silence, reduceMotion: true)
        let still = MercurySimulation(seed: 17, gains: Self.gains, tune: tune)
        still.reset(to: silent)
        let start = Self.bits(still.geometry)
        var held = true
        for _ in 0..<60 {
            still.advance(steps: 1, drive: silent)
            held = held && Self.bits(still.geometry) == start
        }
        #expect(held)
        let speech = Self.drive(Self.speaking, reduceMotion: true)
        let moving = MercurySimulation(seed: 17, gains: Self.gains, tune: tune)
        moving.reset(to: speech)
        let before = Self.bits(moving.geometry)
        moving.advance(steps: 60, drive: speech)
        #expect(Self.bits(moving.geometry) != before)
    }

    /// Slither sets how far the two edges move apart and never lets them mirror. At 0.75, the
    /// least slither, the speaking body, the quiet lip and the still poses still average under
    /// 0.6, and every body mirrors further the less it slithers: at 2.5 below its stock
    /// correlation, which lies below its correlation at 0.75.
    @Test func slitherKeepsTheTwoEdgesApart() {
        let processing = RecordingOverlayModel()
        processing.update(.transcribing)
        let warming = MercurySimulation.Drive(
            pose: MercuryPose.target(for: Self.model(Self.speaking, live: false)),
            samples: Self.speaking,
            reduceMotion: false
        )
        let working = MercurySimulation.Drive(
            pose: MercuryPose.target(for: processing),
            samples: Self.silence,
            reduceMotion: false
        )
        let least = MercuryTune(slither: MercuryTune.slitherRange.lowerBound)
        let speaking = Self.drive(Self.speaking)
        let listening = Self.drive(Self.quiet)
        let bodies: [(MercurySimulation.Drive, [UInt64])] = [
            (speaking, [7, 11, 13]), (listening, [7, 11, 13]), (warming, [13]), (working, [13]),
        ]
        for (drive, seeds) in bodies {
            for seed in seeds {
                let averaged = Self.averagedMirrorCorrelation(drive, seed: seed, gains: Self.gains, tune: least)
                #expect(averaged < 0.6, "seed \(seed): \(averaged)")
            }
        }
        for drive in [speaking, listening] {
            let correlations = [2.5, 1.0, 0.75].map { slither in
                Self.averagedMirrorCorrelation(drive, seed: 11, gains: Self.gains, tune: MercuryTune(slither: slither))
            }
            #expect(correlations[0] < correlations[1] && correlations[1] < correlations[2], "\(correlations)")
        }
    }

    /// Drama scales the lurch's and the collapse's blows and nothing else. Their kicks to the
    /// contact-line and varicose fundamentals are linear in the modes, so at Drama 3 the edges
    /// depart three times as far from a body that took no kick, and so do the first substep of the
    /// sway the lurch throws and of the stretch the collapse makes. The copy-only bead's squash is
    /// its gathering rather than a blow, and at Drama 3 the bead is drawn to the bit as at 1.
    @Test func dramaScalesTheBlowsAndNotTheGathering() {
        let lurch = Self.outcome(.insertFailed(reason: "no focused element"))
        let collapse = Self.outcome(.error(.inferenceFailed))
        // Under Reduce Motion the body's kicks are spent, so the edges answer to the modes' alone.
        for model in [lurch, collapse] {
            let departures = [1.0, 3.0].map { drama in
                Self.blowResponse(model, drama: drama, reduceMotion: true) { struck, control in
                    zip(struck.top + struck.bottom, control.top + control.bottom).map {
                        abs(log(Double($0.0) / Double($0.1)))
                    }.max() ?? 0
                }
            }
            #expect(departures[0] > 1e-3, "\(departures)")
            #expect(abs(departures[1] / departures[0] - 3) <= 1e-3, "\(departures)")
        }
        let sways = [1.0, 3.0].map { drama in
            Self.blowResponse(lurch, drama: drama, reduceMotion: false) { struck, control in
                Double(struck.lateralOffset) - Double(control.lateralOffset)
            }
        }
        let stretches = [1.0, 3.0].map { drama in
            Self.blowResponse(collapse, drama: drama, reduceMotion: false) { struck, control in
                Self.aspect(struck) - Self.aspect(control)
            }
        }
        for responses in [sways, stretches] {
            #expect(abs(responses[0]) > 1e-3, "\(responses)")
            #expect(abs(responses[1] / responses[0] - 3) <= 1e-9, "\(responses)")
        }

        let bead = Self.outcome(.copiedOnly(reason: "target_terminal"))
        let gathering = MercurySimulation.Drive(
            pose: MercuryPose.target(for: bead),
            samples: bead.samples,
            reduceMotion: false
        )
        var calm = gathering
        calm.pose.gesture = nil
        let bodies = [1.0, 3.0].map { drama in
            let simulation = MercurySimulation(seed: 23, gains: Self.gains, tune: MercuryTune(drama: drama))
            simulation.reset(to: calm)
            simulation.advance(steps: 60, drive: gathering)
            return Self.bits(simulation.geometry)
        }
        let unkicked = MercurySimulation(seed: 23, gains: Self.gains)
        unkicked.reset(to: calm)
        unkicked.advance(steps: 60, drive: calm)
        #expect(bodies[0] == bodies[1])
        #expect(bodies[0] != Self.bits(unkicked.geometry))
    }

    /// Morph paces the body's shape and never its flow. A lean is a pose step for the sway, which
    /// peaks later the slower the morph and as far at every morph, and under Reduce Motion climbs
    /// straight to the lean at every morph. The mercury flowing through the notch is the same at
    /// every morph, so a speaking body drains on the very substep the stock body does — on the
    /// island and on the collar, with and without Reduce Motion — inside the hand-off's drain.
    @Test func morphPacesTheShapeAndNeverTheSwallow() {
        let listening = Self.drive(Self.quiet)
        var leaning = listening
        leaning.lean = 1
        var calm = listening
        calm.reduceMotion = true
        var calmLeaning = leaning
        calmLeaning.reduceMotion = true
        var peaks: [(at: Int, sway: Double)] = []
        for morph in [0.6, 1.0, 1.6] {
            let tune = MercuryTune(morph: morph)
            let simulation = MercurySimulation(seed: 9, gains: Self.gains, tune: tune)
            simulation.reset(to: listening)
            var sways: [Double] = []
            for _ in 0..<240 {
                simulation.advance(steps: 1, drive: leaning)
                sways.append(Double(simulation.geometry.lateralOffset))
            }
            let peak = sways.indices.max { sways[$0] < sways[$1] } ?? 0
            peaks.append((peak, sways[peak]))

            let steady = MercurySimulation(seed: 9, gains: Self.gains, tune: tune)
            steady.reset(to: calm)
            var previous = 0.0
            var straight = true
            for _ in 0..<240 {
                steady.advance(steps: 1, drive: calmLeaning)
                let sway = Double(steady.geometry.lateralOffset)
                straight = straight && sway >= previous && sway <= MercuryMetrics.leanSway
                previous = sway
            }
            #expect(straight, "morph \(morph) under Reduce Motion")
        }
        #expect(peaks[0].at < peaks[1].at && peaks[1].at < peaks[2].at, "\(peaks)")
        #expect(abs(Double(peaks[2].at) / Double(peaks[1].at) - 1.6) <= 0.1, "\(peaks)")
        #expect(peaks.allSatisfy { abs($0.sway / peaks[1].sway - 1) <= 0.02 }, "\(peaks)")

        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            for reduceMotion in [false, true] {
                let model = Self.model(Self.speaking)
                model.update(layout: layout)
                let speaking = MercurySimulation.Drive.target(for: model, reduceMotion: reduceMotion)
                model.update(poseContext: MercuryPoseContext(draining: true))
                let draining = MercurySimulation.Drive.target(for: model, reduceMotion: reduceMotion)
                let drains = [1.0, 0.6, 1.6].map { morph in
                    let simulation = MercurySimulation(seed: 7, gains: Self.gains, tune: MercuryTune(morph: morph))
                    simulation.reset(to: speaking)
                    var substeps = 0
                    while simulation.geometry.length * simulation.geometry.halfHeight > 0, substeps < 120 {
                        simulation.advance(steps: 1, drive: draining)
                        substeps += 1
                    }
                    return substeps
                }
                let context = "\(layout.kind), Reduce Motion \(reduceMotion): \(drains)"
                #expect(drains[0] <= RecordingOverlayConductor.drainLimit, "\(context)")
                #expect(drains.allSatisfy { $0 == drains[0] }, "\(context)")
            }
        }
    }

    /// The body kit is a drawing transform of the stock law. The kit's body runs the stock body's
    /// motion and is drawn from it: on the island `size` times as long, on the collar as long as the
    /// housing outline it lies along, and on both with every edge at the stock edge times
    /// `size · build · G′ / G`, the depth at `size · build` times the stock depth, the sway where it
    /// is and the kit's crown carried with the silhouette, through the whole pressing session.
    @Test func theBodyKitIsADrawingTransformOfTheStockLaw() {
        let kit = MercuryTuneCorner.kitMin.tune
        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            let session = Self.pressingSession(on: layout)
            let stock = MercurySimulation(seed: 7, gains: Self.gains)
            let tuned = MercurySimulation(seed: 7, gains: Self.gains, tune: kit)
            for simulation in [stock, tuned] {
                simulation.reset(to: session[0].drive)
            }
            #expect(stock.geometry.crownAspect == MercuryMetrics.crownAspect)
            var transformed = true
            var worst = 0.0
            for segment in session {
                if let source = segment.replay {
                    for simulation in [stock, tuned] {
                        simulation.rearmGesture(from: source)
                    }
                }
                for batch in Self.unevenBatches(segment.steps) {
                    for simulation in [stock, tuned] {
                        simulation.advance(steps: batch, drive: segment.drive)
                    }
                    let original = stock.geometry
                    let drawn = tuned.geometry
                    let length = layout.kind == .collar ? Double(original.length) : Double(original.length) * kit.size
                    transformed =
                        transformed && Double(drawn.length) == length
                        && Double(drawn.halfHeight) == Double(original.halfHeight) * (kit.size * kit.build)
                        && drawn.lateralOffset == original.lateralOffset
                        && drawn.crownAspect == kit.crownAspect
                    for station in 0...MercuryMetrics.columns where original.top[station] != 0 {
                        let position = 2 * Double(station) / Double(MercuryMetrics.columns) - 1
                        let expected =
                            kit.size * kit.build * (1 - (1 - kit.endTaper) * position * position)
                            / (1 - (1 - MercuryMetrics.gEnd) * position * position)
                        let upper = Double(drawn.top[station]) / Double(original.top[station])
                        let lower = Double(drawn.bottom[station]) / Double(original.bottom[station])
                        worst = Swift.max(worst, abs(upper - expected), abs(lower - expected))
                    }
                }
            }
            #expect(transformed, "\(layout.kind)")
            #expect(worst <= 0x1p-22, "\(layout.kind): an edge drew \(worst) off the kit's ratio")
        }
    }

    /// The kit keeps the ladder's bodies distinct in kind. At the smallest size, the thinnest
    /// build and both together, the island's warming is still a compact bead and its listening a
    /// long lens 60 pt longer, and speech still makes the lip longer and deeper; the collar, which
    /// keeps its lengths, keeps the same bead and lens, and its speaking frame stays the deeper.
    @Test func theKitKeepsEveryPoseDistinct() {
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        for tune in [MercuryTuneCorner.kitMin.tune, MercuryTune(size: 0.85), MercuryTune(build: 0.80)] {
            for layout in [RecordingOverlayLayout.island, collar] {
                let geometries = [
                    Self.model(Self.speaking, live: false), Self.model(Self.quiet), Self.model(Self.speaking),
                ].map { model in
                    model.update(layout: layout)
                    var drive = MercurySimulation.Drive.target(for: model, reduceMotion: true)
                    drive.samples = Self.silence
                    let simulation = MercurySimulation(seed: 7, gains: Self.gains, tune: tune)
                    simulation.reset(to: drive)
                    return simulation.geometry
                }
                let (warming, listening, speaking) = (geometries[0], geometries[1], geometries[2])
                let context = "\(tune), \(layout.kind)"
                #expect(listening.length - warming.length >= 60, "\(context)")
                #expect(warming.length / (2 * warming.halfHeight) <= 4.5, "\(context)")
                #expect(listening.length / (2 * listening.halfHeight) >= 7.5, "\(context)")
                #expect(speaking.halfHeight > listening.halfHeight, "\(context)")
                if layout.kind == .collar {
                    #expect(speaking.length >= listening.length, "\(context)")
                } else {
                    #expect(speaking.length > listening.length, "\(context)")
                }
            }
        }
    }

    /// A replay is the live transition again. Rearmed from the processing pose at the end of an
    /// outcome's dwell, a body moves nothing until it advances; that advance places its shape at
    /// rest on processing, where a reset into processing would, kicks it into the outcome and
    /// relaxes it, so its length, depth and sway retrace the live processing-to-outcome transition
    /// to the bit at every substep — for every gesture, with and without Reduce Motion, at every
    /// morph and kit — while its crests stay inside the island.
    @Test(arguments: [
        MercuryTune.stock, MercuryTune(size: 0.85, build: 0.80, morph: 1.6), MercuryTune(morph: 0.6, drama: 3),
    ])
    func aReplayRetracesTheLiveTransitionFromProcessing(tune: MercuryTune) {
        let processingModel = RecordingOverlayModel()
        processingModel.update(.transcribing)
        for state in [
            SessionState.copiedOnly(reason: "target_terminal"),
            .insertFailed(reason: "no focused element"),
            .error(.inferenceFailed),
        ] {
            let model = Self.outcome(state)
            for reduceMotion in [false, true] {
                let processing = MercurySimulation.Drive(
                    pose: MercuryPose.target(for: processingModel),
                    samples: processingModel.samples,
                    reduceMotion: reduceMotion
                )
                let outcome = MercurySimulation.Drive(
                    pose: MercuryPose.target(for: model),
                    samples: model.samples,
                    reduceMotion: reduceMotion
                )
                let live = MercurySimulation(seed: 5, gains: Self.gains, tune: tune)
                live.reset(to: processing)
                let replay = MercurySimulation(seed: 5, gains: Self.gains, tune: tune)
                replay.reset(to: outcome)
                replay.advance(steps: 144, drive: outcome)
                let dwelt = Self.bits(replay.geometry)
                replay.rearmGesture(from: processing.pose)
                #expect(Self.bits(replay.geometry) == dwelt)
                replay.advance(steps: 0, drive: outcome)
                #expect(Self.bits(replay.geometry) == dwelt)
                var retraced = true
                var highest = 0.0
                for _ in 0..<144 {
                    live.advance(steps: 1, drive: outcome)
                    replay.advance(steps: 1, drive: outcome)
                    retraced = retraced && Self.shapeBits(live.geometry) == Self.shapeBits(replay.geometry)
                    let geometry = replay.geometry
                    highest = Swift.max(
                        highest, Double(geometry.top.max() ?? 0), -Double(geometry.bottom.min() ?? 0)
                    )
                }
                #expect(retraced, "\(state), Reduce Motion \(reduceMotion)")
                #expect(highest <= Double(MercuryMetrics.maxHalfHeight), "\(state), Reduce Motion \(reduceMotion)")
            }
        }
    }

    /// A rearmed gesture lands on the next advance and only then: rearming moves nothing, an
    /// advance of no substeps keeps it, two single substeps are one batch of two, and only a
    /// second rearm lands it again.
    @Test func aRearmedGestureLandsOnTheNextAdvanceOnly() {
        for state in [
            SessionState.insertFailed(reason: "no focused element"), .error(.inferenceFailed),
        ] {
            let model = Self.outcome(state)
            let drive = MercurySimulation.Drive(
                pose: MercuryPose.target(for: model),
                samples: model.samples,
                reduceMotion: true
            )
            let singles = MercurySimulation(seed: 23, gains: Self.gains)
            let batch = MercurySimulation(seed: 23, gains: Self.gains)
            let twice = MercurySimulation(seed: 23, gains: Self.gains)
            let unarmed = MercurySimulation(seed: 23, gains: Self.gains)
            for simulation in [singles, batch, twice, unarmed] {
                simulation.reset(to: drive)
            }
            let start = Self.bits(singles.geometry)
            for simulation in [singles, batch, twice] {
                simulation.rearmGesture()
            }
            #expect(Self.bits(singles.geometry) == start)
            singles.advance(steps: 0, drive: drive)
            #expect(Self.bits(singles.geometry) == start)
            singles.advance(steps: 1, drive: drive)
            singles.advance(steps: 1, drive: drive)
            batch.advance(steps: 2, drive: drive)
            twice.advance(steps: 1, drive: drive)
            twice.rearmGesture()
            twice.advance(steps: 1, drive: drive)
            unarmed.advance(steps: 2, drive: drive)
            #expect(Self.bits(singles.geometry) == Self.bits(batch.geometry))
            #expect(Self.bits(singles.geometry) != Self.bits(twice.geometry))
            #expect(Self.bits(singles.geometry) != Self.bits(unarmed.geometry))
        }
    }

    /// A retune changes the law under a moving body and moves nothing. Retuned in motion alone,
    /// the frame after it is the frame before it to the bit; retuned to a kit, it is that frame
    /// redrawn — on the island `size` times as long, on the collar as long as before, its sway
    /// where it was and its crown the kit's — and retuned back to stock, it is the frame before to
    /// the bit again.
    @Test func aRetuneMovesNothing() {
        for layout in [RecordingOverlayLayout.island, .forDisplay(.fixtureNotch)] {
            let model = Self.model(Self.speaking)
            model.update(layout: layout)
            let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
            let simulation = MercurySimulation(seed: 7, gains: Self.gains)
            simulation.reset(to: drive)
            simulation.advance(steps: 60, drive: drive)
            let original = simulation.geometry
            simulation.retune(MercuryTuneCorner.fastWild.tune)
            #expect(Self.bits(simulation.geometry) == Self.bits(original), "\(layout.kind)")
            let kit = MercuryTuneCorner.thinWild.tune
            simulation.retune(kit)
            let drawn = simulation.geometry
            let length = layout.kind == .collar ? Double(original.length) : Double(original.length) * kit.size
            #expect(Double(drawn.length) == length, "\(layout.kind)")
            #expect(Double(drawn.halfHeight) == Double(original.halfHeight) * (kit.size * kit.build), "\(layout.kind)")
            #expect(drawn.lateralOffset == original.lateralOffset, "\(layout.kind)")
            #expect(drawn.crownAspect == kit.crownAspect, "\(layout.kind)")
            simulation.retune(.stock)
            #expect(Self.bits(simulation.geometry) == Self.bits(original), "\(layout.kind)")
        }
    }

    /// The law only ever runs a tune inside its ranges: a non-finite value takes stock, an
    /// out-of-range one its nearer bound, every extreme is its own clamp, and a body built on an
    /// unclamped tune is the body built on its clamp.
    @Test func aTuneIsClampedBeforeItEntersTheLaw() {
        let nonfinite = MercuryTune(
            size: .nan, build: .infinity, endTaper: -.infinity, crownAspect: .nan,
            tempo: .nan, viscosity: .infinity, shimmer: -.infinity, reactivity: .nan,
            slither: .nan, morph: .infinity, drama: -.infinity
        )
        #expect(nonfinite.clamped() == .stock)
        let outside = MercuryTune(
            size: 3, build: -1, endTaper: 1, crownAspect: 0,
            tempo: 0, viscosity: 3, shimmer: -1, reactivity: 3,
            slither: 0, morph: 3, drama: 0
        )
        let expected = MercuryTune(
            size: 1, build: 0.80, endTaper: MercuryMetrics.gEnd, crownAspect: 0.60,
            tempo: 0.70, viscosity: 2, shimmer: 0, reactivity: 1.50,
            slither: 0.75, morph: 1.60, drama: 0.50
        )
        #expect(outside.clamped() == expected)
        for tune in MercuryTuneExtremes.all {
            #expect(tune.clamped() == tune)
        }
        let drive = Self.drive(Self.speaking)
        let unclamped = MercurySimulation(seed: 7, gains: Self.gains, tune: outside)
        let clamped = MercurySimulation(seed: 7, gains: Self.gains, tune: expected)
        for simulation in [unclamped, clamped] {
            simulation.reset(to: drive)
            simulation.advance(steps: 60, drive: drive)
        }
        #expect(Self.bits(unclamped.geometry) == Self.bits(clamped.geometry))
    }

    /// Every tuned corner keeps the law's replay: the state after N substeps does not depend on
    /// how they were batched, through an emergence, a lean, a moving panel and an arrival kick.
    @Test(arguments: MercuryTuneCorner.tuned)
    func tunedAdvancingIsReplayableAndBatchIndependent(corner: MercuryTuneCorner) {
        var drive = Self.drive(Self.speaking)
        drive.lean = 0.5
        drive.forcing = MercuryBodyShape.Forcing(tangentialAcceleration: 1_500, normalAcceleration: -800)
        drive.arrival = MercuryArrival(id: 1, swayRate: 60, aspectRate: -1.2)
        let first = MercurySimulation(seed: 7, gains: Self.gains, tune: corner.tune)
        let second = MercurySimulation(seed: 7, gains: Self.gains, tune: corner.tune)
        let batched = MercurySimulation(seed: 7, gains: Self.gains, tune: corner.tune)
        for simulation in [first, second, batched] {
            simulation.reset(to: drive, emerging: true)
        }
        first.advance(steps: 600, drive: drive)
        for _ in 0..<600 {
            second.advance(steps: 1, drive: drive)
        }
        for _ in 0..<6 {
            batched.advance(steps: 100, drive: drive)
        }
        #expect(Self.bits(first.geometry) == Self.bits(second.geometry))
        #expect(Self.bits(first.geometry) == Self.bits(batched.geometry))
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
        gains: MercuryGains,
        tune: MercuryTune = .stock
    ) -> Double {
        let simulation = MercurySimulation(seed: seed, gains: gains, tune: tune)
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

    // MARK: - Tune helpers

    /// One stretch of the pressing session: a drive held for `steps` substeps.
    private struct Segment {
        var drive: MercurySimulation.Drive
        var steps: Int
        /// The pose a replay of this segment's gesture starts from, rearmed as the segment begins.
        var replay: MercuryPose?
        /// The thinnest a live body may draw here, in points of half-thickness.
        var floor: Double?
    }

    /// A session that presses the body every way a session can, on `layout`: speech, a meter
    /// pinned at full scale, one that alternates and a lone impulse, the quiet room, a leaning
    /// panel shoved at the frame clamp with an arrival kick, Reduce Motion turned on under the
    /// loudest meter, processing, the lurch and its replay from processing, the collapse, the
    /// copy-only bead, the swallow, and an emergence into speech with a second arrival.
    private static func pressingSession(on layout: RecordingOverlayLayout) -> [Segment] {
        func live(_ levels: [Float]) -> MercurySimulation.Drive {
            let model = Self.model(levels)
            model.update(layout: layout)
            return MercurySimulation.Drive.target(for: model, reduceMotion: false)
        }
        func settled(_ model: RecordingOverlayModel) -> MercurySimulation.Drive {
            model.update(layout: layout)
            return MercurySimulation.Drive.target(for: model, reduceMotion: false)
        }
        let pinned = [Float](repeating: 1, count: 11)
        var shoved = live(pinned)
        shoved.lean = 1
        shoved.forcing = MercuryBodyShape.Forcing(
            tangentialAcceleration: -MercuryBodyShape.maxFrameAcceleration,
            normalAcceleration: MercuryBodyShape.maxFrameAcceleration
        )
        shoved.arrival = MercuryArrival(id: 1, swayRate: -60, aspectRate: -1.2)
        var stilled = live(pinned)
        stilled.reduceMotion = true
        let working = RecordingOverlayModel()
        working.update(.transcribing)
        let processing = settled(working)
        let lurch = settled(Self.outcome(.insertFailed(reason: "no focused element")))
        let swallowing = Self.model(Self.speaking)
        swallowing.update(layout: layout)
        swallowing.update(poseContext: MercuryPoseContext(draining: true))
        var emerging = live(Self.speaking)
        emerging.arrival = MercuryArrival(id: 2, swayRate: 60, aspectRate: -1.2)
        return [
            Segment(drive: live(Self.speaking), steps: 40, floor: 0.6),
            Segment(drive: live(pinned), steps: 20, floor: 0.3),
            Segment(drive: live([1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]), steps: 20, floor: 0.3),
            Segment(drive: live([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]), steps: 20, floor: 0.3),
            Segment(drive: live(Self.quiet), steps: 20, floor: 0.3),
            Segment(drive: shoved, steps: 30),
            Segment(drive: stilled, steps: 15),
            Segment(drive: processing, steps: 25),
            Segment(drive: lurch, steps: 35),
            Segment(drive: lurch, steps: 30, replay: processing.pose),
            Segment(drive: settled(Self.outcome(.error(.inferenceFailed))), steps: 35),
            Segment(drive: settled(Self.outcome(.copiedOnly(reason: "target_terminal"))), steps: 25),
            Segment(drive: MercurySimulation.Drive.target(for: swallowing, reduceMotion: false), steps: 50),
            Segment(drive: emerging, steps: 40),
        ]
    }

    /// `session` on `simulation`, from rest on its first drive, unchecked.
    private static func run(_ session: [Segment], on simulation: MercurySimulation) {
        simulation.reset(to: session[0].drive)
        for segment in session {
            if let source = segment.replay {
                simulation.rearmGesture(from: source)
            }
            simulation.advance(steps: segment.steps, drive: segment.drive)
        }
    }

    /// `steps` in uneven batches — one, two, then sevens — so batch boundaries fall everywhere.
    private static func unevenBatches(_ steps: Int) -> [Int] {
        var batches: [Int] = []
        var remaining = steps
        var size = 1
        while remaining > 0 {
            let batch = Swift.min(size, remaining)
            batches.append(batch)
            remaining -= batch
            size = size == 1 ? 2 : 7
        }
        return batches
    }

    /// How far the drawn body reaches past what `drive`'s layout allows, in points, positive for a
    /// breach: each station against its ceiling and, on a collar, against the reach its wall
    /// leaves it at the arc length the field lays it, and each end against the track every body
    /// rides.
    private static func breach(_ geometry: MercurySimulation.Geometry, drive: MercurySimulation.Drive) -> Double {
        let length = Double(geometry.length)
        let sway = Double(geometry.lateralOffset)
        var worst = abs(sway) + length / 2 - drive.maxLength / 2
        for station in 0...MercuryMetrics.columns {
            var reach = drive.maxHalfHeight
            if let spine = drive.spine {
                let position = Double(station) / Double(MercuryMetrics.columns) - 0.5
                reach = spine.reach(at: spine.restCenter + sway + position * length, under: drive.maxHalfHeight)
            }
            worst = Swift.max(worst, Double(geometry.top[station]) - reach, -Double(geometry.bottom[station]) - reach)
        }
        return worst
    }

    /// The drawn body's least half-thickness, `(top − bottom) / 2`, over its stations.
    private static func thinnest(_ geometry: MercurySimulation.Geometry) -> Double {
        zip(geometry.top, geometry.bottom).map { (Double($0) - Double($1)) / 2 }.min() ?? 0
    }

    private static func isFinite(_ geometry: MercurySimulation.Geometry) -> Bool {
        geometry.length.isFinite && geometry.halfHeight.isFinite && geometry.lateralOffset.isFinite
            && geometry.top.allSatisfy(\.isFinite) && geometry.bottom.allSatisfy(\.isFinite)
    }

    /// Everything a frame draws, bit for bit.
    private static func bits(_ geometry: MercurySimulation.Geometry) -> [UInt64] {
        shapeBits(geometry) + [geometry.crownAspect.bitPattern]
            + geometry.top.map { UInt64($0.bitPattern) } + geometry.bottom.map { UInt64($0.bitPattern) }
    }

    /// The body shape's part of a frame, bit for bit: length, depth and sway.
    private static func shapeBits(_ geometry: MercurySimulation.Geometry) -> [UInt64] {
        [
            Double(geometry.length).bitPattern, Double(geometry.halfHeight).bitPattern,
            Double(geometry.lateralOffset).bitPattern,
        ]
    }

    /// `ln(L / H)`, the drawn body's aspect.
    private static func aspect(_ geometry: MercurySimulation.Geometry) -> Double {
        log(Double(geometry.length) / Double(geometry.halfHeight))
    }

    /// `measure` of a body that took `model`'s gesture at `drama` against one that did not, both
    /// from rest on the gesture's pose: six substeps under Reduce Motion, one without, before any
    /// wall can take a part.
    private static func blowResponse(
        _ model: RecordingOverlayModel,
        drama: Double,
        reduceMotion: Bool,
        measure: (MercurySimulation.Geometry, MercurySimulation.Geometry) -> Double
    ) -> Double {
        let blow = MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: reduceMotion
        )
        var calm = blow
        calm.pose.gesture = nil
        let steps = reduceMotion ? 6 : 1
        let control = MercurySimulation(seed: 23, gains: gains)
        let struck = MercurySimulation(seed: 23, gains: gains, tune: MercuryTune(drama: drama))
        control.reset(to: calm)
        struck.reset(to: calm)
        control.advance(steps: steps, drive: calm)
        struck.advance(steps: steps, drive: blow)
        return measure(struck.geometry, control.geometry)
    }

    /// Each mode's circle radius about its rest draw, per family, on a speaking island body that
    /// carries the syllable held still under Reduce Motion, at gains faint enough to keep it clear
    /// of containment. The voice drives mode `m` round at its advection rate `m pi / bufferPeriod`,
    /// the `m`-th harmonic of the fundamental's, so once 20 s have let the start die away, five
    /// fundamental periods of the edges' logs over their envelope hold every mode in a frequency
    /// bin of its own and the rest draw in none. At each of a few stations the two edges' bins give
    /// `V_m (1 + e^{-i m pi delta})` and `V_m + N_m`, turned by the station's phase `m pi a`.
    private static func followingRadii(tune: MercuryTune) -> (varicose: [Double], snake: [Double]) {
        let faint = MercuryGains(drive: 0.3, snake: 0.01)
        let carried = Self.drive(Self.speaking, reduceMotion: true)
        let simulation = MercurySimulation(seed: 5, gains: faint, tune: tune)
        simulation.reset(to: carried)
        simulation.advance(steps: 2_400, drive: carried)
        let stations = [8, 24, 40, 56, 72, 88]
        let samples = Int((10 * MercuryMetrics.bufferPeriod / MercuryMetrics.substep).rounded())
        var upper = [[Double]](repeating: [], count: stations.count)
        var lower = [[Double]](repeating: [], count: stations.count)
        for _ in 0..<samples {
            simulation.advance(steps: 1, drive: carried)
            let geometry = simulation.geometry
            let depth = Double(geometry.halfHeight)
            for (slot, station) in stations.enumerated() {
                let position = 2 * Double(station) / Double(MercuryMetrics.columns) - 1
                let envelope = depth * (1 - (1 - MercuryMetrics.gEnd) * position * position)
                upper[slot].append(log(Double(geometry.top[station]) / envelope))
                lower[slot].append(log(-Double(geometry.bottom[station]) / envelope))
            }
        }
        var varicose: [Double] = []
        var snake: [Double] = []
        for index in 0..<MercuryMetrics.modeCount {
            let mode = Double(index + 1)
            let lag = -mode * Double.pi * MercuryMetrics.snakeLag
            let lagged = SIMD2(1 + cos(lag), sin(lag))
            var thickness = SIMD2<Double>()
            var contact = SIMD2<Double>()
            for (slot, station) in stations.enumerated() {
                let top = Self.harmonic(upper[slot], bin: 5 * (index + 1))
                let bottom = Self.harmonic(lower[slot], bin: 5 * (index + 1))
                let back = -mode * Double.pi * Double(station) / Double(MercuryMetrics.columns)
                let turn = SIMD2(cos(back), sin(back))
                let value = Self.product(Self.quotient(top + bottom, lagged), turn)
                thickness += value
                contact += Self.product(top, turn) - value
            }
            varicose.append(Self.magnitude(thickness) / Double(stations.count))
            snake.append(Self.magnitude(contact) / Double(stations.count))
        }
        return (varicose, snake)
    }

    /// `A` of a component `Re[A e^{i 2 pi bin n / N}]` of `samples`, which runs a whole number of
    /// cycles over them: twice their discrete Fourier coefficient at `bin`.
    private static func harmonic(_ samples: [Double], bin: Int) -> SIMD2<Double> {
        var sum = SIMD2<Double>()
        for (index, sample) in samples.enumerated() {
            let angle = -2 * Double.pi * Double(bin * index) / Double(samples.count)
            sum += sample * SIMD2(cos(angle), sin(angle))
        }
        return 2 / Double(samples.count) * sum
    }

    private static func product(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(lhs.x * rhs.x - lhs.y * rhs.y, lhs.x * rhs.y + lhs.y * rhs.x)
    }

    private static func quotient(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> SIMD2<Double> {
        let size = (rhs * rhs).sum()
        return SIMD2(lhs.x * rhs.x + lhs.y * rhs.y, lhs.y * rhs.x - lhs.x * rhs.y) / size
    }

    private static func magnitude(_ value: SIMD2<Double>) -> Double {
        (value * value).sum().squareRoot()
    }
}
