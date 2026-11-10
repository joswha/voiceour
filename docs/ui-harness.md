# Offscreen UI harness

Compiled only under `-DUI_HARNESS`, the harness renders Voiceour's real SwiftUI views in process, dumps the accessibility hierarchy, lints the semantic and raster output, and compares both with committed goldens. It never puts a window on a display, never changes the frontmost app, and needs no Screen Recording or Accessibility permission.

This file is the harness's operational reference and contract: commands, artifacts, scene and flow rules, capture procedures, and the binding [invariants](#invariants). [README.md](../README.md#verification) owns which gates a change must pass.

## Commands

| command | purpose |
| --- | --- |
| `make ui-snap` | Render all scenes; compare AX dumps and PNG digests on macOS 27. |
| `make ui-update` | Rewrite intended scene goldens. |
| `make ui-flow` | Run all flows and compare their journals. |
| `make ui-flow-update` | Rewrite intended flow journals. |
| `make ui-list`, `make ui-flow-list` | Print the scene or flow catalog as JSON. |
| `make ui-all` | All scenes and semantic flows. |
| `make ui-mercury` | Render isolated shipping/prototype material contact sheets for the island and the collar, including the garage's looks, metals, coats, room lighting, and body kit. Not a gate. |
| `make ui-mercury-bench` | Gate 4,096 seeds of each room, 64 production rasters, 64 collar sessions, 30 seconds of motion, every look over 64 rooms on the island and on the collar, 48 option corners over 64 rooms each, and 1,200 island and collar raster plus island engine-and-layer frames at represented 120 Hz, the island's for the stock look and for Street Racer. |

Scene PNG digests and AX dumps are host-sensitive: the committed goldens come from the maintainer's Apple Silicon Mac, so hosted CI runs `make ui-snap` only as an advisory job, while flow journals are host-independent and required. Bless scene goldens from a local render, never from CI output.

`scripts/ui_harness.sh` builds a debug binary with `-DUI_HARNESS` and forwards these flags. `make ui-mercury-bench` instead builds the release configuration with the same flag and runs `.build/release/Voiceour --ui-harness --repo-root . --mode mercury-benchmark` directly, so its timings measure optimized code. It prints one `mercury-benchmark:` line for the stock look and a second for the Overcast screen, the look corpus on both layouts, and the Street Racer arm, prints each failed gate as a `mercury-benchmark: FAIL:` line, and writes the full report to `.build/ui-harness/mercury/benchmark.json`.

| flag | meaning |
| --- | --- |
| `--mode MODE` | `list`, `check`, `update`, `flow-list`, `flow-check`, `flow-update`, `mercury`, or `mercury-benchmark`; default `check`. |
| `--only a,b`, `--except a,b` | Include, then exclude, ids containing or tagged `a` or `b`. |
| `--out DIR`, `--golden DIR` | Artifact and golden directories; default `.build/ui-harness` and `fixtures/ui`. |
| `--repo-root DIR` | Root for both defaults, or set `VOICEOUR_REPO_ROOT`. |
| `--scale 1\|2` | Raster scale; default 1. |
| `--no-sheet`, `--stdout` | Skip the contact sheet; also print the NDJSON manifest to stdout. |

An unfiltered run includes the full catalog. Exit status is 0 when clean or updated, 1 for a changed, missing, or failed artifact or an error-severity lint finding, 2 for bad arguments.

## Artifacts and goldens

```text
.build/ui-harness/
  <scene>.png
  <scene>.ax.txt
  <scene>.ax.diff                 # present only while AX differs
  manifest.jsonl
  contact-sheet.png
  flows/
    <flow>.flow.txt
    <flow>.flow.diff              # present only while the journal differs
    manifest.jsonl
  mercury/                        # isolated material tools; no goldens
    states.png                    # every shipping state on four grounds
    motion.png                    # consecutive shipping speaking frames
    outcome-motion.png            # lurch/collapse impulse transition frames
    worlds.png                    # stock look in four seeds of each room
    looks.png                     # every look on four grounds, speaking
    metals.png                    # every metal bare and clear-coated, darkest/lightest grounds
    coats.png                     # every coat at its default, on titanium and mercury
    lighting.png                  # 10,667 / 6,504 / 4,678 K, underglow off and on
    body.png                      # body-kit corners: speaking at three crowns, listening, warming
    adaptations.png               # standard and bounded Increase Contrast
    comparison.png                # shipping and candidate, same body and room
    candidate-motion.png          # shipping/candidate temporal strips
    candidate-worlds.png          # shipping/candidate seed comparison
    room-sweep.png                # source-count/scale/bounce search
    selected-room-worlds.png      # accepted scalar/chromatic room over eight seeds
    chroma-sweep.png              # accepted room at four chroma strengths
    collar-states.png             # every shipping state on the 185×32 collar, four grounds
    collar-motion.png             # consecutive shipping speaking collar frames
    collar-looks.png              # every look on the 185×32 collar
    benchmark.json                # hard-gate room/raster/collar/look/motion/120 Hz report

fixtures/ui/
  <scene>.png.sha256
  <scene>.ax.txt
  flows/<flow>.flow.txt
```

