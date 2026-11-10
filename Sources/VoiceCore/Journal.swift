import Foundation

/// What kind of utterance an entry is, as the sorting model labelled it.
public enum UtteranceKind: String, Codable, Sendable, CaseIterable {
    case instruction, question, idea, decision, todo, observation, chatter

    public var displayName: String {
        switch self {
        case .instruction: "Instruction"
        case .question: "Question"
        case .idea: "Idea"
        case .decision: "Decision"
        case .todo: "To-do"
        case .observation: "Observation"
        case .chatter: "Chatter"
        }
    }
}

/// The sorting model's labels for one entry. Every field is evidence, never text the model wrote.
///
/// Decoding is lenient so a label written by a newer model, or one whose
/// optional fields are malformed, still loads: only `model` and `labeled_at`
/// are required, and a `kind` this build does not know decodes as nil.
public struct EntryLabel: Codable, Equatable, Sendable {
    /// Nil when the reply named none, or named one this build does not know.
    public var kind: UtteranceKind?
    public var kindConfidence: Double?
    /// The model's topic choice; nil when it chose "none" or no topics were offered.
    public var topicID: String?
    public var topicConfidence: Double?
    /// Lasting value on a 0...3 scale.
    public var keep: Double?
    /// The model id that answered, e.g. "jev-1.14.0".
    public var model: String
    public var labeledAt: Date

    private enum CodingKeys: String, CodingKey {
        case kind
        case kindConfidence = "kind_confidence"
        case topicID = "topic_id"
        case topicConfidence = "topic_confidence"
        case keep
        case model
        case labeledAt = "labeled_at"
    }

    public init(
        kind: UtteranceKind? = nil,
        kindConfidence: Double? = nil,
        topicID: String? = nil,
        topicConfidence: Double? = nil,
        keep: Double? = nil,
        model: String,
        labeledAt: Date
    ) {
        self.kind = kind
        self.kindConfidence = kindConfidence
        self.topicID = topicID
        self.topicConfidence = topicConfidence
        self.keep = keep
        self.model = model
        self.labeledAt = labeledAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        labeledAt = try container.decode(Date.self, forKey: .labeledAt)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap(UtteranceKind.init(rawValue:))
        kindConfidence = try? container.decodeIfPresent(Double.self, forKey: .kindConfidence)
        topicID = try? container.decodeIfPresent(String.self, forKey: .topicID)
        topicConfidence = try? container.decodeIfPresent(Double.self, forKey: .topicConfidence)
        keep = try? container.decodeIfPresent(Double.self, forKey: .keep)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(kindConfidence, forKey: .kindConfidence)
        try container.encodeIfPresent(topicID, forKey: .topicID)
        try container.encodeIfPresent(topicConfidence, forKey: .topicConfidence)
        try container.encodeIfPresent(keep, forKey: .keep)
        try container.encode(model, forKey: .model)
        try container.encode(labeledAt, forKey: .labeledAt)
    }
}

/// The agent session a journal entry belongs to.
///
/// A copy of the binding's identity and the state the Journal shows, without
/// the binding's file paths and prompt-log offset: memory keeps what a reader
/// needs to find and resume the session, nothing about how it was found.
public struct JournalThreadRef: Codable, Equatable, Sendable {
    public var agent: CodingAgent
    public var sessionId: String
    /// Blank decodes and initializes as nil, so a fallback title is chosen
    /// instead of an empty one.
    public var title: String?
    /// Blank decodes and initializes as nil.
    public var workingDirectory: String?
    public var resumable: Bool
    /// Nil while the send check is pending, true when sent, false when not sent.
    public var sent: Bool?
    /// How the dictation was tied to the session. Absent on disk reads as
    /// `.pane`: every link written before words could link a row came from it.
    public var evidence: AgentLinkEvidence

    private enum CodingKeys: String, CodingKey {
        case agent
        case sessionId = "session_id"
        case title
        case workingDirectory = "working_directory"
        case resumable
        case sent
        case evidence
    }

    public init(
        agent: CodingAgent,
        sessionId: String,
        title: String? = nil,
        workingDirectory: String? = nil,
        resumable: Bool = false,
        sent: Bool? = nil,
        evidence: AgentLinkEvidence = .pane
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.title = JournalStrings.nonBlank(title)
        self.workingDirectory = JournalStrings.nonBlank(workingDirectory)
        self.resumable = resumable
        self.sent = sent
        self.evidence = evidence
    }

    public init(_ binding: AgentSessionBinding) {
        let sent: Bool? =
            switch binding.send {
            case .none: nil
            case .some(.notSent): false
            case .some(.sent): true
            }
        self.init(
            agent: binding.agent,
            sessionId: binding.sessionId,
            title: binding.sessionTitle,
            workingDirectory: binding.workingDirectory,
            resumable: binding.resumable,
            sent: sent,
            evidence: binding.evidence
        )
    }

