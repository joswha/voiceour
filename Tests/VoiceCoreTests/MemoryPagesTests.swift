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
                # 2026-11-10, Tuesday

                5 entries · 25 words · 1 agent session · 1 app · 2 notes

                ## Highlights

                - 09:58 · Decision · We keep the app local only.

                ## 09:27–09:58 · omp · voiceoour

                [Check agent session storage](../threads/omp-01a1c154-ce7b-70a7-9d17-da6c0eb43054.md)

                - 09:27:19 · Testing.
                - 09:31:02 · note · A note taken inside this session.
                - 09:58:30 · We keep the app local only.

                ## 10:20 · Mail

                - 10:20:11 · Thanks, see you on Friday.

                ## 11:02 · Notes

                - 11:02:40 · The memory folder should be plain files.

                """
        )
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
                # omp · Check agent session storage

                - Agent: omp
                - Session: 01a1c154-ce7b-70a7-9d17-da6c0eb43054
                - Project: voiceoour
                - Directory: /Users/vlad/Desktop/voiceoour
                - Resume: `cd /Users/vlad/Desktop/voiceoour && omp --resume 01a1c154-ce7b-70a7-9d17-da6c0eb43054`
                - Entries: 4, from 2026-11-10 09:27 to 2026-11-11 08:05

                ## 2026-11-10

                - 09:27:19 · Testing.
                - 09:31:02 · note · A note taken inside this session.
                - 09:58:30 · We keep the app local only.

                ## 2026-11-11

                - 08:05:00 · not sent · This one never left the composer.

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
                # Claude Code · abcdef12

                - Agent: Claude Code
                - Session: abcdef123456
                - Entries: 1, from 2026-11-10 09:00 to 2026-11-10 09:00

                ## 2026-11-10

                - 09:00:00 · Hello.

                """
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
                # Memory system

                Design of the persistent store.

                - Topic id: memory-system
                - Entries: 4

                ## 2026-11-10

                - 09:58:30 · omp · voiceoour · We keep the app local only.
                - 10:20:11 · Mail · Thanks, see you on Friday.
                - 11:02:40 · note · The memory folder should be plain files.

                ## 2026-11-11

                - 12:00:00 · Unsorted words.

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
                # Notes, 2026-11

                ## 2026-11-10

                - 09:31:02 · A note taken inside this session.
                - 11:02:40 · The memory folder should be plain files.

                ## 2026-11-12

                - 07:00:00 · Buy milk.

                """
        )
        #expect(MemoryPages.notes(month: "2026-09", entries: entries, calendar: utc) == nil)
    }

    @Test func theIndexSummarisesTopicsDaysAndThreads() {
        let page = MemoryPages.index(entries: memoryDayEntries + [memoryNotSent], topics: [memorySystem], calendar: utc)

        #expect(page.path == "MEMORY.md")
        #expect(
            page.text == """
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

        #expect(page.text.contains("- Entries: 0 (0 dictations, 0 notes)\n\n## How to read this folder"))
        #expect(!page.text.contains("First entry"))
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

        #expect(page.text.hasSuffix("- 07:00:00 · First line\n  Second line\n"))
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

        #expect(page.text == "# Notes, 2026-12\n\n## 2026-12-01\n\n- 05:30:05 · Late.\n")
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
        #expect(alphaPage.text.contains("- Entries: 0\n"))
        #expect(betaPage.text.contains("- Entries: 1\n"))
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
}
