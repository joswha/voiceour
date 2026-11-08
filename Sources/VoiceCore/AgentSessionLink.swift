import Foundation

/// A coding agent whose local prompt log a dictation can be linked to.
///
/// `allCases` order is the tie-break order when two agents record a prompt at
/// the same instant.
public enum CodingAgent: String, Codable, Sendable, CaseIterable {
    case omp
    case claudeCode = "claude-code"
    case codex

    public var displayName: String {
        switch self {
        case .omp: "omp"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One prompt a coding agent recorded as sent by the user.
public struct AgentPrompt: Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    public var workingDirectory: String?
    public var sessionTitle: String?
    public var sentAt: Date
    public var text: String

    public init(
        agent: CodingAgent,
        sessionId: String,
        workingDirectory: String?,
        sessionTitle: String?,
        sentAt: Date,
        text: String
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.sessionTitle = sessionTitle
        self.sentAt = sentAt
        self.text = text
    }
}

/// Identifies one agent session across History rows.
public struct AgentSessionKey: Hashable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String

    public init(agent: CodingAgent, sessionId: String) {
        self.agent = agent
        self.sessionId = sessionId
    }
}

/// The agent prompt a dictation was sent as.
public struct AgentSessionMatch: Codable, Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    public var workingDirectory: String?
    public var sessionTitle: String?
    public var sentAt: Date
    /// The matching part of the prompt as sent; nil when it equals the
    /// delivered text up to whitespace.
    public var sentText: String?

    public init(
        agent: CodingAgent,
        sessionId: String,
        workingDirectory: String?,
        sessionTitle: String?,
        sentAt: Date,
        sentText: String?
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.sessionTitle = sessionTitle
        self.sentAt = sentAt
        self.sentText = sentText
    }

    public var key: AgentSessionKey {
        AgentSessionKey(agent: agent, sessionId: sessionId)
    }

    /// The agent's name and the session's title, else its directory's name,
    /// else the start of its id.
    public var displayTitle: String {
        let label =
            sessionTitle
            ?? workingDirectory.map(Self.lastPathComponent)
            ?? String(sessionId.prefix(8))
        return "\(agent.displayName) · \(label)"
    }

    /// The session's directory name, when known, and its id.
    public var locationLine: String {
        [workingDirectory.map(Self.lastPathComponent), sessionId]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A shell command that resumes the session in its working directory.
    public var resumeCommand: String {
        let id = Self.shellWord(sessionId)
        let resume =
            switch agent {
            case .omp: "omp --resume \(id)"
            case .claudeCode: "claude --resume \(id)"
            case .codex: "codex resume \(id)"
            }
        guard let workingDirectory else { return resume }
        return "cd \(Self.shellWord(workingDirectory)) && \(resume)"
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// `word` as one POSIX shell word: unchanged when it holds only characters
    /// no shell treats specially, else single-quoted.
    private static func shellWord(_ word: String) -> String {
        let isPlain =
            !word.isEmpty
            && word.unicodeScalars.allSatisfy { scalar in
                switch scalar {
                case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "/", "-": true
                default: false
                }
            }
        if isPlain { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A History row's resolved agent link. A row with no link yet has none of
/// these: it is still pending.
public enum AgentSessionLink: Codable, Equatable, Sendable {
    case linked(AgentSessionMatch)
    /// No prompt matched within the send window, which has closed.
    case unmatched

    public var match: AgentSessionMatch? {
        if case .linked(let match) = self { return match }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case match
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "linked":
            self = .linked(try container.decode(AgentSessionMatch.self, forKey: .match))
        case "unmatched":
            self = .unmatched
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Unknown agent link status \"\(status)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linked(let match):
            try container.encode("linked", forKey: .status)
            try container.encode(match, forKey: .match)
        case .unmatched:
            try container.encode("unmatched", forKey: .status)
        }
    }
}