    /// The session a note was linked to, straight from the resolver. A note
    /// has no send check, so `sent` stays nil.
    public init(_ resolved: ResolvedAgentSession) {
        self.init(
            agent: resolved.agent,
            sessionId: resolved.sessionId,
            title: resolved.sessionTitle,
            workingDirectory: resolved.workingDirectory,
            resumable: resolved.resumable
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(CodingAgent.self, forKey: .agent)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        title = JournalStrings.nonBlank(try container.decodeIfPresent(String.self, forKey: .title))
        workingDirectory = JournalStrings.nonBlank(
            try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        )
        resumable = try container.decodeIfPresent(Bool.self, forKey: .resumable) ?? false
        sent = try container.decodeIfPresent(Bool.self, forKey: .sent)
        evidence = try container.decodeIfPresent(AgentLinkEvidence.self, forKey: .evidence) ?? .pane
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(resumable, forKey: .resumable)
        try container.encodeIfPresent(sent, forKey: .sent)
        // Only a words link writes the key, so a pane link's bytes stay what
        // every earlier build wrote.
        if evidence != .pane {
            try container.encode(evidence, forKey: .evidence)
        }
    }

    public var key: AgentSessionKey {
        AgentSessionKey(agent: agent, sessionId: sessionId)
    }

    /// The working directory's last path component; nil when there is none.
    public var project: String? {
        JournalStrings.lastPathComponent(workingDirectory)
    }
}

/// One thing the user said, as the Journal lenses read it.
public struct JournalEntry: Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case dictation
        case note
    }

    public var id: UUID
    public var createdAt: Date
    public var kind: Kind
    public var text: String
    /// The delivery target; nil for a note or an unrecorded target.
    public var app: DictationAppIdentity?
    /// Linking an entry clears its miss: an entry never holds both.
    public var thread: JournalThreadRef? {
        didSet { if thread != nil { unlinked = nil } }
    }
    /// Microphone capture duration; 0 when unmeasured.
    public var captureSeconds: Double
    /// The effective topic: the user's choice, else a confident label.
    public var topicID: String?
    public var label: EntryLabel?
    /// Why an eligible dictation or note was not linked; nil when it was
    /// linked, when linking was not attempted, or when the reason is unknown.
    public var unlinked: AgentLinkMiss? {
        didSet { if thread != nil { unlinked = nil } }
    }

    public var wordCount: Int { WordCount.count(in: text) }

    public init(
        id: UUID,
        createdAt: Date,
        kind: Kind = .dictation,
        text: String,
        app: DictationAppIdentity? = nil,
        thread: JournalThreadRef? = nil,
        captureSeconds: Double = 0,
        topicID: String? = nil,
        label: EntryLabel? = nil,
        unlinked: AgentLinkMiss? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.app = app
        self.thread = thread
        self.captureSeconds = captureSeconds
        self.topicID = topicID
        self.label = label
        self.unlinked = thread == nil ? unlinked : nil
    }

    /// A History row as a dictation entry. Only a positive `captureMs` counts
    /// as measured, the same rule the stats ledger applies.
    public init(_ session: RecentSession) {
        let app = session.outcome?.targetBundleId.map { bundleId in
            DictationAppIdentity(bundleId: bundleId, name: session.outcome?.targetAppName)
        }
        let captureMs = session.stages?.captureMs ?? 0
        self.init(
            id: session.id,
            createdAt: session.createdAt,
            kind: .dictation,
            text: session.text,
            app: app,
            thread: session.agentSession.map { JournalThreadRef($0) },
            captureSeconds: captureMs > 0 ? Double(captureMs) / 1000 : 0,
            unlinked: session.unlinked
        )
    }
}

/// One agent session with everything said into it.
public struct JournalThread: Equatable, Identifiable, Sendable {
    /// Taken from the newest entry, so the title, directory and resumability
    /// are the latest the binding recorded.
    public var ref: JournalThreadRef
    /// Oldest first, never empty.
    public var entries: [JournalEntry]

    public var id: AgentSessionKey { ref.key }
    public var firstAt: Date { entries[0].createdAt }
    public var lastAt: Date { entries[entries.endIndex - 1].createdAt }
    public var wordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
    public var sentCount: Int { entries.count(where: { $0.thread?.sent == true }) }
    public var notSentCount: Int { entries.count(where: { $0.thread?.sent == false }) }

