import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("AgentPromptEvidenceReader")
struct AgentPromptEvidenceReaderTests {
    /// 2026-11-09T17:51:40Z, when the fixture dictation was delivered.
    private static let at = Date(timeIntervalSince1970: 1_794_246_700)
    private static let words = "Please move the evidence reader into its own file"
    private static let project = ".omp/agent/sessions/-Users-v-project"
    private static let ompId = "01a1c170-1b4d-7e63-8f5c-4d1a6b8c9e32"
    private static let forkId = "01a1c171-2c5e-7f74-9a6d-5e2b7c9d0f43"
    private static let subagentId = "01a1c172-3d6f-7085-ab7e-6f3c8d0e1a54"
    private static let linkId = "01a1c173-4e70-7196-bc8f-704d9e1f2b65"
    private static let archivedId = "01a1c174-5f81-72a7-cd90-815eaf203c76"
    private static let claudeId = AgentFixtures.claudeSessionId

    private func query(_ text: String = AgentPromptEvidenceReaderTests.words) -> PromptEvidenceQuery {
        PromptEvidenceQuery(id: UUID(), text: text, at: Self.at)
    }

    private func later(_ seconds: TimeInterval) -> Date {
        Self.at.addingTimeInterval(seconds)
    }

    private func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func ompFile(_ id: String, folder: String = AgentPromptEvidenceReaderTests.project) -> String {
        "\(folder)/2026-11-09T17-50-00-000Z_\(id).jsonl"
    }

    /// The session the fixture dictation went to, begun a minute before it.
    @discardableResult
    private func writeSession(_ home: FakeAgentHome, prompts: [(text: String, sentAt: Date)]) throws -> String {
        try writeOmp(home, ompFile(Self.ompId), id: Self.ompId, startedAt: later(-60), prompts: prompts)
    }

    /// Writes an omp session file that began at `startedAt` and holds
    /// `prompts`, modified after every query's window opened.
    @discardableResult
    private func writeOmp(
        _ home: FakeAgentHome,
        _ file: String,
        id: String,
        startedAt: Date,
        title: String = "Evidence",
        parent: String? = nil,
        prompts: [(text: String, sentAt: Date)],
        after: [String] = []
    ) throws -> String {
        let fork = parent.map { #","parentSession":"\#($0)""# } ?? ""
        try home.write(
            file,
            lines: [
                #"{"type":"title","v":1,"title":"\#(title)","source":"auto"}"#,
                #"{"type":"session","version":3,"id":"\#(id)","timestamp":"\#(iso(startedAt))","#
                    + #""cwd":"/Users/v/project"\#(fork)}"#,
            ] + prompts.map { AgentFixtures.ompUser($0.text, at: iso($0.sentAt)) } + after
        )
        try home.setModified(file, to: later(3_600))
        return file
    }

    private func claudeLine(
        _ display: String,
        sentAt: Date,
        sessionId: String? = AgentPromptEvidenceReaderTests.claudeId,
        pasted: String = "{}"
    ) -> String {
        let milliseconds = Int64((sentAt.timeIntervalSince1970 * 1_000).rounded())
        let session = sessionId.map { #","sessionId":"\#($0)""# } ?? ""
        return #"{"display":"\#(display)","pastedContents":\#(pasted),"timestamp":\#(milliseconds),"#
            + #""project":"/Users/v/claude"\#(session)}"#
    }

    private func writeClaudeHistory(_ home: FakeAgentHome, _ lines: [String]) throws {
        try home.write(".claude/history.jsonl", lines: lines)
        try home.setModified(".claude/history.jsonl", to: later(3_600))
    }

    private func reader(_ home: FakeAgentHome, log: AgentFileReadLog? = nil) -> AgentPromptEvidenceReader {
        AgentPromptEvidenceReader(
            files: AgentSessionFiles(home: home.url, fileSystem: log?.fileSystem ?? .live)
        )
    }

    // MARK: omp

    @Test func anOmpSessionHoldingTheWordsIsTheMatchWithItsOwnFacts() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = try writeOmp(
            home,
            ompFile(Self.ompId),
            id: Self.ompId,
            startedAt: later(-60),
            title: "\u{F0339} Evidence",
            prompts: [("Note this: \(Self.words), thanks.", later(8))]
        )
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect(
            run
                == PromptEvidenceRun(
                    matches: [
                        wanted.id: PromptEvidenceMatch(
                            agent: .omp,
                            sessionId: Self.ompId,
                            sentAt: later(8),
                            sessionFile: home.canonicalPath(file),
                            workingDirectory: "/Users/v/project",
                            title: "Evidence"
                        )
                    ]
                )
        )
    }

    /// A fork copies its parent's prompts with their original times into a
    /// file that began later; only the parent was sent the words.
    @Test func aForkWhoseCopiedPromptPredatesItsOwnStartIsIgnored() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeSession(home, prompts: [(Self.words, later(5))])
        try writeOmp(
            home,
            "\(Self.project)/2026-11-09T17-52-00-000Z_\(Self.forkId).jsonl",
            id: Self.forkId,
            startedAt: later(20),
            parent: Self.ompId,
            prompts: [(Self.words, later(5)), ("A different prompt the fork was sent itself", later(30))]
        )
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect(run.matches[wanted.id]?.sessionId == Self.ompId)
        #expect(run.matches[wanted.id]?.sentAt == later(5))
        #expect(run.ambiguous.isEmpty)
    }

