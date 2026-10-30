import AppKit
import Testing

@testable import Voiceour

/// Every hand-off as a timeline on the substep clock. The conductor is a pure function of the
/// retargets and presented frames it is handed, so each table replays exactly, beat by beat: what
/// it answers, and the phase it is left in.
struct RecordingOverlayConductorTests {
    typealias Action = RecordingOverlayConductor.Action
    typealias Phase = RecordingOverlayConductor.Phase

    /// One line of a timeline: a retarget or a presented frame at `step`, the answer it must get,
    /// and the phase it must leave.
    struct Beat: Sendable {
        enum Event: Sendable {
            case retarget(to: UInt32, exitSign: Double, instant: Bool)
            case frame(volume: Double)
        }

        var step: Int
        var event: Event
        var expect: Action?
        var phase: Phase

        static func retarget(
            _ step: Int,
            to display: UInt32,
            exitSign: Double,
            instant: Bool = false,
            _ expect: Action?,
            then phase: Phase
        ) -> Beat {
            Beat(
                step: step, event: .retarget(to: display, exitSign: exitSign, instant: instant), expect: expect,
                phase: phase)
        }

        static func frame(_ step: Int, volume: Double, _ expect: Action?, then phase: Phase) -> Beat {
            Beat(step: step, event: .frame(volume: volume), expect: expect, phase: phase)
        }
    }

