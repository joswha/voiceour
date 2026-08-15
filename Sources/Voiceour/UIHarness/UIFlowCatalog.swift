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
        private static let glossaryAliases = "flow term, flow-term"
        private static let noMatchQuery = "definitely-not-a-transcript"
        /// A plausible touch-typist rate, well inside `DictationInsights.typingWPMRange`
        /// and far enough from the default that every derived figure has to move.
        private static let fastTypistWPM = "90"
        private static let defaultBaselineNote =
            "52 wpm is the measured average of 168,000 typists — change it to yours."
        private static let readerBaselineNote =
            "Your typing speed, not the 52 wpm population average."

        /// Queries are grounded in committed AX dumps unless the comment explicitly
        /// names the source-only branch from which the runtime selector is derived.
        private enum Selector {
            // fixtures/ui/menu.idle.ax.txt:5
            static let startDictation = UIQuery.label("START DICTATION")
            // No scene reaches recording MenuView. Derived from MenuView.swift:153-160.
            static let stopDictation = UIQuery.label("STOP DICTATION")

            // fixtures/ui/console.sessions.populated.ax.txt:22
            static let sessionSearch = UIQuery.placeholder("Search transcripts or timestamps")
            // fixtures/ui/console.sessions.search.ax.txt:23
            static let clearSessionSearch = UIQuery.id("sessions.search.clear")

            // fixtures/ui/console.system.granted.ax.txt
            static let historyArm = UIQuery.id("system.history.arm")
            // fixtures/ui/console.system.confirm.ax.txt
            static let historyConfirmation = UIQuery.id("system.history.confirmation")
            // fixtures/ui/console.system.confirm.ax.txt
            static let historyConfirm = UIQuery.id("system.history.confirm")

            // fixtures/ui/console.glossary.empty.ax.txt:23-25
            static let canonicalTerm = UIQuery.placeholder("Canonical term")
            static let aliases = UIQuery.placeholder("Detected as (comma-separated)")
            static let addTerm = UIQuery.label("ADD TERM")
            // No golden contains a term created during a flow. The identifier is formed at
            // GlossaryTermRow.swift:65-66; ProtectedTerm.termId defaults to canonical at Models.swift:40-54.
            static let addedTermRemove = UIQuery.id("remove.FlowTerm")
            // fixtures/ui/console.glossary.populated.ax.txt:47
            static let bundledTermRemove = UIQuery.id("remove.kubectl")

            // fixtures/ui/console.voice.default.ax.txt:35-40
            static let autoStop = UIQuery.label("Stop after silence")
            static let autoStopDuration = UIQuery.label("Auto-stop silence, milliseconds")
            static let cleanup = UIQuery.label("Clean up after capture")

            // One segment per registry descriptor, labelled with its display name:
            // fixtures/ui/console.voice.default.ax.txt:18-20 for the three that
            // predate ARK, VoicePane.swift:108-115 for the shape the pair follows.
            static func backendOption(_ displayName: String) -> UIQuery {
                .label(displayName)
            }
            // fixtures/ui/console.voice.restart-required.ax.txt:21. Published only
            // while a saved backend differs from the one running.
            static let backendRestart = UIQuery.id("voice.backend.restart")

            // HomeVelocityGauges.swift: the one editable figure on Home. No
            // committed golden holds an edited baseline, so the runtime value
            // is what this flow verifies.
            static let typingSpeed = UIQuery.label("Typing speed, words per minute")

            // fixtures/ui/console.system.denied.ax.txt:19
            static let backendRecheck = UIQuery.id("system.backend.recheck")
            // fixtures/ui/console.system.granted.ax.txt:17
            static let backendReady = UIQuery.label("Backend")


            // fixtures/ui/menu.transcript.ax.txt:4
            static let copyLastTranscript = UIQuery.label("Copy last transcript")

            // fixtures/ui/overlay.panel.recording.ax.txt:2-4
            static let cancelRecording = UIQuery.label("Cancel recording")
            static let dictationStatus = UIQuery.label("Dictation status")
            static let finishRecording = UIQuery.label("Finish recording")
            // The idle island's leading control. `RecordingOverlayView.cancelButton`
            // swaps the label on `model.isRecording`; no scene renders an idle overlay.
            static let cancelDictation = UIQuery.label("Cancel dictation")

            // The centre readout addressed by label AND value, which is the whole point of
            // the warm-up flow: both phases publish one element with the same stable label
            // in the same slot, and only the value says which phase it is.
            // `RecordingOverlayModel.accessibilityStatus`; the warm-up half is also pinned
            // by fixtures/ui/overlay.island.warmup.ax.txt.
            static let warmingStatus = UIQuery.all([.label("Dictation status"), .value("Microphone starting")])
            static let listeningStatus = UIQuery.all([.label("Dictation status"), .value("Recording")])
            // fixtures/ui/overlay.panel.partial.ax.txt — panel variant only; the island has no
            // band for a line of text, which the unchanged island goldens keep honest.
            static let partialPreview = UIQuery.label("Live transcript preview")

            // These flow-local identifiers follow ConfirmActionRow.swift:128-159. No scene
            // contains the `flow.confirm` instance; its controls are verified at runtime.
            static let confirmArm = UIQuery.id("flow.confirm.arm")
            static let confirmField = UIQuery.id("flow.confirm.confirmation")
            static let confirmButton = UIQuery.id("flow.confirm.confirm")

            /// One rail row. Addressed by role AND label because every pane publishes an
            /// `AXHeading` carrying its section's label too -- `fixtures/ui/
            /// console.diagnostics.healthy.ax.txt:2-8` for the rows, `:11` for the heading --
            /// so a bare label query would match two nodes and fail as ambiguous.
            static func railItem(_ section: ConsoleSection) -> UIQuery {
                .all([.role("AXButton"), .label(section.label)])
            }

            /// The pane heading a rail selection lands on. The one bounded signal that the
            /// selection change finished, rather than a settle count guessed at.
            static func paneHeading(_ section: ConsoleSection) -> UIQuery {
                .all([.role("AXHeading"), .label(section.label)])
            }
        }

        /// Unfiltered declaration order is execution order and groups journeys by surface.
        static func everything() -> [UIFlow] {
            homeFlows + sessionFlows + voiceFlows + glossaryFlows + systemFlows + menuFlows
                + overlayFlows + atomFlows + modernFlows
        }

        /// Selection goes through `UIHarnessRequest.matches(id:tags:)`, the one spelling of
        /// `--only`/`--except` shared with the scene and film catalogs. Parsing installs the
        /// default `os26` exclusion.
        static func all(request: UIHarnessRequest) -> [UIFlow] {
            everything().filter { request.matches(id: $0.id, tags: $0.tags) }
        }

        // MARK: Home

        private static var homeFlows: [UIFlow] {
            [
                UIFlow(
                    id: "home.empty-to-populated",
                    title: "A first dictation replaces the empty dashboard",
                    tags: ["home", "console", "dictation"],
                    covers: [
                        .state(.home, "working-ready-to-insert"),
                        .journey(.home, "empty-to-populated"),
                    ],
                    host: .console(.home),
                    fixture: pasteFixture,
                    steps: [
                        // fixtures/ui/console.home.empty.ax.txt:14
                        .check("empty", [.text(.equals("No dictations yet"), .exactly(1))]),
                        .act(.dictate(.start)),
                        .wait(.state(.checkingPermissions)),
                        .check("checking-permissions", [.state(.checkingPermissions)]),
                        .release(.permission),
                        .wait(.state(.recording)),
                        .check("recording", [.state(.recording)]),
                        .act(.dictate(.stopAndProcess)),
                        .wait(.state(.finalizingAudio)),
                        .check("finalizing", [.state(.finalizingAudio)]),
                        .release(.recorderStop),
                        .wait(.state(.transcribing)),
                        .check("transcribing", [.state(.transcribing)]),
                        .release(.transcription),
                        .wait(.state(.readyToInsert)),
                        // HomePane.swift:81-89 is source-only here: the session has been recorded,
                        // so the empty branch has become the dashboard before insertion.
                        .check("ready-to-insert", [.state(.readyToInsert), .text(.equals("WORKING"), .atLeast(1))]),
                        .release(.insertion),
                        .wait(.state(.idle)),
                        // HomeAllTimeShelf.swift:15-17 and HomePane.swift:52-59 define the populated endpoint.
                        .wait(.element(.value("ALL TIME"))),
                        .check(
                            "populated",
                            [
                                .absent(.value("No dictations yet")),
                                .text(.equals("ALL TIME"), .exactly(1)),
                                .model(.recentSessionCount, .equals("1")),
                                // The ALL TIME strip reads the lifetime ledger, not the
                                // capped transcript list; at one dictation the two agree,
                                // and that they are both asserted is the point.
                                .model(.lifetimeDictationCount, .equals("1")),
                            ]
                        ),
                    ]
                ),
                UIFlow(
                    id: "home.set-typing-speed",
                    title: "The typing baseline can be corrected on the pane that claims it",
                    tags: ["home", "console", "settings"],
                    covers: [
                        .state(.home, "typing-baseline-custom"),
                        .journey(.home, "set-typing-speed"),
                    ],
                    host: .console(.home),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "population-default",
                            [
                                .model(.typingSpeedWPM, .equals("52")),
                                .text(.equals(defaultBaselineNote), .exactly(1)),
                            ]
                        ),
                        .act(.type(fastTypistWPM, into: Selector.typingSpeed)),
                        .check(
                            "reader-baseline",
                            [
                                .model(.typingSpeedWPM, .equals(fastTypistWPM)),
                                .absent(.value(defaultBaselineNote)),
                                .text(.equals(readerBaselineNote), .exactly(1)),
                            ]
                        ),
                    ]
                ),
            ]
        }

        // MARK: Sessions

        private static var sessionFlows: [UIFlow] {
            [
                UIFlow(
                    id: "sessions.search.no-results",
                    title: "A transcript search reaches the no-match state",
                    tags: ["sessions", "console", "search"],
                    covers: [
                        .state(.sessions, "search-no-results"),
                        .journey(.sessions, "search-no-results"),
                    ],
                    host: .console(.sessions),
                    fixture: .static(.populated),
                    steps: [
                        .act(.type(noMatchQuery, into: Selector.sessionSearch)),
                        // SessionsPane.swift:159-167 is source-only; no committed scene reaches no matches.
                        .wait(.element(.value("Nothing matches “\(noMatchQuery)”"))),
                        .check(
                            "no-results",
                            [
                                .text(.equals("0 of 9 sessions match"), .exactly(1)),
                                .text(.equals("Nothing matches “\(noMatchQuery)”"), .exactly(1)),
                                .exists(Selector.clearSessionSearch),
                            ]
                        ),
                    ]
                ),
                UIFlow(
                    id: "sessions.search.clear",
                    title: "Clearing transcript search restores the complete list",
                    tags: ["sessions", "console", "search"],
                    covers: [.journey(.sessions, "search-clear")],
                    host: .console(.sessions),
                    fixture: .static(.populated),
                    steps: [
                        .act(.type(noMatchQuery, into: Selector.sessionSearch)),
                        .wait(.element(Selector.clearSessionSearch)),
                        .check("filtered", [.text(.equals("0 of 9 sessions match"), .exactly(1))]),
                        .act(.press(Selector.clearSessionSearch)),
                        .wait(.absent(Selector.clearSessionSearch)),
                        // fixtures/ui/console.sessions.populated.ax.txt:12,22,28-33
                        .check(
                            "restored",
                            [
                                .text(.equals("9 SESSIONS"), .exactly(1)),
                                .value(Selector.sessionSearch, .isEmpty),
                                .absent(.value("Nothing matches “\(noMatchQuery)”")),
                            ]
                        ),
                    ]
                ),
            ]
        }

        // MARK: Voice

        private static var voiceFlows: [UIFlow] {
            [
                UIFlow(
                    id: "voice.toggle-cleanup",
                    title: "Transcript cleanup can be switched off",
                    tags: ["voice", "console", "settings"],
                    covers: [
                        .state(.voice, "cleanup-off"),
                        .journey(.voice, "toggle-cleanup"),
                    ],
                    host: .console(.voice),
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
                    ]
                ),
                UIFlow(
                    id: "voice.auto-stop-dependency",
                    title: "Auto-stop controls the silence field enablement",
                    tags: ["voice", "console", "settings"],
                    covers: [
                        .state(.voice, "auto-stop-enabled"),
                        .journey(.voice, "auto-stop-dependency"),
                    ],
                    host: .console(.voice),
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
                    ]
                ),
                UIFlow(
                    id: "voice.select-backend",
                    title: "Every ASR backend can be saved, and the readouts name the running one",
                    tags: ["voice", "system", "console", "settings", "cross-pane"],
                    covers: [.state(.voice, "backend-selections")],
                    host: .console(.voice),
                    fixture: .static(.appleBackendReady),
                    steps: [
                        .check(
                            "apple-running",
                            [
                                .selected(Selector.backendOption("APPLE SPEECH"), true),
                                .model(.activeBackend, .equals("apple")),
                                // VoicePane.runningSummary prints the running descriptor's
                                // model label while saved and running agree, so this line is
                                // the registry's Apple id rather than the Parakeet contract.
                                .text(.equals("apple/SpeechTranscriber (system-managed)"), .exactly(1)),
                                .absent(Selector.backendRestart),
                            ]
                        ),
                        // Every option in declaration order, so the pane is proved to save
                        // each of the three rather than only the one already running.
                        .act(.press(Selector.backendOption("FAKE"))),
                        .check("fake-saved", [.selected(Selector.backendOption("FAKE"), true)]),
                        .act(.press(Selector.backendOption("PARAKEET"))),
                        .check(
                            "parakeet-saved",
                            [
                                .selected(Selector.backendOption("PARAKEET"), true),
                                .selected(Selector.backendOption("APPLE SPEECH"), false),
                                // The header chip carries the saved id, uppercased.
                                .text(.equals("PARAKEET"), .atLeast(1)),
                                // Saving is not switching: the restart mark appears, the
                                // running backend is untouched, and the footer gives up the
                                // model line to say which one that is.
                                .exists(Selector.backendRestart),
                                .model(.activeBackend, .equals("apple")),
                                .text(.equals("APPLE SPEECH IN USE"), .exactly(1)),
                            ]
                        ),
                        .act(.navigate(.system)),
                        .wait(.element(Selector.backendReady)),
                        // The readiness sentence follows the backend that is running, never
                        // the one just saved -- it used to name Parakeet whatever was selected.
                        .check(
                            "system-names-running-backend",
                            [
                                .value(
                                    Selector.backendReady,
                                    .equals("READY, APPLE SPEECH is configured for local transcription.")
                                )
                            ]
                        ),
                    ]
                ),
            ]
        }

        // MARK: Glossary

        private static var glossaryFlows: [UIFlow] {
            [
                UIFlow(
                    id: "glossary.add-term",
                    title: "A canonical term can be added through the ledger",
                    tags: ["glossary", "console", "settings"],
                    covers: [
                        .state(.glossary, "manual-add-result"),
                        .journey(.glossary, "add-term"),
                    ],
                    host: .console(.glossary),
                    fixture: .static(.emptyGlossary),
                    steps: [
                        // fixtures/ui/console.glossary.empty.ax.txt:21-25
                        .check("empty", [.text(.equals("No canonical terms yet"), .exactly(1))]),
                        .act(.type(glossaryTerm, into: Selector.canonicalTerm)),
                        .act(.type(glossaryAliases, into: Selector.aliases)),
                        .act(.press(Selector.addTerm)),
                        .wait(.element(Selector.addedTermRemove)),
                        .check(
                            "added",
                            [
                                .exists(.value(glossaryTerm)),
                                .exists(Selector.addedTermRemove),
                                .model(.glossaryTermCount, .equals("1")),
                            ]
                        ),
                    ]
                ),
                UIFlow(
                    id: "glossary.remove-term",
                    title: "A glossary row can be removed immediately",
                    tags: ["glossary", "console", "settings"],
                    covers: [
                        .state(.glossary, "removal"),
                        .journey(.glossary, "remove-term"),
                    ],
                    host: .console(.glossary),
                    fixture: .static(.populated),
                    steps: [
                        // fixtures/ui/console.glossary.populated.ax.txt:45-47
                        .check("present", [.exists(.value("kubectl")), .exists(Selector.bundledTermRemove)]),
                        .act(.press(Selector.bundledTermRemove)),
                        .wait(.absent(Selector.bundledTermRemove)),
                        .check("removed", [.absent(.value("kubectl")), .absent(Selector.bundledTermRemove)]),
                    ]
                ),
            ]
        }


        // MARK: System

        private static var systemFlows: [UIFlow] {
            [
                UIFlow(
                    id: "system.recheck-backend",
                    title: "Re-checking the backend updates its readiness row",
                    tags: ["system", "console", "settings"],
                    covers: [.journey(.system, "recheck-backend")],
                    host: .console(.system),
                    fixture: .backendRecovery(),
                    steps: [
                        // SystemPane.swift:217-223; fixtures/ui/console.system.denied.ax.txt:17-20.
                        .check(
                            "unavailable",
                            [
                                .exists(.value("CHECK NEEDED")),
                                .label(Selector.backendRecheck, .equals("Re-check backend health")),
                                .role(Selector.backendRecheck, "AXButton"),
                            ]
                        ),
                        .act(.press(Selector.backendRecheck)),
                        // fixtures/ui/console.system.granted.ax.txt:17
                        .wait(.element(Selector.backendReady)),
                        .check(
                            "ready",
                            [
                                .value(
                                    Selector.backendReady,
                                    .equals("READY, PARAKEET is configured for local transcription.")
                                )
                            ]
                        ),
                    ]
                ),
                UIFlow(
                    id: "system.clear-history.confirm",
                    title: "Confirmed history clearing reaches empty Sessions",
                    tags: ["system", "sessions", "console", "cross-pane"],
                    covers: [
                        .state(.system, "clear-history-success"),
                        .journey(.system, "clear-history-confirm"),
                    ],
                    host: .console(.system),
                    fixture: .static(.populated),
                    steps: [
                        .check("available", [.enabled(Selector.historyArm, true)]),
                        .act(.press(Selector.historyArm)),
                        .wait(.element(Selector.historyConfirmation)),
                        .act(.type("CLEAR", into: Selector.historyConfirmation)),
                        .check("armed", [.enabled(Selector.historyConfirm, true)]),
                        .act(.press(Selector.historyConfirm)),
                        .act(.navigate(.sessions)),
                        // fixtures/ui/console.sessions.empty.ax.txt:16-17
                        .wait(.element(.value("No sessions yet"))),
                        .check(
                            "empty-sessions",
                            [
                                .text(.equals("No sessions yet"), .exactly(1)),
                                .text(.equals("Nothing recorded yet"), .exactly(1)),
                                .model(.recentSessionCount, .equals("0")),
                            ]
                        ),
                    ]
                ),
            ]
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
                    covers: [.journey(.menu, "copy-transcript")],
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
                    ]
                ),
            ]
        }

        private static var pasteDeliveredFlow: UIFlow {
            UIFlow(
                id: "dictation.paste.delivered",
                title: "A complete menu dictation is pasted and persisted",
                tags: ["menu", "dictation", "delivery"],
                covers: [
                    .state(.menu, "live"),
                    .state(.menu, "working"),
                    .journey(.menu, "dictation-paste-delivered"),
                ],
                host: .menu,
                fixture: pasteFixture,
                steps: fullDeliverySteps(
                    terminalState: .pasteAttempted,
                    disposition: "paste",
                    bundleID: pasteBundleID,
                    reportLabel: "PASTE ATTEMPTED"
                )
            )
        }

        private static var copyOnlyFlow: UIFlow {
            UIFlow(
                id: "dictation.copy-only.terminal",
                title: "A terminal target receives copy-only delivery",
                tags: ["menu", "dictation", "delivery", "terminal"],
                covers: [
                    .state(.menu, "copy-only-report"),
                    .journey(.menu, "dictation-copy-only"),
                ],
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
                )
            )
        }


        private static var cancelledFlow: UIFlow {
            UIFlow(
                id: "dictation.cancelled",
                title: "Cancelling a live dictation delivers nothing",
                tags: ["menu", "dictation", "cancel"],
                covers: [.journey(.menu, "dictation-cancel")],
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
                ]
            )
        }

        private static var asrErrorFlow: UIFlow {
            UIFlow(
                id: "dictation.asr-error",
                title: "An ASR error is terminal and delivers nothing",
                tags: ["menu", "dictation", "error"],
                covers: [.journey(.menu, "dictation-asr-error")],
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
                ]
            )
        }

        private static var pasteFixture: UIFlowFixture {
            .dictation(
                transcript: dictatedRawText,
                outcome: .pasteAttempted,
                targetBundleID: pasteBundleID,
                targetSafety: .normalText
            )
        }

        /// No `.capture` step anywhere in this journey, deliberately.
        ///
        /// A frame taken at `.recording` measured 59 pt wide on one run and 58 pt on the next:
        /// the menu's LIVE chip breathes on a `.repeatForever` animation whose phase is
        /// wall-clock driven, so its golden flaps every run and trains reviewers to bless
        /// noise. The scene catalog avoids the same trap by refusing to snapshot a processing
        /// overlay. The semantic expectations below already carry the whole journey,
        /// and none of them is a pixel.
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
                    covers: [.journey(.overlay, "recording-controls")],
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
                    ]
                ),
                warmupFlow,
                partialPreviewFlow,
            ]
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
        /// No `.capture` step, deliberately. The centre slot crossfades on
        /// `centerPhaseToken` with a wall-clock curve, so a frame taken here records
        /// whatever opacity this host happened to reach. `overlay.island.warmup` pins the
        /// warm-up pixels with no transition in flight, and `overlay.island.recording`
        /// pins the meter; what a flow adds is the ORDER, which is semantic.
        private static var warmupFlow: UIFlow {
            UIFlow(
                id: "overlay.capture.warmup",
                title: "The island says WARMING until the microphone is really delivering audio",
                tags: ["overlay", "dictation", "warmup"],
                covers: [.state(.overlay, "capture-warmup"), .state(.overlay, "idle")],
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
                            .enabled(Selector.finishRecording, true),
                        ]
                    ),
                    .release(.captureLive),
                    .wait(.element(Selector.listeningStatus)),
                    // Same element, same label, same state: only the value moved, which is
                    // exactly the regression this flow exists to catch. Anything that
                    // reports liveness off "the capture was requested" again fails here.
                    .check(
                        "listening",
                        [
                            .state(.recording),
                            .value(Selector.dictationStatus, .equals("Recording")),
                            .absent(Selector.warmingStatus),
                            .transitions([.idle, .checkingPermissions, .recording], .exact),
                        ]
                    ),
                    // Ends the session rather than leaving a 40 ms metering loop running
                    // in the process for every flow that comes after this one.
                    .act(.dictate(.cancel)),
                    .wait(.state(.idle)),
                ]
            )
        }

        /// The preview line appears while recording and leaves with the session.
        ///
        /// Everything here is gated: the preview lands when the script says so, not when a
        /// 40 ms poll and a decode happen to line up. The `.exactly(1)` count is the point —
        /// a poll that re-requests a preview it already has would publish the line twice.
        private static var partialPreviewFlow: UIFlow {
            UIFlow(
                id: "overlay.partial-preview",
                title: "A live partial transcript appears under the island and clears with the session",
                tags: ["overlay", "dictation", "partial"],
                covers: [.journey(.overlay, "partial-preview")],
                host: .overlay,
                fixture: .partialPreview(),
                steps: [
                    .check("idle", [.state(.idle), .absent(Selector.partialPreview)]),
                    .act(.dictate(.start)),
                    .wait(.state(.checkingPermissions)),
                    .release(.permission),
                    .wait(.state(.recording)),
                    // Recording, and the preview decode has not answered yet: the line must
                    // not appear before there is anything to show.
                    .check("recording", [.state(.recording), .absent(Selector.partialPreview)]),
                    .release(.partialTranscription),
                    .wait(.element(Selector.partialPreview)),
                    .check(
                        "preview",
                        [
                            .state(.recording),
                            .count(Selector.partialPreview, .exactly(1)),
                            .value(Selector.partialPreview, .equals("Partial preview text")),
                        ]
                    ),
                    .act(.dictate(.cancel)),
                    .wait(.state(.idle)),
                    .check(
                        "cleared",
                        [
                            .state(.idle),
                            .absent(Selector.partialPreview),
                            .transitions([.idle, .checkingPermissions, .recording, .cancelled, .idle], .exact),
                        ]
                    ),
                ]
            )
        }

        // MARK: Atoms

        private static var atomFlows: [UIFlow] {
            [
                UIFlow(
                    id: "atoms.confirm-row",
                    title: "ConfirmActionRow arms, runs and returns after durable success",
                    tags: ["atoms", "confirm"],
                    covers: [
                        .state(.atoms, "confirm-in-flight"),
                        .state(.atoms, "confirm-success"),
                        .journey(.atoms, "confirm-row"),
                    ],
                    host: .custom(
                        size: CGSize(width: 808, height: 160),
                        colorScheme: .dark,
                        build: { context in AnyView(FlowConfirmRow(context: context)) }
                    ),
                    fixture: .static(.firstRun, armedGates: [.persistence]),
                    steps: [
                        .check("collapsed", [.enabled(Selector.confirmArm, true)]),
                        .act(.press(Selector.confirmArm)),
                        .wait(.element(Selector.confirmField)),
                        .check("armed", [.exists(Selector.confirmField), .enabled(Selector.confirmButton, false)]),
                        .act(.type("CLEAR", into: Selector.confirmField)),
                        .act(.press(Selector.confirmButton)),
                        // ConfirmActionRow.swift:14-17,150-157 defines this source-only in-flight state.
                        .wait(.element(.label("CLEARING…"))),
                        .check(
                            "in-flight",
                            [
                                .label(Selector.confirmButton, .equals("CLEARING…")),
                                .enabled(Selector.confirmButton, false),
                            ]
                        ),
                        .release(.persistence),
                        .wait(.element(Selector.confirmArm)),
                        .check(
                            "success",
                            [
                                .enabled(Selector.confirmArm, true),
                                .absent(Selector.confirmField),
                                .absent(Selector.confirmButton),
                            ]
                        ),
                    ]
                )
            ]
        }

        // MARK: Modern render path (macOS 26)

        /// The only flows that drive the native branch.
        ///
        /// Every other flow runs with `RenderOverrides.forceLegacyGlass` pinned true by
        /// `UIFixtures.pinProcessSeams()`, so until these landed the repo exercised no
        /// interactive behaviour on the macOS 26 code path anywhere. The `os26` tag is what
        /// releases the seam (`UIFlowRunner.run`) and what excludes them from `make ui-flow`.
        ///
        /// Neither flow captures a frame. `cacheDisplay` does not rasterise SwiftUI
        /// `.glassEffect`, so a native-branch frame golden would record the absence of the
        /// material as stably as its presence; what these flows assert is what the native
        /// branch really does publish -- content, labels, roles, selection and state.
        private static var modernFlows: [UIFlow] {
            [
                UIFlow(
                    id: "console.rail.navigation.os26",
                    title: "Rail navigation keeps every row on the native render path",
                    tags: ["console", "rail", "navigation", "os26"],
                    covers: [.journey(.home, "modern-rail-navigation")],
                    // Diagnostics is a debug pane: `ConsoleRailSections.swift:44-50` keeps it
                    // on the rail only while it is the open pane. Opening it is therefore the
                    // only way to assert the full six-row inventory.
                    host: .console(.diagnostics),
                    fixture: .static(.populated),
                    steps: [
                        .check(
                            "diagnostics",
                            railRows([.home, .sessions, .voice, .glossary, .system, .diagnostics])
                                + [
                                    .selected(Selector.railItem(.diagnostics), true),
                                    .selected(Selector.railItem(.home), false),
                                ]
                        ),
                        .act(.navigate(.voice)),
                        .wait(.element(Selector.paneHeading(.voice))),
                        .check(
                            "voice",
                            railRows([.home, .sessions, .voice, .glossary, .system])
                                + [
                                    // The debug-only row leaves with the pane, by design. Asserted
                                    // rather than ignored: a row that lingered here would make the
                                    // rail lie about where the reader is.
                                    .absent(Selector.railItem(.diagnostics)),
                                    .selected(Selector.railItem(.voice), true),
                                    .selected(Selector.railItem(.home), false),
                                ]
                        ),
                        .act(.navigate(.glossary)),
                        .wait(.element(Selector.paneHeading(.glossary))),
                        .check(
                            "glossary",
                            railRows([.home, .sessions, .voice, .glossary, .system])
                                + [
                                    .selected(Selector.railItem(.glossary), true),
                                    .selected(Selector.railItem(.voice), false),
                                ]
                        ),
                        .act(.navigate(.home)),
                        .wait(.element(Selector.paneHeading(.home))),
                        .check(
                            "home",
                            railRows([.home, .sessions, .voice, .glossary, .system])
                                + [
                                    .selected(Selector.railItem(.home), true),
                                    .selected(Selector.railItem(.glossary), false),
                                ]
                        ),
                    ]
                ),
                UIFlow(
                    id: "menu.primary-action.os26",
                    title: "The menu primary action drives a dictation on the native render path",
                    tags: ["menu", "dictation", "os26"],
                    covers: [.journey(.menu, "modern-primary-action")],
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
                    ]
                ),
            ]
        }

        /// One expectation per rail row rather than one count over all of them: a count that
        /// drops from seven to three names no row, and naming the row that vanished is the
        /// entire point of this assertion.
        private static func railRows(_ sections: [ConsoleSection]) -> [UIExpectation] {
            sections.map { .role(Selector.railItem($0), "AXButton") }
        }
    }

    private struct FlowConfirmRow: View {
        let context: UIFlowContext
        @State private var isConfirming = false

        var body: some View {
            ConfirmActionRow(
                label: "Clear history",
                subject: "Transcript history",
                scope: "Clear local transcript history. Settings and glossary terms are kept.",
                token: "CLEAR",
                actionTitle: "CLEAR HISTORY",
                inFlightTitle: "CLEARING…",
                failureLabel: "NOT ERASED",
                failureText: "Transcript history could not be erased from disk — it will come back on relaunch.",
                identifier: "flow.confirm",
                isAvailable: true,
                isConfirming: $isConfirming,
                perform: {
                    await context.box(.persistence).arrive()
                    return true
                }
            )
            .padding(VoiceourMetrics.Space.xl)
        }
    }

#endif
