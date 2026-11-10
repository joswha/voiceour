import Foundation

/// A derived Markdown page. `path` is relative to the memory root, e.g. "days/2026-11-10.md".
public struct MemoryPage: Equatable, Sendable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// The Markdown pages an agent reads instead of the JSON records.
///
/// Every page is a pure function of its arguments: no clock, no locale and no
/// formatter with implicit settings, so one state always renders the same
/// bytes and a rewrite of an unchanged page changes nothing on disk. The
/// owner's text is quoted verbatim; only the lines after a line break gain the
/// two-space indent that keeps them inside their list item.
public enum MemoryPages {
    public static let indexPath = "MEMORY.md"

    /// The days whose pages `MEMORY.md` links.
    static let recentDayCount = 14
    /// The threads whose pages `MEMORY.md` links.
    static let recentThreadCount = 20

    /// What `pages-format` holds once every derived page of one format, calendar
    /// and zone is on disk. A launch that reads anything else rebuilds the
    /// pages, which also repairs a zone change since the last rebuild.
    public static func formatStamp(calendar: Calendar) -> String {
        "2 gregorian \(calendar.timeZone.identifier)"
    }

    public static func dayPath(_ day: Date, calendar: Calendar) -> String {
        "days/\(MemoryDateText.day(day, calendar: calendar)).md"
    }

    /// `threads/<agent>-<session id>.md`, with every character outside
    /// `A-Z a-z 0-9 . _ -` replaced by `-`: the session id comes from an agent's
    /// own records, and it must never add a path component.
    public static func threadPath(_ key: AgentSessionKey) -> String {
        "threads/\(fileName("\(key.agent.rawValue)-\(key.sessionId)")).md"
    }

    /// Topic ids are slugs already; the same replacement keeps a hand-edited
    /// `topics.json` from steering a page outside `topics/`.
    public static func topicPath(_ topicID: String) -> String {
        "topics/\(fileName(topicID)).md"
    }

    public static func notesPath(month: String) -> String {
        "notes/\(month).md"
    }

