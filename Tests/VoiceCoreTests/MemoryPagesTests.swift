import Foundation
import Testing

@testable import VoiceCore

private func memoryInstant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func memoryEntryID(_ number: Int) -> UUID {
    let digits = String(number)
    return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
}

private let memorySessionID = "01a1c154-ce7b-70a7-9d17-da6c0eb43054"

private func memorySession(sent: Bool?) -> JournalThreadRef {
    JournalThreadRef(
        agent: .omp,
        sessionId: memorySessionID,
        title: "Check agent session storage",
        workingDirectory: "/Users/vlad/Desktop/voiceoour",
        resumable: true,
        sent: sent
    )
}

private let memorySystem = MemoryTopic(
    id: "memory-system",
    name: "Memory system",
    summary: "Design of the persistent store.",
    createdAt: memoryInstant("2026-10-01T08:00:00Z")
)

/// One day of 2026-11-10 (a Tuesday) in UTC: a session with a note inside it
/// and a confident decision, then Mail, then a note on its own.
private let memoryDayEntries: [MemoryEntry] = [
    MemoryEntry(
        id: memoryEntryID(1),
        createdAt: memoryInstant("2026-11-10T09:27:19Z"),
        text: "Testing.",
        thread: memorySession(sent: true)
    ),
    MemoryEntry(
        id: memoryEntryID(2),
        createdAt: memoryInstant("2026-11-10T09:31:02Z"),
        kind: .note,
        text: "A note taken inside this session.",
        thread: memorySession(sent: nil)
    ),
    MemoryEntry(
        id: memoryEntryID(3),
        createdAt: memoryInstant("2026-11-10T09:58:30Z"),
        text: "We keep the app local only.",
        thread: memorySession(sent: true),
        userTopicID: "memory-system",
        label: EntryLabel(
            kind: .decision,
            kindConfidence: 0.9,
            model: "jev-1.14.0",
            labeledAt: memoryInstant("2026-11-10T09:58:32Z")
        )
    ),
    MemoryEntry(
        id: memoryEntryID(4),
        createdAt: memoryInstant("2026-11-10T10:20:11Z"),
        text: "Thanks, see you on Friday.",
        appBundleId: "com.apple.mail",
        appName: "Mail",
        label: EntryLabel(
            topicID: "memory-system",
            topicConfidence: 0.8,
            model: "jev-1.14.0",
            labeledAt: memoryInstant("2026-11-10T10:20:13Z")
        )
    ),
    MemoryEntry(
        id: memoryEntryID(5),
        createdAt: memoryInstant("2026-11-10T11:02:40Z"),
        kind: .note,
        text: "The memory folder should be plain files.",
        userTopicID: "memory-system"
    ),
]

/// The session's next morning: a dictation the agent never sent.
private let memoryNotSent = MemoryEntry(
    id: memoryEntryID(6),
    createdAt: memoryInstant("2026-11-11T08:05:00Z"),
    text: "This one never left the composer.",
    thread: memorySession(sent: false)
)

@Suite("Memory pages")
struct MemoryPagesTests {
    @Test func aDayPageGroupsTheDayIntoBlocksWithHighlights() throws {
        let page = try #require(
            MemoryPages.day(
                memoryInstant("2026-11-10T15:00:00Z"),
                entries: memoryDayEntries + [memoryNotSent],
                topics: [memorySystem],
                calendar: utc
            )
        )

