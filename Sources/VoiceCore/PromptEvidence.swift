import Foundation

/// One dictation to look for in the agents' prompt logs: its delivered text
/// and when it was delivered.
public struct PromptEvidenceQuery: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var at: Date

    public init(id: UUID, text: String, at: Date) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// The one session whose own prompts held a dictation's words, with the facts
/// a binding needs, read from that session's records.
public struct PromptEvidenceMatch: Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    /// The earliest prompt of the session, inside the dictation's window,
    /// that held its words: the moment the dictation was sent.
    public var sentAt: Date
    public var sessionFile: String?
    public var workingDirectory: String?
    public var title: String?

    public init(
        agent: CodingAgent,
        sessionId: String,
        sentAt: Date,
        sessionFile: String? = nil,
        workingDirectory: String? = nil,
        title: String? = nil
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sentAt = sentAt
        self.sessionFile = sessionFile
        self.workingDirectory = workingDirectory
        self.title = title
    }
}

/// What one reading of the prompt logs found. A query in neither field was
/// too short or held by no session.
public struct PromptEvidenceRun: Equatable, Sendable {
    /// Exactly one session held the text.
    public var matches: [UUID: PromptEvidenceMatch]
    /// More than one session held the text, so none is linked.
    public var ambiguous: Set<UUID>

    public init(matches: [UUID: PromptEvidenceMatch] = [:], ambiguous: Set<UUID> = []) {
        self.matches = matches
        self.ambiguous = ambiguous
    }
}

/// Reads every local agent session's own prompt log once and finds, for each
/// query, the one session whose prompts hold its words.
public protocol AgentPromptEvidenceReading: Sendable {
    func evidence(for queries: [PromptEvidenceQuery]) -> PromptEvidenceRun
}

/// Reads nothing, so nothing is linked; the default wherever no reader is
/// injected.
public struct NoAgentPromptEvidenceReading: AgentPromptEvidenceReading {
    public init() {}

    public func evidence(for queries: [PromptEvidenceQuery]) -> PromptEvidenceRun {
        PromptEvidenceRun()
    }
}

/// The rule that decides which words count as evidence, shared by the reader
/// and the coordinator so both count and compare text the same way.
public enum PromptEvidence {
    /// Fewer words recur too often across sessions to name one.
    public static let minimumWords = 6
    /// A prompt timestamp kept in whole seconds reads up to a second early.
    public static let leadTime: TimeInterval = 1
    /// The longest measured delay from a dictation to its prompt was about
    /// 12 minutes; later prompts are more likely another use of the words.
    public static let followTime: TimeInterval = 30 * 60

    /// The span in which a prompt may carry a dictation delivered at `at`.
    public static func window(around at: Date) -> ClosedRange<Date> {
        at.addingTimeInterval(-leadTime)...at.addingTimeInterval(followTime)
    }

    /// The number of maximal runs of letters or digits in `text`.
    public static func words(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            let isWordCharacter = character.isLetter || character.isNumber
            if isWordCharacter, !inWord {
                count += 1
            }
            inWord = isWordCharacter
        }
        return count
    }

    /// `text` with every run of whitespace turned into one space and none at
    /// either end, so a prompt that rewrapped or joined the words still
    /// contains them.
    public static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