The full PNG is for inspection; the committed raster golden is its SHA-256 digest, keeping binary churn out of history.

The collar sheets lay the body on the collar around `.fixtureNotch`'s 185×32 pt camera housing, with the island sheets' seed and room, so each collar row differs from its island row by the layout alone. They composite the housing and the bezel above the screen's top edge in black, as a display has them; the body itself draws nothing inside the housing.

Read the generated `.ax.diff` or `.flow.diff` before any update; update mode writes only changed payloads. A scene with an error-severity lint finding cannot be blessed, and neither can a failing flow.

`manifest.jsonl` starts with one `ui_run` row — mode, filter, scale, scene count, `ok`/`changed`/`missing_golden`/`written`/`failed` tallies, error and warning finding counts, timing, directories, and contact-sheet path — followed by one `ui_scene` row per rendered scene. A scene row carries its overall `status`, `pixel_status` and `ax_status` (`ok`, `changed`, `missing-golden`, `written`, or `failed`), `png_sha256` beside `golden_png_sha256`, `ax_node_count`, lint `findings` (`rule`, `severity`, `message`), warnings, and any error. `flows/manifest.jsonl` starts with a `ui_flow_run` row carrying flow and expectation tallies, then one `ui_flow` row per flow and one `ui_expectation` row per checked expectation with its expected and observed text. `make ui-list` and `make ui-flow-list` print one `ui_catalog` or `ui_flow_catalog` JSON object.

On macOS 27 the native `console.home.populated.png` capture is 99.936% opaque and 0.047% fully transparent, measured from its alpha channel. The native ground passes error-severity lint; base scenes retain Reduce Transparency off, and the dedicated accessibility scenes exercise it on.

Native accessibility titles may be attributed strings. The walker prefers a control's explicit title over its glyph/selected-text label. Dynamic state marks remain nonselectable because macOS 27's grouped-form text-selection wrapper retains its initial accessibility value; selectable History evidence supplies one plain-text accessibility representation to avoid duplicate narration.

### Committed documentation captures

`docs/media/` holds the full PNGs that public documentation displays. They are never hand-edited and never a gate.

| file | source |
| --- | --- |
| `docs/media/home-sample.png` | onscreen `scripts/console_shot.sh`, sample data, 800×1185 pt |
| `docs/media/history-sample.png` | `console.sessions.selection` |
| `docs/media/glossary-sample.png` | `console.glossary.populated` |

The two harness captures are copied straight from `.build/ui-harness/*.png` after `scripts/ui_harness.sh --only console.sessions.selection,console.glossary.populated`.

`home-sample.png` cannot come from the harness, because it is the one documentation capture that shows the console *window*. `cacheDisplay` cannot capture composited desktop glass, and the offscreen window has no title bar. It is photographed onscreen instead, which — unlike the harness — puts a real window on the display and needs Screen Recording permission for the controlling terminal, plus Accessibility trust for the resize:

```sh
CONSOLE_SHOT_SAMPLE_DATA=1 CONSOLE_SHOT_ACTIVATE=1 \
  CONSOLE_SHOT_SIZE=800x1185 CONSOLE_SHOT_SETTLE=1.5 \
  scripts/console_shot.sh home docs/media/home-sample.png
```