        #expect(page.path == "days/2026-11-10.md")
        #expect(
            page.text == """
                ---
                format: 2
                type: day
                tz: \(utc.timeZone.identifier)
                date: 2026-11-10
                entries: 5
                words: 25
                threads: 1
                notes: 2
                ---

                # 2026-11-10, Tuesday

                5 entries · 25 words · 1 agent session · 1 app · 2 notes

                ## Highlights

                - 09:58:30 · 000000000003 · decision · We keep the app local only.

                ## 09:27–09:58 · omp · voiceoour

                [Check agent session storage](../threads/omp-01a1c154-ce7b-70a7-9d17-da6c0eb43054.md)

                - 09:27:19 · 000000000001 · sent · Testing.
                - 09:31:02 · 000000000002 · note · A note taken inside this session.
                - 09:58:30 · 000000000003 · sent · We keep the app local only.

                ## 10:20 · Mail

                - 10:20:11 · 000000000004 · dictation · Thanks, see you on Friday.

                ## 11:02 · Notes

                - 11:02:40 · 000000000005 · note · The memory folder should be plain files.

                """
        )
    }

    /// Each state the grammar names, first match wins: a note stays a note
    /// inside a thread, and a miss shows only on an entry with no thread.
    @Test func everyEntryLineNamesItsState() throws {
        let entries = [
            MemoryEntry(
                id: memoryEntryID(1),
                createdAt: memoryInstant("2026-11-10T09:00:00Z"),
                kind: .note,
                text: "Noted.",
                thread: memorySession(sent: false)
            ),
            MemoryEntry(
                id: memoryEntryID(2),
                createdAt: memoryInstant("2026-11-10T09:00:01Z"),
                text: "Sent.",
                thread: memorySession(sent: true)
            ),
            MemoryEntry(
                id: memoryEntryID(3),
                createdAt: memoryInstant("2026-11-10T09:00:02Z"),
                text: "Not sent.",
                thread: memorySession(sent: false)
            ),
            MemoryEntry(
                id: memoryEntryID(4),
                createdAt: memoryInstant("2026-11-10T09:00:03Z"),
                text: "Unchecked.",
                thread: memorySession(sent: nil)
            ),
            MemoryEntry(
                id: memoryEntryID(5),
                createdAt: memoryInstant("2026-11-10T09:00:04Z"),
                text: "Missed.",
                appBundleId: "com.example.terminal",
                unlinked: .focusMoved
            ),
            MemoryEntry(
                id: memoryEntryID(6),
                createdAt: memoryInstant("2026-11-10T09:00:05Z"),
                text: "Plain.",
                appBundleId: "com.example.terminal"
            ),
        ]

        let page = try #require(
            MemoryPages.day(memoryInstant("2026-11-10T00:00:00Z"), entries: entries, topics: [], calendar: utc)
        )

        #expect(page.text.contains("- 09:00:00 · 000000000001 · note · Noted.\n"))
        #expect(page.text.contains("- 09:00:01 · 000000000002 · sent · Sent.\n"))
        #expect(page.text.contains("- 09:00:02 · 000000000003 · not sent · Not sent.\n"))
        #expect(page.text.contains("- 09:00:03 · 000000000004 · unchecked · Unchecked.\n"))
        #expect(page.text.contains("- 09:00:04 · 000000000005 · unlinked · Missed.\n"))
        #expect(page.text.contains("- 09:00:05 · 000000000006 · dictation · Plain.\n"))
    }

    /// Two entries on one page whose ids end alike both print the whole id;
    /// a page holding only one of them keeps the short form.
    @Test func idsThatEndAlikeOnOnePagePrintWhole() throws {
        let first = try #require(UUID(uuidString: "10000000-0000-0000-0000-0000000000AB"))
        let second = try #require(UUID(uuidString: "20000000-0000-0000-0000-0000000000AB"))
        let third = try #require(UUID(uuidString: "30000000-0000-0000-0000-0000000000AB"))
        let entries = [
            MemoryEntry(id: first, createdAt: memoryInstant("2026-11-10T09:00:00Z"), kind: .note, text: "One."),
            MemoryEntry(id: second, createdAt: memoryInstant("2026-11-10T09:01:00Z"), kind: .note, text: "Two."),
            MemoryEntry(id: third, createdAt: memoryInstant("2026-11-11T09:00:00Z"), kind: .note, text: "Three."),
        ]

        let tenth = try #require(
            MemoryPages.day(memoryInstant("2026-11-10T00:00:00Z"), entries: entries, topics: [], calendar: utc)
        )
        let eleventh = try #require(
            MemoryPages.day(memoryInstant("2026-11-11T00:00:00Z"), entries: entries, topics: [], calendar: utc)
        )
        let notes = try #require(MemoryPages.notes(month: "2026-11", entries: entries, calendar: utc))

        #expect(tenth.text.contains("- 09:00:00 · 10000000-0000-0000-0000-0000000000AB · note · One.\n"))
        #expect(tenth.text.contains("- 09:01:00 · 20000000-0000-0000-0000-0000000000AB · note · Two.\n"))
        #expect(eleventh.text.contains("- 09:00:00 · 0000000000AB · note · Three.\n"))
        #expect(notes.text.contains("- 09:00:00 · 30000000-0000-0000-0000-0000000000AB · note · Three.\n"))
    }

    @Test func aSubjectThatReturnsLaterInTheDayIsMarkedContinued() throws {
        let entries = [
            MemoryEntry(
                id: memoryEntryID(1),
                createdAt: memoryInstant("2026-11-10T09:00:10Z"),
                text: "One.",
                thread: memorySession(sent: true)
            ),
            MemoryEntry(
                id: memoryEntryID(2),
                createdAt: memoryInstant("2026-11-10T09:10:00Z"),
                text: "Two.",
                appBundleId: "com.example.editor"
            ),
            MemoryEntry(
                id: memoryEntryID(3),
                createdAt: memoryInstant("2026-11-10T09:20:00Z"),
                text: "Three.",
                thread: memorySession(sent: true)
            ),
        ]

        let page = try #require(
            MemoryPages.day(memoryInstant("2026-11-10T00:00:00Z"), entries: entries, topics: [], calendar: utc)
        )

        #expect(page.text.contains("\n## 09:00 · omp · voiceoour\n"))
        #expect(page.text.contains("\n## 09:10 · com.example.editor\n"))
        #expect(page.text.contains("\n## 09:20 · omp · voiceoour · continued\n"))
    }

    @Test func aDayWithNoEntryHasNoPage() {
        let page = MemoryPages.day(
            memoryInstant("2026-11-12T12:00:00Z"),
            entries: memoryDayEntries,
            topics: [],
            calendar: utc
        )
        #expect(page == nil)
    }

    @Test func aThreadPageListsTheSessionByDay() throws {
        let page = try #require(
            MemoryPages.thread(
                AgentSessionKey(agent: .omp, sessionId: memorySessionID),
                entries: memoryDayEntries + [memoryNotSent],
                calendar: utc
            )
        )

        #expect(page.path == "threads/omp-01a1c154-ce7b-70a7-9d17-da6c0eb43054.md")
        #expect(
            page.text == """
                ---
                format: 2
                type: thread
                tz: \(utc.timeZone.identifier)
                agent: omp
                session: 01a1c154-ce7b-70a7-9d17-da6c0eb43054
                directory: "/Users/vlad/Desktop/voiceoour"
                resumable: true
                entries: 4
                not_sent: 1
                unchecked: 0
                first: 2026-11-10 09:27
                last: 2026-11-11 08:05
                ---

                # omp · Check agent session storage

                Resume: `cd /Users/vlad/Desktop/voiceoour && omp --resume 01a1c154-ce7b-70a7-9d17-da6c0eb43054`

                ## 2026-11-10

                - 09:27:19 · 000000000001 · sent · Testing.
                - 09:31:02 · 000000000002 · note · A note taken inside this session.
                - 09:58:30 · 000000000003 · sent · We keep the app local only.

                ## 2026-11-11

                - 08:05:00 · 000000000006 · not sent · This one never left the composer.

                """
        )
    }

    @Test func aThreadWithoutDirectoryOrResumeOmitsThoseLines() throws {
        let entry = MemoryEntry(
            id: memoryEntryID(1),
            createdAt: memoryInstant("2026-11-10T09:00:00Z"),
            text: "Hello.",
            thread: JournalThreadRef(agent: .claudeCode, sessionId: "abcdef123456")
        )

        let page = try #require(
            MemoryPages.thread(
                AgentSessionKey(agent: .claudeCode, sessionId: "abcdef123456"),
                entries: [entry],
                calendar: utc
            )
        )

        #expect(
            page.text == """
                ---
                format: 2
                type: thread
                tz: \(utc.timeZone.identifier)
                agent: claude-code
                session: abcdef123456
                resumable: false
                entries: 1
                not_sent: 0
                unchecked: 1
                first: 2026-11-10 09:00
                last: 2026-11-10 09:00
                ---

                # Claude Code · abcdef12

                ## 2026-11-10

                - 09:00:00 · 000000000001 · unchecked · Hello.

                """
        )
    }

    /// A directory is the agent's record, so a line break or a colon in it
    /// stays inside one quoted front matter value.
    @Test func aDirectoryStaysOnOneFrontMatterLine() throws {
        let entry = MemoryEntry(
            id: memoryEntryID(1),
            createdAt: memoryInstant("2026-11-10T09:00:00Z"),
            text: "Hello.",
            thread: JournalThreadRef(
                agent: .omp,
                sessionId: "abcdef123456",
                title: "Odd folder",
                workingDirectory: "/tmp/a: b\n---\nformat: 3 \"q\" \\"
            )
        )

        let page = try #require(
            MemoryPages.thread(AgentSessionKey(agent: .omp, sessionId: "abcdef123456"), entries: [entry], calendar: utc)
        )
        let lines = page.text.split(separator: "\n", omittingEmptySubsequences: false)
        let close = try #require(lines.dropFirst().firstIndex(of: "---"))

        #expect(lines.first == "---")
        #expect(
            Array(lines[1..<close]) == [
                "format: 2",
                "type: thread",
                "tz: \(utc.timeZone.identifier)",
                "agent: omp",
                "session: abcdef123456",
                #"directory: "/tmp/a: b\n---\nformat: 3 \"q\" \\""#,
                "resumable: false",
                "entries: 1",
                "not_sent: 0",
                "unchecked: 1",
                "first: 2026-11-10 09:00",
                "last: 2026-11-10 09:00",
            ]
        )
    }

    @Test func aTopicPageNamesWhereEachEntryWasSaid() {
        let unsorted = MemoryEntry(
            id: memoryEntryID(7),
            createdAt: memoryInstant("2026-11-11T12:00:00Z"),
            text: "Unsorted words.",
            userTopicID: "memory-system"
        )

        let page = MemoryPages.topic(
            memorySystem,
            entries: memoryDayEntries + [memoryNotSent, unsorted],
            topics: [memorySystem],
            calendar: utc
        )

        #expect(page.path == "topics/memory-system.md")
        #expect(
            page.text == """
                ---
                format: 2
                type: topic
                tz: \(utc.timeZone.identifier)
                topic: memory-system
                entries: 4
                ---

                # Memory system

                Design of the persistent store.

                ## 2026-11-10

                - 09:58:30 · 000000000003 · sent · We keep the app local only.
                - 10:20:11 · 000000000004 · dictation · Thanks, see you on Friday.
                - 11:02:40 · 000000000005 · note · The memory folder should be plain files.

                ## 2026-11-11

                - 12:00:00 · 000000000007 · dictation · Unsorted words.

                """
        )
    }

    @Test func aNotesPageHoldsTheMonthsNotesOnly() throws {
        let entries =
            memoryDayEntries + [
                MemoryEntry(
                    id: memoryEntryID(8),
                    createdAt: memoryInstant("2026-11-12T07:00:00Z"),
                    kind: .note,
                    text: "Buy milk."
                ),
                MemoryEntry(
                    id: memoryEntryID(9),
                    createdAt: memoryInstant("2026-10-31T23:00:00Z"),
                    kind: .note,
                    text: "October."
                ),
            ]

        let page = try #require(MemoryPages.notes(month: "2026-11", entries: entries, calendar: utc))

        #expect(page.path == "notes/2026-11.md")
        #expect(
            page.text == """
                ---
                format: 2
                type: notes
                tz: \(utc.timeZone.identifier)
                month: 2026-11
                entries: 3
                ---

                # Notes, 2026-11

                ## 2026-11-10

                - 09:31:02 · 000000000002 · note · A note taken inside this session.
                - 11:02:40 · 000000000005 · note · The memory folder should be plain files.

                ## 2026-11-12

                - 07:00:00 · 000000000008 · note · Buy milk.

                """
        )
        #expect(MemoryPages.notes(month: "2026-09", entries: entries, calendar: utc) == nil)
    }

    @Test func theIndexSummarisesTopicsDaysAndThreads() {
        let page = MemoryPages.index(entries: memoryDayEntries + [memoryNotSent], topics: [memorySystem], calendar: utc)

        #expect(page.path == "MEMORY.md")
        #expect(
            page.text == """
                ---
                format: 2
                type: index
                tz: \(utc.timeZone.identifier)
                entries: 6
                dictations: 4
                notes: 2
                first: 2026-11-10
                last: 2026-11-11
                ---

                # Voiceour memory

                Everything the owner of this Mac dictated or noted with Voiceour, verbatim. \
                Voiceour writes every file here except `agents/`.

                - Entries: 6 (4 dictations, 2 notes)
                - First entry: 2026-11-10
                - Last entry: 2026-11-11

                ## How to read this folder

                - `days/YYYY-MM-DD.md`: one day in time order, grouped by agent session or app.
                - `threads/<agent>-<session id>.md`: everything said into one agent session.
                - `topics/<topic id>.md`: everything filed under one topic.
                - `notes/YYYY-MM.md`: notes, which were saved and never pasted anywhere.
                - `entries/YYYY-MM.json`: the source records. Every other file is derived from them.
                - `topics.json`: the topics and their one-line descriptions.
                - Each entry line reads time · id · state · text. States: sent, not sent, unchecked \
                (not checked yet), note, unlinked (not linked to an agent session), dictation.
                - Your own thread, if Voiceour linked a dictation to this session: omp, threads/omp-<id>.md \
                with <id> the UUID after "Z_" in $PI_SESSION_FILE ($PI_SESSION_ID differs in a subagent); \
                Claude Code, threads/claude-code-$CLAUDE_CODE_SESSION_ID.md. No file means nothing was linked; \
                read today's day page.

                ## Rules for agents

                - Read any file. Quote the owner's words exactly.
                - Write only inside `agents/`. Voiceour overwrites or deletes every other file.
                - A file in `agents/` is Markdown. Start it with a front matter block that names `author`, \
                and `day: YYYY-MM-DD` or `topic: <topic id>`.

                ## Topics

                - [Memory system](topics/memory-system.md): 3 entries. Design of the persistent store.

                ## Recent days

                - [2026-11-11](days/2026-11-11.md): 1 entry
                - [2026-11-10](days/2026-11-10.md): 5 entries

                ## Recent threads

                - [omp · Check agent session storage](threads/omp-01a1c154-ce7b-70a7-9d17-da6c0eb43054.md): \
                4 entries, last 2026-11-11

                """
        )
    }

    @Test func anEmptyIndexOmitsTheListsItHasNothingFor() {
        let page = MemoryPages.index(entries: [], topics: [], calendar: utc)

        #expect(
            page.text.hasPrefix(
                "---\nformat: 2\ntype: index\ntz: \(utc.timeZone.identifier)\nentries: 0\ndictations: 0\nnotes: 0\n---\n"
            )
        )
        #expect(page.text.contains("- Entries: 0 (0 dictations, 0 notes)\n\n## How to read this folder"))
        #expect(!page.text.contains("First entry"))
        #expect(!page.text.contains("\nfirst: "))
        #expect(!page.text.contains("## Topics"))
        #expect(!page.text.contains("## Recent days"))
        #expect(!page.text.contains("## Recent threads"))
    }

    @Test func aSecondLineStaysInsideItsListItem() throws {
        let note = MemoryEntry(
            id: memoryEntryID(1),
            createdAt: memoryInstant("2026-11-12T07:00:00Z"),
            kind: .note,
            text: "First line\nSecond line"
        )

        let page = try #require(MemoryPages.notes(month: "2026-11", entries: [note], calendar: utc))

        #expect(page.text.hasSuffix("- 07:00:00 · 000000000001 · note · First line\n  Second line\n"))
    }

    @Test func pageTimesFollowTheCalendarsTimeZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(secondsFromGMT: 9 * 3600))
        let note = MemoryEntry(
            id: memoryEntryID(1),
            createdAt: memoryInstant("2026-11-30T20:30:05Z"),
            kind: .note,
            text: "Late."
        )

        let page = try #require(MemoryPages.notes(month: "2026-12", entries: [note], calendar: tokyo))

        #expect(page.text.contains("\ntz: \(tokyo.timeZone.identifier)\n"))
        #expect(page.text.hasSuffix("# Notes, 2026-12\n\n## 2026-12-01\n\n- 05:30:05 · 000000000001 · note · Late.\n"))
    }

    @Test func aSessionIdCannotAddAPathComponent() {
        let path = MemoryPages.threadPath(AgentSessionKey(agent: .claudeCode, sessionId: "../../etc/pass wd"))

        #expect(path == "threads/claude-code-..-..-etc-pass-wd.md")
        #expect((path as NSString).pathComponents == ["threads", "claude-code-..-..-etc-pass-wd.md"])
    }
}

