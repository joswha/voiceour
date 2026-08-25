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
    import SwiftUI

    // Shared vocabulary for the offscreen UI harness. Every harness file compiles against
    // these types; nothing here touches AppKit state, so it is safe to reference from the
    // scene catalog, the renderer, the accessibility dump, the lint rules and the CLI.
    //
    // Why the harness exists, and why it is shaped like this, is recorded in
    // docs/ui-harness.md. The short version: agents must be able to inspect this app
    // without a window ever appearing on the user's display.

    /// One get-only accessibility environment adaptation exercised by a scene.
    /// The scope below installs it before SwiftUI evaluates the hierarchy and
    /// restores the prior process-wide seams when the hierarchy disappears.
    enum UIHarnessAccessibilityAdaptation {
        case reduceTransparency
        case increaseContrast
        case differentiateWithoutColor
    }

    /// A single deterministic thing the harness can render, dump and lint.
    struct UIScene {
        /// Stable identifier. Doubles as the artifact basename, so keep it filesystem-safe:
        /// lowercase, dot-separated, e.g. `console.sessions.populated`.
        let id: String
        /// One-line human description used in the contact sheet caption.
        let title: String
        /// Logical point size of the offscreen window content view.
        let size: CGSize
        /// Appearance to force. The harness never inherits the user's system setting.
        let colorScheme: ColorScheme
        /// Free-form grouping used by `--only` filtering, e.g. `console`, `overlay`, `atom`.
        let tags: [String]
        /// Interaction script applied after the first settle and before capture.
        let steps: [UIStep]
        /// Optional accessibility adaptation scoped to this scene's hierarchy.
        let accessibilityAdaptation: UIHarnessAccessibilityAdaptation?
        /// Builds the view. Runs on the main actor inside the harness process only.
        let build: @MainActor () -> AnyView

        init(
            id: String,
            title: String,
            size: CGSize,
            colorScheme: ColorScheme = .dark,
            tags: [String] = [],
            steps: [UIStep] = [],
            accessibilityAdaptation: UIHarnessAccessibilityAdaptation? = nil,
            build: @escaping @MainActor () -> AnyView
        ) {
            self.id = id
            self.title = title
            self.size = size
            self.colorScheme = colorScheme
            self.tags = tags
            self.steps = steps
            self.accessibilityAdaptation = accessibilityAdaptation
            if let accessibilityAdaptation {
                self.build = {
                    AnyView(
                        UIHarnessAccessibilityScope(
                            adaptation: accessibilityAdaptation,
                            build: build
                        )
                    )
                }
            } else {
                self.build = build
            }
        }
    }

    private struct UIHarnessAccessibilityScope: View {
        private let content: AnyView
        private let previous: UIHarnessAccessibilitySnapshot

        @MainActor
        init(
            adaptation: UIHarnessAccessibilityAdaptation,
            build: @escaping @MainActor () -> AnyView
        ) {
            previous = .capture()
            // Fixture construction restores the deterministic baseline, so install
            // the adaptation after building the value but before SwiftUI reads it.
            content = build()
            adaptation.install()
        }

        var body: some View {
            content.onDisappear {
                previous.restore()
            }
        }
    }

    private struct UIHarnessAccessibilitySnapshot {
        let reduceTransparency: Bool?
        let reduceMotion: Bool?
        let differentiateWithoutColor: Bool?
        let increasedContrast: Bool?

        static func capture() -> Self {
            Self(
                reduceTransparency: RenderOverrides.reduceTransparency,
                reduceMotion: RenderOverrides.reduceMotion,
                differentiateWithoutColor: RenderOverrides.differentiateWithoutColor,
                increasedContrast: RenderOverrides.increasedContrast
            )
        }

        func restore() {
            RenderOverrides.reduceTransparency = reduceTransparency
            RenderOverrides.reduceMotion = reduceMotion
            RenderOverrides.differentiateWithoutColor = differentiateWithoutColor
            RenderOverrides.increasedContrast = increasedContrast
        }
    }

    extension UIHarnessAccessibilityAdaptation {
        fileprivate func install() {
            RenderOverrides.reduceTransparency = false
            RenderOverrides.reduceMotion = false
            RenderOverrides.differentiateWithoutColor = false
            RenderOverrides.increasedContrast = false

            switch self {
            case .reduceTransparency:
                RenderOverrides.reduceTransparency = true
            case .increaseContrast:
                RenderOverrides.increasedContrast = true
            case .differentiateWithoutColor:
                RenderOverrides.differentiateWithoutColor = true
            }
        }
    }

    /// Scripted interaction against the offscreen window.
    ///
    /// Deliberately tiny. Synthetic mouse events into an offscreen window are viable but
    /// sharp (AppKit tracking loops deadlock unless mouseUp is enqueued before mouseDown),
    /// so the default click path is the accessibility press action and the mouse path is
    /// the explicit escape hatch.
    enum UIStep {
        /// Press the first accessibility node whose identifier or label matches.
        case press(String)
        /// Synthetic mouse click at the centre of the matching node's frame.
        case click(String)
        /// Type into the current field editor after focusing the matching node.
        case type(String, into: String)
        /// Pump the run loop for a fixed number of milliseconds.
        case settle(Int)
    }

    /// One node of the in-process accessibility tree.
    ///
    /// `frame` is window-local with a top-left origin, in points. Screen coordinates are
    /// deliberately discarded: they would bake the offscreen window's origin into goldens.
    struct AXNode {
        var role: String
        var subrole: String?
        var label: String?
        var value: String?
        /// Prompt text a text field shows while empty (`AXPlaceholderValue`). It is the only
        /// thing identifying an untouched field, so it is both dumped and matchable.
        var placeholder: String?
        var identifier: String?
        var help: String?
        /// Only meaningful for control roles; `nil` for containers that never model it.
        var enabled: Bool?
        /// The `.isSelected` accessibility trait, measured through `isAccessibilitySelected`.
        ///
        /// Deliberately NOT printed by `AXDump.text`. Selection is the one rail fact the
        /// committed dumps never recorded -- different console pane goldens carry
        /// byte-identical rail blocks -- which is exactly the blind spot that let a
        /// rasterisation gap read as "the accessibility tree stayed byte-identical".
        /// Flows can assert it; no golden moves.
        var selected: Bool?
        var frame: CGRect
        var children: [AXNode]
    }

    /// Result of rasterising a scene.
    struct UICapture {
        let width: Int
        let height: Int
        let png: Data
        let sha256: String
        /// Fraction of pixels sharing the single most common colour. 1.0 means a flat fill.
        let dominantColorFraction: Double
        /// Fraction of pixels matching SwiftUI's `#FFCC00` unsupported-view placeholder.
        let placeholderFraction: Double
    }

    /// A machine-checkable UX problem found in a scene.
    struct UIFinding {
        enum Severity: String {
            case error
            case warning
        }

        let rule: String
        let severity: Severity
        let message: String
        /// Slash-joined role path from the hosting root, e.g. `AXGroup/AXScrollArea/AXButton`.
        let path: String
        let frame: CGRect
    }

    /// Per-scene outcome, serialised as one `type: "ui_scene"` line of the manifest.
    struct UISceneResult {
        enum Status: String {
            case ok
            case changed
            case missingGolden
            case written
            case failed
        }

        let scene: UIScene
        let capture: UICapture?
        let findings: [UIFinding]
        let pixelStatus: Status
        let axStatus: Status
        let error: String?
        let durationMs: Int

        var status: Status {
            if error != nil { return .failed }
            for candidate in [pixelStatus, axStatus] where candidate != .ok {
                return candidate
            }
            return .ok
        }
    }

    /// Parsed `--ui-harness` invocation.
    struct UIHarnessRequest {
        enum Mode: String {
            /// Print the scene catalog as JSON and exit.
            case list = "list"
            /// Render, dump, lint and compare against goldens.
            case check = "check"
            /// Same as `check`, but rewrite the goldens instead of failing.
            case update = "update"
            /// Print the flow catalog as JSON and exit.
            case flowList = "flow-list"
            /// Drive flows and compare their semantic journals against goldens.
            case flowCheck = "flow-check"
            /// Same as `flowCheck`, but rewrite the journal goldens instead of failing.
            case flowUpdate = "flow-update"

            /// Whether this mode blesses goldens instead of failing on a difference.
            ///
            /// Shared by the scene and journal reconcilers so each update mode writes only
            /// its own selected goldens.
            var writesGoldens: Bool {
                switch self {
                case .update, .flowUpdate: return true
                case .list, .check, .flowList, .flowCheck: return false
                }
            }
        }

        var mode: Mode = .check
        /// Substring filter over scene or flow ids and tags. Empty means every entry.
        var only: [String] = []
        /// Substring filter over scene or flow ids and tags, applied after `only`.
        var except: [String] = []
        var outputDirectory: URL
        var goldenDirectory: URL
        var scale: Int = 1
        var contactSheet: Bool = true
        /// Emit the manifest to stdout as well as to disk.
        var stdoutManifest: Bool = false

        static let flag = "--ui-harness"

        static func repoRoot(arguments: [String]) -> URL {
            if let value = Self.value(for: "--repo-root", in: arguments) {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            if let value = ProcessInfo.processInfo.environment["VOICEOUR_REPO_ROOT"] {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        /// Supports both `--name=value` and `--name value`, matching the bench executables.
        static func value(for name: String, in arguments: [String]) -> String? {
            if let inline = arguments.first(where: { $0.hasPrefix(name + "=") }) {
                return String(inline.dropFirst(name.count + 1))
            }
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }

        /// Returns `nil` when the harness flag is absent, so normal app launch is untouched.
        init?(arguments: [String]) {
            guard arguments.contains(Self.flag) else { return nil }
            let root = Self.repoRoot(arguments: arguments)
            outputDirectory = root.appendingPathComponent(".build/ui-harness", isDirectory: true)
            goldenDirectory = root.appendingPathComponent("fixtures/ui", isDirectory: true)

            if let raw = Self.value(for: "--mode", in: arguments) {
                guard let parsed = Mode(rawValue: raw) else { return nil }
                mode = parsed
            } else if arguments.contains("--list") {
                mode = .list
            } else if arguments.contains("--update") {
                mode = .update
            } else if arguments.contains("--flow-list") {
                mode = .flowList
            } else if arguments.contains("--flow-check") {
                mode = .flowCheck
            } else if arguments.contains("--flow-update") {
                mode = .flowUpdate
            }

            let rawOnly = Self.value(for: "--only", in: arguments)
            if let raw = rawOnly {
                only = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            if let raw = Self.value(for: "--except", in: arguments) {
                except = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if mode != .list, mode != .flowList, rawOnly == nil {
                // An unfiltered render must stay on the portable path. Explicit filters
                // opt out exactly as they did when the catalog parsed argv itself.
                except = ["os26"]
            }
            if let raw = Self.value(for: "--out", in: arguments) {
                outputDirectory = URL(fileURLWithPath: raw, isDirectory: true)
            }
            if let raw = Self.value(for: "--golden", in: arguments) {
                goldenDirectory = URL(fileURLWithPath: raw, isDirectory: true)
            }
            if let raw = Self.value(for: "--scale", in: arguments), let parsed = Int(raw), parsed == 1 || parsed == 2 {
                scale = parsed
            }
            if arguments.contains("--no-sheet") { contactSheet = false }
            if arguments.contains("--stdout") { stdoutManifest = true }
        }

        func matches(_ scene: UIScene) -> Bool {
            matches(id: scene.id, tags: scene.tags)
        }

        /// The one spelling of `--only`/`--except` matching, so every catalog resolves a
        /// selection identically: `--except` first, then OR-ed substring-or-tag `--only`.
        func matches(id: String, tags: [String]) -> Bool {
            guard !excludes(id, tags: tags) else { return false }
            guard !only.isEmpty else { return true }
            return only.contains { needle in
                id.contains(needle) || tags.contains(needle)
            }
        }

        func excludes(_ id: String, tags: [String]) -> Bool {
            except.contains { needle in
                id.contains(needle) || tags.contains(needle)
            }
        }
    }

    extension UIHarnessRequest {
        static let usage = """
            usage: Voiceour --ui-harness [--list | --update | --flow-list | --flow-check | --flow-update] [options]

              --list             print the scene catalog as JSON and exit
              --update           rewrite scene goldens instead of failing on a difference
              --flow-list        print the flow catalog as JSON and exit
              --flow-check       run flows and compare semantic journals against goldens
              --flow-update      run flows and rewrite semantic journal goldens
              --mode MODE        list|check|update|flow-list|flow-check|flow-update (default check)
              --only a,b         only scenes or flows whose id contains, or whose tags include, a or b
              --except a,b       exclude scenes or flows whose id contains, or whose tags include, a or b; applied after --only
              --out DIR          artifact directory (default <repo>/.build/ui-harness)
              --golden DIR       golden directory (default <repo>/fixtures/ui)
              --repo-root DIR    resolves default --out/--golden (also VOICEOUR_REPO_ROOT)
              --scale 1|2        raster scale (default 1)
              --no-sheet         skip the contact sheet
              --stdout           also write the manifest to stdout

            Renders offscreen. Never activates the app, never places a window on a display,
            and requires no Screen Recording or Accessibility permission.
            """
    }

#endif
