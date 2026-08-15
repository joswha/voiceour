// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/Voiceour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Combine
    import Foundation
    import SwiftUI

    @MainActor
    enum UIFlowRunner {
        static let waitBudget = 3_000
        static let actionSettle = 30

        static func run(_ flow: UIFlow, request: UIHarnessRequest) -> UIFlowResult {
            let context = flow.fixture.makeContext()
            context.transitions.attach(to: context.coordinator)
            defer { context.teardown() }

            let recorder = TextRoleRecorder()
            let previousRecorder = RenderOverrides.textRoleRecorder
            RenderOverrides.textRoleRecorder = recorder
            defer { RenderOverrides.textRoleRecorder = previousRecorder }

            // `makeContext()` above pinned every process seam, including
            // `forceLegacyGlass = true`, so a flow drives the painted path on any host. An
            // `os26` flow exists to drive the OTHER branch, and this is the flow-layer twin
            // of `UIHarnessSystemGlassScope`: release the seam after the fixture is built,
            // because coordinator construction re-pins it, and restore it here rather than
            // leaving the native path to contaminate a portable flow later in the same
            // process.
            let releasesLegacyGlass = flow.tags.contains("os26")
            let previousForceLegacyGlass = RenderOverrides.forceLegacyGlass
            if releasesLegacyGlass { RenderOverrides.forceLegacyGlass = false }
            defer {
                if releasesLegacyGlass { RenderOverrides.forceLegacyGlass = previousForceLegacyGlass }
            }

            let host = resolve(flow.host, context: context)
            var lines: [UIExpectationLine] = []
            var frames: [UIFlowFrame] = []
            var failures: [UIFlowFailure] = []
            var errorDescription: String?
            var expectationOrdinal = 0

            do {
                try UIHarnessRuntime.withLiveScene(
                    size: host.size,
                    colorScheme: host.colorScheme,
                    scale: request.scale,
                    build: host.build
                ) { view, window in
                    for (stepIndex, step) in flow.steps.enumerated() {
                        let stepOrdinal = stepIndex + 1
                        switch step {
                        case .act(let action):
                            perform(
                                action,
                                ordinal: stepOrdinal,
                                view: view,
                                window: window,
                                context: context,
                                failures: &failures
                            )
                            UIHarnessRuntime.pump(iterations: actionSettle)

                        case .release(let gate):
                            guard context.release(gate) else {
                                failures.append(
                                    UIFlowFailure(
                                        ordinal: stepOrdinal,
                                        checkpoint: nil,
                                        domain: .action,
                                        expectation: "release gate \(gate.rawValue)",
                                        observed: "gate \(gate.rawValue) was not armed by fixture \(flow.fixture.name)",
                                        selector: nil,
                                        candidates: []
                                    )
                                )
                                continue
                            }

                        case .wait(let condition):
                            if let failure = wait(
                                for: condition,
                                ordinal: stepOrdinal,
                                view: view,
                                context: context
                            ) {
                                failures.append(failure)
                            }

                        case .check(let checkpoint, let expectations):
                            let tree = AXDump.tree(of: view)
                            let needsRaster = expectations.contains { expectation in
                                if case .lintClean = expectation { return true }
                                return false
                            }
                            let capture = needsRaster ? try UIHarnessRuntime.capture(view, scale: request.scale) : nil
                            let findings =
                                needsRaster
                                ? UILint.evaluate(
                                    root: tree,
                                    capture: capture,
                                    size: host.size,
                                    textSamples: recorder.samples
                                )
                                : []

                            for expectation in expectations {
                                expectationOrdinal += 1
                                let line = UIFlowExpectations.evaluate(
                                    expectation,
                                    tree: tree,
                                    context: context,
                                    capture: capture,
                                    findings: findings,
                                    warnings: UIHarnessRuntime.lastInteractionWarnings,
                                    checkpoint: checkpoint,
                                    ordinal: expectationOrdinal
                                )
                                lines.append(line)
                                if !line.passed {
                                    failures.append(
                                        UIFlowFailure(
                                            ordinal: line.ordinal,
                                            checkpoint: checkpoint,
                                            domain: .expectation,
                                            expectation: line.expectation,
                                            observed: line.observed,
                                            selector: line.selector,
                                            candidates: line.candidates
                                        )
                                    )
                                }
                            }

                        case .capture(let name):
                            let tree = AXDump.tree(of: view)
                            let capture = try UIHarnessRuntime.capture(view, scale: request.scale)
                            let findings = UILint.evaluate(
                                root: tree,
                                capture: capture,
                                size: host.size,
                                textSamples: recorder.samples
                            )
                            let frame = UIHarnessMain.reconcileFlowFrame(
                                flowID: flow.id,
                                frame: name,
                                tree: tree,
                                capture: capture,
                                findings: findings,
                                request: request
                            )
                            frames.append(frame)

                            for finding in findings where finding.severity == .error {
                                failures.append(
                                    UIFlowFailure(
                                        ordinal: stepOrdinal,
                                        checkpoint: name,
                                        domain: .lint,
                                        expectation: "captured frame lint clean",
                                        observed: "\(finding.rule): \(finding.message)",
                                        selector: nil,
                                        candidates: []
                                    )
                                )
                            }
                        }
                    }
                }
            } catch {
                errorDescription = describe(error)
            }

            let preliminary = UIFlowResult(
                flow: flow,
                lines: lines,
                transitions: context.transitions.recorded,
                frames: frames,
                failures: failures,
                warnings: UIHarnessRuntime.lastInteractionWarnings,
                error: errorDescription,
                journalStatus: .ok
            )
            let reconciliation = UIHarnessMain.reconcileFlow(preliminary, request: request)
            return UIFlowResult(
                flow: flow,
                lines: lines,
                transitions: context.transitions.recorded,
                frames: frames,
                failures: failures,
                warnings: UIHarnessRuntime.lastInteractionWarnings + reconciliation.warnings,
                error: errorDescription,
                journalStatus: reconciliation.status
            )
        }

        private struct Host {
            let size: CGSize
            let colorScheme: ColorScheme
            let build: @MainActor () -> AnyView
        }

        private static func resolve(_ host: UIFlowHost, context: UIFlowContext) -> Host {
            switch host {
            case .console(let section):
                return Host(size: UISceneCatalog.consoleSize, colorScheme: .dark) {
                    AnyView(ConsoleView(coordinator: context.coordinator, initialSection: section))
                }


            case .menu:
                return Host(size: UISceneCatalog.menuSize, colorScheme: .dark) {
                    AnyView(
                        MenuView(coordinator: context.coordinator)
                            .frame(width: UISceneCatalog.menuSize.width, alignment: .top)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(VoiceourPalette.Ink.void)
                    )
                }

            case .overlay:
                let bridge = OverlayBridge(coordinator: context.coordinator)
                return Host(size: RecordingOverlayMetrics.windowSize, colorScheme: .dark) {
                    AnyView(
                        RecordingOverlayView(
                            model: bridge.model,
                            onCancel: { context.coordinator.cancel() },
                            onFinish: { context.coordinator.stopAndProcess() }
                        )
                    )
                }

            case .custom(let size, let colorScheme, let build):
                return Host(size: size, colorScheme: colorScheme) {
                    build(context)
                }
            }
        }

        private static func perform(
            _ action: UIFlowAction,
            ordinal: Int,
            view: NSView,
            window: NSWindow,
            context: UIFlowContext,
            failures: inout [UIFlowFailure]
        ) {
            switch action {
            case .dictate(let dictateAction):
                switch dictateAction {
                case .start: context.coordinator.start()
                case .stopAndProcess: context.coordinator.stopAndProcess()
                case .cancel: context.coordinator.cancel()
                case .toggle: context.coordinator.toggle()
                }

            case .navigate(let section):
                performInteraction(
                    .press,
                    query: .label(section.label),
                    expectation: action.description,
                    ordinal: ordinal,
                    view: view,
                    window: window,
                    context: context,
                    failures: &failures
                )

            case .press(let query):
                performInteraction(
                    .press,
                    query: query,
                    expectation: action.description,
                    ordinal: ordinal,
                    view: view,
                    window: window,
                    context: context,
                    failures: &failures
                )

            case .click(let query):
                performInteraction(
                    .click,
                    query: query,
                    expectation: action.description,
                    ordinal: ordinal,
                    view: view,
                    window: window,
                    context: context,
                    failures: &failures
                )

            case .type(let text, let query):
                performInteraction(
                    .type(text),
                    query: query,
                    expectation: action.description,
                    ordinal: ordinal,
                    view: view,
                    window: window,
                    context: context,
                    failures: &failures
                )
            }
        }

        private enum InteractionKind {
            case press
            case click
            case type(String)
        }

        private static func performInteraction(
            _ kind: InteractionKind,
            query: UIQuery,
            expectation: String,
            ordinal: Int,
            view: NSView,
            window: NSWindow,
            context: UIFlowContext,
            failures: inout [UIFlowFailure]
        ) {
            let tree = AXDump.tree(of: view)
            let nodes = UIFlowExpectations.matches(query, in: tree)
            guard nodes.count == 1 else {
                let candidates: [String]
                if nodes.isEmpty {
                    candidates =
                        UIFlowExpectations.evaluate(
                            .exists(query),
                            tree: tree,
                            context: context,
                            capture: nil,
                            findings: [],
                            warnings: UIHarnessRuntime.lastInteractionWarnings,
                            checkpoint: "action",
                            ordinal: ordinal
                        ).candidates
                } else {
                    candidates = []
                }
                failures.append(
                    UIFlowFailure(
                        ordinal: ordinal,
                        checkpoint: nil,
                        domain: .action,
                        expectation: expectation,
                        observed: "\(nodes.count) matches",
                        selector: query.description,
                        candidates: candidates
                    )
                )
                return
            }

            guard let target = interactionTarget(for: nodes[0], in: tree) else {
                failures.append(
                    UIFlowFailure(
                        ordinal: ordinal,
                        checkpoint: nil,
                        domain: .action,
                        expectation: expectation,
                        observed: "1 match, but the node has no unique UIInteraction address",
                        selector: query.description,
                        candidates: []
                    )
                )
                return
            }

            let step: UIStep
            switch kind {
            case .press: step = .press(target)
            case .click: step = .click(target)
            case .type(let text): step = .type(text, into: target)
            }
            let warnings = UIInteraction.apply([step], in: view, window: window)
            UIHarnessRuntime.appendInteractionWarnings(warnings)
            for warning in warnings {
                failures.append(
                    UIFlowFailure(
                        ordinal: ordinal,
                        checkpoint: nil,
                        domain: .action,
                        expectation: expectation,
                        observed: warning,
                        selector: query.description,
                        candidates: []
                    )
                )
            }
        }

        private static func interactionTarget(for node: AXNode, in tree: AXNode) -> String? {
            let candidates = [node.identifier, node.label, node.placeholder].compactMap { $0 }
            for candidate in candidates where !candidate.isEmpty {
                guard let resolved = AXDump.find(candidate, in: tree) else { continue }
                if sameNode(resolved, node) { return candidate }
            }
            return nil
        }

        private static func sameNode(_ left: AXNode, _ right: AXNode) -> Bool {
            left.role == right.role
                && left.subrole == right.subrole
                && left.label == right.label
                && left.value == right.value
                && left.placeholder == right.placeholder
                && left.identifier == right.identifier
                && left.frame == right.frame
        }

        private static func wait(
            for condition: UIWait,
            ordinal: Int,
            view: NSView,
            context: UIFlowContext
        ) -> UIFlowFailure? {
            switch condition {
            case .settle(let requestedTurns):
                let turns = max(0, requestedTurns)
                for _ in 0..<min(turns, waitBudget) {
                    UIHarnessRuntime.pump(iterations: 1)
                }
                guard turns <= waitBudget else {
                    return UIFlowFailure(
                        ordinal: ordinal,
                        checkpoint: nil,
                        domain: .wait,
                        expectation: condition.description,
                        observed: "settled \(waitBudget) turns; not observed within \(waitBudget) turns",
                        selector: nil,
                        candidates: []
                    )
                }
                return nil

            case .state(let pattern):
                if pattern.matches(context.coordinator.state) { return nil }
                for _ in 0..<waitBudget {
                    UIHarnessRuntime.pump(iterations: 1)
                    if pattern.matches(context.coordinator.state) { return nil }
                }
                let current = UIStatePattern.of(context.coordinator.state)
                return UIFlowFailure(
                    ordinal: ordinal,
                    checkpoint: nil,
                    domain: .wait,
                    expectation: condition.description,
                    observed: "current state \(current.rawValue); not observed within \(waitBudget) turns",
                    selector: nil,
                    candidates: []
                )

            case .element(let query):
                if !UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).isEmpty { return nil }
                for _ in 0..<waitBudget {
                    UIHarnessRuntime.pump(iterations: 1)
                    if !UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).isEmpty { return nil }
                }
                let count = UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).count
                return UIFlowFailure(
                    ordinal: ordinal,
                    checkpoint: nil,
                    domain: .wait,
                    expectation: condition.description,
                    observed: "\(count) matches; not observed within \(waitBudget) turns",
                    selector: query.description,
                    candidates: []
                )

            case .absent(let query):
                if UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).isEmpty { return nil }
                for _ in 0..<waitBudget {
                    UIHarnessRuntime.pump(iterations: 1)
                    if UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).isEmpty { return nil }
                }
                let count = UIFlowExpectations.matches(query, in: AXDump.tree(of: view)).count
                return UIFlowFailure(
                    ordinal: ordinal,
                    checkpoint: nil,
                    domain: .wait,
                    expectation: condition.description,
                    observed: "\(count) matches; not observed within \(waitBudget) turns",
                    selector: query.description,
                    candidates: []
                )
            }
        }

        private static func describe(_ error: Error) -> String {
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                return description
            }
            return String(describing: error)
        }
    }

    @MainActor
    private final class OverlayBridge {
        let model = RecordingOverlayModel()
        private var cancellables: [AnyCancellable] = []

        init(coordinator: DictationCoordinator) {
            cancellables.append(
                coordinator.statePublisher.sink { [weak model] state in
                    guard let model else { return }
                    model.update(state)
                    if !state.isActive { model.reset() }
                }
            )
            cancellables.append(
                coordinator.inputMeter.$level.sink { [weak model] level in
                    model?.record(level)
                }
            )
            cancellables.append(
                coordinator.inputMeter.$live.sink { [weak model] live in
                    model?.updateCaptureLive(live)
                }
            )
        }
    }

#endif