@Suite("Memory planner")
struct MemoryPlannerTests {
    private let alpha = MemoryTopic(
        id: "alpha",
        name: "Alpha",
        summary: "",
        createdAt: memoryInstant("2026-10-01T08:00:00Z")
    )
    private let beta = MemoryTopic(
        id: "beta",
        name: "Beta",
        summary: "",
        createdAt: memoryInstant("2026-10-01T08:00:00Z")
    )

    private func bound(_ number: Int, _ iso: String, session: String) -> MemoryEntry {
        MemoryEntry(
            id: memoryEntryID(number),
            createdAt: memoryInstant(iso),
            text: "Entry \(number).",
            thread: JournalThreadRef(agent: .omp, sessionId: session)
        )
    }

    private func mailed(_ number: Int, _ iso: String, topic: String? = nil) -> MemoryEntry {
        MemoryEntry(
            id: memoryEntryID(number),
            createdAt: memoryInstant(iso),
            text: "Entry \(number).",
            appBundleId: "com.apple.mail",
            userTopicID: topic
        )
    }

    @Test func addingAnEntryRewritesOnlyWhatItAppearsIn() {
        let earlier = bound(1, "2026-11-09T08:00:00Z", session: "aaaa")
        let added = bound(2, "2026-11-10T10:00:00Z", session: "bbbb")

        let write = MemoryPlanner.write(
            before: [earlier],
            after: [added, earlier],
            topicsBefore: [],
            topicsAfter: [],
            calendar: utc
        )

        #expect(write.months == ["2026-11": [earlier, added]])
        #expect(write.topics == nil)
        #expect(write.pages.map(\.path) == ["MEMORY.md", "days/2026-11-10.md", "threads/omp-bbbb.md"])
        #expect(write.removedPages.isEmpty)
    }

