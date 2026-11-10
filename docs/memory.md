# Memory contract

The memory folder: what it holds, how it is laid out and written, when the app folds dictations into it, the user's topics, the sorting model's labels, what agents may do with it, and how their notes come back. The Journal lenses that show it belong to [console-ui.md](console-ui.md); the History record and the persistence tail it shares belong to [runtime.md › Persistence](runtime.md#persistence); the label request on the wire belongs to [runtime.md › Local-first and network policy](runtime.md#local-first-and-network-policy). [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

## Principle

- Memory holds what the user said, verbatim: every dictation it keeps and every note. NEVER alter an entry's `text`; a page quotes it exactly, adding only the continuation indent ([Pages](#pages)).
- A model MAY label an entry (`EntryLabel`: kind, topic, keep, each with its confidence) and NEVER writes one. No model output becomes entry text, page prose or a topic. Voiceour NEVER calls a model that writes text: a recap, a synthesis or an outcome note is written by the user's own agent, from a prompt the user copies or the skill's recipe ([Agent access](#agent-access)).
- Text written by an agent lives only under `agents/`. Voiceour writes every other file in the folder. Under `agents/` it only reads: it shows each Markdown note there as plain text under the day or topic the note names and on the thread its `session` names, and NEVER writes, edits, moves, labels, searches or sends a file there. It removes `agents/` only with the rest of the folder on Clear Memory.

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
| `pages-format` | The stamp of the last finished pages rebuild, `2 gregorian <time zone id>` and a newline ([Write planner](#write-planner)). |
| `skills/voiceour-memory/SKILL.md` | The agent skill, written by Voiceour: fixed wording whose only variable is the root's path ([Agent skill](#agent-skill)). |
| `agents/` | Written by agents only. Voiceour reads the notes there and never writes ([Agent access](#agent-access)). |

- `MEMORY.md` and every page under `days/`, `threads/`, `topics/` and `notes/` are derived from `entries/` and `topics.json` and MUST be rewritten deterministically: one state renders the same bytes on every run, on every Mac. The skill is derived from nothing but the root's path, so one root renders the same bytes on every run.
- Files MUST be owner-only (0600) and directories 0700, the root included. Each file is written atomically; there is no cross-file transaction, so a later write repairs what an interrupted one left.
- JSON: ISO 8601 dates with a time zone (`2026-11-10T09:27:19Z`), sorted keys, pretty printed, slashes unescaped. A month or topic list that becomes empty removes its file; a page with nothing left to show is removed.
- Every path, page and prompt is read in the planner calendar (`memoryCalendar`, `Sources/Voiceour/MemoryJournal.swift`): the Gregorian calendar whatever the user's calendar setting, because the folder's `YYYY-MM-DD` and `YYYY-MM` names are Gregorian, in `TimeZone.current`, so an entry made late on the last evening of a month files under the month the user lived it in. A test or harness clock pins the zone through the runtime calendar.

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
| `unlinked` | Why a link to the agent session was attempted and missed: one [`AgentLinkMiss` raw value](runtime.md#link-miss-reasons). Absent = linked, not attempted, or unknown. Never with `thread`; no page shows it. |
| `capture_seconds` | Measured speaking time; 0 when unmeasured. |
| `user_topic_id` | The topic the user filed it under. |
| `user_removed_topic` | The user removed it from every topic. |
| `label` | The sorting model's labels: `kind`, `kind_confidence`, `topic_id`, `topic_confidence`, `keep` (0–3), `model`, `labeled_at`. |

- Decoding MUST be lenient so a field never costs the entry its text. Required: `id`, `created_at`, `text`. An unknown `kind` reads as `dictation`; a missing `capture_seconds` as 0 and `user_removed_topic` as false; a malformed `thread` or `label`, and an unknown or malformed `unlinked`, reads as absent. `unlinked` is written only when set.
- `thread` requires `agent` and `session_id`; a blank `title` or `working_directory` reads as absent, a missing `resumable` as false. `label` requires `model` and `labeled_at`; any other field that is missing, malformed or an unknown kind reads as absent.
- A month file that is not a JSON array of entries is unreadable as a whole ([Lifecycle](#lifecycle)).
- Effective topic (`effectiveTopicID(known:)`), first match wins: when `user_topic_id` is set, that topic if it is known, else nothing; nothing when `user_removed_topic`; the label's topic when it is known and `topic_confidence` ≥ 0.6 (`OrganizerPolicy.topicConfidence`); else nothing. A model label NEVER overrides a user choice, including a choice whose topic was since deleted.
- Topic ids are slugs of `a-z`, `0-9` and `-`, NEVER `none`; an id never changes after creation.

## Pages

`MemoryPages` (`Sources/VoiceCore/MemoryPages.swift`) renders every page; its source holds the fixed prose. This section is the format an agent parses: page format 2.

### Front matter

Every page begins with a block: a line `---`, flat `key: value` lines in the order below, then a line `---`. The block reads with [`AgentNoteParser`'s front matter rules](#agent-access). Numbers, booleans (`true`, `false`), dates and times are bare. An id (`session`, `topic`, `month`) is bare when it holds only `A-Z a-z 0-9 . _ -`, else a JSON string literal; `directory` is always one. A JSON string literal escapes `"`, `\`, every control character and U+0085, U+2028 and U+2029, so a value from the records never leaves its line. Titles and names appear only in the `#` heading.

| page | keys after `format: 2`, `type: <type>`, `tz: <time zone id>` |
| --- | --- |
| `MEMORY.md`, type `index` | `entries`, `dictations`, `notes`; then `first: YYYY-MM-DD`, `last: YYYY-MM-DD` when there are entries |
| day, type `day` | `date: YYYY-MM-DD`, `entries`, `words`, `threads`, `notes` |
| thread, type `thread` | `agent: <omp\|claude-code>`, `session`, `directory` (absent when unknown), `resumable`, `entries`, `not_sent`, `unchecked`, `first: YYYY-MM-DD HH:mm`, `last: YYYY-MM-DD HH:mm` |
| topic, type `topic` | `topic: <topic id>`, `entries` |
| notes, type `notes` | `month: YYYY-MM`, `entries` |

`tz` is the planner calendar's time zone identifier; every date and time on the page is in it.

### Entry lines

Every entry on a day, thread, topic or notes page is one list item: `- HH:mm:ss · <id> · <state> · <text>`. A reader splits at the first three ` · `; the text comes last and nothing follows it.

- `<id>`: the last 12 characters of the entry's `id` as `entries/*.json` writes it (uppercase hex). When two entries on the same page share those 12 characters, both lines on that page carry the whole id. The rule looks at one page only, so a diff and a rebuild print the same id.
- `<state>`, first match wins: `note` (kind note); `sent`, `not sent` or `unchecked` for an entry with a `thread` whose `sent` is true, false or absent (`unchecked`: the send check has not decided, and may never); `unlinked` (no thread, `unlinked` set); `dictation`.
- `<text>`: the entry's text verbatim. It keeps its line breaks; every line after the first is indented two spaces so it stays inside its list item. Nothing else in the text changes.
- A day page's Highlights use the same line with the label's kind in the state slot: `decision`, `idea`, `to-do`, `question`.

### Page bodies

After the front matter, sections are separated by one blank line; a page ends with exactly one newline; counts use singular forms for 1. Empty sections are omitted. `## YYYY-MM-DD` opens each day's entry lines, oldest first, on thread, topic and notes pages.

- `MEMORY.md`: `# Voiceour memory`, the entry counts and date span, How to read this folder, Rules for agents, every topic with its count and summary, the 14 newest days and the 20 newest threads, each a link to its page. How to read this folder ends with two bullets: the entry line (`Each entry line reads time · id · state · text.`, naming every state), and how an agent finds its own thread: omp, `threads/omp-<id>.md` with `<id>` the UUID after `Z_` in `$PI_SESSION_FILE`; Claude Code, `threads/claude-code-$CLAUDE_CODE_SESSION_ID.md`; no file means nothing was linked, so read today's day page.
- Day page: `# YYYY-MM-DD, <English weekday>`, a summary line of the nonzero counts (entries, words, agent sessions, apps, notes) joined by ` · `, the day's Highlights (decision, idea, to-do and question labels at or above `JournalQuery.highlightConfidence`), then one section per block in time order headed `## HH:mm–HH:mm · <source>` (`## HH:mm · <source>` when both ends match), with ` · continued` appended when the same source already had a block earlier that day. The source is the agent's name and project, followed by a line linking the thread page; `Notes`; the app's name, or its bundle id; or `Unknown target`. Blocks are `JournalQuery.rewind` blocks (`Sources/VoiceCore/Journal.swift`), so a day page and the Rewind lens group a day identically.
- Thread page: `# <thread title>`, then a line `Resume:` and the resume command in backticks when the session is resumable, then entries by day.
- Topic page: `# <topic name>`, its summary when set, then entries by day. A topic with no entry still has a page.
- Notes page: `# Notes, YYYY-MM`, then the month's notes by day.
- Pages MUST be pure functions of their arguments: NEVER the clock, the locale, the current calendar or a formatter with implicit settings. Times are `HH:mm:ss` or `HH:mm`, dates `YYYY-MM-DD`, zero-padded by hand in the given calendar's time zone; weekday names are English from a fixed array.
- Thread and topic file names replace every character outside `A-Z a-z 0-9 . _ -` with `-`, so a session id from an agent's records or a hand-edited `topics.json` can never add a path component.

## Write planner

- Every memory mutation except Clear Memory MUST go through `commitMemory(entries:topics:)` (`Sources/Voiceour/MemoryJournal.swift`): it publishes the new state on the main actor and enqueues the one write that brings disk to it. Clear Memory (`clearMemory()`) publishes the empty state and enqueues the folder's removal on the same tail instead, because a plan rewrites only files the store owns.
- `MemoryPlanner.write(before:after:topicsBefore:topicsAfter:calendar:)` diffs the state disk holds against the new one, off the main actor, and rewrites only what the difference touches: for each entry added, removed or changed, its month file, day page, thread page, effective-topic page and notes page, both before and after the change; for a changed topic list, `topics.json` and every old and new topic page. `MEMORY.md` is rewritten whenever anything changed; no change writes nothing.
- `MemoryPlanner.rebuild(entries:topics:calendar:)` renders every file from one state. Diffs and a rebuild over the same state MUST produce the same bytes for every file they both write.
- `MemoryPlanner.rebuildPages(entries:topics:calendar:sweep:)` renders every page of one state and nothing else: it NEVER rewrites `entries/` or `topics.json`, whose lenient decoding would drop what this build cannot read. With `sweep`, the store removes every regular `*.md` directly in `days/`, `threads/`, `topics/` and `notes/` that the write did not write; it NEVER touches a symlink, a subfolder, `agents/`, `skills/`, `entries/`, `topics.json`, a `*.corrupt-*` file or `pages-format`. The write carries the stamp `MemoryPages.formatStamp(calendar:)`, written last, only after every page, removal, sweep and the skill succeeded. An empty state with no topics writes nothing. The diff never sweeps or stamps.
- The planner is pure: no file system, no clock, no root. `MemoryStore.apply` writes months, then `topics.json`, then pages, then removals, then the sweep, then, unless the write is empty or left no folder, the skill ([Agent skill](#agent-skill)), then `pages-format`.
- Launch rebuild: after the load and its quarantine, when the folder holds at least one entry or topic and `pages-format` is absent or differs from the stamp of the planner calendar (a new page format or a new time zone), the coordinator enqueues `rebuildPages` as the first element of the persistence tail, before any commit, through the same write port. Launch NEVER waits for it. A load that set a file aside rebuilds without sweeping, so the pages of the entries it could not read stay. A failure reports “Memory could not be saved.” and leaves the stamp as it was, so the next launch retries. A matching stamp writes nothing.

## Lifecycle

- Launch loads the folder whenever it exists, whatever the switch says, and the Journal shows everything it holds. An absent folder is an empty memory; nothing is created until there is something to write or the user presses Copy Install Command ([Agent skill](#agent-skill)), and a launch rebuild never creates the folder.
- `Settings.memoryEnabled` (`memory_enabled`, off by default, “Keep dictations in memory” in Settings ▸ Memory) decides only whether each newly delivered dictation is folded in. Turning it on adds every History row memory lacks, matched by id, with its binding or its `unlinked`. Turning it off stops new dictations and changes nothing already kept.
- A delivered dictation MUST fold into memory in the same main-actor turn as History and the ledger, and its files are written through the same FIFO tail (`recentSessionPersistenceTail`) after the History and ledger snapshots. Delivery NEVER waits for the memory write.
- A dictation delivered to a secure target reaches no record, memory included.
- A note (`kind: note`) MUST be saved whatever `Settings.memoryEnabled` says: the user asked for it to be kept. `recordNote(text:captureSeconds:)` (`Sources/Voiceour/MemoryJournal.swift`) commits it through `commitMemory` on the same tail, with no app, the recording's length as `capture_seconds`, and the text the note branch hands it: the whole final text for a session started as a note, whatever had focus, or the text after the spoken command ([text-pipeline.md › Spoken note command](text-pipeline.md#spoken-note-command)). Whitespace-only text is no note and ends the session as cancelled. A note has no History row and never enters the ledger, so it leaves memory only by Delete Entry…, Clear Memory or Clear History and Memory; Clear History alone NEVER removes it.
- A note's `thread` is set at most once, right after the save, when agent session binding applies to its target and the focused session resolves exactly ([runtime.md › Agent session binding](runtime.md#agent-session-binding)); its `sent` stays absent. When it applies and the link misses, the note's `unlinked` is set instead. Clear Memory cancels a link still pending.
- Deleting a transcript deletes the History row and the memory entry with its id, whichever exist; a Journal reading row offers Delete Entry… for an entry History no longer holds. Clear History leaves memory alone; its confirmation's “Clear History and Memory” erases both. Clear Memory removes the whole folder, `agents/` and the skill included, behind every write already queued, and fails while the app is terminating.
- An agent-session binding that attaches to, refreshes on, or is stripped from a History row MUST be mirrored onto the memory entry with the same id, and so MUST a row's `unlinked`. Turning agent session binding off strips `thread` and `unlinked` from every memory entry, not only those with a History row.
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

- Agents read the folder directly as files; Voiceour offers no server, socket or API for it. `MEMORY.md` tells an agent how to read the folder and where it may write; the [agent skill](#agent-skill) tells an agent where the folder is.
- `MemoryPages.agentInstructions(root:)` (`Sources/VoiceCore/MemoryAgentInstructions.swift`) is the paragraph a user pastes into an agent's instructions file, copied by Settings ▸ Memory ▸ Copy Agent Instructions: it names the folder, says to read `MEMORY.md` first and follow its rules, and to write only inside `agents/`. Its wording is fixed; NEVER add the user's text, ids or paths other than the root.
- Agents write only under `agents/`. Voiceour overwrites or deletes every other file without notice.
- An agent note is a Markdown file directly under `agents/` that Voiceour can place. `MemoryStore.loadAgentNotes()` (`Sources/VoiceCore/AgentNotes.swift`) loads every note, newest modification first, equal times by file name; `AgentNoteParser.parse(fileName:text:modifiedAt:)` reads one. The coordinator's `refreshAgentNotes()` runs the load off the main actor, one at a time, and publishes `agentNotes`; Clear Memory empties it.
- Front matter: the file's first line is exactly `---`, and the block runs to the next line that is exactly `---`. Each line inside is `key: value`, split at the first colon, both sides trimmed, one pair of matching single or double quotes dropped; any other line is ignored. `author` is required. `day: YYYY-MM-DD` MUST name a day that exists in the Gregorian calendar; any other value is ignored. `topic: <topic id>` names a topic by id. A note needs a usable `day` or `topic` and MAY name both. `title` is optional. A file without front matter, without `author`, or without a usable `day` or `topic` is no note, because Voiceour cannot place it, and is ignored.
- `session: <agent>-<session id>` is optional and names the thread the note reports on by the thread page's file stem (`MemoryPages.threadFileStem`, `threads/<stem>.md` without folder and extension). It is kept only when every character is in `A-Z a-z 0-9 . _ -`, else ignored. It places nothing alone: a note naming a `session` and no usable `day` or `topic` is no note. It is matched to a thread by exact equality and NEVER used as a path.
- Body: everything after the closing `---`, without the blank lines before and after it; nothing else in it changes.
- Limits: only visible, regular `.md` files directly in `agents/` count. Subfolders, hidden files and symbolic links are skipped, so a note can never pull in a file from outside the folder. A file larger than 262,144 bytes (`AgentNoteParser.maximumBytes`), measured again on the bytes read, is ignored, and so is one that is not UTF-8. At most 500 notes (`AgentNoteParser.maximumFiles`) load, newest modification first; files that are not notes do not count toward the 500. An absent or unreadable folder is no notes; loading NEVER throws or reports.
- What Voiceour does with a note: it shows the note as plain text, with its title (or file name), author and modification time, under the Rewind day its `day` names, on the page of the topic its `topic` names, and on the page of the thread whose file stem equals its `session` ([console-ui.md › Agent notes](console-ui.md#agent-notes)); a note naming an unknown topic shows under no topic, and one naming a session no thread has shows on no thread. Nothing more: a note NEVER becomes a memory entry, appears on a page Voiceour writes, enters a search, the Notes lens or a count, receives a label, or leaves the Mac, and Voiceour NEVER writes, edits, renames or deletes a single file under `agents/`; only Clear Memory, or Clear History and Memory, removes the folder whole with the rest of memory.
- Three prompts carry the loop to the user's own agent; Voiceour itself writes no recap or outcome and calls no writing model. Each is one paragraph naming absolute paths under the memory root, each path quoted so a root with spaces reads as one value, and holds no entry text; the source holds the exact wording.
  - `MemoryPages.recapPrompt(day:root:calendar:)`, copied by Rewind's Copy Recap Prompt: read the day page `days/YYYY-MM-DD.md` and `MEMORY.md`, write a recap of what the user worked on, decided and left open, quoting the user exactly, and save it as `agents/YYYY-MM-DD-recap.md` with front matter naming `author`, `day` and `title`.
  - `MemoryPages.synthesisPrompt(topic:root:)`, copied by an open topic's Copy Synthesis Prompt: read the topic page and `MEMORY.md`, write a synthesis of what the user concluded, what changed over time and what is still undecided, quoting the user exactly, and save it as `agents/topic-<file name>.md` with front matter naming `author`, `topic` and `title`. The prompt holds the topic's name and id. `<file name>` is the topic page's sanitized file name ([Pages](#pages)), so a hand-edited topic id can never point the agent outside `agents/`.
  - `MemoryPages.outcomePrompt(thread:day:root:calendar:)`, copied by an open thread's Copy Outcome Prompt, offered only when memory keeps one of the thread's entries so its page exists: read the thread page `threads/<stem>.md` and `MEMORY.md`, write what the agent did with what the user asked, what is still open and what it needs from the user, quoting the user exactly, and save it as `agents/<stem>.md` (`MemoryPages.outcomeNotePath`), replacing that file if it exists, with front matter naming `author`, `day`, `session: <stem>` and `title`. `<stem>` is the thread's file stem and `day` the day of the thread's latest entry in the planner calendar; both are written out literally, so the agent derives nothing from its own environment and a subagent's or a resumed session's id cannot misfile the note. The prompt holds no title. The stem is the thread page's sanitized file name, so a session id can never point the agent outside `agents/`, and each thread has one outcome note, which each new report replaces.
- A note the agent saves shows in the Journal the next time the tab appears, its lens changes or a thread opens.

### Agent skill

- `MemoryPages.agentSkill(root:)` (`Sources/VoiceCore/MemoryAgentInstructions.swift`) renders `skills/voiceour-memory/SKILL.md` (`MemoryPages.agentSkillPath`), a skill an agent loads on demand. Its front matter names it `voiceour-memory` (`MemoryPages.agentSkillName`, equal to the name of the folder holding it, which omp, Claude Code, Codex and Cursor require) and carries a fixed `description` of at most 1,024 characters with no `<` or `>`, which says to use it when the owner refers to something they said, dictated, noted or decided earlier, asks what they worked on, or when a task they dictated to the session ends. Its wording is fixed and its only variable is the root's path, written once; NEVER add the user's text, an id, a date or anything from the clock or the locale.
- What it tells an agent, in order:
  - Where the folder is, as a quoted path, and to read `MEMORY.md` there first.
  - How to find its own thread page: omp, `threads/omp-<id>.md` with `<id>` cut from `$PI_SESSION_FILE` by a fixed `sed` command, never `$PI_SESSION_ID`, which in a subagent names no page; Claude Code, `threads/claude-code-$CLAUDE_CODE_SESSION_ID.md`. No page means nothing was linked to the session, so it reads today's day page instead.
  - The rules: read any file in the folder, quote the owner exactly, write only inside `agents/`, and never copy the owner's words into commits, issues or messages unless the owner asks.
  - When and how to record an outcome: only when its session's page exists, a task the owner dictated in that session has ended, it is not a subagent, and no other agent gave it the task. It then replaces `agents/<agent>-<id>.md`, the thread page's file name, with front matter naming `author`, `day`, `session: <agent>-<id>` and `title`, followed by what it did, what is still open and what it needs from the owner. When writing outside its workspace needs approval, it asks once or skips the note.
- Writes: `MemoryStore.writeAgentSkill()` writes the file (0600; its folder, `skills/` and the root 0700) only when it is missing or its bytes differ, so an unchanged skill keeps its modification time and an agent that loads it sees no churn. `MemoryStore.apply` calls it after every write that is not empty and leaves the folder on disk, and Settings ▸ Memory ▸ Copy Install Command calls it through `prepareAgentSkill()` (`Sources/Voiceour/MemoryJournal.swift`) on the persistence tail, behind every write already queued. That press is an explicit action, so it MAY create the folder with nothing else in it; it writes nothing while the app is terminating. A new wording or a moved root reaches disk with the next memory change or press.
- Install: `MemoryPages.skillInstallCommand(root:)` is one line for sh and zsh that the user runs once in Terminal; Voiceour never runs it and never writes into an agent's folder. For each of `$HOME/.omp/agent/skills`, `$HOME/.claude/skills` and `$HOME/.agents/skills` that already exists as a folder, it links `voiceour-memory` there to `<root>/skills/voiceour-memory` with `ln -sfn` when that name is absent or already a symbolic link, and prints `Linked <folder>`. It NEVER creates an agent's folder and NEVER replaces a real file or folder of that name, so running it again is harmless. The root is single-quoted, each `'` written as `'\''`.
- Reach: omp reads `~/.omp/agent/skills`, Claude Code `~/.claude/skills`, Codex `~/.agents/skills`, and Cursor both of the last two. A project whose omp configuration has an `includeSkills` list sees the skill only when the list names `voiceour-memory`. Copy Agent Instructions stays the per-project alternative.
- Clear Memory removes the skill with the folder; the links the user made then point at nothing until the next memory write or press writes the file again. A changed `VOICEOUR_SUPPORT_DIR` moves the root, so the command must be run again for the new root.
- Every agent session on this Mac that loads personal skills can discover the folder through the skill and read all of it, including a session that reads untrusted content and may be steered by it. The skill's rule against copying the owner's words elsewhere is a request to the agent, not an enforcement.

## Privacy

- Memory leaves the Mac through Voiceour only as label requests, and only while Sort entries with Jev is on and a key is set. Each request holds one entry's text, cut to its first 8,000 characters, and the ids, names and summaries of the first 254 topics; NEVER an agent session's id, title, project or directory, the app, a file path, audio, raw recognizer text, timings, another entry, or anything under `agents/`. It goes to TypeSafe, `POST https://api.typesafe.ai/v1/systemone`, and to no other host: a redirect is refused. What TypeSafe says about hosting, training and retention is recorded, with its sources and the date read, in [README › Model and network contract](../README.md#model-and-network-contract).
- Memory is uncapped and kept until the user deletes an entry or clears memory.
- Diagnostics name the switch state (`keep dictations in memory: on|off`), the entry count (`memory entries: <count>`), the folder path (`memory:` under storage), the sorting switch (`sort entries with jev: on|off`) and where the key comes from (`typesafe key: environment|key file|none`). NEVER the key, entry text, topic names, session ids or session paths.