    public static func index(entries: [MemoryEntry], topics: [MemoryTopic], calendar: Calendar) -> MemoryPage {
        let entries = MemoryStore.oldestFirst(entries)
        let known = Set(topics.map(\.id))
        let noteCount = entries.count(where: { $0.kind == .note })

        var fields: [FrontMatterField] = [
            ("entries", "\(entries.count)"),
            ("dictations", "\(entries.count - noteCount)"),
            ("notes", "\(noteCount)"),
        ]
        var facts = [
            "- Entries: \(entries.count) (\(counted(entries.count - noteCount, "dictation", "dictations")), "
                + "\(counted(noteCount, "note", "notes")))"
        ]
        if let first = entries.first, let last = entries.last {
            let firstDay = MemoryDateText.day(first.createdAt, calendar: calendar)
            let lastDay = MemoryDateText.day(last.createdAt, calendar: calendar)
            fields += [("first", firstDay), ("last", lastDay)]
            facts.append("- First entry: \(firstDay)")
            facts.append("- Last entry: \(lastDay)")
        }

        var sections = [
            frontMatter("index", calendar: calendar, fields),
            "# Voiceour memory",
            "Everything the owner of this Mac dictated or noted with Voiceour, verbatim. "
                + "Voiceour writes every file here except `agents/`.",
            facts.joined(separator: "\n"),
            "## How to read this folder",
            """
            - `days/YYYY-MM-DD.md`: one day in time order, grouped by agent session or app.
            - `threads/<agent>-<session id>.md`: everything said into one agent session.
            - `topics/<topic id>.md`: everything filed under one topic.
            - `notes/YYYY-MM.md`: notes, which were saved and never pasted anywhere.
            - `entries/YYYY-MM.json`: the source records. Every other file is derived from them.
            - `topics.json`: the topics and their one-line descriptions.
            - Each entry line reads time · id · state · text. States: sent, not sent, unchecked (not checked yet), \
            note, unlinked (not linked to an agent session), dictation.
            - Your own thread, if Voiceour linked a dictation to this session: omp, threads/omp-<id>.md with <id> \
            the UUID after "Z_" in $PI_SESSION_FILE ($PI_SESSION_ID differs in a subagent); Claude Code, \
            threads/claude-code-$CLAUDE_CODE_SESSION_ID.md. No file means nothing was linked; read today's day page.
            """,
            "## Rules for agents",
            """
            - Read any file. Quote the owner's words exactly.
            - Write only inside `agents/`. Voiceour overwrites or deletes every other file.
            - A file in `agents/` is Markdown. Start it with a front matter block that names `author`, \
            and `day: YYYY-MM-DD` or `topic: <topic id>`.
            """,
        ]

        if !topics.isEmpty {
            var topicCounts: [String: Int] = [:]
            for entry in entries {
                if let topicID = entry.effectiveTopicID(known: known) {
                    topicCounts[topicID, default: 0] += 1
                }
            }
            let lines = topics.map { topic in
                let line =
                    "- [\(topic.name)](\(topicPath(topic.id))): "
                    + "\(counted(topicCounts[topic.id] ?? 0, "entry", "entries"))."
                let summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return summary.isEmpty ? line : "\(line) \(indented(summary))"
            }
            sections.append("## Topics")
            sections.append(lines.joined(separator: "\n"))
        }

        var dayCounts: [Date: Int] = [:]
        for entry in entries {
            dayCounts[calendar.startOfDay(for: entry.createdAt), default: 0] += 1
        }
        let recentDays = dayCounts.keys.sorted(by: >).prefix(recentDayCount)
        if !recentDays.isEmpty {
            let lines = recentDays.map { day in
                let name = MemoryDateText.day(day, calendar: calendar)
                return "- [\(name)](\(dayPath(day, calendar: calendar))): "
                    + counted(dayCounts[day] ?? 0, "entry", "entries")
            }
            sections.append("## Recent days")
            sections.append(lines.joined(separator: "\n"))
        }

        let journal = entries.map { JournalEntry($0, knownTopicIDs: known) }
        let recentThreads = JournalQuery.threads(in: journal).prefix(recentThreadCount)
        if !recentThreads.isEmpty {
            let lines = recentThreads.map { thread in
                "- [\(thread.displayTitle)](\(threadPath(thread.id))): "
                    + "\(counted(thread.entries.count, "entry", "entries")), "
                    + "last \(MemoryDateText.day(thread.lastAt, calendar: calendar))"
            }
            sections.append("## Recent threads")
            sections.append(lines.joined(separator: "\n"))
        }

        return MemoryPage(path: indexPath, text: rendered(sections))
    }