    /// Subagent transcripts, archives, custom session files and a name that
    /// only links into a subagent folder are never opened.
    @Test func filesBeyondTheTopLevelSessionFilesAreNeverRead() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let parent = ompFile(Self.ompId)
        try writeOmp(home, parent, id: Self.ompId, startedAt: later(-60), prompts: [(Self.words, later(5))])
        let subagentFolder = parent.replacingOccurrences(of: ".jsonl", with: "")
        let subagent = try writeOmp(
            home,
            ompFile(Self.subagentId, folder: subagentFolder),
            id: Self.subagentId,
            startedAt: later(-60),
            prompts: [(Self.words, later(6))]
        )
        try writeOmp(
            home,
            ompFile(Self.archivedId, folder: ".omp/agent/sessions-archive/-Users-v-project"),
            id: Self.archivedId,
            startedAt: later(-60),
            prompts: [(Self.words, later(7))]
        )
        try writeOmp(
            home,
            ompFile(Self.archivedId, folder: ".omp/agent/custom-session-files/-Users-v-project"),
            id: Self.archivedId,
            startedAt: later(-60),
            prompts: [(Self.words, later(7))]
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.path(ompFile(Self.linkId)),
            withDestinationPath: home.path(subagent)
        )
        let log = AgentFileReadLog()
        let wanted = query()

        let run = reader(home, log: log).evidence(for: [wanted])