    @Test func removingTheLastEntryOfADayRemovesItsPageAndEmptyMonth() {
        let october = mailed(1, "2026-10-20T08:00:00Z")
        let november = mailed(2, "2026-11-10T10:00:00Z")

        let write = MemoryPlanner.write(
            before: [october, november],
            after: [october],
            topicsBefore: [],
            topicsAfter: [],
            calendar: utc
        )

        #expect(write.months == ["2026-11": []])
        #expect(write.pages.map(\.path) == ["MEMORY.md"])
        #expect(write.removedPages == ["days/2026-11-10.md"])
    }

    @Test func movingAnEntryBetweenTopicsRewritesBothTopicPages() throws {
        let filed = mailed(1, "2026-11-10T10:00:00Z", topic: "alpha")
        var moved = filed
        moved.userTopicID = "beta"

        let write = MemoryPlanner.write(
            before: [filed],
            after: [moved],
            topicsBefore: [alpha, beta],
            topicsAfter: [alpha, beta],
            calendar: utc
        )

        #expect(write.pages.map(\.path) == ["MEMORY.md", "days/2026-11-10.md", "topics/alpha.md", "topics/beta.md"])
        let alphaPage = try #require(write.pages.first { $0.path == "topics/alpha.md" })
        let betaPage = try #require(write.pages.first { $0.path == "topics/beta.md" })
        #expect(alphaPage.text.contains("\nentries: 0\n"))
        #expect(betaPage.text.contains("\nentries: 1\n"))
        #expect(write.topics == nil)
    }