    /// One day in time order, in the blocks the Rewind lens shows. Nil when the
    /// day holds no entry.
    public static func day(
        _ day: Date,
        entries: [MemoryEntry],
        topics: [MemoryTopic],
        calendar: Calendar
    ) -> MemoryPage? {
        let start = calendar.startOfDay(for: day)
        let known = Set(topics.map(\.id))
        let journal = MemoryStore.oldestFirst(
            entries.filter { calendar.isDate($0.createdAt, inSameDayAs: start) }
        )
        .map { JournalEntry($0, knownTopicIDs: known) }
        let rewind = JournalQuery.rewind(day: start, in: journal, calendar: calendar)
        guard !rewind.blocks.isEmpty else { return nil }
        let ids = lineIDs(journal)

        let counts: [(count: Int, singular: String, plural: String)] = [
            (rewind.entryCount, "entry", "entries"),
            (rewind.wordCount, "word", "words"),
            (rewind.threadCount, "agent session", "agent sessions"),
            (rewind.appCount, "app", "apps"),
            (rewind.noteCount, "note", "notes"),
        ]
        let summary = counts.filter { $0.count > 0 }.map { counted($0.count, $0.singular, $0.plural) }
        let date = MemoryDateText.day(start, calendar: calendar)

        var sections = [
            frontMatter(
                "day",
                calendar: calendar,
                [
                    ("date", date),
                    ("entries", "\(rewind.entryCount)"),
                    ("words", "\(rewind.wordCount)"),
                    ("threads", "\(rewind.threadCount)"),
                    ("notes", "\(rewind.noteCount)"),
                ]
            ),
            "# \(date), \(MemoryDateText.weekday(start, calendar: calendar))",
            summary.joined(separator: " · "),
        ]

        if !rewind.highlights.isEmpty {
            let lines = rewind.highlights.map { highlight in
                entryLine(highlight.entry, state: highlight.kind.displayName.lowercased(), ids: ids, calendar: calendar)
            }
            sections.append("## Highlights")
            sections.append(lines.joined(separator: "\n"))
        }

        for block in rewind.blocks {
            let startTime = MemoryDateText.time(block.startAt, calendar: calendar, seconds: false)
            let endTime = MemoryDateText.time(block.endAt, calendar: calendar, seconds: false)
            let span = startTime == endTime ? startTime : "\(startTime)–\(endTime)"
            let continuation = block.isContinuation ? " · continued" : ""
            switch block.subject {
            case .thread(let ref):
                sections.append("## \(span) · \(threadSource(ref).joined(separator: " · "))\(continuation)")
                let linkText = ref.title ?? String(ref.sessionId.prefix(8))
                sections.append("[\(linkText)](../\(threadPath(ref.key)))")
            case .notes:
                sections.append("## \(span) · Notes\(continuation)")
            case .app(let app):
                sections.append("## \(span) · \(app.name ?? app.bundleId)\(continuation)")
            case .unknown:
                sections.append("## \(span) · Unknown target\(continuation)")
            }
            let lines = block.entries.map { entryLine($0, ids: ids, calendar: calendar) }
            sections.append(lines.joined(separator: "\n"))
        }

        return MemoryPage(path: dayPath(start, calendar: calendar), text: rendered(sections))
    }

    /// Everything said into one agent session, by day. Nil when no entry
    /// belongs to the session.
    public static func thread(_ key: AgentSessionKey, entries: [MemoryEntry], calendar: Calendar) -> MemoryPage? {
        let journal = MemoryStore.oldestFirst(entries.filter { $0.thread?.key == key })
            .map { JournalEntry($0, knownTopicIDs: []) }
        guard let thread = JournalQuery.threads(in: journal).first(where: { $0.id == key }) else { return nil }

        let ref = thread.ref
        let states = thread.entries.map { EntryState($0) }
        var fields: [FrontMatterField] = [
            ("agent", ref.agent.rawValue),
            ("session", idValue(ref.sessionId)),
        ]
        if let directory = ref.workingDirectory {
            fields.append(("directory", jsonString(directory)))
        }
        fields += [
            ("resumable", ref.resumable ? "true" : "false"),
            ("entries", "\(thread.entries.count)"),
            ("not_sent", "\(states.count(where: { $0 == .notSent }))"),
            ("unchecked", "\(states.count(where: { $0 == .unchecked }))"),
            ("first", MemoryDateText.dayAndTime(thread.firstAt, calendar: calendar)),
            ("last", MemoryDateText.dayAndTime(thread.lastAt, calendar: calendar)),
        ]

        var sections = [frontMatter("thread", calendar: calendar, fields), "# \(thread.displayTitle)"]
        if ref.resumable {
            sections.append("Resume: `\(thread.resumeCommand)`")
        }
        let ids = lineIDs(thread.entries)
        sections += daySections(thread.entries, calendar: calendar) { entry in
            entryLine(entry, ids: ids, calendar: calendar)
        }
        return MemoryPage(path: threadPath(key), text: rendered(sections))
    }

