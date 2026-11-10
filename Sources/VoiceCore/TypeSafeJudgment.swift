import Foundation

/// One option of a choice question. The rubric tells the model what the
/// option means; an option without one is sent as JSON null.
public struct JudgmentOption: Equatable, Sendable {
    public var key: String
    public var rubric: String?

    public init(key: String, rubric: String?) {
        self.key = key
        self.rubric = rubric
    }
}

/// One question the sorting model answers about the request's text.
public struct JudgmentQuestion: Equatable, Sendable {
    /// What shape the answer takes.
    public enum Form: Equatable, Sendable {
        /// Pick one option; the reply carries the option key and a confidence.
        case choice([JudgmentOption])
        /// Place the text on a scale; the levels run lowest first.
        case score([String])
        /// A yes-or-no judgment answered as a number; it carries no criteria.
        case noul
    }

    public var id: String
    public var instructions: String
    public var form: Form

    public init(id: String, instructions: String, form: Form) {
        self.id = id
        self.instructions = instructions
        self.form = form
    }
}

/// One TypeSafe System One request: the text to judge and the questions to
/// answer about it. The request asks for labels only, so the model never
/// writes text that memory keeps.
public struct JudgmentRequest: Equatable, Sendable {
    public var model: String
    public var state: String
    public var questions: [JudgmentQuestion]

    public init(model: String, state: String, questions: [JudgmentQuestion]) {
        self.model = model
        self.state = state
        self.questions = questions
    }

    /// The request bytes: {"model":…,"state":…,"questions":{id:{"type":"choice"|"score"|"noul","instructions":…,"criteria":…}}}. Deterministic.
    ///
    /// Keys are sorted so the same request always produces the same bytes.
    /// When two questions share an id, or two options of one choice share a
    /// key, the first one wins.
    public func body() throws -> Data {
        var wireQuestions: [String: WireQuestion] = [:]
        for question in questions where wireQuestions[question.id] == nil {
            wireQuestions[question.id] = WireQuestion(question: question)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(WireRequest(model: model, state: state, questions: wireQuestions))
    }

    /// The three questions that label one entry: "kind" (choice over every UtteranceKind raw value), "topic" (choice over topic ids plus "none";
    /// omitted when `topics` is empty), "keep" (score, four levels).
    ///
    /// Only the first `OrganizerPolicy.maximumTopics` topics are offered, and
    /// the text is cut to `OrganizerPolicy.maximumTextCharacters` characters.
    public static func organize(text: String, topics: [MemoryTopic]) -> JudgmentRequest {
        var questions = [
            JudgmentQuestion(
                id: OrganizerQuestionID.kind,
                instructions: "What kind of utterance is this dictation?",
                form: .choice(UtteranceKind.allCases.map { JudgmentOption(key: $0.rawValue, rubric: rubric(for: $0)) })
            )
        ]
        if !topics.isEmpty {
            let offered = topics.prefix(OrganizerPolicy.maximumTopics).map { topic in
                JudgmentOption(key: topic.id, rubric: rubric(for: topic))
            }
            questions.append(
                JudgmentQuestion(
                    id: OrganizerQuestionID.topic,
                    instructions: "Which topic is this dictation about?",
                    form: .choice(
                        offered + [
                            JudgmentOption(key: OrganizerPolicy.noneOption, rubric: "None of these topics fits.")
                        ])
                )
            )
        }
        questions.append(
            JudgmentQuestion(
                id: OrganizerQuestionID.keep,
                instructions: "How much lasting value does this dictation have for the speaker's future work?",
                form: .score([
                    "Throwaway: a test phrase, filler, or a routine command with no lasting information.",
                    "Working instruction that matters only inside its current task.",
                    "Holds a preference, constraint or fact that would be useful to recall later.",
                    "A decision, plan or idea that should be kept.",
                ])
            )
        )
        return JudgmentRequest(
            model: OrganizerPolicy.model,
            state: String(text.prefix(OrganizerPolicy.maximumTextCharacters)),
            questions: questions
        )
    }

    private static func rubric(for kind: UtteranceKind) -> String {
        switch kind {
        case .instruction: "Tells an assistant or agent to do something now."
        case .question: "Asks for information or an explanation."
        case .idea: "Proposes a possibility, design or approach to consider."
        case .decision: "States a choice that has been made."
        case .todo: "A reminder or task for the speaker to do later."
        case .observation: "Reports something noticed, a fact or a status."
        case .chatter: "A test phrase, filler, greeting or text with no content."
        }
    }

    /// The topic's summary is the rubric the user wrote for it; a topic
    /// without one is offered by name alone.
    private static func rubric(for topic: MemoryTopic) -> String {
        let summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? topic.name : "\(topic.name): \(summary)"
    }
}

/// The answers of one TypeSafe System One reply, keyed by question id.
public struct JudgmentReply: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public var choice: String
        public var confidence: Double
    }

    public var model: String
    public var choices: [String: Choice]
    public var scores: [String: Double]
    public var nouls: [String: Double]

    /// Reads a reply of the form {"model":…,"answers":{id:{"type":"choice","choice":…,"confidence":…}|{"type":"score","score":…}|{"type":"noul","noul":…}}}.
    ///
    /// Throws when the body is not an object or lacks a string `model` or an
    /// object `answers`. An answer whose type is unknown, or whose fields are
    /// missing or mistyped, is skipped so one odd answer costs only itself.
    public init(data: Data) throws {
        let wire = try JSONDecoder().decode(WireReply.self, from: data)
        model = wire.model
        var choices: [String: Choice] = [:]
        var scores: [String: Double] = [:]
        var nouls: [String: Double] = [:]
        for (id, answer) in wire.answers {
            switch answer {
            case .choice(let choice): choices[id] = choice
            case .score(let score): scores[id] = score
            case .noul(let noul): nouls[id] = noul
            case .skipped: break
            }
        }
        self.choices = choices
        self.scores = scores
        self.nouls = nouls
    }

    /// Maps the "kind", "topic" and "keep" answers. A topic answer of "none", or an id not in `topics`, gives topicID nil.
    ///
    /// A kind the app does not know gives no kind and no kind confidence, so a
    /// confidence never describes a kind that is absent.
    public func label(topics: [MemoryTopic], now: Date) -> EntryLabel {
        var label = EntryLabel(keep: scores[OrganizerQuestionID.keep], model: model, labeledAt: now)
        if let answer = choices[OrganizerQuestionID.kind], let kind = UtteranceKind(rawValue: answer.choice) {
            label.kind = kind
            label.kindConfidence = answer.confidence
        }
        if let answer = choices[OrganizerQuestionID.topic],
            answer.choice != OrganizerPolicy.noneOption,
            topics.contains(where: { $0.id == answer.choice })
        {
            label.topicID = answer.choice
            label.topicConfidence = answer.confidence
        }
        return label
    }
}

