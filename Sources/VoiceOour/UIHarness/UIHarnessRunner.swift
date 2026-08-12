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

            // Catalog and ledger modes are pure data paths. In particular, coverage must
            // never create the NSApplication or touch a window just to verify declarations.
            switch request.mode {
            case .flowList:
                return emitFlowCatalog(request)
            case .coverage:
                return reportCoverage(request)
            case .list, .check, .update, .flowCheck, .flowUpdate, .film:
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
            case .film:
                return runFilm(request)
            case .flowList, .coverage:
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
            // the painted path a portable flow already covers and claim native-branch
            // coverage for it.
            //
            // Skip them rather than abort, exactly as the scene path does: `--only console`
            // substring-matches `console.rail.navigation.os26` alongside the portable console
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
            let coverage = evaluateCoverage(
                selectedFlows: flows,
                passingFlows: results.filter(\.passed).map(\.flow)
            )
            _ = writeFlowManifest(request: request, results: results, coverage: coverage)
            return reportFlows(results, coverage: coverage, request: request)
        }

        private static func reportCoverage(_ request: UIHarnessRequest) -> Bool {
            let flows = UIFlowCatalog.everything()
            let coverage = evaluateCoverage(selectedFlows: flows, passingFlows: flows)
            return reportFlows([], coverage: coverage, request: request)
        }

        private static func evaluateCoverage(
            selectedFlows: [UIFlow],
            passingFlows: [UIFlow]
        ) -> UICoverageReport {
            let allFlows = UIFlowCatalog.everything()
            return UICoverageLedger.evaluate(
                requirements: UICoverageRegistry.requirements,
                passingClaims: coverageClaims(for: passingFlows),
                selectedClaims: Set(selectedFlows.flatMap(\.covers)),
                allClaims: coverageClaims(for: allFlows),
                sceneIDs: Set(UISceneCatalog.everything().map(\.id))
            )
        }

        private static func coverageClaims(for flows: [UIFlow]) -> [UICoverageKey: [String]] {
            var claims: [UICoverageKey: [String]] = [:]
            for flow in flows {
                for key in flow.covers {
                    claims[key, default: []].append(flow.id)
                }
            }
            return claims
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
        let covers: [String]
        let checkpoints: Int
        let expectations: Int

        @MainActor
        init(_ flow: UIFlow) {
            id = flow.id
            title = flow.title
            tags = flow.tags
            covers = flow.covers.map(\.description)
            checkpoints = flow.checkpointCount
            expectations = flow.expectationCount
        }
    }

    // MARK: - Film run

    extension UIHarnessMain {
        private static func runFilm(_ request: UIHarnessRequest) -> Bool {
            let reels = UIFilmCatalog.all(request: request)
            guard !reels.isEmpty else {
                return report("no film reel matched the request filters")
            }
            var ok = true
            for reel in reels {
                ok = record(reel, request: request) && ok
            }
            return ok
        }

        /// Records one reel and writes its `reel.json` sidecar.
        ///
        /// No golden, no digest, no lint: a reel is media. The failure modes it does own --
        /// a capture that throws, a frame that cannot be written -- return false so the
        /// process exits 1 rather than leaving a half-written reel to be turned into a GIF.
        private static func record(_ reel: UIFilmReel, request: UIHarnessRequest) -> Bool {
            let directory =
                request.outputDirectory
                .appendingPathComponent("film", isDirectory: true)
                .appendingPathComponent(reel.id, isDirectory: true)
            guard prepareReelDirectory(directory) else { return false }

            // The stage is built before hosting so the script and the hierarchy share one
            // observable model. The builder is hoisted out of the call because `withLiveScene`
            // already takes a trailing closure.
            let stage = reel.stage()
            let build: @MainActor () -> AnyView = { stage.view }
            var frameCount = 0
            do {
                try UIHarnessRuntime.withLiveScene(
                    size: reel.size,
                    colorScheme: reel.colorScheme,
                    scale: request.scale,
                    build: build
                ) { view, _ in
                    let recorder = UIFilmRecorder(view: view, scale: request.scale, directory: directory)
                    try stage.script(recorder)
                    frameCount = recorder.frameCount
                }
            } catch {
                return report("failed \(reel.id): \(describe(error))")
            }

            guard writeReelDocument(reel, request: request, frameCount: frameCount, directory: directory) else {
                return false
            }
            let pixels = pixelSize(of: reel, scale: request.scale)
            note(
                "\(tool): film \(reel.id) \(frameCount) frames, \(pixels.width)x\(pixels.height) px, "
                    + "\(reel.frameMilliseconds) ms/frame",
                machineMode: request.stdoutManifest
            )
            note("\(tool): artifacts \(directory.path)", machineMode: request.stdoutManifest)
            return true
        }

        /// Recreated from empty on every run. A reel that gets shorter would otherwise leave
        /// the previous run's trailing `frame-NNNN.png` behind, and ffmpeg's `frame-%04d.png`
        /// pattern would splice those orphans onto the end of the GIF.
        private static func prepareReelDirectory(_ directory: URL) -> Bool {
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return report("cannot prepare \(directory.path): \(describe(error))")
            }
            return true
        }

        private static func writeReelDocument(
            _ reel: UIFilmReel,
            request: UIHarnessRequest,
            frameCount: Int,
            directory: URL
        ) -> Bool {
            let pixels = pixelSize(of: reel, scale: request.scale)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var blob = Data()
            do {
                blob.append(
                    try encoder.encode(
                        UIFilmReelRow(
                            id: reel.id,
                            title: reel.title,
                            frameCount: frameCount,
                            frameMilliseconds: reel.frameMilliseconds,
                            width: pixels.width,
                            height: pixels.height,
                            scale: request.scale
                        )))
                blob.append(0x0A)
            } catch {
                return report("cannot encode \(reel.id): \(describe(error))")
            }
            if request.stdoutManifest {
                print(String(decoding: blob, as: UTF8.self), terminator: "")
            }
            do {
                try blob.write(to: directory.appendingPathComponent("reel.json"), options: .atomic)
            } catch {
                return report("cannot write \(reel.id) reel.json: \(describe(error))")
            }
            return true
        }

        /// PIXEL dimensions, matching what every frame's PNG IHDR carries, so the GIF
        /// assembler never has to multiply by the scale itself.
        private static func pixelSize(of reel: UIFilmReel, scale: Int) -> (width: Int, height: Int) {
            let clamped = CGFloat(max(1, scale))
            return (Int((reel.size.width * clamped).rounded()), Int((reel.size.height * clamped).rounded()))
        }
    }

    private struct UIFilmReelRow: Encodable {
        let type = "ui_film_reel"
        let id: String
        let title: String
        let frameCount: Int
        let frameMilliseconds: Int
        let width: Int
        let height: Int
        let scale: Int

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case title
            case frameCount = "frame_count"
            case frameMilliseconds = "frame_milliseconds"
            case width
            case height
            case scale
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
            // `console.home.os26` as well as the sixteen portable console scenes, and that
            // focused run is the documented everyday workflow. Refusing the whole selection
            // over one unrenderable match would break it on exactly the hosts that can only
            // ever use the portable path. Fail only when nothing renderable is left.
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
            // A lint error is never blessed into a golden: a blank or #FFCC00 placeholder
            // render would otherwise freeze the bug in place and assert nothing forever.
            let blessable = !findings.contains { $0.severity == .error }
            let axData = Data(render.axText.utf8)
            let axGolden = goldenURL(scene, "ax.txt", request)
            // The pixel golden is the sha256 of the PNG, not the PNG. 24 console-sized
            // renders weigh 7.6 MB and every `--update` would rewrite half-megabyte binaries
            // into git history; the digests are 65 bytes each and detect the same change.
            // The rendered PNG still lands in the artifact directory, and the contact sheet
            // is how you actually look at it.
            let pixelGolden = goldenURL(scene, "png.sha256", request)
            // Snapshotted before `reconcile`, which overwrites the golden in `update` mode.
            let previousAX = FileManager.default.contents(atPath: axGolden.path)
                .flatMap { String(data: $0, encoding: .utf8) }
            let previousPixelDigest = FileManager.default.contents(atPath: pixelGolden.path)
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            writeArtifact(render.capture.png, to: artifactURL(scene, "png", request), warnings: &warnings)
            writeArtifact(axData, to: artifactURL(scene, "ax.txt", request), warnings: &warnings)

            let pixel = reconcile(
                payload: Data((render.capture.sha256 + "\n").utf8),
                golden: pixelGolden,
                mode: request.mode,
                blessable: blessable
            )
            let axOutcome = reconcile(payload: axData, golden: axGolden, mode: request.mode, blessable: blessable)
            refreshDiff(
                scene,
                axText: render.axText,
                previous: previousAX,
                status: axOutcome.status,
                request: request,
                warnings: &warnings
            )
            warnings.append(contentsOf: [pixel.warning, axOutcome.warning].compactMap { $0 })

            let result = UISceneResult(
                scene: scene,
                capture: render.capture,
                findings: findings,
                pixelStatus: pixel.status,
                axStatus: axOutcome.status,
                error: nil,
                durationMs: elapsedMs(since: clock)
            )
            return UISceneOutcome(
                result: result,
                warnings: warnings,
                axNodeCount: AXDump.nodeCount(render.root),
                goldenPNGDigest: previousPixelDigest
            )
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