    /// Everything filed under one topic, by day. A topic with no entry still
    /// has a page, because the topic itself exists until the user removes it.
    public static func topic(
        _ topic: MemoryTopic,
        entries: [MemoryEntry],
        topics: [MemoryTopic],
        calendar: Calendar
    ) -> MemoryPage {
        var known = Set(topics.map(\.id))
        known.insert(topic.id)
        let filed = MemoryStore.oldestFirst(entries.filter { $0.effectiveTopicID(known: known) == topic.id })
            .map { JournalEntry($0, knownTopicIDs: known) }

        var sections = [
            frontMatter("topic", calendar: calendar, [("topic", idValue(topic.id)), ("entries", "\(filed.count)")]),
            "# \(topic.name)",
        ]
        let summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            sections.append(summary)
        }
        let ids = lineIDs(filed)
        sections += daySections(filed, calendar: calendar) { entry in
            entryLine(entry, ids: ids, calendar: calendar)
        }
        return MemoryPage(path: topicPath(topic.id), text: rendered(sections))
    }

    /// The month's notes, by day. Nil when the month holds no note.
    public static func notes(month: String, entries: [MemoryEntry], calendar: Calendar) -> MemoryPage? {
        let notes = MemoryStore.oldestFirst(
            entries.filter { $0.kind == .note && MemoryStore.monthKey(for: $0.createdAt, calendar: calendar) == month }
        )
        .map { JournalEntry($0, knownTopicIDs: []) }
        guard !notes.isEmpty else { return nil }

        let ids = lineIDs(notes)
        let sections =
            [
                frontMatter("notes", calendar: calendar, [("month", idValue(month)), ("entries", "\(notes.count)")]),
                "# Notes, \(month)",
            ]
            + daySections(notes, calendar: calendar) { entry in
                entryLine(entry, ids: ids, calendar: calendar)
            }
        return MemoryPage(path: notesPath(month: month), text: rendered(sections))
    }

    // MARK: Rendering

    /// Sections apart by one blank line, and one trailing newline.
    private static func rendered(_ sections: [String]) -> String {
        sections.joined(separator: "\n\n") + "\n"
    }

    /// A `## YYYY-MM-DD` heading and its lines for each day, oldest first.
    /// `entries` must already be oldest first.
    private static func daySections(
        _ entries: [JournalEntry],
        calendar: Calendar,
        line: (JournalEntry) -> String
    ) -> [String] {
        var sections: [String] = []
        var currentDay: String?
        var lines: [String] = []
        for entry in entries {
            let day = MemoryDateText.day(entry.createdAt, calendar: calendar)
            if day != currentDay {
                if let currentDay {
                    sections.append("## \(currentDay)")
                    sections.append(lines.joined(separator: "\n"))
                }
                currentDay = day
                lines = []
            }
            lines.append(line(entry))
        }
        if let currentDay {
            sections.append("## \(currentDay)")
            sections.append(lines.joined(separator: "\n"))
        }
        return sections
    }

    /// `- HH:mm:ss · <id> · <state> · <text>`. The text comes last and nothing
    /// follows it, so a reader splits a line at its first three separators and
    /// never inside the owner's words. `state` defaults to the entry's own.
    private static func entryLine(
        _ entry: JournalEntry,
        state: String? = nil,
        ids: [UUID: String],
        calendar: Calendar
    ) -> String {
        let time = MemoryDateText.time(entry.createdAt, calendar: calendar, seconds: true)
        let id = ids[entry.id] ?? entry.id.uuidString
        return "- \(time) · \(id) · \(state ?? EntryState(entry).rawValue) · \(indented(entry.text))"
    }

    /// The id each entry on one page is printed with: the last 12 characters
    /// of its `uuidString`, as `entries/*.json` writes it, or the whole of it
    /// when another entry on the same page ends the same way. The rule looks
    /// at one page only, so a page rewritten by a diff equals its rebuild.
    private static func lineIDs(_ entries: [JournalEntry]) -> [UUID: String] {
        let ids = Set(entries.map(\.id))
        var suffixCounts: [String: Int] = [:]
        for id in ids {
            suffixCounts[String(id.uuidString.suffix(12)), default: 0] += 1
        }
        var result: [UUID: String] = [:]
        for id in ids {
            let short = String(id.uuidString.suffix(12))
            result[id] = suffixCounts[short] == 1 ? short : id.uuidString
        }
        return result
    }

    /// What became of an entry, first match wins. `unchecked` rather than
    /// "pending": the send check may never decide, and a page has no clock to
    /// say how long it waited.
    private enum EntryState: String {
        case note
        case sent
        case notSent = "not sent"
        case unchecked
        case unlinked
        case dictation

        init(_ entry: JournalEntry) {
            if entry.kind == .note {
                self = .note
            } else if let thread = entry.thread {
                switch thread.sent {
                case true?: self = .sent
                case false?: self = .notSent
                case nil: self = .unchecked
                }
            } else {
                self = entry.unlinked == nil ? .dictation : .unlinked
            }
        }
    }

    private typealias FrontMatterField = (key: String, value: String)

    /// The `---` block every derived page opens with: flat `key: value` lines
    /// an agent or `AgentNoteParser` reads without parsing the Markdown below.
    /// Values that come from records are quoted by the caller, so none of them
    /// can close the block or start a key of its own.
    private static func frontMatter(_ type: String, calendar: Calendar, _ fields: [FrontMatterField]) -> String {
        let common: [FrontMatterField] = [("format", "2"), ("type", type), ("tz", calendar.timeZone.identifier)]
        let lines = (common + fields).map { "\($0.key): \($0.value)" }
        return (["---"] + lines + ["---"]).joined(separator: "\n")
    }

    /// An id bare, as front matter writes ids, when it is a plain token; a
    /// hand-edited record holding anything else is quoted so it stays on its line.
    private static func idValue(_ id: String) -> String {
        let plain =
            !id.isEmpty
            && id.unicodeScalars.allSatisfy { scalar in
                switch scalar {
                case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": true
                default: false
                }
            }
        return plain ? id : jsonString(id)
    }

    /// A JSON string literal. Every character a reader may take for a line
    /// break is escaped, so a value read from records stays on one line.
    static func jsonString(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        result.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            case _
            where scalar.value < 0x20 || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029:
                let hex = String(scalar.value, radix: 16)
                result.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            default: result.append(scalar)
            }
        }
        result.append("\"")
        return String(result)
    }

    private static func threadSource(_ ref: JournalThreadRef) -> [String] {
        [ref.agent.displayName] + (ref.project.map { [$0] } ?? [])
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// The text with every line after the first indented two spaces, so a
    /// multi-line entry stays inside its list item. Nothing else changes.
    static func indented(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return text }
        var result = String.UnicodeScalarView()
        for (offset, scalar) in scalars.enumerated() {
            result.append(scalar)
            let endsLine =
                scalar == "\n"
                || (scalar == "\r" && (offset + 1 == scalars.count || scalars[offset + 1] != "\n"))
            if endsLine {
                result.append(contentsOf: "  ".unicodeScalars)
            }
        }
        return String(result)
    }

    private static func fileName(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": result.append(scalar)
            default: result.append("-")
            }
        }
        return String(result)
    }
}