    /// The agent's name and the session's title, else its folder's name, else
    /// the start of its id: the same fallback a History row's binding shows.
    public var displayTitle: String {
        "\(ref.agent.displayName) · \(ref.title ?? ref.project ?? String(ref.sessionId.prefix(8)))"
    }

    public var resumeCommand: String {
        AgentSessionBinding.resumeCommand(
            agent: ref.agent,
            sessionId: ref.sessionId,
            workingDirectory: ref.workingDirectory
        )
    }
}

/// Threads that share one working directory.
public struct JournalProjectGroup: Equatable, Identifiable, Sendable {
    /// Nil for the threads that have no working directory.
    public var directory: String?
    /// Newest `lastAt` first.
    public var threads: [JournalThread]

    public var id: String { directory ?? "" }

    /// The directory's last path component.
    public var project: String? { JournalStrings.lastPathComponent(directory) }
}

/// One run of a day spent on one subject.
public struct RewindBlock: Equatable, Identifiable, Sendable {
    public enum Subject: Equatable, Sendable {
        /// An entry bound to an agent session; a note with a thread belongs here too.
        case thread(JournalThreadRef)
        /// A note with no thread.
        case notes
        /// An unbound dictation with a recorded target.
        case app(DictationAppIdentity)
        /// An unbound dictation with no recorded target.
        case unknown
    }

    /// For `.thread` and `.app`, the identity carried by the block's newest entry.
    public var subject: Subject
    /// Oldest first, never empty.
    public var entries: [JournalEntry]
    /// Whether the same subject already had a block earlier in the day.
    public var isContinuation: Bool

    public var id: UUID { entries[0].id }
    public var startAt: Date { entries[0].createdAt }
    public var endAt: Date { entries[entries.endIndex - 1].createdAt }
    public var wordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }
}

public struct RewindHighlight: Equatable, Identifiable, Sendable {
    public var kind: UtteranceKind
    public var entry: JournalEntry

    public var id: UUID { entry.id }
}

public struct RewindDay: Equatable, Sendable {
    /// The calendar's start of the day.
    public var day: Date
    /// In time order, oldest first.
    public var blocks: [RewindBlock]
    public var entryCount: Int
    public var wordCount: Int
    public var captureSeconds: Double
    /// Distinct agent sessions among the day's entries.
    public var threadCount: Int
    /// Distinct bundle ids among the day's entries that have no thread.
    public var appCount: Int
    public var noteCount: Int
    public var firstAt: Date?
    public var lastAt: Date?
    /// In time order; empty when no entry has a confident highlight label.
    public var highlights: [RewindHighlight]
}

/// Threads, project groups and one-day rewinds read from journal entries.
///
/// Pure functions of their arguments. Every entry point that needs a day takes
/// its `Calendar`, and nothing here reads the clock, the locale or the current
/// calendar, so a time-zone boundary is expressible in a test. Every ordering
/// is total, so a list does not reshuffle between reloads.
public enum JournalQuery {
    /// A pause longer than this starts a new block.
    public static let blockGap: TimeInterval = 1800
    public static let highlightConfidence: Double = 0.6

    /// The kinds worth surfacing in a day's highlights. Instructions,
    /// observations and chatter are what the user said on the way to these.
    private static let highlightKinds: Set<UtteranceKind> = [.decision, .idea, .todo, .question]

    /// The agent sessions the entries were said into, newest `lastAt` first,
    /// ties by session id. Entries with no thread contribute nothing.
    public static func threads(in entries: [JournalEntry]) -> [JournalThread] {
        var groups: [AgentSessionKey: [JournalEntry]] = [:]
        for entry in chronological(entries) {
            guard let thread = entry.thread else { continue }
            groups[thread.key, default: []].append(entry)
        }
        return
            groups.values
            .compactMap { members -> JournalThread? in
                guard let ref = members.last?.thread else { return nil }
                return JournalThread(ref: ref, entries: members)
            }
            .sorted(by: isNewer)
    }

    /// Threads grouped by their exact working directory. Groups are ordered by
    /// their newest thread, ties by directory; the group of threads with no
    /// directory is always last.
    public static func projectGroups(of threads: [JournalThread]) -> [JournalProjectGroup] {
        Dictionary(grouping: threads) { $0.ref.workingDirectory }
            .map { JournalProjectGroup(directory: $0.key, threads: $0.value.sorted(by: isNewer)) }
            .sorted { lhs, rhs in
                guard let lhsDirectory = lhs.directory else { return false }
                guard let rhsDirectory = rhs.directory else { return true }
                let lhsNewest = lhs.threads[0].lastAt
                let rhsNewest = rhs.threads[0].lastAt
                if lhsNewest != rhsNewest { return lhsNewest > rhsNewest }
                return lhsDirectory < rhsDirectory
            }
    }

