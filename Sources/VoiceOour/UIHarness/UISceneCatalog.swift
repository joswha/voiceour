// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
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
    // Adding coverage is a one-place edit: append a `UIScene` to the matching group
    // array below (`consoleScenes`, `paneScenes`, `menuScenes`, `overlayScenes`,
    // `atomScenes`, `accessibilityScenes`, `systemGlassScenes`), which is all `all()`
    // concatenates. Prefer the area factories over a raw `UIScene(...)` so sizes,
    // tags and appearance stay consistent. Every scene must be reproducible byte for
    // byte, which in practice means:
    //
    //   * take app state from `UIFixtures.coordinator(_:)` — never
    //     `DictationCoordinator.live()`, which spawns the ASR sidecar, taps the
    //     keyboard and opens the microphone;
    //   * never let a scene derive anything from `Date()`, `UUID()`, `.random`,
    //     `NSColor.controlAccentColor`, or the user's Keychain / TCC state (see
    //     `RenderOverrides` for the pins that already exist);
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
        /// captures from the real app, and clears `ConsoleScaffold`'s 1164x560 minimum.
        static let consoleSize = CGSize(
            width: VoiceOourMetrics.Window.defaultWidth,
            height: VoiceOourMetrics.Window.defaultHeight
        )

        /// Console measure for panes taller than a fresh install's window. The
        /// keyed Refinement configurations already push their CONNECTION card past
        /// the 820 pt fold — visible in `console.refinement.configured`, whose
        /// Status row sits at y=824 — and a scene whose whole subject is that row
        /// has to show it. The window is resizable, so this is a geometry a user
        /// reaches by dragging, not one invented for the harness.
        static let tallConsoleSize = CGSize(
            width: VoiceOourMetrics.Window.defaultWidth,
            height: 1_000
        )

        /// `MenuBarExtra` popover measure: matches `MenuView`'s fixed 280 pt
        /// `MenuLayout.popoverWidth`, tall enough for the fullest menu state without clipping.
        static let menuSize = CGSize(width: 280, height: 420)

        /// Ordered so the contact sheet reads top-down like the app does: the
        /// console section by section, then the pieces that live outside it.
        private static var registry: [UISceneDescriptor] {
            consoleScenes
                + paneScenes
                + menuScenes
                + overlayScenes
                + atomScenes
                + accessibilityScenes
                + systemGlassScenes
        }

        static func everything() -> [UIScene] {
            // Covers direct atom/overlay scenes as well as coordinator-backed ones.
            // Portable scenes stay pinned to the painted path; only the explicitly
            // tagged system-glass scenes below release that pin for their lifetime.
            UIFixtures.pinProcessSeams()
            return registry.map { $0.makeScene() }
        }

        static func all(request: UIHarnessRequest) -> [UIScene] {
            everything().filter(request.matches)
        }

        /// Unfiltered catalog access for structural tests and coverage accounting.
        static func all() -> [UIScene] {
            everything()
        }

        // MARK: Console — one per ConsoleSection, plus its notable states

        private static var consoleScenes: [UISceneDescriptor] {
            [
                console(
                    "console.home.populated",
                    "Home dashboard with a full session history",
                    section: .home,
                    fixture: .populated
                ),
                console(
                    "console.home.empty",
                    "Home dashboard on first run",
                    section: .home,
                    fixture: .firstRun,
                    tags: ["empty"]
                ),
                console(
                    "console.home.recording",
                    "Home dashboard while a capture is live",
                    section: .home,
                    fixture: .recording
                ),
                console(
                    "console.sessions.populated",
                    "Sessions list, day groups and transcript detail",
                    section: .sessions,
                    fixture: .populated
                ),
                console(
                    "console.sessions.selection",
                    "Sessions transcript with a selected surface ready to teach",
                    section: .sessions,
                    fixture: .populated,
                    transcriptSelectionSurface: "offscreen renderer"
                ),
                console(
                    "console.sessions.empty",
                    "Sessions with nothing dictated yet",
                    section: .sessions,
                    fixture: .firstRun,
                    tags: ["empty"]
                ),
                console(
                    "console.sessions.search",
                    "Sessions filtered by a typed query",
                    section: .sessions,
                    fixture: .populated,
                    tags: ["steps"],
                    steps: [
                        .type("accessibility", into: "Search transcripts or timestamps"),
                        .settle(120),
                    ]
                ),
                console(
                    "console.voice.default",
                    "Voice pane: hotkey, backend picker and cleanup",
                    section: .voice,
                    fixture: .populated
                ),
                console(
                    "console.voice.restart-required",
                    "Voice pane with a saved backend waiting for restart",
                    section: .voice,
                    fixture: .backendSwitchPending
                ),
                console(
                    "console.glossary.populated",
                    "Glossary table with the bundled canonical terms",
                    section: .glossary,
                    fixture: .populated
                ),
                console(
                    "console.glossary.empty",
                    "Glossary table with every term removed",
                    section: .glossary,
                    fixture: .emptyGlossary,
                    tags: ["empty"]
                ),
                console(
                    "console.refinement.off",
                    "Refinement pane with the refiner switched off",
                    section: .refinement,
                    fixture: .populated
                ),
                console(
                    "console.refinement.configured",
                    "Refinement pane with a provider, model and saved key",
                    section: .refinement,
                    fixture: .refinerConfigured
                ),
                console(
                    "console.refinement.apple",
                    "Refinement pane on Apple's on-device model",
                    section: .refinement,
                    fixture: .refinerAppleOnDevice
                ),
                console(
                    "console.refinement.omp",
                    "Refinement pane on the brokered Oh My Pi sign-in",
                    section: .refinement,
                    fixture: .refinerOmp,
                    size: tallConsoleSize
                ),
                console(
                    "console.refinement.omp-login-failed",
                    "Refinement pane after Oh My Pi sign-in could not start",
                    section: .refinement,
                    fixture: .refinerOmpLoginFailed,
                    size: tallConsoleSize
                ),
                console(
                    "console.refinement.custom",
                    "Refinement pane on a custom endpoint, probe in flight",
                    section: .refinement,
                    fixture: .refinerCustom,
                    size: tallConsoleSize
                ),
                console(
                    "console.refinement.unauthorized",
                    "Refinement pane after the endpoint rejected the key",
                    section: .refinement,
                    fixture: .refinerUnauthorized,
                    size: tallConsoleSize
                ),
                console(
                    "console.refinement.unreachable",
                    "Refinement pane after the probe never got an answer",
                    section: .refinement,
                    fixture: .refinerUnreachable,
                    size: tallConsoleSize
                ),
                console(
                    "console.system.granted",
                    "System readiness with every permission granted",
                    section: .system,
                    fixture: .backendReady
                ),
                console(
                    "console.system.denied",
                    "System readiness with permissions denied",
                    section: .system,
                    fixture: .backendUnavailable
                ),
                console(
                    "console.system.confirm",
                    "System danger zone in its confirm state",
                    section: .system,
                    fixture: .populated,
                    tags: ["steps"],
                    steps: [.press("CLEAR HISTORY"), .settle(120)]
                ),
                console(
                    "console.diagnostics.healthy",
                    "Diagnostics ledger with a ready backend",
                    section: .diagnostics,
                    fixture: .backendReady
                ),
                console(
                    "console.diagnostics.unavailable",
                    "Diagnostics ledger with an unreachable backend",
                    section: .diagnostics,
                    fixture: .backendUnavailable
                ),
            ]
        }

        /// One representative state for every console section on the native macOS 26
        /// material path. These are intentionally separate from the portable scenes:
        /// they have no meaning on a host where the SDK symbols cannot execute.
        private static var systemGlassScenes: [UISceneDescriptor] {
            [
                systemConsole(
                    "console.home.os26",
                    "Home dashboard on system glass",
                    section: .home,
                    fixture: .populated
                ),
                systemConsole(
                    "console.sessions.os26",
                    "Sessions on system glass",
                    section: .sessions,
                    fixture: .populated
                ),
                systemConsole(
                    "console.voice.os26",
                    "Voice settings on system glass",
                    section: .voice,
                    fixture: .populated
                ),
                systemConsole(
                    "console.glossary.os26",
                    "Glossary on system glass",
                    section: .glossary,
                    fixture: .populated
                ),
                systemConsole(
                    "console.refinement.os26",
                    "Configured refinement on system glass",
                    section: .refinement,
                    fixture: .refinerConfigured
                ),
                systemConsole(
                    "console.system.os26",
                    "Granted system access on system glass",
                    section: .system,
                    fixture: .backendReady
                ),
                systemConsole(
                    "console.diagnostics.os26",
                    "Healthy diagnostics on system glass",
                    section: .diagnostics,
                    fixture: .backendReady
                ),
                systemMenu(
                    "menu.idle.os26",
                    "Menu bar popover at rest on system glass",
                    fixture: .populated
                ),
                systemMenu(
                    "menu.error.os26",
                    "Menu bar popover after a failed start on system glass",
                    fixture: .micDenied
                ),
                systemMenu(
                    "menu.transcript.os26",
                    "Menu bar popover with the last transcript on system glass",
                    fixture: .completedDictation
                ),
                systemOverlay(
                    "overlay.panel.recording.os26",
                    "Recording overlay panel, listening on system glass",
                    size: CGSize(width: 260, height: 80)
                ),
                systemOverlay(
                    "overlay.island.recording.os26",
                    "Recording overlay island, listening on system glass",
                    size: CGSize(width: 180, height: 34),
                    islandOnly: true
                ),
            ]
        }

        // MARK: Panes hosted without the console shell

        private static var paneScenes: [UISceneDescriptor] {
            // ConsoleView hardcodes `.environment(\.colorScheme, .dark)`, so a
            // light console scene would be a no-op. Hosting the pane directly is
            // the only way to catch a light-appearance regression.
            [
                pane(
                    "pane.home.light",
                    "Home dashboard forced to the light appearance",
                    colorScheme: .light,
                    tags: ["light"]
                ) {
                    HomePane(coordinator: UIFixtures.coordinator(.populated))
                }
            ]
        }

        // MARK: Accessibility adaptations

        /// Each scene is the named base scene with exactly one accessibility
        /// adaptation enabled. The app-owned seams are necessary because the SDK
        /// environment values are get-only.
        private static var accessibilityScenes: [UISceneDescriptor] {
            [
                accessibilityConsole(
                    "a11y.reduce-transparency",
                    "Home dashboard with Reduce Transparency enabled",
                    section: .home,
                    fixture: .populated,
                    adaptation: .reduceTransparency
                ),
                accessibilityConsole(
                    "a11y.increase-contrast",
                    "Voice pane with Increase Contrast enabled",
                    section: .voice,
                    fixture: .populated,
                    adaptation: .increaseContrast
                ),
                accessibilityConsole(
                    "a11y.differentiate-without-color",
                    "Denied system state with Differentiate Without Color enabled",
                    section: .system,
                    fixture: .backendUnavailable,
                    adaptation: .differentiateWithoutColor
                ),
                accessibilityConsole(
                    "a11y.reduce-motion",
                    "Recording dashboard with Reduce Motion enabled",
                    section: .home,
                    fixture: .recording,
                    adaptation: .reduceMotion
                ),
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
            ]
        }

        // MARK: Component sheets

        private static var atomScenes: [UISceneDescriptor] {
            [
                sheet(
                    "atom.controls",
                    "GlassKit control atoms in every mode",
                    size: CGSize(width: 760, height: 620)
                ) {
                    ControlAtomSheet()
                },
                sheet(
                    "atom.properties",
                    "PropertyKit ledger rows in every mode",
                    // The measure the ledger panes hand their rows, plus the sheet's
                    // own padding: every row is exactly as wide here as it ships.
                    size: CGSize(
                        width: VoiceOourMetrics.Content.form + VoiceOourMetrics.Space.xl * 2,
                        height: 1_080
                    ),
                    tags: ["steps"],
                    // `ConfirmActionRow` owns `didFail`, so the failure line is only
                    // reachable through the state machine that publishes it: fill the
                    // token, confirm, and let the failed sample's `perform` answer
                    // false. Every other state on this sheet is a value.
                    steps: [
                        .type(
                            PropertyAtomSheet.token,
                            into: "\(PropertyAtomSheet.failedIdentifier).confirmation"
                        ),
                        .press("\(PropertyAtomSheet.failedIdentifier).confirm"),
                        .settle(120),
                    ]
                ) {
                    PropertyAtomSheet()
                },
            ]
        }

        // MARK: - Factories

        /// A full console window, at the first-launch measure unless a section is
        /// taller than one. `ConsoleView`'s `onAppear` activation is suppressed
        /// while the activation policy is `.prohibited`, which
        /// `UIHarnessRuntime.prepareProcess()` sets before any scene builds, so the
        /// real shell — left rail, section header, pane — is safe to host.
        private static func console(
            _ identifier: String,
            _ title: String,
            section: ConsoleSection,
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
                                ConsoleView(
                                    coordinator: UIFixtures.coordinator(fixture),
                                    initialSection: section
                                )
                            )
                        }
                    )
                }
                return AnyView(ConsoleView(coordinator: UIFixtures.coordinator(fixture), initialSection: section))
            }
        }

        /// Builds the fixture before releasing the glass seam: coordinator construction
        /// re-pins every process seam, so the override must be installed after it and
        /// before `NSHostingView` evaluates the hierarchy.
        private static func systemConsole(
            _ identifier: String,
            _ title: String,
            section: ConsoleSection,
            fixture: UIFixtures.Kind
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: consoleSize,
                colorScheme: .dark,
                tags: ["console", "os26"]
            ) {
                AnyView(
                    UIHarnessSystemGlassScope {
                        AnyView(
                            ConsoleView(
                                coordinator: UIFixtures.coordinator(fixture),
                                initialSection: section
                            )
                        )
                    }
                )
            }
        }

        /// A full-console accessibility variant. The scene contract installs the
        /// selected adaptation before SwiftUI evaluates the hierarchy and restores
        /// the prior process-wide seams during teardown.
        private static func accessibilityConsole(
            _ identifier: String,
            _ title: String,
            section: ConsoleSection,
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
                AnyView(ConsoleView(coordinator: UIFixtures.coordinator(fixture), initialSection: section))
            }
        }

        /// A single pane hosted without the console shell, on the opaque window ink
        /// the shell would otherwise supply.
        private static func pane<Content: View>(
            _ identifier: String,
            _ title: String,
            colorScheme: ColorScheme = .dark,
            tags: [String] = [],
            steps: [UIStep] = [],
            @ViewBuilder content: @escaping @MainActor () -> Content
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: consoleSize,
                colorScheme: colorScheme,
                tags: ["pane"] + tags,
                steps: steps
            ) {
                AnyView(
                    content()
                        .padding(VoiceOourMetrics.Space.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(backdrop(for: colorScheme))
                )
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

        /// Native-material overlay coverage at both production measures. The model
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

        /// A component sheet: pure-value views with no coordinator behind them. A
        /// sheet carries an interaction script only when the state it has to show is
        /// owned by the component itself and cannot be handed in as a value.
        private static func sheet<Content: View>(
            _ identifier: String,
            _ title: String,
            size: CGSize,
            tags: [String] = [],
            steps: [UIStep] = [],
            @ViewBuilder content: @escaping @MainActor () -> Content
        ) -> UISceneDescriptor {
            UISceneDescriptor(id: identifier, title: title, size: size, tags: ["atom"] + tags, steps: steps) {
                AnyView(
                    content()
                        .padding(VoiceOourMetrics.Space.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(backdrop(for: .dark))
                )
            }
        }

        /// Literal fills, not `NSColor` system colours: a dynamic system colour
        /// resolves against this Mac's accent and appearance settings and would not
        /// port between machines.
        private static func backdrop(for scheme: ColorScheme) -> Color {
            scheme == .dark ? VoiceOourPalette.Ink.void : Color(white: 0.96)
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

    // MARK: - Component sheets

    /// One labelled shelf of related atoms.
    private struct AtomRow<Content: View>: View {
        let title: String
        let content: Content

        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
                Text(title)
                    .font(VoiceOourTypography.eyebrow)
                    .kerning(1.4)
                    .foregroundStyle(VoiceOourPalette.Text.low)

                HStack(alignment: .center, spacing: VoiceOourMetrics.Space.md) {
                    content
                    Spacer(minLength: 0)
                }

                HairlineDivider()
            }
        }
    }

    /// Every `GlassKit` control atom in every mode it ships, on one deterministic
    /// grid. Pure-value views: no coordinator, no app state, nothing to settle.
    private struct ControlAtomSheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.lg) {
                AtomRow("STATUSCHIP") {
                    StatusChip(label: "neutral", mode: .neutral)
                    StatusChip(label: "ok", mode: .ok)
                    StatusChip(label: "warn", mode: .warn)
                    StatusChip(label: "crit", mode: .crit)
                    StatusChip(label: "compact", mode: .ok, size: .compact)
                }

                AtomRow("GLASSBUTTONSTYLE") {
                    Button("GHOST") {}
                        .buttonStyle(GlassButtonStyle(kind: .ghost))
                    Button("PRIMARY") {}
                        .buttonStyle(GlassButtonStyle(kind: .accent))
                    Button("DANGER") {}
                        .buttonStyle(GlassButtonStyle(kind: .danger))
                    Button("DISABLED") {}
                        .buttonStyle(GlassButtonStyle(kind: .accent))
                        .disabled(true)
                }

                AtomRow("PLATEBUTTONSTYLE") {
                    Button("ROW") {}
                        .buttonStyle(PlateButtonStyle(isSelected: false))
                    Button("SELECTED ROW") {}
                        .buttonStyle(PlateButtonStyle(isSelected: true))
                }

                AtomRow("GLASSTOGGLESTYLE") {
                    Toggle("Switched on", isOn: .constant(true))
                        .toggleStyle(GlassToggleStyle())
                    Toggle("Switched off", isOn: .constant(false))
                        .toggleStyle(GlassToggleStyle())
                }

                AtomRow("KEYCAP") {
                    KeyCap("fn")
                    KeyCap("⌘")
                    KeyCap("⌘⇧V")
                    KeyCap("esc")
                }

                AtomRow("ROWICONBUTTON") {
                    RowIconButton(systemName: "doc.on.doc", accessibilityLabel: "Copy sample") {}
                    RowIconButton(systemName: "trash", kind: .danger, accessibilityLabel: "Remove sample") {}
                }

                AtomRow("GLASSTEXTFIELDSTYLE") {
                    TextField("Empty field", text: .constant(""))
                        .textFieldStyle(GlassTextFieldStyle())
                        .frame(width: VoiceOourMetrics.Field.medium)
                    TextField("Filled field", text: .constant("mlx-parakeet"))
                        .textFieldStyle(GlassTextFieldStyle())
                        .frame(width: VoiceOourMetrics.Field.medium)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// Every `PropertyKit` ledger row in every mode, composed the way the System,
    /// Diagnostics and Refinement panes compose them: inside `SettingsSectionBlock`
    /// cards on the shared label/value grid. Hosting the real container is the point
    /// — a ledger row has to publish the same row-bounds anchor `SettingsRow`
    /// publishes or the section's overlay hairlines land between the wrong rows, and
    /// a row rendered on its own can never show that.
    private struct PropertyAtomSheet: View {
        /// The confirm token both armed samples take. The scene's step script types
        /// it, so it cannot be spelled twice.
        static let token = "CLEAR"

        /// Interaction identifiers stay scene-local: `diagnostics.history` and
        /// `refinement.key` belong to the panes, and a sheet that borrowed one would
        /// make a search for that pane's own coverage ambiguous.
        static let failedIdentifier = "atom.confirm.failed"
        private static let armedIdentifier = "atom.confirm.armed"
        private static let collapsedIdentifier = "atom.confirm.collapsed"
        private static let unavailableIdentifier = "atom.confirm.unavailable"

        /// Armed through real state rather than `.constant(true)`: `ConfirmActionRow`
        /// writes this binding false the moment its work succeeds, and a constant
        /// binding would silently swallow the one transition these samples exist to
        /// hold open. Neither sample's `perform` ever succeeds, so both stay armed.
        @State private var isArmed = true
        @State private var isArmedAfterFailure = true

        var body: some View {
            // `ContentCard` fills `maxHeight: .infinity`, so without `fixedSize` each
            // card would stretch to a quarter of the scene instead of to its own
            // content: this sheet has no scroll view to propose an ideal height.
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.lg) {
                propertyRows
                settingsRows
                confirmActionRows
                dependentGroup
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        // MARK: PropertyRow

        /// Every value and accessory shape the panes ask for: a prose value, a
        /// trailing metadata datum with an accessibility override, a machine value
        /// with its copy action, a valueless status row whose caption carries the
        /// failure, and a status row whose remediation is a real action button.
        private var propertyRows: some View {
            SettingsSectionBlock(eyebrow: "PROPERTYROW") {
                PropertyRow("Version", value: UIFixtures.Ledger.version)

                // Prose-only: no value, no rail. The caption takes the value slot
                // on line one instead of stranding the label beside an empty band.
                PropertyRow("On-device", caption: UIFixtures.Ledger.onDeviceProse)

                PropertyRow(
                    "Saved sessions",
                    value: UIFixtures.Ledger.savedSessions,
                    accessories: [.metadata(UIFixtures.Ledger.savedSessionsSize)],
                    accessibilityValue:
                        "\(UIFixtures.Ledger.savedSessions) sessions, \(UIFixtures.Ledger.savedSessionsSize) on disk"
                )

                PropertyRow(
                    "Settings",
                    value: UIFixtures.Ledger.settingsPath,
                    valueStyle: .mono,
                    accessories: [
                        .copy(
                            payload: UIFixtures.Ledger.settingsPath,
                            label: "Copy SETTINGS PATH",
                            identifier: "atom.property.settings.copy"
                        )
                    ]
                )

                PropertyRow(
                    "Health probe",
                    caption: UIFixtures.Ledger.healthFailure,
                    captionColor: VoiceOourPalette.Signal.crimson,
                    accessories: [
                        .status("ERROR", .crit),
                        .copy(
                            payload: UIFixtures.Ledger.healthReport,
                            label: "Copy the backend health report",
                            identifier: "atom.property.health.copy"
                        ),
                    ]
                )

                PropertyRow(
                    "Microphone",
                    caption: UIFixtures.Ledger.microphonePrompt,
                    accessories: [
                        .status("WILL PROMPT", .warn),
                        .action(
                            title: "OPEN SYSTEM SETTINGS…",
                            kind: .ghost,
                            label: "Open Microphone privacy settings",
                            identifier: "atom.property.microphone.settings",
                            isEnabled: true,
                            isInFlight: false,
                            perform: {}
                        ),
                    ]
                )
            }
        }

        // MARK: SettingsRow

        /// The two slots `SettingsRow` grew: a trailing status chip over a footer
        /// stack holding the state readout plus the live "applies next" note (the
        /// System mute row's shape — one explanatory caption per state, with scope
        /// left to the picker that owns it), and a footer with no chip (the
        /// mute-scope row's shape), which is the other half of the overload surface
        /// callers now compile against.
        private var settingsRows: some View {
            SettingsSectionBlock(eyebrow: "SETTINGSROW") {
                SettingsRow(label: "Mute during capture", status: (label: "MUTE ON", mode: .neutral)) {
                    Toggle("Mute system audio while recording", isOn: .constant(true))
                        .toggleStyle(GlassToggleStyle())
                        .fixedSize(horizontal: true, vertical: false)
                } footer: {
                    VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                        CaptionText("System audio will be muted during recording and restored when the session ends.")

                        CaptionText("Applies from the next recording.")
                    }
                }

                SettingsRow(label: "Timeout") {
                    TextField(UIFixtures.Ledger.timeout, text: .constant(UIFixtures.Ledger.timeout))
                        .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                        .frame(width: VoiceOourMetrics.Field.short)
                } footer: {
                    CaptionText("Clamped to 500–30000 ms when the field commits.")
                }
            }
        }

        // MARK: ConfirmActionRow

        /// Every state the row reaches without a pane behind it: collapsed with
        /// nothing to erase, collapsed and available, armed, and armed after a refused
        /// erase. The collapsed pair takes a constant binding because a still life is
        /// all they are; the armed pair owns real state above.
        private var confirmActionRows: some View {
            SettingsSectionBlock(eyebrow: "CONFIRMACTIONROW") {
                confirmRow(
                    identifier: Self.unavailableIdentifier,
                    isAvailable: false,
                    isConfirming: .constant(false),
                    succeeds: true
                )

                confirmRow(
                    identifier: Self.collapsedIdentifier,
                    isAvailable: true,
                    isConfirming: .constant(false),
                    succeeds: true
                )

                confirmRow(
                    identifier: Self.armedIdentifier,
                    isAvailable: true,
                    isConfirming: $isArmed,
                    succeeds: true
                )

                confirmRow(
                    identifier: Self.failedIdentifier,
                    isAvailable: true,
                    isConfirming: $isArmedAfterFailure,
                    succeeds: false
                )
            }
        }

        /// One sample per state, differing only in availability, arming and whether
        /// the work succeeds: the copy is the pane's copy, so a change to the danger
        /// grammar shows up here as a diff rather than as four sheets to update.
        private func confirmRow(
            identifier: String,
            isAvailable: Bool,
            isConfirming: Binding<Bool>,
            succeeds: Bool
        ) -> some View {
            ConfirmActionRow(
                label: "Clear history",
                subject: "Transcript history",
                scope: "Clear local transcript history. Settings and glossary terms are kept.",
                token: Self.token,
                actionTitle: "CLEAR HISTORY",
                inFlightTitle: "CLEARING…",
                failureLabel: "NOT ERASED",
                failureText: UIFixtures.Ledger.historyFailure,
                identifier: identifier,
                isAvailable: isAvailable,
                isConfirming: isConfirming,
                perform: { succeeds }
            )
        }

        // MARK: DependentGroup

        /// The disabled half of the refinement pane's dependent block, which is the
        /// one place the primitives' disabled tone is visible: label, machine value,
        /// chip, caption and field all recede together, and nothing here sets a colour
        /// to make that happen.
        private var dependentGroup: some View {
            DependentGroup(isEnabled: false, label: "Refiner configuration") {
                SettingsSectionBlock(eyebrow: "DEPENDENTGROUP · DISABLED") {
                    PropertyRow("Endpoint", value: UIFixtures.Ledger.endpoint, valueStyle: .mono)

                    SettingsRow(label: "Model", status: (label: "NEEDS KEY", mode: .warn)) {
                        TextField(UIFixtures.Ledger.model, text: .constant(UIFixtures.Ledger.model))
                            .textFieldStyle(GlassTextFieldStyle())
                            .frame(width: VoiceOourMetrics.Field.medium)
                    } footer: {
                        CaptionText("Sent with every refinement request.")
                    }
                }
            }
        }
    }

#endif
