import Foundation
import Testing

@testable import VoiceCore

@Suite("TypeSafe judgment")
struct TypeSafeJudgmentTests {
    private let memorySystem = MemoryTopic(
        id: "memory-system",
        name: "Memory system",
        summary: "Design of the persistent store.",
        createdAt: fixedNow
    )
    private let billing = MemoryTopic(id: "billing", name: "Billing", summary: "  ", createdAt: fixedNow)

    private static let kindCriteria: WireJSON = [
        "instruction": "Tells an assistant or agent to do something now.",
        "question": "Asks for information or an explanation.",
        "idea": "Proposes a possibility, design or approach to consider.",
        "decision": "States a choice that has been made.",
        "todo": "A reminder or task for the speaker to do later.",
        "observation": "Reports something noticed, a fact or a status.",
        "chatter": "A test phrase, filler, greeting or text with no content.",
    ]

    private static let keepQuestion: WireJSON = [
        "type": "score",
        "instructions": "How much lasting value does this dictation have for the speaker's future work?",
        "criteria": [
            "Throwaway: a test phrase, filler, or a routine command with no lasting information.",
            "Working instruction that matters only inside its current task.",
            "Holds a preference, constraint or fact that would be useful to recall later.",
            "A decision, plan or idea that should be kept.",
        ],
    ]

    private func decodedBody(_ request: JudgmentRequest) throws -> WireJSON {
        try JSONDecoder().decode(WireJSON.self, from: request.body())
    }

    private func reply(_ json: String) throws -> JudgmentReply {
        try JudgmentReply(data: Data(json.utf8))
    }

    private func topicOptionKeys(_ request: JudgmentRequest) -> [String]? {
        guard let question = request.questions.first(where: { $0.id == "topic" }) else { return nil }
        switch question.form {
        case .choice(let options): return options.map(\.key)
        case .score, .noul: return nil
        }
    }

    // MARK: Request

    @Test func anOrganizeRequestWithTwoTopicsHasTheWireShape() throws {
        let request = JudgmentRequest.organize(text: "We keep the app local only.", topics: [memorySystem, billing])

        let expected: WireJSON = [
            "model": "jev-1.14.0",
            "state": "We keep the app local only.",
            "questions": [
                "kind": [
                    "type": "choice",
                    "instructions": "What kind of utterance is this dictation?",
                    "criteria": Self.kindCriteria,
                ],
                "topic": [
                    "type": "choice",
                    "instructions": "Which topic is this dictation about?",
                    "criteria": [
                        "memory-system": "Memory system: Design of the persistent store.",
                        "billing": "Billing",
                        "none": "None of these topics fits.",
                    ],
                ],
                "keep": Self.keepQuestion,
            ],
        ]
        #expect(try decodedBody(request) == expected)
        #expect(request.questions.map(\.id) == ["kind", "topic", "keep"])
        #expect(topicOptionKeys(request) == ["memory-system", "billing", "none"])
    }

    /// An option without a rubric is still offered, as null; a noul carries no criteria at all.
    @Test func aMissingRubricIsSentAsNullAndANoulHasNoCriteria() throws {
        let request = JudgmentRequest(
            model: "jev-1.14.0",
            state: "Text.",
            questions: [
                JudgmentQuestion(
                    id: "pick",
                    instructions: "Pick one.",
                    form: .choice([JudgmentOption(key: "a", rubric: "First."), JudgmentOption(key: "b", rubric: nil)])
                ),
                JudgmentQuestion(id: "rate", instructions: "Rate it.", form: .score(["Low.", "High."])),
                JudgmentQuestion(id: "spam", instructions: "Is it spam?", form: .noul),
            ]
        )

        let expected: WireJSON = [
            "model": "jev-1.14.0",
            "state": "Text.",
            "questions": [
                "pick": ["type": "choice", "instructions": "Pick one.", "criteria": ["a": "First.", "b": .null]],
                "rate": ["type": "score", "instructions": "Rate it.", "criteria": ["Low.", "High."]],
                "spam": ["type": "noul", "instructions": "Is it spam?"],
            ],
        ]
        #expect(try decodedBody(request) == expected)
    }

    @Test func theTopicQuestionIsOmittedWithoutTopics() throws {
        let request = JudgmentRequest.organize(text: "Testing.", topics: [])

        #expect(request.questions.map(\.id) == ["kind", "keep"])
        #expect(try decodedBody(request)["questions"]?["topic"] == nil)
    }

    @Test func onlyTheFirst254TopicsAreOffered() throws {
        let topics = (0..<300).map { index in
            MemoryTopic(id: "topic-\(index)", name: "Topic \(index)", summary: "", createdAt: fixedNow)
        }

        let request = JudgmentRequest.organize(text: "Testing.", topics: topics)

        let keys = try #require(topicOptionKeys(request))
        #expect(keys.count == 255)
        #expect(Array(keys.dropLast()) == topics.prefix(254).map(\.id))
        #expect(keys.last == "none")
        guard case .object(let criteria)? = try decodedBody(request)["questions"]?["topic"]?["criteria"] else {
            Issue.record("The topic question has no criteria object")
            return
        }
        #expect(criteria.count == 255)
        #expect(criteria["topic-253"] == "Topic 253")
        #expect(criteria["topic-254"] == nil)
    }

