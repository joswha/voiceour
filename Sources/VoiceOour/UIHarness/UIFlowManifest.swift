// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation

    extension UIHarnessMain {
        static func writeFlowManifest(
            request: UIHarnessRequest,
            results: [UIFlowResult],
            coverage: UICoverageReport
        ) -> Bool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let tally = flowTally(results)
            var blob = Data()
            do {
                blob.append(try encoder.encode(UIFlowRunRow(request: request, tally: tally, coverage: coverage)))
                blob.append(0x0A)
                for result in results {
                    blob.append(try encoder.encode(UIFlowRow(result)))
                    blob.append(0x0A)
                    for line in result.lines {
                        blob.append(try encoder.encode(UIExpectationRow(flowID: result.flow.id, line: line)))
                        blob.append(0x0A)
                    }
                    for frame in result.frames {
                        blob.append(try encoder.encode(UIFlowFrameRow(flowID: result.flow.id, frame: frame)))
                        blob.append(0x0A)
                    }
                }
                for entry in coverage.entries.sorted(by: { $0.requirement.key < $1.requirement.key }) {
                    blob.append(try encoder.encode(UICoverageRow(entry)))
                    blob.append(0x0A)
                }
            } catch {
                return report("cannot encode the flow manifest: \(describe(error))")
            }

            if request.stdoutManifest {
                print(String(decoding: blob, as: UTF8.self), terminator: "")
            }
            let outputDirectory = request.outputDirectory.appendingPathComponent("flows", isDirectory: true)
            let goldenDirectory = request.goldenDirectory.appendingPathComponent("flows", isDirectory: true)
            do {
                for directory in [outputDirectory, goldenDirectory] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
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
        let errorFindings: Int
        let warningFindings: Int
        let coverageDeclared: Int
        let coverageCovered: Int
        let coverageSnapshot: Int
        let coverageNotVerifiable: Int
        let coverageUncovered: Int
        let coverageNotSelected: Int
        let coverageBroken: Int
        let undeclaredCoverageKeys: [String]

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
            case errorFindings = "error_findings"
            case warningFindings = "warning_findings"
            case coverageDeclared = "coverage_declared"
            case coverageCovered = "coverage_covered"
            case coverageSnapshot = "coverage_snapshot"
            case coverageNotVerifiable = "coverage_not_verifiable"
            case coverageUncovered = "coverage_uncovered"
            case coverageNotSelected = "coverage_not_selected"
            case coverageBroken = "coverage_broken"
            case undeclaredCoverageKeys = "undeclared_coverage_keys"
        }

        init(request: UIHarnessRequest, tally: UIFlowTally, coverage: UICoverageReport) {
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
            errorFindings = tally.errorFindings
            warningFindings = tally.warningFindings
            coverageDeclared = coverage.entries.count
            coverageCovered = coverage.count(.covered)
            coverageSnapshot = coverage.count(.snapshot)
            coverageNotVerifiable = coverage.count(.notVerifiable)
            coverageUncovered = coverage.count(.uncovered)
            coverageNotSelected = coverage.count(.notSelected)
            coverageBroken = coverage.count(.broken)
            undeclaredCoverageKeys = coverage.undeclared.sorted()
        }
    }

    private struct UIFlowRow: Encodable {
        let type = "ui_flow"
        let id: String
        let title: String
        let tags: [String]
        let covers: [String]
        let status: String
        let checkpoints: Int
        let expectations: Int
        let expectationsFailed: Int
        let transitions: [String]
        let frames: Int
        let warnings: [String]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case title
            case tags
            case covers
            case status
            case checkpoints
            case expectations
            case expectationsFailed = "expectations_failed"
            case transitions
            case frames
            case warnings
            case error
        }

        init(_ result: UIFlowResult) {
            id = result.flow.id
            title = result.flow.title
            tags = result.flow.tags
            covers = result.flow.covers.map(\.description)
            status = UIHarnessMain.flowStatusLabel(result.status)
            checkpoints = result.flow.checkpointCount
            expectations = result.lines.count
            expectationsFailed = result.lines.filter { !$0.passed }.count
            transitions = result.transitions.map(\.rawValue)
            frames = result.frames.count
            warnings = result.warnings
            error = result.error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(tags, forKey: .tags)
            try container.encode(covers, forKey: .covers)
            try container.encode(status, forKey: .status)
            try container.encode(checkpoints, forKey: .checkpoints)
            try container.encode(expectations, forKey: .expectations)
            try container.encode(expectationsFailed, forKey: .expectationsFailed)
            try container.encode(transitions, forKey: .transitions)
            try container.encode(frames, forKey: .frames)
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

    private struct UIFlowFrameRow: Encodable {
        let type = "ui_flow_frame"
        let flowID: String
        let name: String
        let id: String
        let pixelStatus: String
        let axStatus: String
        let pngSha256: String?
        let goldenPngSha256: String?
        let axNodeCount: Int
        let findings: [UIFlowFindingRow]

        enum CodingKeys: String, CodingKey {
            case type
            case flowID = "flow_id"
            case name
            case id
            case pixelStatus = "pixel_status"
            case axStatus = "ax_status"
            case pngSha256 = "png_sha256"
            case goldenPngSha256 = "golden_png_sha256"
            case axNodeCount = "ax_node_count"
            case findings
        }

        init(flowID: String, frame: UIFlowFrame) {
            self.flowID = flowID
            name = frame.name
            id = frame.id
            pixelStatus = UIHarnessMain.statusLabel(frame.pixelStatus)
            axStatus = UIHarnessMain.statusLabel(frame.axStatus)
            pngSha256 = frame.pngDigest
            goldenPngSha256 = frame.goldenPngDigest
            axNodeCount = frame.nodeCount
            findings = frame.findings.map(UIFlowFindingRow.init)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(flowID, forKey: .flowID)
            try container.encode(name, forKey: .name)
            try container.encode(id, forKey: .id)
            try container.encode(pixelStatus, forKey: .pixelStatus)
            try container.encode(axStatus, forKey: .axStatus)
            try UINullable.encode(pngSha256, forKey: .pngSha256, into: &container)
            try UINullable.encode(goldenPngSha256, forKey: .goldenPngSha256, into: &container)
            try container.encode(axNodeCount, forKey: .axNodeCount)
            try container.encode(findings, forKey: .findings)
        }
    }

    private struct UICoverageRow: Encodable {
        let type = "ui_coverage"
        let key: String
        let kind: String
        let surface: String
        let title: String
        let status: String
        let disposition: String
        let claimants: [String]
        let limitation: String?
        let problem: String?

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case kind
            case surface
            case title
            case status
            case disposition
            case claimants
            case limitation
            case problem
        }

        init(_ entry: UICoverageEntry) {
            let requirement = entry.requirement
            key = requirement.key.description
            kind = requirement.key.kind.rawValue
            surface = requirement.key.surface.rawValue
            title = requirement.title
            status = entry.status.rawValue
            disposition = requirement.disposition.label
            claimants = entry.claimants.sorted()
            switch requirement.disposition {
            case .notVerifiable(let knownLimitation): limitation = knownLimitation.rawValue
            case .required, .snapshotOnly: limitation = nil
            }
            problem = entry.problem
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(kind, forKey: .kind)
            try container.encode(surface, forKey: .surface)
            try container.encode(title, forKey: .title)
            try container.encode(status, forKey: .status)
            try container.encode(disposition, forKey: .disposition)
            try container.encode(claimants, forKey: .claimants)
            try UINullable.encode(limitation, forKey: .limitation, into: &container)
            try UINullable.encode(problem, forKey: .problem, into: &container)
        }
    }

    private struct UIFlowFindingRow: Encodable {
        let rule: String
        let severity: String
        let message: String
        let path: String
        let frame: UIFrameRow

        enum CodingKeys: String, CodingKey {
            case rule
            case severity
            case message
            case path
            case frame
        }

        init(_ finding: UIFinding) {
            rule = finding.rule
            severity = finding.severity.rawValue
            message = finding.message
            path = finding.path
            frame = UIFrameRow(finding.frame)
        }
    }

#endif
