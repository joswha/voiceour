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

    // The journal wire format is deliberately plain and fixed:
    //
    //   flow: <id>
    //   title: <title>
    //   fixture: <fixture name>
    //   transitions: <state> -> <state>
    //   PASS <ordinal> <checkpoint> | <expectation> | <observed>
    //   FAIL <ordinal> <checkpoint> | <expectation> | <observed>
    //         selector: <selector>
    //         candidate: <candidate>
    //   warnings: <warning>
    //
    // Checkpoints retain script order, failure details retain candidate order, warning lines
    // are last, and the file is UTF-8 with LF endings and one trailing LF.

    enum UIFlowJournal {
        static func render(_ result: UIFlowResult) -> String {
            var rendered = [
                "flow: \(result.flow.id)",
                "title: \(result.flow.title)",
                "fixture: \(result.flow.fixture.name)",
                "transitions: \(result.transitions.map(\.rawValue).joined(separator: " -> "))",
            ]

            var expectationIndex = result.lines.startIndex
            for step in result.flow.steps {
                switch step {
                case .check(_, let expectations):
                    for _ in expectations where expectationIndex < result.lines.endIndex {
                        append(result.lines[expectationIndex], to: &rendered)
                        expectationIndex = result.lines.index(after: expectationIndex)
                    }
                case .act, .release, .wait:
                    break
                }
            }

            // A contained runner failure can stop before it walks the rest of the script. If a
            // result nevertheless carries extra evaluated lines, preserve their recorded order
            // instead of silently dropping evidence from the current artifact.
            while expectationIndex < result.lines.endIndex {
                append(result.lines[expectationIndex], to: &rendered)
                expectationIndex = result.lines.index(after: expectationIndex)
            }

            rendered.append(contentsOf: result.warnings.map { "warnings: \($0)" })
            return rendered.joined(separator: "\n") + "\n"
        }

        private static func append(_ line: UIExpectationLine, to rendered: inout [String]) {
            rendered.append(
                "\(line.passed ? "PASS" : "FAIL") \(line.ordinal) \(line.checkpoint) | "
                    + "\(line.expectation) | \(line.observed)"
            )
            guard !line.passed else { return }
            if let selector = line.selector {
                rendered.append("      selector: \(selector)")
            }
            rendered.append(contentsOf: line.candidates.map { "      candidate: \($0)" })
        }
    }

    extension UIHarnessMain {
        static func reconcileFlow(
            _ result: UIFlowResult,
            request: UIHarnessRequest
        ) -> (status: UISceneResult.Status, warnings: [String]) {
            var warnings: [String] = []
            guard prepareFlowDirectories(request, warnings: &warnings) else {
                return (.failed, warnings)
            }

            let journal = UIFlowJournal.render(result)
            let payload = Data(journal.utf8)
            let artifact = flowOutputDirectory(request).appendingPathComponent("\(result.flow.id).flow.txt")
            let golden = flowGoldenDirectory(request).appendingPathComponent("\(result.flow.id).flow.txt")
            let previous = FileManager.default.contents(atPath: golden.path)
                .flatMap { String(data: $0, encoding: .utf8) }

            writeArtifact(payload, to: artifact, warnings: &warnings)
            let outcome = reconcile(
                payload: payload,
                golden: golden,
                mode: request.mode,
                blessable: result.passed
            )
            refreshFlowDiff(
                id: result.flow.id,
                current: journal,
                previous: previous,
                status: outcome.status,
                request: request,
                warnings: &warnings
            )
            if let warning = outcome.warning { warnings.append(warning) }
            return (outcome.status, warnings)
        }

        private static func prepareFlowDirectories(
            _ request: UIHarnessRequest,
            warnings: inout [String]
        ) -> Bool {
            for directory in [flowOutputDirectory(request), flowGoldenDirectory(request)] {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    warnings.append("cannot create flows directory: \(describe(error))")
                    return false
                }
            }
            return true
        }

        private static func flowOutputDirectory(_ request: UIHarnessRequest) -> URL {
            request.outputDirectory.appendingPathComponent("flows", isDirectory: true)
        }

        private static func flowGoldenDirectory(_ request: UIHarnessRequest) -> URL {
            request.goldenDirectory.appendingPathComponent("flows", isDirectory: true)
        }

        private static func refreshFlowDiff(
            id: String,
            current: String,
            previous: String?,
            status: UISceneResult.Status,
            request: UIHarnessRequest,
            warnings: inout [String]
        ) {
            let diff = flowOutputDirectory(request).appendingPathComponent("\(id).flow.diff")
            guard status != .written, let previous, previous != current else {
                try? FileManager.default.removeItem(at: diff)
                return
            }
            let text = UIHarnessDiff.unified(
                old: previous.components(separatedBy: "\n"),
                new: current.components(separatedBy: "\n"),
                oldLabel: "fixtures/ui/flows/\(id).flow.txt",
                newLabel: ".build/ui-harness/flows/\(id).flow.txt"
            )
            writeArtifact(Data(text.utf8), to: diff, warnings: &warnings)
        }
    }

#endif
