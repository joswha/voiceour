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

        /// Queries are exact. Every action and single-node expectation rejects zero
        /// or multiple matches rather than silently retargeting a nearby control.
        private enum Selector {
            static let startDictation = UIQuery.label("START DICTATION")
            static let stopDictation = UIQuery.label("STOP DICTATION")

            static let sessionSearch = UIQuery.id("sessions.search.field")
            static let clearSessionSearch = UIQuery.id("sessions.search.clear")
            static let restoredTranscript = UIQuery.value(
                "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay."
            )

            static let canonicalTerm = UIQuery.id("glossary.add-term.canonical")
            static let aliases = UIQuery.id("glossary.add-term.aliases")
            static let addTerm = UIQuery.id("glossary.add-term.submit")
            static let addedTermRemove = UIQuery.id("remove.FlowTerm")
            static let bundledTermRemove = UIQuery.id("remove.kubectl")

            static let autoStop = UIQuery.id("voice.auto-stop.toggle")
            static let autoStopDuration = UIQuery.id("voice.auto-stop.duration")
            static let cleanup = UIQuery.id("voice.cleanup.toggle")

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
            static let listeningStatus = UIQuery.all([
                .label("Dictation status"),
                .value("Recording"),
            ])

            static let generalContent = UIQuery.id("capture.hotkey")
            static let glossaryContent = canonicalTerm
            static let historyContent = sessionSearch
            static let systemContent = UIQuery.id("system.diagnostics.copy")

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
                        .wait(.element(Selector.restoredTranscript)),
                        .check(
                            "restored",
                            [
                                .value(Selector.sessionSearch, .isEmpty),
                                .absent(.value("Nothing matches “\(noMatchQuery)”")),
                                .exists(Selector.restoredTranscript),
                                .model(.recentSessionCount, .equals("9")),
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
                    host: .console(.general),
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
                UIFlow(
                    id: "voice.auto-stop-dependency",
                    title: "Auto-stop controls the silence field enablement",
                    tags: ["voice", "console", "settings"],
                    host: .console(.general),
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
                    title: "A canonical term can be added through the glossary",
                    tags: ["glossary", "console", "settings"],
                    host: .console(.glossary),
                    fixture: .static(.emptyGlossary),
                    steps: [
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
                    ]),
                UIFlow(
                    id: "glossary.remove-term",
                    title: "A glossary row can be removed immediately",
                    tags: ["glossary", "console", "settings"],
                    host: .console(.glossary),
                    fixture: .static(.populated),
                    steps: [
                        .check("present", [.exists(.value("kubectl")), .exists(Selector.bundledTermRemove)]),
                        .act(.press(Selector.bundledTermRemove)),
                        .wait(.absent(Selector.bundledTermRemove)),
                        .check("removed", [.absent(.value("kubectl")), .absent(Selector.bundledTermRemove)]),
                    ]),
            ]
        }

        // MARK: System

        private static var systemFlows: [UIFlow] {
            [
                UIFlow(
                    id: "system.recheck-backend",
                    title: "Re-checking the backend updates its readiness row",
                    tags: ["system", "console", "settings"],
                    host: .console(.system),
                    fixture: .backendRecovery(),
                    steps: [
                        .wait(.element(Selector.backendStatusWithValue("CHECKING…"))),
                        .check(
                            "initial-probe",
                            [.value(Selector.backendStatus, .equals("CHECKING…"))]
                        ),
                        .release(.backendHealthUnavailable),
                        .wait(.element(Selector.backendStatusWithValue("CHECK NEEDED"))),
                        .check(
                            "unavailable",
                            [
                                .value(Selector.backendStatus, .equals("CHECK NEEDED")),
                                .label(Selector.backendRecheck, .equals("Re-check backend health")),
                                .role(Selector.backendRecheck, "AXButton"),
                            ]
                        ),
                        .act(.press(Selector.backendRecheck)),
                        .wait(.element(Selector.backendStatusWithValue("CHECKING…"))),
                        .check(
                            "checking",
                            [.value(Selector.backendStatus, .equals("CHECKING…"))]
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
                tabNavigationFlow(
                    id: "console.tab.navigation",
                    title: "The native console switches through every tab",
                    tags: ["console", "tab", "navigation"]
                )
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
                host: .console(.general),
                fixture: .static(.populated),
                steps: [
                    .check(
                        "general",
                        [
                            .count(Selector.generalContent, .exactly(1)),
                            .value(Selector.tab(.general), .equals("1")),
                            .absent(Selector.glossaryContent),
                        ]
                    ),
                    .act(.navigate(.glossary)),
                    .wait(.element(Selector.glossaryContent)),
                    .check(
                        "glossary",
                        [
                            .count(Selector.glossaryContent, .exactly(1)),
                            .absent(Selector.generalContent),
                            .value(Selector.tab(.glossary), .equals("1")),
                            .value(Selector.tab(.general), .equals("0")),
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
                    .act(.navigate(.system)),
                    .wait(.element(Selector.systemContent)),
                    .check(
                        "system",
                        [
                            .count(Selector.systemContent, .exactly(1)),
                            .absent(Selector.historyContent),
                            .value(Selector.tab(.system), .equals("1")),
                            .value(Selector.tab(.history), .equals("0")),
                        ]
                    ),
                ]
            )
        }
    }

#endif