/// Plans the files one change rewrites, so disk follows memory without a
/// rewrite of the whole, uncapped folder on every dictation.
public enum MemoryPlanner {
    /// The files to rewrite so disk matches `after`, given the state `before` that disk holds now.
    /// Pure. Rewrites only the months, pages and topics file the difference touches, plus MEMORY.md
    /// whenever anything changed.
    public static func write(
        before: [MemoryEntry],
        after: [MemoryEntry],
        topicsBefore: [MemoryTopic],
        topicsAfter: [MemoryTopic],
        calendar: Calendar
    ) -> MemoryWrite {
        let knownBefore = Set(topicsBefore.map(\.id))
        let knownAfter = Set(topicsAfter.map(\.id))
        let oldByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        var touched = Subjects()
        var entriesChanged = false
        for id in Set(oldByID.keys).union(newByID.keys) {
            let old = oldByID[id]
            let new = newByID[id]
            guard old != new else { continue }
            entriesChanged = true
            if let old {
                touched.insert(old, known: knownBefore, calendar: calendar)
            }
            if let new {
                touched.insert(new, known: knownAfter, calendar: calendar)
            }
        }

        let topicsChanged = topicsBefore != topicsAfter
        guard entriesChanged || topicsChanged else { return MemoryWrite() }
        if topicsChanged {
            // Every topic page names its topic and counts its entries, and a
            // topic that is gone takes its page with it.
            touched.topics.formUnion(knownBefore)
            touched.topics.formUnion(knownAfter)
        }

        return planned(
            touched,
            entries: MemoryStore.oldestFirst(after),
            topics: topicsAfter,
            writesTopics: topicsChanged,
            calendar: calendar
        )
    }