The first three variables are load-bearing; `CONSOLE_SHOT_SETTLE` only lengthens the pre-capture settle from its 0.6 s default. `CONSOLE_SHOT_SAMPLE_DATA=1` points the app at a scratch support directory seeded from `fixtures/media/console-sample`; without it the capture publishes the maintainer's own transcripts and the apps they dictate into. `CONSOLE_SHOT_ACTIVATE=1` lets the window become key, so the traffic lights and tab labels photograph at full strength instead of their inactive greys. `CONSOLE_SHOT_SIZE` overrides the default 800×980 window, which clips the activity grid.

The seeded directory is not the fixture copied verbatim. `scripts/seed_console_data.swift` rebases every day key, every app's `lastDay` and every transcript stamp by one offset, so the newest day lands today: the ledger prunes day buckets past 400 days, and a fixture frozen at its authored dates would eventually photograph an empty grid and a zero streak. `console.home.full-page` remains the harness golden for the same page's layout — the offscreen render is what gates a layout change; this capture only illustrates it.

Because the window is real, the Top-apps rows resolve icons through LaunchServices and show whichever of the sample bundle ids are installed on the capturing Mac. That is a property of an onscreen capture, not a seam: `RenderOverrides.installedApps` pins those only for the offscreen goldens.

`docs/media/app-icon.png` is `sips`-exported from `Resources/AppIcon.icns` at 256×256.

## Scenes

A scene is an id, size, tags, and a closure building the real view. `make ui-list` is the authoritative inventory: the console tabs and their empty, first-run, search, filtered, teach, permission and confirmation states; Settings ▸ Island and its showroom; the menu popover; the recording panel, island and collar, and the island in every look; accessibility adaptations. Every scene follows the shipping macOS 27 path.

Console fixtures run Granite (`realBackend = "granite"`, health backend id `granite-ctc`), so their scenes cover Settings ▸ Model naming Granite's single artifact, its readiness rows, and Home's 0.51 GB first-run download.

Home's first-run card needs no seam of its own. Whether it is owed is computed from three real inputs a fixture already owns — the persisted `has_completed_first_run` flag, the seeded transcript journal, and the seeded lifetime ledger — so the `firstRunDownloading`, `firstRunReady`, `firstRunAcquisitionFailed` and `erasedFigures` fixtures reach their states the way a real install does. Adding a `RenderOverrides` field for it would be a branch that exists only to make a golden pass.

`menu.sidecar-error` drives the actual coordinator through a wrapped sidecar model failure before capturing the menu. It locks the specific cause and recovery controls, rather than assigning an error state directly.

`overlay.notch.recording`, `.listening`, `.warmup`, `.processing`, `.copied`, `.lurch`, `.error`, `.reduced-motion` and `.fullscreen` render the collar around `.fixtureNotch`'s 185×32 pt camera housing on its 33 pt menu-bar band, and `overlay.notch.wide` the speaking collar around `.fixtureWideNotch`'s 220×38 pt housing on its 39 pt band. `.fullscreen` is the speaking collar with the model's pose context saying the frontmost window fills the display, so its film runs along both ears into the empty band. Each is the canvas alone, as the island scenes are: 314×59 and 349×65 pt, the collar's whole panel. The showroom's own per-pose models, `IslandShowroomPose.model()`, supply the island and collar scenes' states, except `.lurch` and `.error`, which build their own outcomes, and the model carries the layout `UIFixtures.collarLayout(on:)` resolves through `RecordingOverlayLayout.forDisplay(_:)`, the resolution the panel makes; it traps on a display that would fall back to the island.

`UIFixtures.pinProcessSeams()` pins `RenderOverrides.overlayDisplay` to `.fixtureNotchless`, beside the mercury pins, so anything that resolves the overlay's display reads the island's notchless display instead of the rendering Mac's screen. The collar scenes set their layout on the model rather than through that seam.

`overlay.island.overcast`, the `overlay.island.look.<look>` scenes, one for every look other than Stock, and `overlay.notch.look.street-racer`, the speaking collar in Street Racer, pass their appearance straight to `RecordingOverlayView`; every other overlay scene renders the stock appearance. No seam is involved. Street Racer changes every input a look reaches, so the collar scene locks a look's paint, room lighting, response, and body kit on the collar's layout, where the body kit keeps the housing's length.

