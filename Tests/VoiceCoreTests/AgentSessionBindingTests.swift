import Foundation
import Testing

@testable import VoiceCore

@Suite("Agent session binding")
struct AgentSessionBindingTests {
    private let boundAt = Date(timeIntervalSinceReferenceDate: 100)
    private let sessionId = "01a1c16f-1d2e-7a3b-9c4d-5e6f7a8b9c0d"

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Wire form

    @Test(arguments: [
        AgentPromptSend.sent(sentAt: Date(timeIntervalSinceReferenceDate: 160), text: "deploy the kubectl cluster"),
        AgentPromptSend.sent(sentAt: Date(timeIntervalSinceReferenceDate: 160), text: nil),
        AgentPromptSend.notSent,
    ])
    func eachSendStateRoundTrips(send: AgentPromptSend) throws {
        #expect(try roundTrip(send) == send)
    }

    @Test func sendStatesUseTheirWireNames() throws {
        func status(_ send: AgentPromptSend) throws -> String? {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(send)) as? [String: Any]
            return object?["status"] as? String
        }

        #expect(try status(.sent(sentAt: boundAt, text: nil)) == "sent")
        #expect(try status(.notSent) == "notSent")
    }

    @Test func aFullBindingRoundTrips() throws {
        let binding = AgentSessionBinding(
            agent: .claudeCode,
            sessionId: sessionId,
            sessionFile: "/Users/v/.claude/projects/-Users-v-voiceour/\(sessionId).jsonl",
            workingDirectory: "/Users/v/voiceour",
            sessionTitle: "BIND: Voice",
            boundAt: boundAt,
            promptLogOffset: 4_096,
            resumable: true,
            send: .sent(sentAt: boundAt.addingTimeInterval(1), text: "this thing")
        )

        #expect(try roundTrip(binding) == binding)
    }

    /// A send state History cannot read keeps the binding: the send check runs
    /// again.
    @Test func aBindingWithAnUnknownSendStatusKeepsEverythingButTheSend() throws {
        let binding = try decode(
            AgentSessionBinding.self,
            """
            {
              "agent": "omp",
              "sessionId": "\(sessionId)",
              "workingDirectory": "/Users/v/voiceour",
              "sessionTitle": "BIND: Voice",
              "boundAt": 100,
              "promptLogOffset": 12,
              "resumable": true,
              "send": {"status": "bogus"}
            }
            """
        )

        #expect(
            binding
                == AgentSessionBinding(
                    agent: .omp,
                    sessionId: sessionId,
                    workingDirectory: "/Users/v/voiceour",
                    sessionTitle: "BIND: Voice",
                    boundAt: boundAt,
                    promptLogOffset: 12,
                    resumable: true
                )
        )
    }

    /// A binding History cannot read must not cost the row.
    @Test func aRowWithAMalformedBindingKeepsItsText() throws {
        let session = try decode(
            RecentSession.self,
            """
            {
              "id": "00000000-0000-0000-0000-000000000102",
              "createdAt": 42,
              "text": "written by a later version",
              "agentSession": {"agent": "codex", "sessionId": "abc", "boundAt": 42}
            }
            """
        )

        #expect(session.text == "written by a later version")
        #expect(session.agentSession == nil)
    }

    @Test func aRowWithOnlyTheRetiredAgentLinkDecodesUnbound() throws {
        let session = try decode(
            RecentSession.self,
            """
            {
              "id": "00000000-0000-0000-0000-000000000103",
              "createdAt": 42,
              "text": "linked by text matching",
              "agentLink": {
                "status": "linked",
                "agent": "omp",
                "sessionId": "\(sessionId)",
                "sentAt": 43
              }
            }
            """
        )

        #expect(session.text == "linked by text matching")
        #expect(session.agentSession == nil)
    }

    // MARK: Link miss

    private func row(unlinked: AgentLinkMiss?, agentSession: AgentSessionBinding? = nil) -> RecentSession {
        RecentSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 42),
            text: "pasted into tern",
            agentSession: agentSession,
            unlinked: unlinked
        )
    }

    private func jsonObject(_ session: RecentSession) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
        return try #require(object as? [String: Any])
    }

    @Test(arguments: AgentLinkMiss.allCases)
    func eachMissRoundTripsOnARowUnderItsRawValue(miss: AgentLinkMiss) throws {
        let session = row(unlinked: miss)

        #expect(try jsonObject(session)["unlinked"] as? String == miss.rawValue)
        #expect(try roundTrip(session) == session)
    }

    @Test func missesUseSnakeCaseWireNames() throws {
        #expect(try jsonObject(row(unlinked: .ternTimeout))["unlinked"] as? String == "tern_timeout")
        #expect(try jsonObject(row(unlinked: .sessionUnconfirmed))["unlinked"] as? String == "session_unconfirmed")
    }

    /// Rows written before misses existed load unchanged, and a row with no
    /// miss writes no key.
    @Test func aRowWithoutAMissDecodesAsUnknownAndWritesNoKey() throws {
        let legacy = try decode(
            RecentSession.self,
            #"{"id": "00000000-0000-0000-0000-000000000104", "createdAt": 42, "text": "pasted into tern"}"#
        )

        #expect(legacy == row(unlinked: nil))
        #expect(try jsonObject(legacy)["unlinked"] == nil)
    }

    /// A miss this build cannot read must not cost the row.
    @Test(arguments: [#""pane_closed""#, "7", #"{"reason": "busy"}"#])
    func anUnknownOrMalformedMissReadsAsUnknownAndKeepsTheRow(value: String) throws {
        let session = try decode(
            RecentSession.self,
            """
            {"id": "00000000-0000-0000-0000-000000000104", "createdAt": 42, "text": "pasted into tern", \
            "unlinked": \(value)}
            """
        )

        #expect(session == row(unlinked: nil))
    }

    @Test func aRowStoredWithABindingAndAMissReadsAsBound() throws {
        let session = try decode(
            RecentSession.self,
            """
            {
              "id": "00000000-0000-0000-0000-000000000104",
              "createdAt": 42,
              "text": "pasted into tern",
              "agentSession": {"agent": "omp", "sessionId": "\(sessionId)", "boundAt": 100},
              "unlinked": "focus_moved"
            }
            """
        )

        #expect(session.agentSession?.sessionId == sessionId)
        #expect(session.unlinked == nil)
    }

    @Test func aRowNeverHoldsBothABindingAndAMiss() {
        let binding = AgentSessionBinding(agent: .omp, sessionId: sessionId, boundAt: boundAt)

        var session = row(unlinked: .busy)
        session.agentSession = binding
        #expect(session.unlinked == nil)

        session.unlinked = .focusMoved
        #expect(session.unlinked == nil)
        #expect(session.agentSession == binding)

        #expect(row(unlinked: .codex, agentSession: binding).unlinked == nil)

        session.agentSession = nil
        session.unlinked = .codex
        #expect(session.unlinked == .codex)
    }

    @Test func theJournalReadsARowsMiss() {
        #expect(JournalEntry(row(unlinked: .remote)).unlinked == .remote)
        #expect(MemoryEntry(row(unlinked: .remote)).unlinked == .remote)
    }

    @Test func aBlankTitleDecodesAsNoTitle() throws {
        let binding = try decode(
            AgentSessionBinding.self,
            #"{"agent": "omp", "sessionId": "\#(sessionId)", "sessionTitle": "  \n ", "boundAt": 100}"#
        )

        #expect(binding.sessionTitle == nil)
        #expect(binding.resumable == false)
        #expect(binding.send == nil)
    }

    // MARK: Presentation

    @Test func theDisplayTitleFallsBackFromTitleToFolderToTheStartOfTheId() {
        func title(_ sessionTitle: String?, _ directory: String?, _ agent: CodingAgent = .omp) -> String {
            AgentSessionBinding(
                agent: agent,
                sessionId: sessionId,
                workingDirectory: directory,
                sessionTitle: sessionTitle,
                boundAt: boundAt
            ).displayTitle
        }

        #expect(title("BIND: Voice", "/Users/v/voiceour") == "omp · BIND: Voice")
        #expect(title(nil, "/Users/v/voiceour") == "omp · voiceour")
        #expect(title(" ", "/Users/v/voiceour") == "omp · voiceour")
        #expect(title(nil, nil, .claudeCode) == "Claude Code · 01a1c16f")
    }

    @Test func theLocationLineOmitsTheFolderWhenTheTitleFellBackToIt() {
        func location(_ sessionTitle: String?, _ directory: String?) -> String {
            AgentSessionBinding(
                agent: .omp,
                sessionId: sessionId,
                workingDirectory: directory,
                sessionTitle: sessionTitle,
                boundAt: boundAt
            ).locationLine
        }

        #expect(location("BIND: Voice", "/Users/v/voiceour") == "voiceour · \(sessionId)")
        #expect(location(nil, "/Users/v/voiceour") == sessionId)
        #expect(location("BIND: Voice", nil) == sessionId)
    }

    @Test func resumeCommandsQuoteOnlyWhatTheShellWouldSplit() {
        func command(_ agent: CodingAgent, _ sessionId: String, _ directory: String?) -> String {
            AgentSessionBinding(
                agent: agent,
                sessionId: sessionId,
                workingDirectory: directory,
                boundAt: boundAt
            ).resumeCommand
        }

        #expect(command(.omp, "0190f6c2-5a1e", nil) == "omp --resume 0190f6c2-5a1e")
        #expect(
            command(.omp, "0190f6c2-5a1e", "/Users/v/My Repo") == "cd '/Users/v/My Repo' && omp --resume 0190f6c2-5a1e")
        #expect(command(.omp, "abc-123", "/tmp/it's") == "cd '/tmp/it'\\''s' && omp --resume abc-123")
        #expect(command(.claudeCode, "abc-123", nil) == "claude --resume abc-123")
        #expect(
            command(.claudeCode, "abc-123", "/Users/v/voiceour") == "cd /Users/v/voiceour && claude --resume abc-123")
        #expect(command(.claudeCode, "abc 123", nil) == "claude --resume 'abc 123'")
    }

    @Test func sentTextAndNotSentReflectTheSend() {
        var binding = AgentSessionBinding(agent: .omp, sessionId: sessionId, boundAt: boundAt)
        #expect(binding.sentText == nil)
        #expect(binding.isNotSent == false)

        binding.send = .sent(sentAt: boundAt, text: "this thing")
        #expect(binding.sentText == "this thing")
        #expect(binding.isNotSent == false)

        binding.send = .notSent
        #expect(binding.sentText == nil)
        #expect(binding.isNotSent)
    }

    // MARK: Setting

    @Test func theBindingSettingDecodesAndDefaultsOff() throws {
        #expect(try decode(Settings.self, #"{"agent_session_binding_enabled": true}"#).agentSessionBindingEnabled)
        #expect(try decode(Settings.self, "{}").agentSessionBindingEnabled == false)
        #expect(Settings().agentSessionBindingEnabled == false)
    }

    /// The retired linking setting never turns binding on.
    @Test func theRetiredLinkingSettingIsIgnored() throws {
        let settings = try decode(Settings.self, #"{"agent_session_linking_enabled": true}"#)

        #expect(settings.agentSessionBindingEnabled == false)
    }
}
