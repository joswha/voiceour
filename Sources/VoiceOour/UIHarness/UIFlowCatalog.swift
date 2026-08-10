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
        private static let codeEditorBundleID = "com.apple.dt.Xcode"
        private static let glossaryTerm = "FlowTerm"
        private static let glossaryAliases = "flow term, flow-term"
        private static let noMatchQuery = "definitely-not-a-transcript"

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

            // fixtures/ui/console.system.denied.ax.txt:19
            static let backendRecheck = UIQuery.id("system.backend.recheck")
            // fixtures/ui/console.system.granted.ax.txt:17
            static let backendReady = UIQuery.label("Backend")

            // fixtures/ui/console.refinement.off.ax.txt:18,47
            static let enableRefiner = UIQuery.label("Enable refiner")
            static let checkRefiner = UIQuery.label("CHECK")

            // fixtures/ui/menu.transcript.ax.txt:4
            static let copyLastTranscript = UIQuery.label("Copy last transcript")

            // fixtures/ui/overlay.panel.recording.ax.txt:2-4
            static let cancelRecording = UIQuery.label("Cancel recording")
            static let dictationStatus = UIQuery.label("Dictation status")
            static let finishRecording = UIQuery.label("Finish recording")

            // These flow-local identifiers follow ConfirmActionRow.swift:128-159. No scene
            // contains the `flow.confirm` instance; its controls are verified at runtime.
            static let confirmArm = UIQuery.id("flow.confirm.arm")
            static let confirmField = UIQuery.id("flow.confirm.confirmation")
            static let confirmButton = UIQuery.id("flow.confirm.confirm")
        }

        /// Unfiltered declaration order is execution order and groups journeys by surface.
        static func everything() -> [UIFlow] {
            homeFlows + sessionFlows + voiceFlows + glossaryFlows + refinementFlows + systemFlows
                + menuFlows + overlayFlows + atomFlows
        }

        /// Mirrors `UISceneCatalog`: `--only` is OR-ed substring-or-tag matching and
        /// `--except` is applied afterwards. Parsing installs the default `os26` exclusion.
        static func all(request: UIHarnessRequest) -> [UIFlow] {
            everything().filter { flow in
                guard !request.excludes(flow.id, tags: flow.tags) else { return false }
                guard !request.only.isEmpty else { return true }
                return request.only.contains { needle in
                    flow.id.contains(needle) || flow.tags.contains(needle)
                }
            }
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
                        // The first session is not persisted until refinement finishes, so HomePane
                        // still renders HomeEmptyState here; WORKING belongs to the dashboard below.
                        .wait(.state(.refining)),
                        .check("refining", [.state(.refining)]),
                        .release(.refinement),
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
                            ]
                        ),
                    ]
                )
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

        // MARK: Refinement

        private static var refinementFlows: [UIFlow] {
            [
                UIFlow(
                    id: "refinement.enable-and-check",
                    title: "Enable a configured refiner and check reachability",
                    tags: ["refinement", "console", "settings"],
                    covers: [
                        .state(.refinement, "check-success"),
                        .journey(.refinement, "enable-and-check"),
                    ],
                    host: .tallConsole(.refinement),
                    fixture: .refinerCheck(),
                    steps: [
                        .check(
                            "disabled",
                            [
                                .value(Selector.enableRefiner, .equals("0")),
                                .enabled(Selector.checkRefiner, false),
                                .model(.refinementEnabled, .equals("false")),
                            ]
                        ),
                        .act(.press(Selector.enableRefiner)),
                        .check(
                            "enabled",
                            [
                                .value(Selector.enableRefiner, .equals("1")),
                                .enabled(Selector.checkRefiner, true),
                                .model(.refinementEnabled, .equals("true")),
                            ]
                        ),
                        .act(.press(Selector.checkRefiner)),
                        // RefinementConnectionSection.swift:81-88 defines this source-only post-CHECK verdict.
                        .wait(.element(.value("REACHABLE · 3 MODELS"))),
                        .check("reachable", [.text(.equals("REACHABLE · 3 MODELS"), .exactly(1))]),
                    ]
                )
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
                                    .equals("READY, Parakeet MLX is configured for local transcription.")
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
                codeEditorRefinementSkipFlow,
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
                    reportLabel: "PASTE ATTEMPTED",
                    includesRefinement: true
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
                    refined: dictatedText,
                    outcome: .copiedOnly(reason: "Terminal targets are copy-only."),
                    targetBundleID: terminalBundleID,
                    targetSafety: .terminal,
                    refinementEnabled: false
                ),
                // Terminal safety intentionally skips cloud refinement in the real policy.
                steps: fullDeliverySteps(
                    terminalState: .copiedOnly,
                    disposition: "copy",
                    bundleID: terminalBundleID,
                    reportLabel: "COPIED ONLY",
                    includesRefinement: false
                )
            )
        }

        private static var codeEditorRefinementSkipFlow: UIFlow {
            UIFlow(
                id: "dictation.refinement-skipped.code-editor",
                title: "A code-editor target skips refinement by policy",
                tags: ["menu", "dictation", "delivery", "code-editor", "refinement"],
                covers: [.journey(.menu, "dictation-code-editor-skips-refinement")],
                host: .menu,
                fixture: .dictation(
                    transcript: dictatedRawText,
                    refined: "This refiner result must never reach a code editor.",
                    outcome: .copiedOnly(reason: "Code editor targets are copy-only."),
                    targetBundleID: codeEditorBundleID,
                    targetSafety: .codeEditor,
                    refinementEnabled: true,
                    reaches: [.permission, .recorderStop, .transcription, .insertion]
                ),
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
                    .wait(.state(.readyToInsert)),
                    .release(.insertion),
                    .wait(.state(.idle)),
                    .check(
                        "refinement-skipped",
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
                                    .copiedOnly,
                                    .idle,
                                ],
                                .exact
                            ),
                            .model(.refinementEnabled, .equals("true")),
                            .model(.deliveredText, .equals(dictatedText)),
                            .model(.deliveryBundleID, .equals(codeEditorBundleID)),
                            .model(.deliveryDisposition, .equals("copy")),
                        ]
                    ),
                ]
            )
        }

        private static var cancelledFlow: UIFlow {
            UIFlow(
                id: "dictation.cancelled",
                title: "Cancelling a live dictation delivers nothing",
                tags: ["menu", "dictation", "cancel"],
                covers: [.journey(.menu, "dictation-cancel")],
                host: .menu,
                // Cancelling from `.recording` never reaches the recorder-stop, transcription,
                // refinement or insertion boundaries, so arming them would leave four gates no
                // script can release -- indistinguishable from a script that forgot to.
                fixture: .dictation(
                    transcript: dictatedText,
                    refined: dictatedText,
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
                refined: dictatedText,
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
        /// overlay. The twenty semantic expectations below already carry the whole journey,
        /// and none of them is a pixel.
        private static func fullDeliverySteps(
            terminalState: UIStatePattern,
            disposition: String,
            bundleID: String,
            reportLabel: String,
            includesRefinement: Bool
        ) -> [UIFlowStep] {
            var steps: [UIFlowStep] = [
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
            ]
            steps.append(contentsOf: [
                .act(.press(Selector.stopDictation)),
                .wait(.state(.finalizingAudio)),
                .check("finalizing-audio", [.state(.finalizingAudio), .text(.equals("WORKING"), .exactly(1))]),
                .release(.recorderStop),
                .wait(.state(.transcribing)),
                .check("transcribing", [.state(.transcribing), .text(.equals("WORKING"), .exactly(1))]),
                .release(.transcription),
            ])
            if includesRefinement {
                steps.append(contentsOf: [
                    .wait(.state(.refining)),
                    .check("refining", [.state(.refining), .text(.equals("WORKING"), .exactly(1))]),
                    .release(.refinement),
                ])
            }
            steps.append(contentsOf: [
                .wait(.state(.readyToInsert)),
                .check("ready-to-insert", [.state(.readyToInsert), .text(.equals("WORKING"), .exactly(1))]),
                .release(.insertion),
                .wait(.state(.idle)),
            ])
            var transitionSequence: [UIStatePattern] = [
                .idle,
                .checkingPermissions,
                .recording,
                .finalizingAudio,
                .transcribing,
                .cleaning,
            ]
            if includesRefinement { transitionSequence.append(.refining) }
            transitionSequence.append(contentsOf: [.readyToInsert, terminalState, .idle])
            steps.append(
                .check(
                    "delivered",
                    [
                        .transitions(transitionSequence, .exact),
                        .model(.deliveredText, .equals(dictatedText)),
                        .model(.deliveryBundleID, .equals(bundleID)),
                        .model(.deliveryDisposition, .equals(disposition)),
                        .model(.deliveryCount, .equals("1")),
                        .model(.recentSessionCount, .equals("1")),
                        // CaptureModels.swift:132-150 defines the exact outcome labels.
                        .text(.equals(reportLabel), .exactly(1)),
                    ]
                )
            )
            return steps
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
                )
            ]
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
            .padding(VoiceOourMetrics.Space.xl)
        }
    }

#endif