    @Test func removingATopicRemovesItsPageAndRewritesTheTopics() {
        let filed = mailed(1, "2026-11-10T10:00:00Z", topic: "alpha")

        let write = MemoryPlanner.write(
            before: [filed],
            after: [filed],
            topicsBefore: [alpha, beta],
            topicsAfter: [beta],
            calendar: utc
        )

        #expect(write.topics == [beta])
        #expect(write.months.isEmpty)
        #expect(write.pages.map(\.path) == ["MEMORY.md", "topics/beta.md"])
        #expect(write.removedPages == ["topics/alpha.md"])
    }

    @Test func identicalStatesWriteNothing() {
        let first = bound(1, "2026-11-09T08:00:00Z", session: "aaaa")
        let second = mailed(2, "2026-11-10T10:00:00Z", topic: "alpha")

        let write = MemoryPlanner.write(
            before: [first, second],
            after: [second, first],
            topicsBefore: [alpha],
            topicsAfter: [alpha],
            calendar: utc
        )

        #expect(write.isEmpty)
        #expect(write == MemoryWrite())
    }

    @Test func rebuildCoversEveryMonthAndPage() {
        let october = mailed(1, "2026-10-20T08:00:00Z")
        let note = MemoryEntry(
            id: memoryEntryID(2),
            createdAt: memoryInstant("2026-10-21T09:00:00Z"),
            kind: .note,
            text: "A note.",
            userTopicID: "alpha"
        )
        let november = bound(3, "2026-11-09T08:00:00Z", session: "aaaa")

        let write = MemoryPlanner.rebuild(entries: [november, note, october], topics: [alpha, beta], calendar: utc)

        #expect(write.months == ["2026-10": [october, note], "2026-11": [november]])
        #expect(write.topics == [alpha, beta])
        #expect(
            write.pages.map(\.path) == [
                "MEMORY.md",
                "days/2026-10-20.md",
                "days/2026-10-21.md",
                "days/2026-11-09.md",
                "notes/2026-10.md",
                "threads/omp-aaaa.md",
                "topics/alpha.md",
                "topics/beta.md",
            ]
        )
        #expect(write.removedPages.isEmpty)
    }

    @Test func aPagesRebuildWritesEveryPageAndNoRecord() {
        let october = mailed(1, "2026-10-20T08:00:00Z")
        let november = bound(2, "2026-11-09T08:00:00Z", session: "aaaa")
        let full = MemoryPlanner.rebuild(entries: [november, october], topics: [alpha], calendar: utc)

        let write = MemoryPlanner.rebuildPages(
            entries: [november, october], topics: [alpha], calendar: utc, sweep: true)

        #expect(write.months.isEmpty)
        #expect(write.topics == nil)
        #expect(write.pages == full.pages)
        #expect(write.removedPages.isEmpty)
        #expect(write.sweepDerived)
        // Foundation may name UTC "GMT"; the stamp states whatever identifier the calendar carries.
        #expect(write.pagesFormat == "2 gregorian \(utc.timeZone.identifier)")
        #expect(MemoryPages.formatStamp(calendar: utc) == "2 gregorian \(utc.timeZone.identifier)")
        #expect(
            !MemoryPlanner.rebuildPages(entries: [october], topics: [], calendar: utc, sweep: false).sweepDerived
        )
    }

    /// A launch rebuild of an empty memory must not create the folder.
    @Test func aPagesRebuildOfAnEmptyStateWritesNothing() {
        let write = MemoryPlanner.rebuildPages(entries: [], topics: [], calendar: utc, sweep: true)

        #expect(write.isEmpty)
        #expect(write == MemoryWrite())
    }

    /// Diff writes applied in order to a map of files leave exactly the pages a
    /// pages rebuild of the same state renders, byte for byte, after every step.
    /// Ids share a few endings, so pages often hold two ids that end alike.
    @Test func diffWritesAppliedInOrderEqualAPagesRebuild() throws {
        var random = SeededGenerator(seed: 0x2026_1110)
        let topics = [alpha, beta]
        let topicChoices: [String?] = ["alpha", "beta", nil]
        let sessions = ["aaaa", "bbbb", "cccc"]
        let titles: [String?] = ["First title", "Second title", nil]
        let sentChoices: [Bool?] = [true, false, nil]
        let misses: [AgentLinkMiss?] = [.busy, .codex, nil]
        let kinds: [UtteranceKind] = [.decision, .idea, .todo, .question, .chatter]
        let endings = ["0000000000A1", "0000000000B2", "0000000000C3", "0000000000D4", "0000000000E5", "0000000000F6"]
        // Four days across a month boundary.
        let start = memoryInstant("2026-10-30T18:00:00Z")

        func pick<Element>(_ choices: [Element]) -> Element {
            choices[Int.random(in: 0..<choices.count, using: &random)]
        }
        func chance(_ oneIn: Int) -> Bool {
            Int.random(in: 0..<oneIn, using: &random) == 0
        }
        func session() -> JournalThreadRef {
            JournalThreadRef(
                agent: .omp,
                sessionId: pick(sessions),
                title: pick(titles),
                workingDirectory: "/work/\(pick(sessions))",
                resumable: chance(2),
                sent: pick(sentChoices)
            )
        }
        func newID(_ serial: Int) -> UUID {
            let hex = String(serial, radix: 16, uppercase: true)
            return UUID(
                uuidString: String(repeating: "0", count: 8 - hex.count) + hex + "-0000-0000-0000-" + pick(endings))!
        }

        var entries: [MemoryEntry] = []
        var files = pageFiles(MemoryPlanner.rebuildPages(entries: [], topics: topics, calendar: utc, sweep: true))
        var serial = 0
        for step in 1...300 {
            var next = entries
            let index = next.isEmpty ? nil : Int.random(in: 0..<next.count, using: &random)
            switch (Int.random(in: 0..<8, using: &random), index) {
            case (0...2, _), (_, nil):
                serial += 1
                let createdAt = start.addingTimeInterval(TimeInterval(Int.random(in: 0..<(4 * 86_400), using: &random)))
                let isNote = chance(4)
                let linked = chance(2)
                let thread = linked ? session() : nil
                let app = !isNote && !linked && chance(2) ? "com.apple.mail" : nil
                let text = chance(5) ? "Entry \(serial).\nSecond line." : "Entry \(serial)."
                let userTopic = chance(3) ? pick(topicChoices) : nil
                let label =
                    chance(4)
                    ? EntryLabel(
                        kind: pick(kinds),
                        kindConfidence: 0.9,
                        topicID: pick(topicChoices),
                        topicConfidence: 0.8,
                        model: "jev-1.14.0",
                        labeledAt: createdAt
                    ) : nil
                let miss = linked ? nil : pick(misses)
                next.append(
                    MemoryEntry(
                        id: newID(serial),
                        createdAt: createdAt,
                        kind: isNote ? .note : .dictation,
                        text: text,
                        appBundleId: app,
                        thread: thread,
                        userTopicID: userTopic,
                        label: label,
                        unlinked: miss
                    )
                )
            case (3, let index?):
                next[index].text += " Edited."
            case (4, let index?):
                let topic = pick(topicChoices)
                next[index].userTopicID = topic
                next[index].userRemovedTopic = topic == nil
            case (5, let index?):
                next[index].thread = session()
            case (6, let index?):
                if next[index].thread != nil {
                    next[index].thread?.sent = pick(sentChoices)
                } else {
                    next[index].unlinked = pick(misses)
                }
            case (_, let index?):
                next.remove(at: index)
            }

            let write = MemoryPlanner.write(
                before: entries,
                after: next,
                topicsBefore: topics,
                topicsAfter: topics,
                calendar: utc
            )
            #expect(!write.sweepDerived)
            #expect(write.pagesFormat == nil)
            for page in write.pages {
                files[page.path] = page.text
            }
            for path in write.removedPages {
                files[path] = nil
            }
            entries = next

            let rebuilt = pageFiles(
                MemoryPlanner.rebuildPages(entries: entries, topics: topics, calendar: utc, sweep: true)
            )
            try #require(files == rebuilt, "step \(step)")
        }

        #expect(entries.count > 20)
        // Some page printed whole ids, so the collision rule was exercised.
        #expect(files.values.contains { $0.contains("-0000-0000-0000-0000000000") })
    }
}

/// SplitMix64: a seeded run replays the same steps on every run and every Mac.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private func pageFiles(_ write: MemoryWrite) -> [String: String] {
    Dictionary(uniqueKeysWithValues: write.pages.map { ($0.path, $0.text) })
}
