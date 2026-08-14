// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation
    // MARK: - Catalog

    extension UIHarnessMain {
        static func emitCatalog(_ request: UIHarnessRequest) -> Bool {
            let entries = UISceneCatalog.all().filter(request.matches).map(UICatalogEntry.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(UICatalogDocument(scenes: entries))
                guard let line = String(data: data, encoding: .utf8) else {
                    return report("catalog JSON was not UTF-8")
                }
                print(line)
                return true
            } catch {
                return report("cannot encode the scene catalog: \(describe(error))")
            }
        }
    }
    // MARK: - Manifest

    extension UIHarnessMain {
        static func writeManifest(
            request: UIHarnessRequest,
            outcomes: [UISceneOutcome],
            startedAt: String,
            durationMs: Int,
            contactSheet: String?
        ) -> Bool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let header = UIRunRow(
                request: request,
                counts: tally(outcomes),
                startedAt: startedAt,
                durationMs: durationMs,
                contactSheet: contactSheet
            )
            var blob = Data()
            do {
                blob.append(try encoder.encode(header))
                blob.append(0x0A)
                for outcome in outcomes {
                    blob.append(try encoder.encode(UISceneRow(outcome: outcome, scale: request.scale)))
                    blob.append(0x0A)
                }
            } catch {
                return report("cannot encode the manifest: \(describe(error))")
            }
            if request.stdoutManifest {
                print(String(decoding: blob, as: UTF8.self), terminator: "")
            }
            do {
                try blob.write(to: request.outputDirectory.appendingPathComponent("manifest.jsonl"), options: .atomic)
            } catch {
                return report("cannot write the manifest: \(describe(error))")
            }
            return true
        }
    }
    // MARK: - Wire format

    private struct UICatalogDocument: Encodable {
        let type = "ui_catalog"
        let scenes: [UICatalogEntry]
    }

    private struct UICatalogEntry: Encodable {
        let id: String
        let title: String
        let tags: [String]
        let width: Int
        let height: Int
        let colorScheme: String
        let steps: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case tags
            case width
            case height
            case colorScheme = "color_scheme"
            case steps
        }

        @MainActor
        init(_ scene: UIScene) {
            id = scene.id
            title = scene.title
            tags = scene.tags
            width = Int(scene.size.width.rounded())
            height = Int(scene.size.height.rounded())
            colorScheme = UIHarnessMain.schemeName(scene.colorScheme)
            steps = scene.steps.map { UIHarnessMain.stepText($0) }
        }
    }

    private struct UIRunRow: Encodable {
        let type = "ui_run"
        let mode: String
        let only: [String]
        let scale: Int
        let scenes: Int
        let ok: Int
        let changed: Int
        let missingGolden: Int
        let written: Int
        let failed: Int
        let errorFindings: Int
        let warningFindings: Int
        let startedAt: String
        let durationMs: Int
        let outputDirectory: String
        let goldenDirectory: String
        let contactSheet: String?

        enum CodingKeys: String, CodingKey {
            case type
            case mode
            case only
            case scale
            case scenes
            case ok
            case changed
            case missingGolden = "missing_golden"
            case written
            case failed
            case errorFindings = "error_findings"
            case warningFindings = "warning_findings"
            case startedAt = "started_at"
            case durationMs = "duration_ms"
            case outputDirectory = "output_dir"
            case goldenDirectory = "golden_dir"
            case contactSheet = "contact_sheet"
        }

        init(request: UIHarnessRequest, counts: UITally, startedAt: String, durationMs: Int, contactSheet: String?) {
            mode = request.mode.rawValue
            only = request.only
            scale = request.scale
            scenes = counts.total
            ok = counts.ok
            changed = counts.changed
            missingGolden = counts.missingGolden
            written = counts.written
            failed = counts.failed
            errorFindings = counts.errorFindings
            warningFindings = counts.warningFindings
            self.startedAt = startedAt
            self.durationMs = durationMs
            outputDirectory = request.outputDirectory.path
            goldenDirectory = request.goldenDirectory.path
            self.contactSheet = contactSheet
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(mode, forKey: .mode)
            try container.encode(only, forKey: .only)
            try container.encode(scale, forKey: .scale)
            try container.encode(scenes, forKey: .scenes)
            try container.encode(ok, forKey: .ok)
            try container.encode(changed, forKey: .changed)
            try container.encode(missingGolden, forKey: .missingGolden)
            try container.encode(written, forKey: .written)
            try container.encode(failed, forKey: .failed)
            try container.encode(errorFindings, forKey: .errorFindings)
            try container.encode(warningFindings, forKey: .warningFindings)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(outputDirectory, forKey: .outputDirectory)
            try container.encode(goldenDirectory, forKey: .goldenDirectory)
            try UINullable.encode(contactSheet, forKey: .contactSheet, into: &container)
        }
    }

    private struct UISceneRow: Encodable {
        let type = "ui_scene"
        let id: String
        let title: String
        let tags: [String]
        let width: Int
        let height: Int
        let scale: Int
        let status: String
        let pixelStatus: String
        let axStatus: String
        let pngSha256: String?
        let goldenPngSha256: String?
        let axNodeCount: Int
        let durationMs: Int
        let findings: [UIFindingRow]
        let warnings: [String]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case title
            case tags
            case width
            case height
            case scale
            case status
            case pixelStatus = "pixel_status"
            case axStatus = "ax_status"
            case pngSha256 = "png_sha256"
            case goldenPngSha256 = "golden_png_sha256"
            case axNodeCount = "ax_node_count"
            case durationMs = "duration_ms"
            case findings
            case warnings
            case error
        }

        @MainActor
        init(outcome: UISceneOutcome, scale: Int) {
            let result = outcome.result
            id = result.scene.id
            title = result.scene.title
            tags = result.scene.tags
            width = Int(result.scene.size.width.rounded())
            height = Int(result.scene.size.height.rounded())
            self.scale = scale
            status = UIHarnessMain.statusLabel(result.status)
            pixelStatus = UIHarnessMain.statusLabel(result.pixelStatus)
            axStatus = UIHarnessMain.statusLabel(result.axStatus)
            pngSha256 = result.capture?.sha256
            goldenPngSha256 = outcome.goldenPNGDigest
            axNodeCount = outcome.axNodeCount
            durationMs = result.durationMs
            findings = result.findings.map(UIFindingRow.init)
            warnings = outcome.warnings
            error = result.error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(tags, forKey: .tags)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(scale, forKey: .scale)
            try container.encode(status, forKey: .status)
            try container.encode(pixelStatus, forKey: .pixelStatus)
            try container.encode(axStatus, forKey: .axStatus)
            try UINullable.encode(pngSha256, forKey: .pngSha256, into: &container)
            try UINullable.encode(goldenPngSha256, forKey: .goldenPngSha256, into: &container)
            try container.encode(axNodeCount, forKey: .axNodeCount)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(findings, forKey: .findings)
            try container.encode(warnings, forKey: .warnings)
            try UINullable.encode(error, forKey: .error, into: &container)
        }
    }

    struct UIFindingRow: Encodable {
        let rule: String
        let severity: String
        let message: String
        let path: String
        let frame: UIFrameRow

        init(_ finding: UIFinding) {
            rule = finding.rule
            severity = finding.severity.rawValue
            message = finding.message
            path = finding.path
            frame = UIFrameRow(finding.frame)
        }
    }

    /// Frames are rounded to one decimal so subpixel jitter never churns the manifest, and
    /// so the numbers agree with the ones the lint rules print inside `message`.
    /// Shared with `UIFlowManifest`: the flow manifest emits the same `x`/`y`/`width`/`height`
    /// shape, so a second copy could only drift.
    struct UIFrameRow: Encodable {
        let originX: Double
        let originY: Double
        let width: Double
        let height: Double

        enum CodingKeys: String, CodingKey {
            case originX = "x"
            case originY = "y"
            case width
            case height
        }

        init(_ frame: CGRect) {
            originX = UIFrameRow.round(frame.origin.x)
            originY = UIFrameRow.round(frame.origin.y)
            width = UIFrameRow.round(frame.size.width)
            height = UIFrameRow.round(frame.size.height)
        }

        private static func round(_ value: CGFloat) -> Double {
            let scaled = (Double(value) * 10).rounded()
            return scaled == 0 ? 0 : scaled / 10
        }
    }

    /// Keeps nullable manifest keys present instead of omitted, matching `BenchMeta`.
    /// Shared with `UIFlowManifest`, which has the same explicit-null keys.
    enum UINullable {
        static func encode<Key: CodingKey>(
            _ value: String?,
            forKey key: Key,
            into container: inout KeyedEncodingContainer<Key>
        ) throws {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

#endif