Settings ▸ Island has its own scenes. `console.settings.island.tuning` opens every fold at stock; `console.settings.island.look` shows a non-stock look's readouts and the rows its choices enable; `console.settings.island.custom` shows the CUSTOM mark — Arctic Platinum with its Finish moved — beside a persisted free placement, with Dock Island enabled above the free caption; `console.settings.island.outcome` holds the showroom at an outcome pose, where Play Again appears but is never pressed, because its 1.2 s hold runs on the wall clock. `a11y.island.increase-contrast` locks the disabled Brightness and Contrast rows with their caption, and `a11y.island.reduce-motion` the disabled Shimmer row with its caption; each also captures the showroom under its adaptation. The readout-focused Settings scenes — `console.settings.denied`, `console.settings.downloading`, and `a11y.differentiate-without-color` — and `console.settings.island.custom` render the whole Settings page, because the Island section puts Readiness below the 820 pt first-launch measure; `console.settings.granted` keeps that measure. Scenes that open folds are taller, sized to their open rows, and `console.settings.island.outcome` is sized to the showroom it locks.

Two seams keep the garage deterministic. `RenderOverrides.islandPlacementDefaults` points every placement read and write — Settings ▸ Island's Dock Island row, the overlay controller, and the flows' probe alike — at the harness suite `com.voiceour.ui-harness.placement`, which every seam pin resets to docked, so a free placement is always one a fixture put there and no golden encodes where the rendering Mac's user last left the island. `RenderOverrides.islandShowroomPose` pins the showroom's opening pose; it stays nil, which opens on Speaking, except in the scope of the one scene that shows an outcome pose. The pinned mercury seed also starts the showroom's room sequence and seeds Surprise Me, so its draws are part of the flow journals.

The Journal tab (`ConsoleTab.history`, golden prefix `console.sessions.`) opens on Timeline, the History list, and its Rewind and Threads lenses have scenes of their own: `console.sessions.rewind` shows the populated fixture's newest day; `console.sessions.rewind.search` types `accessibility` into `journal.rewind.search` and settles, as `console.sessions.search` does; `console.sessions.threads` lists the fixture's agent sessions with none open; `console.sessions.threads.open` shows the page of `UIFixtures.agentSession`'s thread; `console.sessions.rewind.empty` and `console.sessions.threads.empty` render both lenses on the `firstRun` fixture. Three seams say where the tab opens: `RenderOverrides.journalInitialLens` the lens, `journalInitialDay` the day Rewind shows, and `journalInitialThread` the thread Threads shows open. Each stays nil, which is Timeline, Rewind's newest day and no thread, except inside `UIHarnessJournalScope`, which sets all three together and restores them on teardown, because they describe one opening state and combine with no other seam. The `console(...)` factory reaches it through its `journalLens:`, `journalDay:` and `journalThread:` parameters. A lens is pinned, never pressed: the segmented `journal.lens` picker sits in a window that never becomes key, so a scene states its lens exactly as the tab bar is driven by a binding rather than a press.

Memory reaches the harness through the coordinator's own ports, never through the support folder. Every harness coordinator, the scene fixtures' and the flows' gated dictation alike, passes `memoryWrite: { _, _ in }` and `memoryClear: { _ in }`, for the reason `recentSessionSnapshotSave` is a no-op there: a scene or a scripted turn of the switch must not depend on a scratch-file write or removal completing. The derived `MemoryStore` stays in the fixture's scratch directory, so `memoryExistsOnDisk` is always false and Settings offers Clear Memory only while memory holds entries. Each coordinator also receives what the folder holds from its `memoryLoad` closure instead of reading it: the flows' gated dictation states an empty folder, and scene fixtures state theirs through `UIFixtures.make(memory:)`, empty except in the `remembered` fixture: the populated History with `memoryEnabled` on, the nine History rows as memory entries under their History ids, and twelve older dictations History no longer holds, on 2025-05-20, 2025-05-28 and 2025-06-03, some in the fixture's omp session (one of them not sent) and the rest in apps, all built from `fixedIdentifier` and the pinned clock. `UIFixtures.pinProcessSeams()` pins `RenderOverrides.memoryPath` to `/Users/harness/Library/Application Support/Voiceour/memory` beside the other storage paths, so Diagnostics never prints this Mac's home folder. `console.sessions.rewind.memory` opens Rewind on `UIFixtures.rememberedDay`, 2025-05-28, a day only memory holds, with a continued omp block; `console.sessions.threads.memory` opens the omp thread, whose page reaches back past History's oldest row.

