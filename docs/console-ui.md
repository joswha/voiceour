# Native UI contract

The console window, the Journal tab, and the visual vocabulary shared with the menu, Home and the island. The island itself has its own contract, [recording-island.md](recording-island.md). [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

## Console

- Native `Window("Voiceour", id: "main")`, one `TabView`: Home, Glossary, Journal, Settings. Glossary, Settings and each Journal lens are grouped `Form`s; Home is a figures page. Last tab reopens unless first-run guidance requires Home. The Journal tab's identifier stays `history`: `--console-section=history`, the `console.last-tab` default and `console.tab.history`.
- MUST use native controls: `TabView`, grouped `Form`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, `Slider`, `ColorPicker`, `DisclosureGroup`, search, context menus. NEVER custom chrome, control skins, forced dark window appearance. Preserve system accent, focus, metrics, VoiceOver, accessibility settings.
- Sliders: integer UI units with an explicit `step`; `.labelsHidden()` + `.accessibilityLabel`/`.accessibilityValue` (the spoken readout); trailing monospaced readout, hidden from AX. NEVER `minimumValueLabel`/`maximumValueLabel`: they publish tiny step buttons (`tiny-hit-target`). Radio `Picker`s stay direct Form rows; an `HStack` wrapper splits one into a group per item.
- Destructive actions MUST use titled native confirmation dialogs with destructive roles.
- App styling inside Forms: monospaced code values, `ConsoleStateMark`, `ConsoleCaption`, `ConsoleRow`, `MeterBar`, the Island showroom (production `MercurySurface`). Native-plate meters/marks use system semantic colours; `StatusChip` uses app palette.
- Ground: `NSGlassEffectView(style: .regular)` behind native section plates; no app tint. Clear only `NSWindow.isOpaque` + `backgroundColor`. Reduce Transparency → `windowBackgroundColor`. NEVER place text directly on sampled desktop or use SwiftUI `.glassEffect` in shipping views.
- Settings order: Dictation, Audio, Model, debug-only Backend, Island, Readiness, Capture, Privacy, Memory, Danger. No General tab. Memory: the “Keep dictations in memory” toggle (`setMemoryEnabled`) and Copy Agent Instructions (`MemoryPages.agentInstructions(root:)`). Danger: Clear History…, Clear Memory… (offered while `memoryExistsOnDisk`), Clear Vocabulary…. Clear History's confirmation dialog carries a second destructive button, “Clear History and Memory”, that erases memory too.
- Home/Settings MUST share `ConsoleReadiness` values, sentences, remediation. `DictationPolicy.owesFirstRunGuidance` = `Settings.hasCompletedFirstRun == false` AND both durable records empty; missing flag defaults false. `completeFirstRun()` stays outside the journaling branch: secure delivery completes onboarding; refusal/cancel/failed decode does not.
- All showing routes MUST use `ConsolePresentation`: menu, `--show-console`, `applicationShouldHandleReopen` (Dock, `open -a`, reopening), `onAppear`. Console open → `.regular`, front/deminiaturized; close → `.accessory`. `--no-activate` or `.prohibited` → no presentation management. Disable miniaturization and restoration.

## Journal

History is the record: the newest 500 dictations delivered to non-secure targets, stored in `recent-sessions.json`, cleared by Clear History. Memory is the durable, uncapped record in `<support>/memory/` ([memory.md](memory.md)). The Journal tab shows both through three lenses. Views: `ConsoleJournalTab.swift` (tab, lens picker), `ConsoleHistoryTab.swift` (Timeline), `JournalRewindLens.swift`, `JournalThreadsLens.swift`, `JournalEntryRow.swift`; pure grouping lives in `Sources/VoiceCore/Journal.swift` (`JournalQuery`).

- Every lens MUST be its own grouped `Form` whose first section is the lens picker: a native segmented `Picker` (`journal.lens`) with Timeline, Rewind, Threads. The tab always opens on Timeline; NEVER persist the lens. `RenderOverrides.journalInitialLens`, `journalInitialDay` and `journalInitialThread` pin a lens state for the harness.
- Timeline reads History's rows. Rewind and Threads read `coordinator.journalEntries`: every memory entry plus each History row memory does not hold, oldest first, memory winning for an id both hold. NEVER store anything new for them; nothing leaves the Mac.
- Derived lists (entries, days, blocks, threads, matches) MUST be rebuilt on appear, on change of History's row ids or bindings, and on change of `coordinator.memoryRevision`, NEVER in `body`.
- Rewind and Threads MUST take the calendar from `RenderOverrides.calendar ?? .current` and render month names from fixed arrays, so goldens never depend on the locale.

### Timeline

- Exactly one open transcript; its own grouped `Section` directly below selected row, inside that day. Each day names itself once and renders one–three plates.
- Closed rows: stamp, outcome mark, word count, destination icon/name, two-line preview. While one opens, others fade to 0.45 (0.8 under Increase Contrast). Open heading omits preview.
- The open transcript is the control; no detail action buttons. Single click copies all delivered text as a plain, non-transient string; transient COPIED TO CLIPBOARD mark + VoiceOver confirmation. Selection/right-click `Fix / Teach “word”` + ⌘T teaches. One footer: selected teaching surface, instruction, or copy confirmation.
- `HistoryInputMonitor`: margin click/Escape close; ⌘T teaches. Transcript MUST expose named copy/teach accessibility actions.
- Row context menu: Copy Transcript, Fix / Teach a Word, Show Only *App*, then — on an agent-bound row — Open Thread, Show Only This Agent Session and, only when `AgentSessionBinding.resumable`, Copy Resume Command (`AgentSessionBinding.resumeCommand`, shell-quoted), Delete.
- Raw (only when different), Sent (only when the bound session's sent prompt differs from the delivered text: `AgentSessionBinding.sentText != nil`) and Details MUST be sibling `DisclosureGroup`s, independent bindings, all closed on each newly opened transcript. Details: Target (friendly app + non-normal safety chip), Agent (`displayTitle` + monospaced `locationLine`, with ` · Not sent` appended when `isNotSent`; no send wording while pending), Timings, least-sure word. No evidence → omit Details. Labels MUST carry ids + explicit default AX actions; the SwiftUI triangle reports successful press without toggling.
- Search + app filter + agent-session filter are ANDed; the agent-session filter keys on `agentSession?.key`. `Menu`-wrapped inline `Picker` exists only with delivery-target rows. Facets: count descending, display label, bundle id; app name from newest row. One `N of M sessions match` caption. Last matching app row disappears → drop filter; same for the agent-session filter's last bound row. Menu re-sorts resolved labels; `RecentSessionQuery.appFacets` preserves its pure order.
- Timeline reloads derived rows when any row's `agentSession` changes, and calls `refreshAgentSessions()` on appear, when the set of row ids changes, and on selection ([runtime.md › Agent session binding](runtime.md#agent-session-binding)).
- Timeline keeps every `sessions.*` identifier.

### Rewind

- Replays one day. Navigator row: Earlier Day (`journal.rewind.earlier`), a day menu (`journal.rewind.day`), Later Day (`journal.rewind.later`); they step only through days that hold entries. The menu lists the 14 newest days, then one submenu per earlier month.
- Day figures: Entries (count and words; `journal.rewind.entries`), Speaking time (only when measured), Where (agent sessions, apps, notes), Span (first to last time).
- Then one `Section` per block, in time order. A block is a run of consecutive dictations into the same agent session, or into the same app when no session is bound; a pause longer than 30 minutes starts a new block. A subject that returns later in the day is marked “continued”. A session block shows the session title with a context menu: Open Thread and, only when resumable, Copy Resume Command.
- Search field `journal.rewind.search` (“Search everything you said”, clear `journal.rewind.search.clear`) replaces the day with matches from every day: text, session title, project folder, app name; newest first, at most 200 shown, one caption that states the count.

### Threads

- Agent sessions as pages, grouped by working directory: the folder's name is the heading; sessions with no known directory sit under “No project folder”, last. A thread row shows title, agent, dictation count, time span and not-sent count.
- Exactly one open thread; its page is its own `Section` directly below its row: Session id (`journal.threads.session`), Folder, Copy Resume Command (`journal.threads.resume`, resumable sessions only), Show in Timeline (`journal.threads.timeline`, sets Timeline's agent-session filter), then every dictation oldest first under day captions. A thread page MAY carry these two bordered buttons; the no-detail-buttons rule binds only Timeline's open transcript.
- Search field `journal.threads.search` (clear `journal.threads.search.clear`) filters threads by the same fields as Rewind.
- No bound dictation → the lens says how to turn on Settings ▸ Privacy ▸ Link dictations to agent sessions.

### Reading rows

- Rewind and Threads render dictations as `JournalEntryRow`: timestamp + the whole text, NEVER truncated. The row is the control: a click copies the text as a plain, non-transient string; transient COPIED mark + VoiceOver confirmation.
- NOT SENT mark when the bound session never sent the dictation.
- Context menu: Copy Text; Show in Timeline (row still in History); Open Thread (row has a session); Delete Entry… only when History no longer holds the entry, behind a titled confirmation dialog with a destructive role, deleting the memory entry with that id. Teach, Raw, Sent and Details stay in Timeline, and so does Delete for a row History holds; NEVER add them to a reading row.

### App identity

- `AppIdentity`: installed Finder display name > persisted name > `AppDisplayName.label(bundleId:name:)`; bundle id stays key, never display label. Icon: Home badge (monogram if uninstalled), Timeline `Control.inlineIcon`; Target/filter chip have names only.
- `InstalledAppCatalog`: sole bundle-id LaunchServices lookup, main-actor/process-lifetime cached. `RenderOverrides.installedApps` pins goldens. Live menu *Will paste into* uses `AppDisplayName` directly.

## Visual vocabulary

`DesignTokens.swift` owns values. App palette belongs to menu, island, Home only.

| token / role | contract |
| --- | --- |
| `Ink.void` | opaque sRGB (0.02, 0.03, 0.05) |
| `Text.high`, `Text.mid`, `Text.low` | (0.89, 0.91, 0.95); (0.64, 0.71, 0.80); (0.51, 0.56, 0.64) |
| cyan / mint / amber / crimson | active-live-focus / success / degraded-waiting / failure-destructive |
| `micro`, `caption`, `label` | 10 / 12 / 13 pt |
| `tileValue`, `metric`, `heroMetric` | 20 / 32 / 64 pt |
| `hair`, `xs`, `sm`, `md`, `lg`, `xl` | 2 / 4 / 8 / 12 / 16 / 24 pt |
| controls | 24 / 28 / 32 / 40 pt; compact status marks: 20 pt |

- One dominant signal colour/view. `Alien.bloom`/heat ladder: Home fill/glyph/glow only, NEVER text. Four steps = quartiles of busiest day; Differentiate Without Color substitutes size steps at one hue.
- `OnGlass` cyan/mint/amber/crimson: system-glass text only, ≥4.5:1 against white and black; not painted/opaque grounds.
- Home islands remain fixed-dark in either appearance. Paint `Ink.pane` + `glassTint` + specular/`Alien` rims; NEVER stack another material over the glass ground. Declare `surfaceGround` for contrast lint.
- `MenuBarExtra(.window)`: 280 pt, three whitespace-separated blocks: Status (state, optional mute, Fn, headline), Report (failure/transcript/outcome; absent when empty), Actions (primary + grouped commands). The transcript well holds only the transcript; a click copies it, and a mint caption under the well confirms the write until the transcript changes. Download/warmup MUST stay visible; re-poll health while acquisition advances.
- Motion: quick 0.14 s, standard 0.18 s, deliberate 0.22 s. MUST respect Reduce Motion. Animate menu report/state resizing; native console keeps system behavior; resting settings stay static except the Island showroom (live only while visible, still under Reduce Motion).
- Controls MUST have stable human labels. NEVER encode state only in colour. Chips/marks carry words; Differentiate Without Color adds symbols. Captions stay separate from control AX labels. Gesture-only behavior requires named AX actions; completion announces.
- `micro` sets only chips, keycaps, the primary capsule and chart axes. NEVER micro subtext: labels, hints or counts beside content; a fact the reader needs takes the caption voice.
