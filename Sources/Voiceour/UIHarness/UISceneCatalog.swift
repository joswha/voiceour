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
    import VoiceCore
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
    //   * never leave a `.repeatForever`, `TimelineView(.animation)` or view-bound
    //     display link live in a scene. A continuous renderer needs an exact pinned
    //     frame seam; the recording island uses `RenderOverrides.mercuryStep`.
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
                    "console.home.populated",
                    "Home lifetime stats, streaks and the activity grid",
                    tab: .home,
                    fixture: .populated
                ),
                // The only scene that renders Home's whole page at once: the default
                // 820 pt window clips the activity grid, so nothing else locks the
                // heatmap, its month rail and its legend against a layout change.
                console(
                    "console.home.full-page",
                    "Home's whole page at documentation height",
                    tab: .home,
                    fixture: .populated,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 1_080)
                ),
                console(
                    "console.home.empty",
                    "Home with its history and lifetime figures erased",
                    tab: .home,
                    fixture: .erasedFigures,
                    tags: ["empty"]
                ),
                // The three states a fresh install actually meets, in the order a
                // reader meets them. All three carry Home's first-run card, which
                // exists only until a dictation is delivered, so no other scene can
                // show them: a fixture with sessions has already retired it.
                console(
                    "console.home.first-run.downloading",
                    "Home's first-run card while the speech model downloads",
                    tab: .home,
                    fixture: .firstRunDownloading,
                    tags: ["first-run"]
                ),
                console(
                    "console.home.first-run.ready",
                    "Home's first-run card with the model ready and no permission answered",
                    tab: .home,
                    fixture: .firstRunReady,
                    tags: ["first-run"]
                ),
                console(
                    "console.home.first-run.failed",
                    "Home's first-run card after the sidecar reported a failed acquisition",
                    tab: .home,
                    fixture: .firstRunAcquisitionFailed,
                    tags: ["first-run"]
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
                    "console.glossary.mixed",
                    "Glossary with a taught term and an imported term",
                    tab: .glossary,
                    fixture: .mixedGlossary
                ),
                console(
                    "console.glossary.editing",
                    "Glossary with one term open for editing",
                    tab: .glossary,
                    fixture: .mixedGlossary,
                    tags: ["steps"],
                    steps: [.press("glossary.term.kubectl")]
                ),
                console(
                    "console.glossary.search",
                    "Glossary narrowed by a typed query",
                    tab: .glossary,
                    fixture: .mixedGlossary,
                    tags: ["steps"],
                    steps: [.type("dock", into: "glossary.search.field")]
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
                    "console.sessions.teach",
                    "History teach editor opened on the selected surface",
                    tab: .history,
                    fixture: .populated,
                    teachingSurface: "offscreen renderer"
                ),
                console(
                    "console.sessions.deselected",
                    "History after the open transcript was closed",
                    tab: .history,
                    fixture: .populated,
                    deselected: true
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
                        .settle(120),
                    ]
                ),
                console(
                    "console.sessions.filtered",
                    "History filtered to one app's sessions",
                    tab: .history,
                    fixture: .populated,
                    appFilter: "com.apple.dt.Xcode"
                ),
                console(
                    "console.settings.granted",
                    "Settings preferences and readiness with every permission granted",
                    tab: .settings,
                    fixture: .backendReady
                ),
                console(
                    "console.settings.denied",
                    "Settings readiness with permissions denied",
                    tab: .settings,
                    fixture: .backendUnavailable
                ),
                console(
                    "console.settings.downloading",
                    "Settings readiness while the model is still downloading",
                    tab: .settings,
                    fixture: .backendDownloading
                ),
            ]
        }

        /// Representative native-material scenes for each surviving surface with
        /// a macOS 26 availability branch. The console itself is now a native
        /// `TabView`/`Form` hierarchy and has no separate branch, and the recording
        /// island has no branch at all: it is one CPU-rasterized mercury body on
        /// every OS, with no capsule, no material and no glass to exercise.
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
                    "Settings preferences with Increase Contrast enabled",
                    tab: .settings,
                    fixture: .populated,
                    adaptation: .increaseContrast
                ),
                accessibilityConsole(
                    "a11y.differentiate-without-color",
                    "Denied readiness state with Differentiate Without Color enabled",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    adaptation: .differentiateWithoutColor
                ),
                accessibilityConsole(
                    "a11y.home.differentiate",
                    "Home activity grid with Differentiate Without Color enabled",
                    tab: .home,
                    fixture: .populated,
                    adaptation: .differentiateWithoutColor
                ),
                accessibilityConsole(
                    "a11y.home.reduce-transparency",
                    "Home islands with Reduce Transparency enabled",
                    tab: .home,
                    fixture: .populated,
                    adaptation: .reduceTransparency
                ),
            ]
        }

        // MARK: Menu bar popover

        private static var menuScenes: [UISceneDescriptor] {
            [
                menu("menu.idle", "Menu bar popover at rest", fixture: .populated),
                menu("menu.error", "Menu bar popover after a failed start", fixture: .micDenied),
                menu("menu.transcript", "Menu bar popover with the last transcript", fixture: .completedDictation),
                menu(
                    "menu.downloading",
                    "Menu bar popover while the speech model downloads",
                    fixture: .backendDownloading
                ),
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
                    title: "Recording overlay island, speaking",
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
                    id: "overlay.island.listening",
                    title: "Recording overlay island, live microphone hearing nothing",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: quietOverlayModel(),
                            onCancel: {},
                            onFinish: {},
                            islandOnly: true
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.copied",
                    title: "Recording overlay island, copy-only outcome",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: copiedOverlayModel(),
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
                UISceneDescriptor(
                    id: "overlay.island.processing",
                    title: "Recording overlay island, transcribing",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: processingOverlayModel(),
                            onCancel: {},
                            onFinish: {},
                            islandOnly: true
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.reduced-motion",
                    title: "Recording overlay island with Reduce Motion enabled",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay", "a11y"],
                    accessibilityAdaptation: .reduceMotion
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
                    id: "overlay.island.weather",
                    title: "Recording overlay island reflecting the debug Spectral Weather world",
                    size: RecordingOverlayMetrics.islandSize,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        UIHarnessMercuryWorldScope(world: .spectralWeather) {
                            AnyView(
                                RecordingOverlayView(
                                    model: listeningOverlayModel(),
                                    onCancel: {},
                                    onFinish: {},
                                    islandOnly: true
                                )
                            )
                        }
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
            deselected: Bool = false,
            appFilter: String? = nil,
            teachingSurface: String? = nil,
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
                if deselected {
                    return AnyView(
                        UIHarnessDeselectedHistoryScope {
                            AnyView(
                                ConsoleWindowView(
                                    coordinator: UIFixtures.coordinator(fixture),
                                    initialTab: tab
                                )
                            )
                        }
                    )
                }
                if let appFilter {
                    return AnyView(
                        UIHarnessFilteredHistoryScope(bundleId: appFilter) {
                            AnyView(
                                ConsoleWindowView(
                                    coordinator: UIFixtures.coordinator(fixture),
                                    initialTab: tab
                                )
                            )
                        }
                    )
                }
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
                if let teachingSurface {
                    return AnyView(
                        UIHarnessTeachingHistoryScope(surface: teachingSurface) {
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

        /// Literal fills, not `NSColor` system colours: a dynamic system colour
        /// resolves against this Mac's accent and appearance settings and would not
        /// port between machines.
        private static func backdrop(for scheme: ColorScheme) -> Color {
            scheme == .dark ? VoiceourPalette.Ink.void : Color(white: 0.96)
        }

        // MARK: - Overlay state

        /// Eleven fixed drive levels, oldest first — the same shape the live meter
        /// produces, minus the microphone. They are the mercury body's forcing now, not
        /// bar heights: the body reads them as a travelling crest train.
        private static let driveLevels: [Float] = [
            0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46,
        ]

        /// A capture that is live and receiving buffers. These levels also carry it past
        /// the voice-activity hysteresis — two consecutive samples at or above 0.10 — so
        /// the golden records the speaking pose rather than the listening one.
        private static func listeningOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.recording)
            model.updateCaptureLive(true)
            for level in driveLevels {
                model.record(level)
            }
            return model
        }

        /// A live microphone in a quiet room. Every level sits at or below the release
        /// threshold, so the voice-activity hysteresis never starts and the body holds
        /// the narrower listening pose. This is the state a user looks at before every
        /// utterance, so it gets a golden of its own rather than sharing one with the
        /// speaking body.
        private static func quietOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.recording)
            model.updateCaptureLive(true)
            for level in [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]
                as [Float]
            {
                model.record(level)
            }
            return model
        }

        /// One unclean delivery at its stable endpoint: the gathered gesture, no control
        /// of any kind, and one safe status value.
        private static func copiedOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            let state = SessionState.copiedOnly(reason: "target_terminal")
            model.update(state)
            if let outcome = RecordingOverlayOutcome(state: state) {
                model.present(outcome)
            }
            return model
        }

        /// A capture that has been started and is not delivering audio yet: the state the
        /// island holds for 1422 ms on a cold AirPods Max link against 99 ms on the
        /// built-in microphone. The drive levels below are fed in deliberately —
        /// `record(_:)` drops every one of them while capture is not live, so this scene
        /// pins both halves of the fix at once: the body cannot be driven from a warm-up
        /// buffer, and it holds the small calm warming lens instead of the listening pose.
        private static func warmingOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.recording)
            for level in driveLevels {
                model.record(level)
            }
            return model
        }

        /// The working droplet: short, tall, and disconnected from the voice. Capturable
        /// now that the retired three-dot mark's wall-clock phase is gone — the body is
        /// pinned to one substep index like every other overlay scene.
        private static func processingOverlayModel() -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(.transcribing)
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

    /// Process-wide value seam scoped to the one scene that renders History's teach
    /// editor. Command-T and the transcript's own `Fix / Teach` item are the only
    /// ways in, and neither can be delivered to a window that never becomes key, so
    /// the state is pinned rather than performed. One surface sets both seams
    /// because the gesture leaves both behind it: the selection the footer line
    /// names, and the form the editor opens holding.
    private struct UIHarnessTeachingHistoryScope: View {
        private let content: AnyView
        private let previousSurface: String?
        private let previousTeachSurface: String?

        @MainActor
        init(surface: String, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previousSurface = RenderOverrides.transcriptSelectionSurface
            previousTeachSurface = RenderOverrides.historyTeachSurface
            RenderOverrides.transcriptSelectionSurface = surface
            RenderOverrides.historyTeachSurface = surface
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.transcriptSelectionSurface = previousSurface
                    RenderOverrides.historyTeachSurface = previousTeachSurface
                }
        }
    }

    /// Process-wide value seam scoped to the one scene that renders History with no
    /// transcript open. Closing one is a click on the form's own background, which
    /// no scene step can address — steps press accessibility nodes — so the state is
    /// pinned rather than performed.
    private struct UIHarnessDeselectedHistoryScope: View {
        private let content: AnyView
        private let previous: Bool

        @MainActor
        init(build: @escaping @MainActor () -> AnyView) {
            content = build()
            previous = RenderOverrides.historyStartsDeselected
            RenderOverrides.historyStartsDeselected = true
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.historyStartsDeselected = previous
                }
        }
    }

    /// Process-wide value seam scoped to the one scene that renders History
    /// narrowed to a single app. Engaging the filter opens an `NSMenu`, which an
    /// offscreen window that can never order front cannot show, so the filtered
    /// state is pinned rather than performed.
    private struct UIHarnessFilteredHistoryScope: View {
        private let content: AnyView
        private let previous: String?

        @MainActor
        init(bundleId: String, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previous = RenderOverrides.historyInitialAppFilter
            RenderOverrides.historyInitialAppFilter = bundleId
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.historyInitialAppFilter = previous
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

    /// Process-wide value seam scoped to the one scene that renders the debug world.
    /// Switching it in the running app is a Settings picker behind `--debug`, which the
    /// harness never passes, so the state is pinned rather than performed.
    private struct UIHarnessMercuryWorldScope: View {
        private let content: AnyView
        private let previous: MercuryWorld?

        @MainActor
        init(world: MercuryWorld, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previous = RenderOverrides.mercuryWorld
            RenderOverrides.mercuryWorld = world
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.mercuryWorld = previous
                }
        }
    }

#endif
