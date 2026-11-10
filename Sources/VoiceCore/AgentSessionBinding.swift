import Foundation

/// A coding agent whose session a dictation can be bound to.
public enum CodingAgent: String, Codable, Sendable, CaseIterable {
    case omp
    case claudeCode = "claude-code"

    public var displayName: String {
        switch self {
        case .omp: "omp"
        case .claudeCode: "Claude Code"
        }
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

/// The host pane that had focus just before a paste, as the host reported it.
///
/// A binding is made only when the same pane and the same foreground process
/// have focus before and after the paste, so a focus change in between binds
/// nothing.
public struct AgentFocusCapture: Equatable, Sendable {
    public var pane: String
    public var foregroundPid: Int32

    public init(pane: String, foregroundPid: Int32) {
        self.pane = pane
        self.foregroundPid = foregroundPid
    }
}

/// The agent session whose input received a paste, resolved from live state.
public struct ResolvedAgentSession: Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    /// The session's record file. For a session the agent has not written yet,
    /// the path it will write.
    public var sessionFile: String?
    public var workingDirectory: String?
    public var sessionTitle: String?
    /// Bytes in the session's prompt log when the binding resolved, just after
    /// the paste. The send check reads from a little before them, keeping only
    /// prompts sent after the paste.
    public var promptLogOffset: Int?
    /// Whether the session can be resumed now: its record file exists.
    public var resumable: Bool

    public init(
        agent: CodingAgent,
        sessionId: String,
        sessionFile: String?,
        workingDirectory: String?,
        sessionTitle: String?,
        promptLogOffset: Int?,
        resumable: Bool
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sessionFile = sessionFile
        self.workingDirectory = workingDirectory
        self.sessionTitle = sessionTitle
        self.promptLogOffset = promptLogOffset
        self.resumable = resumable
    }
}

/// Whether the bound session sent the dictation as a prompt.
public enum AgentPromptSend: Codable, Equatable, Sendable {
    /// Sent at `sentAt`. `text` is the matching part of the prompt as sent,
    /// present only when it differs from the delivered text.
    case sent(sentAt: Date, text: String?)
    /// No prompt of the bound session carried the dictation within the send
    /// window.
    case notSent

    private enum CodingKeys: String, CodingKey {
        case status
        case sentAt
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "sent":
            self = .sent(
                sentAt: try container.decode(Date.self, forKey: .sentAt),
                text: try container.decodeIfPresent(String.self, forKey: .text)
            )
        case "notSent":
            self = .notSent
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Unknown send status \"\(status)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sent(let sentAt, let text):
            try container.encode("sent", forKey: .status)
            try container.encode(sentAt, forKey: .sentAt)
            try container.encodeIfPresent(text, forKey: .text)
        case .notSent:
            try container.encode("notSent", forKey: .status)
        }
    }
}

