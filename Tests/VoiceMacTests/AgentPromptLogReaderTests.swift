import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("AgentPromptLogReader")
struct AgentPromptLogReaderTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentPromptLogReaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func sorted(_ prompts: [AgentPrompt]) -> [AgentPrompt] {
        prompts.sorted { $0.sentAt < $1.sentAt }
    }

    private let ompHeader = [
        "{\"type\":\"title\",\"v\":1,\"title\":\"\u{F0339} BIND: Voice\",\"pad\":\"          \"}",
        #"{"type":"session","version":3,"id":"sid-1","cwd":"/Users/v/voiceour"}"#,
    ]

    private func ompUser(_ text: String, at timestamp: String) -> String {
        #"{"type":"message","timestamp":"\#(timestamp)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func ompSession(in home: URL) -> URL {
        home.appending(path: ".omp/agent/sessions/-Users-v-voiceour/2026-11-08T08-06-22-500Z_sid-1.jsonl")
    }

    @Test func ompSessionFilesYieldTheirUserPromptsWithTitleAndDirectory() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = ompSession(in: home)
        try write(
            ompHeader + [
                ompUser("first prompt", at: "2026-11-08T08:06:23.966Z"),
                #"{"type":"message","timestamp":"2026-11-08T08:07:00Z","message":{"role":"user","content":["#
                    + #"{"type":"text","text":"second"},{"type":"image","data":"x"},{"type":"text","text":"prompt"}]}}"#,
                #"{"type":"message","timestamp":"2026-11-08T08:07:05.000Z","#
                    + #""message":{"role":"assistant","content":"reply"}}"#,
            ],
            to: session
        )
        // A subagent transcript beside the session is not a prompt the user sent.
        try write(
            [
                #"{"type":"session","version":3,"id":"sub-1","cwd":"/tmp"}"#,
                ompUser("subagent task", at: "2026-11-08T08:06:30.000Z"),
            ],
            to: session.deletingPathExtension().appending(path: "sub.jsonl")
        )

        let prompts = sorted(AgentPromptLogReader(homeDirectory: home).prompts(sentSince: .distantPast))

        #expect(prompts.map(\.text) == ["first prompt", "second\nprompt"])
        #expect(prompts.allSatisfy { $0.agent == .omp })
        #expect(prompts.allSatisfy { $0.sessionId == "sid-1" })
        #expect(prompts.allSatisfy { $0.workingDirectory == "/Users/v/voiceour" })
        #expect(prompts.allSatisfy { $0.sessionTitle == "BIND: Voice" })
        let firstSent = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-08T08:06:23.966Z")
        #expect(prompts.first?.sentAt == firstSent)
    }

    @Test func laterReadsPickUpAppendedCompleteLinesAndReparseAShrunkFile() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = ompSession(in: home)
        try write(
            ompHeader + [
                ompUser("one", at: "2026-11-08T08:06:23.000Z"),
                ompUser("two", at: "2026-11-08T08:06:24.000Z"),
            ],
            to: session
        )
        let reader = AgentPromptLogReader(homeDirectory: home)
        #expect(reader.prompts(sentSince: .distantPast).count == 2)

        try append(ompUser("three", at: "2026-11-08T08:06:25.000Z") + "\n", to: session)
        #expect(reader.prompts(sentSince: .distantPast).count == 3)

        // A line still being written waits for its newline.
        try append(ompUser("four", at: "2026-11-08T08:06:26.000Z"), to: session)
        #expect(reader.prompts(sentSince: .distantPast).count == 3)
        try append("\n", to: session)
        #expect(sorted(reader.prompts(sentSince: .distantPast)).map(\.text) == ["one", "two", "three", "four"])

        // Rewritten in place, shorter: parsed again from the start.
        try write(ompHeader + [ompUser("only", at: "2026-11-08T08:06:27.000Z")], to: session)
        #expect(reader.prompts(sentSince: .distantPast).map(\.text) == ["only"])
    }

    /// A file last written before `since` cannot hold a prompt sent since, so
    /// it is not read at all, whatever its lines claim.
    @Test func aFileLastModifiedBeforeSinceContributesNothing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = ompSession(in: home)
        try write(ompHeader + [ompUser("late", at: "2030-01-01T00:00:00.000Z")], to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: session.path
        )

        let prompts = AgentPromptLogReader(homeDirectory: home)
            .prompts(sentSince: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(prompts.isEmpty)
    }

    @Test func claudeCodeHistoryExpandsPastedTextAndSkipsLinesWithoutASession() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            [
                #"{"display":"fix [Pasted text #1 +2 lines]","pastedContents":{"1":{"id":1,"type":"text","#
                    + #""content":"a\nb"}},"timestamp":1762588800000,"project":"/Users/v/p","sessionId":"c-1"}"#,
                #"{"display":"no session","pastedContents":{},"timestamp":1762588801000,"project":"/Users/v/p"}"#,
            ],
            to: home.appending(path: ".claude/history.jsonl")
        )

        let prompts = AgentPromptLogReader(homeDirectory: home).prompts(sentSince: .distantPast)

        #expect(
            prompts == [
                AgentPrompt(
                    agent: .claudeCode,
                    sessionId: "c-1",
                    workingDirectory: "/Users/v/p",
                    sessionTitle: nil,
                    sentAt: Date(timeIntervalSince1970: 1_762_588_800),
                    text: "fix a\nb"
                )
            ]
        )
    }

    @Test func codexHistoryTakesTheLastThreadNameAsTitle() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            [
                #"{"session_id":"x-1","ts":1762588800,"text":"hello codex"}"#,
                #"{"session_id":"x-2","ts":1762588900,"text":"untitled"}"#,
            ],
            to: home.appending(path: ".codex/history.jsonl")
        )
        try write(
            [
                #"{"id":"x-1","thread_name":"Old name","updated_at":"2026-11-08T08:00:00Z"}"#,
                #"{"id":"x-1","thread_name":"New name","updated_at":"2026-11-08T08:05:00Z"}"#,
            ],
            to: home.appending(path: ".codex/session_index.jsonl")
        )

        let prompts = sorted(AgentPromptLogReader(homeDirectory: home).prompts(sentSince: .distantPast))

        #expect(prompts.map(\.agent) == [.codex, .codex])
        #expect(prompts.map(\.text) == ["hello codex", "untitled"])
        #expect(prompts.map(\.sessionTitle) == ["New name", nil])
        #expect(prompts.map(\.workingDirectory) == [nil, nil])
        #expect(prompts.first?.sentAt == Date(timeIntervalSince1970: 1_762_588_800))
    }

    @Test func aHomeWithoutAgentLogsYieldsNothing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(AgentPromptLogReader(homeDirectory: home).prompts(sentSince: .distantPast).isEmpty)
    }
}