The `remembered` folder also holds three notes (`MemoryEntry.kind == .note`, no app), built from `fixedIdentifier` and the pinned clock like its dictations: one taken in the fixture's omp session on 2025-05-20, its `sent` nil because a note has no send check, and two with no session on 2025-05-28, an afternoon apart. So `console.sessions.rewind.memory` also shows a Notes block and its continuation that evening, and `console.sessions.threads.memory` lists the omp note on the thread's page. The Notes lens has two scenes: `console.sessions.notes` lists the three notes in their two day groups, newest first, and `console.sessions.notes.empty` renders the lens on the `populated` fixture, whose memory holds no note. Menu scenes need nothing new: the Take a Note row (`menu.take-note`) renders wherever the menu is idle and ungated.

The `remembered` folder also holds three topics (`UIFixtures.rememberedTopics`: Memory folder, Offscreen harness, Planning), handed over by the same `memoryLoad` closure through `UIFixtures.make(memory:topics:)`, and about half its entries carry labels stamped `OrganizerPolicy.model` at the pinned instant. On 2025-05-20, `UIFixtures.labelledDay`, an idea, a decision, a to-do and the omp note's question sit at or above `JournalQuery.highlightConfidence`; no other day holds a highlight kind that confident, and 2025-05-28 holds a decision at 0.55 so the bar itself is in a golden. Confident topic labels file several entries, one topic label sits at 0.42 under an entry the user filed by hand under another topic, and one note is filed by hand with no label at all, so Memory folder counts seven entries, Offscreen harness three and Planning two. The labels add highlight marks to rows on that day, which `console.sessions.threads.memory` and `console.sessions.notes` show on the omp note. Topics has three scenes: `console.sessions.topics` lists the three with none open; `console.sessions.topics.open` presses the first `journal.topics.row`, Memory folder, as a scene step, because no seam pins an open topic and a plain button press is one an offscreen window takes; `console.sessions.topics.empty` renders the lens on `populated`, whose memory holds no topic. `console.sessions.rewind.highlights` opens Rewind on the labelled day, led by its Highlights.

Every harness coordinator, the scene fixtures' and the flows' gated dictation alike, keeps the default `NoEntryOrganizing`, which labels nothing and reaches no network, and passes `typeSafeKeys: UIFixtures.typeSafeKeys(in: scratch)`: no environment and a `typesafe.key` in the fixture's scratch folder, which starts absent. A nil key source would read this process's environment, so a golden would change with whether the developer's shell exports `TYPESAFE_API_KEY`. Every scene therefore shows the no-key state: Topics offers no Sorting section, and Settings ▸ Memory reads "Not set" with the sorting switch disabled.

Agent notes reach the harness through the coordinator's `memoryAgentNotesLoad` port, never through an `agents/` folder. Every harness coordinator passes it explicitly: the flows' gated dictation states `{ _ in [] }`, and scene fixtures state theirs through `UIFixtures.make(agentNotes:)`, empty except in the `remembered` fixture, whose loader hands over `UIFixtures.rememberedAgentNotes`, newest modification first as `MemoryStore.loadAgentNotes()` orders them: `memoryFolderSynthesis` (`memory-folder-synthesis.md`, by omp, titled "Where the memory folder stands", topic `memory-folder`, saved 2025-05-29 09:30) and `rememberedDayRecap` (`2025-05-28-recap.md`, by omp, titled "Wednesday recap", day 2025-05-28, saved that evening at 21:05). Both are built from the pinned clock, and neither body repeats an entry's text, so a query that finds an entry by its text never finds a note too. `ConsoleJournalTab` calls `refreshAgentNotes()` on appear, so no step is needed: `console.sessions.rewind.memory` shows the recap under "From your agents", below Copy Recap Prompt and above the day's first block, and `console.sessions.topics.open` shows the synthesis on the Memory folder page below Copy Synthesis Prompt and above the page's entries. Both sit inside the default 820 pt window, so neither has a taller scene of its own; both scenes carry the `agent-notes` tag.

Scene rules:

1. Build coordinators through `UIFixtures`, never `DictationCoordinator.live()`.
2. Derive no artifact value from the current time, randomness, the system accent, local permission grants, home paths, or the developer's locale or time zone.
3. Pin those values through the existing main-actor [`RenderOverrides`](../Sources/Voiceour/RenderOverrides.swift) seams. Every seam defaults to nil or false, and at those defaults production must behave as if the type did not exist. A set seam substitutes an input or selects a path production already reaches — `override ?? realValue` for a value, `if let` for a wholesale replacement — never a branch that exists only to make a golden pass.
4. Avoid perpetual animation. Fixed run-loop pumping makes an animating scene time-dependent.
5. Extend the closest existing scene instead of starting a second fixture convention.

