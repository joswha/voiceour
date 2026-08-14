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

    import Darwin
    import Foundation

    extension UIHarnessMain {
        static func reportFlows(
            _ results: [UIFlowResult],
            coverage: UICoverageReport,
            request: UIHarnessRequest
        ) -> Bool {
            let machineMode = request.stdoutManifest
            for result in results where result.status != .ok {
                note(flowResultLine(result), machineMode: machineMode)
            }
            for result in results {
                for line in result.lines where !line.passed {
                    note(
                        "ui-flow: FAIL \(result.flow.id) \(line.checkpoint) \(line.expectation) "
                            + "| observed \(line.observed)",
                        machineMode: machineMode
                    )
                }
            }
            // Broken declarations and undeclared claims are always fatal: the ledger itself is
            // wrong. A merely UNCOVERED key is judged by the ratchet below instead, because
            // this app has real gaps today and a gate that is red on day one gets bypassed.
            for entry in coverage.entries where entry.status == .broken {
                let detail = entry.problem ?? entry.requirement.title
                note("ui-flow: BROKEN \(entry.requirement.key) | \(detail)", machineMode: machineMode)
            }
            for key in coverage.undeclared {
                note("ui-flow: UNDECLARED \(key)", machineMode: machineMode)
            }

            var baselineWarnings: [String] = []
            let ratchet = UICoverageBaseline.evaluate(coverage, request: request)
            var baselineWritten = false
            if request.mode == .flowUpdate {
                baselineWritten = UICoverageBaseline.write(
                    coverage,
                    request: request,
                    warnings: &baselineWarnings
                )
            }
            for key in ratchet.regressions {
                note(
                    "ui-flow: UNCOVERED \(key) | not in \(UICoverageBaseline.fileName): coverage regressed",
                    machineMode: machineMode
                )
            }
            for key in ratchet.stale {
                note(
                    "ui-flow: STALE-BASELINE \(key) | now covered; prune it with make ui-flow-update",
                    machineMode: machineMode
                )
            }
            if ratchet.missing {
                note(
                    "ui-flow: no \(UICoverageBaseline.fileName); generate it with make ui-flow-update",
                    machineMode: machineMode
                )
            }
            if baselineWritten {
                note("ui-flow: written \(UICoverageBaseline.fileName)", machineMode: machineMode)
            }
            for warning in baselineWarnings {
                flowError("ui-flow: \(warning)")
            }

            for result in results {
                if let error = result.error {
                    flowError("ui-flow: ERROR \(result.flow.id) | \(error)")
                }
                for frame in result.frames {
                    for finding in frame.findings where finding.severity == .error {
                        flowError(
                            "ui-flow: ERROR \(result.flow.id) \(frame.name) \(finding.rule) | \(finding.message)"
                        )
                    }
                }
            }

            note("ui-flow: \(flowTallyLine(flowTally(results), coverage: coverage))", machineMode: machineMode)
            let artifacts = request.outputDirectory.appendingPathComponent("flows", isDirectory: true).path
            note("ui-flow: artifacts \(artifacts)", machineMode: machineMode)

            let artifactFailure = results.contains { result in
                result.status != .ok && result.status != .written
            }
            let ledgerFailure =
                coverage.entries.contains { $0.status == .broken }
                || !coverage.undeclared.isEmpty
                || ratchet.failing
            return !artifactFailure && !ledgerFailure
        }

        static func flowTally(_ results: [UIFlowResult]) -> UIFlowTally {
            var tally = UIFlowTally()
            tally.flows = results.count
            for result in results {
                switch result.status {
                case .ok: tally.passed += 1
                case .failed: tally.failed += 1
                case .changed: tally.changed += 1
                case .missingGolden: tally.missingGolden += 1
                case .written: tally.written += 1
                }
                tally.expectations += result.lines.count
                tally.expectationsPassed += result.lines.filter(\.passed).count
                tally.expectationsFailed += result.lines.filter { !$0.passed }.count
                for frame in result.frames {
                    tally.errorFindings += frame.findings.filter { $0.severity == .error }.count
                    tally.warningFindings += frame.findings.filter { $0.severity == .warning }.count
                }
            }
            return tally
        }

        nonisolated static func flowStatusLabel(_ status: UIFlowResult.Status) -> String {
            guard let sceneStatus = UISceneResult.Status(rawValue: status.rawValue) else {
                preconditionFailure("flow and scene status vocabularies diverged")
            }
            return statusLabel(sceneStatus)
        }

        private static func flowResultLine(_ result: UIFlowResult) -> String {
            let frames: String
            if result.frames.isEmpty {
                frames = "none"
            } else {
                frames = result.frames.map { frame in
                    "\(frame.name)(pixel=\(statusLabel(frame.pixelStatus)),ax=\(statusLabel(frame.axStatus)))"
                }.joined(separator: ",")
            }
            return "ui-flow: \(flowStatusLabel(result.status)) \(result.flow.id) "
                + "journal=\(statusLabel(result.journalStatus)) frames=\(frames)"
        }

        private static func flowTallyLine(_ tally: UIFlowTally, coverage: UICoverageReport) -> String {
            var parts = [
                "\(tally.flows) flow\(tally.flows == 1 ? "" : "s")",
                "\(tally.passed) passed",
            ]
            if tally.changed > 0 { parts.append("\(tally.changed) changed") }
            if tally.missingGolden > 0 { parts.append("\(tally.missingGolden) missing-golden") }
            if tally.written > 0 { parts.append("\(tally.written) written") }
            if tally.failed > 0 { parts.append("\(tally.failed) failed") }
            parts.append("\(tally.expectations) expectations")
            if tally.expectationsFailed > 0 { parts.append("\(tally.expectationsFailed) expectation-failures") }
            if tally.errorFindings > 0 { parts.append("\(tally.errorFindings) lint-errors") }
            if tally.warningFindings > 0 { parts.append("\(tally.warningFindings) lint-warnings") }
            parts.append("\(coverage.count(.covered)) covered")
            if coverage.count(.uncovered) > 0 { parts.append("\(coverage.count(.uncovered)) uncovered") }
            if coverage.count(.broken) > 0 { parts.append("\(coverage.count(.broken)) broken") }
            if !coverage.undeclared.isEmpty { parts.append("\(coverage.undeclared.count) undeclared") }
            return parts.joined(separator: ", ")
        }

        private static func flowError(_ message: String) {
            fputs("\(message)\n", stderr)
        }
    }

    struct UIFlowTally {
        var flows = 0
        var passed = 0
        var failed = 0
        var changed = 0
        var missingGolden = 0
        var written = 0
        var expectations = 0
        var expectationsPassed = 0
        var expectationsFailed = 0
        var errorFindings = 0
        var warningFindings = 0
    }

#endif
