import Testing

@testable import Voiceour

/// Every hand-off rule as a timeline. The policy is a pure function of the times and displays
/// it is handed, so each table replays exactly, beat by beat.
struct RecordingOverlayMovePolicyTests {
    typealias Cause = RecordingOverlayMovePolicy.Cause
    typealias Decision = RecordingOverlayMovePolicy.Decision

    /// One line of a timeline: ask the policy and check its answer, or report a move.
    struct Beat: Sendable {
        enum Action: Sendable {
            case evaluate(Cause, current: UInt32, candidate: UInt32, frozen: Bool, expect: Decision)
            case moved(from: UInt32, to: UInt32)
        }

        var now: Double
        var action: Action

        static func ask(
            _ now: Double,
            _ cause: Cause,
            on current: UInt32,
            toward candidate: UInt32,
            frozen: Bool = false,
            _ expect: Decision
        ) -> Beat {
            let action = Action.evaluate(cause, current: current, candidate: candidate, frozen: frozen, expect: expect)
            return Beat(now: now, action: action)
        }

        static func moved(_ now: Double, from: UInt32, to: UInt32) -> Beat {
            Beat(now: now, action: .moved(from: from, to: to))
        }
    }

    struct Timeline: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var beats: [Beat]
    }

    @Test(arguments: RecordingOverlayMovePolicyTests.timelines)
    func everyHandOffRuleReplaysItsTimeline(_ timeline: Timeline) {
        var policy = RecordingOverlayMovePolicy()
        for (index, beat) in timeline.beats.enumerated() {
            switch beat.action {
            case .evaluate(let cause, let current, let candidate, let frozen, let expected):
                let decision = policy.evaluate(
                    now: beat.now,
                    current: current,
                    candidate: candidate,
                    cause: cause,
                    frozen: frozen
                )
                #expect(decision == expected, "beat \(index) at \(beat.now)s")
            case .moved(let from, let to):
                policy.didMove(now: beat.now, from: from, to: to)
            }
        }
    }

    private static let builtIn: UInt32 = 1
    private static let external: UInt32 = 2
    private static let projector: UInt32 = 3
    private static let deferral = RecordingOverlayMovePolicy.clickDeferral
    private static let hold = RecordingOverlayMovePolicy.returnHold
    private static let quiet = RecordingOverlayMovePolicy.reconfigurationQuiet

    static let timelines: [Timeline] = [
        Timeline(
            testDescription: "focus on another display moves at once",
            beats: [
                .ask(0, .focus, on: builtIn, toward: external, .move(display: external, instant: false))
            ]
        ),
        Timeline(
            testDescription: "the display the island is on is never a move",
            beats: [
                .ask(0, .focus, on: builtIn, toward: builtIn, .stay),
                .ask(0.5, .pointerClick, on: builtIn, toward: builtIn, .stay),
            ]
        ),
        Timeline(
            testDescription: "a click on another display defers, then focus decides",
            beats: [
                .ask(1, .pointerClick, on: builtIn, toward: external, .reevaluate(at: 1 + deferral)),
                .ask(1 + deferral, .focus, on: builtIn, toward: builtIn, .stay),
                .ask(2, .pointerClick, on: builtIn, toward: external, .reevaluate(at: 2 + deferral)),
                .ask(2 + deferral, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "going back within 1.5 s must hold 0.4 s",
            beats: [
                .moved(0, from: builtIn, to: external),
                .ask(0.5, .focus, on: external, toward: builtIn, .reevaluate(at: 0.5 + hold)),
                .ask(0.75, .focus, on: external, toward: builtIn, .reevaluate(at: 0.5 + hold)),
                .ask(0.5 + hold, .focus, on: external, toward: builtIn, .move(display: builtIn, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a return hold restarts once focus stays put",
            beats: [
                .moved(0, from: builtIn, to: external),
                .ask(0.25, .focus, on: external, toward: builtIn, .reevaluate(at: 0.25 + hold)),
                .ask(0.5, .focus, on: external, toward: external, .stay),
                .ask(0.75, .focus, on: external, toward: builtIn, .reevaluate(at: 0.75 + hold)),
                .ask(0.75 + hold, .focus, on: external, toward: builtIn, .move(display: builtIn, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a display never left, or left 1.5 s ago, moves at once",
            beats: [
                .moved(0, from: builtIn, to: external),
                .ask(0.25, .focus, on: external, toward: projector, .move(display: projector, instant: false)),
                .moved(0.25, from: external, to: projector),
                .ask(1.5, .focus, on: projector, toward: builtIn, .move(display: builtIn, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "every display left recently is a return, not only the last",
            beats: [
                .moved(0, from: builtIn, to: external),
                .moved(0.5, from: external, to: projector),
                .ask(1, .focus, on: projector, toward: builtIn, .reevaluate(at: 1 + hold)),
            ]
        ),
        Timeline(
            testDescription: "a click back toward a display just left defers, then holds",
            beats: [
                .moved(0, from: builtIn, to: external),
                .ask(0.25, .pointerClick, on: external, toward: builtIn, .reevaluate(at: 0.25 + deferral)),
                .ask(0.25 + deferral, .focus, on: external, toward: builtIn, .reevaluate(at: 0.25 + deferral + hold)),
                .ask(
                    0.25 + deferral + hold,
                    .focus,
                    on: external,
                    toward: builtIn,
                    .move(display: builtIn, instant: false)
                ),
            ]
        ),
        Timeline(
            testDescription: "three moves within 5 s are instant until 3 s pass without one",
            beats: [
                .moved(0, from: builtIn, to: external),
                .moved(1, from: external, to: projector),
                .moved(2, from: projector, to: builtIn),
                .ask(4.5, .focus, on: builtIn, toward: external, .move(display: external, instant: true)),
                .moved(4.5, from: builtIn, to: external),
                .ask(7.25, .focus, on: external, toward: projector, .move(display: projector, instant: true)),
                .moved(7.25, from: external, to: projector),
                .ask(10.25, .focus, on: projector, toward: builtIn, .move(display: builtIn, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "two moves, or three spread over 5 s, are no storm",
            beats: [
                .moved(0, from: builtIn, to: external),
                .moved(2.5, from: external, to: projector),
                .ask(3, .focus, on: projector, toward: builtIn, .move(display: builtIn, instant: false)),
                .moved(5, from: projector, to: builtIn),
                .ask(6, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a hand-off onto the same display is not a move",
            beats: [
                .moved(0, from: builtIn, to: builtIn),
                .moved(0.25, from: builtIn, to: builtIn),
                .moved(0.5, from: builtIn, to: builtIn),
                .ask(0.75, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a frozen island stays",
            beats: [
                .ask(0, .focus, on: builtIn, toward: external, frozen: true, .stay),
                .ask(0.25, .pointerClick, on: builtIn, toward: external, frozen: true, .stay),
                .ask(0.5, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a reconfiguration holds every move until 0.3 s of quiet",
            beats: [
                .ask(1, .reconfiguration, on: builtIn, toward: external, .reevaluate(at: 1 + quiet)),
                .ask(1.25, .reconfiguration, on: builtIn, toward: external, .reevaluate(at: 1.25 + quiet)),
                .ask(1.5, .focus, on: builtIn, toward: external, .reevaluate(at: 1.25 + quiet)),
                .ask(1.5, .pointerClick, on: builtIn, toward: external, .reevaluate(at: 1.25 + quiet)),
                .ask(1.25 + quiet, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
        Timeline(
            testDescription: "a reconfiguration during a freeze still starts the quiet period",
            beats: [
                .ask(2, .reconfiguration, on: builtIn, toward: external, frozen: true, .stay),
                .ask(2.125, .focus, on: builtIn, toward: external, .reevaluate(at: 2 + quiet)),
                .ask(2 + quiet, .focus, on: builtIn, toward: external, .move(display: external, instant: false)),
            ]
        ),
    ]
}
