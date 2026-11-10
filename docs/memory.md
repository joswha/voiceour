# Memory contract

The memory folder: what it holds, how it is laid out and written, when the app folds dictations into it, the user's topics, the sorting model's labels, and what agents may do with it. The Journal lenses that show it belong to [console-ui.md](console-ui.md); the History record and the persistence tail it shares belong to [runtime.md › Persistence](runtime.md#persistence); the label request on the wire belongs to [runtime.md › Local-first and network policy](runtime.md#local-first-and-network-policy). [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

## Principle

- Memory holds what the user said, verbatim: every dictation it keeps and every note. NEVER alter an entry's `text`; a page quotes it exactly, adding only the continuation indent ([Pages](#pages)).
- A model MAY label an entry (`EntryLabel`: kind, topic, keep, each with its confidence) and NEVER writes one. No model output becomes entry text, page prose or a topic.
- Text written by an agent lives only under `agents/`. Voiceour writes every other file in the folder and NEVER reads, writes or moves anything under `agents/`; it removes `agents/` only with the rest of the folder on Clear Memory.

## Folder and files

`MemoryStore` (`Sources/VoiceCore/MemoryStore.swift`) owns the folder: `<support>/memory/`, `<support>` being the support directory of [runtime.md › Persistence](runtime.md#persistence), so `VOICEOUR_SUPPORT_DIR` moves it too.

| path | contents |
| --- | --- |
| `entries/YYYY-MM.json` | Source of truth: that month's entries, a JSON array, oldest first. |
| `topics.json` | The user's topics: `id`, `name`, `summary`, `created_at`. Absent when there are none. |
| `MEMORY.md` | Index: counts, layout, rules for agents, topics, recent days and threads. |
| `days/YYYY-MM-DD.md` | One day. |
| `threads/<agent>-<session id>.md` | One agent session. |
| `topics/<topic id>.md` | One topic. |
| `notes/YYYY-MM.md` | One month's notes. |
| `agents/` | Written by agents only. |

- Every file except `entries/` and `topics.json` is derived from them and MUST be rewritten deterministically: one state renders the same bytes on every run, on every Mac.
- Files MUST be owner-only (0600) and directories 0700, the root included. Each file is written atomically; there is no cross-file transaction, so a later write repairs what an interrupted one left.
- JSON: ISO 8601 dates with a time zone (`2026-11-10T09:27:19Z`), sorted keys, pretty printed, slashes unescaped. A month or topic list that becomes empty removes its file; a page with nothing left to show is removed.
- Months, days and note months are read in the time zone of the calendar the planner is given, so an entry made late on the last evening of a month files under the month the user lived it in.

## Entries

`MemoryEntry` (`Sources/VoiceCore/MemoryEntry.swift`), one per dictation or note.

| JSON key | meaning |
| --- | --- |
| `id` | UUID. A dictation keeps its History row id; memory and History match on it. |
| `created_at` | When the dictation was delivered or the note saved. |
| `kind` | `dictation`, or `note`: saved and delivered nowhere. |
| `text` | The user's words, verbatim. |
| `app_bundle_id`, `app_name` | Delivery target; absent for a note or an unrecorded target. |
| `thread` | The agent session it went into: `agent`, `session_id`, `title`, `working_directory`, `resumable`, `sent` (absent = send check pending). |
| `capture_seconds` | Measured speaking time; 0 when unmeasured. |
| `user_topic_id` | The topic the user filed it under. |
| `user_removed_topic` | The user removed it from every topic. |
| `label` | The sorting model's labels: `kind`, `kind_confidence`, `topic_id`, `topic_confidence`, `keep` (0–3), `model`, `labeled_at`. |

- Decoding MUST be lenient so a field never costs the entry its text. Required: `id`, `created_at`, `text`. An unknown `kind` reads as `dictation`; a missing `capture_seconds` as 0 and `user_removed_topic` as false; a malformed `thread` or `label` reads as absent.
- `thread` requires `agent` and `session_id`; a blank `title` or `working_directory` reads as absent, a missing `resumable` as false. `label` requires `model` and `labeled_at`; any other field that is missing, malformed or an unknown kind reads as absent.
- A month file that is not a JSON array of entries is unreadable as a whole ([Lifecycle](#lifecycle)).
- Effective topic (`effectiveTopicID(known:)`), first match wins: when `user_topic_id` is set, that topic if it is known, else nothing; nothing when `user_removed_topic`; the label's topic when it is known and `topic_confidence` ≥ 0.6 (`OrganizerPolicy.topicConfidence`); else nothing. A model label NEVER overrides a user choice, including a choice whose topic was since deleted.
- Topic ids are slugs of `a-z`, `0-9` and `-`, NEVER `none`; an id never changes after creation.

## Pages

`MemoryPages` (`Sources/VoiceCore/MemoryPages.swift`) renders every page; its source holds the exact text, which this file does not repeat.

- `MEMORY.md`: entry counts and date span, how to read the folder, the rules for agents, every topic with its count and summary, the 14 newest days and the 20 newest threads. Empty sections are omitted.
- Day page: a summary line, the day's highlights (confident decision, idea, to-do and question labels), then one section per block in time order. Blocks are `JournalQuery.rewind` blocks (`Sources/VoiceCore/Journal.swift`), so a day page and the Rewind lens group a day identically.
- Thread page: agent, session id, project, directory, resume command when resumable, entry count and span, then entries by day, marked `note` or `not sent`.
- Topic page: name, summary, id, count, then entries by day with their source (agent and project, app, or `note`).
- Notes page: the month's notes by day.
- Pages MUST be pure functions of their arguments: NEVER the clock, the locale, the current calendar or a formatter with implicit settings. Times are `HH:mm:ss` or `HH:mm`, dates `YYYY-MM-DD`, zero-padded by hand in the given calendar's time zone; weekday names are English from a fixed array.
- An entry's text keeps its line breaks; every line after the first is indented two spaces so it stays inside its list item. Nothing else in the text changes.
- Thread and topic file names replace every character outside `A-Z a-z 0-9 . _ -` with `-`, so a session id from an agent's records or a hand-edited `topics.json` can never add a path component.
- Every page ends with exactly one newline; counts use singular forms for 1.

## Write planner

- Every memory mutation except Clear Memory MUST go through `commitMemory(entries:topics:)` (`Sources/Voiceour/MemoryJournal.swift`): it publishes the new state on the main actor and enqueues the one write that brings disk to it. Clear Memory (`clearMemory()`) publishes the empty state and enqueues the folder's removal on the same tail instead, because a plan rewrites only files the store owns.
- `MemoryPlanner.write(before:after:topicsBefore:topicsAfter:calendar:)` diffs the state disk holds against the new one, off the main actor, and rewrites only what the difference touches: for each entry added, removed or changed, its month file, day page, thread page, effective-topic page and notes page, both before and after the change; for a changed topic list, `topics.json` and every old and new topic page. `MEMORY.md` is rewritten whenever anything changed; no change writes nothing.
- `MemoryPlanner.rebuild(entries:topics:calendar:)` renders every file from one state. Diffs and a rebuild over the same state MUST produce the same bytes for every file they both write.
- The planner is pure: no file system, no clock. `MemoryStore.apply` writes months, then `topics.json`, then pages, then removals.

## Lifecycle

- Launch loads the folder whenever it exists, whatever the switch says, and the Journal shows everything it holds. An absent folder is an empty memory; nothing is created until there is something to write.
- `Settings.memoryEnabled` (`memory_enabled`, off by default, “Keep dictations in memory” in Settings ▸ Memory) decides only whether each newly delivered dictation is folded in. Turning it on adds every History row memory lacks, matched by id. Turning it off stops new dictations and changes nothing already kept.
- A delivered dictation MUST fold into memory in the same main-actor turn as History and the ledger, and its files are written through the same FIFO tail (`recentSessionPersistenceTail`) after the History and ledger snapshots. Delivery NEVER waits for the memory write.
- A dictation delivered to a secure target reaches no record, memory included.
- A note (`kind: note`) MUST be saved whatever `Settings.memoryEnabled` says: the user asked for it to be kept. `recordNote(text:captureSeconds:)` (`Sources/Voiceour/MemoryJournal.swift`) commits it through `commitMemory` on the same tail, with no app, the recording's length as `capture_seconds`, and the text the note branch hands it: the whole final text for a session started as a note, whatever had focus, or the text after the spoken command ([text-pipeline.md › Spoken note command](text-pipeline.md#spoken-note-command)). Whitespace-only text is no note and ends the session as cancelled. A note has no History row and never enters the ledger, so it leaves memory only by Delete Entry…, Clear Memory or Clear History and Memory; Clear History alone NEVER removes it.
- A note's `thread` is set at most once, right after the save, when agent session binding applies to its target and the focused session resolves exactly ([runtime.md › Agent session binding](runtime.md#agent-session-binding)); its `sent` stays absent. Clear Memory cancels a link still pending.
- Deleting a transcript deletes the History row and the memory entry with its id, whichever exist; a Journal reading row offers Delete Entry… for an entry History no longer holds. Clear History leaves memory alone; its confirmation's “Clear History and Memory” erases both. Clear Memory removes the whole folder, `agents/` included, behind every write already queued, and fails while the app is terminating.
- An agent-session binding that attaches to, refreshes on, or is stripped from a History row MUST be mirrored onto the memory entry with the same id. Turning agent session binding off strips `thread` from every memory entry, not only those with a History row.
- An unreadable month file, `topics.json`, or an `entries/` that cannot be listed is set aside as `<name>.corrupt-<ISO8601>` and reported: “Memory could not be read — kept as <file>.”, or “Memory could not be read and could not be set aside.” when the move fails. Everything else still loads. NEVER overwrite an unreadable file with what memory believes it held.
- A failed write reports “Memory could not be saved.” and NEVER blocks a later write; a failed clear reports “Memory could not be erased.” NEVER suppress either.
- Clear Memory also cancels every sorting request and Sort Entries run in flight ([Sorting](#sorting)).

## Topics

- Topics are the user's. They live in `topics.json`; the sorting model NEVER creates, renames or deletes one. Every edit goes through `TopicCatalog` (`Sources/VoiceCore/TopicCatalog.swift`) and `commitMemory(entries:topics:)`: `addTopic(name:summary:)`, `updateTopic(id:name:summary:)` and `removeTopic(id:)` (`Sources/Voiceour/MemoryOrganizing.swift`), driven by the Journal's Topics lens ([console-ui.md › Topics](console-ui.md#topics)).
- A topic's id is the slug of its trimmed name: diacritics folded, lower-case ASCII letters and digits kept, every run of anything else one `-`, none at either end. The id and `created_at` are fixed at creation; a rename changes only `name` and `summary`, so pages and labels that point at the id keep pointing at it.
- Refusals (`TopicCatalog.Refusal`), and the change is not applied: `emptyName` when the slug is empty; `reserved` when it is `none`; `duplicate(<existing name>)` when another topic has that id, a name with that slug, or the same name ignoring case; `tooMany` when adding a topic past 254 (`OrganizerPolicy.maximumTopics`). A rename is compared against the other topics only, so a topic may keep its name or change its case.
- A summary is one line, the rubric the sorting model reads: line breaks become spaces and the ends are trimmed.
- Removing a topic clears `user_topic_id` on every entry the user filed under it; the entries stay in memory, unfiled. A label that named the removed topic no longer counts, because its topic is unknown.
- Filing (`fileEntry(id:underTopic:)`, the reading rows' File Under menu) is an explicit request to keep the entry: an entry only History holds is added to memory first, whatever `Settings.memoryEnabled` says. A topic sets `user_topic_id` and clears `user_removed_topic`; No Topic (nil) clears `user_topic_id` and sets `user_removed_topic`, which removes the entry from every topic, a label's included.

## Sorting

- `Settings.organizerEnabled` (`organizer_enabled`, off by default, “Sort entries with Jev” in Settings ▸ Memory) turns on TypeSafe's Jev model (`OrganizerPolicy.model`, `jev-1.14.0`) as a labeller. It does nothing without a key from `TypeSafeKeySource` ([runtime.md › Local-first and network policy](runtime.md#local-first-and-network-policy)).
- The model only labels. An answer is stored as the entry's `label`: a kind (`UtteranceKind`), a topic id from the offered topics or none, a keep score (0–3), their confidences, the model id and `labeled_at`. A newer label replaces an older one. NEVER store model output anywhere else, and NEVER let it change `text`, a topic or a user choice.
- Per entry: with the switch on and a key present, each entry that newly enters memory — a folded dictation or a saved note — is labelled once by an owned background task after its commit. Nothing waits for it: not delivery, not state, not the next dictation. Entries kept any other way, such as by turning Keep dictations in memory on or by File Under, are labelled by Sort Entries.
- Sort Entries (`sortEntries()`, the Topics lens) is an explicit run over every memory entry with no user topic, newest first, at most 500 per run and at most 4 requests at a time. A press while a run is in flight, while the switch is off or with no key does nothing. `organizerRun` publishes `done`, `total`, `failed` and `isFinished`; `cancelSortEntries()` stops the run and keeps the labels already written.
- A label is written, through `commitMemory`, only while the `.organizing` generation token it started under is current, the switch is on, termination has not begun, and the entry still exists with the same text. Turning the switch off, Clear Memory and quit cancel every organizer task and invalidate the token; the coordinator observes `.organizing` with `currentToken` and NEVER `begin`s it.
- A request that fails leaves its entry exactly as it was, unlabelled or with its earlier label, and reports nothing by itself; a Sort Entries run counts such entries in `failed`, and the Topics lens says how many could not be sorted.
- What a label changes: the effective topic ([Entries](#entries)) when its topic is known, its confidence is at least 0.6, and the user has neither filed nor removed the entry; and the highlights of the Rewind lens and day pages, which list decision, idea, to-do and question labels with kind confidence at least 0.6 (`JournalQuery.highlightConfidence`).

## Agent access

- Agents read the folder directly as files; Voiceour offers no server, socket or API for it. `MEMORY.md` tells an agent how to read the folder and where it may write.
- `MemoryPages.agentInstructions(root:)` (`Sources/VoiceCore/MemoryAgentInstructions.swift`) is the paragraph a user pastes into an agent's instructions file, copied by Settings ▸ Memory ▸ Copy Agent Instructions: it names the folder, says to read `MEMORY.md` first and follow its rules, and to write only inside `agents/`. Its wording is fixed; NEVER add the user's text, ids or paths other than the root.
- Agents write only under `agents/`: Markdown files whose front matter names `author` and a `day` or `topic`. Voiceour overwrites or deletes every other file without notice.

## Privacy

- Memory leaves the Mac through Voiceour only as label requests, and only while Sort entries with Jev is on and a key is set. Each request holds one entry's text, cut to its first 8,000 characters, and the ids, names and summaries of the first 254 topics; NEVER an agent session's id, title, project or directory, the app, a file path, audio, raw recognizer text, timings, another entry, or anything under `agents/`. It goes to TypeSafe, `POST https://api.typesafe.ai/v1/systemone`, and to no other host: a redirect is refused. What TypeSafe says about hosting, training and retention is recorded, with its sources and the date read, in [README › Model and network contract](../README.md#model-and-network-contract).
- Memory is uncapped and kept until the user deletes an entry or clears memory.
- Diagnostics name the switch state (`keep dictations in memory: on|off`), the entry count (`memory entries: <count>`), the folder path (`memory:` under storage), the sorting switch (`sort entries with jev: on|off`) and where the key comes from (`typesafe key: environment|key file|none`). NEVER the key, entry text, topic names, session ids or session paths.
