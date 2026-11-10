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
        let accessibilityAdaptations: Set<UIHarnessAccessibilityAdaptation>
        let build: @MainActor () -> AnyView

        init(
            id: String,
            title: String,
            size: CGSize,
            colorScheme: ColorScheme = .dark,
            tags: [String] = [],
            steps: [UIStep] = [],
            accessibilityAdaptations: Set<UIHarnessAccessibilityAdaptation> = [],
            build: @escaping @MainActor () -> AnyView
        ) {
            self.id = id
            self.title = title
            self.size = size
            self.colorScheme = colorScheme
            self.tags = tags
            self.steps = steps
            self.accessibilityAdaptations = accessibilityAdaptations
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
                accessibilityAdaptations: accessibilityAdaptations,
                build: build
            )
        }
    }

    // The curated list of things the offscreen UI harness renders, dumps and lints.
    //
    // Adding a scene is a one-place edit: append a `UIScene` to the matching group
    // array below (`consoleScenes`, `qaScenes`, `lightScenes`, `menuScenes`,
    // `overlayScenes`, `accessibilityScenes`), which is all `all()` concatenates.
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
        /// `MenuLayout.popoverWidth`, tall enough for every ordinary menu state without
        /// clipping. The stress scenes pass their own height.
        static let menuSize = CGSize(width: 280, height: 420)

        /// The console window's minimum, which AppKit will not let a user resize below: the
        /// narrowest and shortest window any console scene may photograph.
        static let minimumSize = CGSize(
            width: VoiceourMetrics.Window.minWidth,
            height: VoiceourMetrics.Window.minHeight
        )

        /// Settings' Island page at a window tall enough to photograph it whole: `height` is a
        /// multiple of 4 that reaches the page's last Position caption without a scroller, so it
        /// depends on which folds the scene opens and on `width`, which the page wraps to. Nil
        /// is the first-launch width, for the reason `console`'s size is optional.
        static func islandPage(_ height: CGFloat, width: CGFloat? = nil) -> CGSize {
            CGSize(width: width ?? VoiceourMetrics.Window.defaultWidth, height: height)
        }

        /// Ordered so the contact sheet reads top-down like the app does: the
        /// console tab by tab, its edge cases and its light twins, then the pieces
        /// that live outside it.
        private static var registry: [UISceneDescriptor] {
            consoleScenes
                + qaScenes
                + lightScenes
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
                // The Glossary opens on All Terms with the first term's page.
                console(
                    "console.glossary.populated",
                    "Glossary's All Terms with the bundled canonical terms",
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
                // A taught and an imported term beside the bundled ones, so the origin
                // treatment only a non-default glossary shows renders in the list.
                console(
                    "console.glossary.mixed",
                    "Glossary's All Terms with a taught term and an imported term",
                    tab: .glossary,
                    fixture: .mixedGlossary
                ),
                // The Yours origin in the sidebar, a plain button the never-key window takes:
                // the list narrowed to the taught and imported terms, the sidebar item selected.
                console(
                    "console.glossary.yours",
                    "Glossary narrowed to the user's own terms",
                    tab: .glossary,
                    fixture: .mixedGlossary,
                    tags: ["steps"],
                    steps: [.press("glossary.origin.yours"), .settle(120)]
                ),
                console(
                    "console.glossary.editing",
                    "Glossary with the bundled kubectl term's page open",
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
                // Add Term from the list bar: the draft page, its fields empty, that a new
                // term is written on.
                console(
                    "console.glossary.draft",
                    "Glossary's draft page for a new term",
                    tab: .glossary,
                    fixture: .populated,
                    tags: ["steps"],
                    steps: [.press("glossary.add-term"), .settle(120)]
                ),
                // Two suggestions pending, so the sidebar offers Suggestions and the tab opens
                // on it with the first suggestion's page: its misheard words, the term they may
                // be, and Accept, Ignore and Reject. No step: the tab chooses this itself.
                console(
                    "console.glossary.suggestions",
                    "Glossary opened on its pending suggestions, the first one's page shown",
                    tab: .glossary,
                    fixture: .glossarySuggestions,
                    tags: ["suggestions"]
                ),
                // The component kit on its own, in the console's composition, so a change to
                // one component shows here before it moves any tab's golden.
                kitGallery("console.kit.gallery", "The component kit in the console's composition"),
                // The gallery in another accent, so a theme change that moves only one accent's
                // colours shows in a golden. The light accents are in `lightScenes`.
                kitGallery(
                    "console.kit.gallery.blue",
                    "The component kit in the blue accent",
                    accent: .blue
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
                    "Timeline with no dictation selected",
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
                    "console.sessions.agent-filtered",
                    "History filtered to one agent session",
                    tab: .history,
                    fixture: .populated,
                    agentSession: UIFixtures.agentSession
                ),
                // The Tern row whose link missed, selected with its Details unfolded: the Agent
                // heading bound rows use, reading why this one is not linked. No seam pins a
                // selection other than the newest row's, and a plain press on the row and on the
                // Details heading is one this window takes.
                console(
                    "console.sessions.unlinked",
                    "History row pasted into Tern whose agent link missed, Details open on the reason",
                    tab: .history,
                    fixture: .populated,
                    tags: ["agent-link", "steps"],
                    steps: [
                        .press(UIFixtures.unlinkedRowText),
                        .settle(120),
                        .press("sessions.detail.details"),
                        .settle(120),
                    ]
                ),
                // A row linked by its words, as Link Earlier Dictations links one, selected the
                // same way: its Details name the session under Agent and say the link came from
                // its words, not from a focused pane.
                console(
                    "console.sessions.evidence",
                    "History row linked to its agent session by its words, Details open on how",
                    tab: .history,
                    fixture: .populated,
                    tags: ["agent-link", "steps"],
                    steps: [
                        .press(UIFixtures.evidenceRowText),
                        .settle(120),
                        .press("sessions.detail.details"),
                        .settle(120),
                    ]
                ),
                // A transcript of one word, "Testing.", pasted into Tern: the newest row, so the
                // Timeline's own first selection. Its island spans the page while its text is a
                // few points wide, so a transcript laid out at any width but the island's shows
                // here as the word broken mid-way and spilling past the island's bottom edge.
                console(
                    "console.sessions.short",
                    "Timeline opened on a one-word transcript pasted into Tern",
                    tab: .history,
                    fixture: .transcriptEdges
                ),
                // A 225-character URL with no space in it, selected by a press on its row by
                // its text: the island must break the token at its own edge and grow to hold
                // every line.
                console(
                    "console.sessions.unbroken",
                    "Timeline transcript of one unbroken URL, wrapped inside its island",
                    tab: .history,
                    fixture: .transcriptEdges,
                    tags: ["steps"],
                    steps: [
                        .press(UIFixtures.unbrokenRowText),
                        .settle(120),
                    ]
                ),
                // The Journal's other lenses. The tab opens on Timeline, and a sidebar press is
                // not one a window that never becomes key can count on, so each scene pins the
                // lens it shows, as the tab bar is driven by a binding rather than a press.
                console(
                    "console.sessions.rewind",
                    "Journal Rewind on the fixture's newest day",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .rewind
                ),
                console(
                    "console.sessions.rewind.search",
                    "Journal Rewind searching every day for a typed query",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .rewind,
                    tags: ["steps"],
                    steps: [
                        .type("accessibility", into: "journal.rewind.search"),
                        .settle(120),
                    ]
                ),
                console(
                    "console.sessions.rewind.empty",
                    "Journal Rewind with nothing dictated yet",
                    tab: .history,
                    fixture: .firstRun,
                    journalLens: .rewind,
                    tags: ["empty"]
                ),
                console(
                    "console.sessions.threads",
                    "Journal Threads listing the fixture's agent sessions by project",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .threads
                ),
                console(
                    "console.sessions.threads.open",
                    "Journal Threads with one agent session's page open",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .threads,
                    journalThread: UIFixtures.agentSession
                ),
                // The same page in a window at the console's minimum width, 800 pt, as a window
                // the user narrowed keeps its size across launches: the sidebar folds to its
                // rail of glyphs and the page's bar, too narrow for its titles, draws its
                // buttons' glyphs alone.
                console(
                    "console.sessions.narrow",
                    "Journal Threads in a narrow window, the sidebar a rail and the page's actions glyphs",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .threads,
                    journalThread: UIFixtures.agentSession,
                    size: CGSize(width: VoiceourMetrics.Window.minWidth, height: VoiceourMetrics.Window.defaultHeight)
                ),
                console(
                    "console.sessions.threads.empty",
                    "Journal Threads with no agent session yet",
                    tab: .history,
                    fixture: .firstRun,
                    journalLens: .threads,
                    tags: ["empty"]
                ),
                // The same empty lens with linking on: the setting is no longer the next step,
                // so the lens names the paste that makes a thread. The fixture's one row is a
                // paste into Tern whose link missed, so no thread exists.
                console(
                    "console.sessions.threads.empty.linking",
                    "Journal Threads with no agent session yet and linking on",
                    tab: .history,
                    fixture: .pastedUnlinked,
                    journalLens: .threads,
                    tags: ["empty", "agent-link"]
                ),
                // The same two lenses over a memory folder that reaches past History: a day
                // only memory holds, and the omp thread with entries older than any History row.
                // The fixture's loader states an agent's recap of that day, so Rewind shows it
                // under "From your agents", below Copy Recap Prompt, without a step.
                console(
                    "console.sessions.rewind.memory",
                    "Journal Rewind on a day only memory holds",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .rewind,
                    journalDay: UIFixtures.rememberedDay,
                    tags: ["memory", "agent-notes"]
                ),
                // The omp thread's page reaches past History's oldest row, and it leads with the
                // omp agent's outcome note under "From the session", which the loader states
                // keyed to the thread, beside Copy Outcome Prompt in the page's bar.
                console(
                    "console.sessions.threads.memory",
                    "Journal Threads with a session page that reaches past History, led by its outcome note",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .threads,
                    journalThread: UIFixtures.agentSession,
                    tags: ["memory", "agent-notes"]
                ),
                // The Notes lens: the remembered fixture's three notes in two day groups,
                // one of them taken in the omp session, and the populated fixture, whose
                // memory is off and holds no note, for the lens with nothing to list.
                console(
                    "console.sessions.notes",
                    "Journal Notes listing every note memory holds, newest day first",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .notes,
                    tags: ["memory", "notes"]
                ),
                console(
                    "console.sessions.notes.empty",
                    "Journal Notes with no note taken yet",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .notes,
                    tags: ["empty", "notes"]
                ),
                // The Topics lens: the remembered fixture's three topics, most entries first,
                // with the largest one's page, the lens's own first selection, showing the agent
                // synthesis the fixture's loader states for that topic; and the populated
                // fixture, whose memory holds no topic. The harness key source holds no key, so
                // no Sorting card shows on any Mac.
                console(
                    "console.sessions.topics",
                    "Journal Topics listing the user's topics, the largest one's page selected",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .topics,
                    tags: ["memory", "topics", "agent-notes"]
                ),
                console(
                    "console.sessions.topics.empty",
                    "Journal Topics with no topic made yet",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .topics,
                    tags: ["empty", "topics"]
                ),
                // New Topic pressed beside existing topics, and a name typed: the draft row in
                // the list and its page, with Add Topic enabled because the name is not blank.
                console(
                    "console.sessions.topics.draft",
                    "Journal Topics with a new topic's draft named and not yet added",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .topics,
                    tags: ["memory", "topics", "steps"],
                    steps: [
                        .press("journal.topics.new"),
                        .settle(120),
                        .type("Release notes", into: "journal.topics.new.name"),
                        .settle(120),
                    ]
                ),
                // Rewind on the remembered fixture's labelled day, whose four confident
                // highlight kinds lead the day as Highlights and mark their rows.
                console(
                    "console.sessions.rewind.highlights",
                    "Journal Rewind on a day the sorting model labelled, led by its highlights",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .rewind,
                    journalDay: UIFixtures.labelledDay,
                    tags: ["memory", "highlights"]
                ),
                // Settings as it opens, on the Dictation page, which it opens on every time:
                // the hotkey, auto-stop and its duration, and cleanup.
                console(
                    "console.settings.granted",
                    "Settings as it opens, on the Dictation page",
                    tab: .settings,
                    fixture: .backendReady
                ),
                // The Appearance page on a fresh install: System and Green selected, and the
                // preview drawn in the scene's own appearance.
                console(
                    "console.settings.appearance",
                    "Settings' Appearance page with System and Green selected",
                    tab: .settings,
                    fixture: .backendReady,
                    tags: ["appearance", "steps"],
                    steps: settingsPage("appearance")
                ),
                // The microphone picker on the connected Yeti, and the mute and cue switches.
                console(
                    "console.settings.audio",
                    "Settings' Audio page with a connected microphone selected",
                    tab: .settings,
                    fixture: .backendReady,
                    tags: ["steps"],
                    steps: settingsPage("audio")
                ),
                // The saved microphone unplugged and an output device with no mute: the NOT
                // CONNECTED and UNAVAILABLE marks, their captions and the Audio item's caution.
                console(
                    "console.settings.audio.unavailable",
                    "Settings' Audio page with the saved microphone missing and mute unavailable",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    tags: ["steps"],
                    steps: settingsPage("audio")
                ),
                // Granite named as the one model, with its single artifact ready.
                console(
                    "console.settings.model",
                    "Settings' Model page with Granite ready",
                    tab: .settings,
                    fixture: .backendReady,
                    tags: ["steps"],
                    steps: settingsPage("model")
                ),
                // Every readiness mark good: the backend ready and every permission granted.
                console(
                    "console.settings.readiness",
                    "Settings' Readiness page with the model ready and every permission granted",
                    tab: .settings,
                    fixture: .backendReady,
                    tags: ["steps"],
                    steps: settingsPage("readiness")
                ),
                // Every readiness mark bad: the backend unreachable and the microphone denied.
                console(
                    "console.settings.denied",
                    "Settings' Readiness page with the backend unreachable and permissions denied",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    tags: ["steps"],
                    steps: settingsPage("readiness")
                ),
                // Capture and insertion both denied, each beside the button that opens its
                // System Settings pane.
                console(
                    "console.settings.capture.denied",
                    "Settings' Capture page with capture and insertion denied",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    tags: ["steps"],
                    steps: settingsPage("capture")
                ),
                // The model part-way through its 0.51 GB download, with the progress bar.
                console(
                    "console.settings.downloading",
                    "Settings' Readiness page while the speech model downloads",
                    tab: .settings,
                    fixture: .backendDownloading,
                    tags: ["steps"],
                    steps: settingsPage("readiness")
                ),
                // Agent-session linking on, so the page offers Link Earlier Dictations beside
                // Copy Diagnostics.
                console(
                    "console.settings.privacy",
                    "Settings' Privacy page with agent-session linking on",
                    tab: .settings,
                    fixture: .linkingOn,
                    tags: ["agent-link", "steps"],
                    steps: settingsPage("privacy")
                ),
                // Memory on, so its copy buttons are enabled, and the sorting key "Not set"
                // with the sorting switch disabled, as on every harness Mac.
                console(
                    "console.settings.memory",
                    "Settings' Memory page with memory on",
                    tab: .settings,
                    fixture: .remembered,
                    tags: ["memory", "steps"],
                    steps: settingsPage("memory")
                ),
                // The arm buttons that clear History, memory and learned vocabulary, unarmed,
                // over the populated History.
                console(
                    "console.settings.danger",
                    "Settings' Danger page over a populated history",
                    tab: .settings,
                    fixture: .populated,
                    tags: ["steps"],
                    steps: settingsPage("danger")
                ),
                // Every Garage control, caption, readout and spoken value at stock, the look
                // gallery with Stock selected, and the showroom's raster.
                console(
                    "console.settings.island.tuning",
                    "Settings' Island page with all four folds open at the stock look",
                    tab: .settings,
                    fixture: .backendReady,
                    size: islandPage(3_048),
                    tags: ["island", "steps"],
                    steps: settingsPage("island") + islandFoldSteps
                ),
                // The rows only a non-stock look shows or enables: the film slider, the
                // underglow's color and strength, the Overcast radio, signed and kelvin
                // readouts away from stock, and the ARCTIC PLATINUM mark and selected card.
                console(
                    "console.settings.island.look",
                    "Settings' Island page with all four folds open on the Arctic Platinum look",
                    tab: .settings,
                    fixture: .islandLook,
                    size: islandPage(3_104),
                    tags: ["island", "steps"],
                    steps: settingsPage("island") + islandFoldSteps
                ),
                // CUSTOM, a look gallery with no card selected, and Dock Island live beside the
                // free placement's caption, the folds shut as the page first shows them.
                console(
                    "console.settings.island.custom",
                    "Settings' Island page tuned off a look, with a free island placement",
                    tab: .settings,
                    fixture: .islandCustom,
                    size: islandPage(1_300),
                    tags: ["island", "steps"],
                    steps: settingsPage("island")
                ),
                // An outcome pose, which only this scene can show: Play Again present and
                // enabled, and the showroom drawn at the gesture's pinned endpoint, the same
                // frame semantics as `overlay.island.copied`. Play Again itself is never
                // pressed here: its 1.2 s hold is wall-clock. The pose is pinned; the page is
                // pressed, as every other Island scene's is.
                console(
                    "console.settings.island.outcome",
                    "Settings' Island page, its showroom holding the delivery-failed gesture",
                    tab: .settings,
                    fixture: .backendReady,
                    showroomPose: .deliveryFailed,
                    tags: ["island", "steps"],
                    steps: settingsPage("island")
                ),
            ]
        }

        /// Opens one Settings page. Settings opens on Dictation and never remembers the page,
        /// so a scene of any other page presses its sidebar item, a plain button the never-key
        /// window takes; the settle lets the chosen page's controls replace Dictation's before
        /// the next step or the capture. `section` is the page's raw value.
        private static func settingsPage(_ section: String) -> [UIStep] {
            [.press("settings.section.\(section)"), .settle(120)]
        }

        /// Opens all four Garage folds on the Island page. Each press reaches one fold's
        /// disclosure button through its identifier, shut on the page's first appearance;
        /// the settle lets the last fold's rows finish inserting before the capture.
        private static let islandFoldSteps: [UIStep] = [
            .press("island.group.material"),
            .press("island.group.lighting"),
            .press("island.group.body"),
            .press("island.group.motion"),
            .settle(120),
        ]

        // MARK: QA — the edge cases every tab and the menu must hold

        /// The stress, minimal and narrow states a reader's own data and window reach, on the
        /// QA fixtures. Ids keep their tab's prefix so each counts as that tab's golden. Every
        /// console scene here is at least the window's 800 × 560 minimum.
        private static var qaScenes: [UISceneDescriptor] {
            [
                // The Timeline on 500 rows: its first selection the Tern paste bound to the
                // 96-character unbroken thread title and never sent, beside rows of one word,
                // 400 and 10,000 words, an unbroken token, Japanese, Arabic and emoji, a
                // 60-character app name, and a day group of 300.
                console(
                    "console.sessions.stress",
                    "Timeline on 500 rows, opened on a never-sent paste into a thread with an unbroken title",
                    tab: .history,
                    fixture: .stressHistory,
                    tags: ["qa", "stress"]
                ),
                // The same at the window's minimum: the sidebar a rail, the page at its
                // narrowest and only 560 pt of the list.
                console(
                    "console.sessions.stress.narrow",
                    "Timeline on 500 rows in the minimum window",
                    tab: .history,
                    fixture: .stressHistory,
                    size: minimumSize,
                    tags: ["qa", "stress", "narrow"]
                ),
                // The day only memory holds, with 1,000 dictations across twelve apps: the
                // four-digit entry count, the twelve-app Where tile and a page of 1,000 rows.
                console(
                    "console.sessions.rewind.stress",
                    "Journal Rewind on a day of 1,000 dictations",
                    tab: .history,
                    fixture: .stressHistory,
                    journalLens: .rewind,
                    journalDay: UIFixtures.stressBusyDay,
                    tags: ["qa", "stress", "memory"]
                ),
                // The largest topic, the lens's own first selection: a 70-character name beside
                // its 70-character sibling, a 120-character summary and 600 filed entries.
                console(
                    "console.sessions.topics.stress",
                    "Journal Topics opened on a long-named topic with 600 entries",
                    tab: .history,
                    fixture: .stressMemory,
                    journalLens: .topics,
                    tags: ["qa", "stress", "memory", "topics"]
                ),
                // The newest note, the lens's own first selection, is 20,000 characters long;
                // a one-word note sits in the list below it.
                console(
                    "console.sessions.notes.stress",
                    "Journal Notes opened on a 20,000-character note",
                    tab: .history,
                    fixture: .stressMemory,
                    journalLens: .notes,
                    tags: ["qa", "stress", "memory", "notes"]
                ),
                // Every Home figure past its tile's measure, at `console.home.full-page`'s
                // height so the activity grid, its 30 weeks and the forty apps' top five all show.
                console(
                    "console.home.stress",
                    "Home with seven-digit figures, a 12345-hour total and forty long app names",
                    tab: .home,
                    fixture: .stressStats,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: 1_080),
                    tags: ["qa", "stress"]
                ),
                // The smallest figures: one dictation, one word, one app, a one-day streak.
                console(
                    "console.home.minimal",
                    "Home with one dictation of one word",
                    tab: .home,
                    fixture: .minimalStats,
                    tags: ["qa"]
                ),
                // The stress figures at the minimum width, tall enough for the whole page:
                // the greeting, the stat grid and the activity grid at their narrowest.
                console(
                    "console.home.narrow",
                    "Home's whole page with the stress figures at the minimum width",
                    tab: .home,
                    fixture: .stressStats,
                    size: CGSize(width: VoiceourMetrics.Window.minWidth, height: 940),
                    tags: ["qa", "stress", "narrow"]
                ),
                // 480 terms narrowed by a search to the one whose canonical is 80 unbroken
                // characters, and its page with 40 spoken forms. The press needs the search:
                // the list is lazy, and the term sorts too far down to be built unsearched.
                console(
                    "console.glossary.stress",
                    "Glossary of 480 terms open on an 80-character term with 40 spoken forms",
                    tab: .glossary,
                    fixture: .stressGlossary,
                    tags: ["qa", "stress", "steps"],
                    steps: [
                        .type("selectable", into: "glossary.search.field"),
                        .settle(120),
                        .press("glossary.term.\(UIFixtures.stressLongTermID)"),
                        .settle(120),
                    ]
                ),
                // A 60-character query that matches nothing: the no-matches state and its
                // actions in the list column, the query held in the field.
                console(
                    "console.glossary.nomatch",
                    "Glossary searched for a 60-character query that matches no term",
                    tab: .glossary,
                    fixture: .stressGlossary,
                    tags: ["qa", "stress", "steps"],
                    steps: [.type(UIFixtures.stressGlossaryQuery, into: "glossary.search.field"), .settle(120)]
                ),
                // Every readiness mark bad at the minimum width: each row's title, mark and
                // remediation sharing a page at its narrowest.
                console(
                    "console.settings.readiness.narrow",
                    "Settings' Readiness page denied at the minimum width",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    size: CGSize(width: VoiceourMetrics.Window.minWidth, height: VoiceourMetrics.Window.defaultHeight),
                    tags: ["qa", "narrow", "steps"],
                    steps: settingsPage("readiness")
                ),
                // A 70-character microphone that is not connected and an output with no mute:
                // the picker, both marks and both captions at their longest.
                console(
                    "console.settings.audio.stress",
                    "Settings' Audio page with a 70-character microphone missing and mute unavailable",
                    tab: .settings,
                    fixture: .stressSettings,
                    tags: ["qa", "stress", "steps"],
                    steps: settingsPage("audio")
                ),
                // The Island page with all four folds open at the minimum width: the showroom,
                // the look gallery and the slider rows at their narrowest.
                console(
                    "console.settings.island.narrow",
                    "Settings' Island page with all four folds open at the minimum width",
                    tab: .settings,
                    fixture: .backendReady,
                    size: islandPage(3_048, width: VoiceourMetrics.Window.minWidth),
                    tags: ["qa", "island", "narrow", "steps"],
                    steps: settingsPage("island") + islandFoldSteps
                ),
                // The window at its minimum height: Settings' sidebar and its pages' first
                // rows in 560 pt.
                console(
                    "console.settings.short",
                    "Settings as it opens in a window at the minimum height",
                    tab: .settings,
                    fixture: .backendReady,
                    size: CGSize(width: VoiceourMetrics.Window.defaultWidth, height: VoiceourMetrics.Window.minHeight),
                    tags: ["qa", "short"]
                ),
                // A capture failure with a 300-character cause, system audio muted and a
                // 3,000-character last transcript: the status row's pills, the headline and the
                // transcript well at their longest at once, 20 pt taller than `menuSize`.
                menu(
                    "menu.stress.failure",
                    "Menu bar popover after a capture failure with a long cause, audio muted",
                    fixture: .stressMenu,
                    size: CGSize(width: menuSize.width, height: 440),
                    tags: ["qa", "stress"]
                ),
                // A paste of one unbroken 200-character token into an app with a 60-character
                // name: the well's three lines and the report's detail line.
                menu(
                    "menu.stress.transcript",
                    "Menu bar popover after pasting one unbroken token into a long-named app",
                    fixture: .stressMenuTranscript,
                    tags: ["qa", "stress"]
                ),
            ]
        }

        // MARK: Light twins

        /// Fresh installs follow the system's appearance, and a fixture keeps System, so these
        /// scenes render the same fixtures as their dark twins in a light window: one per
        /// surface a light reader meets first, so a light-only regression shows in a golden.
        /// Each id is its dark twin's with `.light` appended.
        private static var lightScenes: [UISceneDescriptor] {
            [
                console(
                    "console.home.populated.light",
                    "Home lifetime stats, streaks and the activity grid, light",
                    tab: .home,
                    fixture: .populated,
                    colorScheme: .light,
                    tags: ["light"]
                ),
                console(
                    "console.home.first-run.ready.light",
                    "Home's first-run card with the model ready and no permission answered, light",
                    tab: .home,
                    fixture: .firstRunReady,
                    colorScheme: .light,
                    tags: ["light", "first-run"]
                ),
                console(
                    "console.sessions.populated.light",
                    "History list, day groups and transcript detail, light",
                    tab: .history,
                    fixture: .populated,
                    colorScheme: .light,
                    tags: ["light"]
                ),
                console(
                    "console.sessions.rewind.light",
                    "Journal Rewind on the fixture's newest day, light",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .rewind,
                    colorScheme: .light,
                    tags: ["light"]
                ),
                console(
                    "console.sessions.threads.open.light",
                    "Journal Threads with one agent session's page open, light",
                    tab: .history,
                    fixture: .populated,
                    journalLens: .threads,
                    journalThread: UIFixtures.agentSession,
                    colorScheme: .light,
                    tags: ["light"]
                ),
                console(
                    "console.sessions.topics.light",
                    "Journal Topics listing the user's topics, the largest one's page selected, light",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .topics,
                    colorScheme: .light,
                    tags: ["light", "memory", "topics", "agent-notes"]
                ),
                console(
                    "console.sessions.notes.light",
                    "Journal Notes listing every note memory holds, light",
                    tab: .history,
                    fixture: .remembered,
                    journalLens: .notes,
                    colorScheme: .light,
                    tags: ["light", "memory", "notes"]
                ),
                console(
                    "console.glossary.editing.light",
                    "Glossary with the bundled kubectl term's page open, light",
                    tab: .glossary,
                    fixture: .mixedGlossary,
                    colorScheme: .light,
                    tags: ["light", "steps"],
                    steps: [.press("glossary.term.kubectl")]
                ),
                console(
                    "console.glossary.suggestions.light",
                    "Glossary opened on its pending suggestions, light",
                    tab: .glossary,
                    fixture: .glossarySuggestions,
                    colorScheme: .light,
                    tags: ["light", "suggestions"]
                ),
                console(
                    "console.settings.granted.light",
                    "Settings as it opens, on the Dictation page, light",
                    tab: .settings,
                    fixture: .backendReady,
                    colorScheme: .light,
                    tags: ["light"]
                ),
                console(
                    "console.settings.denied.light",
                    "Settings' Readiness page with the backend unreachable and permissions denied, light",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    colorScheme: .light,
                    tags: ["light", "steps"],
                    steps: settingsPage("readiness")
                ),
                console(
                    "console.settings.appearance.light",
                    "Settings' Appearance page with System and Green selected, light",
                    tab: .settings,
                    fixture: .backendReady,
                    colorScheme: .light,
                    tags: ["light", "appearance", "steps"],
                    steps: settingsPage("appearance")
                ),
                // As tall as its dark twin: the same page and folds.
                console(
                    "console.settings.island.look.light",
                    "Settings' Island page with all four folds open on the Arctic Platinum look, light",
                    tab: .settings,
                    fixture: .islandLook,
                    size: islandPage(3_104),
                    colorScheme: .light,
                    tags: ["light", "island", "steps"],
                    steps: settingsPage("island") + islandFoldSteps
                ),
                kitGallery(
                    "console.kit.gallery.light",
                    "The component kit in the console's composition, light",
                    colorScheme: .light
                ),
                // Three more accents in the light, where a pale accent is hardest to keep
                // legible: yellow, orange and the hueless graphite.
                kitGallery(
                    "console.kit.gallery.light.yellow",
                    "The component kit in the yellow accent, light",
                    colorScheme: .light,
                    accent: .yellow
                ),
                kitGallery(
                    "console.kit.gallery.light.orange",
                    "The component kit in the orange accent, light",
                    colorScheme: .light,
                    accent: .orange
                ),
                kitGallery(
                    "console.kit.gallery.light.graphite",
                    "The component kit in the graphite accent, light",
                    colorScheme: .light,
                    accent: .graphite
                ),
                menu(
                    "menu.idle.light", "Menu bar popover at rest, light", fixture: .populated, colorScheme: .light),
                menu(
                    "menu.transcript.light",
                    "Menu bar popover with the last transcript, light",
                    fixture: .completedDictation,
                    colorScheme: .light
                ),
                menu(
                    "menu.error.light",
                    "Menu bar popover after a failed start, light",
                    fixture: .micDenied,
                    colorScheme: .light
                ),
                menu(
                    "menu.downloading.light",
                    "Menu bar popover while the speech model downloads, light",
                    fixture: .backendDownloading,
                    colorScheme: .light
                ),
            ]
        }

        // MARK: Accessibility adaptations

        /// Each scene is a native console tab or the kit with accessibility adaptations
        /// enabled: one at a time in the dark, one each in the light, and one pair at once.
        /// The app-owned seams are necessary because the SDK environment values are get-only.
        private static var accessibilityScenes: [UISceneDescriptor] {
            [
                accessibilityConsole(
                    "a11y.reduce-transparency",
                    "History transcript with Reduce Transparency enabled",
                    tab: .history,
                    fixture: .populated,
                    adaptations: [.reduceTransparency]
                ),
                kitGallery(
                    "a11y.kit.reduce-transparency",
                    "The component kit with Reduce Transparency enabled",
                    adaptations: [.reduceTransparency]
                ),
                // Settings as it opens, on the Dictation page, with rims and text escalated.
                accessibilityConsole(
                    "a11y.increase-contrast",
                    "Settings' Dictation page with Increase Contrast enabled",
                    tab: .settings,
                    fixture: .populated,
                    adaptations: [.increaseContrast]
                ),
                // Every readiness mark bad, so each carries the symbol that says so without
                // its colour.
                accessibilityConsole(
                    "a11y.differentiate-without-color",
                    "Settings' Readiness page denied, with Differentiate Without Color enabled",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    adaptations: [.differentiateWithoutColor],
                    tags: ["steps"],
                    steps: settingsPage("readiness")
                ),
                accessibilityConsole(
                    "a11y.home.differentiate",
                    "Home activity grid with Differentiate Without Color enabled",
                    tab: .home,
                    fixture: .populated,
                    adaptations: [.differentiateWithoutColor]
                ),
                accessibilityConsole(
                    "a11y.home.reduce-transparency",
                    "Home islands with Reduce Transparency enabled",
                    tab: .home,
                    fixture: .populated,
                    adaptations: [.reduceTransparency]
                ),
                // Brightness and Contrast disabled beside the caption that says why, and the
                // showroom drawn at the accessible tone the island itself will use.
                accessibilityConsole(
                    "a11y.island.increase-contrast",
                    "Settings' Island page, lighting fold open, with Increase Contrast enabled",
                    tab: .settings,
                    fixture: .backendReady,
                    adaptations: [.increaseContrast],
                    size: islandPage(1_856),
                    tags: ["island", "steps"],
                    steps: settingsPage("island") + [.press("island.group.lighting"), .settle(120)]
                ),
                // Shimmer disabled beside the caption that says why, and the showroom's own
                // Reduce Motion sentence; the rest of Motion stays live, as voice motion does.
                accessibilityConsole(
                    "a11y.island.reduce-motion",
                    "Settings' Island page, motion fold open, with Reduce Motion enabled",
                    tab: .settings,
                    fixture: .backendReady,
                    adaptations: [.reduceMotion],
                    size: islandPage(1_924),
                    tags: ["island", "steps"],
                    steps: settingsPage("island") + [.press("island.group.motion"), .settle(120)]
                ),
                // Every readiness mark bad in the light, with rims and text escalated: Increase
                // Contrast where the light theme's quietest text sits closest to its ground.
                accessibilityConsole(
                    "a11y.light.increase-contrast",
                    "Settings' Readiness page denied, light, with Increase Contrast enabled",
                    tab: .settings,
                    fixture: .backendUnavailable,
                    adaptations: [.increaseContrast],
                    colorScheme: .light,
                    tags: ["light", "steps"],
                    steps: settingsPage("readiness")
                ),
                // The Timeline in the light with every surface opaque.
                accessibilityConsole(
                    "a11y.light.reduce-transparency",
                    "History transcript, light, with Reduce Transparency enabled",
                    tab: .history,
                    fixture: .populated,
                    adaptations: [.reduceTransparency],
                    colorScheme: .light,
                    tags: ["light"]
                ),
                // Two adaptations at once on the stress Timeline, whose newest row carries the
                // most marks a row can: each mark escalated and carrying its symbol together.
                accessibilityConsole(
                    "a11y.combined",
                    "Stress Timeline with Increase Contrast and Differentiate Without Color enabled",
                    tab: .history,
                    fixture: .stressHistory,
                    adaptations: [.increaseContrast, .differentiateWithoutColor],
                    tags: ["qa", "stress"]
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
                // A paste into Tern with binding on: the report's link line names the thread
                // the row is bound to, or says why the row is not linked.
                menu(
                    "menu.pasted.linked",
                    "Menu bar popover after a paste into Tern linked to its agent thread",
                    fixture: .pastedLinked
                ),
                menu(
                    "menu.pasted.unlinked",
                    "Menu bar popover after a paste into Tern whose agent link missed",
                    fixture: .pastedUnlinked
                ),
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
                    accessibilityAdaptations: [.reduceMotion]
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
                    accessibilityAdaptations: [.reduceMotion],
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

        /// A full native console window, at the app's first-launch measure, dark unless the
        /// scene is a light twin. Fixtures keep the System appearance, so the window's colour
        /// scheme is what the console resolves. `ConsoleWindowView` suppresses activation
        /// while the harness keeps the process policy `.prohibited`, so hosting it can never
        /// take focus.
        private static func console(
            _ identifier: String,
            _ title: String,
            tab: ConsoleTab,
            fixture: UIFixtures.Kind,
            transcriptSelectionSurface: String? = nil,
            deselected: Bool = false,
            appFilter: String? = nil,
            agentSession: AgentSessionKey? = nil,
            journalLens: JournalLens? = nil,
            journalDay: Date? = nil,
            journalThread: AgentSessionKey? = nil,
            teachingSurface: String? = nil,
            showroomPose: IslandShowroomPose? = nil,
            // Optional rather than `= consoleSize`: a default argument expression is
            // evaluated outside this enum's main-actor context, so it may not read a
            // main-actor static. Nil is the first-launch measure, resolved below.
            size: CGSize? = nil,
            colorScheme: ColorScheme = .dark,
            tags: [String] = [],
            steps: [UIStep] = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size ?? consoleSize,
                colorScheme: colorScheme,
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
                if let agentSession {
                    return AnyView(
                        UIHarnessAgentFilteredHistoryScope(key: agentSession) {
                            AnyView(
                                ConsoleWindowView(
                                    coordinator: UIFixtures.coordinator(fixture),
                                    initialTab: tab
                                )
                            )
                        }
                    )
                }
                if journalLens != nil || journalDay != nil || journalThread != nil {
                    return AnyView(
                        UIHarnessJournalScope(lens: journalLens, day: journalDay, thread: journalThread) {
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
        /// selected adaptations before SwiftUI evaluates the hierarchy and restores
        /// the prior process-wide seams during teardown.
        private static func accessibilityConsole(
            _ identifier: String,
            _ title: String,
            tab: ConsoleTab,
            fixture: UIFixtures.Kind,
            adaptations: Set<UIHarnessAccessibilityAdaptation>,
            colorScheme: ColorScheme = .dark,
            // Nil is the first-launch measure, for the same reason as in `console`.
            size: CGSize? = nil,
            tags: [String] = [],
            steps: [UIStep] = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size ?? consoleSize,
                colorScheme: colorScheme,
                tags: ["console", "a11y"] + tags,
                steps: steps,
                accessibilityAdaptations: adaptations
            ) {
                AnyView(ConsoleWindowView(coordinator: UIFixtures.coordinator(fixture), initialTab: tab))
            }
        }

        /// The component kit's gallery at the console's measure, on `Kit.Screen`, in the theme
        /// `colorScheme` and `accent` resolve.
        private static func kitGallery(
            _ identifier: String,
            _ title: String,
            colorScheme: ColorScheme = .dark,
            accent: ConsoleAccent = .green,
            adaptations: Set<UIHarnessAccessibilityAdaptation> = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: consoleSize,
                colorScheme: colorScheme,
                tags: adaptations.isEmpty ? ["console", "kit"] : ["console", "kit", "a11y"],
                accessibilityAdaptations: adaptations
            ) {
                AnyView(KitGallery(accent: accent))
            }
        }

        /// The menu popover at its fixed width over the theme's ground. `size` is nil for
        /// `menuSize`, for the reason `console`'s is optional; a stress scene passes the height
        /// its content needs.
        private static func menu(
            _ identifier: String,
            _ title: String,
            fixture: UIFixtures.Kind,
            colorScheme: ColorScheme = .dark,
            size: CGSize? = nil,
            tags: [String] = []
        ) -> UISceneDescriptor {
            UISceneDescriptor(
                id: identifier,
                title: title,
                size: size ?? menuSize,
                colorScheme: colorScheme,
                tags: ["menu"] + tags
            ) {
                AnyView(
                    MenuView(coordinator: UIFixtures.coordinator(fixture))
                        .frame(width: menuSize.width, alignment: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(backdrop(for: colorScheme))
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
            accessibilityAdaptations: Set<UIHarnessAccessibilityAdaptation> = [],
            model makeModel: @escaping @MainActor () -> RecordingOverlayModel
        ) -> UISceneDescriptor {
            let layout = UIFixtures.collarLayout(on: display)
            return UISceneDescriptor(
                id: identifier,
                title: title,
                size: layout.canvasRect.size,
                tags: ["overlay"] + tags,
                accessibilityAdaptations: accessibilityAdaptations
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

        /// The green theme's ground for `scheme`, from the generator, not an `NSColor` system
        /// colour: a dynamic system colour resolves against this Mac's accent and appearance
        /// settings and would not port between machines.
        private static func backdrop(for scheme: ColorScheme) -> Color {
            Theme.resolve(scheme: scheme, accent: .green, increasedContrast: false).ground
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

    /// Process-wide value seam scoped to the one scene that renders History
    /// narrowed to a single agent session. The filter is engaged from a row's
    /// context menu, an `NSMenu` an offscreen window cannot open, so the filtered
    /// state is pinned rather than performed.
    private struct UIHarnessAgentFilteredHistoryScope: View {
        private let content: AnyView
        private let previous: AgentSessionKey?

        @MainActor
        init(key: AgentSessionKey, build: @escaping @MainActor () -> AnyView) {
            content = build()
            previous = RenderOverrides.historyInitialAgentSession
            RenderOverrides.historyInitialAgentSession = key
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.historyInitialAgentSession = previous
                }
        }
    }

    /// Process-wide value seams scoped to the scenes and flows that open the Journal on
    /// another lens than Timeline. The lens is chosen in the sidebar, whose press a window
    /// that never becomes key cannot be relied on to take, so the lens is pinned rather
    /// than pressed, as the tab bar is driven by a binding. Rewind's day and the selected
    /// thread are each a click that a scene which only renders cannot make, so they are
    /// pinned beside it. The three describe one opening state and combine with no other
    /// seam, so one scope sets all three, nil included, and restores all three. Internal
    /// rather than private because the flow runner wraps a console host in it too.
    struct UIHarnessJournalScope: View {
        private let content: AnyView
        private let previousLens: JournalLens?
        private let previousDay: Date?
        private let previousThread: AgentSessionKey?

        @MainActor
        init(
            lens: JournalLens?,
            day: Date? = nil,
            thread: AgentSessionKey? = nil,
            build: @escaping @MainActor () -> AnyView
        ) {
            content = build()
            previousLens = RenderOverrides.journalInitialLens
            previousDay = RenderOverrides.journalInitialDay
            previousThread = RenderOverrides.journalInitialThread
            RenderOverrides.journalInitialLens = lens
            RenderOverrides.journalInitialDay = day
            RenderOverrides.journalInitialThread = thread
        }

        var body: some View {
            content
                .onDisappear {
                    RenderOverrides.journalInitialLens = previousLens
                    RenderOverrides.journalInitialDay = previousDay
                    RenderOverrides.journalInitialThread = previousThread
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