/// The question ids the organizer asks and reads back.
private enum OrganizerQuestionID {
    static let kind = "kind"
    static let topic = "topic"
    static let keep = "keep"
}

// MARK: Wire form

private struct WireRequest: Encodable {
    let model: String
    let state: String
    let questions: [String: WireQuestion]
}

private struct WireQuestion: Encodable {
    let question: JudgmentQuestion

    private enum CodingKeys: String, CodingKey {
        case type
        case instructions
        case criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question.instructions, forKey: .instructions)
        switch question.form {
        case .choice(let options):
            try container.encode("choice", forKey: .type)
            var criteria = container.nestedContainer(keyedBy: OptionKey.self, forKey: .criteria)
            var written: Set<String> = []
            for option in options {
                guard written.insert(option.key).inserted else { continue }
                let key = OptionKey(stringValue: option.key)
                if let rubric = option.rubric {
                    try criteria.encode(rubric, forKey: key)
                } else {
                    try criteria.encodeNil(forKey: key)
                }
            }
        case .score(let levels):
            try container.encode("score", forKey: .type)
            try container.encode(levels, forKey: .criteria)
        case .noul:
            try container.encode("noul", forKey: .type)
        }
    }
}

/// A coding key for an option key the caller chose.
private struct OptionKey: CodingKey {
    let stringValue: String

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int? { nil }

    init?(intValue: Int) {
        return nil
    }
}

private struct WireReply: Decodable {
    let model: String
    let answers: [String: WireAnswer]
}

/// One answer as the reply carries it. Decoding never fails: an answer this
/// app cannot read becomes `.skipped`.
private enum WireAnswer: Decodable {
    case choice(JudgmentReply.Choice)
    case score(Double)
    case noul(Double)
    case skipped

    private enum CodingKeys: String, CodingKey {
        case type
        case choice
        case confidence
        case score
        case noul
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
            let type = try? container.decode(String.self, forKey: .type)
        else {
            self = .skipped
            return
        }
        switch type {
        case "choice":
            if let choice = try? container.decode(String.self, forKey: .choice),
                let confidence = try? container.decode(Double.self, forKey: .confidence)
            {
                self = .choice(JudgmentReply.Choice(choice: choice, confidence: confidence))
            } else {
                self = .skipped
            }
        case "score":
            if let score = try? container.decode(Double.self, forKey: .score) {
                self = .score(score)
            } else {
                self = .skipped
            }
        case "noul":
            if let noul = try? container.decode(Double.self, forKey: .noul) {
                self = .noul(noul)
            } else {
                self = .skipped
            }
        default:
            self = .skipped
        }
    }
}