    /// The complete write that rebuilds every file from `entries` and `topics`.
    public static func rebuild(entries: [MemoryEntry], topics: [MemoryTopic], calendar: Calendar) -> MemoryWrite {
        planned(
            everySubject(entries: entries, topics: topics, calendar: calendar),
            entries: MemoryStore.oldestFirst(entries),
            topics: topics,
            writesTopics: true,
            calendar: calendar
        )
    }

    /// Every derived page of one state, and nothing else: a new page format or
    /// time zone never rewrites `entries/` or `topics.json`, whose lenient
    /// decoding would drop whatever this build cannot read. With `sweep`, the
    /// store also removes the derived pages this write does not name; the
    /// stamp lands last, so a write that fails part way is retried. An empty
    /// state writes nothing, so a rebuild never creates the folder.
    public static func rebuildPages(
        entries: [MemoryEntry],
        topics: [MemoryTopic],
        calendar: Calendar,
        sweep: Bool
    ) -> MemoryWrite {
        guard !entries.isEmpty || !topics.isEmpty else { return MemoryWrite() }
        var subjects = everySubject(entries: entries, topics: topics, calendar: calendar)
        subjects.months = []
        var write = planned(
            subjects,
            entries: MemoryStore.oldestFirst(entries),
            topics: topics,
            writesTopics: false,
            calendar: calendar
        )
        write.sweepDerived = sweep
        write.pagesFormat = MemoryPages.formatStamp(calendar: calendar)
        return write
    }

    private static func everySubject(entries: [MemoryEntry], topics: [MemoryTopic], calendar: Calendar) -> Subjects {
        let known = Set(topics.map(\.id))
        var subjects = Subjects()
        for entry in entries {
            subjects.insert(entry, known: known, calendar: calendar)
        }
        subjects.topics.formUnion(known)
        return subjects
    }