    /// The start of every day, in `calendar`'s time zone, that holds an entry;
    /// newest first, each once.
    public static func days(in entries: [JournalEntry], calendar: Calendar) -> [Date] {
        Set(entries.map { calendar.startOfDay(for: $0.createdAt) }).sorted(by: >)
    }

    /// One day of entries as runs on one subject, with the day's totals and
    /// highlights.
    ///
    /// A block ends when the subject changes or when the pause to the next
    /// entry is longer than `blockGap`. Threads are told apart by session key
    /// and apps by bundle id alone, so a title or app name that changed during
    /// the day does not split a run.
    public static func rewind(day: Date, in entries: [JournalEntry], calendar: Calendar) -> RewindDay {
        let dayEntries = chronological(entries.filter { calendar.isDate($0.createdAt, inSameDayAs: day) })

        var runs: [(key: RewindSubjectKey, entries: [JournalEntry])] = []
        for entry in dayEntries {
            let key = RewindSubjectKey(subject(of: entry))
            if let run = runs.last, run.key == key, let previous = run.entries.last,
                entry.createdAt.timeIntervalSince(previous.createdAt) <= blockGap
            {
                runs[runs.endIndex - 1].entries.append(entry)
            } else {
                runs.append((key, [entry]))
            }
        }

        var seen: Set<RewindSubjectKey> = []
        var blocks: [RewindBlock] = []
        for run in runs {
            let newest = run.entries[run.entries.endIndex - 1]
            blocks.append(
                RewindBlock(subject: subject(of: newest), entries: run.entries, isContinuation: seen.contains(run.key))
            )
            seen.insert(run.key)
        }

        let highlights = dayEntries.compactMap { entry -> RewindHighlight? in
            guard let label = entry.label, let kind = label.kind, highlightKinds.contains(kind),
                let confidence = label.kindConfidence, confidence >= highlightConfidence
            else { return nil }
            return RewindHighlight(kind: kind, entry: entry)
        }

        return RewindDay(
            day: calendar.startOfDay(for: day),
            blocks: blocks,
            entryCount: dayEntries.count,
            wordCount: dayEntries.reduce(0) { $0 + $1.wordCount },
            captureSeconds: dayEntries.reduce(0) { $0 + $1.captureSeconds },
            threadCount: Set(dayEntries.compactMap { $0.thread?.key }).count,
            appCount: Set(dayEntries.filter { $0.thread == nil }.compactMap { $0.app?.bundleId }).count,
            noteCount: dayEntries.count(where: { $0.kind == .note }),
            firstAt: dayEntries.first?.createdAt,
            lastAt: dayEntries.last?.createdAt,
            highlights: highlights
        )
    }

    /// Entries whose text, thread title, project or app name contains `query`,
    /// ignoring case and diacritics, in input order.
    ///
    /// The comparison is not localized, so the result does not depend on the
    /// user's locale. `query` is expected pre-trimmed; an empty query matches
    /// everything.
    public static func matches(in entries: [JournalEntry], query: String) -> [JournalEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            let fields: [String?] = [entry.text, entry.thread?.title, entry.thread?.project, entry.app?.name]
            return fields.contains { field in
                guard let field else { return false }
                return field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Oldest first; entries at the same instant keep their input order.
    private static func chronological(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func isNewer(_ lhs: JournalThread, _ rhs: JournalThread) -> Bool {
        if lhs.lastAt != rhs.lastAt { return lhs.lastAt > rhs.lastAt }
        if lhs.ref.sessionId != rhs.ref.sessionId { return lhs.ref.sessionId < rhs.ref.sessionId }
        return lhs.ref.agent.rawValue < rhs.ref.agent.rawValue
    }

    private static func subject(of entry: JournalEntry) -> RewindBlock.Subject {
        if let thread = entry.thread { return .thread(thread) }
        if entry.kind == .note { return .notes }
        if let app = entry.app { return .app(app) }
        return .unknown
    }
}

/// A block subject's identity: the session key or bundle id only, so the
/// display fields a subject carries never split a run.
private enum RewindSubjectKey: Hashable {
    case thread(AgentSessionKey)
    case notes
    case app(String)
    case unknown

    init(_ subject: RewindBlock.Subject) {
        switch subject {
        case .thread(let ref): self = .thread(ref.key)
        case .notes: self = .notes
        case .app(let app): self = .app(app.bundleId)
        case .unknown: self = .unknown
        }
    }
}

/// Text rules the Journal's value types share.
private enum JournalStrings {
    static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func lastPathComponent(_ path: String?) -> String? {
        path.flatMap { nonBlank(($0 as NSString).lastPathComponent) }
    }
}