## Semantic flows

A flow hosts a real menu, overlay, or console view with an inert fixture, then drives real controls and `DictationCoordinator` transitions through a deterministic script. Checkpoints assert named semantics into a host-independent `.flow.txt` journal, which is the durable contract; flows own no raster or AX golden. `make ui-flow-list` is the authoritative inventory.

Failure journeys inject the same `SidecarASRClientError.protocolError` wrapper the real client throws. `dictation.asr-error` checks the engine-specific cause and zero delivery/history; `dictation.asr-recovery` presses the real Try Again control and completes a later utterance; `overlay.asr-error` checks the actionable failure announcement without a delivery confirmation. Process-level malformed JSON/schema/UTF-8 rejection and respawn are exercised separately through `ASRSidecarStub`, including a client-to-coordinator integration path.

`island.*` flows drive Settings ▸ Island through its real controls: the look, coat and room radios, the fold labels and the Material fold's Restore Stock, the underglow switch, Surprise Me, Another Room, and Dock Island. One slider moves: `island.tune-to-custom` steps Finish once through the accessibility increment, which SwiftUI brackets with editing begin and end, so the step exercises the release commit every Garage slider shares. Checkpoints read the committed look, its canonical description, whether a draft is still pending, and whether the persisted placement is docked or free, so a journal verifies the committed settings rather than only a redrawn view: `island.position-dock` presses Dock Island on a free placement and checks that the placement is docked, the button disabled, and the caption the docked one. The Metal and Pose pop-up menus are pinned by fixtures instead, because an unordered offscreen window cannot open an `NSMenu`. Undo has no flow: ⌘Z is a key equivalent that AppKit offers only to the key window, so `IslandGarageEditorTests` drive the undo steps against a standalone `UndoManager`.

`journal.*` flows host the console with `.console(.history, journalLens:)`, which wraps it in the same `UIHarnessJournalScope` the scenes use, so a flow pins its lens instead of pressing `journal.lens` and drives only the controls inside the lens. `journal.rewind.navigate` presses Earlier Day and Later Day and checks the `journal.rewind.entries` figure and whether Later Day is enabled on each day. `journal.rewind.memory-days` walks Earlier Day on the `remembered` fixture through every History day, waiting on each day's figure, into 2025-06-03, the newest day only memory holds, and checks its figure, one of its entries, and that Later Day and Earlier Day are both enabled. `journal.rewind.search` types `offscreen`, checks that the match caption counts both the entries that say it and the entries bound to the session whose title holds it, then clears the search and checks the day's figure is back. `journal.threads.open` opens and closes the fixture's omp thread from its row and checks that `journal.threads.session` names the session's id. `journal.threads.show-in-timeline` presses Show in Timeline and checks that Timeline arrives filtered to that session. Every thread row carries `journal.threads.row`, so a flow addresses one row by that identifier together with the title its label leads with.

`system.memory.toggle` presses `system.memory.toggle` in Settings on the populated fixture and checks that the switch reads on, that the model key `memoryEntryCount` (`coordinator.memoryEntries.count`, beside `recentSessionCount`) reports the nine History rows as memory entries, and that `system.memory.copy-instructions`, disabled before the press, is enabled after it.

Notes have three flows. `dictation.note.menu` presses `menu.take-note` on the gated dictation fixture, checks that the status line promises a note while recording and that the row is gone until the session ends, stops through the same `.permission`, `.recorderStop` and `.transcription` gates the dictation flows release, and checks that the transitions run `… cleaning, noteSaved, idle` with no `readyToInsert`, that the report reads NOTE SAVED with its detail, that History, deliveries and pasteboard writes all stay at zero, and that memory holds one note with the dictated text. `dictation.note.spoken-prefix` scripts a transcript that begins "Note to self, " on the same fixture and presses Start Dictation; the session is a delivery until its words are read, so its transitions pass `readyToInsert` before `noteSaved`, and the same checks then prove the note was saved without the prefix. Neither arms `.insertion`, because a note never reaches it. `journal.notes.search` pins the Notes lens on the `remembered` fixture, types `UIFixtures.rememberedNoteQuery` into `journal.notes.search`, checks that one note row remains, presses `journal.notes.search.clear`, and checks that all three are back. Note rows are counted by the `, note, ` their accessibility label carries and addressed by their text. Two model keys serve these checks beside `memoryEntryCount`: `noteCount`, the memory entries whose kind is `.note`, and `lastSavedNote`, the text of the memory entry `coordinator.lastSavedNoteID` names, read back from memory rather than from the transcript.

