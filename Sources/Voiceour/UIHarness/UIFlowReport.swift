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
            for result in results {
                if let error = result.error {
                    flowError("ui-flow: ERROR \(result.flow.id) | \(error)")
                }
            }

            note("ui-flow: \(flowTallyLine(flowTally(results)))", machineMode: machineMode)
            let artifacts = request.outputDirectory.appendingPathComponent("flows", isDirectory: true).path
            note("ui-flow: artifacts \(artifacts)", machineMode: machineMode)

            let artifactFailure = results.contains { result in
                result.status != .ok && result.status != .written
            }
            return !artifactFailure
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
            "ui-flow: \(flowStatusLabel(result.status)) \(result.flow.id) "
                + "journal=\(statusLabel(result.journalStatus))"
        }

        private static func flowTallyLine(_ tally: UIFlowTally) -> String {
            var parts = [
                "\(tally.flows) flow\(tally.flows == 1 ? "" : "s")",
                "\(tally.passed) passed",
            ]
            if tally.changed > 0 { parts.append("\(tally.changed) changed") }
            if tally.missingGolden > 0 { parts.append("\(tally.missingGolden) missing-golden") }
            if tally.written > 0 { parts.append("\(tally.written) written") }
            if tally.failed > 0 { parts.append("\(tally.failed) failed") }
            parts.append("\(tally.expectations) expectations")
            if tally.expectationsFailed > 0 {
                parts.append("\(tally.expectationsFailed) expectation-failures")
            }
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
    }

#endif
