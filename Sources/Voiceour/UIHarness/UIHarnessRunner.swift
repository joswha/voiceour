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

    import Dispatch
    import Foundation
    import SwiftUI
    // CLI driver for the offscreen UI harness.
    //
    // Renders every catalog scene into a borderless window parked far offscreen, dumps the
    // in-process accessibility tree, lints both, diffs the result against the goldens in
    // `fixtures/ui/`, and writes machine-readable artifacts. Nothing is ever ordered onto a
    // display and the frontmost application never changes.
    //
    // See docs/ui-harness.md for the artifact layout, the manifest schema, and the honest
    // list of what an offscreen render cannot show you.

    @MainActor
    enum UIHarnessMain {
        /// Prefix for every human-facing line, so `ui_harness.sh | grep ui-harness:` works.
        static let tool = "ui-harness"

        static func run(_ request: UIHarnessRequest) -> Bool {
            if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
                print(UIHarnessRequest.usage)
                return true
            }

            // Flow catalog mode is a pure data path and never needs to create the
            // NSApplication or touch a window.
            switch request.mode {
            case .flowList:
                return emitFlowCatalog(request)
            case .mercury:
                // Pure CoreGraphics: the mercury bench rasterizes straight into a bitmap
                // and never hosts a view, so it needs no NSApplication and no window.
                return MercurySheet.run(request)
            case .mercuryBenchmark:
                return MercuryChromeBenchmark.run(request)
            case .list, .check, .update, .flowCheck, .flowUpdate:
                break
            }

            // Must happen before any CoreGraphics window API, including in `--list` mode:
            // without a finished-launching NSApplication the first CGS call aborts the
            // process. It also pins the activation policy to `.prohibited`, which is what
            // keeps the console scenes from promoting the app and stealing focus.
            UIHarnessRuntime.prepareProcess()

            switch request.mode {
            case .list:
                return emitCatalog(request)
            case .check, .update:
                return runScenes(request)
            case .flowCheck, .flowUpdate:
                return runFlows(request)
            case .flowList, .mercury, .mercuryBenchmark:
                preconditionFailure("pure-data harness mode reached the hosting dispatch")
            }
        }
    }

    // MARK: - Flow run

    extension UIHarnessMain {
        private static func emitFlowCatalog(_ request: UIHarnessRequest) -> Bool {
            let document = UIFlowCatalogDocument(
                flows: UIFlowCatalog.all(request: request).map(UIFlowCatalogEntry.init)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(document)
                guard let line = String(data: data, encoding: .utf8) else {
                    return report("flow catalog JSON was not UTF-8")
                }
                print(line)
                return true
            } catch {
                return report("cannot encode the flow catalog: \(describe(error))")
            }
        }

        private static func runFlows(_ request: UIHarnessRequest) -> Bool {
            var flows = UIFlowCatalog.all(request: request)
            guard !flows.isEmpty else {
                return report("no flow matched the request filters")
            }
            // `os26` flows release `RenderOverrides.forceLegacyGlass` so the script drives the
            // native macOS 26 branch. `#available` resolves against the RUNTIME OS, so on
            // macOS 14/15 releasing the seam changes nothing: every one of them would re-run
            // the painted path a portable flow already verifies while pretending to exercise
            // the native branch.
            //
            // Skip them rather than abort, exactly as the scene path does: `--only console`
            // substring-matches `console.tab.navigation.os26` alongside the portable console
            // flows, and that focused run is the documented everyday workflow. Fail only when
            // nothing runnable is left.
            if #unavailable(macOS 26) {
                let native = flows.filter { $0.tags.contains("os26") }
                if !native.isEmpty {
                    flows.removeAll { $0.tags.contains("os26") }
                    guard !flows.isEmpty else {
                        return report(
                            "every matched flow is tagged os26 and needs macOS 26; this host is "
                                + "older, so they would drive the painted path rather than the "
                                + "native branch. Use --except os26 (that is what `make ui-flow` does)."
                        )
                    }
                    report(
                        "skipping \(native.count) os26 flow(s): they need macOS 26 and this host "
                            + "is older. Running the \(flows.count) portable flow(s)."
                    )
                }
            }

            let results = flows.map { UIFlowRunner.run($0, request: request) }
            _ = writeFlowManifest(request: request, results: results)
            return reportFlows(results, request: request)
        }
    }

    private struct UIFlowCatalogDocument: Encodable {
        let type = "ui_flow_catalog"
        let flows: [UIFlowCatalogEntry]
    }

    private struct UIFlowCatalogEntry: Encodable {
        let id: String
        let title: String
        let tags: [String]
        let checkpoints: Int
        let expectations: Int

        @MainActor
        init(_ flow: UIFlow) {
            id = flow.id
            title = flow.title
            tags = flow.tags
            checkpoints = flow.checkpointCount
            expectations = flow.expectationCount
        }
    }

    // MARK: - Scene run

    extension UIHarnessMain {
        private static func runScenes(_ request: UIHarnessRequest) -> Bool {
            var scenes = UISceneCatalog.all(request: request)
            guard !scenes.isEmpty else {
                return report("no scene matched --only \(request.only.joined(separator: ","))")
            }
            // `os26` scenes execute the native macOS 26 code branch. They do NOT capture the
            // system material: `cacheDisplay` does not rasterise SwiftUI `.glassEffect`, so it
            // is absent from these renders rather than flattened, and what the goldens record
            // is the app's own paint, geometry and accessibility tree on that branch.
            //
            // `#available` resolves against the RUNTIME OS, so on macOS 14/15 every one of
            // them would quietly take the painted fallback branch and record something the
            // scene does not exist to show. In `check` mode that is a confusing failure; in
            // `update` mode it would overwrite the native goldens with fallback renders, and
            // the corruption would only surface on the next Tahoe machine.
            //
            // Skip them rather than abort: `--only console` substring-matches
            // native scenes such as `console.sessions.os26` as well as the portable
            // console scenes, and that focused run is the documented everyday workflow.
            // Refusing the whole selection over one unrenderable match would break it on
            // exactly the hosts that can only ever use the portable path. Fail only when
            // nothing renderable is left.
            if #unavailable(macOS 26) {
                let native = scenes.filter { $0.tags.contains("os26") }
                if !native.isEmpty {
                    scenes.removeAll { $0.tags.contains("os26") }
                    guard !scenes.isEmpty else {
                        return report(
                            "every matched scene is tagged os26 and needs macOS 26; this host is "
                                + "older, so they would record the painted fallback rather than "
                                + "the native branch. Use --except os26 (that is what `make ui-snap` does)."
                        )
                    }
                    report(
                        "skipping \(native.count) os26 scene(s): they need macOS 26 and this host "
                            + "is older. Rendering the \(scenes.count) portable scene(s)."
                    )
                }
            }
            guard prepareDirectories(request) else { return false }
            // `prepareProcess()` already enabled enhanced accessibility and reported failure
            // on stderr. Per scene, the consequence is caught as an `empty-tree` lint error,
            // which fails the run, so nothing here needs to re-check it.

            let startedAt = ISO8601DateFormatter().string(from: Date())
            let clock = DispatchTime.now()
            var outcomes: [UISceneOutcome] = []
            outcomes.reserveCapacity(scenes.count)
            for scene in scenes {
                outcomes.append(execute(scene, request: request))
            }

            let sheetPath = writeContactSheet(outcomes, request: request)
            let manifestOK = writeManifest(
                request: request,
                outcomes: outcomes,
                startedAt: startedAt,
                durationMs: elapsedMs(since: clock),
                contactSheet: sheetPath
            )
            summarise(outcomes, request: request)
            return manifestOK && !hasFailure(outcomes)
        }

        private static func prepareDirectories(_ request: UIHarnessRequest) -> Bool {
            var directories = [request.outputDirectory]
            if request.mode.writesGoldens { directories.append(request.goldenDirectory) }
            for directory in directories {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    return report("cannot create \(directory.path): \(describe(error))")
                }
            }
            return true
        }

        /// Every per-scene failure is contained here: a scene that throws is recorded as
        /// `failed` and the remaining scenes still render.
        private static func execute(_ scene: UIScene, request: UIHarnessRequest) -> UISceneOutcome {
            let clock = DispatchTime.now()
            do {
                let render = try renderScene(scene, scale: request.scale)
                return reconcileScene(scene, render: render, request: request, clock: clock)
            } catch {
                let result = UISceneResult(
                    scene: scene,
                    capture: nil,
                    findings: [],
                    pixelStatus: .failed,
                    axStatus: .failed,
                    error: describe(error),
                    durationMs: elapsedMs(since: clock)
                )
                return UISceneOutcome(result: result, warnings: [], axNodeCount: 0, goldenPNGDigest: nil)
            }
        }

        /// `withHostedScene` settles the hierarchy, runs the scene's interaction script and
        /// settles again before handing over the view, so the body only reads.
        private static func renderScene(_ scene: UIScene, scale: Int) throws -> UIRenderedScene {
            let recorder = TextRoleRecorder()
            let previousRecorder = RenderOverrides.textRoleRecorder
            RenderOverrides.textRoleRecorder = recorder
            defer {
                RenderOverrides.textRoleRecorder = previousRecorder
            }

            return try UIHarnessRuntime.withHostedScene(scene, scale: scale) { view in
                let root = AXDump.tree(of: view)
                let capture = try UIHarnessRuntime.capture(view, scale: scale)
                return UIRenderedScene(
                    root: root,
                    axText: AXDump.text(root),
                    capture: capture,
                    warnings: UIHarnessRuntime.lastInteractionWarnings,
                    textSamples: recorder.samples
                )
            }
        }

        private static func reconcileScene(
            _ scene: UIScene,
            render: UIRenderedScene,
            request: UIHarnessRequest,
            clock: DispatchTime
        ) -> UISceneOutcome {
            var warnings = render.warnings
            let findings = UILint.evaluate(
                root: render.root,
                capture: render.capture,
                size: scene.size,
                textSamples: render.textSamples
            )
            let reconciliation = reconcileCapture(
                identifier: scene.id,
                capture: render.capture,
                axText: render.axText,
                findings: findings,
                pngArtifact: artifactURL(scene, "png", request),
                axArtifact: artifactURL(scene, "ax.txt", request),
                pngGolden: goldenURL(scene, "png.sha256", request),
                axGolden: goldenURL(scene, "ax.txt", request),
                mode: request.mode,
                warnings: &warnings,
                refreshAXDiff: { _, current, previous, status, diffWarnings in
                    refreshDiff(
                        scene,
                        axText: current,
                        previous: previous,
                        status: status,
                        request: request,
                        warnings: &diffWarnings
                    )
                }
            )

            let result = UISceneResult(
                scene: scene,
                capture: render.capture,
                findings: findings,
                pixelStatus: reconciliation.pixel.status,
                axStatus: reconciliation.ax.status,
                error: nil,
                durationMs: elapsedMs(since: clock)
            )
            return UISceneOutcome(
                result: result,
                warnings: warnings,
                axNodeCount: AXDump.nodeCount(render.root),
                goldenPNGDigest: reconciliation.previousPixelDigest
            )
        }

        static func reconcileCapture(
            identifier: String,
            capture: UICapture,
            axText: String,
            findings: [UIFinding],
            pngArtifact: URL,
            axArtifact: URL,
            pngGolden: URL,
            axGolden: URL,
            mode: UIHarnessRequest.Mode,
            warnings: inout [String],
            refreshAXDiff: (
                _ identifier: String,
                _ current: String,
                _ previous: String?,
                _ status: UISceneResult.Status,
                _ warnings: inout [String]
            ) -> Void
        ) -> (pixel: UIGoldenOutcome, ax: UIGoldenOutcome, previousPixelDigest: String?) {
            let axData = Data(axText.utf8)
            writeCaptureArtifacts(
                capture: capture,
                axData: axData,
                pngArtifact: pngArtifact,
                axArtifact: axArtifact,
                warnings: &warnings
            )

            // The pixel golden is the sha256 of the PNG, not the PNG. 24 console-sized
            // renders weigh 7.6 MB and every `--update` would rewrite half-megabyte binaries
            // into git history; the digests are 65 bytes each and detect the same change.
            // The rendered PNG still lands in the artifact directory, and the contact sheet
            // is how you actually look at it.
            let previousAX = FileManager.default.contents(atPath: axGolden.path)
                .flatMap { String(data: $0, encoding: .utf8) }
            let previousPixelDigest = FileManager.default.contents(atPath: pngGolden.path)
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // A lint error is never blessed into a golden: a blank or #FFCC00 placeholder
            // render would otherwise freeze the bug in place and assert nothing forever.
            let blessable = !findings.contains { $0.severity == .error }
            let pixel = reconcile(
                payload: Data((capture.sha256 + "\n").utf8),
                golden: pngGolden,
                mode: mode,
                blessable: blessable
            )
            let ax = reconcile(payload: axData, golden: axGolden, mode: mode, blessable: blessable)
            refreshAXDiff(identifier, axText, previousAX, ax.status, &warnings)
            warnings.append(contentsOf: [pixel.warning, ax.warning].compactMap { $0 })
            return (pixel: pixel, ax: ax, previousPixelDigest: previousPixelDigest)
        }

        static func writeCaptureArtifacts(
            capture: UICapture,
            axData: Data,
            pngArtifact: URL,
            axArtifact: URL,
            warnings: inout [String]
        ) {
            writeArtifact(capture.png, to: pngArtifact, warnings: &warnings)
            writeArtifact(axData, to: axArtifact, warnings: &warnings)
        }
    }
    // MARK: - Internal value types

    private struct UIRenderedScene {
        let root: AXNode
        let axText: String
        let capture: UICapture
        let warnings: [String]
        let textSamples: [TextRoleSample]
    }

    /// `UISceneResult` plus the three things the manifest needs that it does not carry.
    struct UISceneOutcome {
        let result: UISceneResult
        let warnings: [String]
        let axNodeCount: Int
        let goldenPNGDigest: String?
    }

#endif
