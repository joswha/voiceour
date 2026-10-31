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
    // `accessibilityScenes`), which is all `all()` concatenates.
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

        /// Settings' whole page with every Island fold shut. The Island section puts
        /// Readiness, Capture, Privacy and Danger below the first-launch measure, so a scene
        /// about any of them renders at this height instead: a multiple of 4 that reaches the
        /// last Danger caption without a scroller.
        static let settingsPageSize = CGSize(
            width: VoiceourMetrics.Window.defaultWidth,
            height: 2_212
        )

        /// Ordered so the contact sheet reads top-down like the app does: the
        /// console tab by tab, then the pieces that live outside it.
        private static var registry: [UISceneDescriptor] {
            consoleScenes
                + menuScenes
                + overlayScenes
                + accessibilityScenes
        }

        static func everything() -> [UIScene] {
            // Covers direct overlay scenes as well as coordinator-backed ones. The
            // pins are process-wide, so they are installed before any scene closure
            // runs; every scene then renders the one shipping path.
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
                // The first-launch measure, which now ends inside the Island showroom: what a
                // fresh install's Settings tab shows before any scrolling.
                console(
                    "console.settings.granted",
                    "Settings at the first-launch measure with every permission granted",
                    tab: .settings,
                    fixture: .backendReady
                ),
                console(
                    "console.settings.denied",
                    "Settings' whole page, readiness with permissions denied",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    size: settingsPageSize
                ),
                console(
                    "console.settings.downloading",
                    "Settings' whole page, readiness while the model is still downloading",
                    tab: .settings,
                    fixture: .backendDownloading,
                    size: settingsPageSize
                ),
                // Every Garage control, caption, readout and spoken value at stock, and the
                // showroom's raster.
                console(
                    "console.settings.island.tuning",
                    "Settings' Island section with all four folds open at the stock look",
                    tab: .settings,
                    fixture: .backendReady,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 3_192),
                    tags: ["island", "steps"],
                    steps: islandFoldSteps
                ),
                // The rows only a non-stock look shows or enables: the film slider, the
                // underglow's color and strength, the Overcast radio, signed and kelvin
                // readouts away from stock, and the ARCTIC PLATINUM mark.
                console(
                    "console.settings.island.look",
                    "Settings' Island section with all four folds open on the Arctic Platinum look",
                    tab: .settings,
                    fixture: .islandLook,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 3_212),
                    tags: ["island", "steps"],
                    steps: islandFoldSteps
                ),
                // CUSTOM, a look list with nothing selected, and Dock Island live beside the
                // free placement's caption.
                console(
                    "console.settings.island.custom",
                    "Settings' Island section tuned off a look, with a free island placement",
                    tab: .settings,
                    fixture: .islandCustom,
                    size: settingsPageSize,
                    tags: ["island"]
                ),
                // An outcome pose, which only this scene can show: Play Again present and
                // enabled, and the showroom drawn at the gesture's pinned endpoint, the same
                // frame semantics as `overlay.island.copied`. Play Again itself is never
                // pressed here: its 1.2 s hold is wall-clock.
                console(
                    "console.settings.island.outcome",
                    "Settings' Island showroom holding the delivery-failed gesture",
                    tab: .settings,
                    fixture: .backendReady,
                    showroomPose: .deliveryFailed,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 1_024),
                    tags: ["island"]
                ),
            ]
        }

        /// Opens all four Garage folds. Each press reaches one `DisclosureGroup` through the
        /// identifier and named action on its label; the settle lets the last fold's rows
        /// finish inserting before the capture.
        private static let islandFoldSteps: [UIStep] = [
            .press("island.group.material"),
            .press("island.group.lighting"),
            .press("island.group.body"),
            .press("island.group.motion"),
            .settle(120),
        ]

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
                    "Settings' whole page denied, with Differentiate Without Color enabled",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    adaptation: .differentiateWithoutColor,
                    size: settingsPageSize
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
                // Brightness and Contrast disabled beside the caption that says why, and the
                // showroom drawn at the accessible tone the island itself will use.
                accessibilityConsole(
                    "a11y.island.increase-contrast",
                    "Settings' Island lighting fold with Increase Contrast enabled",
                    tab: .settings,
                    fixture: .backendReady,
                    adaptation: .increaseContrast,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 2_488),
                    tags: ["island", "steps"],
                    steps: [.press("island.group.lighting"), .settle(120)]
                ),
                // Shimmer disabled beside the caption that says why, and the showroom's own
                // Reduce Motion sentence; the rest of Motion stays live, as voice motion does.
                accessibilityConsole(
                    "a11y.island.reduce-motion",
                    "Settings' Island motion fold with Reduce Motion enabled",
                    tab: .settings,
                    fixture: .backendReady,
                    adaptation: .reduceMotion,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 2_512),
                    tags: ["island", "steps"],
                    steps: [.press("island.group.motion"), .settle(120)]
                ),
            ]
        }

        // MARK: Menu bar popover

        private static var menuScenes: [UISceneDescriptor] {
            [
                menu("menu.idle", "Menu bar popover at rest", fixture: .populated),
                menu("menu.error", "Menu bar popover after a failed start", fixture: .micDenied),
                menu(
                    "menu.sidecar-error", "Menu bar popover after a wrapped sidecar failure", fixture: .sidecarFailure),
                menu("menu.transcript", "Menu bar popover with the last transcript", fixture: .completedDictation),
                menu(
                    "menu.downloading",
                    "Menu bar popover while the speech model downloads",
                    fixture: .backendDownloading
                ),
            ]
        }

        // MARK: Recording overlay

        /// Every body the showroom can hold comes from `IslandShowroomPose.model()`, the
        /// builders the Settings showroom previews with, so a golden and the showroom can never
        /// disagree about what a pose is. The collar's failed-delivery and error scenes latch
        /// outcomes of their own, whose status sentences their goldens lock.
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
                            model: IslandShowroomPose.speaking.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {}
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.recording",
                    title: "Recording overlay island, speaking",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.speaking.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                // The state a user looks at before every utterance, so it gets a golden of
                // its own rather than sharing one with the speaking body.
                UISceneDescriptor(
                    id: "overlay.island.listening",
                    title: "Recording overlay island, live microphone hearing nothing",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.listening.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                // One unclean delivery at its stable endpoint: the gathered gesture, no
                // control of any kind, and one safe status value.
                UISceneDescriptor(
                    id: "overlay.island.copied",
                    title: "Recording overlay island, copy-only outcome",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.copyOnly.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                // Warming Up feeds the speaking levels to a capture that is not live yet, and
                // `record(_:)` drops every one, so this golden pins both halves of that fix:
                // the body cannot be driven from a warm-up buffer, and it holds the small calm
                // warming lens instead of the listening pose.
                UISceneDescriptor(
                    id: "overlay.island.warmup",
                    title: "Recording overlay island, microphone still warming up",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.warmingUp.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                // The working droplet: short, tall, and disconnected from the voice, pinned
                // to one substep index like every other overlay scene.
                UISceneDescriptor(
                    id: "overlay.island.processing",
                    title: "Recording overlay island, transcribing",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.processing.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                UISceneDescriptor(
                    id: "overlay.island.reduced-motion",
                    title: "Recording overlay island with Reduce Motion enabled",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay", "a11y"],
                    accessibilityAdaptation: .reduceMotion
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.speaking.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            islandOnly: true
                        )
                    )
                },
                // The stock look in the other room a user can choose. The appearance goes
                // straight to the view, exactly as a session's latched look does.
                UISceneDescriptor(
                    id: "overlay.island.overcast",
                    title: "Recording overlay island speaking in the Overcast room",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.speaking.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            island: { overcastIsland },
                            islandOnly: true
                        )
                    )
                },
            ] + lookScenes + collarScenes
        }

        /// Stock in every respect but its room.
        private static let overcastIsland: IslandAppearance = {
            var island = IslandAppearance.stock
            island.room = .spectralWeather
            return island
        }()

        /// Every named look but Stock on the real island, speaking: the raster each look
        /// ships as. Stock's is `overlay.island.recording`. Ids spell the look's raw tag with
        /// dashes, the separator every other scene basename uses.
        private static var lookScenes: [UISceneDescriptor] {
            IslandLook.allCases.filter { $0 != .stock }.map { look in
                UISceneDescriptor(
                    id: "overlay.island.look." + look.rawValue.replacingOccurrences(of: "_", with: "-"),
                    title: "Recording overlay island speaking in the \(look.displayName) look",
                    size: RecordingOverlayLayout.island.canvasRect.size,
                    tags: ["overlay"]
                ) {
                    AnyView(
                        RecordingOverlayView(
                            model: IslandShowroomPose.speaking.model(),
                            onCancel: {},
                            onFinish: {},
                            onDock: {},
                            island: { look.appearance },
                            islandOnly: true
                        )
                    )
                }
            }
        }

        /// The collar around the 16-inch MacBook Pro's camera housing, `.fixtureNotch`: the
        /// island's states on the showroom's model builders, laid along the housing's outline.
        /// `wide` is the same panel at More Space, whose housing spans more points. Canvas alone
        /// like the island scenes; the collar's canvas is its whole panel, hung flush from the
        /// screen's top edge around the housing.
        private static var collarScenes: [UISceneDescriptor] {
            [
                collar(
                    "overlay.notch.recording",
                    "Recording overlay collar around the camera housing, speaking",
                    model: { IslandShowroomPose.speaking.model() }
                ),
                collar(
                    "overlay.notch.listening",
                    "Recording overlay collar, live microphone hearing nothing",
                    model: { IslandShowroomPose.listening.model() }
                ),
                collar(
                    "overlay.notch.warmup",
                    "Recording overlay collar, microphone still warming up",
                    model: { IslandShowroomPose.warmingUp.model() }
                ),
                collar(
                    "overlay.notch.processing",
                    "Recording overlay collar, transcribing",
                    model: { IslandShowroomPose.processing.model() }
                ),
                collar(
                    "overlay.notch.copied",
                    "Recording overlay collar, copy-only outcome",
                    model: { IslandShowroomPose.copyOnly.model() }
                ),
                collar(
                    "overlay.notch.lurch",
                    "Recording overlay collar, failed delivery",
                    model: { outcomeOverlayModel(.insertFailed(reason: "no focused element")) }
                ),
                collar(
                    "overlay.notch.error",
                    "Recording overlay collar, transcription error",
                    model: { outcomeOverlayModel(.error(.inferenceFailed)) }
                ),
                collar(
                    "overlay.notch.reduced-motion",
                    "Recording overlay collar with Reduce Motion enabled",
                    tags: ["a11y"],
                    accessibilityAdaptation: .reduceMotion,
                    model: { IslandShowroomPose.speaking.model() }
                ),
                // Over a full-screen app the band beside the housing is empty black, and the
                // speaking collar turns both fillets and runs out along the ears into it.
                collar(
                    "overlay.notch.fullscreen",
                    "Recording overlay collar over a full-screen app, speaking",
                    model: {
                        let model = IslandShowroomPose.speaking.model()
                        model.update(poseContext: MercuryPoseContext(fullScreen: true))
                        return model
                    }
                ),
                collar(
                    "overlay.notch.wide",
                    "Recording overlay collar around a wider camera housing, speaking",
                    display: .fixtureWideNotch,
                    model: { IslandShowroomPose.speaking.model() }
                ),
                // A look reaches the collar through the same latched appearance as the island:
                // its paint, room lighting, tone and motion law, and its body kit on the
                // collar's terms, edges and height redrawn along the housing's own length.
                // Street Racer changes every one of them at once.
                collar(
                    "overlay.notch.look.street-racer",
                    "Recording overlay collar speaking in the \(IslandLook.streetRacer.displayName) look",
                    island: IslandLook.streetRacer.appearance,
                    model: { IslandShowroomPose.speaking.model() }
                ),
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
            showroomPose: IslandShowroomPose? = nil,
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
                if let showroomPose {
                    return AnyView(
                        UIHarnessShowroomPoseScope(pose: showroomPose) {
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
            adaptation: UIHarnessAccessibilityAdaptation,
            // Nil is the first-launch measure, for the same reason as in `console`.
            size: CGSize? = nil,
            tags: [String] = [],
            steps: [UIStep] = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size ?? consoleSize,
                colorScheme: .dark,
                tags: ["console", "a11y"] + tags,
                steps: steps,
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

        /// The collar around the camera housing of `display`, its canvas alone like the island
        /// scenes. The scene measures the layout's canvas, which for the collar is the whole
        /// panel, and the model carries the layout, so the body, its pose ladder and the status
        /// element's frame all read the collar the panel would lay out on that display. `island`
        /// goes straight to the view, exactly as a session's latched look does.
        private static func collar(
            _ identifier: String,
            _ title: String,
            display: OverlayDisplay = .fixtureNotch,
            island: IslandAppearance = .stock,
            tags: [String] = [],
            accessibilityAdaptation: UIHarnessAccessibilityAdaptation? = nil,
            model makeModel: @escaping @MainActor () -> RecordingOverlayModel
        ) -> UISceneDescriptor {
            let layout = UIFixtures.collarLayout(on: display)
            return UISceneDescriptor(
                id: identifier,
                title: title,
                size: layout.canvasRect.size,
                tags: ["overlay"] + tags,
                accessibilityAdaptation: accessibilityAdaptation
            ) {
                let model = makeModel()
                model.update(layout: layout)
                return AnyView(
                    RecordingOverlayView(
                        model: model,
                        onCancel: {},
                        onFinish: {},
                        onDock: {},
                        island: { island },
                        islandOnly: true
                    )
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

        /// One unclean delivery at its stable endpoint: the outcome's gesture, no control of
        /// any kind, and one safe status value. Only the collar's failed-delivery and error
        /// scenes build one here: their outcomes are not the showroom's, so their goldens lock
        /// status sentences the showroom never shows.
        private static func outcomeOverlayModel(_ state: SessionState) -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(state)
            if let outcome = RecordingOverlayOutcome(state: state) {
                model.present(outcome)
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

    /// Process-wide value seam scoped to the one scene that renders the Settings showroom
    /// holding an outcome. The pose is chosen from an `NSMenu` popup, which an offscreen
    /// window that can never order front cannot open, so the pose is pinned rather than
    /// performed. Building the fixture first lets its standard pins run, which leave the
    /// pose nil, before this scene installs its own.
    private struct UIHarnessShowroomPoseScope: View {
        private let content: AnyView
        private let previous: IslandShowroomPose?

        @MainActor
        init(pose: IslandShowroomPose, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previous = RenderOverrides.islandShowroomPose
            RenderOverrides.islandShowroomPose = pose
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.islandShowroomPose = previous
                }
        }
    }

#endif