/// A History row's agent session, bound when the dictation was pasted into it.
public struct AgentSessionBinding: Codable, Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    public var sessionFile: String?
    public var workingDirectory: String?
    /// The session's title; nil until the agent names the session.
    public var sessionTitle: String?
    public var boundAt: Date
    public var promptLogOffset: Int?
    public var resumable: Bool
    /// Nil until the send check resolves.
    public var send: AgentPromptSend?

    private enum CodingKeys: String, CodingKey {
        case agent
        case sessionId
        case sessionFile
        case workingDirectory
        case sessionTitle
        case boundAt
        case promptLogOffset
        case resumable
        case send
    }

    public init(
        agent: CodingAgent,
        sessionId: String,
        sessionFile: String? = nil,
        workingDirectory: String? = nil,
        sessionTitle: String? = nil,
        boundAt: Date,
        promptLogOffset: Int? = nil,
        resumable: Bool = false,
        send: AgentPromptSend? = nil
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sessionFile = sessionFile
        self.workingDirectory = workingDirectory
        self.sessionTitle = Self.nonBlank(sessionTitle)
        self.boundAt = boundAt
        self.promptLogOffset = promptLogOffset
        self.resumable = resumable
        self.send = send
    }

    public init(_ resolved: ResolvedAgentSession, boundAt: Date) {
        self.init(
            agent: resolved.agent,
            sessionId: resolved.sessionId,
            sessionFile: resolved.sessionFile,
            workingDirectory: resolved.workingDirectory,
            sessionTitle: resolved.sessionTitle,
            boundAt: boundAt,
            promptLogOffset: resolved.promptLogOffset,
            resumable: resolved.resumable
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(CodingAgent.self, forKey: .agent)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        sessionFile = try container.decodeIfPresent(String.self, forKey: .sessionFile)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        sessionTitle = Self.nonBlank(try container.decodeIfPresent(String.self, forKey: .sessionTitle))
        boundAt = try container.decode(Date.self, forKey: .boundAt)
        promptLogOffset = try container.decodeIfPresent(Int.self, forKey: .promptLogOffset)
        resumable = try container.decodeIfPresent(Bool.self, forKey: .resumable) ?? false
        // An unknown send status keeps the binding; the check runs again.
        send = try? container.decodeIfPresent(AgentPromptSend.self, forKey: .send)
    }

    public var key: AgentSessionKey {
        AgentSessionKey(agent: agent, sessionId: sessionId)
    }

    /// The agent's name and the session's title, else its folder's name, else
    /// the start of its id.
    public var displayTitle: String {
        "\(agent.displayName) · \(sessionTitle ?? folderName ?? String(sessionId.prefix(8)))"
    }

    /// The session's folder and id. The folder is left out when the title
    /// already fell back to it.
    public var locationLine: String {
        guard sessionTitle != nil, let folderName else { return sessionId }
        return "\(folderName) · \(sessionId)"
    }

    /// A shell command that resumes the session in its working directory.
    public var resumeCommand: String {
        Self.resumeCommand(agent: agent, sessionId: sessionId, workingDirectory: workingDirectory)
    }

    /// A shell command that resumes `agent`'s session `sessionId`, changing to
    /// `workingDirectory` first when one is given.
    ///
    /// Static so a reader that holds only the session's identity, such as a
    /// Journal thread rebuilt from memory, produces the same text a binding does.
    public static func resumeCommand(agent: CodingAgent, sessionId: String, workingDirectory: String?) -> String {
        let id = shellWord(sessionId)
        let resume =
            switch agent {
            case .omp: "omp --resume \(id)"
            case .claudeCode: "claude --resume \(id)"
            }
        guard let workingDirectory, !workingDirectory.isEmpty else { return resume }
        return "cd \(shellWord(workingDirectory)) && \(resume)"
    }

    /// The matching part of the prompt as sent, when it differs from the
    /// delivered text.
    public var sentText: String? {
        if case .sent(_, let text) = send { return text }
        return nil
    }

    public var isNotSent: Bool {
        send == .notSent
    }

    private var folderName: String? {
        workingDirectory.flatMap { Self.nonBlank(($0 as NSString).lastPathComponent) }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
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

/// One prompt the bound session recorded as sent by the user.
public struct AgentSessionPrompt: Equatable, Sendable {
    public var sentAt: Date
    public var text: String

    public init(sentAt: Date, text: String) {
        self.sentAt = sentAt
        self.text = text
    }
}

/// What the bound session's own records say now.
public struct AgentSessionSnapshot: Equatable, Sendable {
    /// The session's title; nil while the agent has not named it.
    public var title: String?
    public var sessionFileExists: Bool
    /// Prompts appended after the binding's prompt-log offset, oldest first.
    public var prompts: [AgentSessionPrompt]

    public init(title: String?, sessionFileExists: Bool, prompts: [AgentSessionPrompt]) {
        self.title = title
        self.sessionFileExists = sessionFileExists
        self.prompts = prompts
    }
}
