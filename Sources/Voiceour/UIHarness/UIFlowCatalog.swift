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
        /// `dictatedText` behind the spoken note command, as recognition punctuates it:
        /// the command and its comma are dropped and the note's first letter capitalised,
        /// so the saved note is `dictatedText` exactly.
        private static let spokenNoteText =
            "Note to self, the offscreen harness renders every console pane without stealing focus."
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
            static let retryDictation = UIQuery.label("Try Again")
            static let startAfterFailure = UIQuery.label("Start Dictation")

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

            // The fixture binds two Terminal rows to one omp session and gives one of
            // them a prompt edited before it was sent: a comma the dictation did not
            // have. Its closed row is addressed by its preview, like the mid-list row.
            static let sentFold = UIQuery.id("sessions.detail.sent")
            static let detailsAgent = UIQuery.value("Agent")
            // SwiftUI publishes a text inside a `LabeledContent` value twice, nested; the
            // identifier is on the outer node only, so it addresses the title once.
            static let agentTitle = UIQuery.id("sessions.detail.agent")
            static let agentRowText =
                "Post the mouse up before sending the mouse down or AppKit's tracking loop wedges."
            static let agentRow = UIQuery.labelContains(agentRowText)
            static let agentTranscript = UIQuery.value(agentRowText)
            static let sentTextNode = UIQuery.value(
                "Post the mouse up before sending the mouse down, or AppKit's tracking loop wedges."
            )

            // Journal ▸ Rewind and Threads. A flow opens either lens through its host's
            // `journalLens` pin rather than pressing its sidebar item: that is not a press a
            // window that never becomes key can count on.
            static let rewindEarlier = UIQuery.id("journal.rewind.earlier")
            static let rewindLater = UIQuery.id("journal.rewind.later")
            static let rewindSearch = UIQuery.id("journal.rewind.search")
            static let clearRewindSearch = UIQuery.id("journal.rewind.search.clear")
            static let rewindEntriesReadout = UIQuery.id("journal.rewind.entries")
            // Entries and words on the fixture's two newest days: rows 1 to 3 on the day
            // Rewind opens on; rows 4 and 5 on the day before it.
            static let newestDayFigure = "3 · 37 words"
            static let earlierDayFigure = "2 · 23 words"
            // Rows 1 and 7 say it, and rows 6 and 9 are bound to the omp session whose
            // title holds it, so the count proves the search reads titles as well as text.
            static let rewindQuery = "offscreen"
            static let rewindMatchCaption = "4 matches"
            // Row 9 matches by its session title alone, on a day Rewind does not open on.
            static let titleMatchRow = UIQuery.labelContains(
                "An activation policy of prohibited is the only setting that never steals focus."
            )

            /// Rewind's Entries readout showing `figure`. The identifier is set on the whole
            /// `LabeledContent`, so it names the readout and the value names the day.
            static func rewindEntries(_ figure: String) -> UIQuery {
                .all([rewindEntriesReadout, .value(figure)])
            }

            // The History days older than those two, newest first: row 6 and the Tern row
            // whose link missed, then rows 7, 8 and 9, one a day. Rows 7 and 9 hold the same
            // count, so the day between them is what tells the two apart on a walk through
            // every day.
            static let olderHistoryDayFigures = ["2 · 27 words", "1 · 13 words", "1 · 8 words", "1 · 13 words"]
            // 2025-06-03, the newest day only memory holds: two entries in the omp session
            // and two in Xcode. Its first entry is addressed by its text, which no History
            // row and no other day holds.
            static let memoryDayFigure = "4 · 54 words"
            static let memoryDayRow = UIQuery.labelContains(
                "Pin the memory folder path in Diagnostics the same way the other storage paths are pinned."
            )
            // 2025-05-28, `UIFixtures.rememberedDay`, one Earlier Day past that: four
            // dictations and two notes.
            static let rememberedDayFigure = "6 · 73 words"

            // Every thread row carries `journal.threads.row`, so the omp session's row is
            // addressed by the title its label leads with, which no other label holds.
            static let agentThreadRow = UIQuery.all([
                .id("journal.threads.row"),
                .labelContains(UIFixtures.agentSessionTitle),
            ])
            // The populated fixture's other thread, the Claude Code session row 5 is linked to
            // by its words. It has no title, so its label leads with its project; the agent's
            // name in its summary is what no other thread row's label holds.
            static let wordsThreadRow = UIQuery.all([
                .id("journal.threads.row"),
                .labelContains(CodingAgent.claudeCode.displayName),
            ])
            static let threadRows = UIQuery.id("journal.threads.row")
            // An open thread's id and folder sit inside its Details fold, which every newly
            // opened thread starts shut, so neither is in the tree until the fold is pressed.
            // The fold's label shows while it is shut, so a flow waits on it for the page.
            static let threadDetails = UIQuery.id("journal.threads.details")
            static let threadSession = UIQuery.id("journal.threads.session")
            static let threadFolder = UIQuery.id("journal.threads.folder")
            static let threadTimeline = UIQuery.id("journal.threads.timeline")
            static let clearAgentFilter = UIQuery.id("sessions.agent-filter.clear")

            // Journal ▸ Notes. Every note row's label reads "<time>, note, <text>", so the
            // mark between commas counts note rows and a note's text addresses one of them.
            static let notesSearch = UIQuery.id("journal.notes.search")
            static let clearNotesSearch = UIQuery.id("journal.notes.search.clear")
            static let noteRows = UIQuery.labelContains(", note, ")

            static func noteRow(_ text: String) -> UIQuery {
                .labelContains(text)
            }

            // Journal ▸ Topics. Every topic row carries `journal.topics.row` and a label
            // that reads "<name>, <count> entries, <summary>", so a row is addressed by the
            // identifier together with its name, and its count is read from its label.
            static let newTopicName = UIQuery.id("journal.topics.new.name")
            static let newTopicSummary = UIQuery.id("journal.topics.new.summary")
            static let addTopic = UIQuery.id("journal.topics.add")
            static let cancelTopic = UIQuery.id("journal.topics.new.cancel")
            static let addTopicRefusal = UIQuery.id("journal.topics.new.refusal")
            // The unsaved topic's row at the head of the list, while New Topic's page is open.
            static let topicDraft = UIQuery.id("journal.topics.draft")
            static let topicRows = UIQuery.id("journal.topics.row")
            static let topicName = UIQuery.id("journal.topics.name")
            static let topicSummary = UIQuery.id("journal.topics.summary")
            static let topicSave = UIQuery.id("journal.topics.save")
            static let addedTopicName = "Release notes"
            static let addedTopicSummary = "What ships in each version."
            // The refusal names the topic already holding the name, in curly quotes.
            static let duplicateTopicRefusal = "\u{201C}Release notes\u{201D} already covers that name."

            static func topicRow(_ name: String) -> UIQuery {
                .all([topicRows, .labelContains(name)])
            }

            /// A topic row's whole label, the facts its second line shows, in order.
            static func topicRowLabel(_ topic: MemoryTopic, entries: Int) -> String {
                "\(topic.name), \(entries) \(entries == 1 ? "entry" : "entries"), \(topic.summary)"
            }

            // Journal agent notes and the three prompts that ask for them. A note row is one
            // element that contains its caption, "<title> · by <author> · <date> <time>", as
            // the value of a text node, so a note is addressed by its row identifier together
            // with that caption. A prompt's confirmation is its page's toast, one element per
            // lens with an identifier of its own, which shows only while a copy is confirmed.
            static let rewindAgentNote = UIQuery.id("journal.rewind.agent-note")
            static let topicAgentNote = UIQuery.id("journal.topics.agent-note")
            static let threadAgentNote = UIQuery.id("journal.threads.agent-note")
            static let recapPrompt = UIQuery.id("journal.rewind.recap-prompt")
            static let synthesisPrompt = UIQuery.id("journal.topics.synthesis-prompt")
            static let outcomePrompt = UIQuery.id("journal.threads.outcome-prompt")
            static let rewindCopied = UIQuery.id("journal.rewind.copied")
            static let topicsCopied = UIQuery.id("journal.topics.copied")
            static let threadsCopied = UIQuery.id("journal.threads.copied")
            static let newTopic = UIQuery.id("journal.topics.new")

            /// The caption `JournalAgentNoteRow` gives `note`, built by the row's own rule in
            /// the calendar the harness pins, so the flows and the lens cannot disagree on it.
            @MainActor
            static func agentNoteCaption(_ note: AgentNote) -> String {
                JournalAgentNoteRow.caption(of: note, calendar: UIFixtures.pinnedCalendar)
            }

            // The menu's "Take a Note" row, offered only between sessions, and what its
            // status line and report say while a note records and once it is saved.
            static let takeNote = UIQuery.id("menu.take-note")
            static let noteTargetLine = "Will save as a note"
            static let noteSavedLabel = "Note saved"
            static let noteSavedDetail = "Saved to memory. Nothing was pasted or copied."

            // The menu report's link line: a borderless button naming the thread the
            // reported paste was linked to, or a caption saying why it was not.
            static let reportThread = UIQuery.id("menu.report.thread")
            static let reportUnlinked = UIQuery.id("menu.report.unlinked")

            static let addTermButton = UIQuery.id("glossary.add-term")
            static let glossarySearch = UIQuery.id("glossary.search.field")
            static let termCanonical = UIQuery.id("glossary.term.canonical")
            static let termAddForm = UIQuery.id("glossary.term.add-form")
            static let termSave = UIQuery.id("glossary.term.save")
            static let termRemove = UIQuery.id("glossary.term.remove")
            static let draftCanonical = UIQuery.id("glossary.draft.canonical")
            static let draftAddForm = UIQuery.id("glossary.draft.add-form")
            static let draftSave = UIQuery.id("glossary.draft.save")
            static let draftCancel = UIQuery.id("glossary.draft.cancel")
            // The unsaved term's row at the head of the list, while its page is open.
            static let draftRow = UIQuery.id("glossary.draft.row")
            // A row is addressed by its term id, which is the canonical spelling
            // for a term created without one.
            static let bundledTermRow = UIQuery.id("glossary.term.kubectl")
            static let addedTermRow = UIQuery.id("glossary.term.FlowTerm")
            static let taughtTermRow = UIQuery.id("glossary.term.term-neurodock")
            static let importedTermRow = UIQuery.id("glossary.term.term-voiceourbench")
            // The Glossary sidebar: the three origins, and Suggestions while any are pending.
            static let allTermsOrigin = UIQuery.id("glossary.origin.all")
            static let yoursOrigin = UIQuery.id("glossary.origin.yours")
            static let builtInOrigin = UIQuery.id("glossary.origin.builtin")
            static let suggestionsItem = UIQuery.id("glossary.suggestions")

            /// One of the buttons a suggestion's page offers: `accept`, `ignore` or `reject`.
            static func suggestion(_ id: String, _ action: String) -> UIQuery {
                .id("suggestion.\(id).\(action)")
            }

            /// A Settings sidebar item, by its section's raw value. Settings shows one
            /// section's page at a time and only that page's controls are in the tree, so a
            /// flow presses the section before it reads any of them. The selected item
            /// carries `.isSelected`.
            static func settingsSection(_ rawValue: String) -> UIQuery {
                .id("settings.section.\(rawValue)")
            }

            static let microphonePicker = UIQuery.id("voice.microphone.picker")

            /// A Settings ▸ Appearance tile, by `ConsoleAppearance` raw value. The chosen
            /// tile carries `.isSelected`.
            static func appearanceTile(_ appearance: ConsoleAppearance) -> UIQuery {
                .id("settings.appearance.\(appearance.rawValue)")
            }

            /// A Settings ▸ Appearance accent swatch, by `ConsoleAccent` raw value. The chosen
            /// swatch carries `.isSelected`.
            static func accentSwatch(_ accent: ConsoleAccent) -> UIQuery {
                .id("settings.accent.\(accent.rawValue)")
            }

            static let historyArm = UIQuery.id("system.history.arm")

            static let autoStop = UIQuery.id("voice.auto-stop.toggle")
            static let autoStopDuration = UIQuery.id("voice.auto-stop.duration")
            static let cleanup = UIQuery.id("voice.cleanup.toggle")

            static let backendRecheck = UIQuery.id("system.backend.recheck")
            static let backendStatus = UIQuery.id("system.backend.status")

            static let memoryToggle = UIQuery.id("system.memory.toggle")
            static let memoryCopyInstructions = UIQuery.id("system.memory.copy-instructions")
            // Copy Install Command writes the skill through the coordinator's seam before it
            // copies; this caption replaces the row's own when that write fails.
            static let memoryCopySkillCommand = UIQuery.id("system.memory.copy-skill-command")
            static let skillWriteFailure = "The skill could not be written on this Mac."
            // Settings confirms every copy in the page toast, which shows only while a copy
            // is confirmed.
            static let settingsCopied = UIQuery.id("settings.copied")

            // Settings ▸ Memory's sorting rows. The harness key source has no environment
            // and an absent key file, so every fixture starts with no key on every Mac.
            static let organizerToggle = UIQuery.id("system.organizer.toggle")
            static let organizerKeyStatus = UIQuery.id("system.organizer.key.status")
            static let organizerKeyField = UIQuery.id("system.organizer.key.field")
            static let organizerKeySave = UIQuery.id("system.organizer.key.save")
            static let organizerKeyRemove = UIQuery.id("system.organizer.key.remove")
            // A made-up key: what reaches the journal is the step that typed it, and the
            // checks prove it reaches no node of the tree.
            static let fakeTypeSafeKey = "test-key-123"

            // Settings ▸ Privacy's linking switch and Link Earlier Dictations, whose caption
            // says what the button does until a run reports.
            static let agentLinksToggle = UIQuery.id("system.agent-links.toggle")
            static let linkEarlier = UIQuery.id("system.agent.link-earlier")
            static let linkEarlierBeforeRun =
                "Finds earlier dictations whose exact words reached one omp or Claude Code session on this Mac, "
                + "and links them to it."

            /// What a run on `UIFixtures.history` reports: its rows picked the way
            /// `linkEarlierDictations()` picks them, one of them in the harness reader's table,
            /// and the sentence the run's own `summary` builds, so the flow cannot drift from
            /// either the fixture or the wording.
            @MainActor
            static var linkEarlierSummary: String {
                let lookedFor = UIFixtures.history.filter { row in
                    row.agentSession == nil
                        && row.unlinked != .removedByYou
                        && PromptEvidence.words(row.text) >= PromptEvidence.minimumWords
                }
                return LinkEarlierRun(isRunning: false, linked: 1, notFound: lookedFor.count - 1, ambiguous: 0)
                    .summary
            }

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

            /// The trigger row: the first row of the Dictation page, which Settings
            /// opens on.
            static let settingsContent = UIQuery.id("capture.hotkey")
            static let glossaryContent = glossarySearch
            static let historyContent = sessionSearch
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

            // Settings ▸ Island. Coats and looks share two labels, Oil Slick and Chameleon,
            // so every coat radio and look card is addressed inside its own group. A look
            // card is a button that carries `.isSelected` when its look is the committed one.
            static let islandShowroom = UIQuery.id("island.showroom")
            static let islandLookMark = UIQuery.id("island.showroom.look")
            static let islandAnotherRoom = UIQuery.id("island.showroom.room")
            static let islandMaterialFold = UIQuery.id("island.group.material")
            static let islandLightingFold = UIQuery.id("island.group.lighting")
            static let islandBodyFold = UIQuery.id("island.group.body")
            static let islandMotionFold = UIQuery.id("island.group.motion")
            static let islandFilm = UIQuery.id("island.material.film")
            static let islandCandy = UIQuery.id("island.material.candy")
            static let islandFinish = UIQuery.id("island.material.finish")
            static let islandMaterialStock = UIQuery.id("island.material.stock")
            static let islandTemperature = UIQuery.id("island.lighting.temperature")
            static let islandUnderglow = UIQuery.id("island.lighting.underglow")
            static let islandUnderglowColor = UIQuery.id("island.lighting.underglow.color")
            static let islandUnderglowStrength = UIQuery.id("island.lighting.underglow.strength")
            static let islandSize = UIQuery.id("island.body.size")
            static let islandTempo = UIQuery.id("island.motion.tempo")
            static let islandSurprise = UIQuery.id("island.look.surprise")
            static let islandPositionDock = UIQuery.id("island.position.dock")
            static let islandFreePlacementCaption =
                "Kept where you let it go, at the same relative spot on each display."
            static let islandDockedPlacementCaption =
                "On a display with a camera notch the island frames the notch; "
                + "elsewhere it floats centered near the top. Drag it 24 pt to tear it off."

            static func islandLook(_ look: IslandLook) -> UIQuery {
                .within(.id("island.look"), .label(look.displayName))
            }

            static func islandCoat(_ coat: IslandCoat) -> UIQuery {
                .within(.id("island.material.coat"), .label(coat.displayName))
            }

            static func islandRoom(_ room: MercuryWorld) -> UIQuery {
                .within(.id("island.lighting.room"), .label(room.displayName))
            }
        }

        /// Unfiltered declaration order is execution order and groups journeys by surface.
        static func everything() -> [UIFlow] {
            sessionFlows + journalFlows + voiceFlows + islandFlows + glossaryFlows + systemFlows
                + consoleFlows + menuFlows + overlayFlows
        }

        /// Selection goes through `UIHarnessRequest.matches(id:tags:)`, the one spelling of
        /// `--only`/`--except` shared with the scene catalog. Nothing is excluded unless
        /// `--except` asks for it: every flow drives the one shipping render path.
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
                        .wait(.element(.label("Nothing matches “\(noMatchQuery)”"))),
                        .check(
                            "no-results",
                            [
                                .text(.equals("0 of 10 dictations match"), .exactly(1)),
                                .count(.label("Nothing matches “\(noMatchQuery)”"), .exactly(1)),
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
                        .check("filtered", [.text(.equals("0 of 10 dictations match"), .exactly(1))]),
                        .act(.press(Selector.clearSessionSearch)),
                        .wait(.absent(Selector.clearSessionSearch)),
                        .wait(.element(Selector.newestTranscript)),
                        .check(
                            "restored",
                            [
                                .value(Selector.sessionSearch, .isEmpty),
                                .absent(.label("Nothing matches “\(noMatchQuery)”")),
                                .exists(Selector.newestTranscript),
                                .model(.recentSessionCount, .equals("10")),
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
                                .value(Selector.rawFold, .equals("Collapsed")),
                                .absent(Selector.newestRaw),
                            ]
                        ),
                        .act(.press(Selector.rawFold)),
                        .wait(.element(Selector.newestRaw)),
                        .check(
                            "unfolded",
                            [
                                .count(Selector.rawFold, .exactly(1)),
                                .value(Selector.rawFold, .equals("Expanded")),
                                .count(Selector.newestRaw, .exactly(1)),
                            ]
                        ),
                        .act(.press(Selector.rawFold)),
                        .wait(.absent(Selector.newestRaw)),
                        .check(
                            "refolded",
                            [
                                .count(Selector.rawFold, .exactly(1)),
                                .value(Selector.rawFold, .equals("Collapsed")),
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
                                .value(Selector.detailsFold, .equals("Collapsed")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .exists(Selector.rawFold),
                                .value(Selector.rawFold, .equals("Collapsed")),
                            ]
                        ),
                        .act(.press(Selector.detailsFold)),
                        .wait(.element(Selector.detailsTarget)),
                        .check(
                            "unfolded",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("Expanded")),
                                .count(Selector.detailsTarget, .exactly(1)),
                                .count(Selector.detailsTimings, .exactly(1)),
                                .count(Selector.detailsLeastSure, .exactly(1)),
                                .value(Selector.rawFold, .equals("Collapsed")),
                            ]
                        ),
                        .act(.press(Selector.detailsFold)),
                        .wait(.absent(Selector.detailsTarget)),
                        .check(
                            "refolded",
                            [
                                .count(Selector.detailsFold, .exactly(1)),
                                .value(Selector.detailsFold, .equals("Collapsed")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .value(Selector.rawFold, .equals("Collapsed")),
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
                                .value(Selector.detailsFold, .equals("Collapsed")),
                                .absent(Selector.detailsTarget),
                                .absent(Selector.detailsTimings),
                                .absent(Selector.detailsLeastSure),
                                .absent(Selector.rawFold),
                            ]
                        ),
                    ]),
                // A bound transcript answers where its text went: a Sent fold, shut
                // until asked for, holds the prompt as its agent received it, and the
                // Details fold names the agent session.
                UIFlow(
                    id: "sessions.agent-link",
                    title: "A linked transcript shows its agent session and the text that was sent",
                    tags: ["sessions", "console", "detail"],
                    host: .console(.history),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.agentRow)),
                        .wait(.element(Selector.agentTranscript)),
                        .check(
                            "opened",
                            [
                                .count(Selector.sentFold, .exactly(1)),
                                .value(Selector.sentFold, .equals("Collapsed")),
                                .absent(Selector.sentTextNode),
                                .absent(Selector.rawFold),
                            ]
                        ),
                        .act(.press(Selector.sentFold)),
                        .wait(.element(Selector.sentTextNode)),
                        .check(
                            "sent",
                            [
                                .value(Selector.sentFold, .equals("Expanded")),
                                .count(Selector.sentTextNode, .exactly(1)),
                            ]
                        ),
                        .act(.press(Selector.detailsFold)),
                        .wait(.element(Selector.detailsAgent)),
                        .check(
                            "agent",
                            [
                                .count(Selector.detailsAgent, .exactly(1)),
                                .count(Selector.agentTitle, .exactly(1)),
                                .value(Selector.agentTitle, .equals("omp · Harness offscreen capture")),
                            ]
                        ),
                    ]),
            ]
        }

        // MARK: Journal

        private static var journalFlows: [UIFlow] {
            [
                // Rewind opens on the newest day that holds an entry, so Later is disabled
                // until Earlier has moved off it; a step back and forth must land on the
                // same day's figure it left.
                UIFlow(
                    id: "journal.rewind.navigate",
                    title: "Rewind steps to the previous day and back",
                    tags: ["journal", "console", "rewind"],
                    host: .console(.history, journalLens: .rewind),
                    fixture: .static(.populated),
                    steps: [
                        .wait(.element(Selector.rewindEntries(Selector.newestDayFigure))),
                        .check(
                            "newest",
                            [
                                .exists(Selector.rewindEntries(Selector.newestDayFigure)),
                                .enabled(Selector.rewindEarlier, true),
                                .enabled(Selector.rewindLater, false),
                            ]
                        ),
                        .act(.press(Selector.rewindEarlier)),
                        .wait(.element(Selector.rewindEntries(Selector.earlierDayFigure))),
                        .check(
                            "earlier",
                            [
                                .exists(Selector.rewindEntries(Selector.earlierDayFigure)),
                                .absent(Selector.rewindEntries(Selector.newestDayFigure)),
                                .enabled(Selector.rewindLater, true),
                            ]
                        ),
                        .act(.press(Selector.rewindLater)),
                        .wait(.element(Selector.rewindEntries(Selector.newestDayFigure))),
                        .check(
                            "returned",
                            [
                                .exists(Selector.rewindEntries(Selector.newestDayFigure)),
                                .absent(Selector.rewindEntries(Selector.earlierDayFigure)),
                                .enabled(Selector.rewindLater, false),
                            ]
                        ),
                    ]),
                // A search covers every day at once and turns the list into matches while the
                // page keeps the day it shows; clearing it brings the days back.
                UIFlow(
                    id: "journal.rewind.search",
                    title: "Rewind search counts matches on every day and clears back to the days",
                    tags: ["journal", "console", "rewind", "search"],
                    host: .console(.history, journalLens: .rewind),
                    fixture: .static(.populated),
                    steps: [
                        .act(.type(Selector.rewindQuery, into: Selector.rewindSearch)),
                        .wait(.element(.value(Selector.rewindMatchCaption))),
                        .check(
                            "matched",
                            [
                                .text(.equals(Selector.rewindMatchCaption), .exactly(1)),
                                .count(Selector.titleMatchRow, .exactly(1)),
                                .exists(Selector.clearRewindSearch),
                                .exists(Selector.rewindEntries(Selector.newestDayFigure)),
                            ]
                        ),
                        .act(.press(Selector.clearRewindSearch)),
                        .wait(.absent(Selector.clearRewindSearch)),
                        .wait(.element(Selector.rewindEntries(Selector.newestDayFigure))),
                        .check(
                            "cleared",
                            [
                                .value(Selector.rewindSearch, .isEmpty),
                                .absent(.value(Selector.rewindMatchCaption)),
                                .absent(Selector.titleMatchRow),
                                .exists(Selector.rewindEntries(Selector.newestDayFigure)),
                            ]
                        ),
                    ]),
                rewindMemoryDaysFlow,
                // Threads opens on its newest thread, a row press selects another thread's
                // page, and a press on the selected row keeps it: the page names the session it
                // belongs to once its Details fold is opened, and the fold stays open.
                UIFlow(
                    id: "journal.threads.open",
                    title: "A thread row selects its session's page and a second press keeps it",
                    tags: ["journal", "console", "threads"],
                    host: .console(.history, journalLens: .threads),
                    fixture: .static(.populated),
                    steps: [
                        .wait(.element(Selector.agentThreadRow)),
                        .wait(.element(Selector.threadDetails)),
                        .check(
                            "newest",
                            [
                                .count(Selector.threadRows, .exactly(2)),
                                .selected(Selector.wordsThreadRow, true),
                                .selected(Selector.agentThreadRow, false),
                                .count(Selector.threadDetails, .exactly(1)),
                                .absent(Selector.threadSession),
                            ]
                        ),
                        .act(.press(Selector.agentThreadRow)),
                        .wait(.element(.all([.role("AXHeading"), .label(UIFixtures.agentSessionTitle)]))),
                        .check(
                            "selected",
                            [
                                .count(Selector.threadDetails, .exactly(1)),
                                .value(Selector.threadDetails, .equals("Collapsed")),
                                .absent(Selector.threadSession),
                                .selected(Selector.agentThreadRow, true),
                                .selected(Selector.wordsThreadRow, false),
                            ]
                        ),
                        .act(.press(Selector.threadDetails)),
                        .wait(.element(Selector.threadSession)),
                        .check(
                            "details",
                            [
                                .count(Selector.threadSession, .exactly(1)),
                                .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                                .selected(Selector.agentThreadRow, true),
                            ]
                        ),
                        .act(.press(Selector.agentThreadRow)),
                        .wait(.element(Selector.threadSession)),
                        .check(
                            "kept",
                            [
                                .value(Selector.threadDetails, .equals("Expanded")),
                                .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                                .selected(Selector.agentThreadRow, true),
                                .count(Selector.threadRows, .exactly(2)),
                            ]
                        ),
                    ]),
                threadsDetailsFlow,
                // Show in Timeline leaves the lens for Timeline narrowed to the thread's
                // rows, the state a row's context menu reaches, which this window cannot open.
                UIFlow(
                    id: "journal.threads.show-in-timeline",
                    title: "An open thread shows its rows in Timeline, filtered to its session",
                    tags: ["journal", "console", "threads"],
                    host: .console(.history, journalLens: .threads),
                    fixture: .static(.populated),
                    steps: [
                        .wait(.element(Selector.agentThreadRow)),
                        .act(.press(Selector.agentThreadRow)),
                        .wait(.element(Selector.threadTimeline)),
                        .check(
                            "opened",
                            [
                                .count(Selector.threadTimeline, .exactly(1)),
                                .absent(Selector.threadSession),
                            ]
                        ),
                        .act(.press(Selector.threadDetails)),
                        .wait(.element(Selector.threadSession)),
                        .check(
                            "details",
                            [
                                .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                                .count(Selector.threadTimeline, .exactly(1)),
                            ]
                        ),
                        .act(.press(Selector.threadTimeline)),
                        .wait(.element(Selector.sessionSearch)),
                        .check(
                            "timeline",
                            [
                                .count(Selector.sessionSearch, .exactly(1)),
                                .exists(Selector.clearAgentFilter),
                                .absent(Selector.threadRows),
                            ]
                        ),
                    ]),
                routeThreadFlow,
                notesSearchFlow,
                topicsAddFlow,
                topicsCreateFlow,
                topicsCancelFlow,
                topicsOpenFlow,
                rewindRecapPromptFlow,
                topicsSynthesisPromptFlow,
                threadsOutcomePromptFlow,
            ]
        }

        /// The menu's thread line leaves a request on the coordinator and opens the console;
        /// the console moves to the Journal and the Journal opens the thread in Threads, then
        /// consumes the request. The fixture states the request as the console finds it when
        /// it opens because of one, and the host opens on Home, so the move to the Journal is
        /// the window's own and not the host's.
        private static var routeThreadFlow: UIFlow {
            UIFlow(
                id: "journal.route.thread",
                title: "A pending thread request opens the console on that thread in Threads",
                tags: ["journal", "console", "threads", "agent-link"],
                host: .console(.home),
                fixture: .static(.threadRequested),
                steps: [
                    // The fold is shut on a thread the route opens, so the page is waited on
                    // by its label and the id is read only after the fold is pressed.
                    .wait(.element(Selector.threadDetails)),
                    .check(
                        "routed",
                        [
                            .value(Selector.tab(.history), .equals("1")),
                            .value(Selector.tab(.home), .equals("0")),
                            .count(Selector.threadDetails, .exactly(1)),
                            .value(Selector.threadDetails, .equals("Collapsed")),
                            .selected(Selector.agentThreadRow, true),
                            .model(.pendingJournalThread, .isEmpty),
                        ]
                    ),
                    .act(.press(Selector.threadDetails)),
                    .wait(.element(Selector.threadSession)),
                    .check(
                        "details",
                        [
                            .count(Selector.threadSession, .exactly(1)),
                            .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                        ]
                    ),
                ])
        }

        /// The id and folder sit in a fold that every opened thread starts shut, so a press
        /// shows them and opening another thread shuts it again: the second page reads the
        /// same as the first until its own fold is pressed. The populated fixture's two threads
        /// are the omp session and the Claude Code session row 5 is linked to by its words.
        private static var threadsDetailsFlow: UIFlow {
            let folder = "/Users/harness/voiceour"
            return UIFlow(
                id: "journal.threads.details",
                title: "An open thread's Details fold shows its id and folder and shuts when another thread opens",
                tags: ["journal", "console", "threads"],
                host: .console(.history, journalLens: .threads),
                fixture: .static(.populated),
                steps: [
                    .wait(.element(Selector.agentThreadRow)),
                    .act(.press(Selector.agentThreadRow)),
                    .wait(.element(Selector.threadDetails)),
                    .check(
                        "folded",
                        [
                            .selected(Selector.agentThreadRow, true),
                            .count(Selector.threadDetails, .exactly(1)),
                            .value(Selector.threadDetails, .equals("Collapsed")),
                            .absent(Selector.threadSession),
                            .absent(Selector.threadFolder),
                        ]
                    ),
                    .act(.press(Selector.threadDetails)),
                    .wait(.element(Selector.threadSession)),
                    .check(
                        "unfolded",
                        [
                            .value(Selector.threadDetails, .equals("Expanded")),
                            .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                            .value(Selector.threadFolder, .equals(folder)),
                        ]
                    ),
                    .act(.press(Selector.wordsThreadRow)),
                    .wait(.absent(Selector.threadSession)),
                    .check(
                        "switched",
                        [
                            .selected(Selector.wordsThreadRow, true),
                            .selected(Selector.agentThreadRow, false),
                            .count(Selector.threadDetails, .exactly(1)),
                            .value(Selector.threadDetails, .equals("Collapsed")),
                            .absent(Selector.threadSession),
                            .absent(Selector.threadFolder),
                        ]
                    ),
                    .act(.press(Selector.threadDetails)),
                    .wait(.element(Selector.threadSession)),
                    .check(
                        "unfolded-again",
                        [
                            .value(Selector.threadDetails, .equals("Expanded")),
                            .value(Selector.threadSession, .equals(UIFixtures.wordsLinkedSession.sessionId)),
                            .value(Selector.threadFolder, .equals(folder)),
                        ]
                    ),
                ]
            )
        }

        /// Rewind's days come from memory as well as History, so Earlier Day walks on past
        /// History's oldest day into the days only memory holds. The walk waits on every
        /// day's figure, so a day memory failed to add, or a History day it hid, stops it
        /// on the step where the figure first differs.
        private static var rewindMemoryDaysFlow: UIFlow {
            let figures: [String] =
                [Selector.earlierDayFigure] + Selector.olderHistoryDayFigures + [Selector.memoryDayFigure]
            let walk: [UIFlowStep] = figures.flatMap { figure -> [UIFlowStep] in
                [
                    .act(.press(Selector.rewindEarlier)),
                    .wait(.element(Selector.rewindEntries(figure))),
                ]
            }
            let opened: [UIFlowStep] = [.wait(.element(Selector.rewindEntries(Selector.newestDayFigure)))]
            let checked: [UIFlowStep] = [
                .check(
                    "older-than-history",
                    [
                        .exists(Selector.rewindEntries(Selector.memoryDayFigure)),
                        .count(Selector.memoryDayRow, .exactly(1)),
                        .enabled(Selector.rewindLater, true),
                        .enabled(Selector.rewindEarlier, true),
                    ]
                )
            ]
            return UIFlow(
                id: "journal.rewind.memory-days",
                title: "Rewind steps past History's oldest day into days only memory holds",
                tags: ["journal", "console", "rewind", "memory"],
                host: .console(.history, journalLens: .rewind),
                fixture: .static(.remembered),
                steps: opened + walk + checked
            )
        }

        /// An agent's recap shows under the day its front matter names, with its title and
        /// author, and not on the next day that holds an entry. Copy Recap Prompt writes once
        /// through the harness pasteboard seam and shows the page's toast. The prompt names the
        /// fixture's scratch memory folder, so its text is not checked; only that exactly one
        /// write happened.
        private static var rewindRecapPromptFlow: UIFlow {
            let recap = UIQuery.within(
                Selector.rewindAgentNote,
                .value(Selector.agentNoteCaption(UIFixtures.rememberedDayRecap))
            )
            // The same walk as `journal.rewind.memory-days`, one day further, waiting on
            // every day's figure so the presses never outrun the page.
            let figures: [String] =
                [Selector.earlierDayFigure] + Selector.olderHistoryDayFigures
                + [Selector.memoryDayFigure, Selector.rememberedDayFigure]
            let walk: [UIFlowStep] = figures.flatMap { figure -> [UIFlowStep] in
                [
                    .act(.press(Selector.rewindEarlier)),
                    .wait(.element(Selector.rewindEntries(figure))),
                ]
            }
            let opened: [UIFlowStep] = [
                .wait(.element(Selector.rewindEntries(Selector.newestDayFigure))),
                .check(
                    "newest",
                    [
                        .exists(Selector.recapPrompt),
                        .absent(Selector.rewindCopied),
                        .model(.pasteboardWrites, .equals("0")),
                    ]
                ),
            ]
            let copied: [UIFlowStep] = [
                // Notes load off the main actor, so the row is waited on, not assumed.
                .wait(.element(recap)),
                .check(
                    "recap",
                    [
                        .exists(Selector.rewindEntries(Selector.rememberedDayFigure)),
                        .exists(recap),
                        .enabled(Selector.recapPrompt, true),
                        .absent(Selector.rewindCopied),
                        .model(.pasteboardWrites, .equals("0")),
                    ]
                ),
                .act(.press(Selector.recapPrompt)),
                .wait(.element(Selector.rewindCopied)),
                .check(
                    "copied",
                    [
                        .exists(Selector.rewindCopied),
                        .model(.pasteboardWrites, .equals("1")),
                        .exists(recap),
                    ]
                ),
                // Back one day, once the recap has been seen to load: the note stays with
                // the day it names.
                .act(.press(Selector.rewindLater)),
                .wait(.element(Selector.rewindEntries(Selector.memoryDayFigure))),
                .check(
                    "later-day",
                    [
                        .exists(Selector.rewindEntries(Selector.memoryDayFigure)),
                        .absent(Selector.rewindAgentNote),
                        .model(.pasteboardWrites, .equals("1")),
                    ]
                ),
            ]
            return UIFlow(
                id: "journal.rewind.recap-prompt",
                title: "Rewind shows an agent's recap under its day and copies the day's recap prompt",
                tags: ["journal", "console", "rewind", "memory", "agent-notes", "clipboard"],
                host: .console(.history, journalLens: .rewind),
                fixture: .static(.remembered),
                steps: opened + walk + copied
            )
        }

        /// An agent's synthesis shows on the page of the topic its front matter names, which
        /// Topics opens on because it holds the most entries, and on no other topic's page.
        /// Copy Synthesis Prompt writes once through the harness pasteboard seam and shows the
        /// page's toast; the prompt names the scratch memory folder, so its text is not checked.
        private static var topicsSynthesisPromptFlow: UIFlow {
            let topic = UIFixtures.memoryFolderTopic
            let row = Selector.topicRow(topic.name)
            let otherRow = Selector.topicRow("Planning")
            let synthesis = UIQuery.within(
                Selector.topicAgentNote,
                .value(Selector.agentNoteCaption(UIFixtures.memoryFolderSynthesis))
            )
            return UIFlow(
                id: "journal.topics.synthesis-prompt",
                title: "The first topic shows an agent's synthesis and copies the topic's synthesis prompt",
                tags: ["journal", "console", "topics", "memory", "agent-notes", "clipboard"],
                host: .console(.history, journalLens: .topics),
                fixture: .static(.remembered),
                steps: [
                    .wait(.element(row)),
                    .wait(.element(Selector.topicName)),
                    // Notes load off the main actor, so the row is waited on, not assumed.
                    .wait(.element(synthesis)),
                    .check(
                        "opened",
                        [
                            .selected(row, true),
                            .exists(synthesis),
                            .enabled(Selector.synthesisPrompt, true),
                            .absent(Selector.topicsCopied),
                            .model(.pasteboardWrites, .equals("0")),
                        ]
                    ),
                    .act(.press(Selector.synthesisPrompt)),
                    .wait(.element(Selector.topicsCopied)),
                    .check(
                        "copied",
                        [
                            .exists(Selector.topicsCopied),
                            .model(.pasteboardWrites, .equals("1")),
                            .exists(synthesis),
                        ]
                    ),
                    .act(.press(otherRow)),
                    .wait(.absent(synthesis)),
                    .check(
                        "elsewhere",
                        [
                            .selected(otherRow, true),
                            .absent(Selector.topicAgentNote),
                            .model(.pasteboardWrites, .equals("1")),
                        ]
                    ),
                ]
            )
        }

        /// An agent's outcome note shows on the page of the thread its `session` names and
        /// not on the newest thread's page, where Threads opens. Copy Outcome Prompt writes
        /// once through the harness pasteboard seam and shows the page's toast; the prompt
        /// names the scratch memory folder, so its text is not checked. The page's id is read
        /// last, from its Details fold, so the note and the prompt are checked on the page as
        /// it opens.
        private static var threadsOutcomePromptFlow: UIFlow {
            let outcome = UIQuery.within(
                Selector.threadAgentNote,
                .value(Selector.agentNoteCaption(UIFixtures.agentSessionOutcome))
            )
            return UIFlow(
                id: "journal.threads.outcome-prompt",
                title: "A thread shows its agent's outcome note and copies the thread's outcome prompt",
                tags: ["journal", "console", "threads", "memory", "agent-notes", "clipboard"],
                host: .console(.history, journalLens: .threads),
                fixture: .static(.remembered),
                steps: [
                    .wait(.element(Selector.agentThreadRow)),
                    .wait(.element(Selector.threadDetails)),
                    .check(
                        "newest",
                        [
                            .selected(Selector.agentThreadRow, false),
                            .absent(Selector.threadSession),
                            .absent(Selector.threadAgentNote),
                            .model(.pasteboardWrites, .equals("0")),
                        ]
                    ),
                    .act(.press(Selector.agentThreadRow)),
                    // Notes load off the main actor, so the row is waited on, not assumed.
                    .wait(.element(outcome)),
                    .check(
                        "opened",
                        [
                            .selected(Selector.agentThreadRow, true),
                            .value(Selector.threadDetails, .equals("Collapsed")),
                            .absent(Selector.threadSession),
                            .count(Selector.threadAgentNote, .exactly(1)),
                            .exists(outcome),
                            .enabled(Selector.outcomePrompt, true),
                            .absent(Selector.threadsCopied),
                            .model(.pasteboardWrites, .equals("0")),
                        ]
                    ),
                    .act(.press(Selector.outcomePrompt)),
                    .wait(.element(Selector.threadsCopied)),
                    .check(
                        "copied",
                        [
                            .exists(Selector.threadsCopied),
                            .model(.pasteboardWrites, .equals("1")),
                            .exists(outcome),
                        ]
                    ),
                    .act(.press(Selector.threadDetails)),
                    .wait(.element(Selector.threadSession)),
                    .check(
                        "details",
                        [
                            .value(Selector.threadSession, .equals(UIFixtures.agentSession.sessionId)),
                            .model(.pasteboardWrites, .equals("1")),
                        ]
                    ),
                ]
            )
        }

        /// The Notes search runs over every note at once: a word one note holds leaves that
        /// note's row alone, and clearing the search brings every note back. Which rows match
        /// is read from the fixture's own texts, so the query and the rows cannot drift apart.
        private static var notesSearchFlow: UIFlow {
            let query = UIFixtures.rememberedNoteQuery
            let texts = UIFixtures.rememberedNoteTexts
            let matched = texts.filter { $0.lowercased().contains(query) }
            let hidden = texts.filter { !$0.lowercased().contains(query) }
            let total = String(texts.count)
            let everyRow: [UIExpectation] = texts.map { .count(Selector.noteRow($0), .exactly(1)) }
            let matchedRows: [UIExpectation] = matched.map { .count(Selector.noteRow($0), .exactly(1)) }
            let hiddenRows: [UIExpectation] = hidden.map { .absent(Selector.noteRow($0)) }
            let listedChecks: [UIExpectation] = [
                .count(Selector.noteRows, .exactly(texts.count)),
                .absent(Selector.clearNotesSearch),
                .model(.noteCount, .equals(total)),
            ]
            let matchedChecks: [UIExpectation] = [
                .count(Selector.noteRows, .exactly(1)),
                .value(Selector.notesSearch, .equals(query)),
                .exists(Selector.clearNotesSearch),
                .model(.noteCount, .equals(total)),
            ]
            let restoredChecks: [UIExpectation] = [
                .value(Selector.notesSearch, .isEmpty),
                .count(Selector.noteRows, .exactly(texts.count)),
            ]

            var steps: [UIFlowStep] = texts.map { .wait(.element(Selector.noteRow($0))) }
            steps.append(.check("listed", listedChecks + everyRow))
            steps.append(.act(.type(query, into: Selector.notesSearch)))
            steps.append(.wait(.element(Selector.clearNotesSearch)))
            steps += hidden.map { UIFlowStep.wait(.absent(Selector.noteRow($0))) }
            steps.append(.check("matched", matchedChecks + matchedRows + hiddenRows))
            steps.append(.act(.press(Selector.clearNotesSearch)))
            steps.append(.wait(.absent(Selector.clearNotesSearch)))
            steps += hidden.map { UIFlowStep.wait(.element(Selector.noteRow($0))) }
            steps.append(.check("restored", restoredChecks + everyRow))
            return UIFlow(
                id: "journal.notes.search",
                title: "A Notes search narrows to the one note that holds the word and clears back to every note",
                tags: ["journal", "console", "notes", "search", "memory"],
                host: .console(.history, journalLens: .notes),
                fixture: .static(.remembered),
                steps: steps
            )
        }

        /// On a Journal with no topic, Topics is one empty state whose New Topic opens the
        /// draft page. Add Topic makes and selects a row with the name and summary as typed
        /// and closes the draft; New Topic, now in the list bar, opens it again with both
        /// fields empty, and a second topic under the same name is refused with a caption
        /// that names the topic already holding it, leaving the typed name in place to be
        /// changed. Memory stays empty: a topic is not an entry.
        private static var topicsAddFlow: UIFlow {
            let name = Selector.addedTopicName
            let summary = Selector.addedTopicSummary
            let added = Selector.topicRow(name)
            return UIFlow(
                id: "journal.topics.add",
                title: "Add Topic makes and selects a topic row, and New Topic refuses the same name twice",
                tags: ["journal", "console", "topics", "memory"],
                host: .console(.history, journalLens: .topics),
                fixture: .static(.populated),
                steps: [
                    .wait(.element(Selector.newTopic)),
                    .check(
                        "empty",
                        [
                            .absent(Selector.topicRows),
                            .absent(Selector.topicDraft),
                            .absent(Selector.newTopicName),
                            .count(.label("No topics yet"), .exactly(1)),
                        ]
                    ),
                    .act(.press(Selector.newTopic)),
                    .wait(.element(Selector.newTopicName)),
                    .check(
                        "drafting",
                        [
                            .exists(Selector.topicDraft),
                            .enabled(Selector.addTopic, false),
                            .absent(Selector.addTopicRefusal),
                        ]
                    ),
                    .act(.type(name, into: Selector.newTopicName)),
                    .act(.type(summary, into: Selector.newTopicSummary)),
                    .wait(.element(.all([Selector.newTopicSummary, .value(summary)]))),
                    .check(
                        "typed",
                        [
                            .value(Selector.newTopicName, .equals(name)),
                            .enabled(Selector.addTopic, true),
                        ]
                    ),
                    .act(.press(Selector.addTopic)),
                    .wait(.element(added)),
                    .check(
                        "added",
                        [
                            .count(Selector.topicRows, .exactly(1)),
                            .label(added, .equals("\(name), 0 entries, \(summary)")),
                            .selected(added, true),
                            .absent(Selector.newTopicName),
                            .absent(Selector.topicDraft),
                            .absent(Selector.addTopicRefusal),
                            .model(.memoryEntryCount, .equals("0")),
                        ]
                    ),
                    .act(.press(Selector.newTopic)),
                    .wait(.element(Selector.newTopicName)),
                    .check(
                        "reopened",
                        [
                            .value(Selector.newTopicName, .isEmpty),
                            .value(Selector.newTopicSummary, .isEmpty),
                            .enabled(Selector.addTopic, false),
                        ]
                    ),
                    .act(.type(name, into: Selector.newTopicName)),
                    .wait(.element(.all([Selector.newTopicName, .value(name)]))),
                    .act(.press(Selector.addTopic)),
                    .wait(.element(Selector.addTopicRefusal)),
                    .check(
                        "refused",
                        [
                            .value(Selector.addTopicRefusal, .equals(Selector.duplicateTopicRefusal)),
                            .count(Selector.topicRows, .exactly(1)),
                            .value(Selector.newTopicName, .equals(name)),
                        ]
                    ),
                ]
            )
        }

        /// Topics opens on the topic with the most entries, and a row press moves the page to
        /// another topic and back. The row's label states the count, and the page lists exactly
        /// the entries that count under the topic: confident labels, the entry the user filed
        /// by hand over a label that named another topic, and the labelled note, and nothing
        /// another topic holds.
        private static var topicsOpenFlow: UIFlow {
            let topic = UIFixtures.memoryFolderTopic
            let texts = UIFixtures.memoryFolderTexts
            let row = Selector.topicRow(topic.name)
            let otherRow = Selector.topicRow("Offscreen harness")
            // Filed under the harness topic by a confident label, so its absence from the
            // first page proves the page lists one topic's entries only.
            let otherTopicEntry = UIQuery.labelContains("A scene must never wait on a scratch file write to finish.")
            let pageRows: [UIExpectation] = texts.map { .count(.labelContains($0), .exactly(1)) }
            let noRows: [UIExpectation] = texts.map { .absent(.labelContains($0)) }
            let first: [UIExpectation] = [
                .count(Selector.topicRows, .exactly(3)),
                // Seven, written out rather than taken from the fixture, so a fixture whose
                // filing rule drifted fails here instead of moving with the page.
                .label(row, .equals(Selector.topicRowLabel(topic, entries: 7))),
                .selected(row, true),
                .value(Selector.topicName, .equals(topic.name)),
                .value(Selector.topicSummary, .equals(topic.summary)),
                .enabled(Selector.topicSave, false),
                .absent(otherTopicEntry),
            ]
            let switched: [UIExpectation] = [
                .selected(otherRow, true),
                .selected(row, false),
                .count(otherTopicEntry, .exactly(1)),
            ]
            return UIFlow(
                id: "journal.topics.open",
                title: "The first topic's page lists its entries, and a row press moves the page to another topic",
                tags: ["journal", "console", "topics", "memory"],
                host: .console(.history, journalLens: .topics),
                fixture: .static(.remembered),
                steps: [
                    .wait(.element(row)),
                    .wait(.element(Selector.topicName)),
                    .check("first", first + pageRows),
                    .act(.press(otherRow)),
                    .wait(.element(otherTopicEntry)),
                    .check("switched", switched + noRows),
                    .act(.press(row)),
                    .wait(.element(.all([Selector.topicName, .value(topic.name)]))),
                    .check("returned", first + pageRows),
                ]
            )
        }

        /// New Topic on a Journal that holds topics puts a draft row at the head of the list,
        /// selected, and opens the draft page, where Add Topic waits for a name. Adding makes
        /// the topic, selects its row and closes the draft; the summary is optional, so the
        /// row's label is the name and its count alone.
        private static var topicsCreateFlow: UIFlow {
            let name = Selector.addedTopicName
            let first = Selector.topicRow(UIFixtures.memoryFolderTopic.name)
            let added = Selector.topicRow(name)
            return UIFlow(
                id: "journal.topics.create",
                title: "New Topic opens a draft row and page, and Add Topic replaces the draft with the selected topic",
                tags: ["journal", "console", "topics", "memory"],
                host: .console(.history, journalLens: .topics),
                fixture: .static(.remembered),
                steps: [
                    .wait(.element(first)),
                    .wait(.element(Selector.topicName)),
                    .check(
                        "listed",
                        [
                            .count(Selector.topicRows, .exactly(3)),
                            .selected(first, true),
                            .absent(Selector.topicDraft),
                            .absent(Selector.newTopicName),
                        ]
                    ),
                    .act(.press(Selector.newTopic)),
                    .wait(.element(Selector.newTopicName)),
                    .check(
                        "drafting",
                        [
                            .count(Selector.topicDraft, .exactly(1)),
                            .selected(Selector.topicDraft, true),
                            .selected(first, false),
                            .exists(Selector.newTopicName),
                            .value(Selector.newTopicName, .isEmpty),
                            .enabled(Selector.addTopic, false),
                        ]
                    ),
                    .act(.type(name, into: Selector.newTopicName)),
                    .wait(.element(.all([Selector.newTopicName, .value(name)]))),
                    .check("typed", [.enabled(Selector.addTopic, true)]),
                    .act(.press(Selector.addTopic)),
                    .wait(.element(added)),
                    .wait(.absent(Selector.topicDraft)),
                    .check(
                        "added",
                        [
                            .count(Selector.topicRows, .exactly(4)),
                            .label(added, .equals("\(name), 0 entries")),
                            .selected(added, true),
                            .selected(first, false),
                            .absent(Selector.topicDraft),
                            .absent(Selector.newTopicName),
                            .value(Selector.topicName, .equals(name)),
                        ]
                    ),
                ]
            )
        }

        /// Cancel on the draft page removes the draft row and its words and gives the
        /// selection back to the topic that was open when New Topic was pressed, so a second
        /// New Topic starts empty.
        private static var topicsCancelFlow: UIFlow {
            let topic = UIFixtures.memoryFolderTopic
            let row = Selector.topicRow(topic.name)
            return UIFlow(
                id: "journal.topics.cancel",
                title: "Cancel discards the draft topic and returns to the topic that was open",
                tags: ["journal", "console", "topics", "memory"],
                host: .console(.history, journalLens: .topics),
                fixture: .static(.remembered),
                steps: [
                    .wait(.element(row)),
                    .wait(.element(Selector.topicName)),
                    .act(.press(Selector.newTopic)),
                    .wait(.element(Selector.newTopicName)),
                    .act(.type(Selector.addedTopicName, into: Selector.newTopicName)),
                    .wait(.element(.all([Selector.newTopicName, .value(Selector.addedTopicName)]))),
                    .check(
                        "drafting",
                        [
                            .selected(Selector.topicDraft, true),
                            .selected(row, false),
                            .enabled(Selector.addTopic, true),
                        ]
                    ),
                    .act(.press(Selector.cancelTopic)),
                    .wait(.absent(Selector.topicDraft)),
                    .wait(.element(.all([Selector.topicName, .value(topic.name)]))),
                    .check(
                        "cancelled",
                        [
                            .absent(Selector.topicDraft),
                            .absent(Selector.newTopicName),
                            .count(Selector.topicRows, .exactly(3)),
                            .selected(row, true),
                            .value(Selector.topicName, .equals(topic.name)),
                            .absent(Selector.topicRow(Selector.addedTopicName)),
                        ]
                    ),
                    .act(.press(Selector.newTopic)),
                    .wait(.element(Selector.newTopicName)),
                    .check(
                        "reopened-empty",
                        [
                            .value(Selector.newTopicName, .isEmpty),
                            .enabled(Selector.addTopic, false),
                        ]
                    ),
                ]
            )
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
                        .act(.press(Selector.settingsSection("dictation"))),
                        .wait(.element(Selector.cleanup)),
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
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("dictation"))),
                        .wait(.element(Selector.autoStop)),
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

        // MARK: Island

        /// Settings ▸ Island. Each journey first presses the Island section, whose page is
        /// the only one in the tree once it is selected. Checks read the committed settings
        /// (`islandLook`, `islandAppearance`) beside the controls, so each journey proves a
        /// control's commit reached the persisted settings rather than only that the view
        /// redrew. Sliders move by accessibility increment, which commits exactly as a
        /// released drag does.
        ///
        /// Undo has no flow: ⌘Z is a key equivalent, which AppKit offers only to the key
        /// window, and this one can never become key. The Garage's undo steps are unit-tested
        /// against a standalone `UndoManager` instead.
        private static var islandFlows: [UIFlow] {
            let tags = ["island", "console", "settings"]
            let stock = IslandAppearance.stock.canonicalDescription
            // The journal records both lines, so a change to the draw algorithm shows up as
            // a journal diff even though the expectation is computed from it.
            let firstDraw = IslandAppearance.surprise(
                seed: MercuryMetrics.defaultSeed, draw: 0, avoiding: .stock)
            let secondDraw = IslandAppearance.surprise(
                seed: MercuryMetrics.defaultSeed, draw: 1, avoiding: firstDraw)
            return [
                UIFlow(
                    id: "island.look-selection",
                    title: "Choosing a look commits it and the showroom mark names it",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandLook(.stock))),
                        .check(
                            "stock",
                            [
                                .selected(Selector.islandLook(.stock), true),
                                .value(Selector.islandLookMark, .equals("Stock")),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                        .act(.press(Selector.islandLook(.neonKit))),
                        .check(
                            "neon-kit",
                            [
                                .selected(Selector.islandLook(.neonKit), true),
                                .selected(Selector.islandLook(.stock), false),
                                .value(Selector.islandLookMark, .equals("Neon Kit")),
                                .model(.islandLook, .equals("neon_kit")),
                                .model(.islandDraftPending, .equals("0")),
                            ]
                        ),
                        .act(.press(Selector.islandLook(.stock))),
                        .check(
                            "stock-again",
                            [
                                .selected(Selector.islandLook(.stock), true),
                                .value(Selector.islandLookMark, .equals("Stock")),
                                .model(.islandAppearance, .equals(stock)),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.tune-to-custom",
                    title: "One slider step off a look reads as Custom until its fold is restored",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandMaterialFold)),
                        .act(.press(Selector.islandMaterialFold)),
                        .wait(.element(Selector.islandFinish)),
                        .check(
                            "material-open",
                            [
                                .value(Selector.islandFinish, .equals("0")),
                                .enabled(Selector.islandMaterialStock, false),
                            ]
                        ),
                        .act(.increment(Selector.islandFinish)),
                        .check(
                            "custom",
                            [
                                .value(Selector.islandFinish, .equals("5")),
                                .valueDescription(Selector.islandFinish, .equals("5 percent")),
                                .value(Selector.islandLookMark, .equals("Custom")),
                                // Custom is no card, so the look it left reads unselected.
                                .selected(Selector.islandLook(.stock), false),
                                .model(.islandLook, .equals("custom")),
                                // Committed on the step's editing end, not left as a draft.
                                .model(.islandDraftPending, .equals("0")),
                                .enabled(Selector.islandMaterialStock, true),
                            ]
                        ),
                        .act(.press(Selector.islandMaterialStock)),
                        .check(
                            "stock-again",
                            [
                                .value(Selector.islandFinish, .equals("0")),
                                .value(Selector.islandLookMark, .equals("Stock")),
                                .enabled(Selector.islandMaterialStock, false),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.coat-film",
                    title: "Each film coat opens the film slider at its own stock thickness",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandMaterialFold)),
                        .act(.press(Selector.islandMaterialFold)),
                        .wait(.element(Selector.islandCoat(.none))),
                        .check(
                            "none",
                            [
                                .value(Selector.islandCoat(.none), .equals("1")),
                                .absent(Selector.islandFilm),
                            ]
                        ),
                        .act(.press(Selector.islandCoat(.pearl))),
                        .check(
                            "pearl",
                            [
                                .value(Selector.islandFilm, .equals("70")),
                                .valueDescription(Selector.islandFilm, .equals("70 nanometers")),
                                .model(.islandAppearance, .contains("coat=pearl film=70 ")),
                            ]
                        ),
                        .act(.press(Selector.islandCoat(.oilSlick))),
                        .check(
                            "oil-slick",
                            [
                                .value(Selector.islandFilm, .equals("450")),
                                .model(.islandAppearance, .contains("coat=oil_slick film=450 ")),
                            ]
                        ),
                        .act(.press(Selector.islandCoat(.chameleon))),
                        .check(
                            "chameleon",
                            [
                                .value(Selector.islandFilm, .equals("350")),
                                .model(.islandAppearance, .contains("coat=chameleon film=350 ")),
                            ]
                        ),
                        .act(.press(Selector.islandCoat(.none))),
                        .check(
                            "none-again",
                            [
                                .value(Selector.islandCoat(.none), .equals("1")),
                                .absent(Selector.islandFilm),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.candy-coat",
                    title: "The Candy coat alone offers a dye color well",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandMaterialFold)),
                        .act(.press(Selector.islandMaterialFold)),
                        .wait(.element(Selector.islandCoat(.candy))),
                        .check("bare", [.absent(Selector.islandCandy)]),
                        .act(.press(Selector.islandCoat(.candy))),
                        .check(
                            "candy",
                            [
                                .exists(Selector.islandCandy),
                                .enabled(Selector.islandCandy, true),
                                .absent(Selector.islandFilm),
                                .model(.islandAppearance, .contains("coat=candy ")),
                            ]
                        ),
                        .act(.press(Selector.islandCoat(.none))),
                        .check(
                            "bare-again",
                            [
                                .absent(Selector.islandCandy),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.underglow-dependency",
                    title: "The underglow switch governs its color and strength",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandLightingFold)),
                        .act(.press(Selector.islandLightingFold)),
                        .wait(.element(Selector.islandUnderglow)),
                        .check(
                            "off",
                            [
                                .value(Selector.islandUnderglow, .equals("0")),
                                .enabled(Selector.islandUnderglowColor, false),
                                .enabled(Selector.islandUnderglowStrength, false),
                            ]
                        ),
                        .act(.press(Selector.islandUnderglow)),
                        .check(
                            "on",
                            [
                                .value(Selector.islandUnderglow, .equals("1")),
                                .enabled(Selector.islandUnderglowColor, true),
                                .enabled(Selector.islandUnderglowStrength, true),
                                .value(Selector.islandUnderglowStrength, .equals("60")),
                                .model(.islandLook, .equals("custom")),
                            ]
                        ),
                        .act(.press(Selector.islandUnderglow)),
                        .check(
                            "off-again",
                            [
                                .enabled(Selector.islandUnderglowColor, false),
                                .enabled(Selector.islandUnderglowStrength, false),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.room-selection",
                    title: "Choosing Overcast relights the showroom and commits the room",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandLightingFold)),
                        .act(.press(Selector.islandLightingFold)),
                        .wait(.element(Selector.islandRoom(.spectralWeather))),
                        .act(.press(Selector.islandRoom(.spectralWeather))),
                        .check(
                            "overcast",
                            [
                                .value(Selector.islandRoom(.spectralWeather), .equals("1")),
                                .value(Selector.islandShowroom, .equals("Speaking, Overcast room 1")),
                                .model(.islandAppearance, .contains("room=spectral_weather ")),
                            ]
                        ),
                        .act(.press(Selector.islandRoom(.roomOfTen))),
                        .check(
                            "studio",
                            [
                                .value(Selector.islandRoom(.roomOfTen), .equals("1")),
                                .value(Selector.islandShowroom, .equals("Speaking, Studio room 1")),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.surprise",
                    title: "Surprise Me commits the seeded draws in order",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandSurprise)),
                        .check("stock", [.model(.islandLook, .equals("stock"))]),
                        .act(.press(Selector.islandSurprise)),
                        .check(
                            "first-draw",
                            [
                                .model(.islandAppearance, .equals(firstDraw.canonicalDescription)),
                                .model(.islandLook, .equals(UIFlowExpectations.islandLookTag(firstDraw))),
                                .model(.islandDraftPending, .equals("0")),
                            ]
                        ),
                        .act(.press(Selector.islandSurprise)),
                        .check(
                            "second-draw",
                            [
                                .model(.islandAppearance, .equals(secondDraw.canonicalDescription)),
                                .model(.islandLook, .equals(UIFlowExpectations.islandLookTag(secondDraw))),
                                .model(.islandDraftPending, .equals("0")),
                            ]
                        ),
                    ]),
                // The preview's room is view state: drawing another one must never reach
                // the island's settings.
                UIFlow(
                    id: "island.showroom-room",
                    title: "Another Room changes the preview and saves nothing",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandShowroom)),
                        .check(
                            "room-1",
                            [
                                .label(Selector.islandShowroom, .equals("Island preview")),
                                .value(Selector.islandShowroom, .equals("Speaking, Studio room 1")),
                                .model(.islandLook, .equals("stock")),
                            ]
                        ),
                        .act(.press(Selector.islandAnotherRoom)),
                        .check(
                            "room-2",
                            [
                                .value(Selector.islandShowroom, .equals("Speaking, Studio room 2")),
                                .model(.islandAppearance, .equals(stock)),
                                .model(.islandDraftPending, .equals("0")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.folds-independent",
                    title: "The four Garage folds open and close independently",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandMaterialFold)),
                        .check(
                            "closed",
                            [
                                .value(Selector.islandMaterialFold, .equals("Collapsed")),
                                .value(Selector.islandLightingFold, .equals("Collapsed")),
                                .value(Selector.islandBodyFold, .equals("Collapsed")),
                                .value(Selector.islandMotionFold, .equals("Collapsed")),
                                .absent(Selector.islandFinish),
                                .absent(Selector.islandTemperature),
                                .absent(Selector.islandSize),
                                .absent(Selector.islandTempo),
                            ]
                        ),
                        .act(.press(Selector.islandMaterialFold)),
                        .act(.press(Selector.islandMotionFold)),
                        .wait(.element(Selector.islandTempo)),
                        .check(
                            "material-and-motion",
                            [
                                .exists(Selector.islandFinish),
                                .exists(Selector.islandTempo),
                                .absent(Selector.islandTemperature),
                                .absent(Selector.islandSize),
                            ]
                        ),
                        .act(.press(Selector.islandMaterialFold)),
                        .wait(.absent(Selector.islandFinish)),
                        .check(
                            "motion-only",
                            [
                                .absent(Selector.islandFinish),
                                .exists(Selector.islandTempo),
                                .value(Selector.islandMotionFold, .equals("Expanded")),
                            ]
                        ),
                    ]),
                UIFlow(
                    id: "island.position-dock",
                    title: "Dock Island docks a torn-off island and says where it goes",
                    tags: tags,
                    host: .console(.settings),
                    fixture: .static(.islandCustom),
                    steps: [
                        .act(.press(Selector.settingsSection("island"))),
                        .wait(.element(Selector.islandPositionDock)),
                        .check(
                            "free",
                            [
                                .enabled(Selector.islandPositionDock, true),
                                .label(Selector.islandPositionDock, .equals("Dock the island")),
                                .text(.equals(Selector.islandFreePlacementCaption), .exactly(1)),
                                .model(.islandPlacement, .equals("free")),
                            ]
                        ),
                        .act(.press(Selector.islandPositionDock)),
                        .check(
                            "docked",
                            [
                                .enabled(Selector.islandPositionDock, false),
                                .text(.equals(Selector.islandDockedPlacementCaption), .exactly(1)),
                                .text(.equals(Selector.islandFreePlacementCaption), .exactly(0)),
                                .model(.islandPlacement, .equals("docked")),
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
                        .check("empty", [.count(.label("No terms yet"), .exactly(1))]),
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
                        .check("awaiting-confirmation", [.model(.glossaryTermCount, .equals("7"))]),
                    ]),
                // The sidebar's origins narrow the list without touching the glossary: a
                // bundled term is Built-in, and a taught or imported term is Yours.
                UIFlow(
                    id: "glossary.origins",
                    title: "The sidebar's origins narrow the list to Yours or Built-in terms",
                    tags: ["glossary", "console", "origins"],
                    host: .console(.glossary),
                    fixture: .static(.mixedGlossary),
                    steps: [
                        .wait(.element(Selector.bundledTermRow)),
                        .check(
                            "all",
                            [
                                .selected(Selector.allTermsOrigin, true),
                                .exists(Selector.bundledTermRow),
                                .exists(Selector.taughtTermRow),
                            ]
                        ),
                        .act(.press(Selector.yoursOrigin)),
                        .wait(.absent(Selector.bundledTermRow)),
                        .check(
                            "yours",
                            [
                                .selected(Selector.yoursOrigin, true),
                                .selected(Selector.allTermsOrigin, false),
                                .exists(Selector.taughtTermRow),
                                .exists(Selector.importedTermRow),
                                .absent(Selector.bundledTermRow),
                            ]
                        ),
                        .act(.press(Selector.builtInOrigin)),
                        .wait(.element(Selector.bundledTermRow)),
                        .check(
                            "built-in",
                            [
                                .selected(Selector.builtInOrigin, true),
                                .selected(Selector.yoursOrigin, false),
                                .exists(Selector.bundledTermRow),
                                .absent(Selector.taughtTermRow),
                                .absent(Selector.importedTermRow),
                                .model(.glossaryTermCount, .equals("7")),
                            ]
                        ),
                    ]),
                // Suggestions open first while any are pending, on the first suggestion's
                // page. Teaching it confirms the misheard form on its existing term and moves
                // the page to the next suggestion; refusing the last one empties Suggestions,
                // which leaves the sidebar and hands the tab back to All Terms, where the
                // taught term's row now names the form it was taught.
                UIFlow(
                    id: "glossary.suggestion-teach",
                    title:
                        "Teaching a suggestion adds its form to the term, and handling the last returns to All Terms",
                    tags: ["glossary", "console", "suggestions"],
                    host: .console(.glossary),
                    fixture: .static(.glossarySuggestions),
                    steps: [
                        .wait(.element(Selector.suggestion("suggestion-neurodock", "accept"))),
                        .check(
                            "suggestions",
                            [
                                .selected(Selector.suggestionsItem, true),
                                .selected(Selector.allTermsOrigin, false),
                                .exists(Selector.suggestion("suggestion-neurodock", "accept")),
                            ]
                        ),
                        .act(.press(Selector.suggestion("suggestion-neurodock", "accept"))),
                        .wait(.element(Selector.suggestion("suggestion-kubectl", "accept"))),
                        .check(
                            "next-suggestion",
                            [
                                .absent(Selector.suggestion("suggestion-neurodock", "accept")),
                                .absent(Selector.suggestion("suggestion-neurodock", "ignore")),
                                .absent(Selector.suggestion("suggestion-neurodock", "reject")),
                                .exists(Selector.suggestion("suggestion-kubectl", "accept")),
                            ]
                        ),
                        .act(.press(Selector.suggestion("suggestion-kubectl", "reject"))),
                        .wait(.absent(Selector.suggestionsItem)),
                        .wait(.element(Selector.taughtTermRow)),
                        .check(
                            "all-terms",
                            [
                                .absent(Selector.suggestionsItem),
                                .selected(Selector.allTermsOrigin, true),
                                .label(Selector.taughtTermRow, .contains("new row dock")),
                                // Teaching confirms a form on an existing term; it adds none.
                                .model(.glossaryTermCount, .equals("7")),
                            ]
                        ),
                    ]),
                // Add Term puts a "New term" draft row at the head of the list and opens its
                // page; Cancel removes both and adds nothing.
                UIFlow(
                    id: "glossary.draft-cancel",
                    title: "Cancel on a new term's page removes its draft row and adds nothing",
                    tags: ["glossary", "console"],
                    host: .console(.glossary),
                    fixture: .static(.mixedGlossary),
                    steps: [
                        .wait(.element(Selector.bundledTermRow)),
                        .check(
                            "listed",
                            [
                                .absent(Selector.draftRow),
                                .absent(Selector.draftCanonical),
                            ]
                        ),
                        .act(.press(Selector.addTermButton)),
                        .wait(.element(Selector.draftRow)),
                        .check(
                            "drafting",
                            [
                                .count(Selector.draftRow, .exactly(1)),
                                .selected(Selector.draftRow, true),
                                .exists(Selector.draftCanonical),
                                .exists(Selector.draftCancel),
                            ]
                        ),
                        .act(.press(Selector.draftCancel)),
                        .wait(.absent(Selector.draftRow)),
                        .check(
                            "cancelled",
                            [
                                .absent(Selector.draftRow),
                                .absent(Selector.draftCanonical),
                                .exists(Selector.bundledTermRow),
                                .model(.glossaryTermCount, .equals("7")),
                            ]
                        ),
                    ]),
            ]
        }

        // MARK: System

        private static var systemFlows: [UIFlow] {
            [
                UIFlow(
                    id: "system.recheck-backend",
                    title: "An unanswered backend probe reads as Engine offline until re-proven",
                    tags: ["system", "console", "settings"],
                    host: .console(.settings),
                    fixture: .backendRecovery(),
                    steps: [
                        .act(.press(Selector.settingsSection("readiness"))),
                        .wait(.element(Selector.backendStatusWithValue("Checking…"))),
                        .check(
                            "initial-probe",
                            [.value(Selector.backendStatus, .equals("Checking…"))]
                        ),
                        .release(.backendHealthUnavailable),
                        // A probe that never answered, with no cached model, is the
                        // engine being absent — not a failed download (nothing was
                        // downloading) and not a shrug ("Check needed").
                        .wait(.element(Selector.backendStatusWithValue("Engine offline"))),
                        .check(
                            "unavailable",
                            [
                                .value(Selector.backendStatus, .equals("Engine offline")),
                                .label(Selector.backendRecheck, .equals("Re-check backend health")),
                                .role(Selector.backendRecheck, "AXButton"),
                            ]
                        ),
                        .act(.press(Selector.backendRecheck)),
                        // The failure is environmental: starting a re-probe does not
                        // erase it. Only fresh good evidence may clear the row.
                        .check(
                            "rechecking",
                            [.value(Selector.backendStatus, .equals("Engine offline"))]
                        ),
                        .release(.backendHealth),
                        .wait(.element(Selector.backendStatusWithValue("Ready"))),
                        .check(
                            "ready",
                            [
                                .value(Selector.backendStatus, .equals("Ready")),
                                .text(
                                    .equals("GRANITE is configured for local transcription."),
                                    .exactly(1)
                                ),
                            ]
                        ),
                    ]),
                // Turning memory on keeps every History row memory lacks, in the same turn,
                // and offers the agent paragraph, which is withheld while memory is off and
                // no folder exists for it to point at.
                UIFlow(
                    id: "system.memory.toggle",
                    title: "Turning memory on keeps the History rows and offers the agent instructions",
                    tags: ["system", "console", "settings", "memory"],
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("memory"))),
                        .wait(.element(Selector.memoryToggle)),
                        .check(
                            "off",
                            [
                                .value(Selector.memoryToggle, .equals("0")),
                                .enabled(Selector.memoryCopyInstructions, false),
                                .model(.memoryEntryCount, .equals("0")),
                            ]
                        ),
                        .act(.press(Selector.memoryToggle)),
                        .wait(.element(.all([Selector.memoryToggle, .value("1")]))),
                        .check(
                            "on",
                            [
                                .value(Selector.memoryToggle, .equals("1")),
                                .model(.memoryEntryCount, .equals("10")),
                                .model(.recentSessionCount, .equals("10")),
                                .enabled(Selector.memoryCopyInstructions, true),
                            ]
                        ),
                    ]),
                // Copy Install Command first writes the skill through the coordinator's seam,
                // which the harness keeps inert, then copies the command once. The command names
                // the fixture's scratch memory folder, an absolute path, so its text is not
                // checked; only that exactly one write happened and no failure was reported.
                UIFlow(
                    id: "system.memory.skill-command",
                    title: "Copy Install Command copies the skill's install command once",
                    tags: ["system", "console", "settings", "memory", "clipboard"],
                    host: .console(.settings),
                    fixture: .static(.remembered),
                    steps: [
                        .act(.press(Selector.settingsSection("memory"))),
                        .wait(.element(Selector.memoryCopySkillCommand)),
                        .check(
                            "offered",
                            [
                                .value(Selector.memoryToggle, .equals("1")),
                                .enabled(Selector.memoryCopySkillCommand, true),
                                .absent(Selector.settingsCopied),
                                .model(.pasteboardWrites, .equals("0")),
                            ]
                        ),
                        .act(.press(Selector.memoryCopySkillCommand)),
                        .wait(.element(Selector.settingsCopied)),
                        .check(
                            "copied",
                            [
                                .exists(Selector.settingsCopied),
                                .model(.pasteboardWrites, .equals("1")),
                                .text(.equals(Selector.skillWriteFailure), .exactly(0)),
                            ]
                        ),
                    ]),
                // A saved key enables the sorting switch and is never drawn: the field
                // empties, the status names only where the key lives, and no node of the
                // tree holds the key's text. The key file sits in the fixture's scratch
                // folder, and the harness key source reads no environment.
                UIFlow(
                    id: "system.organizer.key",
                    title: "Saving a TypeSafe key enables sorting and leaves the key nowhere on screen",
                    tags: ["system", "console", "settings", "memory", "organizer"],
                    host: .console(.settings),
                    fixture: .static(.populated),
                    steps: [
                        .act(.press(Selector.settingsSection("memory"))),
                        .wait(.element(Selector.organizerKeyStatus)),
                        .check(
                            "no-key",
                            [
                                .value(Selector.organizerKeyStatus, .equals("Not set")),
                                .value(Selector.organizerToggle, .equals("0")),
                                .enabled(Selector.organizerToggle, false),
                                .enabled(Selector.organizerKeySave, false),
                                .absent(Selector.organizerKeyRemove),
                            ]
                        ),
                        .act(.type(Selector.fakeTypeSafeKey, into: Selector.organizerKeyField)),
                        .check(
                            "typed",
                            [
                                .enabled(Selector.organizerKeySave, true),
                                .enabled(Selector.organizerToggle, false),
                            ]
                        ),
                        .act(.press(Selector.organizerKeySave)),
                        .wait(.element(.all([Selector.organizerKeyStatus, .value("Saved in typesafe.key")]))),
                        .check(
                            "saved",
                            [
                                .value(Selector.organizerKeyStatus, .equals("Saved in typesafe.key")),
                                .value(Selector.organizerKeyField, .isEmpty),
                                .enabled(Selector.organizerKeySave, false),
                                .exists(Selector.organizerKeyRemove),
                                .enabled(Selector.organizerToggle, true),
                                .value(Selector.organizerToggle, .equals("0")),
                                .text(.contains(Selector.fakeTypeSafeKey), .exactly(0)),
                                .absent(.labelContains(Selector.fakeTypeSafeKey)),
                                .absent(.value(Selector.fakeTypeSafeKey)),
                            ]
                        ),
                    ]),
                // Link Earlier Dictations on the populated History with linking on. The harness
                // reader answers from a table holding one row and opens no agent's files, so the
                // run links that row, counts every other row it looked for as not found, and
                // copies nothing; the button is offered again once the run has reported.
                UIFlow(
                    id: "system.agent.link-earlier",
                    title: "Link Earlier Dictations links the row an agent's prompts held and counts the rest",
                    tags: ["system", "console", "settings", "agent-link"],
                    host: .console(.settings),
                    fixture: .static(.linkingOn),
                    steps: [
                        .act(.press(Selector.settingsSection("privacy"))),
                        .wait(.element(Selector.linkEarlier)),
                        .check(
                            "offered",
                            [
                                .value(Selector.agentLinksToggle, .equals("1")),
                                .enabled(Selector.linkEarlier, true),
                                .text(.equals(Selector.linkEarlierBeforeRun), .exactly(1)),
                                .model(.pasteboardWrites, .equals("0")),
                            ]
                        ),
                        .act(.press(Selector.linkEarlier)),
                        .wait(.element(.value(Selector.linkEarlierSummary))),
                        .check(
                            "reported",
                            [
                                .text(.equals(Selector.linkEarlierSummary), .exactly(1)),
                                .text(.equals(Selector.linkEarlierBeforeRun), .exactly(0)),
                                .enabled(Selector.linkEarlier, true),
                                .model(.recentSessionCount, .equals("10")),
                                .model(.pasteboardWrites, .equals("0")),
                            ]
                        ),
                    ]),
            ]
        }

        // MARK: Console tabs

        private static var consoleFlows: [UIFlow] {
            [
                homeStatsFlow,
                homeFirstRunFlow,
                tabNavigationFlow,
                settingsSectionsFlow,
                settingsAppearanceFlow,
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

        /// The console's four destinations in declaration order. Each leg asserts that
        /// the tab reporting itself selected is the one whose content rendered, so a
        /// selection that moves the control without moving the destination fails here.
        private static var tabNavigationFlow: UIFlow {
            UIFlow(
                id: "console.tab.navigation",
                title: "The native console switches through every tab",
                tags: ["console", "tab", "navigation"],
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
                    // Settings opens on the Dictation page beside its sidebar, each shown
                    // once: the sidebar reaches every other section's page from here.
                    .check(
                        "settings",
                        [
                            .count(Selector.settingsContent, .exactly(1)),
                            .count(Selector.settingsSection("privacy"), .exactly(1)),
                            .absent(Selector.historyContent),
                            .value(Selector.tab(.settings), .equals("1")),
                            .value(Selector.tab(.history), .equals("0")),
                        ]
                    ),
                ]
            )
        }

        /// Settings shows one section per page. It opens on Dictation, and a sidebar press
        /// swaps the page rather than scrolling to it: the item reporting itself selected
        /// is the one whose controls are in the tree, and the previous page's controls
        /// leave it.
        private static var settingsSectionsFlow: UIFlow {
            let dictation = Selector.settingsSection("dictation")
            let audio = Selector.settingsSection("audio")
            let danger = Selector.settingsSection("danger")
            return UIFlow(
                id: "settings.sections",
                title: "Settings opens on Dictation and a sidebar item swaps in its section's page",
                tags: ["console", "settings", "navigation"],
                host: .console(.settings),
                fixture: .static(.populated),
                steps: [
                    .wait(.element(Selector.settingsContent)),
                    // `Kit.Screen` paints `Ink.void` behind every page, so the raster the
                    // geometry and contrast rules read is real paint.
                    .check(
                        "dictation",
                        [
                            .selected(dictation, true),
                            .exists(Selector.settingsContent),
                            .absent(Selector.microphonePicker),
                            .lintClean,
                        ]
                    ),
                    .act(.press(audio)),
                    .wait(.element(Selector.microphonePicker)),
                    .check(
                        "audio",
                        [
                            .selected(audio, true),
                            .selected(dictation, false),
                            .exists(Selector.microphonePicker),
                            .absent(Selector.settingsContent),
                        ]
                    ),
                    .act(.press(danger)),
                    .wait(.element(Selector.historyArm)),
                    .check(
                        "danger",
                        [
                            .selected(danger, true),
                            .selected(audio, false),
                            .exists(Selector.historyArm),
                            .absent(Selector.microphonePicker),
                        ]
                    ),
                ]
            )
        }

        /// Settings ▸ Appearance: each tile and swatch commits its choice to the settings the
        /// console and the menu theme themselves from, and the chosen one alone carries
        /// `.isSelected`. The populated fixture opens on System and Green.
        private static var settingsAppearanceFlow: UIFlow {
            let system = Selector.appearanceTile(.system)
            let light = Selector.appearanceTile(.light)
            let green = Selector.accentSwatch(.green)
            let purple = Selector.accentSwatch(.purple)
            return UIFlow(
                id: "settings.appearance",
                title: "Appearance tiles and accent swatches commit the console's look",
                tags: ["console", "settings", "appearance"],
                host: .console(.settings),
                fixture: .static(.populated),
                steps: [
                    .act(.press(Selector.settingsSection("appearance"))),
                    .wait(.element(system)),
                    .check(
                        "system",
                        [
                            .selected(Selector.settingsSection("appearance"), true),
                            .selected(system, true),
                            .selected(light, false),
                            .selected(green, true),
                            .model(.consoleAppearance, .equals("system")),
                            .model(.consoleAccent, .equals("green")),
                        ]
                    ),
                    .act(.press(light)),
                    .wait(.element(light)),
                    .check(
                        "light",
                        [
                            .selected(light, true),
                            .selected(system, false),
                            .model(.consoleAppearance, .equals("light")),
                            .model(.consoleAccent, .equals("green")),
                        ]
                    ),
                    .act(.press(purple)),
                    .wait(.element(purple)),
                    .check(
                        "purple",
                        [
                            .selected(purple, true),
                            .selected(green, false),
                            .selected(light, true),
                            .model(.consoleAccent, .equals("purple")),
                            .model(.consoleAppearance, .equals("light")),
                        ]
                    ),
                    .act(.press(system)),
                    .wait(.element(system)),
                    .check(
                        "system-again",
                        [
                            .selected(system, true),
                            .selected(light, false),
                            .model(.consoleAppearance, .equals("system")),
                            .model(.consoleAccent, .equals("purple")),
                        ]
                    ),
                ]
            )
        }

        // MARK: Menu and dictation

        private static var menuFlows: [UIFlow] {
            [
                menuPrimaryActionFlow,
                pasteDeliveredFlow,
                copyOnlyFlow,
                cancelledFlow,
                asrErrorFlow,
                asrRecoveryFlow,
                noteMenuFlow,
                noteSpokenPrefixFlow,
                reportOpenThreadFlow,
                UIFlow(
                    id: "menu.copy-transcript",
                    title: "The last transcript can be copied from its card",
                    tags: ["menu", "clipboard"],
                    host: .menu,
                    fixture: .static(.completedDictation),
                    steps: [
                        // MenuTranscriptPreview.swift:30-32; fixtures/ui/menu.transcript.ax.txt:4.
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

        /// The report's thread line, on a paste into Tern whose row is bound, names the thread
        /// and asks the console for it. No console is hosted here, so the request stays on the
        /// coordinator to be read; `journal.route.thread` proves what the console does with it.
        private static var reportOpenThreadFlow: UIFlow {
            let key = UIFixtures.agentSession
            return UIFlow(
                id: "menu.report.open-thread",
                title: "The report's thread line asks the console for the thread the paste reached",
                tags: ["menu", "agent-link"],
                host: .menu,
                fixture: .static(.pastedLinked),
                steps: [
                    .wait(.element(Selector.reportThread)),
                    .check(
                        "linked",
                        [
                            .text(.equals("Pasted"), .exactly(1)),
                            .text(.equals("Pasted into \(UIFixtures.ternAppName)."), .exactly(1)),
                            .role(Selector.reportThread, "AXButton"),
                            .label(
                                Selector.reportThread,
                                .equals("Open thread, \(key.agent.displayName) · \(UIFixtures.agentSessionTitle)")
                            ),
                            .absent(Selector.reportUnlinked),
                            .model(.pendingJournalThread, .isEmpty),
                        ]
                    ),
                    .act(.press(Selector.reportThread)),
                    .wait(.element(Selector.reportThread)),
                    .check(
                        "requested",
                        [
                            .model(.pendingJournalThread, .equals("\(key.agent.rawValue)-\(key.sessionId)")),
                            .count(Selector.reportThread, .exactly(1)),
                        ]
                    ),
                ])
        }

        private static var menuPrimaryActionFlow: UIFlow {
            UIFlow(
                id: "menu.primary-action",
                title: "The menu primary action drives a dictation",
                tags: ["menu", "dictation"],
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
                    // `.lintClean` is affordable where the host paints `Ink.void` behind
                    // the content: the menu host paints it behind `MenuView`, so the raster
                    // the geometry and contrast rules read is real paint rather than an
                    // unrasterised window ground.
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
                            // MenuView.swift's `dictationTitle`: one capsule, two labels.
                            .absent(Selector.startDictation),
                            .role(Selector.stopDictation, "AXButton"),
                            .label(Selector.stopDictation, .equals("STOP DICTATION")),
                            .enabled(Selector.stopDictation, true),
                            .text(.equals("Live"), .exactly(1)),
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
            )
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
                    reportLabel: "Pasted",
                    // The pill reads "Pasted" too, so the detail is matched whole: the
                    // harness target has no name of its own and is named from its bundle id.
                    reportDetail: .equals("Pasted into Writer.")
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
                    outcome: .copiedOnly(reason: InsertionSafetyPolicy.targetClassReason(.terminal)),
                    targetBundleID: terminalBundleID,
                    targetSafety: .terminal
                ),
                steps: fullDeliverySteps(
                    terminalState: .copiedOnly,
                    disposition: "copy",
                    bundleID: terminalBundleID,
                    reportLabel: "Copy only",
                    // The policy's own reason reaches its explicit sentence, never the
                    // humanized fallback. The app's name leads it when the target has one.
                    reportDetail: .contains(" is a terminal. Press \u{2318}V to paste.")
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
                    .check("recording", [.state(.recording), .text(.equals("Live"), .exactly(1))]),
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
            let failure = UserFacingDictationFailure(code: .backendUnavailable, detail: nil)
            return UIFlow(
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
                            .model(.processingInFlight, .equals("false")),
                            .text(.equals(Kit.Pill.sentence(failure.title)), .exactly(1)),
                            .text(.equals(failure.cause), .exactly(1)),
                            .enabled(Selector.retryDictation, true),
                        ]
                    ),
                ])
        }

        private static var asrRecoveryFlow: UIFlow {
            let failure = UserFacingDictationFailure(code: .manifestMismatch, detail: nil)
            return UIFlow(
                id: "dictation.asr-recovery",
                title: "A model failure offers recovery and the next dictation delivers",
                tags: ["menu", "dictation", "error", "recovery", "model"],
                host: .menu,
                fixture: .dictationRecovery(code: .manifestMismatch, transcript: dictatedText),
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
                        "model-failure",
                        [
                            .text(.equals(Kit.Pill.sentence(failure.title)), .exactly(1)),
                            .text(.equals(failure.cause), .exactly(1)),
                            .enabled(Selector.retryDictation, true),
                            .enabled(Selector.startAfterFailure, true),
                            .model(.processingInFlight, .equals("false")),
                            .model(.deliveryCount, .equals("0")),
                            .model(.recentSessionCount, .equals("0")),
                        ]
                    ),
                    .act(.press(Selector.retryDictation)),
                    .act(.press(Selector.startAfterFailure)),
                    // The first utterance opened these sticky gates. The next one can
                    // record immediately, but still parks at its first insertion.
                    .wait(.state(.recording)),
                    .check(
                        "recording-again",
                        [
                            .absent(Selector.retryDictation),
                            .text(.equals(failure.cause), .exactly(0)),
                            .model(.errorMessage, .isEmpty),
                            .enabled(Selector.stopDictation, true),
                        ]
                    ),
                    .act(.press(Selector.stopDictation)),
                    .wait(.state(.readyToInsert)),
                    .release(.insertion),
                    .wait(.state(.idle)),
                    .check(
                        "recovered",
                        [
                            .transitions(
                                [
                                    .error, .checkingPermissions, .recording, .finalizingAudio,
                                    .transcribing, .cleaning, .readyToInsert, .pasteAttempted, .idle,
                                ],
                                .contiguous
                            ),
                            .model(.deliveredText, .equals(dictatedText)),
                            .model(.deliveryDisposition, .equals("paste")),
                            .model(.deliveryCount, .equals("1")),
                            .model(.recentSessionCount, .equals("1")),
                            .model(.processingInFlight, .equals("false")),
                            .model(.errorMessage, .isEmpty),
                            .absent(Selector.retryDictation),
                            .text(.equals("Pasted"), .exactly(1)),
                        ]
                    ),
                ]
            )
        }

        /// The menu's Take a Note row starts a recording whose words are saved to memory
        /// and delivered nowhere: the state machine skips `.readyToInsert` because there is
        /// no delivery to get ready for, and ends on `.noteSaved`.
        private static var noteMenuFlow: UIFlow {
            UIFlow(
                id: "dictation.note.menu",
                title: "Take a Note saves the dictation to memory and delivers it nowhere",
                tags: ["menu", "dictation", "note", "memory"],
                host: .menu,
                fixture: noteFixture(transcript: dictatedText),
                steps: noteSteps(
                    start: Selector.takeNote,
                    noteTargetLines: 1,
                    states: [
                        .idle, .checkingPermissions, .recording, .finalizingAudio,
                        .transcribing, .cleaning, .noteSaved, .idle,
                    ]
                ))
        }

        /// "Note to self" at the start of an ordinary dictation files it as a note. The
        /// session is a delivery until the words are read, so it passes `.readyToInsert`
        /// before the prefix turns it into a note, and the note is saved without the prefix.
        private static var noteSpokenPrefixFlow: UIFlow {
            UIFlow(
                id: "dictation.note.spoken-prefix",
                title: "A dictation that starts with note to self is saved as a note without the prefix",
                tags: ["menu", "dictation", "note", "memory"],
                host: .menu,
                fixture: noteFixture(transcript: spokenNoteText),
                steps: noteSteps(
                    start: Selector.startDictation,
                    noteTargetLines: 0,
                    states: [
                        .idle, .checkingPermissions, .recording, .finalizingAudio,
                        .transcribing, .cleaning, .readyToInsert, .noteSaved, .idle,
                    ]
                ))
        }

        /// A note never reaches the insertion boundary, so arming it would leave a gate no
        /// script can release. The target is an ordinary text field, where a spoken note is
        /// honoured and a delivery would have pasted.
        private static func noteFixture(transcript: String) -> UIFlowFixture {
            .dictation(
                transcript: transcript,
                outcome: .pasteAttempted,
                targetBundleID: pasteBundleID,
                targetSafety: .normalText,
                reaches: [.permission, .recorderStop, .transcription]
            )
        }

        /// One note from start to the menu's report. `noteTargetLines` is how many times
        /// the status line promises a note while recording: once for a session started as
        /// a note, never for a dictation that only becomes one when its words are read.
        private static func noteSteps(
            start: UIQuery,
            noteTargetLines: Int,
            states: [UIStatePattern]
        ) -> [UIFlowStep] {
            [
                .check(
                    "idle",
                    [
                        .role(Selector.takeNote, "AXButton"),
                        .enabled(Selector.takeNote, true),
                        .model(.recentSessionCount, .equals("0")),
                        .model(.noteCount, .equals("0")),
                    ]
                ),
                .act(.press(start)),
                .wait(.state(.checkingPermissions)),
                .release(.permission),
                .wait(.state(.recording)),
                .check(
                    "live",
                    [
                        .state(.recording),
                        .text(.equals(Selector.noteTargetLine), .exactly(noteTargetLines)),
                        // A session in flight offers its stop action alone.
                        .absent(Selector.takeNote),
                        .enabled(Selector.stopDictation, true),
                    ]
                ),
                .act(.press(Selector.stopDictation)),
                .wait(.state(.finalizingAudio)),
                .release(.recorderStop),
                .wait(.state(.transcribing)),
                .release(.transcription),
                .wait(.state(.idle)),
                .check(
                    "saved",
                    [
                        .transitions(states, .exact),
                        .text(.equals(Selector.noteSavedLabel), .exactly(1)),
                        .text(.equals(Selector.noteSavedDetail), .exactly(1)),
                        .model(.recentSessionCount, .equals("0")),
                        .model(.deliveryCount, .equals("0")),
                        .model(.pasteboardWrites, .equals("0")),
                        .model(.noteCount, .equals("1")),
                        .model(.lastSavedNote, .equals(dictatedText)),
                        .model(.transcript, .equals(dictatedText)),
                        .exists(Selector.takeNote),
                    ]
                ),
            ]
        }

        private static var pasteFixture: UIFlowFixture {
            .dictation(
                transcript: dictatedRawText,
                outcome: .pasteAttempted,
                targetBundleID: pasteBundleID,
                targetSafety: .normalText
            )
        }

        /// The menu's Live pill breathes on a wall-clock-driven animation. The semantic
        /// expectations below therefore carry the complete journey without sampling an
        /// arbitrary animation phase.
        private static func fullDeliverySteps(
            terminalState: UIStatePattern,
            disposition: String,
            bundleID: String,
            reportLabel: String,
            reportDetail: UIText
        ) -> [UIFlowStep] {
            [
                .act(.press(Selector.startDictation)),
                .wait(.state(.checkingPermissions)),
                .check("checking-permissions", [.state(.checkingPermissions), .text(.equals("Working"), .exactly(1))]),
                .release(.permission),
                .wait(.state(.recording)),
                .check(
                    "live",
                    [
                        .state(.recording),
                        .text(.equals("Live"), .exactly(1)),
                        .exists(Selector.stopDictation),
                    ]
                ),
                .act(.press(Selector.stopDictation)),
                .wait(.state(.finalizingAudio)),
                .check("finalizing-audio", [.state(.finalizingAudio), .text(.equals("Working"), .exactly(1))]),
                .release(.recorderStop),
                .wait(.state(.transcribing)),
                .check("transcribing", [.state(.transcribing), .text(.equals("Working"), .exactly(1))]),
                .release(.transcription),
                .wait(.state(.readyToInsert)),
                .check("ready-to-insert", [.state(.readyToInsert), .text(.equals("Working"), .exactly(1))]),
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
                        // `InsertionOutcome.summary(in:)` defines the exact outcome words.
                        .text(.equals(reportLabel), .exactly(1)),
                        .text(reportDetail, .exactly(1)),
                    ]
                ),
            ]
        }

        // MARK: Overlay

        private static var overlayFlows: [UIFlow] {
            [
                UIFlow(
                    id: "overlay.recording.actions",
                    title: "The recording island publishes both labelled actions and no controls",
                    tags: ["overlay", "dictation"],
                    host: .overlay,
                    fixture: .static(.recording),
                    steps: [
                        .check(
                            "actions",
                            [
                                .exists(Selector.dictationStatus),
                                .value(Selector.dictationStatus, .equals("Speaking")),
                                // The island is one procedural body: nothing in it is a
                                // control, so the two actions the discs used to carry
                                // live on the status element itself.
                                .count(.role("AXButton"), .exactly(0)),
                                .actions(
                                    Selector.dictationStatus,
                                    ["Finish recording", "Cancel recording"]
                                ),
                            ]
                        )
                    ]),
                warmupFlow,
                overlayCopyOnlyFlow,
                overlayASRErrorFlow,
            ]
        }

        private static var overlayASRErrorFlow: UIFlow {
            let failure = UserFacingDictationFailure(code: .insufficientDiskSpace, detail: nil)
            return UIFlow(
                id: "overlay.asr-error",
                title: "A sidecar refusal announces its actionable cause without confirming delivery",
                tags: ["overlay", "dictation", "error"],
                host: .overlay,
                fixture: .dictationError(code: .insufficientDiskSpace),
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
                    .wait(.state(.error)),
                    .check(
                        "failed-with-cause",
                        [
                            .value(Selector.dictationStatus, .equals(failure.cause)),
                            .actions(Selector.dictationStatus, []),
                            .model(.deliveryCount, .equals("0")),
                            .model(.recentSessionCount, .equals("0")),
                            .model(.processingInFlight, .equals("false")),
                        ]
                    ),
                ]
            )
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
                    outcome: .copiedOnly(reason: InsertionSafetyPolicy.targetClassReason(.terminal)),
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
                    .check(
                        "processing-action",
                        [
                            .actions(
                                Selector.dictationStatus,
                                ["Cancel dictation"]
                            ),
                            .count(.role("AXButton"), .exactly(0)),
                        ]
                    ),
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
                            .actions(Selector.dictationStatus, []),
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

        /// The capture-live boundary the surface used to hide.
        ///
        /// `AudioRecording.captureIsLive()` used to be answered by the protocol default
        /// `true`, or by the first tap callback even when it held zeros. A cold Bluetooth
        /// link can therefore spend 1.4 seconds in `.recording` before real audio arrives.
        /// This journey holds that boundary: one stable status element moves from
        /// "Microphone starting" to "Speaking", while the distinct warming and speaking
        /// mercury poses are pinned by their scene goldens.
        private static var warmupFlow: UIFlow {
            UIFlow(
                id: "overlay.capture.warmup",
                title: "The island reports microphone warm-up until audio is really live",
                tags: ["overlay", "dictation", "warmup"],
                host: .overlay,
                fixture: .captureWarmup(),
                steps: [
                    // Before anything starts there is no body and no element at all: the
                    // panel is a hole, so a click reaches the app underneath.
                    .check(
                        "idle",
                        [
                            .state(.idle),
                            .absent(Selector.dictationStatus),
                            .count(.role("AXButton"), .exactly(0)),
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
                            .actions(
                                Selector.dictationStatus,
                                ["Finish recording", "Cancel recording"]
                            ),
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
    }

#endif