        #expect(run.matches[wanted.id]?.sessionId == Self.ompId)
        #expect(run.ambiguous.isEmpty)
        let sessions = home.canonicalPath(Self.project) + "/"
        #expect(!log.readPaths.isEmpty)
        #expect(log.readPaths.allSatisfy { $0 == home.canonicalPath(parent) })
        // The parent file's own path starts with the folder's name, so the check needs the separator.
        #expect(!log.readPaths.contains { $0.hasPrefix(home.canonicalPath(subagentFolder) + "/") })
        #expect(log.readPaths.allSatisfy { $0.hasPrefix(sessions) })
    }

    @Test func aFileLastModifiedBeforeTheWindowOpenedIsNotRead() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = try writeSession(home, prompts: [(Self.words, later(5))])
        try home.setModified(file, to: later(-1.5))
        let log = AgentFileReadLog()

        let run = reader(home, log: log).evidence(for: [query()])

        #expect(run == PromptEvidenceRun())
        #expect(log.readPaths.isEmpty)
    }

    @Test(arguments: [(-1.1, false), (-1.0, true), (1_800.0, true), (1_801.0, false)])
    func aPromptCountsOnlyInsideTheWindow(offset: TimeInterval, counts: Bool) throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeSession(home, prompts: [(Self.words, later(offset))])
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect((run.matches[wanted.id]?.sentAt == later(offset)) == counts)
        #expect(run.matches.count == (counts ? 1 : 0))
    }

    /// The binding reader stops at 16 MiB; this pass reads every byte.
    @Test func aFileOverSixteenMebibytesStillMatchesAPromptNearItsHead() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let reply =
            #"{"type":"message","id":"r","timestamp":"\#(iso(later(10)))","#
            + #""message":{"role":"assistant","content":"\#(String(repeating: "x", count: 1_024))"}}"#
        let file = try writeOmp(
            home,
            ompFile(Self.ompId),
            id: Self.ompId,
            startedAt: later(-60),
            prompts: [(Self.words, later(5))],
            after: Array(repeating: reply, count: 17_000)
        )
        #expect(try home.size(file) > 16 << 20)
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect(run.matches[wanted.id]?.sentAt == later(5))
    }

    // MARK: The rule

    @Test func twoSessionsHoldingTheWordsAreAmbiguous() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeSession(home, prompts: [(Self.words, later(5))])
        try writeClaudeHistory(home, [claudeLine(Self.words, sentAt: later(9))])
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect(run == PromptEvidenceRun(matches: [:], ambiguous: [wanted.id]))
    }

    @Test func fewerThanSixWordsNeverMatch() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeOmp(
            home,
            ompFile(Self.ompId),
            id: Self.ompId,
            startedAt: later(-60),
            prompts: [("Ship it, then test it. Ship it, then test it now.", later(5))]
        )
        let five = query("Ship it, then test it.")
        let six = query("Ship it, then test it now.")

        let run = reader(home).evidence(for: [five, six])

        #expect(run.matches[five.id] == nil)
        #expect(!run.ambiguous.contains(five.id))
        #expect(run.matches[six.id]?.sessionId == Self.ompId)
    }

    /// The owner often builds one prompt from several dictations.
    @Test func onePromptHoldingTwoDictationsMatchesBoth() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let second = "Then run the whole suite once on main"
        try writeOmp(
            home,
            ompFile(Self.ompId),
            id: Self.ompId,
            startedAt: later(-60),
            prompts: [("First: \(Self.words). \(second).", later(40))]
        )
        let first = query()
        let then = query(second)

        let run = reader(home).evidence(for: [first, then])

        #expect(run.matches[first.id]?.sessionId == Self.ompId)
        #expect(run.matches[then.id]?.sessionId == Self.ompId)
        #expect(run.matches[then.id]?.sentAt == later(40))
    }

    @Test func wordsMatchAcrossWhitespaceButNotAcrossCase() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeOmp(
            home,
            ompFile(Self.ompId),
            id: Self.ompId,
            startedAt: later(-60),
            prompts: [("Please  move the\\nevidence reader into its own file", later(5))]
        )
        let rewrapped = query("Please move the evidence\n reader into its own file ")
        let lowercased = query(Self.words.lowercased())

        let run = reader(home).evidence(for: [rewrapped, lowercased])

        #expect(run.matches[rewrapped.id]?.sessionId == Self.ompId)
        #expect(run.matches[lowercased.id] == nil)
    }

    // MARK: Claude Code

    @Test func aClaudeCodeMatchCarriesItsProjectTitleAndTranscript() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeClaudeHistory(
            home,
            [
                claudeLine(
                    "Look at [Pasted text #2 +1 lines] please",
                    sentAt: later(12),
                    pasted: #"{"2":{"id":2,"type":"text","content":"\#(Self.words)"}}"#
                )
            ]
        )
        let transcript = try home.write(
            ".claude/projects/-Users-v-claude/\(Self.claudeId).jsonl",
            lines: [#"{"type":"custom-title","customTitle":"Reader split"}"#]
        )
        let wanted = query()

        let run = reader(home).evidence(for: [wanted])

        #expect(
            run.matches[wanted.id]
                == PromptEvidenceMatch(
                    agent: .claudeCode,
                    sessionId: Self.claudeId,
                    sentAt: later(12),
                    sessionFile: AgentSessionFileSystem.live.realPath(transcript),
                    workingDirectory: "/Users/v/claude",
                    title: "Reader split"
                )
        )
    }

    /// Claude Code kept only a hash of this paste; its text is never fetched,
    /// not even from the paste cache that holds it.
    @Test func aHashOnlyClaudeCodePasteStaysUnexpandedAndDoesNotMatch() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeClaudeHistory(
            home,
            [
                claudeLine(
                    "Look at [Pasted text #1 +3 lines]",
                    sentAt: later(12),
                    pasted: #"{"1":{"id":1,"type":"text","contentHash":"9f2c41"}}"#
                )
            ]
        )
        try home.write(".claude/paste-cache/9f2c41.txt", text: Self.words)
        let log = AgentFileReadLog()

        let run = reader(home, log: log).evidence(for: [query()])

        #expect(run == PromptEvidenceRun())
        #expect(!log.readPaths.contains { $0.contains("/paste-cache/") })
    }

    @Test func aClaudeCodeLineWithoutAUsableSessionIsSkipped() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try writeClaudeHistory(
            home,
            [
                claudeLine(Self.words, sentAt: later(12), sessionId: nil),
                claudeLine(Self.words, sentAt: later(13), sessionId: "not-a-session"),
            ]
        )

        let run = reader(home).evidence(for: [query()])

        #expect(run == PromptEvidenceRun())
    }

    @Test func aClaudeCodeHistoryOutsideTheAllowedRootsIsNotRead() throws {
        let home = try FakeAgentHome()
        let elsewhere = try FakeAgentHome()
        defer {
            home.remove()
            elsewhere.remove()
        }
        let outside = try elsewhere.write("history.jsonl", lines: [claudeLine(Self.words, sentAt: later(12))])
        try FileManager.default.createDirectory(
            at: home.url.appending(path: ".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.path(".claude/history.jsonl"),
            withDestinationPath: outside
        )
        let log = AgentFileReadLog()

        let run = reader(home, log: log).evidence(for: [query()])

        #expect(run == PromptEvidenceRun())
        #expect(log.readPaths.isEmpty)
    }
}
