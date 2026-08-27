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

    import SwiftUI
    import VoiceCore

    @MainActor
    enum UIFlowCatalog {
        private static let dictatedText =
            "The offscreen harness renders every console pane without stealing focus."
        private static let dictatedRawText =
            "The offscreen harness renders renders every console pane without stealing focus."
        private static let pasteBundleID = "com.example.Writer"
        private static let terminalBundleID = "com.apple.Terminal"
        private static let glossaryTerm = "FlowTerm"
        private static let glossaryForms = "flow form, other form"
        private static let noMatchQuery = "definitely-not-a-transcript"

        /// Queries are exact. Every action and single-node expectation rejects zero
        /// or multiple matches rather than silently retargeting a nearby control.
        private enum Selector {
            static let startDictation = UIQuery.label("START DICTATION")
            static let stopDictation = UIQuery.label("STOP DICTATION")

            static let sessionSearch = UIQuery.id("sessions.search.field")
            static let clearSessionSearch = UIQuery.id("sessions.search.clear")
            // The transcript text is both an address and a payload: the well publishes it
            // as the value of its own node, and a copy has to leave exactly these bytes on
            // the pasteboard, which is a `UIText` rule rather than a query. Hence the
            // string beside the query built from it.
            static let newestTranscriptText =
                "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay."
            static let newestTranscript = UIQuery.value(newestTranscriptText)

            // A transcript two day groups below the newest one, so opening it proves the
            // detail follows the row that was clicked rather than trailing the whole list.
            static let midListTranscriptText =
                "Golden files must never encode the developer's display profile."
            static let midListTranscript = UIQuery.value(midListTranscriptText)
            // A closed row publishes no identifier and one combined label — stamp,
            // outcome word, word count, then the preview — so the preview text is the
            // only handle on it. Nothing else carries that text as a label: the open
            // row drops its preview and the well publishes the text as a value, so
            // exactly one node's label contains it.
            static let midListRow = UIQuery.labelContains(midListTranscriptText)

            // The detail has no buttons: the transcript is the control. Neither
            // gesture on it can be delivered here — a plain click is refused by an
            // `NSTextView` in an inactive app, and Command-T is offered only to a key
            // window, which this one can never become. `sessions.detail.in-place`
            // therefore asserts the well and the line that names both gestures, and
            // the gestures themselves are verified in the real app.
            static let detailTranscript = UIQuery.id("sessions.detail.transcript")

            // The pre-cleanup text of the newest transcript, folded shut until asked
            // for. The fixture gives exactly one session a raw text that differs from
            // its final text, so exactly one node can carry either of these.
            static let rawFold = UIQuery.id("sessions.detail.raw")
            static let newestRawText =
                "uh wire the offscreen renderer to NSHostingView and uh capture with cache display"
            static let newestRaw = UIQuery.value(newestRawText)

            // The record's own measurements — what received the text, how long each
            // stage took, and the decoder's least sure word — folded shut beside Raw
            // and independent of it. Each is the label of one `LabeledContent`, which
            // publishes it as the value of a static text node.
            static let detailsFold = UIQuery.id("sessions.detail.details")
            static let detailsTarget = UIQuery.value("Target")
            static let detailsTimings = UIQuery.value("Timings")
            static let detailsLeastSure = UIQuery.value("Least sure")

            static let addTermButton = UIQuery.id("glossary.add-term")
            static let glossarySearch = UIQuery.id("glossary.search.field")
            static let termCanonical = UIQuery.id("glossary.term.canonical")
            static let termAddForm = UIQuery.id("glossary.term.add-form")
            static let termSave = UIQuery.id("glossary.term.save")
            static let termRemove = UIQuery.id("glossary.term.remove")
            static let draftCanonical = UIQuery.id("glossary.draft.canonical")
            static let draftAddForm = UIQuery.id("glossary.draft.add-form")
            static let draftSave = UIQuery.id("glossary.draft.save")
            // A row is addressed by its term id, which is the canonical spelling
            // for a term created without one.
            static let bundledTermRow = UIQuery.id("glossary.term.kubectl")
            static let addedTermRow = UIQuery.id("glossary.term.FlowTerm")

            static let autoStop = UIQuery.id("voice.auto-stop.toggle")
            static let autoStopDuration = UIQuery.id("voice.auto-stop.duration")
            static let cleanup = UIQuery.id("voice.cleanup.toggle")

            static let modelPickerCompact = UIQuery.label("Compact")
            static let modelRestart = UIQuery.id("voice.model.restart")

            static let backendRecheck = UIQuery.id("system.backend.recheck")
            static let backendStatus = UIQuery.id("system.backend.status")

            static func backendStatusWithValue(_ value: String) -> UIQuery {
                .all([backendStatus, .value(value)])
            }

            static let copyLastTranscript = UIQuery.label("Copy last transcript")

            static let cancelRecording = UIQuery.label("Cancel recording")
            static let dictationStatus = UIQuery.label("Dictation status")
            static let finishRecording = UIQuery.label("Finish recording")
            static let cancelDictation = UIQuery.label("Cancel dictation")
            static let warmingStatus = UIQuery.all([
                .label("Dictation status"),
                .value("Microphone starting"),
            ])
            /// Live capture, hearing nothing yet: the meter's resting row.
            static let listeningStatus = UIQuery.all([
                .label("Dictation status"),
                .value("Listening"),
            ])
            /// Live capture with real speech, past the voice-activity hysteresis.
            static let speakingStatus = UIQuery.all([
                .label("Dictation status"),
                .value("Speaking"),
            ])
            static let copiedOutcome = UIQuery.all([
                .label("Dictation status"),
                .value("The transcript is on the clipboard."),
            ])

            /// The Dictation trigger row: the preference half of the merged
            /// Settings tab, and its first row.
            static let settingsContent = UIQuery.id("capture.hotkey")
            static let glossaryContent = glossarySearch
            static let historyContent = sessionSearch
            /// The Privacy row's action: the readiness half of the same tab.
            static let settingsDiagnostics = UIQuery.id("system.diagnostics.copy")
            static let homeContent = UIQuery.id("home.hero")

            static let homeTimeTile = UIQuery.id("home.tile.time")
            static let homeWordsTile = UIQuery.id("home.tile.words")
            static let homeSpeedTile = UIQuery.id("home.tile.wpm")
            static let homeCurrentStreak = UIQuery.id("home.streak.current")
            static let homeLongestStreak = UIQuery.id("home.streak.longest")
            static let homeActivityGrid = UIQuery.id("home.activity.grid")

            /// Home's first-run card. The gesture line is the card's headline, so
            /// its presence is the card's presence; the three chips are what the
            /// card is *for*, and the caption it supersedes must never render
            /// beside it.
            static let firstRunGesture = UIQuery.id("home.first-run.gesture")
            static let firstRunModel = UIQuery.id("home.first-run.model")
            static let firstRunMicrophone = UIQuery.id("home.first-run.microphone")
            static let firstRunAccessibility = UIQuery.id("home.first-run.accessibility")
            static let homeZeroCaption = UIQuery.id("home.empty")

            static func tab(_ tab: ConsoleTab) -> UIQuery {
                .id("console.tab.\(tab.rawValue)")
            }
        }

        /// Unfiltered declaration order is execution order and groups journeys by surface.
        static func everything() -> [UIFlow] {
            sessionFlows + voiceFlows + glossaryFlows + systemFlows + consoleFlows + menuFlows
                + overlayFlows + modernFlows
        }

        /// Selection goes through `UIHarnessRequest.matches(id:tags:)`, the one spelling of
        /// `--only`/`--except` shared with the scene catalog. Parsing installs the default
        /// `os26` exclusion.
        static func all(request: UIHarnessRequest) -> [UIFlow] {
            everything().filter { request.matches(id: $0.id, tags: $0.tags) }
        }

        // MARK: Sessions

        private static var sessionFlows: [UIFlow] {
            [
                UIFlow(
                    id: "sessions.search.no-results",
                    title: "A transcript search reaches the no-match state",
                    tags: ["sessions", "console", "search"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .act(.type(noMatchQuery, into: Selector.sessionSearch)),
                        .wait(.element(.value("Nothing matches “\(noMatchQuery)”"))),
                        .check(
                            "no-results",
                            [
                                .text(.equals("0 of 9 sessions match"), .exactly(1)),
                                .text(.equals("Nothing matches “\(noMatchQuery)”"), .exactly(1)),
                                .exists(Selector.clearSessionSearch),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "sessions.search.clear",
                    title: "Clearing transcript search restores the complete list",
                    tags: ["sessions", "console", "search"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .act(.type(noMatchQuery, into: Selector.sessionSearch)),
                        .wait(.element(Selector.clearSessionSearch)),
                        .check("filtered", [.text(.equals("0 of 9 sessions match"), .exactly(1))]),
                        .act(.press(Selector.clearSessionSearch)),
                        .wait(.absent(Selector.clearSessionSearch)),
                        .wait(.element(Selector.newestTranscript)),
                        .check(
                            "restored",
                            [
                                .value(Selector.sessionSearch, .isEmpty),
                                .absent(.value("Nothing matches “\(noMatchQuery)”")),
                                .exists(Selector.newestTranscript),
                                .model(.recentSessionCount, .equals("9")),
                            ]
                        ),
                    ]),
                // The detail is emitted inside the day group that holds its row, so
                // selecting an older transcript has to open it there and close the one
                // History arrived on. One transcript well in the tree is the assertion
                // that only one detail is ever open — the trailing `Section("Transcript")`
                // this replaced could not be wrong about that, and this can. The footer
                // line is asserted with it because it is now the only place the tab states
                // its two gestures, and both of them are unreachable from here.
                //
                // Measured: copying and teaching cannot have flows of their own. Copy is a
                // plain click on the transcript, and `NSTextView` refuses first mouse in an
                // app that is not active, so the synthetic click lands on nothing — the
                // override never ran and the pasteboard seam recorded no write. Teaching is
                // Command-T or the text view's own context menu, and
                // `-performKeyEquivalent:` is consulted only for the key window, which this
                // one can never become. Both gestures are verified in the real app; the
                // `console.sessions.selection` scene locks what the footer says once a
                // selection exists.
                UIFlow(
                    id: "sessions.detail.in-place",
                    title: "Selecting a transcript opens its detail on the row it belongs to",
                    tags: ["sessions", "console", "detail"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.midListRow)),
                        .wait(.element(Selector.midListTranscript)),
                        .check(
                            "moved",
                            [
                                .count(Selector.midListTranscript, .exactly(1)),
                                .absent(Selector.newestTranscript),
                                .count(Selector.detailTranscript, .exactly(1)),
                                .text(
                                    .equals(
                                        "Click the transcript to copy it. Select any words, or right-click one, "
                                            + "then press \u{2318}T to teach a correction."
                                    ),
                                    .exactly(1)
                                ),
                            ]
                        ),
                    ]),
                // The raw text is the one measurement the detail folds away, because at
                // dictation length it is several times the height of every other evidence
                // row. History arrives on the newest transcript, which is the one seeded
                // row whose raw text differs from its final text, so the fold is already
                // on screen and already shut.
                UIFlow(
                    id: "sessions.raw-fold",
                    title: "The raw transcript stays folded until it is asked for",
                    tags: ["sessions", "console", "detail"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "folded",
                            [
                                .count(Selector.rawFold, .exactly(1)),
                                .value(Selector.rawFold, .equals("false")),
                                .absent(Selector.newestRaw),
                            ]
                        ),
                        .act(.press(Selector.rawFold)),
                        .wait(.element(Selector.newestRaw)),
                        .check(
                            "unfolded",
                            [
                                .count(Selector.rawFold, .exactly(1)),
                                .value(Selector.rawFold, .equals("true")),
                                .count(Selector.newestRaw, .exactly(1)),
                            ]
                        ),
                        .act(.press(Selector.rawFold)),
                        .wait(.absent(Selector.newestRaw)),
                        .check(
                            "refolded",
                            [
                                .count(Selector.rawFold, .exactly(1)),
                                .value(Selector.rawFold, .equals("false")),
                                .absent(Selector.newestRaw),
                            ]
                        ),
                    ]),
                // Target, Timings and Least sure are the record's own measurements, and a
                // reader who opened a transcript came for the words. They sit behind a
                // second disclosure beside Raw, with its own binding: opening either fold
                // must leave the other one shut. History arrives on the newest transcript,
                // the one seeded row that carries all three of them.
                UIFlow(
                    id: "sessions.details-fold",
                    title: "Session metadata stays folded until it is asked for",
                    tags: ["sessions", "console", "detail"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "folded",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("false")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .exists(Selector.rawFold),
                                .value(Selector.rawFold, .equals("false")),
                            ]
                        ),
                        .act(.press(Selector.detailsFold)),
                        .wait(.element(Selector.detailsTarget)),
                        .check(
                            "unfolded",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("true")),
                                .count(Selector.detailsTarget, .exactly(1)),
                                .count(Selector.detailsTimings, .exactly(1)),
                                .count(Selector.detailsLeastSure, .exactly(1)),
                                .value(Selector.rawFold, .equals("false")),
                            ]
                        ),
                        .act(.press(Selector.detailsFold)),
                        .wait(.absent(Selector.detailsTarget)),
                        .check(
                            "refolded",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("false")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .value(Selector.rawFold, .equals("false")),
                            ]
                        ),
                        // A fold is a question asked about one transcript, so it closes with
                        // it: opening Details and then selecting another record must not
                        // carry that answer over. The mid-list row also has no differing raw
                        // text, so its detail proves the other half of the composition — a
                        // Details fold without a Raw fold above it.
                        .act(.press(Selector.detailsFold)),
                        .wait(.element(Selector.detailsTarget)),
                        .act(.press(Selector.midListRow)),
                        .wait(.element(Selector.midListTranscript)),
                        .check(
                            "switched",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("false")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .absent(Selector.rawFold),
                            ]
                        ),
                    ]),
            ]
        }

        // MARK: Voice

        private static var voiceFlows: [UIFlow] {
            [
                UIFlow(
                    id: "voice.toggle-cleanup",
                    title: "Transcript cleanup can be switched off",
                    tags: ["voice", "console", "settings"],
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "enabled",
                            [.value(Selector.cleanup, .equals("1")), .model(.cleanupEnabled, .equals("true"))]
                        ),
                        .act(.press(Selector.cleanup)),
                        .check(
                            "disabled",
                            [.value(Selector.cleanup, .equals("0")), .model(.cleanupEnabled, .equals("false"))]
                        ),
                    ]),
                // The restart affordance is the whole switching mechanism: the picker only
                // records a choice, and a selection that never offers the restart would leave
                // the app running the previous weights with no way to notice.
                UIFlow(
                    id: "voice.model-selection",
                    title: "Choosing a smaller model records the choice and asks for a restart",
                    tags: ["voice", "console", "settings", "model"],
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "balanced-in-use",
                            [
                                .model(.selectedModelVariant, .equals("f16")),
                                .absent(Selector.modelRestart),
                            ]
                        ),
                        .act(.press(Selector.modelPickerCompact)),
                        .check(
                            "compact-pending-restart",
                            [
                                .model(.selectedModelVariant, .equals("q8_0")),
                                .exists(Selector.modelRestart),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "voice.auto-stop-dependency",
                    title: "Auto-stop controls the silence field enablement",
                    tags: ["voice", "console", "settings"],
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "off",
                            [
                                .value(Selector.autoStop, .equals("0")),
                                .enabled(Selector.autoStopDuration, false),
                            ]
                        ),
                        .act(.press(Selector.autoStop)),
                        .check(
                            "on",
                            [
                                .value(Selector.autoStop, .equals("1")),
                                .enabled(Selector.autoStopDuration, true),
                            ]
                        ),
                    ]),
            ]
        }

        // MARK: Glossary

        private static var glossaryFlows: [UIFlow] {
            [
                UIFlow(
                    id: "glossary.add-term",
                    title: "A term can be added through the glossary",
                    tags: ["glossary", "console", "settings"],
                    host: .console(.glossary),
                    fixture: .static(.emptyGlossary),
                    steps: [
                        .check("empty", [.text(.equals("No terms yet"), .exactly(1))]),
                        .act(.press(Selector.addTermButton)),
                        .act(.type(glossaryTerm, into: Selector.draftCanonical)),
                        .act(.type(glossaryForms, into: Selector.draftAddForm)),
                        .act(.press(Selector.draftSave)),
                        .wait(.element(Selector.addedTermRow)),
                        .check(
                            "added",
                            [
                                .exists(Selector.addedTermRow),
                                // The one typed line is two forms, not one string.
                                .exists(.labelContains("heard as flow form, other form")),
                                .model(.glossaryTermCount, .equals("1")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "glossary.edit-term",
                    title: "A term opens in place and takes a new spoken form",
                    tags: ["glossary", "console", "settings"],
                    host: .console(.glossary),
                    fixture: .static(.mixedGlossary),
                    steps: [
                        .act(.press(Selector.bundledTermRow)),
                        .check(
                            "open",
                            [
                                .exists(Selector.termCanonical),
                                .exists(Selector.termAddForm),
                                .exists(Selector.termSave),
                            ]
                        ),
                        .act(.type("kube kettle", into: Selector.termAddForm)),
                        .act(.press(Selector.termSave)),
                        .check("saved", [.exists(.labelContains("kube kettle"))]),
                    ]),
                UIFlow(
                    id: "glossary.remove-term",
                    title: "Removing a term asks first",
                    tags: ["glossary", "console", "settings"],
                    host: .console(.glossary),
                    fixture: .static(.mixedGlossary),
                    steps: [
                        .act(.press(Selector.bundledTermRow)),
                        .act(.press(Selector.termRemove)),
                        // The safety property, and where this flow stops: a
                        // `confirmationDialog` cannot be driven by a window that
                        // never becomes key, exactly as History's delete
                        // confirmation is not flow-covered either.
                        .check("awaiting-confirmation", [.model(.glossaryTermCount, .equals("9"))]),
                    ]),
            ]
        }

        // MARK: System

        private static var systemFlows: [UIFlow] {
            [
                UIFlow(
                    id: "system.recheck-backend",
                    title: "An unanswered backend probe reads as ENGINE OFFLINE until re-proven",
                    tags: ["system", "console", "settings"],
                    host: .console(.settings),
                    fixture: .backendRecovery(),
                    steps: [
                        .wait(.element(Selector.backendStatusWithValue("CHECKING…"))),
                        .check(
                            "initial-probe",
                            [.value(Selector.backendStatus, .equals("CHECKING…"))]
                        ),
                        .release(.backendHealthUnavailable),
                        // A probe that never answered, with no cached model, is the
                        // engine being absent — not a failed download (nothing was
                        // downloading) and not a shrug ("CHECK NEEDED").
                        .wait(.element(Selector.backendStatusWithValue("ENGINE OFFLINE"))),
                        .check(
                            "unavailable",
                            [
                                .value(Selector.backendStatus, .equals("ENGINE OFFLINE")),
                                .label(Selector.backendRecheck, .equals("Re-check backend health")),
                                .role(Selector.backendRecheck, "AXButton"),
                            ]
                        ),
                        .act(.press(Selector.backendRecheck)),
                        // The failure is environmental: starting a re-probe does not
                        // erase it. Only fresh good evidence may clear the row.
                        .check(
                            "rechecking",
                            [.value(Selector.backendStatus, .equals("ENGINE OFFLINE"))]
                        ),
                        .release(.backendHealth),
                        .wait(.element(Selector.backendStatusWithValue("READY"))),
                        .check(
                            "ready",
                            [
                                .value(Selector.backendStatus, .equals("READY")),
                                .text(
                                    .equals("PARAKEET is configured for local transcription."),
                                    .exactly(1)
                                ),
                            ]
                        ),
                    ])
            ]
        }

        // MARK: Console tabs

        private static var consoleFlows: [UIFlow] {
            [
                homeStatsFlow,
                homeFirstRunFlow,
                tabNavigationFlow(
                    id: "console.tab.navigation",
                    title: "The native console switches through every tab",
                    tags: ["console", "tab", "navigation"]
                ),
            ]
        }

        /// The card a fresh install opens on, and the one event that retires it.
        ///
        /// The retirement is a durable decision made inside the stop pipeline, so
        /// the interesting assertion is negative and ordered: the card is still
        /// there while a recording is live — a started dictation has completed
        /// nothing — and gone once a transcript has been delivered. Home's zeroed
        /// caption must never appear beside the card or in place of it afterwards:
        /// the card names the gesture in full, and by the time it leaves there are
        /// figures to read.
        ///
        /// Driven through `dictate` rather than a control because the trigger is
        /// the global Fn/Globe tap, which an offscreen window can never receive,
        /// and the console has no start button of its own.
        private static var homeFirstRunFlow: UIFlow {
            UIFlow(
                id: "home.first-run",
                title: "Home's first-run card retires on the first delivered dictation",
                tags: ["console", "home", "first-run"],
                host: .console(.home),
                fixture: .static(.firstRun),
                steps: [
                    .wait(.element(Selector.firstRunGesture)),
                    .check(
                        "owed",
                        [
                            .count(Selector.firstRunGesture, .exactly(1)),
                            .label(
                                Selector.firstRunGesture,
                                .equals("Tap Fn or Globe to dictate, speak, then tap again to finish.")
                            ),
                            .count(Selector.firstRunModel, .exactly(1)),
                            .count(Selector.firstRunMicrophone, .exactly(1)),
                            .count(Selector.firstRunAccessibility, .exactly(1)),
                            .absent(Selector.homeZeroCaption),
                            .model(.recentSessionCount, .equals("0")),
                        ]
                    ),
                    .act(.dictate(.start)),
                    .wait(.state(.recording)),
                    .check(
                        "recording",
                        [
                            .count(Selector.firstRunGesture, .exactly(1)),
                            .model(.recentSessionCount, .equals("0")),
                        ]
                    ),
                    .act(.dictate(.stopAndProcess)),
                    .wait(.absent(Selector.firstRunGesture)),
                    .check(
                        "retired",
                        [
                            .absent(Selector.firstRunGesture),
                            .absent(Selector.homeZeroCaption),
                            .count(Selector.homeContent, .exactly(1)),
                            .model(.recentSessionCount, .equals("1")),
                        ]
                    ),
                ]
            )
        }

        /// Home states the fixture ledger's figures, and still states them after
        /// a round trip through another tab — the derived values are recomputed
        /// on every appearance, so a stale or re-zeroed readout would show up
        /// here rather than in a reader's console.
        private static var homeStatsFlow: UIFlow {
            UIFlow(
                id: "home.stats",
                title: "Home reports the lifetime ledger",
                tags: ["console", "home", "stats"],
                host: .console(.home),
                fixture: .static(.populated),
                steps: [
                    .wait(.element(Selector.homeContent)),
                    .check(
                        "figures",
                        [
                            .count(Selector.homeContent, .exactly(1)),
                            .value(Selector.homeTimeTile, .equals("4 hr 32 min")),
                            .value(Selector.homeWordsTile, .equals("36.1K words")),
                            .value(Selector.homeSpeedTile, .equals("133 wpm")),
                            .value(Selector.homeCurrentStreak, .equals("0 days")),
                            .value(Selector.homeLongestStreak, .equals("6 days")),
                            .label(
                                Selector.homeActivityGrid,
                                .equals(
                                    "Dictation activity, last 30 weeks: "
                                        + "23 active days, busiest day 4351 words"
                                )
                            ),
                        ]
                    ),
                    .act(.navigate(.history)),
                    .wait(.element(Selector.historyContent)),
                    .act(.navigate(.home)),
                    .wait(.element(Selector.homeContent)),
                    .check(
                        "returned",
                        [
                            .value(Selector.homeTimeTile, .equals("4 hr 32 min")),
                            .value(Selector.homeWordsTile, .equals("36.1K words")),
                            .value(Selector.homeLongestStreak, .equals("6 days")),
                        ]
                    ),
                ]
            )
        }

        // MARK: Menu and dictation

        private static var menuFlows: [UIFlow] {
            [
                pasteDeliveredFlow,
                copyOnlyFlow,
                cancelledFlow,
                asrErrorFlow,
                UIFlow(
                    id: "menu.copy-transcript",
                    title: "The last transcript can be copied from its card",
                    tags: ["menu", "clipboard"],
                    host: .menu,
                    fixture: .static(.completedDictation),
                    steps: [
                        // MenuTranscriptPreview.swift:57-59; fixtures/ui/menu.transcript.ax.txt:4.
                        .check(
                            "available",
                            [
                                .enabled(Selector.copyLastTranscript, true),
                                .label(Selector.copyLastTranscript, .equals("Copy last transcript")),
                                .role(Selector.copyLastTranscript, "AXButton"),
                                .value(Selector.copyLastTranscript, .equals(UIFixtures.pinnedTranscript)),
                            ]
                        ),
                        .act(.press(Selector.copyLastTranscript)),
                        .check(
                            "copied",
                            [
                                .model(.pasteboardText, .equals(UIFixtures.pinnedTranscript)),
                                .model(.pasteboardWrites, .equals("1")),
                            ]
                        ),
                    ]),
            ]
        }

        private static var pasteDeliveredFlow: UIFlow {
            UIFlow(
                id: "dictation.paste.delivered",
                title: "A complete menu dictation is pasted and persisted",
                tags: ["menu", "dictation", "delivery"],
                host: .menu,
                fixture: pasteFixture,
                steps: fullDeliverySteps(
                    terminalState: .pasteAttempted,
                    disposition: "paste",
                    bundleID: pasteBundleID,
                    reportLabel: "PASTE ATTEMPTED"
                ))
        }

        private static var copyOnlyFlow: UIFlow {
            UIFlow(
                id: "dictation.copy-only.terminal",
                title: "A terminal target receives copy-only delivery",
                tags: ["menu", "dictation", "delivery", "terminal"],
                host: .menu,
                fixture: .dictation(
                    transcript: dictatedText,
                    outcome: .copiedOnly(reason: "Terminal targets are copy-only."),
                    targetBundleID: terminalBundleID,
                    targetSafety: .terminal
                ),
                steps: fullDeliverySteps(
                    terminalState: .copiedOnly,
                    disposition: "copy",
                    bundleID: terminalBundleID,
                    reportLabel: "COPIED ONLY"
                ))
        }

        private static var cancelledFlow: UIFlow {
            UIFlow(
                id: "dictation.cancelled",
                title: "Cancelling a live dictation delivers nothing",
                tags: ["menu", "dictation", "cancel"],
                host: .menu,
                // Cancelling from `.recording` never reaches the recorder-stop,
                // transcription or insertion boundaries, so arming them would leave
                // three gates no script can release.
                fixture: .dictation(
                    transcript: dictatedText,
                    outcome: .pasteAttempted,
                    targetBundleID: pasteBundleID,
                    targetSafety: .normalText,
                    reaches: [.permission]
                ),
                steps: [
                    .act(.press(Selector.startDictation)),
                    .wait(.state(.checkingPermissions)),
                    .release(.permission),
                    .wait(.state(.recording)),
                    .check("recording", [.state(.recording), .text(.equals("LIVE"), .exactly(1))]),
                    .act(.dictate(.cancel)),
                    .wait(.state(.idle)),
                    .check(
                        "cancelled",
                        [
                            .transitions([.idle, .checkingPermissions, .recording, .cancelled, .idle], .exact),
                            .model(.deliveryCount, .equals("0")),
                            .model(.recentSessionCount, .equals("0")),
                        ]
                    ),
                ])
        }

        private static var asrErrorFlow: UIFlow {
            UIFlow(
                id: "dictation.asr-error",
                title: "An ASR error is terminal and delivers nothing",
                tags: ["menu", "dictation", "error"],
                host: .menu,
                fixture: .dictationError(code: .backendUnavailable),
                steps: [
                    .act(.press(Selector.startDictation)),
                    .wait(.state(.checkingPermissions)),
                    .release(.permission),
                    .wait(.state(.recording)),
                    .act(.press(Selector.stopDictation)),
                    .wait(.state(.finalizingAudio)),
                    .release(.recorderStop),
                    .wait(.state(.transcribing)),
                    .release(.transcription),
                    .wait(.state(.error)),
                    .check(
                        "asr-error",
                        [
                            .state(.error),
                            .transitions(
                                [.idle, .checkingPermissions, .recording, .finalizingAudio, .transcribing, .error],
                                .exact
                            ),
                            .model(.deliveryCount, .equals("0")),
                            .model(.recentSessionCount, .equals("0")),
                        ]
                    ),
                ])
        }

        private static var pasteFixture: UIFlowFixture {
            .dictation(
                transcript: dictatedRawText,
                outcome: .pasteAttempted,
                targetBundleID: pasteBundleID,
                targetSafety: .normalText
            )
        }

        /// The menu's LIVE chip breathes on a wall-clock-driven animation. The semantic
        /// expectations below therefore carry the complete journey without sampling an
        /// arbitrary animation phase.
        private static func fullDeliverySteps(
            terminalState: UIStatePattern,
            disposition: String,
            bundleID: String,
            reportLabel: String
        ) -> [UIFlowStep] {
            [
                .act(.press(Selector.startDictation)),
                .wait(.state(.checkingPermissions)),
                .check("checking-permissions", [.state(.checkingPermissions), .text(.equals("WORKING"), .exactly(1))]),
                .release(.permission),
                .wait(.state(.recording)),
                .check(
                    "live",
                    [
                        .state(.recording),
                        .text(.equals("LIVE"), .exactly(1)),
                        .exists(Selector.stopDictation),
                    ]
                ),
                .act(.press(Selector.stopDictation)),
                .wait(.state(.finalizingAudio)),
                .check("finalizing-audio", [.state(.finalizingAudio), .text(.equals("WORKING"), .exactly(1))]),
                .release(.recorderStop),
                .wait(.state(.transcribing)),
                .check("transcribing", [.state(.transcribing), .text(.equals("WORKING"), .exactly(1))]),
                .release(.transcription),
                .wait(.state(.readyToInsert)),
                .check("ready-to-insert", [.state(.readyToInsert), .text(.equals("WORKING"), .exactly(1))]),
                .release(.insertion),
                .wait(.state(.idle)),
                .check(
                    "delivered",
                    [
                        .transitions(
                            [
                                .idle,
                                .checkingPermissions,
                                .recording,
                                .finalizingAudio,
                                .transcribing,
                                .cleaning,
                                .readyToInsert,
                                terminalState,
                                .idle,
                            ],
                            .exact
                        ),
                        .model(.deliveredText, .equals(dictatedText)),
                        .model(.deliveryBundleID, .equals(bundleID)),
                        .model(.deliveryDisposition, .equals(disposition)),
                        .model(.deliveryCount, .equals("1")),
                        .model(.recentSessionCount, .equals("1")),
                        // CaptureModels.swift:132-150 defines the exact outcome labels.
                        .text(.equals(reportLabel), .exactly(1)),
                    ]
                ),
            ]
        }

        // MARK: Overlay

        private static var overlayFlows: [UIFlow] {
            [
                UIFlow(
                    id: "overlay.recording.controls",
                    title: "The recording overlay exposes both labelled controls",
                    tags: ["overlay", "dictation"],
                    host: .overlay,
                    fixture: .static(.recording),
                    steps: [
                        .check(
                            "controls",
                            [
                                .exists(Selector.dictationStatus),
                                .enabled(Selector.cancelRecording, true),
                                .label(Selector.cancelRecording, .equals("Cancel recording")),
                                .enabled(Selector.finishRecording, true),
                                .label(Selector.finishRecording, .equals("Finish recording")),
                            ]
                        )
                    ]),
                warmupFlow,
                overlayCopyOnlyFlow,
            ]
        }

        /// The overlay bridge holds the terminal presentation stable after the
        /// coordinator's adjacent `.idle`, so the journal can inspect the outcome
        /// without making a wall-clock dwell part of a semantic gate.
        private static var overlayCopyOnlyFlow: UIFlow {
            UIFlow(
                id: "overlay.delivery.copy-only",
                title: "A copy-only delivery leaves one safe, buttonless outcome",
                tags: ["overlay", "dictation", "delivery", "terminal"],
                host: .overlay,
                fixture: .dictation(
                    transcript: dictatedText,
                    outcome: .copiedOnly(reason: "Terminal targets are copy-only."),
                    targetBundleID: terminalBundleID,
                    targetSafety: .terminal
                ),
                steps: [
                    .act(.dictate(.start)),
                    .wait(.state(.checkingPermissions)),
                    .release(.permission),
                    .wait(.state(.recording)),
                    .act(.dictate(.stopAndProcess)),
                    .wait(.state(.finalizingAudio)),
                    .release(.recorderStop),
                    .wait(.state(.transcribing)),
                    .release(.transcription),
                    .wait(.state(.readyToInsert)),
                    .release(.insertion),
                    .wait(.state(.idle)),
                    .wait(.element(Selector.copiedOutcome)),
                    .check(
                        "copied",
                        [
                            .value(
                                Selector.dictationStatus,
                                .equals("The transcript is on the clipboard.")
                            ),
                            .absent(Selector.cancelRecording),
                            .absent(Selector.cancelDictation),
                            .absent(Selector.finishRecording),
                            .count(.role("AXButton"), .exactly(0)),
                            .transitions(
                                [
                                    .idle,
                                    .checkingPermissions,
                                    .recording,
                                    .finalizingAudio,
                                    .transcribing,
                                    .cleaning,
                                    .readyToInsert,
                                    .copiedOnly,
                                    .idle,
                                ],
                                .exact
                            ),
                            .model(.deliveryDisposition, .equals("copy")),
                        ]
                    ),
                ]
            )
        }

        /// The window this whole surface was blind to.
        ///
        /// `AudioRecording.captureIsLive()` used to be answered by the protocol default --
        /// `true`, always -- or, on the streaming path, by the arrival of the first tap
        /// callback, which on AirPods Max fires at 151 ms holding a buffer of pure zeros.
        /// The island therefore drew a flat meter for the 1.4 s before real audio arrived,
        /// which looks exactly like a live meter in a quiet room, and the user spoke into
        /// the hole. This journey stands inside that window: one element, one stable
        /// label, and a value that changes at the moment the capture actually wakes up.
        ///
        /// The centre slot crossfades on `centerPhaseToken` with a wall-clock curve.
        /// `overlay.island.warmup` and `overlay.island.recording` pin the stable endpoints;
        /// this journey verifies their order.
        private static var warmupFlow: UIFlow {
            UIFlow(
                id: "overlay.capture.warmup",
                title: "The island says WARMING until the microphone is really delivering audio",
                tags: ["overlay", "dictation", "warmup"],
                host: .overlay,
                fixture: .captureWarmup(),
                steps: [
                    // Before anything starts: the trailing cap holds no action at all, so
                    // the island publishes exactly one control, the discard.
                    .check(
                        "idle",
                        [
                            .state(.idle),
                            .absent(Selector.finishRecording),
                            .enabled(Selector.cancelDictation, true),
                            .count(.role("AXButton"), .exactly(1)),
                        ]
                    ),
                    .act(.dictate(.start)),
                    .wait(.state(.checkingPermissions)),
                    .release(.permission),
                    .wait(.state(.recording)),
                    .wait(.element(Selector.warmingStatus)),
                    // `.recording` and NOT listening. The finish action is already live --
                    // the user may stop a dictation that has not started hearing them --
                    // and the readout is the only thing that says so.
                    .check(
                        "warming",
                        [
                            .state(.recording),
                            .value(Selector.dictationStatus, .equals("Microphone starting")),
                            .absent(Selector.listeningStatus),
                            .absent(Selector.speakingStatus),
                            .enabled(Selector.finishRecording, true),
                        ]
                    ),
                    .release(.captureLive),
                    .wait(.element(Selector.speakingStatus)),
                    // Same element, same label, same state: only the value moved, which is
                    // exactly the regression this flow exists to catch. Anything that
                    // reports liveness off "the capture was requested" again fails here.
                    //
                    // The value is "Speaking" rather than "Listening" because the fixture's
                    // metering loop feeds real levels, so this leg also proves the readout
                    // crosses the voice-activity hysteresis from actual samples. The
                    // resting row a quiet microphone draws is pinned by
                    // `overlay.island.listening` instead, which can hold it still.
                    .check(
                        "listening",
                        [
                            .state(.recording),
                            .value(Selector.dictationStatus, .equals("Speaking")),
                            .absent(Selector.warmingStatus),
                            .transitions([.idle, .checkingPermissions, .recording], .exact),
                        ]
                    ),
                    // Ends the session rather than leaving a 40 ms metering loop running
                    // in the process for every flow that comes after this one.
                    .act(.dictate(.cancel)),
                    .wait(.state(.idle)),
                ])
        }

        // MARK: Modern render path (macOS 26)

        /// The menu journey drives its macOS 26 branch. The console journey keeps
        /// the renamed compatibility contract while exercising the same native
        /// `TabView` hierarchy under the `os26` harness tag.
        private static var modernFlows: [UIFlow] {
            [
                tabNavigationFlow(
                    id: "console.tab.navigation.os26",
                    title: "The native console switches tabs under the os26 harness path",
                    tags: ["console", "tab", "navigation", "os26"]
                ),
                UIFlow(
                    id: "menu.primary-action.os26",
                    title: "The menu primary action drives a dictation on the native render path",
                    tags: ["menu", "dictation", "os26"],
                    host: .menu,
                    // Modelled on `dictation.cancelled`: cancelling from `.recording` never
                    // reaches the later boundaries, so arming them would leave gates no script
                    // can release.
                    fixture: .dictation(
                        transcript: dictatedText,
                        outcome: .pasteAttempted,
                        targetBundleID: pasteBundleID,
                        targetSafety: .normalText,
                        reaches: [.permission]
                    ),
                    steps: [
                        // `.lintClean` is affordable here and nowhere else on the native path:
                        // the menu host paints `Ink.void` behind `MenuView`, so the raster the
                        // geometry and contrast rules read is real paint rather than the
                        // unrasterised window ground an `os26` console render leaves behind.
                        .check(
                            "idle",
                            [
                                .role(Selector.startDictation, "AXButton"),
                                .label(Selector.startDictation, .equals("START DICTATION")),
                                .enabled(Selector.startDictation, true),
                                .lintClean,
                            ]
                        ),
                        .act(.press(Selector.startDictation)),
                        .wait(.state(.checkingPermissions)),
                        .release(.permission),
                        .wait(.state(.recording)),
                        .check(
                            "live",
                            [
                                .state(.recording),
                                .transitions([.idle, .checkingPermissions, .recording], .exact),
                                // MenuView.swift:155-157: one capsule, two labels.
                                .absent(Selector.startDictation),
                                .role(Selector.stopDictation, "AXButton"),
                                .label(Selector.stopDictation, .equals("STOP DICTATION")),
                                .enabled(Selector.stopDictation, true),
                                .text(.equals("LIVE"), .exactly(1)),
                            ]
                        ),
                        .act(.dictate(.cancel)),
                        .wait(.state(.idle)),
                        .check(
                            "idle-again",
                            [
                                .state(.idle),
                                .transitions([.idle, .checkingPermissions, .recording, .cancelled, .idle], .exact),
                                .absent(Selector.stopDictation),
                                .label(Selector.startDictation, .equals("START DICTATION")),
                                .enabled(Selector.startDictation, true),
                                .model(.deliveryCount, .equals("0")),
                            ]
                        ),
                    ]),
            ]
        }

        private static func tabNavigationFlow(
            id: String,
            title: String,
            tags: [String]
        ) -> UIFlow {
            UIFlow(
                id: id,
                title: title,
                tags: tags,
                host: .console(.home),
                fixture: .static(.populated),
                steps: [
                    .check(
                        "home",
                        [
                            .count(Selector.homeContent, .exactly(1)),
                            .value(Selector.tab(.home), .equals("1")),
                            .absent(Selector.settingsContent),
                        ]
                    ),
                    .act(.navigate(.glossary)),
                    .wait(.element(Selector.glossaryContent)),
                    .check(
                        "glossary",
                        [
                            .count(Selector.glossaryContent, .exactly(1)),
                            .value(Selector.tab(.glossary), .equals("1")),
                            .value(Selector.tab(.home), .equals("0")),
                            .absent(Selector.historyContent),
                        ]
                    ),
                    .act(.navigate(.history)),
                    .wait(.element(Selector.historyContent)),
                    .check(
                        "history",
                        [
                            .count(Selector.historyContent, .exactly(1)),
                            .absent(Selector.glossaryContent),
                            .value(Selector.tab(.history), .equals("1")),
                            .value(Selector.tab(.glossary), .equals("0")),
                        ]
                    ),
                    .act(.navigate(.settings)),
                    .wait(.element(Selector.settingsContent)),
                    // Both halves of the merged tab in one check: the preference
                    // rows the General tab used to own and the diagnostics row the
                    // System tab used to own now render on one destination.
                    .check(
                        "settings",
                        [
                            .count(Selector.settingsContent, .exactly(1)),
                            .count(Selector.settingsDiagnostics, .exactly(1)),
                            .absent(Selector.historyContent),
                            .value(Selector.tab(.settings), .equals("1")),
                            .value(Selector.tab(.history), .equals("0")),
                        ]
                    ),
                ]
            )
        }
    }

#endif
