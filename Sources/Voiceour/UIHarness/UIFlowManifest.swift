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

    extension UIHarnessMain {
        static func writeFlowManifest(
            request: UIHarnessRequest,
            results: [UIFlowResult]
        ) -> Bool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let tally = flowTally(results)
            var blob = Data()
            do {
                blob.append(try encoder.encode(UIFlowRunRow(request: request, tally: tally)))
                blob.append(0x0A)
                for result in results {
                    blob.append(try encoder.encode(UIFlowRow(result)))
                    blob.append(0x0A)
                    for line in result.lines {
                        blob.append(try encoder.encode(UIExpectationRow(flowID: result.flow.id, line: line)))
                        blob.append(0x0A)
                    }
                }
            } catch {
                return report("cannot encode the flow manifest: \(describe(error))")
            }

            if request.stdoutManifest {
                print(String(decoding: blob, as: UTF8.self), terminator: "")
            }
            let outputDirectory = request.outputDirectory.appendingPathComponent("flows", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try blob.write(to: outputDirectory.appendingPathComponent("manifest.jsonl"), options: .atomic)
            } catch {
                return report("cannot write the flow manifest: \(describe(error))")
            }
            return true
        }
    }

    private struct UIFlowRunRow: Encodable {
        let type = "ui_flow_run"
        let mode: String
        let only: [String]
        let except: [String]
        let flows: Int
        let ok: Int
        let failed: Int
        let changed: Int
        let missingGolden: Int
        let written: Int
        let expectations: Int
        let expectationsPassed: Int
        let expectationsFailed: Int

        enum CodingKeys: String, CodingKey {
            case type
            case mode
            case only
            case except
            case flows
            case ok
            case failed
            case changed
            case missingGolden = "missing_golden"
            case written
            case expectations
            case expectationsPassed = "expectations_passed"
            case expectationsFailed = "expectations_failed"
        }

        init(request: UIHarnessRequest, tally: UIFlowTally) {
            mode = request.mode.rawValue
            only = request.only
            except = request.except
            flows = tally.flows
            ok = tally.passed
            failed = tally.failed
            changed = tally.changed
            missingGolden = tally.missingGolden
            written = tally.written
            expectations = tally.expectations
            expectationsPassed = tally.expectationsPassed
            expectationsFailed = tally.expectationsFailed
        }
    }

    private struct UIFlowRow: Encodable {
        let type = "ui_flow"
        let id: String
        let title: String
        let tags: [String]
        let status: String
        let checkpoints: Int
        let expectations: Int
        let expectationsFailed: Int
        let transitions: [String]
        let warnings: [String]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case title
            case tags
            case status
            case checkpoints
            case expectations
            case expectationsFailed = "expectations_failed"
            case transitions
            case warnings
            case error
        }

        init(_ result: UIFlowResult) {
            id = result.flow.id
            title = result.flow.title
            tags = result.flow.tags
            status = UIHarnessMain.flowStatusLabel(result.status)
            checkpoints = result.flow.checkpointCount
            expectations = result.lines.count
            expectationsFailed = result.lines.filter { !$0.passed }.count
            transitions = result.transitions.map(\.rawValue)
            warnings = result.warnings
            error = result.error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(tags, forKey: .tags)
            try container.encode(status, forKey: .status)
            try container.encode(checkpoints, forKey: .checkpoints)
            try container.encode(expectations, forKey: .expectations)
            try container.encode(expectationsFailed, forKey: .expectationsFailed)
            try container.encode(transitions, forKey: .transitions)
            try container.encode(warnings, forKey: .warnings)
            try UINullable.encode(error, forKey: .error, into: &container)
        }
    }

    private struct UIExpectationRow: Encodable {
        let type = "ui_expectation"
        let flowID: String
        let checkpoint: String
        let ordinal: Int
        let status: String
        let expectation: String
        let observed: String
        let selector: String?
        let candidates: [String]

        enum CodingKeys: String, CodingKey {
            case type
            case flowID = "flow_id"
            case checkpoint
            case ordinal
            case status
            case expectation
            case observed
            case selector
            case candidates
        }

        init(flowID: String, line: UIExpectationLine) {
            self.flowID = flowID
            checkpoint = line.checkpoint
            ordinal = line.ordinal
            status = line.passed ? "pass" : "fail"
            expectation = line.expectation
            observed = line.observed
            selector = line.selector
            candidates = line.candidates
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(flowID, forKey: .flowID)
            try container.encode(checkpoint, forKey: .checkpoint)
            try container.encode(ordinal, forKey: .ordinal)
            try container.encode(status, forKey: .status)
            try container.encode(expectation, forKey: .expectation)
            try container.encode(observed, forKey: .observed)
            try UINullable.encode(selector, forKey: .selector, into: &container)
            try container.encode(candidates, forKey: .candidates)
        }
    }

#endif