    /// Renders every subject in `subjects` from `entries`, which must be oldest
    /// first; a subject with nothing left to show loses its file.
    private static func planned(
        _ subjects: Subjects,
        entries: [MemoryEntry],
        topics: [MemoryTopic],
        writesTopics: Bool,
        calendar: Calendar
    ) -> MemoryWrite {
        let known = Set(topics.map(\.id))
        var byMonth: [String: [MemoryEntry]] = [:]
        var byDay: [Date: [MemoryEntry]] = [:]
        var byThread: [AgentSessionKey: [MemoryEntry]] = [:]
        var byTopic: [String: [MemoryEntry]] = [:]
        var notesByMonth: [String: [MemoryEntry]] = [:]
        for entry in entries {
            let month = MemoryStore.monthKey(for: entry.createdAt, calendar: calendar)
            byMonth[month, default: []].append(entry)
            byDay[calendar.startOfDay(for: entry.createdAt), default: []].append(entry)
            if let key = entry.thread?.key {
                byThread[key, default: []].append(entry)
            }
            if let topicID = entry.effectiveTopicID(known: known) {
                byTopic[topicID, default: []].append(entry)
            }
            if entry.kind == .note {
                notesByMonth[month, default: []].append(entry)
            }
        }

        var write = MemoryWrite(topics: writesTopics ? topics : nil)
        for month in subjects.months {
            write.months[month] = byMonth[month] ?? []
        }

        var pages = [MemoryPages.index(entries: entries, topics: topics, calendar: calendar)]
        var removed: [String] = []
        for day in subjects.days {
            if let page = MemoryPages.day(day, entries: byDay[day] ?? [], topics: topics, calendar: calendar) {
                pages.append(page)
            } else {
                removed.append(MemoryPages.dayPath(day, calendar: calendar))
            }
        }
        for key in subjects.threads {
            if let page = MemoryPages.thread(key, entries: byThread[key] ?? [], calendar: calendar) {
                pages.append(page)
            } else {
                removed.append(MemoryPages.threadPath(key))
            }
        }
        for topicID in subjects.topics {
            if let topic = topics.first(where: { $0.id == topicID }) {
                pages.append(
                    MemoryPages.topic(topic, entries: byTopic[topicID] ?? [], topics: topics, calendar: calendar)
                )
            } else {
                removed.append(MemoryPages.topicPath(topicID))
            }
        }
        for month in subjects.noteMonths {
            if let page = MemoryPages.notes(month: month, entries: notesByMonth[month] ?? [], calendar: calendar) {
                pages.append(page)
            } else {
                removed.append(MemoryPages.notesPath(month: month))
            }
        }

        write.pages = pages.sorted { $0.path < $1.path }
        write.removedPages = removed.sorted()
        return write
    }

    /// The month files and pages an entry appears in.
    private struct Subjects {
        var months: Set<String> = []
        var days: Set<Date> = []
        var threads: Set<AgentSessionKey> = []
        var topics: Set<String> = []
        var noteMonths: Set<String> = []

        mutating func insert(_ entry: MemoryEntry, known: Set<String>, calendar: Calendar) {
            let month = MemoryStore.monthKey(for: entry.createdAt, calendar: calendar)
            months.insert(month)
            days.insert(calendar.startOfDay(for: entry.createdAt))
            if let key = entry.thread?.key {
                threads.insert(key)
            }
            if let topicID = entry.effectiveTopicID(known: known) {
                topics.insert(topicID)
            }
            if entry.kind == .note {
                noteMonths.insert(month)
            }
        }
    }
}

/// Calendar dates and times as fixed-width digits, read in the calendar's own
/// time zone and padded by hand so no locale can change a page or a file name.
enum MemoryDateText {
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// `YYYY-MM-DD`.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = padded(components.year ?? 0, 4)
        return "\(year)-\(padded(components.month ?? 0, 2))-\(padded(components.day ?? 0, 2))"
    }

    /// `YYYY-MM`.
    static func month(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(padded(components.year ?? 0, 4))-\(padded(components.month ?? 0, 2))"
    }

    /// `HH:mm:ss`, or `HH:mm` without seconds.
    static func time(_ date: Date, calendar: Calendar, seconds: Bool) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = "\(padded(components.hour ?? 0, 2)):\(padded(components.minute ?? 0, 2))"
        return seconds ? "\(minutes):\(padded(components.second ?? 0, 2))" : minutes
    }

    /// `YYYY-MM-DD HH:mm`.
    static func dayAndTime(_ date: Date, calendar: Calendar) -> String {
        "\(day(date, calendar: calendar)) \(time(date, calendar: calendar, seconds: false))"
    }

    /// The English weekday name, whatever the calendar's locale.
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        return weekdays.indices.contains(index) ? weekdays[index] : ""
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