Topics have two flows and sorting one. `journal.topics.add` types a name and a summary into `journal.topics.new.name` and `journal.topics.new.summary` on the `populated` fixture, presses `journal.topics.add`, and checks that one `journal.topics.row` reads "Release notes, 0 entries, What ships in each version.", that both fields are empty and memory still holds no entry; it then types the same name again, presses Add Topic, and checks that `journal.topics.new.refusal` names the existing topic and the list still holds one row. `journal.topics.open` presses the Memory folder row on the `remembered` fixture, addressed by `journal.topics.row` together with its name, checks that its label counts seven entries, that `journal.topics.name` and `journal.topics.summary` hold the topic's own words, and that the page lists exactly `UIFixtures.memoryFolderTexts` and no entry of another topic, then presses the row again and checks the page is gone. `system.organizer.key` opens Settings on `populated`, checks that `system.organizer.key.status` reads "Not set" and `system.organizer.toggle` is disabled, types the made-up key `test-key-123` into `system.organizer.key.field`, presses `system.organizer.key.save`, and checks that the status reads "Saved in typesafe.key", the field is empty, Remove Key is offered, the switch is enabled and still off, and no static text, label or value in the tree holds the key's text. The key is written to the fixture's scratch folder, never to the support directory. No flow presses Sort Entries: with `NoEntryOrganizing` a run would only count failures.

Agent notes have two flows on the `remembered` fixture, and both press a copy button. Every flow's `UIFlowContext` installs `GeneralPasteboard.writeOverride` before its script runs, static console fixtures included, so the press lands in the effect recorder and never on the real clipboard. Neither checks `pasteboardText`: a prompt names the fixture's scratch memory folder, an absolute path. `journal.rewind.recap-prompt` checks on the newest day that `journal.rewind.recap-prompt` is offered, no COPIED mark shows and `pasteboardWrites` is 0; walks Earlier Day as `journal.rewind.memory-days` does, waiting on each day's figure, one day further to 2025-05-28; waits on the `journal.rewind.agent-note` row holding the caption "Wednesday recap · by omp"; presses Copy Recap Prompt, waits for the COPIED mark and checks `pasteboardWrites` is 1; then presses Later Day back to 2025-06-03 and checks that no agent note shows there. `journal.topics.synthesis-prompt` checks that neither a `journal.topics.agent-note` row nor `journal.topics.synthesis-prompt` shows while every topic is shut and `pasteboardWrites` is 0, presses the Memory folder row, waits on the note row captioned "Where the memory folder stands · by omp", presses Copy Synthesis Prompt, waits for the COPIED mark and checks `pasteboardWrites` is 1. The COPIED mark clears after 1.4 s of wall clock, so each flow checks it straight after the wait that saw it and never after a later step.

## Invariants

