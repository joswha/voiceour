import Foundation
import Testing

@testable import VoiceCore

@Suite("Agent session linker")
struct AgentSessionLinkerTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

    private func dictation(_ text: String) -> AgentSessionLinker.Dictation {
        AgentSessionLinker.Dictation(id: id, createdAt: t, text: text)
    }

    private func prompt(
        _ text: String,
        at offset: TimeInterval,
        session: String = "session-a",
        agent: CodingAgent = .omp
    ) -> AgentPrompt {
        AgentPrompt(
            agent: agent,
            sessionId: session,
            workingDirectory: "/Users/v/voiceour",
            sessionTitle: nil,
            sentAt: t.addingTimeInterval(offset),
            text: text
        )
    }

    private func resolve(
        _ text: String,
        _ prompts: [AgentPrompt],
        now offset: TimeInterval = 3_600
    ) -> AgentSessionLink? {
        AgentSessionLinker.resolve([dictation(text)], prompts: prompts, now: t.addingTimeInterval(offset))[id]
    }

    @Test func anEditedPromptLinksAndKeepsTheSentSpan() {
        let link = resolve(
            "Deploy the Kubernetes cluster to staging.",
            [prompt("ok so deploy the kubectl cluster to staging. then report back", at: 60)]
        )

        #expect(link?.match?.sessionId == "session-a")
        #expect(link?.match?.sentAt == t.addingTimeInterval(60))
        #expect(link?.match?.sentText == "deploy the kubectl cluster to staging.")
    }

    @Test func anIdenticalPromptLinksWithoutSentText() {
        let link = resolve("Run the tests again.", [prompt("Run the tests again.", at: 10)])

        #expect(link?.match != nil)
        #expect(link?.match?.sentText == nil)
    }

    /// The earliest qualifying prompt wins, whatever order the logs list them in.
    @Test func theEarliestQualifyingPromptWins() {
        let link = resolve(
            "Run the tests again.",
            [
                prompt("Run the tests again.", at: 60, session: "session-b"),
                prompt("Run the tests again.", at: 30, session: "session-a"),
            ]
        )

        #expect(link?.match?.sessionId == "session-a")
    }

    @Test(arguments: [
        (-4.0, true), (-6.0, false), (1_800.0, true), (1_801.0, false),
    ])
    func theSendWindowIsInclusive(offset: TimeInterval, links: Bool) {
        let link = resolve("Run the tests again.", [prompt("Run the tests again.", at: offset)], now: 7_200)

        #expect((link?.match != nil) == links)
        if !links { #expect(link == .unmatched) }
    }

    /// No match yet stays pending while a prompt could still be sent, and
    /// becomes final when the window closes.
    @Test func aDictationWithoutAMatchIsPendingUntilTheWindowCloses() {
        let prompts = [prompt("something else entirely", at: 30)]

        #expect(resolve("Run the tests again.", prompts, now: 600) == nil)
        #expect(resolve("Run the tests again.", prompts, now: 1_800) == .unmatched)
    }

    /// A short phrase aligns inside almost any prompt, so it links only to a
    /// prompt that is exactly that phrase.
    @Test func aShortDictationLinksOnlyToTheWholePrompt() {
        #expect(resolve("proceed", [prompt("proceed", at: 5)])?.match != nil)
        #expect(resolve("proceed", [prompt("please proceed with it", at: 5)]) == .unmatched)
    }

    @Test func aDictationWithoutWordsIsUnmatched() {
        #expect(resolve("…", [prompt("…", at: 5)], now: 0) == .unmatched)
    }

    @Test func resumeCommandsQuoteOnlyWhatTheShellWouldSplit() {
        func command(_ agent: CodingAgent, _ sessionId: String, _ directory: String?) -> String {
            AgentSessionMatch(
                agent: agent,
                sessionId: sessionId,
                workingDirectory: directory,
                sessionTitle: nil,
                sentAt: t,
                sentText: nil
            ).resumeCommand
        }

        #expect(
            command(.omp, "0190f6c2-5a1e", "/Users/v/My Repo") == "cd '/Users/v/My Repo' && omp --resume 0190f6c2-5a1e")
        #expect(command(.claudeCode, "abc-123", nil) == "claude --resume abc-123")
        #expect(command(.codex, "abc-123", nil) == "codex resume abc-123")
        #expect(command(.omp, "abc-123", "/tmp/it's") == "cd '/tmp/it'\\''s' && omp --resume abc-123")
    }
}
