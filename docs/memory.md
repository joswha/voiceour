# Memory contract

The memory folder: what it holds, how it is laid out and written, when the app folds dictations into it, and what agents may do with it. The Journal lenses that show it belong to [console-ui.md](console-ui.md); the History record and the persistence tail it shares belong to [runtime.md › Persistence](runtime.md#persistence). [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

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
- Deleting a transcript deletes the History row and the memory entry with its id, whichever exist; a Journal reading row offers Delete Entry… for an entry History no longer holds. Clear History leaves memory alone; its confirmation's “Clear History and Memory” erases both. Clear Memory removes the whole folder, `agents/` included, behind every write already queued, and fails while the app is terminating.
- An agent-session binding that attaches to, refreshes on, or is stripped from a History row MUST be mirrored onto the memory entry with the same id. Turning agent session binding off strips `thread` from every memory entry, not only those with a History row.
- An unreadable month file, `topics.json`, or an `entries/` that cannot be listed is set aside as `<name>.corrupt-<ISO8601>` and reported: “Memory could not be read — kept as <file>.”, or “Memory could not be read and could not be set aside.” when the move fails. Everything else still loads. NEVER overwrite an unreadable file with what memory believes it held.
- A failed write reports “Memory could not be saved.” and NEVER blocks a later write; a failed clear reports “Memory could not be erased.” NEVER suppress either.

## Agent access

- Agents read the folder directly as files; Voiceour offers no server, socket or API for it. `MEMORY.md` tells an agent how to read the folder and where it may write.
- `MemoryPages.agentInstructions(root:)` (`Sources/VoiceCore/MemoryAgentInstructions.swift`) is the paragraph a user pastes into an agent's instructions file, copied by Settings ▸ Memory ▸ Copy Agent Instructions: it names the folder, says to read `MEMORY.md` first and follow its rules, and to write only inside `agents/`. Its wording is fixed; NEVER add the user's text, ids or paths other than the root.
- Agents write only under `agents/`: Markdown files whose front matter names `author` and a `day` or `topic`. Voiceour overwrites or deletes every other file without notice.

## Privacy

- Nothing in memory leaves the Mac through Voiceour. Memory is uncapped and kept until the user deletes an entry or clears memory.
- Diagnostics name the switch state (`keep dictations in memory: on|off`), the entry count (`memory entries: <count>`) and the folder path (`memory:` under storage). NEVER entry text, topic names, session ids or session paths.
