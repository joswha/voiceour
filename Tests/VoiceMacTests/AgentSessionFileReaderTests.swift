import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("AgentSessionFileReader")
struct AgentSessionFileReaderTests {
    private let boundAt = Date(timeIntervalSince1970: 1_794_246_692.31)

    private func ompBinding(_ home: FakeAgentHome, file: String, offset: Int?) -> AgentSessionBinding {
        AgentSessionBinding(
            agent: .omp,
            sessionId: AgentFixtures.nextSessionId,
            sessionFile: home.path(file),
            boundAt: boundAt,
            promptLogOffset: offset
        )
    }

    private func claudeBinding(offset: Int?) -> AgentSessionBinding {
        AgentSessionBinding(
            agent: .claudeCode,
            sessionId: AgentFixtures.claudeSessionId,
            boundAt: boundAt,
            promptLogOffset: offset
        )
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    // MARK: omp

    /// The live case: session 01a1c16f holds a typed "testing" before the
    /// paste and "This thing." after it.
    @Test func ompPromptsKeepTheirExactTimestamps() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId)
                + [AgentFixtures.ompUser("testing", at: "2026-11-09T17:51:29.712Z")]
        )
        let offset = try home.size(file)
        try home.append(file, text: AgentFixtures.ompUser("This thing.", at: "2026-11-09T17:51:33.311Z") + "\n")
        let reader = AgentSessionFileReader(homeDirectory: home.url)

        // A binding made before "testing" was sent sees both prompts.
        var earlier = ompBinding(home, file: file, offset: 0)
        earlier.boundAt = Date(timeIntervalSince1970: 1_794_246_689)
        let all = try #require(reader.read(earlier))
        let afterPaste = try #require(reader.read(ompBinding(home, file: file, offset: offset)))

        #expect(all.prompts.map(\.text) == ["testing", "This thing."])
        #expect(all.prompts.map { milliseconds($0.sentAt) } == [1_794_246_689_712, 1_794_246_693_311])
        // "testing" lies before the offset, within the lookback, but was sent
        // 2.6 s before the binding: an earlier prompt, not this dictation.
        #expect(afterPaste.prompts.map(\.text) == ["This thing."])
        #expect(afterPaste.sessionFileExists)
        // omp's title is still empty: no title yet.
        #expect(afterPaste.title == nil)
    }

    @Test func ompPromptsAreUserMessagesAfterTheOffsetWithTextPartsJoined() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "\u{F0339} BIND: Voice")
                + [AgentFixtures.ompUser("before", at: "2026-11-09T17:51:20.000Z")]
        )
        let offset = try home.size(file)
        try home.append(
            file,
            text: [
                AgentFixtures.ompUser("first", at: "2026-11-09T17:51:40.000Z"),
                #"{"type":"message","timestamp":"2026-11-09T17:51:50Z","message":{"role":"user","content":["#
                    + #"{"type":"text","text":"second"},{"type":"image","data":"x"},"#
                    + #"{"type":"text","text":"prompt"}]}}"#,
                #"{"type":"message","timestamp":"2026-11-09T17:51:55.000Z","#
                    + #""message":{"role":"assistant","content":"reply"}}"#,
                // Still being written: no newline yet.
                AgentFixtures.ompUser("partial", at: "2026-11-09T17:52:00.000Z"),
            ].joined(separator: "\n")
        )

        let snapshot = try #require(
            AgentSessionFileReader(homeDirectory: home.url).read(ompBinding(home, file: file, offset: offset))
        )

        #expect(snapshot.title == "BIND: Voice")
        #expect(snapshot.prompts.map(\.text) == ["first", "second\nprompt"])
    }

    @Test func aMovedOmpSessionIsFoundByIdAtTopLevel() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let moved =
            ".omp/agent/sessions/-Users-v-elsewhere/2026-11-09T17-51-31-004Z_\(AgentFixtures.nextSessionId).jsonl"
        try home.write(
            moved,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "Moved")
                + [AgentFixtures.ompUser("after move", at: "2026-11-09T17:51:40.000Z")]
        )

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: AgentFixtures.nextSessionFile, offset: 0))

        #expect(snapshot?.title == "Moved")
        #expect(snapshot?.sessionFileExists == true)
        #expect(snapshot?.prompts.map(\.text) == ["after move"])
    }

    @Test func anUnwrittenOmpSessionHasNoFileAndNoPrompts() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        // A subagent transcript that happens to carry the id is not the session.
        try home.write(
            ".omp/agent/sessions/-x/2026-11-09T17-50-00-000Z_parent/x_\(AgentFixtures.nextSessionId).jsonl",
            lines: [AgentFixtures.ompUser("subagent", at: "2026-11-09T17:51:40.000Z")]
        )

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: AgentFixtures.nextSessionFile, offset: 0))

        #expect(snapshot == AgentSessionSnapshot(title: nil, sessionFileExists: false, prompts: []))
    }

    @Test func aTitleOfOnlyAGlyphIsNoTitle() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(file, lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "\u{F0339}  "))

        let snapshot = AgentSessionFileReader(homeDirectory: home.url).read(ompBinding(home, file: file, offset: 0))

        #expect(snapshot?.title == nil)
        #expect(snapshot?.sessionFileExists == true)
    }

    @Test func anOffsetBeyondTheEndRescansOnlyRecentPrompts() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId) + [
                AgentFixtures.ompUser("long before", at: "2026-11-09T17:51:20.000Z"),
                AgentFixtures.ompUser("just before", at: "2026-11-09T17:51:31.500Z"),
                AgentFixtures.ompUser("after", at: "2026-11-09T17:51:33.311Z"),
            ]
        )

        let offset = try home.size(file) + 500
        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: offset))

        // boundAt is 17:51:32.31; one second before it is 17:51:31.31.
        #expect(snapshot?.prompts.map(\.text) == ["just before", "after"])
    }

    @Test func anOffsetInsideALineRescansOnlyRecentPrompts() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        let head = AgentFixtures.ompHead(id: AgentFixtures.nextSessionId)
        try home.write(file, lines: head + [AgentFixtures.ompUser("long before", at: "2026-11-09T17:51:20.000Z")])
        let lineStart = try home.size(file)
        try home.append(file, text: AgentFixtures.ompUser("after", at: "2026-11-09T17:51:33.311Z") + "\n")

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: lineStart + 10))

        #expect(snapshot?.prompts.map(\.text) == ["after"])
    }

    /// The offset is measured when binding finishes, a moment after the
    /// paste; a prompt sent in between lies before it.
    @Test func anOmpPromptSentBetweenThePasteAndTheOffsetIsFound() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId) + [
                AgentFixtures.ompUser("long before", at: "2026-11-09T17:51:20.000Z"),
                AgentFixtures.ompUser("in the gap", at: "2026-11-09T17:51:32.900Z"),
            ]
        )
        let offset = try home.size(file)
        try home.append(file, text: AgentFixtures.ompUser("after", at: "2026-11-09T17:51:40.000Z") + "\n")

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: offset))

        #expect(snapshot?.prompts.map(\.text) == ["in the gap", "after"])
    }

    @Test func aPromptBeforeTheOffsetSentOverASecondBeforeTheBindingIsIgnored() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        // boundAt is 17:51:32.31; one second before it is 17:51:31.31.
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId) + [
                AgentFixtures.ompUser("too early", at: "2026-11-09T17:51:31.000Z"),
                AgentFixtures.ompUser("just in time", at: "2026-11-09T17:51:31.500Z"),
            ]
        )

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: try home.size(file)))

        #expect(snapshot?.prompts.map(\.text) == ["just in time"])
    }

    @Test func aRescanOfALargeFileFindsARecentPromptAtItsEnd() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        let reply =
            #"{"type":"message","timestamp":"2026-11-09T17:51:20.000Z","message":{"role":"assistant","content":""#
            + String(repeating: "x", count: 1_000) + #""}}"#
        // Over 5 MiB of replies, past the old 4 MiB read limit.
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId)
                + Array(repeating: reply, count: 5_300)
                + [AgentFixtures.ompUser("recent", at: "2026-11-09T17:51:33.311Z")]
        )
        let size = try home.size(file)
        #expect(size > 5 << 20)

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: size + 500))

        #expect(snapshot?.prompts.map(\.text) == ["recent"])
    }

    @Test func theCutLineAtTheStartOfTheLookbackIsNeverParsed() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        // The lookback starts exactly at a user message embedded after other
        // bytes on the same line: its tail alone would parse as a prompt.
        let embedded = AgentFixtures.ompUser("cut", at: "2026-11-09T17:51:32.000Z")
        let gap = String(repeating: "y", count: AgentSessionFileReader.promptLookback - embedded.utf8.count - 2)
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId) + ["xxxx" + embedded, gap]
        )
        let offset = try home.size(file)
        try home.append(file, text: AgentFixtures.ompUser("after", at: "2026-11-09T17:51:40.000Z") + "\n")

        let snapshot = AgentSessionFileReader(homeDirectory: home.url)
            .read(ompBinding(home, file: file, offset: offset))

        #expect(snapshot?.prompts.map(\.text) == ["after"])
    }

    @Test func anOmpSessionFileOutsideTheAllowedRootsIsNotRead() throws {
        let home = try FakeAgentHome()
        let elsewhere = try FakeAgentHome()
        defer {
            home.remove()
            elsewhere.remove()
        }
        let outside = try elsewhere.write(
            "2026-11-09T17-51-31-004Z_\(AgentFixtures.nextSessionId).jsonl",
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "Secret")
        )
        // A link inside the root that leads outside it is outside too.
        let link = home.path(AgentFixtures.nextSessionFile)
        try FileManager.default.createDirectory(
            atPath: (link as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let reader = AgentSessionFileReader(homeDirectory: home.url)
        var binding = ompBinding(home, file: AgentFixtures.nextSessionFile, offset: 0)

        #expect(reader.read(binding) == nil)
        binding.sessionFile = outside
        #expect(reader.read(binding) == nil)
    }

    @Test func aBindingWhoseIdIsNoUUIDReadsNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var binding = ompBinding(home, file: AgentFixtures.nextSessionFile, offset: 0)
        binding.sessionId = "../../etc"
        binding.sessionFile = nil

        #expect(AgentSessionFileReader(homeDirectory: home.url).read(binding) == nil)
    }

    // MARK: Claude Code

    @Test func claudeCodePromptsAreTheBoundSessionsHistoryLinesAfterTheOffset() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let history = ".claude/history.jsonl"
        let id = AgentFixtures.claudeSessionId
        try home.write(
            history,
            lines: [#"{"display":"before","pastedContents":{},"timestamp":1794246680000,"sessionId":"\#(id)"}"#]
        )
        let offset = try home.size(history)
        try home.append(
            history,
            text: [
                #"{"display":"fix [Pasted text #1 +2 lines] now","pastedContents":{"1":{"id":1,"type":"text","#
                    + #""content":"a\nb"},"2":{"id":2,"type":"image"}},"timestamp":1794246693311,"#
                    + #""project":"/Users/v/p","sessionId":"\#(id)"}"#,
                #"{"display":"other session","pastedContents":{},"timestamp":1794246694000,"#
                    + #""sessionId":"\#(AgentFixtures.claudeJobSessionId)"}"#,
                #"{"display":"no session","pastedContents":{},"timestamp":1794246695000}"#,
                #"{"display":"[Pasted text #3] kept","pastedContents":{},"timestamp":1794246696000,"#
                    + #""sessionId":"\#(id)"}"#,
            ].joined(separator: "\n") + "\n"
        )
        try home.write(
            ".claude/projects/-Users-v-p/\(id).jsonl",
            lines: [
                #"{"type":"ai-title","aiTitle":"Old"}"#,
                #"{"type":"custom-title","customTitle":"Login fix"}"#,
            ]
        )

        let snapshot = try #require(AgentSessionFileReader(homeDirectory: home.url).read(claudeBinding(offset: offset)))

        #expect(snapshot.title == "Login fix")
        #expect(snapshot.sessionFileExists)
        #expect(snapshot.prompts.map(\.text) == ["fix a\nb now", "[Pasted text #3] kept"])
        #expect(snapshot.prompts.first.map { milliseconds($0.sentAt) } == 1_794_246_693_311)
    }

    @Test func aClaudeCodeHistoryThatShrankRescansOnlyRecentPrompts() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let id = AgentFixtures.claudeSessionId
        try home.write(
            ".claude/history.jsonl",
            lines: [
                #"{"display":"old","timestamp":1794246600000,"sessionId":"\#(id)"}"#,
                #"{"display":"new","timestamp":1794246693311,"sessionId":"\#(id)"}"#,
            ]
        )

        let snapshot = AgentSessionFileReader(homeDirectory: home.url).read(claudeBinding(offset: 1_000_000))

        #expect(snapshot?.prompts.map(\.text) == ["new"])
        #expect(snapshot?.sessionFileExists == false)
        #expect(snapshot?.title == nil)
    }

    @Test func aClaudeCodeTitleIsTheRegistryNameUnlessDerived() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let id = AgentFixtures.claudeSessionId
        try home.write(".claude/projects/-Users-v-p/\(id).jsonl", lines: [#"{"type":"ai-title","aiTitle":"Auto"}"#])
        // Neither another session's record nor a file not named by a pid
        // supplies the name.
        try home.write(
            ".claude/sessions/1000.json",
            text: AgentFixtures.claudeRecord(
                pid: 1000,
                sessionId: AgentFixtures.claudeJobSessionId,
                extra: #","name":"Other","nameSource":"user""#
            )
        )
        try home.write(
            ".claude/sessions/notes.json",
            text: AgentFixtures.claudeRecord(pid: 1, sessionId: id, extra: #","name":"Stray","nameSource":"user""#)
        )
        let record = ".claude/sessions/61208.json"
        func writeRecord(name: String, source: String) throws {
            try home.write(
                record,
                text: AgentFixtures.claudeRecord(
                    pid: 61208,
                    sessionId: id,
                    extra: #","name":"\#(name)","nameSource":"\#(source)""#
                )
            )
        }
        let reader = AgentSessionFileReader(homeDirectory: home.url)

        try writeRecord(name: "Voice binding", source: "user")
        #expect(reader.read(claudeBinding(offset: 0))?.title == "Voice binding")

        try writeRecord(name: "voice-binding", source: "derived")
        #expect(reader.read(claudeBinding(offset: 0))?.title == "Auto")
    }

    @Test func aClaudeCodeHistoryOutsideTheAllowedRootsIsNotRead() throws {
        let home = try FakeAgentHome()
        let elsewhere = try FakeAgentHome()
        defer {
            home.remove()
            elsewhere.remove()
        }
        let outside = try elsewhere.write(
            "history.jsonl",
            lines: [#"{"display":"x","timestamp":1794246693311,"sessionId":"\#(AgentFixtures.claudeSessionId)"}"#]
        )
        try FileManager.default.createDirectory(
            at: home.url.appending(path: ".claude"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.path(".claude/history.jsonl"),
            withDestinationPath: outside
        )

        #expect(AgentSessionFileReader(homeDirectory: home.url).read(claudeBinding(offset: 0)) == nil)
    }
}