    struct Timeline: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var beats: [Beat]
    }

    @Test(arguments: RecordingOverlayConductorTests.timelines)
    func everyHandOffReplaysItsTimeline(_ timeline: Timeline) {
        var conductor = RecordingOverlayConductor(display: Self.builtIn)
        for (index, beat) in timeline.beats.enumerated() {
            let action: Action?
            switch beat.event {
            case .retarget(let display, let exitSign, let instant):
                action = conductor.retarget(to: display, exitSign: exitSign, step: beat.step, instant: instant)
            case .frame(let volume):
                action = conductor.frame(volume: volume, step: beat.step)
            }
            #expect(action == beat.expect, "beat \(index) at substep \(beat.step)")
            #expect(conductor.phase == beat.phase, "beat \(index) at substep \(beat.step)")
        }
    }

    /// The destination the move policy measures candidates against, and the lean a drain takes.
    @Test func theConductorNamesWhereTheBodyIsGoingAndHowItLeans() {
        var conductor = RecordingOverlayConductor(display: Self.builtIn)
        #expect(conductor.destination == Self.builtIn)
        #expect(conductor.isResting)
        #expect(conductor.drainSign == nil)

        _ = conductor.retarget(to: Self.external, exitSign: -1, step: 0, instant: false)
        #expect(conductor.destination == Self.external)
        #expect(!conductor.isResting)
        #expect(conductor.drainSign == -1)

        _ = conductor.frame(volume: 0, step: 3)
        #expect(conductor.destination == Self.external)
        #expect(!conductor.isResting)
        #expect(conductor.drainSign == nil)
    }

    /// The sign is the side the destination lies on, by the order of the displays' centres, and
    /// the arrival kick carries it into the sway with a landing squash.
    @Test func theExitSignFollowsTheDisplaysCentresAndTheArrivalCarriesIt() {
        let builtIn = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)
        let right = CGRect(x: 1_728, y: -323, width: 2_560, height: 1_440)
        let left = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let above = CGRect(x: -96, y: 1_117, width: 1_920, height: 1_080)
        #expect(RecordingOverlayConductor.exitSign(from: builtIn, to: right) == 1)
        #expect(RecordingOverlayConductor.exitSign(from: right, to: builtIn) == -1)
        #expect(RecordingOverlayConductor.exitSign(from: builtIn, to: left) == -1)
        #expect(RecordingOverlayConductor.exitSign(from: builtIn, to: above) == 0)

        #expect(
            RecordingOverlayConductor.arrival(id: 4, sign: -1)
                == MercuryArrival(id: 4, swayRate: -60, aspectRate: -1.2)
        )
        #expect(
            RecordingOverlayConductor.arrival(id: 5, sign: 0)
                == MercuryArrival(id: 5, swayRate: 0, aspectRate: -1.2)
        )
    }

    private static let builtIn: UInt32 = 1
    private static let external: UInt32 = 2
    private static let projector: UInt32 = 3
    private static let cap = RecordingOverlayConductor.drainLimit
    private static let emergence = RecordingOverlayConductor.emergenceLength
    /// A speaking island's volume, 160 × 9.5 pt.
    private static let full = 1_520.0

    static let timelines: [Timeline] = [
        Timeline(
            testDescription: "a drain re-frames once the body is empty",
            beats: [
                .retarget(
                    10, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 10, exitSign: 1)),
                .frame(11, volume: full, nil, then: .draining(from: builtIn, to: external, startStep: 10, exitSign: 1)),
                .frame(40, volume: 1, nil, then: .draining(from: builtIn, to: external, startStep: 10, exitSign: 1)),
                .frame(
                    41, volume: 0.5, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 41)),
            ]
        ),
        Timeline(
            testDescription: "a drain re-frames at its limit with whatever is left",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(
                    cap - 1, volume: 72, nil, then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(
                    cap, volume: 70, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: cap)),
            ]
        ),
        Timeline(
            testDescription: "a stall that presents several substeps at once still ends the drain at its limit",
            beats: [
                .retarget(
                    100, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 100, exitSign: 1)),
                .frame(146, volume: 80, nil, then: .draining(from: builtIn, to: external, startStep: 100, exitSign: 1)),
                .frame(
                    150, volume: 60, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 150)),
            ]
        ),
        Timeline(
            testDescription: "a return during the drain emerges in place with no re-frame",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(12, volume: 400, nil, then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .retarget(14, to: builtIn, exitSign: -1, nil, then: .emerging(display: builtIn, startStep: 14)),
                .frame(20, volume: 0.25, nil, then: .emerging(display: builtIn, startStep: 14)),
                .frame(14 + emergence, volume: 300, .settled, then: .resting(display: builtIn)),
            ]
        ),
        Timeline(
            testDescription: "a third display re-aims the drain without restarting it",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(20, volume: 600, nil, then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .retarget(
                    24, to: projector, exitSign: -1, nil,
                    then: .draining(from: builtIn, to: projector, startStep: 0, exitSign: -1)),
                .frame(
                    cap, volume: 90, .reframe(to: projector, arrivalSign: -1),
                    then: .emerging(display: projector, startStep: cap)),
            ]
        ),
        Timeline(
            testDescription: "a retarget toward where the body is or is going changes nothing",
            beats: [
                .retarget(0, to: builtIn, exitSign: 0, nil, then: .resting(display: builtIn)),
                .retarget(
                    1, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 1, exitSign: 1)),
                .retarget(
                    5, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 1, exitSign: 1)),
                .frame(
                    9, volume: 0, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 9)),
                .retarget(10, to: external, exitSign: 1, nil, then: .emerging(display: external, startStep: 9)),
            ]
        ),
        Timeline(
            testDescription: "Reduce Motion re-frames at once, with no drain and no arrival kick",
            beats: [
                .retarget(
                    7, to: external, exitSign: 1, instant: true, .reframe(to: external, arrivalSign: nil),
                    then: .resting(display: external)),
                .frame(8, volume: full, nil, then: .resting(display: external)),
                .retarget(
                    9, to: builtIn, exitSign: -1, instant: true, .reframe(to: builtIn, arrivalSign: nil),
                    then: .resting(display: builtIn)),
            ]
        ),
        Timeline(
            testDescription: "an instant move cuts a drain or an emergence short",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .retarget(
                    6, to: projector, exitSign: -1, instant: true, .reframe(to: projector, arrivalSign: nil),
                    then: .resting(display: projector)),
                .retarget(
                    8, to: external, exitSign: 1, nil,
                    then: .draining(from: projector, to: external, startStep: 8, exitSign: 1)),
                .retarget(9, to: projector, exitSign: -1, instant: true, nil, then: .resting(display: projector)),
                .retarget(
                    10, to: external, exitSign: 1, nil,
                    then: .draining(from: projector, to: external, startStep: 10, exitSign: 1)),
                .frame(
                    30, volume: 0, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 30)),
                .retarget(
                    31, to: builtIn, exitSign: -1, instant: true, .reframe(to: builtIn, arrivalSign: nil),
                    then: .resting(display: builtIn)),
            ]
        ),
        Timeline(
            testDescription: "emerging settles after 60 substeps",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(
                    30, volume: 0, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 30)),
                .frame(30 + emergence - 1, volume: full, nil, then: .emerging(display: external, startStep: 30)),
                .frame(30 + emergence, volume: full, .settled, then: .resting(display: external)),
                .frame(30 + emergence + 1, volume: full, nil, then: .resting(display: external)),
            ]
        ),
        Timeline(
            testDescription: "a retarget while emerging drains again from the display it emerges on",
            beats: [
                .retarget(
                    0, to: external, exitSign: 1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: 1)),
                .frame(
                    30, volume: 0, .reframe(to: external, arrivalSign: 1),
                    then: .emerging(display: external, startStep: 30)),
                .retarget(
                    45, to: builtIn, exitSign: -1, nil,
                    then: .draining(from: external, to: builtIn, startStep: 45, exitSign: -1)),
                .frame(
                    60, volume: 0, .reframe(to: builtIn, arrivalSign: -1),
                    then: .emerging(display: builtIn, startStep: 60)),
            ]
        ),
        Timeline(
            testDescription: "the arrival sign mirrors the exit sign",
            beats: [
                .retarget(
                    0, to: external, exitSign: -1, nil,
                    then: .draining(from: builtIn, to: external, startStep: 0, exitSign: -1)),
                .frame(
                    5, volume: 0, .reframe(to: external, arrivalSign: -1),
                    then: .emerging(display: external, startStep: 5)),
                .frame(5 + emergence, volume: full, .settled, then: .resting(display: external)),
                .retarget(
                    70, to: projector, exitSign: 0, nil,
                    then: .draining(from: external, to: projector, startStep: 70, exitSign: 0)),
                .frame(
                    75, volume: 0, .reframe(to: projector, arrivalSign: 0),
                    then: .emerging(display: projector, startStep: 75)),
            ]
        ),
        Timeline(
            testDescription: "a resting body ignores its frames, empty or not",
            beats: [
                .frame(0, volume: 0, nil, then: .resting(display: builtIn)),
                .frame(500, volume: full, nil, then: .resting(display: builtIn)),
            ]
        ),
    ]
}

