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
    // MARK: - Goldens

    extension UIHarnessMain {
        /// Compares one payload against its golden, writing the golden in `update` mode.
        ///
        /// An identical payload reports `ok` rather than `written`, and nothing is written:
        /// `--update` then names exactly which goldens moved and leaves the rest untouched
        /// in git.
        static func reconcile(
            payload: Data,
            golden: URL,
            mode: UIHarnessRequest.Mode,
            blessable: Bool
        ) -> UIGoldenOutcome {
            let existing = FileManager.default.contents(atPath: golden.path)
            if existing == payload {
                return UIGoldenOutcome(status: .ok, warning: nil)
            }
            guard mode.writesGoldens, blessable else {
                return UIGoldenOutcome(status: existing == nil ? .missingGolden : .changed, warning: nil)
            }
            do {
                try payload.write(to: golden, options: .atomic)
                return UIGoldenOutcome(status: .written, warning: nil)
            } catch {
                let warning = "cannot write golden \(golden.lastPathComponent): \(describe(error))"
                return UIGoldenOutcome(status: .failed, warning: warning)
            }
        }

        /// Writes `<out>/<id>.ax.diff` while the dump differs from its golden, and clears the
        /// file otherwise. This is the first artifact an agent should read after a red run,
        /// so a stale one is worse than none: `written` means `update` just replaced the
        /// golden with this very dump, and the diff it would describe no longer exists.
        static func refreshDiff(
            _ scene: UIScene,
            axText: String,
            previous: String?,
            status: UISceneResult.Status,
            request: UIHarnessRequest,
            warnings: inout [String]
        ) {
            let diffURL = artifactURL(scene, "ax.diff", request)
            guard status != .written, let previous, previous != axText else {
                try? FileManager.default.removeItem(at: diffURL)
                return
            }
            let text = UIHarnessDiff.unified(
                old: previous.components(separatedBy: "\n"),
                new: axText.components(separatedBy: "\n"),
                oldLabel: goldenURL(scene, "ax.txt", request).path,
                newLabel: artifactURL(scene, "ax.txt", request).path
            )
            writeArtifact(Data(text.utf8), to: diffURL, warnings: &warnings)
        }

        /// `<id>.<suffix>` at the default scale, `<id>@2x.<suffix>` otherwise.
        ///
        /// Without the suffix a `--scale 2` run would diff 2x pixels against 1x goldens and
        /// report every scene as `changed`. The scale also pins `displayScale`, which moves
        /// pixel snapping and therefore the accessibility frames, so the dump is scaled too.
        private static func basename(_ scene: UIScene, _ suffix: String, _ scale: Int) -> String {
            scale == 1 ? "\(scene.id).\(suffix)" : "\(scene.id)@\(scale)x.\(suffix)"
        }

        static func artifactURL(_ scene: UIScene, _ suffix: String, _ request: UIHarnessRequest) -> URL {
            request.outputDirectory.appendingPathComponent(basename(scene, suffix, request.scale))
        }

        static func goldenURL(_ scene: UIScene, _ suffix: String, _ request: UIHarnessRequest) -> URL {
            request.goldenDirectory.appendingPathComponent(basename(scene, suffix, request.scale))
        }

        static func writeArtifact(_ data: Data, to url: URL, warnings: inout [String]) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                warnings.append("cannot write \(url.lastPathComponent): \(describe(error))")
            }
        }
    }

    // MARK: - Contact sheet

    extension UIHarnessMain {
        static func writeContactSheet(_ outcomes: [UISceneOutcome], request: UIHarnessRequest) -> String? {
            guard request.contactSheet else { return nil }
            let tiles: [(id: String, png: Data)] = outcomes.compactMap { outcome in
                guard let capture = outcome.result.capture else { return nil }
                return (id: outcome.result.scene.id, png: capture.png)
            }
            guard !tiles.isEmpty else { return nil }

            let columns = min(4, max(1, Int(Double(tiles.count).squareRoot().rounded(.up))))
            let url = request.outputDirectory.appendingPathComponent("contact-sheet.png")
            do {
                try UIContactSheet.compose(tiles, columns: columns).write(to: url, options: .atomic)
                return url.path
            } catch {
                report("contact sheet: \(describe(error))")
                return nil
            }
        }
    }
    struct UIGoldenOutcome {
        let status: UISceneResult.Status
        let warning: String?
    }

#endif