- `UIHarnessRuntime.prepareProcess()` MUST set `.prohibited` before hosting, reassert before/after hosting, and enforce it in `ConsolePresentation` + app delegate first-run guards. `.accessory` or key refusal is insufficient. Ignore `setActivationPolicy(.prohibited)`'s false return; policy still applies.
- MUST initialize `NSApplication.shared` + `finishLaunching()` before CoreGraphics window APIs.
- `OffscreenWindow` parks at (-30,000, -30,000). `constrainFrameRect(_:to:)` MUST return the requested frame without `super`; otherwise AppKit pulls it onscreen. NEVER become key/main or order front; swallow ordinary ordering and `orderFrontRegardless`; permit order-out for close.
- MUST enable enhanced accessibility before the dump; otherwise `NSHostingView` exposes a near-empty AX tree.
- Fixed pump: 150 × 1 ms before/after interaction; 30 at teardown. Each iteration runs a run-loop slice AND drains posted events. NEVER replace with sleep, run-loop-only, or adaptive “stable” capture; animations make adaptive sampling nondeterministic.
- Capture uses `cacheDisplay(in:to:)` into an owned interleaved RGBA8 `NSBitmapImageRep`, `.deviceRGB`, with alpha. NEVER system caching bitmap (monitor profile/cICP drift), alpha removal (subpixel smoothing), or `ImageRenderer` (AppKit placeholders).
- Offscreen capture cannot sample composited console/menu glass or blur/shadow filters. NEVER weaken offscreen guarantees to recover them; real material inspection requires an agreed onscreen check, `CONSOLE_SHOT_COMPOSITED=1 scripts/console_shot.sh <tab>`.
- Mercury is a `CGImage`, seed/step-pinned (room and look come from the appearance under test), with no display link during capture: the harness pins `RenderOverrides.mercurySeed` and `RenderOverrides.mercuryStep` for the whole process, so the island, the collar and the Settings showroom each write one exact `CGImage` through the production engine, room and rasterizer. Scene goldens and `make ui-mercury` artifacts are the material proof.
- Flows cover tabs and delivered/copy-only/cancel/error journeys. Offscreen key refusal prevents History click-to-copy/⌘T; unordered windows cannot open filter `NSMenu` or a row's context menu. `console.sessions.selection`, `console.sessions.teach`, `console.sessions.deselected`, `console.sessions.filtered`, `console.sessions.agent-filtered` pin states, not gesture execution; live gesture verification requires consent. The Journal's lens, Rewind's day and the open thread are pinned through `UIHarnessJournalScope`, never pressed; `journal.*` flows pin the lens through `UIFlowHost.console(_:journalLens:)`. `sessions.agent-link` drives the Sent and Details folds of a fixture row bound to an agent session; fixture coordinators keep binding off with `NoAgentSessionResolving` and `NoAgentSessionReading`, so the harness never runs `tern`, inspects processes, or reads the home folder. Island flows drive looks, coats, rooms, folds, Restore Stock, underglow, Surprise Me, Another Room and Dock Island, plus one slider step (`island.tune-to-custom`: AX increment on Finish) through the release commit every Garage slider shares; checkpoints read committed state. Metal and Pose menus are pinned by fixtures; ⌘Z needs a key window, so `IslandGarageEditorTests` own undo.
- Harness coordinators MUST pass inert `memoryWrite` and `memoryClear`, state memory through `memoryLoad` (`UIFixtures.make(memory:)`) and agent notes through `memoryAgentNotesLoad` (`UIFixtures.make(agentNotes:)`), so no scene or flow reads or writes a memory folder or its `agents/`, the real support directory's least of all. `RenderOverrides.memoryPath` is pinned with the other storage paths.
- Harness coordinators MUST keep the default `NoEntryOrganizing` (or a canned in-memory organizer) and pass `typeSafeKeys: UIFixtures.typeSafeKeys(in:)`, so no scene or flow reaches the network or reads the process environment or the support directory's `typesafe.key`.
- `RenderOverrides` is production-compiled. Every default MUST be nil/false and behavior-neutral. Values use `override ?? realValue`; replacements use `if let`. Seams MUST substitute real inputs/reachable states, NEVER fabricate outcomes or golden-only branches.
- Allowed seams: time/locale/calendar/timezone, permissions/paths/accessibility, History selection/filter/agent-session filter/teach surface, Journal opening lens/Rewind day/open thread, installed apps/microphones, mercury seed (session and showroom rooms, Surprise Me)/step, overlay display, island placement defaults, island showroom pose, text-role instrumentation, agent session ports fixed to `NoAgentSessionResolving`/`NoAgentSessionReading` (fixture bindings are History rows, never resolved). Preserve `historyStartsDeselected`, `historyInitialAppFilter`, `historyInitialAgentSession`, `historyTeachSurface`, `journalInitialLens`, `journalInitialDay`, `journalInitialThread`, `availableMicrophones`, `installedApps`, `islandPlacementDefaults`, `islandShowroomPose`, `textRoleRecorder`; [RenderOverrides.swift](../Sources/Voiceour/RenderOverrides.swift) owns exact fields/rationales.
- MUST read `.ax.diff`/`.flow.diff` before blessing. NEVER bless error-severity lint or red flows. Filtered runs are iteration aids, not full-catalog proof. CI flows required; hosted scene snapshots advisory. NEVER bless CI raster drift.
