// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import CoreGraphics
    import Foundation

    private struct UILintContext {
        let root: AXNode
        let flat: [UILint.FlatNode]
        let capture: UICapture?
        let size: CGSize
        let textSamples: [TextRoleSample]
    }

    private protocol UILintRule {
        var id: String { get }
        var severity: UIFinding.Severity { get }

        func evaluate(context: UILintContext) -> [UIFinding]
    }

    private struct RegisteredUILintRule: UILintRule {
        let id: String
        /// Registry metadata only. A finding's own severity remains authoritative so
        /// rules that classify individual findings can emit a different severity.
        let severity: UIFinding.Severity
        let evaluator: (UILintContext) -> [UIFinding]

        func evaluate(context: UILintContext) -> [UIFinding] {
            evaluator(context)
        }
    }

    // Machine-checkable UX rules for the offscreen UI harness.
    //
    // Goldens catch *change*; these rules catch *wrongness*. An agent pointing the
    // harness at a brand-new screen has no golden to diff against, so on the first run
    // the lint pass is the only automated signal that the scene is actually sane:
    // that it rendered at all, that the accessibility tree came up, that nothing spills
    // out of the window, that every control is addressable and big enough to hit.
    //
    // Design rules for everything in this file:
    //   * Deterministic. Two runs over the same tree must produce a byte-identical list,
    //     so the final ordering is explicit and never inherited from traversal or from
    //     Dictionary iteration order.
    //   * Silent on unknown data. A missing frame, a nil capture or a zero-sized scene is
    //     absent information, not a violation. False positives train agents to ignore us.
    //   * Bounded. No rule may flood the manifest; the quadratic one is explicitly capped.
    //
    // This file depends only on Foundation, CoreGraphics and UIHarnessContracts.swift.
    enum UILint {
        /// Roles the harness treats as user-operable. Interaction steps address these,
        /// so a defect on one of them is both a UX bug and an untestable node.
        private static let interactiveRoles: Set<String> = [
            "axbutton",
            "axcheckbox",
            "axdisclosuretriangle",
            "axlink",
            "axmenuitem",
            "axpopupbutton",
            "axradiobutton",
            "axslider",
        ]

        /// Geometry slack, in points. AppKit rounds accessibility frames to backing pixels,
        /// so a half-point overhang is arithmetic, not a layout bug.
        private static let epsilon: CGFloat = 0.5

        /// Minimum comfortable control edge, in points. Not invented: the recording
        /// overlay's control discs are the smallest affordance this project ships on
        /// purpose — `RecordingOverlayLayout.Disc.visualSize` is 22 inside a 28pt hit
        /// frame. Anything below it is smaller than our own floor.
        private static let minimumHitTarget: CGFloat = 22

        /// Share of the smaller control that must be covered before an overlap is reported.
        private static let overlapAreaThreshold: Double = 0.25

        /// Minimum share of the smaller frame required to join a role sample to readable AX text.
        private static let textFrameOverlapThreshold: Double = 0.5

        /// Hard cap on `overlapping-controls` findings. One broken ZStack can otherwise
        /// pair every control with every other one and bury the rest of the manifest.
        private static let overlapFindingLimit = 20

        /// Longest quoted label fragment embedded in a message, in characters.
        private static let messageTextLimit = 40

        /// Longest list of paths embedded in a single `duplicate-identifier` message.
        private static let duplicatePathLimit = 4

        /// Canonical interactive heights: four controls plus the four row pitches.
        private static let allowedControlHeights: Set<CGFloat> = [24, 28, 32, 40, 44, 64]

        /// Above the tallest row pitch an interactive node is a content container, not a
        /// control, and is checked against the 4 pt grid instead of the control scale.
        private static let containerHeightFloor: CGFloat = 64

        /// A broken layout can put every descendant off-grid; preserve a useful prefix.
        private static let offGridFindingLimit = 20

        private static let gridUnit: CGFloat = 4
        private static let gridEpsilon: CGFloat = 0.01

        /// Reference hit area, in square points: `RowIconButton`'s own 22x22 footprint.
        /// Tested as an area rather than per-edge because a full-width `GlassToggleStyle`
        /// row is 528x18 -- twenty times easier to hit than the reference, yet a naive
        /// per-edge test called it undersized.
        private static let minimumHitArea: CGFloat = minimumHitTarget * minimumHitTarget

        /// Thinnest edge a control may have before it is unhittable however long it is.
        private static let minimumHitEdge: CGFloat = 8

        /// Scroller parts AppKit synthesises inside every `NSScroller`. SwiftUI exposes no
        /// way to label or resize them, macOS overlay scrollers paint nothing at rest, and
        /// treating them as app controls produced 45 findings against stock `ScrollView`s
        /// and none against real UI. Matched on subrole only: a disabled-but-genuinely-tiny
        /// app button must still be seen.
        private static let scrollerPartSubroles: Set<String> = [
            "axincrementarrow",
            "axdecrementarrow",
            "axincrementpage",
            "axdecrementpage",
        ]

        /// Roles whose frame is a viewport rather than a container. Their children are
        /// positioned in document space and legitimately extend past them, so comparing a
        /// child against them is meaningless -- it turned every scrolled settings pane into
        /// phantom overflow (113 findings, 0 real).
        private static let scrollContainerRoles: Set<String> = [
            "axscrollarea",
            "axscrollbar",
        ]

        // MARK: - Composition

        /// The rule order is deliberate and matches the original append sequence.
        /// Add a rule here; `evaluate` supplies the complete scene context to each one.
        private static let rules: [any UILintRule] = [
            RegisteredUILintRule(id: "blank-render", severity: .error) { context in
                blankRender(root: context.root, capture: context.capture, size: context.size)
            },
            RegisteredUILintRule(id: "unsupported-view", severity: .error) { context in
                unsupportedView(root: context.root, capture: context.capture, size: context.size)
            },
            RegisteredUILintRule(id: "empty-tree", severity: .error) { context in
                emptyTree(root: context.root, nodeCount: context.flat.count)
            },
            RegisteredUILintRule(id: "text-contrast", severity: .error) { context in
                textContrast(flat: context.flat, textSamples: context.textSamples)
            },
            RegisteredUILintRule(id: "out-of-bounds", severity: .error) { context in
                outOfBounds(flat: context.flat, size: context.size)
            },
            RegisteredUILintRule(id: "clipped-child", severity: .warning) { context in
                clippedChild(flat: context.flat)
            },
            RegisteredUILintRule(id: "tiny-hit-target", severity: .warning) { context in
                tinyHitTarget(flat: context.flat)
            },
            RegisteredUILintRule(id: "unlabeled-control", severity: .error) { context in
                unlabeledControl(flat: context.flat)
            },
            RegisteredUILintRule(id: "overlapping-controls", severity: .warning) { context in
                overlappingControls(flat: context.flat)
            },
            RegisteredUILintRule(id: "duplicate-identifier", severity: .warning) { context in
                duplicateIdentifier(flat: context.flat)
            },
            RegisteredUILintRule(id: "control-height", severity: .warning) { context in
                controlHeight(flat: context.flat)
            },
            RegisteredUILintRule(id: "off-grid", severity: .warning) { context in
                offGrid(flat: context.flat, size: context.size)
            },
        ]

        /// Runs every rule over one rendered scene and returns findings in a stable order.
        ///
        /// `capture` is optional so the accessibility rules can run without a raster; the
        /// pixel rules simply stay quiet when it is absent.
        static func evaluate(
            root: AXNode,
            capture: UICapture?,
            size: CGSize,
            textSamples: [TextRoleSample] = []
        ) -> [UIFinding] {
            let context = UILintContext(
                root: root,
                flat: flatten(root),
                capture: capture,
                size: size,
                textSamples: textSamples
            )
            return ordered(rules.flatMap { $0.evaluate(context: context) })
        }

        // MARK: - Rules

        /// `blank-render`: the scene rasterised as an (almost) flat fill.
        ///
        /// Catches the regression where the view builds and the accessibility tree looks
        /// plausible but nothing actually painted — a scene hosted before its data loaded,
        /// a `.opacity(0)` left in, a background that swallowed its own content. Promoting
        /// a flat rectangle to a golden freezes the bug in, and every later run passes.
        private static func blankRender(
            root: AXNode,
            capture: UICapture?,
            size: CGSize
        ) -> [UIFinding] {
            guard let capture, capture.width > 0, capture.height > 0 else { return [] }
            guard capture.dominantColorFraction >= 0.995 else { return [] }
            let share = percent(capture.dominantColorFraction, decimals: 2)
            return [
                UIFinding(
                    rule: "blank-render",
                    severity: .error,
                    message: "scene rendered as a flat fill: \(share) of "
                        + "\(capture.width)x\(capture.height) pixels share one colour; "
                        + "a golden of this image would assert nothing",
                    path: rolePath(root),
                    frame: bounds(of: size)
                )
            ]
        }

        /// `unsupported-view`: SwiftUI painted its `#FFCC00` "cannot render" placeholder.
        ///
        /// Catches an AppKit-backed view (NSViewRepresentable, ProgressView, the repo's own
        /// FrostedGlassBackground) failing to rasterise. It fails silently — you get a
        /// cheerful yellow rectangle with a no-entry badge instead of an error — so without
        /// this rule the placeholder gets committed as the expected appearance.
        private static func unsupportedView(
            root: AXNode,
            capture: UICapture?,
            size: CGSize
        ) -> [UIFinding] {
            guard let capture, capture.width > 0, capture.height > 0 else { return [] }
            guard capture.placeholderFraction > 0.001 else { return [] }
            let share = percent(capture.placeholderFraction, decimals: 3)
            return [
                UIFinding(
                    rule: "unsupported-view",
                    severity: .error,
                    message: "\(share) of the image is SwiftUI's #FFCC00 unsupported-view "
                        + "placeholder; an AppKit-backed view in this scene did not rasterise",
                    path: rolePath(root),
                    frame: bounds(of: size)
                )
            ]
        }

        /// `empty-tree`: fewer than two accessibility nodes came back.
        ///
        /// Almost never means the UI is genuinely empty. It means the hosting view reported
        /// no children — in practice the `setAccessibilityEnhancedUserInterface:` flag did
        /// not take, which drops the tree from 23 nodes to 1 and makes every `find`-based
        /// interaction step silently do nothing.
        private static func emptyTree(root: AXNode, nodeCount: Int) -> [UIFinding] {
            guard nodeCount < 2 else { return [] }
            return [
                UIFinding(
                    rule: "empty-tree",
                    severity: .error,
                    message: "accessibility tree has \(nodeCount) node(s) under "
                        + "\(describe(root)); the enhanced-user-interface flag most likely "
                        + "failed, so no node is addressable",
                    path: rolePath(root),
                    frame: root.frame
                )
            ]
        }

        /// `out-of-bounds`: a node's frame leaves the scene rectangle.
        ///
        /// Catches content pushed outside the window by a fixed frame, a negative padding or
        /// a layout that assumed a wider container. The pixels are cropped away, so the
        /// screenshot looks merely "tight" while the control is unreachable.
        private static func outOfBounds(flat: [FlatNode], size: CGSize) -> [UIFinding] {
            guard size.width > 0, size.height > 0 else { return [] }
            let sceneBounds = bounds(of: size)
            var findings: [UIFinding] = []
            for entry in flat {
                let frame = entry.node.frame
                guard isMeasurable(frame) else { continue }
                // Scrolled content below the fold is correct, not escaped layout.
                guard !isInsideScrollContainer(entry, in: flat) else { continue }
                let edges = overflowEdges(of: frame, in: sceneBounds)
                guard !edges.isEmpty else { continue }
                findings.append(
                    UIFinding(
                        rule: "out-of-bounds",
                        severity: .error,
                        message: "\(describe(entry.node)) at \(frameText(frame)) escapes the "
                            + "\(number(size.width))x\(number(size.height)) scene by "
                            + "\(edges.joined(separator: ", "))",
                        path: entry.path,
                        frame: frame
                    )
                )
            }
            return findings
        }

        /// `clipped-child`: a node's frame escapes its parent's frame.
        ///
        /// The truncation detector. A label wider than its container, a row taller than the
        /// list that holds it, a popover that outgrew its anchor: all of them render clipped
        /// and all of them look deliberate in a screenshot until you know the child's real
        /// extent. Only parents with a real frame participate, so unmeasured containers
        /// cannot manufacture violations.
        private static func clippedChild(flat: [FlatNode]) -> [UIFinding] {
            var findings: [UIFinding] = []
            for entry in flat {
                guard let parentIndex = entry.parent else { continue }
                let parent = flat[parentIndex]
                let frame = entry.node.frame
                guard isMeasurable(frame), isMeasurable(parent.node.frame) else { continue }
                // A scroll viewport publishes its clip rect; its children publish document
                // positions. Overflow against it is the mechanism, not a defect.
                guard !isScrollContainer(parent.node) else { continue }
                let edges = overflowEdges(of: frame, in: parent.node.frame)
                guard !edges.isEmpty else { continue }
                findings.append(
                    UIFinding(
                        rule: "clipped-child",
                        severity: .warning,
                        message: "\(describe(entry.node)) at \(frameText(frame)) escapes its "
                            + "parent \(describe(parent.node)) at \(frameText(parent.node.frame)) "
                            + "by \(edges.joined(separator: ", ")); content is clipped",
                        path: entry.path,
                        frame: frame
                    )
                )
            }
            return findings
        }

        /// `tiny-hit-target`: an interactive node smaller than this project's own floor.
        ///
        /// Catches a control that shrank because its icon shrank, or because a `.frame` was
        /// applied to the label rather than to the button. Below 22x22 the affordance is hard
        /// to hit with a pointer and effectively impossible with a trackpad under motion.
        private static func tinyHitTarget(flat: [FlatNode]) -> [UIFinding] {
            var findings: [UIFinding] = []
            for entry in flat where isInteractive(entry.node) {
                let frame = entry.node.frame
                guard isMeasurable(frame) else { continue }
                let area = frame.width * frame.height
                guard area < minimumHitArea || min(frame.width, frame.height) < minimumHitEdge else { continue }
                findings.append(
                    UIFinding(
                        rule: "tiny-hit-target",
                        severity: .warning,
                        message: "\(describe(entry.node)) is \(number(frame.width))x"
                            + "\(number(frame.height)) pt (\(number(frame.width * frame.height)) sq pt), "
                            + "under this project's own \(number(minimumHitTarget))x"
                            + "\(number(minimumHitTarget)) pt RowIconButton affordance",
                        path: entry.path,
                        frame: frame
                    )
                )
            }
            return findings
        }

        /// `unlabeled-control`: an interactive node carrying no label, value, placeholder,
        /// identifier or help.
        ///
        /// Two bugs in one. VoiceOver announces the control as its bare role, and the
        /// harness's own `AXDump.find` — which matches on identifier, label or placeholder —
        /// cannot address it, so no interaction step can ever exercise it. Catches an icon-only
        /// Button that lost its `.accessibilityLabel`.
        ///
        /// A placeholder counts. An empty SwiftUI `TextField` publishes no label at all, only
        /// `AXPlaceholderValue`, and that string is both what VoiceOver announces and what
        /// `find` resolves a `type` step against — so a field with one is neither unannounced
        /// nor unaddressable, and flagging it would be a false positive on every text field
        /// in the app.
        private static func unlabeledControl(flat: [FlatNode]) -> [UIFinding] {
            var findings: [UIFinding] = []
            for entry in flat where isInteractive(entry.node) {
                let node = entry.node
                guard isMeasurable(node.frame) else { continue }
                let described =
                    trimmed(node.label) ?? trimmed(node.value)
                    ?? trimmed(node.placeholder) ?? trimmed(node.identifier) ?? trimmed(node.help)
                guard described == nil else { continue }
                findings.append(
                    UIFinding(
                        rule: "unlabeled-control",
                        severity: .error,
                        message: "\(rolePath(node)) at \(frameText(node.frame)) has no label, "
                            + "value, placeholder, identifier or help; it is unannounced to "
                            + "VoiceOver and unaddressable by harness interaction steps",
                        path: entry.path,
                        frame: node.frame
                    )
                )
            }
            return findings
        }

        /// `overlapping-controls`: two unrelated interactive nodes sitting on top of each other.
        ///
        /// Catches the layout where one control eats another's clicks — a ZStack ordering
        /// mistake, an overlay that forgot `.allowsHitTesting(false)`, a row action drifting
        /// under a trailing accessory. The pixels can look fine; only the frames disagree.
        /// Ancestor/descendant pairs are excluded because containment is how the tree works.
        private static func overlappingControls(flat: [FlatNode]) -> [UIFinding] {
            // Sorted first so the pair sweep emits pairs in lexicographic key order; the cap
            // then truncates a stable prefix rather than an arbitrary subset.
            let controls = flat.filter { isInteractive($0.node) && isMeasurable($0.node.frame) }
                .sorted(by: precedes)
            var findings: [UIFinding] = []
            outer: for (offset, left) in controls.enumerated() {
                for right in controls[(offset + 1)...] {
                    guard let overlap = overlapShare(left.node.frame, right.node.frame) else { continue }
                    guard !isRelated(left, right, in: flat) else { continue }
                    findings.append(overlapFinding(left: left, right: right, share: overlap))
                    if findings.count >= overlapFindingLimit { break outer }
                }
            }
            return findings
        }

        /// `duplicate-identifier`: several nodes share an identifier *and* a label.
        ///
        /// `find` matches identifier first, so two nodes agreeing on both are genuinely
        /// indistinguishable and a `press` step can silently retarget itself. The label must
        /// collide too: SwiftUI auto-stamps `Image(systemName:)` names as identifiers, so
        /// eight `xmark` remove buttons on one pane are normal and each stays addressable by
        /// its own label. One finding per group keeps the output bounded.
        private static func duplicateIdentifier(flat: [FlatNode]) -> [UIFinding] {
            var groups: [String: [FlatNode]] = [:]
            for entry in flat {
                guard let identifier = trimmed(entry.node.identifier) else { continue }
                groups[identifier + "\u{1}" + (trimmed(entry.node.label) ?? ""), default: []].append(entry)
            }
            var findings: [UIFinding] = []
            for key in groups.keys.sorted() {
                guard let entries = groups[key], entries.count > 1 else { continue }
                let sortedEntries = entries.sorted(by: precedes)
                guard let first = sortedEntries.first else { continue }
                findings.append(
                    UIFinding(
                        rule: "duplicate-identifier",
                        severity: .warning,
                        message: "identifier \"\(clip(trimmed(first.node.identifier) ?? ""))\" and label "
                            + "\"\(clip(trimmed(first.node.label) ?? ""))\" are shared by "
                            + "\(sortedEntries.count) nodes (\(pathList(sortedEntries))); "
                            + "find() and interaction steps cannot address them unambiguously",
                        path: first.path,
                        frame: first.node.frame
                    )
                )
            }
            return findings
        }

        /// `text-contrast`: a readable static-text node resolves below its WCAG AA
        /// threshold. Samples without measurable geometry or an AX text match stay quiet:
        /// absent recorder or accessibility information is not a contrast violation.
        private static func textContrast(
            flat: [FlatNode],
            textSamples: [TextRoleSample]
        ) -> [UIFinding] {
            let staticTexts =
                flat
                .filter { $0.node.role.lowercased() == "axstatictext" && isMeasurable($0.node.frame) }
                .sorted(by: precedes)
            let samples = textSamples.sorted { left, right in
                let leftKey = (finite(left.frame.minY), finite(left.frame.minX), left.role)
                let rightKey = (finite(right.frame.minY), finite(right.frame.minX), right.role)
                return leftKey < rightKey
            }

            var findings: [UIFinding] = []
            for sample in samples {
                guard isMeasurable(sample.frame),
                    sample.pointSize.isFinite,
                    sample.pointSize > 0,
                    isResolved(sample.foreground),
                    isResolved(sample.ground),
                    let entry = staticTexts.first(where: {
                        overlapShare(
                            $0.node.frame,
                            sample.frame,
                            minimum: textFrameOverlapThreshold
                        )
                    })
                else { continue }

                let threshold =
                    sample.pointSize >= 18
                        || (sample.pointSize >= 14 && sample.isBold)
                    ? 3.0
                    : 4.5
                let ratio = wcagContrast(sample.foreground, sample.ground)
                guard ratio + 0.005 < threshold else { continue }

                let label = clip(
                    trimmed(entry.node.value)
                        ?? trimmed(entry.node.label)
                        ?? trimmed(entry.node.placeholder)
                        ?? ""
                )
                findings.append(
                    UIFinding(
                        rule: "text-contrast",
                        severity: .error,
                        message: "AXStaticText \"\(label)\" renders role \(sample.role) at "
                            + "\(decimal(ratio, places: 2)):1 against its ground; WCAG AA requires "
                            + "\(decimal(threshold, places: 1)):1 at \(number(sample.pointSize)) pt",
                        path: entry.path,
                        frame: entry.node.frame
                    )
                )
            }
            return findings
        }

        /// `control-height`: an app-owned interactive node is not on either the Control
        /// scale or the row-pitch scale. `isInteractive` carries the closed scroller-part
        /// exemption shared by every interactive-node rule.
        ///
        /// Nodes taller than the tallest row pitch are exempt from the scale. A pressable
        /// *card* — the menu's transcript well, a session row carrying a preview line — is
        /// a content container that happens to own an action, not a control, and its
        /// height is set by the grid rather than by the control scale. Policing those
        /// against 24/28/32/40 flags correct UI, which is the failure mode this rule set
        /// exists to avoid. They are still held to the 4 pt grid.
        private static func controlHeight(flat: [FlatNode]) -> [UIFinding] {
            var findings: [UIFinding] = []
            for entry in flat where isInteractive(entry.node) {
                let frame = entry.node.frame
                guard isMeasurable(frame) else { continue }
                let height = (frame.height * 10).rounded() / 10
                guard !allowedControlHeights.contains(height) else { continue }
                if height > containerHeightFloor {
                    let offGrid = abs(height - gridUnit * (height / gridUnit).rounded())
                    guard offGrid > gridEpsilon else { continue }
                }
                findings.append(
                    UIFinding(
                        rule: "control-height",
                        severity: .warning,
                        message: "\(describe(entry.node)) is \(number(height)) pt tall; "
                            + "the Control scale is 24 / 28 / 32 / 40 and the Row scale "
                            + "is 32 / 40 / 44 / 64",
                        path: entry.path,
                        frame: frame
                    )
                )
            }
            return findings
        }

        /// `off-grid`: an accessibility-measurable, explicitly bounded column width
        /// leaves the 4 pt grid.
        ///
        /// The exemption list is closed:
        /// E1. Every role except AXScrollArea. Text, image and text-area extents are
        ///     intrinsic; paint-only card and tile bounds are absent AX information.
        /// E2. AppKit's synthesised scroller parts, which are not AXScrollArea nodes
        ///     and are already excluded from interactive rules by `isInteractive`.
        /// E3. Any tested width below 4 pt: hairlines and marks are not layout columns.
        /// E4. Interactive widths hug font-derived labels and are not tested.
        /// E5. Interactive heights are owned by `control-height`, avoiding duplicates.
        /// E6. Non-measurable frames are unknown data, not violations.
        /// E7. All origins are exempt. Their positions accumulate intrinsic type metrics
        ///     as well as token spacing, so AX cannot attribute an off-grid origin to a
        ///     designer-controlled value without crying wolf.
        /// E8. Scroll heights and outer viewports whose width fills the window remainder
        ///     are derived from available space. Only bounded internal viewport widths,
        ///     such as Sessions columns, remain controlled subjects.
        private static func offGrid(
            flat: [FlatNode],
            size: CGSize
        ) -> [UIFinding] {
            let subjects = flat.filter {
                $0.node.role.lowercased() == "axscrollarea"
                    && !isWindowRemainderViewport($0.node.frame, sceneSize: size)
            }.sorted(by: precedes)
            var findings: [UIFinding] = []
            for entry in subjects {
                let node = entry.node
                let frame = node.frame
                guard isMeasurable(frame) else { continue }

                let width = frame.width
                guard width >= gridUnit,
                    abs(width - gridUnit * (width / gridUnit).rounded()) > gridEpsilon
                else {
                    continue
                }

                findings.append(
                    UIFinding(
                        rule: "off-grid",
                        severity: .warning,
                        message: "\(describe(node)) is off the 4 pt grid: width=\(number(width))",
                        path: entry.path,
                        frame: frame
                    )
                )
                if findings.count >= offGridFindingLimit { break }
            }
            return findings
        }

        /// The outer pane scroll view is sized by the scene remainder, not by a fixed
        /// content-width token. In every harness shell it occupies more than half the
        /// scene and terminates at the standard 24 pt trailing content inset.
        private static func isWindowRemainderViewport(_ frame: CGRect, sceneSize: CGSize) -> Bool {
            let trailingContentInset: CGFloat = 24
            return isMeasurable(frame)
                && sceneSize.width > 0
                && frame.width > sceneSize.width / 2
                && abs(frame.maxX - (sceneSize.width - trailingContentInset)) <= gridEpsilon
        }

        // MARK: - Flattened tree

        /// One node plus the context the rules need: its role path, its parent and its
        /// pre-order index. Pre-order guarantees `parent < index`, which makes the ancestor
        /// walk terminating by construction.
        fileprivate struct FlatNode {
            let node: AXNode
            let path: String
            let parent: Int?
            let index: Int
        }

        private static func flatten(_ root: AXNode) -> [FlatNode] {
            var result: [FlatNode] = []
            appendSubtree(root, path: rolePath(root), parent: nil, into: &result)
            return result
        }

        private static func appendSubtree(
            _ node: AXNode,
            path: String,
            parent: Int?,
            into result: inout [FlatNode]
        ) {
            let index = result.count
            result.append(FlatNode(node: node, path: path, parent: parent, index: index))
            for child in node.children {
                appendSubtree(child, path: path + "/" + rolePath(child), parent: index, into: &result)
            }
        }

        // MARK: - Geometry helpers

        private static func bounds(of size: CGSize) -> CGRect {
            CGRect(origin: .zero, size: size)
        }

        /// A frame carries usable information only when it has real, finite extent. Zero-size
        /// and non-finite frames mean "not measured" and are never treated as violations.
        private static func isMeasurable(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.size.width.isFinite && rect.size.height.isFinite
                && rect.size.width > 0 && rect.size.height > 0
        }

        /// Human-readable list of the edges by which `rect` pokes outside `container`,
        /// ignoring overhangs within `epsilon`. Empty means contained.
        private static func overflowEdges(of rect: CGRect, in container: CGRect) -> [String] {
            let candidates: [(String, CGFloat)] = [
                ("left", container.minX - rect.minX),
                ("top", container.minY - rect.minY),
                ("right", rect.maxX - container.maxX),
                ("bottom", rect.maxY - container.maxY),
            ]
            return
                candidates
                .filter { $0.1 > epsilon }
                .map { "\(number($0.1)) pt past the \($0.0) edge" }
        }

        /// Fraction of the smaller rectangle covered by the intersection, or `nil` when the
        /// pair does not overlap enough to matter.
        private static func overlapShare(_ first: CGRect, _ second: CGRect) -> Double? {
            let intersection = first.intersection(second)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            let smaller = min(Double(first.width * first.height), Double(second.width * second.height))
            guard smaller > 0 else { return nil }
            let covered = Double(intersection.width * intersection.height) / smaller
            return covered > overlapAreaThreshold ? covered : nil
        }

        /// Whether the two frames overlap at least `minimum` of the smaller area.
        private static func overlapShare(
            _ first: CGRect,
            _ second: CGRect,
            minimum: Double
        ) -> Bool {
            let intersection = first.intersection(second)
            guard !intersection.isNull, !intersection.isEmpty else { return false }
            let smaller = min(Double(first.width * first.height), Double(second.width * second.height))
            guard smaller > 0 else { return false }
            return Double(intersection.width * intersection.height) / smaller >= minimum
        }

        private static func overlapFinding(
            left: FlatNode,
            right: FlatNode,
            share: Double
        ) -> UIFinding {
            UIFinding(
                rule: "overlapping-controls",
                severity: .warning,
                message: "\(describe(left.node)) at \(frameText(left.node.frame)) overlaps "
                    + "\(describe(right.node)) at \(frameText(right.node.frame)) over "
                    + "\(percent(share, decimals: 1)) of the smaller control; one of them "
                    + "will swallow the other's clicks",
                path: left.path,
                frame: left.node.frame
            )
        }

        private static func isRelated(_ left: FlatNode, _ right: FlatNode, in flat: [FlatNode]) -> Bool {
            isAncestor(left.index, of: right.index, in: flat)
                || isAncestor(right.index, of: left.index, in: flat)
        }

        private static func isAncestor(_ ancestor: Int, of descendant: Int, in flat: [FlatNode]) -> Bool {
            var cursor = flat[descendant].parent
            while let current = cursor {
                if current == ancestor { return true }
                cursor = flat[current].parent
            }
            return false
        }

        // MARK: - Ordering

        /// Total order over findings: severity, rule, path, frame origin, message. Explicit
        /// rather than inherited from traversal, because `Array.sorted` is not stable and the
        /// manifest is diffed byte for byte.
        private static func ordered(_ findings: [UIFinding]) -> [UIFinding] {
            findings.sorted { left, right in sortKey(left) < sortKey(right) }
        }

        private static func sortKey(_ finding: UIFinding) -> (Int, String, String, Double, Double, String) {
            (
                finding.severity == .error ? 0 : 1,
                finding.rule,
                finding.path,
                finite(finding.frame.origin.x),
                finite(finding.frame.origin.y),
                finding.message
            )
        }

        /// Total order over nodes, used to make pair selection and duplicate reporting stable.
        /// The pre-order index is the final tiebreak, so siblings with identical roles and
        /// frames still compare deterministically.
        private static func precedes(_ left: FlatNode, _ right: FlatNode) -> Bool {
            let leftKey = (left.path, finite(left.node.frame.minX), finite(left.node.frame.minY), left.index)
            let rightKey = (right.path, finite(right.node.frame.minX), finite(right.node.frame.minY), right.index)
            return leftKey < rightKey
        }

        // MARK: - Text helpers

        private static func isInteractive(_ node: AXNode) -> Bool {
            guard interactiveRoles.contains(node.role.lowercased()) else { return false }
            guard let subrole = trimmed(node.subrole) else { return true }
            return !scrollerPartSubroles.contains(subrole.lowercased())
        }

        private static func isScrollContainer(_ node: AXNode) -> Bool {
            scrollContainerRoles.contains(node.role.lowercased())
        }

        /// True when a strict ancestor is a scroll viewport, so this node's frame is a
        /// document-space position that the scene rectangle cannot judge.
        private static func isInsideScrollContainer(_ entry: FlatNode, in flat: [FlatNode]) -> Bool {
            var cursor = entry.parent
            while let current = cursor {
                if isScrollContainer(flat[current].node) { return true }
                cursor = flat[current].parent
            }
            return false
        }

        private static func isResolved(_ color: (r: Double, g: Double, b: Double)) -> Bool {
            color.r.isFinite && color.g.isFinite && color.b.isFinite
        }

        private static func wcagContrast(
            _ foreground: (r: Double, g: Double, b: Double),
            _ ground: (r: Double, g: Double, b: Double)
        ) -> Double {
            let foregroundLuminance = wcagLuminance(foreground)
            let groundLuminance = wcagLuminance(ground)
            return (max(foregroundLuminance, groundLuminance) + 0.05)
                / (min(foregroundLuminance, groundLuminance) + 0.05)
        }

        private static func wcagLuminance(_ color: (r: Double, g: Double, b: Double)) -> Double {
            0.2126 * wcagLinear(color.r)
                + 0.7152 * wcagLinear(color.g)
                + 0.0722 * wcagLinear(color.b)
        }

        private static func wcagLinear(_ component: Double) -> Double {
            let value = min(max(component, 0), 1)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        private static func rolePath(_ node: AXNode) -> String {
            node.role.isEmpty ? "?" : node.role
        }

        /// Names a node the way a human would point at it on screen: identifier first (the
        /// harness handle), then label, value, placeholder or help. Placeholder sits after
        /// value but ahead of help because for an empty text field it is the only thing on
        /// the element, and "AXTextField placeholder …" is how a reader finds it on screen.
        private static func describe(_ node: AXNode) -> String {
            let role = rolePath(node)
            if let identifier = trimmed(node.identifier) { return "\(role) #\(clip(identifier))" }
            if let label = trimmed(node.label) { return "\(role) \"\(clip(label))\"" }
            if let value = trimmed(node.value) { return "\(role) value \"\(clip(value))\"" }
            if let placeholder = trimmed(node.placeholder) { return "\(role) placeholder \"\(clip(placeholder))\"" }
            if let help = trimmed(node.help) { return "\(role) help \"\(clip(help))\"" }
            return role
        }

        private static func pathList(_ entries: [FlatNode]) -> String {
            let shown = entries.prefix(duplicatePathLimit).map(\.path).joined(separator: ", ")
            let hidden = entries.count - min(entries.count, duplicatePathLimit)
            return hidden > 0 ? "\(shown), +\(hidden) more" : shown
        }

        private static func trimmed(_ text: String?) -> String? {
            guard let text else { return nil }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        /// Collapses newlines and truncates, so one runaway label cannot turn a manifest line
        /// into a paragraph.
        private static func clip(_ text: String) -> String {
            let flatText =
                text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            guard flatText.count > messageTextLimit else { return flatText }
            return String(flatText.prefix(messageTextLimit)) + "..."
        }

        private static func frameText(_ rect: CGRect) -> String {
            "(\(number(rect.origin.x)), \(number(rect.origin.y)), "
                + "\(number(rect.size.width))x\(number(rect.size.height)))"
        }

        /// One decimal place, with negative zero normalised away so the same geometry always
        /// prints the same bytes.
        private static func number(_ value: CGFloat) -> String {
            let scaled = (finite(value) * 10).rounded()
            return String(format: "%.1f", scaled == 0 ? 0 : scaled / 10)
        }

        private static func decimal(_ value: Double, places: Int) -> String {
            String(format: "%.\(places)f", value)
        }

        private static func percent(_ fraction: Double, decimals: Int) -> String {
            let value = finite(CGFloat(fraction)) * 100
            return String(format: "%.\(decimals)f%%", value)
        }

        private static func finite(_ value: CGFloat) -> Double {
            value.isFinite ? Double(value) : 0
        }
    }

#endif
