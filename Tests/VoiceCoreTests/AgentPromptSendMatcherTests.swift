import Foundation
import Testing

@testable import VoiceCore

@Suite("Agent prompt send matcher")
struct AgentPromptSendMatcherTests {
    private let boundAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func prompt(_ text: String, at offset: TimeInterval) -> AgentSessionPrompt {
        AgentSessionPrompt(sentAt: boundAt.addingTimeInterval(offset), text: text)
    }

    private func resolve(
        _ dictation: String,
        _ prompts: [AgentSessionPrompt],
        now offset: TimeInterval = 3_600
    ) -> AgentPromptSend? {
        AgentPromptSendMatcher.resolve(
            dictation: dictation,
            boundAt: boundAt,
            prompts: prompts,
            now: boundAt.addingTimeInterval(offset)
        )
    }

    private func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    // MARK: Alignment

    @Test func anIdenticalPromptIsSentWithoutText() {
        #expect(
            resolve("Run the tests again.", [prompt("Run the tests again.", at: 10)])
                == .sent(sentAt: boundAt.addingTimeInterval(10), text: nil)
        )
    }

    @Test func anEditedPromptKeepsTheSentSpan() {
        #expect(
            resolve("Deploy the cluster to staging.", [prompt("Deploy the cluster, to staging.", at: 20)])
                == .sent(sentAt: boundAt.addingTimeInterval(20), text: "Deploy the cluster, to staging.")
        )
    }

    @Test func aPromptThatWrapsTheDictationKeepsOnlyTheMatchingSpan() {
        #expect(
            resolve(
                "Deploy the Kubernetes cluster to staging.",
                [prompt("ok so deploy the kubectl cluster to staging. then report back", at: 60)]
            ) == .sent(sentAt: boundAt.addingTimeInterval(60), text: "deploy the kubectl cluster to staging.")
        )
    }

    @Test func aPromptThatScoresBelowTheMinimumIsNotSent() {
        #expect(
            resolve("Deploy the Kubernetes cluster to staging.", [prompt("the cluster is down again", at: 60)])
                == .notSent
        )
    }

    // MARK: Short dictations

    /// A short phrase aligns inside almost any prompt, so it matches only a
    /// prompt that starts or ends with exactly its words.
    @Test(
        arguments: [
            ("testing", true, "testing"),
            ("testing please", true, "testing"),
            ("now testing", true, "testing"),
            ("run the testing suite", false, nil),
        ] as [(String, Bool, String?)])
    func aShortDictationMatchesOnlyAtThePromptsEdges(promptText: String, sent: Bool, text: String?) {
        let result = resolve("Testing.", [prompt(promptText, at: 5)])

        if sent {
            #expect(result == .sent(sentAt: boundAt.addingTimeInterval(5), text: text))
        } else {
            #expect(result == .notSent)
        }
    }

    // MARK: Send window

    @Test(arguments: [(1_800.0, true), (1_801.0, false)])
    func theSendWindowIsInclusive(offset: TimeInterval, sent: Bool) {
        let result = resolve("Run the tests again.", [prompt("Run the tests again.", at: offset)], now: 7_200)
        let expected: AgentPromptSend = sent ? .sent(sentAt: boundAt.addingTimeInterval(offset), text: nil) : .notSent

        #expect(result == expected)
    }

    /// No match stays pending while a prompt could still be sent, and becomes
    /// final when the window closes.
    @Test func noMatchIsPendingUntilTheWindowCloses() {
        let prompts = [prompt("something else entirely", at: 30)]

        #expect(resolve("Run the tests again.", prompts, now: 600) == nil)
        #expect(resolve("Run the tests again.", prompts, now: 1_799) == nil)
        #expect(resolve("Run the tests again.", prompts, now: 1_800) == .notSent)
    }

    /// The earliest matching prompt wins, whatever order the log lists them in;
    /// prompts sent at the same instant keep their input order.
    @Test func theEarliestMatchingPromptWins() {
        #expect(
            resolve(
                "Run the tests again.",
                [
                    prompt("Run the tests again.", at: 60),
                    prompt("Run the tests again!", at: 30),
                    prompt("run the tests again", at: 30),
                ]
            ) == .sent(sentAt: boundAt.addingTimeInterval(30), text: "Run the tests again!")
        )
    }

    @Test func aDictationWithoutWordsIsNotSent() {
        #expect(resolve("…", [prompt("…", at: 5)], now: 0) == .notSent)
    }

    // MARK: Live timeline

    @Test func aDictationSentAsTypedResolvesSentWithoutText() {
        let boundAt = utc("2026-11-09T17:51:32.310Z")
        let sentAt = utc("2026-11-09T17:51:33.311Z")

        #expect(
            AgentPromptSendMatcher.resolve(
                dictation: "This thing.",
                boundAt: boundAt,
                prompts: [AgentSessionPrompt(sentAt: sentAt, text: "This thing.")],
                now: sentAt.addingTimeInterval(1)
            ) == .sent(sentAt: sentAt, text: nil)
        )
    }

    /// The "testing" typed later went to another session, so it is not among
    /// the bound session's prompts: the row resolves not sent once the window
    /// closes.
    @Test func aDictationItsSessionNeverSentResolvesNotSentAfterTheWindow() {
        let boundAt = utc("2026-11-09T17:50:37.540Z")

        #expect(
            AgentPromptSendMatcher.resolve(
                dictation: "Testing.",
                boundAt: boundAt,
                prompts: [],
                now: boundAt.addingTimeInterval(1_799)
            ) == nil
        )
        #expect(
            AgentPromptSendMatcher.resolve(
                dictation: "Testing.",
                boundAt: boundAt,
                prompts: [],
                now: boundAt.addingTimeInterval(AgentPromptSendMatcher.sendWindow)
            ) == .notSent
        )
    }
}