/// The controller's pure geometry: where the collar's panel goes, how far the body leans, and when
/// the frontmost window is full screen.
struct RecordingOverlayHandOffGeometryTests {
    /// Centred on the housing and flush with the top edge, the collar's canvas lays its outline on
    /// the housing: the outline's walls land on the housing's.
    @Test(arguments: [OverlayDisplay.fixtureNotch, .fixtureWideNotch])
    func theCollarHangsFromTheTopEdgeAroundItsHousing(display: OverlayDisplay) throws {
        let housing = try #require(display.housing)
        let layout = RecordingOverlayLayout.forDisplay(display)
        guard case .collar(let outline) = layout.spine.kind else {
            Issue.record("a notched display wears the collar")
            return
        }
        let frame = RecordingOverlayController.collarFrame(
            panelSize: layout.panelSize,
            housing: housing,
            displayFrame: display.frame
        )
        #expect(frame.size == layout.panelSize)
        #expect(frame.maxY == display.frame.maxY)
        #expect(frame.midX == housing.midX)
        // Canvas-local x, origin at the canvas centre, in global x.
        #expect(abs(Double(frame.midX) + outline.minX - Double(housing.minX)) < 1e-9)
        #expect(abs(Double(frame.midX) + outline.maxX - Double(housing.maxX)) < 1e-9)
        #expect(abs(Double(frame.midY) + outline.bottom - Double(housing.minY)) < 1e-9)
    }

    @Test func theLeanIsTheWindowsOffsetInHalfDisplayWidthsHeldToOne() {
        let display = OverlayDisplay.fixtureNotch.frame
        let anchor = display.midX
        func window(centredAt x: CGFloat) -> CGRect {
            CGRect(x: x - 300, y: 200, width: 600, height: 500)
        }
        #expect(
            RecordingOverlayController.lean(
                towardWindow: window(centredAt: anchor), anchorX: anchor, displayFrame: display) == 0)
        #expect(
            RecordingOverlayController.lean(
                towardWindow: window(centredAt: anchor + 432), anchorX: anchor, displayFrame: display)
                == 0.5
        )
        #expect(
            RecordingOverlayController.lean(
                towardWindow: window(centredAt: anchor - 864), anchorX: anchor, displayFrame: display)
                == -1
        )
        // A window on a display to the right leans the body fully, and no further.
        #expect(
            RecordingOverlayController.lean(
                towardWindow: window(centredAt: 3_000), anchorX: anchor, displayFrame: display) == 1
        )
        #expect(RecordingOverlayController.lean(towardWindow: nil, anchorX: anchor, displayFrame: display) == 0)
        #expect(
            RecordingOverlayController.lean(towardWindow: window(centredAt: 10), anchorX: anchor, displayFrame: .zero)
                == 0)
    }

    @Test func aWindowIsFullScreenWhenItFillsTheDisplayToWithinAPoint() {
        let display = OverlayDisplay.fixtureNotch.frame
        #expect(RecordingOverlayController.isFullScreen(window: display, displayFrame: display))
        #expect(
            RecordingOverlayController.isFullScreen(window: display.insetBy(dx: 0.5, dy: 0.5), displayFrame: display))
        #expect(!RecordingOverlayController.isFullScreen(window: display.insetBy(dx: 0, dy: 2), displayFrame: display))
        // A maximised window stops at the menu bar: the band beside the notch is still menus.
        let maximised = OverlayDisplay.fixtureNotch.visibleFrame
        #expect(!RecordingOverlayController.isFullScreen(window: maximised, displayFrame: display))
        #expect(!RecordingOverlayController.isFullScreen(window: nil, displayFrame: display))
    }

    /// Quartz measures down from the primary display's top edge; AppKit measures up from its
    /// bottom edge.
    @Test func aQuartzWindowFrameTurnsIntoAppKitCoordinates() {
        let quartz = CGRect(x: 100, y: 40, width: 600, height: 500)
        let appKit = RecordingOverlayFocusTracker.appKitFrame(quartz: quartz, primaryDisplayHeight: 1_117)
        #expect(appKit == CGRect(x: 100, y: 577, width: 600, height: 500))
        let below = CGRect(x: 1_800, y: 1_200, width: 300, height: 200)
        #expect(
            RecordingOverlayFocusTracker.appKitFrame(quartz: below, primaryDisplayHeight: 1_117)
                == CGRect(x: 1_800, y: -283, width: 300, height: 200)
        )
    }
}
