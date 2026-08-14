// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import CoreGraphics
    import Foundation
    import Testing
    @testable import Voiceour

    /// Characterizes `UILint.evaluate` against hand-built accessibility trees.
    ///
    /// The lint pass is the only automated signal on a scene with no golden yet, so
    /// its ordering and its exemptions are contracts. These cases pin the four that
    /// carry the most weight: the total order over findings, the scroll/scroller
    /// exemptions that stopped 158 false positives, the duplicate-identifier
    /// grouping, and the overlap cap that keeps one broken ZStack from burying the
    /// rest of the manifest.
    struct UILintTests {
        private func node(
            role: String,
            subrole: String? = nil,
            label: String? = nil,
            identifier: String? = nil,
            frame: CGRect,
            children: [AXNode] = []
        ) -> AXNode {
            AXNode(
                role: role,
                subrole: subrole,
                label: label,
                value: nil,
                placeholder: nil,
                identifier: identifier,
                help: nil,
                enabled: true,
                selected: nil,
                frame: frame,
                children: children
            )
        }

        private func evaluate(_ root: AXNode, size: CGSize = CGSize(width: 400, height: 300)) -> [UIFinding] {
            UILint.evaluate(root: root, capture: nil, size: size)
        }

        // MARK: Ordering

        @Test func errorsSortAheadOfWarningsAndRulesSortAlphabetically() {
            // One unlabeled 40x40 button (error) plus one labeled 10x10 button, whose
            // off-scale height and sub-threshold area trip two separate warnings.
            let root = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(role: "AXButton", frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
                    node(role: "AXButton", label: "Tiny", frame: CGRect(x: 200, y: 10, width: 10, height: 10)),
                ]
            )

            let findings = evaluate(root)

            #expect(findings.map(\.rule) == ["unlabeled-control", "control-height", "tiny-hit-target"])
            #expect(findings.map(\.severity) == [.error, .warning, .warning])
        }

        @Test func findingOrderIsIndependentOfSiblingDeclarationOrder() {
            let left = node(role: "AXButton", frame: CGRect(x: 10, y: 10, width: 40, height: 40))
            let right = node(role: "AXButton", frame: CGRect(x: 200, y: 10, width: 40, height: 40))
            let forward = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [left, right]
            )
            let reversed = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [right, left]
            )

            #expect(evaluate(forward).map(\.message) == evaluate(reversed).map(\.message))
        }

        // MARK: Scroll and scroller exemptions

        @Test func scrollerPartsAreNotTreatedAsUndersizedAppControls() {
            let root = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXButton",
                        subrole: "AXIncrementArrow",
                        frame: CGRect(x: 380, y: 10, width: 6, height: 6)
                    ),
                    node(
                        role: "AXButton",
                        subrole: "AXDecrementArrow",
                        frame: CGRect(x: 380, y: 20, width: 6, height: 6)
                    ),
                ]
            )

            #expect(evaluate(root).isEmpty)
        }

        @Test func documentContentOverflowingAScrollViewportIsNotAClippedChild() {
            let overflowing = node(
                role: "AXGroup",
                label: "Document",
                frame: CGRect(x: 0, y: 0, width: 360, height: 900)
            )
            let insideScroll = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXScrollArea",
                        label: "Pane",
                        frame: CGRect(x: 0, y: 0, width: 360, height: 280),
                        children: [overflowing]
                    )
                ]
            )
            let insidePlainGroup = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXGroup",
                        label: "Pane",
                        frame: CGRect(x: 0, y: 0, width: 360, height: 280),
                        children: [overflowing]
                    )
                ]
            )

            #expect(evaluate(insideScroll).contains { $0.rule == "clipped-child" } == false)
            #expect(evaluate(insidePlainGroup).contains { $0.rule == "clipped-child" })
        }

        // MARK: Duplicate identifiers

        @Test func identifierCollisionOnlyReportsWhenTheLabelCollidesToo() {
            let sharedIdentifierDistinctLabels = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXButton", label: "Remove Swift", identifier: "xmark",
                        frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
                    node(
                        role: "AXButton", label: "Remove Kotlin", identifier: "xmark",
                        frame: CGRect(x: 100, y: 10, width: 40, height: 40)),
                ]
            )
            let fullyAmbiguous = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXButton", label: "Remove", identifier: "xmark",
                        frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
                    node(
                        role: "AXButton", label: "Remove", identifier: "xmark",
                        frame: CGRect(x: 100, y: 10, width: 40, height: 40)),
                ]
            )

            #expect(evaluate(sharedIdentifierDistinctLabels).contains { $0.rule == "duplicate-identifier" } == false)

            let duplicates = evaluate(fullyAmbiguous).filter { $0.rule == "duplicate-identifier" }
            #expect(duplicates.count == 1, "one finding per colliding group, not one per node")
            #expect(duplicates.first?.message.contains("shared by 2 nodes") == true)
        }

        @Test func oneGroupOfThreeYieldsOneFinding() {
            let root = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: (0..<3).map { index in
                    node(
                        role: "AXButton",
                        label: "Remove",
                        identifier: "xmark",
                        frame: CGRect(x: 10 + 60 * index, y: 10, width: 40, height: 40)
                    )
                }
            )

            let duplicates = evaluate(root).filter { $0.rule == "duplicate-identifier" }
            #expect(duplicates.count == 1)
            #expect(duplicates.first?.message.contains("shared by 3 nodes") == true)
        }

        // MARK: Overlap cap

        @Test func overlappingControlFindingsAreCappedAtTwenty() {
            // Ten fully stacked unrelated controls pair 45 ways; the cap must hold.
            let root = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: (0..<10).map { index in
                    node(
                        role: "AXButton",
                        label: "Stacked \(index)",
                        frame: CGRect(x: 10, y: 10, width: 40, height: 40)
                    )
                }
            )

            let overlaps = evaluate(root).filter { $0.rule == "overlapping-controls" }
            #expect(overlaps.count == 20)
        }

        @Test func ancestorDescendantContainmentIsNeverAnOverlap() {
            let root = node(
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                children: [
                    node(
                        role: "AXButton",
                        label: "Outer",
                        frame: CGRect(x: 10, y: 10, width: 120, height: 40),
                        children: [
                            node(
                                role: "AXButton",
                                label: "Inner",
                                frame: CGRect(x: 14, y: 14, width: 32, height: 32)
                            )
                        ]
                    )
                ]
            )

            #expect(evaluate(root).contains { $0.rule == "overlapping-controls" } == false)
        }
    }

#endif
