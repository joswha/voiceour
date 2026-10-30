import AppKit
import Testing

@testable import Voiceour

/// Every press on the body as a timeline of pointer positions. The drag is a pure function of the
/// press, the moves and the release it is handed, so each table replays exactly: what every move
/// answers and where the release leaves the body.
///
/// The geometry is the fixture displays'. On `.fixtureNotchless` the docked island's envelope is
/// centred at (756, 897) and island centres run over x 106…1406, y 33…925; on `.fixtureNotch` the
/// collar hangs from the housing's bottom centre, (864, 1085), and centres stop at y 1051, the
/// visible frame's top less the padding and half the envelope.
struct RecordingOverlayDragTests {
    typealias Drag = RecordingOverlayDrag

    enum Beat: Sendable {
        /// The pointer moves to `point`, and the drag answers `step`.
        case move(CGPoint, Drag.Step)
        /// The pointer lets go at `point` over a display that docks at `anchor`, and the drag
        /// answers `release`.
        case release(CGPoint, anchor: RecordingOverlayPlacement.Anchor, Drag.Release)
    }

    struct Timeline: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var grab: CGPoint
        var body: Drag.Body
        var reduceMotion = false
        /// The island centres the display under the pointer admits.
        var centres: CGRect
        var beats: [Beat]
    }

    @Test(arguments: RecordingOverlayDragTests.timelines)
    func everyPressReplaysItsTimeline(_ timeline: Timeline) {
        var drag = Drag(grab: timeline.grab, body: timeline.body, reduceMotion: timeline.reduceMotion)
        for (index, beat) in timeline.beats.enumerated() {
            switch beat {
            case .move(let point, let expected):
                #expect(drag.drag(to: point, within: timeline.centres) == expected, "beat \(index)")
            case .release(let point, let anchor, let expected):
                #expect(drag.release(at: point, within: timeline.centres, anchor: anchor) == expected, "beat \(index)")
            }
        }
    }

    /// κ makes the tear-off pull lean the body exactly as far as a full lean toward the window: a
    /// quarter of the pull.
    @Test func theTetherIsStiffEnoughToLeanTheBodyAQuarterOfThePull() {
        #expect(abs(Drag.bandStiffness - 2_500.0 / 3) < 1e-9)
        let forcing = Drag.bandForcing(pull: SIMD2(24, -10))
        #expect(abs(forcing.tangentialAcceleration + 20_000) < 1e-9)
        #expect(abs(forcing.normalAcceleration - 25_000.0 / 3) < 1e-9)
        let swayShift =
            MercuryBodyShape.swayCoupling * forcing.tangentialAcceleration
            / MercuryBodyShape.swayGel.rubberyStiffness
        #expect(abs(swayShift - MercuryMetrics.leanSway) < 1e-9)
    }

    /// The snap hands back the energy the tether held: 60 pt/s along a sideways pull, a −2.03 s⁻¹
    /// squash for a pull straight out of the housing, and no harder for a flick past the distance.
    @Test func theSnapReleasesTheLeanAndTheStretchTheTetherHeld() {
        let sideways = Drag.snap(pull: SIMD2(24, 0))
        #expect(abs(sideways.swayRate - 60) < 1e-9)
        #expect(abs(sideways.aspectRate) < 1e-12)

        let flick = Drag.snap(pull: SIMD2(-90, 0))
        #expect(abs(flick.swayRate + 60) < 1e-9)

        let outward = Drag.snap(pull: SIMD2(0, 24))
        #expect(abs(outward.swayRate) < 1e-12)
        #expect(abs(outward.aspectRate + 2.029) < 0.001)

        // Into the housing, or down from the island, the tether squashed the body, which springs
        // back long.
        let inward = Drag.snap(pull: SIMD2(0, -24))
        #expect(abs(inward.aspectRate - 2.029) < 0.001)

        let diagonal = Drag.snap(pull: SIMD2(30, 40))
        #expect(abs(diagonal.swayRate - 60 * 0.6) < 1e-9)
        #expect(abs(diagonal.aspectRate + 2.029 * 0.8) < 0.001)

        #expect(Drag.snap(pull: SIMD2()) == Drag.Snap(swayRate: 0, aspectRate: 0))
    }

    /// Critically damped from rest: it never passes the dock, it is half a point short of it on its
    /// 23rd substep, and from its 24th it is exactly there.
    @Test func theGlideApproachesItsDockMonotonicallyAndLandsOnIt() {
        let glide = RecordingOverlayGlide(
            from: CGPoint(x: 756, y: 849),
            to: CGPoint(x: 756, y: 897),
            startStep: 100
        )
        #expect(glide.centre(atStep: 100) == glide.from)
        var previous = glide.from.y
        for step in 101..<124 {
            let y = glide.centre(atStep: step).y
            #expect(y > previous, "substep \(step)")
            #expect(y < glide.to.y, "substep \(step)")
            previous = y
        }
        #expect(glide.to.y - previous < 0.5)
        #expect(!glide.isOver(atStep: 123))
        #expect(glide.isOver(atStep: 124))
        #expect(glide.centre(atStep: 124) == glide.to)
        #expect(glide.centre(atStep: 130) == glide.to)
    }

    // MARK: - Fixtures

    private static let islandAxes = RecordingOverlayLayout.island.bodyAxes
    private static let collarAxes = RecordingOverlayLayout.forDisplay(.fixtureNotch).bodyAxes
    /// The notchless fixture's docked island envelope centre.
    private static let home = CGPoint(x: 756, y: 897)
    /// The notched fixture's housing bottom centre.
    private static let housing = CGPoint(x: 864, y: 1_085)
    private static let notchless = RecordingOverlayFramePlacement.islandCentres(
        on: OverlayDisplay.fixtureNotchless.visibleFrame
    )
    private static let notched = RecordingOverlayFramePlacement.islandCentres(
        on: OverlayDisplay.fixtureNotch.visibleFrame
    )

    static let timelines: [Timeline] = [
        Timeline(
            testDescription: "a docked island pulled less than 24 pt stretches, and snaps back where it is",
            grab: home,
            body: .docked(anchor: home, axes: islandAxes),
            centres: notchless,
            beats: [
                .move(CGPoint(x: 766, y: 897), .stretch(pull: CGVector(dx: 10, dy: 0))),
                .move(CGPoint(x: 756, y: 873.5), .stretch(pull: CGVector(dx: 0, dy: -23.5))),
                .move(CGPoint(x: 740, y: 885), .stretch(pull: CGVector(dx: -16, dy: -12))),
                .release(CGPoint(x: 740, y: 885), anchor: .island(home), .snapBack),
            ]
        ),
        Timeline(
            testDescription: "a pull of 24 pt tears the island off under the hand, which then carries it",
            grab: CGPoint(x: 776, y: 900),
            body: .docked(anchor: home, axes: islandAxes),
            centres: notchless,
            beats: [
                .move(CGPoint(x: 790, y: 900), .stretch(pull: CGVector(dx: 14, dy: 0))),
                // Held where it was grabbed, 20 pt right of and 3 pt above the envelope's centre.
                .move(
                    CGPoint(x: 800, y: 900),
                    .tearOff(centre: CGPoint(x: 780, y: 897), snap: Drag.snap(pull: SIMD2(24, 0)))
                ),
                .move(CGPoint(x: 900, y: 700), .carry(centre: CGPoint(x: 880, y: 697))),
                // Carried past the display's edge, it stops where the padding does.
                .move(CGPoint(x: 1_500, y: 10), .carry(centre: CGPoint(x: 1_406, y: 33))),
                .move(CGPoint(x: 900, y: 700), .carry(centre: CGPoint(x: 880, y: 697))),
                .release(CGPoint(x: 900, y: 700), anchor: .island(home), .free(centre: CGPoint(x: 880, y: 697))),
            ]
        ),
        Timeline(
            testDescription: "a torn-off island let go within 48 pt of its dock glides home",
            grab: home,
            body: .docked(anchor: home, axes: islandAxes),
            centres: notchless,
            beats: [
                .move(
                    CGPoint(x: 756, y: 870),
                    .tearOff(centre: CGPoint(x: 756, y: 870), snap: Drag.snap(pull: SIMD2(0, -27)))
                ),
                .move(CGPoint(x: 756, y: 849), .carry(centre: CGPoint(x: 756, y: 849))),
                // Exactly 48 pt from the dock.
                .release(
                    CGPoint(x: 756, y: 849),
                    anchor: .island(home),
                    .dock(.glide(from: CGPoint(x: 756, y: 849), to: home))
                ),
            ]
        ),
        Timeline(
            testDescription: "a torn-off island let go beyond 48 pt of its dock stays free",
            grab: home,
            body: .docked(anchor: home, axes: islandAxes),
            centres: notchless,
            beats: [
                .move(
                    CGPoint(x: 756, y: 870),
                    .tearOff(centre: CGPoint(x: 756, y: 870), snap: Drag.snap(pull: SIMD2(0, -27)))
                ),
                .move(CGPoint(x: 756, y: 848.5), .carry(centre: CGPoint(x: 756, y: 848.5))),
                .release(CGPoint(x: 756, y: 848.5), anchor: .island(home), .free(centre: CGPoint(x: 756, y: 848.5))),
            ]
        ),
        Timeline(
            testDescription: "the collar pulled out of its housing tears off below the menu bar and siphons home",
            // On the chin, 5 pt under the housing.
            grab: CGPoint(x: 864, y: 1_080),
            body: .docked(anchor: housing, axes: collarAxes),
            centres: notched,
            beats: [
                .move(CGPoint(x: 864, y: 1_060), .stretch(pull: CGVector(dx: 0, dy: -20))),
                // Under the hand would put the envelope's centre at 1061, inside the menu bar's
                // padding; it stops at 1051.
                .move(
                    CGPoint(x: 864, y: 1_056),
                    .tearOff(centre: CGPoint(x: 864, y: 1_051), snap: Drag.snap(pull: SIMD2(0, 24)))
                ),
                // 34 pt from the housing's bottom centre, the closest a free island gets.
                .release(CGPoint(x: 864, y: 1_056), anchor: .collar(housing), .dock(.siphon)),
            ]
        ),
        Timeline(
            testDescription: "the collar carried far from its housing stays a free island",
            grab: CGPoint(x: 864, y: 1_080),
            body: .docked(anchor: housing, axes: collarAxes),
            centres: notched,
            beats: [
                .move(
                    CGPoint(x: 864, y: 1_040),
                    .tearOff(centre: CGPoint(x: 864, y: 1_045), snap: Drag.snap(pull: SIMD2(0, 40)))
                ),
                .move(CGPoint(x: 1_000, y: 900), .carry(centre: CGPoint(x: 1_000, y: 905))),
                .release(CGPoint(x: 1_000, y: 900), anchor: .collar(housing), .free(centre: CGPoint(x: 1_000, y: 905))),
            ]
        ),
        Timeline(
            testDescription: "a collar grabbed far along its chin tears off with the island's end under the hand",
            // 106 pt right of the housing's centre, past the island canvas's 98.
            grab: CGPoint(x: 970, y: 1_082),
            body: .docked(anchor: housing, axes: collarAxes),
            centres: notched,
            beats: [
                .move(
                    CGPoint(x: 994, y: 1_082),
                    .tearOff(centre: CGPoint(x: 896, y: 1_051), snap: Drag.snap(pull: SIMD2(24, 0)))
                ),
                .move(CGPoint(x: 1_098, y: 1_000), .carry(centre: CGPoint(x: 1_000, y: 1_003))),
            ]
        ),
        Timeline(
            testDescription: "a free island follows the hand from the first move, with no tether",
            grab: CGPoint(x: 420, y: 505),
            body: .free(centre: CGPoint(x: 400, y: 500)),
            centres: notchless,
            beats: [
                .move(CGPoint(x: 421, y: 505), .carry(centre: CGPoint(x: 401, y: 500))),
                .move(CGPoint(x: 2_000, y: 505), .carry(centre: CGPoint(x: 1_406, y: 500))),
                .move(CGPoint(x: 780, y: 890), .carry(centre: CGPoint(x: 760, y: 885))),
                .release(
                    CGPoint(x: 780, y: 890),
                    anchor: .island(home),
                    .dock(.glide(from: CGPoint(x: 760, y: 885), to: home))
                ),
            ]
        ),
        Timeline(
            testDescription: "a free island near its dock that is only clicked stays where it is",
            grab: CGPoint(x: 770, y: 880),
            body: .free(centre: CGPoint(x: 760, y: 880)),
            centres: notchless,
            beats: [
                .move(CGPoint(x: 770, y: 880), .carry(centre: CGPoint(x: 760, y: 880))),
                .release(CGPoint(x: 770, y: 880), anchor: .island(home), .free(centre: CGPoint(x: 760, y: 880))),
            ]
        ),
        Timeline(
            testDescription: "a free island dropped on a notched display's housing siphons into the collar",
            grab: CGPoint(x: 500, y: 600),
            body: .free(centre: CGPoint(x: 500, y: 600)),
            centres: notched,
            beats: [
                .move(CGPoint(x: 870, y: 1_040), .carry(centre: CGPoint(x: 870, y: 1_040))),
                .release(CGPoint(x: 870, y: 1_040), anchor: .collar(housing), .dock(.siphon)),
            ]
        ),
        Timeline(
            testDescription: "Reduce Motion: the tear-off carries no snap, and the island jumps home",
            grab: home,
            body: .docked(anchor: home, axes: islandAxes),
            reduceMotion: true,
            centres: notchless,
            beats: [
                .move(CGPoint(x: 756, y: 880), .stretch(pull: CGVector(dx: 0, dy: -17))),
                .move(CGPoint(x: 780, y: 870), .tearOff(centre: CGPoint(x: 780, y: 870), snap: nil)),
                .release(CGPoint(x: 780, y: 870), anchor: .island(home), .dock(.jump(to: home))),
            ]
        ),
        Timeline(
            testDescription: "Reduce Motion: the collar re-frames home at once",
            grab: CGPoint(x: 864, y: 1_080),
            body: .docked(anchor: housing, axes: collarAxes),
            reduceMotion: true,
            centres: notched,
            beats: [
                .move(CGPoint(x: 864, y: 1_050), .tearOff(centre: CGPoint(x: 864, y: 1_051), snap: nil)),
                .release(CGPoint(x: 864, y: 1_050), anchor: .collar(housing), .dock(.reframe)),
            ]
        ),
        Timeline(
            testDescription: "Reduce Motion: a free island let go away from its dock stays free",
            grab: CGPoint(x: 400, y: 500),
            body: .free(centre: CGPoint(x: 400, y: 500)),
            reduceMotion: true,
            centres: notchless,
            beats: [
                .move(CGPoint(x: 300, y: 300), .carry(centre: CGPoint(x: 300, y: 300))),
                .release(CGPoint(x: 300, y: 300), anchor: .island(home), .free(centre: CGPoint(x: 300, y: 300))),
            ]
        ),
    ]
}
