import Foundation
import Testing

@testable import VoiceCore

/// A whole-second instant from an ISO 8601 string with an explicit zone, so a
/// modification date set on disk reads back exactly.
private func agentNoteInstant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

@Suite("Agent notes")
struct AgentNotesTests {
    private let modifiedAt = agentNoteInstant("2026-11-10T09:27:19Z")

    private func parse(_ text: String) -> AgentNote? {
        AgentNoteParser.parse(fileName: "note.md", text: text, modifiedAt: modifiedAt)
    }

    // MARK: Parser

    @Test func dayNoteReadsItsFieldsAndBody() throws {
        let note = try #require(
            parse("---\nauthor: Claude\nday: 2026-11-10\ntitle: Tuesday recap\n---\nWorked on memory.\n")
        )

        #expect(
            note
                == AgentNote(
                    id: "note.md",
                    author: "Claude",
                    title: "Tuesday recap",
                    day: "2026-11-10",
                    body: "Worked on memory.",
                    modifiedAt: modifiedAt
                )
        )
    }

    @Test func topicNoteNeedsNoTitle() throws {
        let note = try #require(parse("---\nauthor: omp\ntopic: memory-system\n---\nThe store is plain files."))

        #expect(note.topicID == "memory-system")
        #expect(note.day == nil)
        #expect(note.title == nil)
        #expect(note.body == "The store is plain files.")
    }

    @Test func noteMayNameBothDayAndTopic() throws {
        let note = try #require(parse("---\nauthor: omp\nday: 2028-02-29\ntopic: memory-system\n---\nBoth."))

        #expect(note.day == "2028-02-29")
        #expect(note.topicID == "memory-system")
    }

    @Test func quotedValuesLoseTheirQuotesAndSplitAtTheFirstColon() throws {
        let note = try #require(
            parse(
                "---\nauthor: \"Claude Code\"\nday: '2026-11-10'\ntitle: \"Recap: Tuesday\"\n"
                    + "a line without a colon\nmodel: ignored\n---\nBody."
            )
        )

        #expect(note.author == "Claude Code")
        #expect(note.day == "2026-11-10")
        #expect(note.title == "Recap: Tuesday")
    }

    @Test func sessionIsTrimmedAndUnquoted() throws {
        let doubleQuoted = try #require(
            parse("---\nauthor: omp\nday: 2026-11-10\nsession:   \" omp-5f0c_2b4e.1 \"  \n---\nBody.")
        )
        let singleQuoted = try #require(parse("---\nauthor: omp\nday: 2026-11-10\nsession: 'claude-code-a1'\n---\nB."))
        let bare = try #require(parse("---\nauthor: omp\ntopic: memory-system\nsession: omp-abc\n---\nB."))

        #expect(doubleQuoted.session == "omp-5f0c_2b4e.1")
        #expect(singleQuoted.session == "claude-code-a1")
        #expect(bare.session == "omp-abc")
    }

    @Test(
        arguments: [
            "omp/abc",
            "../omp-abc",
            "omp abc",
            "omp:abc",
            "omp-café",
            "omp-abc\"",
            "\"\"",
            "",
        ]
    )
    func sessionOutsideTheStemAlphabetIsDroppedAndTheNoteKept(_ value: String) throws {
        let note = try #require(parse("---\nauthor: omp\nday: 2026-11-10\nsession: \(value)\n---\nBody."))

        #expect(note.session == nil)
        #expect(note.day == "2026-11-10")
    }

    @Test func impossibleDayIsDroppedWhenTopicStillPlacesTheNote() throws {
        let note = try #require(parse("---\nauthor: omp\nday: 2026-13-40\ntopic: memory-system\n---\nBody."))

        #expect(note.day == nil)
        #expect(note.topicID == "memory-system")
    }

    @Test(
        arguments: [
            "---\nday: 2026-11-10\n---\nMissing author.",
            "---\nauthor:   \nday: 2026-11-10\n---\nBlank author.",
            "---\nauthor: \"\"\nday: 2026-11-10\n---\nQuoted blank author.",
            "---\nauthor: omp\nsession: omp-abc\n---\nOnly a session.",
            "---\nauthor: omp\ntitle: Neither\n---\nNo day and no topic.",
            "---\nauthor: omp\ntopic:  \n---\nBlank topic.",
            "---\nauthor: omp\nday: 2026-13-40\n---\nImpossible date.",
            "---\nauthor: omp\nday: 2026-02-29\n---\nNot a leap year.",
            "---\nauthor: omp\nday: 2026-11-1\n---\nShort date.",
            "author: omp\nday: 2026-11-10\n---\nNo opening line.",
            "\n---\nauthor: omp\nday: 2026-11-10\n---\nBlank line before the opening line.",
            "--- \nauthor: omp\nday: 2026-11-10\n---\nOpening line with a trailing space.",
            "---\nauthor: omp\nday: 2026-11-10\nNo closing line.",
            "",
        ]
    )
    func textThatCannotBePlacedIsNotANote(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func bodyKeepsItsOwnHorizontalRules() throws {
        let note = try #require(
            parse("---\nauthor: omp\nday: 2026-11-10\n---\n\nFirst part.\n\n---\n\nSecond part.\n")
        )

        #expect(note.body == "First part.\n\n---\n\nSecond part.")
    }

    @Test func blankLinesAroundTheBodyAreTrimmedAndInnerOnesKept() throws {
        let note = try #require(
            parse("---\nauthor: omp\ntopic: memory-system\n---\n\n  \n# Heading\n\n\n  Indented.\n\n \n")
        )

        #expect(note.body == "# Heading\n\n\n  Indented.")
    }

    @Test func crlfLinesParseAndTheBodyKeepsThem() throws {
        let note = try #require(parse("---\r\nauthor: omp\r\nday: 2026-11-10\r\n---\r\nOne.\r\nTwo.\r\n"))

        #expect(note.author == "omp")
        #expect(note.body == "One.\r\nTwo.")
    }

    @Test func emptyBodyIsStillANote() throws {
        let note = try #require(parse("---\nauthor: omp\nday: 2026-11-10\n---"))

        #expect(note.body == "")
    }

    // MARK: Loader

    /// A store under a fresh temporary directory, and that directory, which the test removes.
    private func temporaryStore() -> (store: MemoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (MemoryStore(root: directory.appendingPathComponent("memory", isDirectory: true)), directory)
    }

    /// Writes `data` at `path` under the store's `agents/`, last modified at the ISO 8601 instant `modified`.
    private func writeAgentFile(_ data: Data, at path: String, in store: MemoryStore, modified: String) throws {
        let url = store.agentsDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: agentNoteInstant(modified)], ofItemAtPath: url.path)
    }

    private func dayNote(_ body: String) -> Data {
        Data("---\nauthor: omp\nday: 2026-11-10\n---\n\(body)\n".utf8)
    }

    /// A day note of exactly `size` bytes.
    private func dayNote(bytes size: Int) -> Data {
        let header = "---\nauthor: omp\nday: 2026-11-10\n---\n"
        return Data((header + String(repeating: "a", count: size - header.utf8.count)).utf8)
    }

    @Test func loaderReadsOnlyVisibleMarkdownFilesDirectlyUnderAgentsNewestFirst() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newest = "2026-11-10T12:00:00Z"
        let notUTF8 = Data("---\nauthor: omp\nday: 2026-11-10\n---\nCaf".utf8) + Data([0xE9, 0x0A])

        try writeAgentFile(dayNote("Old."), at: "old.md", in: store, modified: "2026-11-01T08:00:00Z")
        try writeAgentFile(dayNote("New."), at: "new.md", in: store, modified: "2026-11-09T08:00:00Z")
        try writeAgentFile(dayNote("Middle."), at: "middle.md", in: store, modified: "2026-11-05T08:00:00Z")
        try writeAgentFile(dayNote("Nested."), at: "folder.md/inner.md", in: store, modified: newest)
        try writeAgentFile(dayNote("Text."), at: "notes.txt", in: store, modified: newest)
        try writeAgentFile(dayNote("Hidden."), at: ".hidden.md", in: store, modified: newest)
        try writeAgentFile(Data("Not front matter.\n".utf8), at: "broken.md", in: store, modified: newest)
        try writeAgentFile(notUTF8, at: "latin1.md", in: store, modified: newest)
        try writeAgentFile(dayNote(bytes: AgentNoteParser.maximumBytes + 1), at: "huge.md", in: store, modified: newest)
        let outside = directory.appendingPathComponent("outside.md")
        try dayNote("Outside.").write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: store.agentsDirectory.appendingPathComponent("link.md"),
            withDestinationURL: outside
        )

        let notes = store.loadAgentNotes()

        #expect(notes.map(\.id) == ["new.md", "middle.md", "old.md"])
        #expect(notes.map(\.body) == ["New.", "Middle.", "Old."])
        #expect(notes.first?.modifiedAt == agentNoteInstant("2026-11-09T08:00:00Z"))
    }

    @Test func fileOfExactlyTheByteLimitLoadsAndOneByteMoreDoesNot() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modified = "2026-11-10T12:00:00Z"

        try writeAgentFile(dayNote(bytes: AgentNoteParser.maximumBytes), at: "limit.md", in: store, modified: modified)
        try writeAgentFile(
            dayNote(bytes: AgentNoteParser.maximumBytes + 1), at: "over.md", in: store, modified: modified)

        #expect(store.loadAgentNotes().map(\.id) == ["limit.md"])
    }

    @Test func limitCountsParsedNotesOnly() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAgentFile(
            Data("Not front matter.\n".utf8), at: "broken.md", in: store, modified: "2026-11-10T12:00:00Z")
        try writeAgentFile(dayNote("Third."), at: "third.md", in: store, modified: "2026-11-10T11:00:00Z")
        try writeAgentFile(dayNote("Second."), at: "second.md", in: store, modified: "2026-11-10T10:00:00Z")
        try writeAgentFile(dayNote("First."), at: "first.md", in: store, modified: "2026-11-10T09:00:00Z")

        #expect(store.loadAgentNotes(maximumFiles: 2).map(\.id) == ["third.md", "second.md"])
    }

    @Test func sameModificationDateOrdersByFileName() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAgentFile(dayNote("B."), at: "b.md", in: store, modified: "2026-11-10T12:00:00Z")
        try writeAgentFile(dayNote("A."), at: "a.md", in: store, modified: "2026-11-10T12:00:00Z")

        #expect(store.loadAgentNotes().map(\.id) == ["a.md", "b.md"])
    }

    @Test func absentFolderIsNoNotes() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.loadAgentNotes().isEmpty)
    }

    // MARK: Prompts

    private let root = URL(
        fileURLWithPath: "/Users/test/Library/Application Support/Voiceour/memory",
        isDirectory: true
    )

    @Test func recapPromptNamesTheDayInTheCalendarsTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bucharest"))
        let expected = """
            Read "/Users/test/Library/Application Support/Voiceour/memory/days/2026-11-10.md", the record of what \
            I dictated and noted that day, and "/Users/test/Library/Application Support/Voiceour/memory/MEMORY.md" \
            for the folder's rules. Write a recap of the day: what I worked on, what I decided, and what is still \
            open. Quote my words exactly wherever you quote. Save it as \
            "/Users/test/Library/Application Support/Voiceour/memory/agents/2026-11-10-recap.md", starting with a \
            front matter block that names author (your own name), day: 2026-11-10 and a title.
            """

        let day = agentNoteInstant("2026-11-09T23:30:00Z")

        #expect(MemoryPages.recapPrompt(day: day, root: root, calendar: calendar) == expected)
    }

    @Test func synthesisPromptNamesTheTopicPageAndItsAgentFile() {
        let topic = MemoryTopic(
            id: "memory-system",
            name: "Memory system",
            summary: "Design of the persistent store.",
            createdAt: agentNoteInstant("2026-10-01T08:00:00Z")
        )
        let expected = """
            Read "/Users/test/Library/Application Support/Voiceour/memory/topics/memory-system.md", everything I \
            filed under the topic "Memory system", and \
            "/Users/test/Library/Application Support/Voiceour/memory/MEMORY.md" for the folder's rules. Write a \
            synthesis: what I concluded, what changed over time, and what is still undecided. Quote my words \
            exactly wherever you quote. Save it as \
            "/Users/test/Library/Application Support/Voiceour/memory/agents/topic-memory-system.md", starting \
            with a front matter block that names author (your own name), topic: memory-system and a title.
            """

        #expect(MemoryPages.synthesisPrompt(topic: topic, root: root) == expected)
    }

    @Test func outcomePromptNamesTheThreadPageAndItsAgentFileLiterally() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bucharest"))
        let key = AgentSessionKey(agent: .omp, sessionId: "5f0c2b4e-3a1d-4c8e-9b7a-2d6e1f0a9c33")
        let expected = """
            Read "/Users/test/Library/Application Support/Voiceour/memory/threads/\
            omp-5f0c2b4e-3a1d-4c8e-9b7a-2d6e1f0a9c33.md", what I said to you in this session, and \
            "/Users/test/Library/Application Support/Voiceour/memory/MEMORY.md" for the folder's rules. Write \
            what you did with what I asked, what is still open, and what you need from me. Quote my words \
            exactly wherever you quote. Save it as "/Users/test/Library/Application Support/Voiceour/memory/\
            agents/omp-5f0c2b4e-3a1d-4c8e-9b7a-2d6e1f0a9c33.md", replacing that file if it exists, starting with \
            a front matter block that names author (your own name), day: 2026-11-10, \
            session: omp-5f0c2b4e-3a1d-4c8e-9b7a-2d6e1f0a9c33 and a title.
            """

        let day = agentNoteInstant("2026-11-09T23:30:00Z")

        #expect(MemoryPages.outcomePrompt(thread: key, day: day, root: root, calendar: calendar) == expected)
    }

    @Test(
        arguments: [
            AgentSessionKey(agent: .omp, sessionId: "5f0c2b4e-3a1d-4c8e-9b7a-2d6e1f0a9c33"),
            AgentSessionKey(agent: .claudeCode, sessionId: "a1b2c3d4-0000-4000-8000-000000000001"),
            AgentSessionKey(agent: .omp, sessionId: "id with spaces: and ü"),
        ]
    )
    func threadFileStemIsTheThreadPageNameAndANoteCanCarryIt(_ key: AgentSessionKey) throws {
        let stem = MemoryPages.threadFileStem(key)
        let note = try #require(parse("---\nauthor: omp\nday: 2026-11-10\nsession: \(stem)\n---\nBody."))

        #expect("threads/\(stem).md" == MemoryPages.threadPath(key))
        #expect(MemoryPages.outcomeNotePath(key) == "agents/\(stem).md")
        #expect(note.session == stem)
    }

    @Test(arguments: ["../../../etc/passwd", "/absolute/path", "a/../../b", "..", "/"])
    func sessionIdCannotSteerTheOutcomeNoteOutsideAgents(_ sessionId: String) {
        let key = AgentSessionKey(agent: .claudeCode, sessionId: sessionId)
        let path = MemoryPages.outcomeNotePath(key)
        let resolved = root.appendingPathComponent(path).standardizedFileURL

        #expect(path.hasPrefix("agents/"))
        #expect(!path.dropFirst("agents/".count).contains("/"))
        #expect(resolved.deletingLastPathComponent().path == root.appendingPathComponent("agents").path)
        #expect(resolved.lastPathComponent == "\(MemoryPages.threadFileStem(key)).md")
    }
}