    /// The cut counts characters, so a letter with a combining accent is never split.
    @Test func aLongTextIsCutToTheCharacterLimit() {
        let accented = "e\u{301}"
        let longText = String(repeating: accented, count: 8_000) + "tail"
        let exact = String(repeating: "a", count: 8_000)

        let cut = JudgmentRequest.organize(text: longText, topics: []).state

        #expect(cut == String(repeating: accented, count: 8_000))
        #expect(cut.count == 8_000)
        #expect(cut.unicodeScalars.count == 16_000)
        #expect(JudgmentRequest.organize(text: exact, topics: []).state == exact)
    }

    @Test func theBodyIsDeterministic() throws {
        let topics = [memorySystem, billing]
        let first = try JudgmentRequest.organize(text: "Same words.", topics: topics).body()
        let second = try JudgmentRequest.organize(text: "Same words.", topics: topics).body()

        #expect(first == second)
    }

    @Test func theBodySortsItsKeys() throws {
        let request = JudgmentRequest(
            model: "m",
            state: "s",
            questions: [JudgmentQuestion(id: "q", instructions: "i", form: .score(["x"]))]
        )

        let body = String(decoding: try request.body(), as: UTF8.self)

        #expect(
            body == #"{"model":"m","questions":{"q":{"criteria":["x"],"instructions":"i","type":"score"}},"state":"s"}"#
        )
    }

    // MARK: Reply

    @Test func aReplyWithEveryAnswerTypeDecodes() throws {
        let decoded = try reply(
            """
            {"model":"jev-1.14.0","answers":{
              "kind":{"type":"choice","choice":"decision","confidence":0.91,"alternatives":{"idea":0.05}},
              "keep":{"type":"score","score":2.5,"distribution":[0,0.1,0.3,0.6]},
              "spam":{"type":"noul","noul":0.25}
            },"usage":{"input_tokens":120}}
            """
        )

        #expect(decoded.model == "jev-1.14.0")
        #expect(decoded.choices == ["kind": JudgmentReply.Choice(choice: "decision", confidence: 0.91)])
        #expect(decoded.scores == ["keep": 2.5])
        #expect(decoded.nouls == ["spam": 0.25])
    }

    /// One answer this app cannot read costs only that answer.
    @Test func anUnreadableAnswerIsSkipped() throws {
        let decoded = try reply(
            """
            {"model":"jev-1.14.0","answers":{
              "rank":{"type":"ranking","order":["a","b"]},
              "bare":{"type":"choice","choice":"idea"},
              "odd":"not an answer",
              "keep":{"type":"score","score":1}
            }}
            """
        )

        #expect(decoded.choices.isEmpty)
        #expect(decoded.nouls.isEmpty)
        #expect(decoded.scores == ["keep": 1])
    }

    @Test(arguments: [
        #"["model","answers"]"#,
        #"{"answers":{}}"#,
        #"{"model":7,"answers":{}}"#,
        #"{"model":"jev-1.14.0"}"#,
        #"{"model":"jev-1.14.0","answers":[]}"#,
    ])
    func aMalformedReplyThrows(json: String) {
        #expect(throws: (any Error).self) {
            try reply(json)
        }
    }

    // MARK: Label

    @Test func aReplyMapsToALabel() throws {
        let decoded = try reply(
            """
            {"model":"jev-1.14.0","answers":{
              "kind":{"type":"choice","choice":"decision","confidence":0.91},
              "topic":{"type":"choice","choice":"memory-system","confidence":0.74},
              "keep":{"type":"score","score":2.5}
            }}
            """
        )

        let label = decoded.label(topics: [memorySystem, billing], now: fixedNow)

        #expect(
            label
                == EntryLabel(
                    kind: .decision,
                    kindConfidence: 0.91,
                    topicID: "memory-system",
                    topicConfidence: 0.74,
                    keep: 2.5,
                    model: "jev-1.14.0",
                    labeledAt: fixedNow
                )
        )
    }

    @Test(arguments: ["none", "retired-topic"])
    func aTopicAnswerThatNamesNoOfferedTopicFilesNothing(choice: String) throws {
        let decoded = try reply(
            """
            {"model":"jev-1.14.0","answers":{
              "kind":{"type":"choice","choice":"idea","confidence":0.8},
              "topic":{"type":"choice","choice":"\(choice)","confidence":0.97},
              "keep":{"type":"score","score":3}
            }}
            """
        )

        let label = decoded.label(topics: [memorySystem, billing], now: fixedNow)

        #expect(
            label == EntryLabel(kind: .idea, kindConfidence: 0.8, keep: 3, model: "jev-1.14.0", labeledAt: fixedNow)
        )
    }

    /// A kind this app does not know leaves no kind and no confidence for it; the other answers still count.
    @Test func anUnknownKindGivesNoKind() throws {
        let decoded = try reply(
            """
            {"model":"jev-2.0.0","answers":{
              "kind":{"type":"choice","choice":"rant","confidence":0.99},
              "topic":{"type":"choice","choice":"billing","confidence":0.65},
              "keep":{"type":"score","score":0}
            }}
            """
        )

        let label = decoded.label(topics: [memorySystem, billing], now: fixedNow)

        #expect(
            label
                == EntryLabel(
                    topicID: "billing", topicConfidence: 0.65, keep: 0, model: "jev-2.0.0", labeledAt: fixedNow)
        )
    }
}

/// A JSON value, so a test compares a request body's structure rather than its bytes.
private enum WireJSON: Decodable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    case null
    case string(String)
    case number(Double)
    case array([WireJSON])
    case object([String: WireJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let array = try? container.decode([WireJSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: WireJSON].self))
        }
    }

    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(arrayLiteral elements: WireJSON...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, WireJSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    subscript(key: String) -> WireJSON? {
        switch self {
        case .object(let object): object[key]
        case .null, .string, .number, .array: nil
        }
    }
}
