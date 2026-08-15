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

    /// Registry metadata for one deterministic harness scene. The descriptor owns
    /// construction so the catalog can enumerate metadata before producing `UIScene`s.
    struct UISceneDescriptor {
        let id: String
        let title: String
        let size: CGSize
        let colorScheme: ColorScheme
        let tags: [String]
        let steps: [UIStep]
        let accessibilityAdaptation: UIHarnessAccessibilityAdaptation?
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
            self.build = build
        }

        func makeScene() -> UIScene {
            UIScene(
                id: id,
                title: title,
                size: size,
                colorScheme: colorScheme,
                tags: tags,
                steps: steps,
                accessibilityAdaptation: accessibilityAdaptation,
                build: build
            )
        }
    }

    // The curated list of things the offscreen UI harness renders, dumps and lints.
    //
    // Adding a scene is a one-place edit: append a `UIScene` to the matching group
    // array below (`consoleScenes`, `menuScenes`, `overlayScenes`,
    // `accessibilityScenes`, `systemGlassScenes`), which is all `all()` concatenates.
    // Prefer the area factories over a raw `UIScene(...)` so sizes, tags and appearance
    // stay consistent. Every scene must be reproducible byte for
    // byte, which in practice means:
    //
    //   * take app state from `UIFixtures.coordinator(_:)` — never
    //     `DictationCoordinator.live()`, which spawns the ASR sidecar, taps the
    //     keyboard and opens the microphone;
    //   * never let a scene derive anything from `Date()`, `UUID()`, `.random`,
    //     `NSColor.controlAccentColor` or the user's TCC state
    //     (see `RenderOverrides` for the pins that already exist);
    //   * avoid states dominated by a `.repeatForever` animation or a
    //     `TimelineView(.animation)` — once the run loop turns, those hash
    //     differently on every run. The recording overlay's comet is the one such
    //     view in this app, and no scene here renders it.
    //
    // See docs/ui-harness.md.

    @MainActor
    enum UISceneCatalog {
        /// Console window measure: the app's own first-launch size, so goldens show
        /// exactly what a fresh install shows. Matches what `scripts/console_shot.sh`
        /// captures from the real app.
        static let consoleSize = CGSize(
            width: VoiceourMetrics.Window.defaultWidth,
            height: VoiceourMetrics.Window.defaultHeight
        )


        /// `MenuBarExtra` popover measure: matches `MenuView`'s fixed 280 pt
        /// `MenuLayout.popoverWidth`, tall enough for the fullest menu state without clipping.
        static let menuSize = CGSize(width: 280, height: 420)

        /// Ordered so the contact sheet reads top-down like the app does: the
        /// console tab by tab, then the pieces that live outside it.
        private static var registry: [UISceneDescriptor] {
            consoleScenes
                + menuScenes
                + overlayScenes
                + accessibilityScenes
                + systemGlassScenes
        }

        static func everything() -> [UIScene] {
            // Covers direct overlay scenes as well as coordinator-backed ones.
            // Portable scenes stay pinned to the painted path; only the explicitly
            // tagged system-glass scenes below release that pin for their lifetime.
            UIFixtures.pinProcessSeams()
            return registry.map { $0.makeScene() }
        }

        static func all(request: UIHarnessRequest) -> [UIScene] {
            everything().filter(request.matches)
        }

        /// Unfiltered catalog access for structural tests.
        static func all() -> [UIScene] {
            everything()
        }

        // MARK: Console — one per native tab, plus its notable states

        private static var consoleScenes: [UISceneDescriptor] {
            [
                console(
                    "console.general.default",
                    "General settings: capture, cleanup and audio",
                    tab: .general,
                    fixture: .populated
                ),
                console(
                    "console.glossary.populated",
                    "Glossary with the bundled canonical terms",
                    tab: .glossary,
                    fixture: .populated
                ),
                console(
                    "console.glossary.empty",
                    "Glossary with every term removed",
                    tab: .glossary,
                    fixture: .emptyGlossary,
                    tags: ["empty"]
                ),
                console(
                    "console.sessions.populated",
                    "History list, day groups and transcript detail",
                    tab: .history,
                    fixture: .populated
                ),
                console(
                    "console.sessions.selection",
                    "History transcript with a selected surface ready to teach",
                    tab: .history,
                    fixture: .populated,
                    transcriptSelectionSurface: "offscreen renderer"
                ),
                console(
                    "console.sessions.empty",
                    "History with nothing dictated yet",
                    tab: .history,
                    fixture: .firstRun,
                    tags: ["empty"]
                ),
                console(
                    "console.sessions.search",
                    "History filtered by a typed query",
                    tab: .history,
                    fixture: .populated,
                    tags: ["steps"],
                    steps: [
                        .type("accessibility", into: "sessions.search.field"),
                        .settle(120)
                    ]
                ),
                console(
                    "console.system.granted",
                    "System readiness with every permission granted",
                    tab: .system,
                    fixture: .backendReady
                ),
                console(
                    "console.system.denied",
                    "System readiness with permissions denied",
                    tab: .system,
                    fixture: .backendUnavailable
                ),
                console(
                    "console.system.downloading",
                    "System readiness while the model is still downloading",
                    tab: .system,
                    fixture: .backendDownloading
                )
            ]
        }

        /// Representative native-material scenes for each surviving surface with
        /// a macOS 26 availability branch. The console itself is now a native
        /// `TabView`/`Form` hierarchy and has no separate branch.
        ///
        /// What these verify is the app's own painted content, geometry, control
        /// boundaries and accessibility tree on that branch -- NOT the system material.
        /// `cacheDisplay` does not rasterise SwiftUI `.glassEffect`, so the material is
        /// absent from these captures rather than flattened.
        private static var systemGlassScenes: [UISceneDescriptor] {
            [
                systemMenu(
                    "menu.idle.os26",
                    "Menu bar popover at rest on the native branch",
                    fixture: .populated
                ),
                systemMenu(
                    "menu.error.os26",
                    "Menu bar popover after a failed start on the native branch",
                    fixture: .micDenied
                ),
                systemMenu(
                    "menu.transcript.os26",
                    "Menu bar popover with the last transcript on the native branch",
                    fixture: .completedDictation
                ),
                systemOverlay(
                    "overlay.panel.recording.os26",
                    "Recording overlay panel, listening on the native branch",
                    size: CGSize(width: 260, height: 80)
                ),
                systemOverlay(
                    "overlay.island.recording.os26",
                    "Recording overlay island, listening on the native branch",
                    size: CGSize(width: 180, height: 34),
                    islandOnly: true
                ),
            ]
        }


        // MARK: Accessibility adaptations

        /// Each scene is a native console tab with exactly one accessibility
        /// adaptation enabled. The app-owned seams are necessary because the SDK
        /// environment values are get-only.
        private static var accessibilityScenes: [UISceneDescriptor] {
            [
                accessibilityConsole(
                    "a11y.reduce-transparency",
                    "History transcript with Reduce Transparency enabled",
                    tab: .history,
                    fixture: .populated,
                    adaptation: .reduceTransparency
                ),
                accessibilityConsole(
                    "a11y.increase-contrast",
                    "General settings with Increase Contrast enabled",
                    tab: .general,
                    fixture: .populated,
                    adaptation: .increaseContrast
                ),
                accessibilityConsole(
                    "a11y.differentiate-without-color",
                    "Denied system state with Differentiate Without Color enabled",
                    tab: .system,
                    fixture: .backendUnavailable,
                    adaptation: .differentiateWithoutColor
                )
            ]
        }

        // MARK: Menu bar popover

        private static var menuScenes: [UISceneDescriptor] {
            [
                menu("menu.idle", "Menu bar popover at rest", fixture: .populated),
                menu("menu.error", "Menu bar popover after a failed start", fixture: .micDenied),
                menu("menu.transcript", "Menu bar popover with the last transcript", fixture: .completedDictation),
            ]
        }

        // MARK: Recording overlay

        private static var overlayScenes: [UISceneDescriptor] {
            [
                UISceneDescriptor(
                    id: "overlay.panel.recording",
                    title: "Recording overlay panel, listening",
                    size: RecordingOverlayMetrics.windowSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: listeningOverlayModel(),
                            onCancel: {},
                            onFinish: {}
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.recording",
                    title: "Recording overlay island, listening",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: listeningOverlayModel(),
                            onCancel: {},
                            onFinish: {},
                            islandOnly: true
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.warmup",
                    title: "Recording overlay island, microphone still warming up",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: warmingOverlayModel(),
                            onCancel: {},
                            onFinish: {},
                            islandOnly: true
                        )
                    )
                },
            ]
        }


        // MARK: - Factories

        /// A full native console window, at the app's first-launch measure.
        /// `ConsoleWindowView` suppresses activation while the harness keeps the
        /// process policy `.prohibited`, so hosting it can never take focus.
        private static func console(
            _ identifier: String,
            _ title: String,
            tab: ConsoleTab,
            fixture: UIFixtures.Kind,
            transcriptSelectionSurface: String? = nil,
            // Optional rather than `= consoleSize`: a default argument expression is
            // evaluated outside this enum's main-actor context, so it may not read a
            // main-actor static. Nil is the first-launch measure, resolved below.
            size: CGSize? = nil,
            tags: [String] = [],
            steps: [UIStep] = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size ?? consoleSize,
                colorScheme: .dark,
                tags: ["console"] + tags,
                steps: steps
            ) {
                if let transcriptSelectionSurface {
                    return AnyView(
                        UIHarnessTranscriptSelectionScope(surface: transcriptSelectionSurface) {
                            AnyView(
                                ConsoleWindowView(
                                    coordinator: UIFixtures.coordinator(fixture),
                                    initialTab: tab
                                )
                            )
                        }
                    )
                }
                return AnyView(ConsoleWindowView(coordinator: UIFixtures.coordinator(fixture), initialTab: tab))
            }
        }


        /// A full-console accessibility variant. The scene contract installs the
        /// selected adaptation before SwiftUI evaluates the hierarchy and restores
        /// the prior process-wide seams during teardown.
        private static func accessibilityConsole(
            _ identifier: String,
            _ title: String,
            tab: ConsoleTab,
            fixture: UIFixtures.Kind,
            adaptation: UIHarnessAccessibilityAdaptation
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: consoleSize,
                colorScheme: .dark,
                tags: ["console", "a11y"],
                accessibilityAdaptation: adaptation
            ) {
                AnyView(ConsoleWindowView(coordinator: UIFixtures.coordinator(fixture), initialTab: tab))
            }
        }


        private static func menu(
            _ identifier: String,
            _ title: String,
            fixture: UIFixtures.Kind
        ) -> UISceneDescriptor {
            UISceneDescriptor(id: identifier, title: title, size: menuSize, tags: ["menu"]) {
                AnyView(
                    MenuView(coordinator: UIFixtures.coordinator(fixture))
                        .frame(width: menuSize.width, alignment: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(backdrop(for: .dark))
                )
            }
        }

        /// The menu equivalent of `systemConsole`: coordinator construction pins
        /// process seams, so the native path is released only after the fixture exists.
        private static func systemMenu(
            _ identifier: String,
            _ title: String,
            fixture: UIFixtures.Kind
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: menuSize,
                tags: ["menu", "os26"]
            ) {
                AnyView(
                    UIHarnessSystemGlassScope {
                        AnyView(
                            MenuView(coordinator: UIFixtures.coordinator(fixture))
                                .frame(width: menuSize.width, alignment: .top)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .background(backdrop(for: .dark))
                        )
                    }
                )
            }
        }

        /// Native-material overlay scenes at both production measures. The model
        /// is built while the process is pinned, then the seam is released exactly
        /// as it is for the system console and menu scenes.
        private static func systemOverlay(
            _ identifier: String,
            _ title: String,
            size: CGSize,
            islandOnly: Bool = false
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size,
                tags: ["overlay", "os26"]
            ) {
                AnyView(
                    UIHarnessSystemGlassScope {
                        AnyView(
                            RecordingOverlayView(
                                model: listeningOverlayModel(),
                                onCancel: {},
                                onFinish: {},
                                islandOnly: islandOnly
                            )
                        )
                    }
                )
            }
        }


        /// Literal fills, not `NSColor` system colours: a dynamic system colour
        /// resolves against this Mac's accent and appearance settings and would not
        /// port between machines.
        private static func backdrop(for scheme: ColorScheme) -> Color {
            scheme == .dark ? VoiceourPalette.Ink.void : Color(white: 0.96)
        }

        // MARK: - Overlay state

        /// Eleven fixed meter samples, oldest first — the same shape the live meter
        /// produces, minus the microphone.
        private static let waveformLevels: [Float] = [
            0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46,
        ]

        /// A capture that is live and receiving buffers, which is the overlay state
        /// that draws the waveform. The processing states draw `FrostedCometIndicator`
        /// instead — a `TimelineView(.animation)` whose orbit phase comes from the
        /// wall clock, so it can never hash the same twice and is left uncovered.
        private static func listeningOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.recording)
            model.updateCaptureLive(true)
            for level in waveformLevels {
                model.record(level)
            }
            return model
        }

        /// A capture that has been started and is not delivering audio yet: the state the
        /// island holds for 1422 ms on a cold AirPods Max link against 99 ms on the
        /// built-in microphone. The meter samples below are fed in deliberately —
        /// `record(_:)` drops every one of them while capture is not live, so this scene
        /// pins both halves of the fix at once: the waveform cannot draw from a warm-up
        /// buffer, and the slot reads WARMING instead of a flat meter.
        private static func warmingOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.recording)
            for level in waveformLevels {
                model.record(level)
            }
            return model
        }
    }

    /// Process-wide value seam scoped to the one scene that needs an AppKit text
    /// selection. Building the fixture first lets its standard seam pins run
    /// before this scene installs its readable substring.
    private struct UIHarnessTranscriptSelectionScope: View {
        private let content: AnyView
        private let previousSurface: String?

        @MainActor
        init(surface: String, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previousSurface = RenderOverrides.transcriptSelectionSurface
            RenderOverrides.transcriptSelectionSurface = surface
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.transcriptSelectionSurface = previousSurface
                }
        }
    }

    /// Process-wide render seam scoped to one hosted scene. `onDisappear` runs during
    /// `UIHarnessRuntime` teardown before the next scene is built, preventing the
    /// native path from contaminating portable scenes later in the same process.
    private struct UIHarnessSystemGlassScope: View {
        private let content: AnyView
        private let previousForceLegacyGlass: Bool

        @MainActor
        init(build: @escaping @MainActor () -> AnyView) {
            content = build()
            previousForceLegacyGlass = RenderOverrides.forceLegacyGlass
            RenderOverrides.forceLegacyGlass = false
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.forceLegacyGlass = previousForceLegacyGlass
                }
        }
    }


#endif
