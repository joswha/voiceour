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

    import Foundation

    enum UIFlowExpectations {
        /// Returns the complete match set in the hierarchy's document order.
        static func matches(_ query: UIQuery, in tree: AXNode) -> [AXNode] {
            var result: [AXNode] = []
            collectMatches(query, in: tree, into: &result)
            return result
        }

        @MainActor
        static func evaluate(
            _ expectation: UIExpectation,
            tree: AXNode,
            context: UIFlowContext,
            capture: UICapture?,
            findings: [UIFinding],
            checkpoint: String,
            ordinal: Int
        ) -> UIExpectationLine {
            let result: Evaluation

            switch expectation {
            case .exists(let query):
                let nodes = matches(query, in: tree)
                result = Evaluation(
                    passed: !nodes.isEmpty,
                    observed: matchCount(nodes.count),
                    candidates: nodes.isEmpty ? candidates(for: query, in: tree) : []
                )

            case .absent(let query):
                let nodes = matches(query, in: tree)
                result = Evaluation(passed: nodes.isEmpty, observed: matchCount(nodes.count))

            case .count(let query, let count):
                let nodes = matches(query, in: tree)
                let passed = count.accepts(nodes.count)
                result = Evaluation(
                    passed: passed,
                    observed: matchCount(nodes.count),
                    candidates: !passed && nodes.isEmpty ? candidates(for: query, in: tree) : []
                )

            case .enabled(let query, let expected):
                result = evaluateUnique(query, in: tree) { node in
                    let actual = node.enabled
                    return Evaluation(
                        passed: actual == expected,
                        observed: actual.map { String(describing: $0) } ?? "unknown"
                    )
                }

            case .selected(let query, let expected):
                result = evaluateUnique(query, in: tree) { node in
                    let actual = node.selected
                    return Evaluation(
                        passed: actual == expected,
                        observed: actual.map { String(describing: $0) } ?? "unknown"
                    )
                }

            case .value(let query, let rule):
                result = evaluateUnique(query, in: tree) { node in
                    let actual = node.value ?? ""
                    return Evaluation(passed: rule.accepts(actual), observed: UIQuery.quote(actual))
                }

            case .label(let query, let rule):
                result = evaluateUnique(query, in: tree) { node in
                    let actual = node.label ?? ""
                    return Evaluation(passed: rule.accepts(actual), observed: UIQuery.quote(actual))
                }

            case .role(let query, let expected):
                result = evaluateUnique(query, in: tree) { node in
                    Evaluation(passed: node.role == expected, observed: node.role)
                }

            case .text(let rule, let count):
                let observed = allNodes(in: tree).reduce(into: 0) { total, node in
                    guard isStaticText(node.role) else { return }
                    if rule.accepts(node.value ?? node.label ?? "") { total += 1 }
                }
                result = Evaluation(passed: count.accepts(observed), observed: matchCount(observed))

            case .state(let expected):
                let actual = UIStatePattern.of(context.coordinator.state)
                result = Evaluation(passed: actual == expected, observed: actual.rawValue)

            case .transitions(let expected, let order):
                result = Evaluation(
                    passed: context.transitions.matches(expected, order: order),
                    observed: context.transitions.rendered.isEmpty ? "none" : context.transitions.rendered
                )

            case .model(let key, let rule):
                let probe = modelProbe(key, context: context)
                result = Evaluation(passed: rule.accepts(probe.value), observed: probe.rendered)

            case .lintClean:
                guard capture != nil else {
                    result = Evaluation(passed: false, observed: "capture unavailable")
                    break
                }
                let failingRules = findings.reduce(into: [String]()) { rules, finding in
                    guard finding.severity == .error, !rules.contains(finding.rule) else { return }
                    rules.append(finding.rule)
                }
                result = Evaluation(
                    passed: failingRules.isEmpty,
                    observed:
                        failingRules.isEmpty
                        ? "no error findings"
                        : "error rules: \(failingRules.joined(separator: ", "))"
                )
            }

            return UIExpectationLine(
                ordinal: ordinal,
                checkpoint: checkpoint,
                passed: result.passed,
                expectation: expectation.expectation,
                observed: result.observed,
                selector: expectation.selector?.description,
                candidates: result.candidates
            )
        }

        private struct Evaluation {
            let passed: Bool
            let observed: String
            let candidates: [String]

            init(passed: Bool, observed: String, candidates: [String] = []) {
                self.passed = passed
                self.observed = observed
                self.candidates = candidates
            }
        }

        private struct ModelProbe {
            let value: String
            let rendered: String
        }

        private static func collectMatches(_ query: UIQuery, in node: AXNode, into result: inout [AXNode]) {
            if nodeMatches(query, node: node) { result.append(node) }
            for child in node.children {
                collectMatches(query, in: child, into: &result)
            }
        }

        private static func nodeMatches(_ query: UIQuery, node: AXNode) -> Bool {
            switch query {
            case .id(let value): return node.identifier == value
            case .label(let value): return node.label == value
            case .value(let value): return node.value == value
            case .placeholder(let value): return node.placeholder == value
            case .labelContains(let value): return node.label?.contains(value) ?? false
            case .role(let value): return node.role == value
            case .all(let queries): return queries.allSatisfy { nodeMatches($0, node: node) }
            }
        }

        private static func evaluateUnique(
            _ query: UIQuery,
            in tree: AXNode,
            evaluate: (AXNode) -> Evaluation
        ) -> Evaluation {
            let nodes = matches(query, in: tree)
            guard nodes.count == 1 else {
                return Evaluation(
                    passed: false,
                    observed: matchCount(nodes.count),
                    candidates: nodes.isEmpty ? candidates(for: query, in: tree) : []
                )
            }
            return evaluate(nodes[0])
        }

        private static func allNodes(in tree: AXNode) -> [AXNode] {
            var nodes = [tree]
            for child in tree.children { nodes.append(contentsOf: allNodes(in: child)) }
            return nodes
        }

        private static func isStaticText(_ role: String) -> Bool {
            role.caseInsensitiveCompare("AXStaticText") == .orderedSame
        }

        private static func matchCount(_ count: Int) -> String {
            count == 1 ? "1 match" : "\(count) matches"
        }

        private static func candidates(for query: UIQuery, in tree: AXNode) -> [String] {
            let needles = queryNeedles(query).filter { !$0.isEmpty }
            guard !needles.isEmpty else { return [] }

            return allNodes(in: tree)
                .filter { node in
                    let fields = [node.label, node.identifier, node.placeholder].compactMap { $0 }
                    return fields.contains { field in
                        needles.contains { needle in sharesCaseInsensitiveSubstring(field, needle) }
                    }
                }
                .map(candidateDescription)
                .sorted()
                .prefix(8)
                .map { $0 }
        }

        private static func queryNeedles(_ query: UIQuery) -> [String] {
            switch query {
            case .id(let value), .label(let value), .value(let value), .placeholder(let value),
                .labelContains(let value):
                return [value]
            case .role:
                return []
            case .all(let queries):
                return queries.flatMap(queryNeedles)
            }
        }

        private static func sharesCaseInsensitiveSubstring(_ left: String, _ right: String) -> Bool {
            let left = left.lowercased()
            let right = right.lowercased()
            return left.contains(right) || right.contains(left)
        }

        private static func candidateDescription(_ node: AXNode) -> String {
            let label = node.label ?? node.placeholder ?? ""
            return "\(node.role) \(UIQuery.quote(label)) id=\(node.identifier ?? "-")"
        }

        @MainActor
        private static func modelProbe(_ key: UIModelKey, context: UIFlowContext) -> ModelProbe {
            let coordinator = context.coordinator
            switch key {
            case .transcript:
                return quotedProbe(coordinator.lastTranscript)
            case .outcome:
                return quotedProbe(coordinator.lastOutcome?.summary.label ?? "")
            case .errorMessage:
                return quotedProbe(coordinator.errorMessage ?? "")
            case .targetLabel:
                return quotedProbe(coordinator.targetLabel)
            case .recentSessionCount:
                return scalarProbe(coordinator.recentSessions.count)
            case .glossaryTermCount:
                return scalarProbe(coordinator.settings.glossary.filter { $0.tombstonedAt == nil }.count)
            case .cleanupEnabled:
                return scalarProbe(coordinator.settings.cleanupEnabled)
            case .activeBackend:
                return quotedProbe(coordinator.activeBackend)
            case .selectedModelVariant:
                return quotedProbe(coordinator.settings.asrModelVariant.rawValue)
            case .processingInFlight:
                return scalarProbe(coordinator.isProcessingInFlight)
            case .deliveredText:
                return quotedProbe(context.effects.lastDelivery?.text ?? "")
            case .deliveryBundleID:
                return quotedProbe(context.effects.lastDelivery?.bundleID ?? "")
            case .deliveryDisposition:
                return quotedProbe(context.effects.lastDelivery?.disposition ?? "")
            case .deliveryCount:
                return scalarProbe(context.effects.deliveries.count)
            case .pasteboardText:
                return quotedProbe(context.effects.pasteboardWrites.last ?? "")
            case .pasteboardWrites:
                return scalarProbe(context.effects.pasteboardWrites.count)
            }
        }

        private static func quotedProbe(_ value: String) -> ModelProbe {
            ModelProbe(value: value, rendered: UIQuery.quote(value))
        }

        private static func scalarProbe<T>(_ value: T) -> ModelProbe {
            let text = String(describing: value)
            return ModelProbe(value: text, rendered: text)
        }
    }

#endif
