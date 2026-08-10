// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import Foundation
    import Testing
    import VoiceCore
    @testable import VoiceOour

    struct UIFlowContractTests {
        @Test func countAcceptsEveryBoundary() {
            #expect(UICount.exactly(2).accepts(2))
            #expect(!UICount.exactly(2).accepts(1))

            #expect(UICount.atLeast(2).accepts(2))
            #expect(UICount.atLeast(2).accepts(3))
            #expect(!UICount.atLeast(2).accepts(1))

            #expect(UICount.atMost(2).accepts(2))
            #expect(UICount.atMost(2).accepts(1))
            #expect(!UICount.atMost(2).accepts(3))

            #expect(UICount.between(2, 4).accepts(2))
            #expect(UICount.between(2, 4).accepts(4))
            #expect(!UICount.between(2, 4).accepts(1))
            #expect(!UICount.between(2, 4).accepts(5))
        }

        @Test func textAcceptsEveryRuleAndEmptyBoundary() {
            #expect(UIText.equals("").accepts(""))
            #expect(UIText.equals("voice").accepts("voice"))
            #expect(!UIText.equals("voice").accepts("Voice"))

            #expect(UIText.contains("").accepts("voice"))
            #expect(UIText.contains("oic").accepts("voice"))
            #expect(!UIText.contains("other").accepts("voice"))

            #expect(UIText.hasPrefix("").accepts("voice"))
            #expect(UIText.hasPrefix("voice").accepts("voice"))
            #expect(!UIText.hasPrefix("ice").accepts("voice"))

            #expect(UIText.hasSuffix("").accepts("voice"))
            #expect(UIText.hasSuffix("voice").accepts("voice"))
            #expect(!UIText.hasSuffix("voi").accepts("voice"))

            #expect(UIText.isEmpty.accepts(""))
            #expect(!UIText.isEmpty.accepts("voice"))
            #expect(UIText.isNotEmpty.accepts("voice"))
            #expect(!UIText.isNotEmpty.accepts(""))
        }

        @Test func statePatternCoversEverySessionStateCase() {
            let cases: [(SessionState, UIStatePattern)] = [
                (.idle, .idle),
                (.checkingPermissions, .checkingPermissions),
                (.recording, .recording),
                (.finalizingAudio, .finalizingAudio),
                (.transcribing, .transcribing),
                (.cleaning, .cleaning),
                (.refining, .refining),
                (.readyToInsert, .readyToInsert),
                (.pasteAttempted, .pasteAttempted),
                (.copiedOnly(reason: "unsafe target"), .copiedOnly),
                (.insertFailed(reason: "event post failed"), .insertFailed),
                (.error(.inferenceFailed), .error),
                (.cancelled, .cancelled),
            ]

            #expect(cases.count == 13)
            #expect(Set(cases.map(\.1)) == Set(UIStatePattern.allCases))
            for (state, expected) in cases {
                #expect(UIStatePattern.of(state) == expected)
                #expect(expected.matches(state))
            }
        }

        @MainActor
        @Test func transitionMatchingHonorsAllOrdersAndEdgeCases() async {
            let coordinator = UIFixtures.coordinator(.firstRun)
            let recorder = UITransitionRecorder()
            recorder.attach(to: coordinator)
            coordinator.cancel()

            #expect(recorder.recorded == [.idle, .cancelled])

            #expect(recorder.matches([.idle, .cancelled], order: .exact))
            #expect(!recorder.matches([.idle], order: .exact))
            #expect(!recorder.matches([], order: .exact))
            #expect(!recorder.matches([.idle, .cancelled, .idle], order: .exact))

            #expect(recorder.matches([.idle, .cancelled], order: .contiguous))
            #expect(recorder.matches([.cancelled], order: .contiguous))
            #expect(recorder.matches([], order: .contiguous))
            #expect(!recorder.matches([.recording], order: .contiguous))
            #expect(!recorder.matches([.idle, .cancelled, .idle], order: .contiguous))

            #expect(recorder.matches([.idle, .cancelled], order: .subsequence))
            #expect(recorder.matches([.cancelled], order: .subsequence))
            #expect(recorder.matches([], order: .subsequence))
            #expect(!recorder.matches([.idle, .cancelled, .idle], order: .subsequence))
            #expect(!recorder.matches([.cancelled, .idle], order: .subsequence))

            recorder.detach()
            await coordinator.prepareForTermination()
        }

        @MainActor
        @Test func armedGateSuspendsUntilReleaseAndResumesExactlyOnce() async {
            let gate = UIGateBox(armed: true)
            var resumes = 0
            let waiter = Task { @MainActor in
                await gate.arrive()
                resumes += 1
            }

            await Task.yield()
            #expect(gate.arrivals == 1)
            #expect(resumes == 0)

            gate.release()
            await waiter.value
            #expect(resumes == 1)

            gate.release()
            await Task.yield()
            #expect(resumes == 1)
        }

        @MainActor
        @Test func releaseBeforeArrivalIsStickyAndRearmClosesAgain() async {
            let gate = UIGateBox(armed: true)
            gate.release()
            var firstResumed = false
            let first = Task { @MainActor in
                await gate.arrive()
                firstResumed = true
            }

            await Task.yield()
            #expect(gate.arrivals == 1)
            #expect(firstResumed)
            gate.drain()
            await first.value

            gate.rearm()
            var secondResumed = false
            let second = Task { @MainActor in
                await gate.arrive()
                secondResumed = true
            }

            await Task.yield()
            #expect(gate.arrivals == 2)
            #expect(!secondResumed)

            gate.release()
            await second.value
            #expect(secondResumed)
        }

        @MainActor
        @Test func drainResumesAParkedWaiterWithoutOpeningTheGate() async {
            let gate = UIGateBox(armed: true)
            var resumes = 0
            let first = Task { @MainActor in
                await gate.arrive()
                resumes += 1
            }

            await Task.yield()
            #expect(gate.arrivals == 1)
            #expect(resumes == 0)
            gate.drain()
            await first.value
            #expect(resumes == 1)

            let second = Task { @MainActor in
                await gate.arrive()
                resumes += 1
            }
            await Task.yield()
            #expect(gate.arrivals == 2)
            #expect(resumes == 1)

            gate.drain()
            await second.value
            #expect(resumes == 2)
        }

        @MainActor
        @Test func unarmedGateNeverSuspendsAndCountsEveryArrival() async {
            let gate = UIGateBox(armed: false)
            var resumes = 0
            let first = Task { @MainActor in
                await gate.arrive()
                resumes += 1
            }
            await Task.yield()
            #expect(resumes == 1)
            gate.drain()
            await first.value

            gate.rearm()
            let second = Task { @MainActor in
                await gate.arrive()
                resumes += 1
            }
            await Task.yield()
            #expect(resumes == 2)
            gate.drain()
            await second.value
            #expect(gate.arrivals == 2)
        }

        @Test func queryAndExpectationDescriptionsAreStableSingleLines() {
            #expect(UIQuery.quote("a\\b\"c\nd\te") == "\"a\\\\b\\\"c\\nd\\te\"")

            let queries: [(UIQuery, String)] = [
                (.id("save-button"), "id=save-button"),
                (.label("Save"), "label=\"Save\""),
                (.value("Ready"), "value=\"Ready\""),
                (.placeholder("Search"), "placeholder=\"Search\""),
                (.labelContains("Sav"), "label~=\"Sav\""),
                (.valueContains("ead"), "value~=\"ead\""),
                (.role("AXButton"), "role=AXButton"),
                (.all([.label("Save"), .role("AXButton")]), "label=\"Save\" & role=AXButton"),
            ]
            for (query, expected) in queries {
                #expect(query.description == expected)
                #expect(!query.description.contains("\n"))
            }

            let expectations: [(UIExpectation, String)] = [
                (.exists(.label("Save")), "exists label=\"Save\""),
                (.absent(.id("error")), "absent id=error"),
                (.count(.role("AXButton"), .exactly(2)), "count role=AXButton exactly 2"),
                (.enabled(.label("Save"), true), "enabled(true) label=\"Save\""),
                (.value(.id("status"), .equals("line\nbreak")), "value id=status == \"line\\nbreak\""),
                (.label(.id("save"), .contains("Sav")), "label id=save contains \"Sav\""),
                (.role(.id("save"), "AXButton"), "role id=save == AXButton"),
                (.text(.hasPrefix("Ready"), .atLeast(1)), "text starts with \"Ready\" at least 1"),
                (.state(.recording), "state == recording"),
                (
                    .transitions([.idle, .recording], .subsequence),
                    "transitions subsequence [idle -> recording]"
                ),
                (.model(.transcript, .isNotEmpty), "model transcript is not empty"),
                (.warnings(.atMost(0)), "interaction warnings at most 0"),
                (.lintClean, "lint clean"),
            ]
            for (expectation, expected) in expectations {
                #expect(expectation.expectation == expected)
                #expect(!expectation.expectation.contains("\n"))
            }
        }

        @Test func flowResultStatusUsesGlobalPrecedence() {
            let flow = UIFlow(
                id: "contract.status",
                title: "Status precedence contract",
                host: .menu,
                fixture: UIFlowFixture.static(.firstRun),
                steps: [.check("contract", [.lintClean])]
            )
            let failureFrame = frame(pixel: .failed, accessibility: .ok)
            let changedFrame = frame(pixel: .changed, accessibility: .ok)
            let missingFrame = frame(pixel: .missingGolden, accessibility: .ok)
            let writtenFrame = frame(pixel: .written, accessibility: .ok)

            #expect(result(flow: flow, journal: .changed, frames: [failureFrame]).status == .failed)
            #expect(result(flow: flow, journal: .missingGolden, frames: [changedFrame]).status == .changed)
            #expect(result(flow: flow, journal: .written, frames: [missingFrame]).status == .missingGolden)
            #expect(result(flow: flow, journal: .ok, frames: [writtenFrame]).status == .written)
            #expect(result(flow: flow, journal: .ok, frames: []).status == .ok)
        }

        private func frame(pixel: UISceneResult.Status, accessibility: UISceneResult.Status) -> UIFlowFrame {
            UIFlowFrame(
                name: "checkpoint",
                id: "contract.status.checkpoint",
                pixelStatus: pixel,
                axStatus: accessibility,
                pngDigest: nil,
                goldenPngDigest: nil,
                nodeCount: 0,
                findings: []
            )
        }

        private func result(
            flow: UIFlow,
            journal: UISceneResult.Status,
            frames: [UIFlowFrame]
        ) -> UIFlowResult {
            UIFlowResult(
                flow: flow,
                lines: [],
                transitions: [],
                frames: frames,
                failures: [],
                warnings: [],
                error: nil,
                journalStatus: journal
            )
        }
    }

#endif
