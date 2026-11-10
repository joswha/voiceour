import Foundation

/// A topic the user owns. `summary` is one line; the sorting model reads it as the rubric.
public struct MemoryTopic: Codable, Equatable, Identifiable, Sendable {
    /// A stable slug of `a-z`, `0-9` and `-`, never `none`, so a page path and
    /// the sorting model's option key can both carry it unchanged.
    public var id: String
    public var name: String
    public var summary: String
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case createdAt = "created_at"
    }

    public init(id: String, name: String, summary: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
    }
}

/// One durable memory entry: a dictation or a note, verbatim.
///
/// The record is the source of truth every memory page derives from, so it
/// decodes leniently: a field a later build wrote, or a label or thread this
/// build cannot read, costs that field and never the entry's text.
public struct MemoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// A dictation keeps its History row id, so the two records of one
    /// utterance stay recognisably the same.
    public var id: UUID
    public var createdAt: Date
    public var kind: JournalEntry.Kind
    public var text: String
    public var appBundleId: String?
    public var appName: String?
    /// Linking an entry clears its miss: an entry never holds both.
    public var thread: JournalThreadRef? {
        didSet { if thread != nil { unlinked = nil } }
    }
    public var captureSeconds: Double
    /// The topic the user filed this entry under.
    public var userTopicID: String?
    /// True when the user removed the entry from every topic, which overrides
    /// whatever topic the sorting model suggests.
    public var userRemovedTopic: Bool
    public var label: EntryLabel?
    /// Why an eligible dictation or note was not linked; nil when it was
    /// linked, when linking was not attempted, or when the reason is unknown.
    /// Never held beside a thread: setting it on a linked entry leaves it nil.
    public var unlinked: AgentLinkMiss? {
        didSet { if thread != nil { unlinked = nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case kind
        case text
        case appBundleId = "app_bundle_id"
        case appName = "app_name"
        case thread
        case captureSeconds = "capture_seconds"
        case userTopicID = "user_topic_id"
        case userRemovedTopic = "user_removed_topic"
        case label
        case unlinked
    }

    public init(
        id: UUID,
        createdAt: Date,
        kind: JournalEntry.Kind = .dictation,
        text: String,
        appBundleId: String? = nil,
        appName: String? = nil,
        thread: JournalThreadRef? = nil,
        captureSeconds: Double = 0,
        userTopicID: String? = nil,
        userRemovedTopic: Bool = false,
        label: EntryLabel? = nil,
        unlinked: AgentLinkMiss? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.appBundleId = appBundleId
        self.appName = appName
        self.thread = thread
        self.captureSeconds = captureSeconds
        self.userTopicID = userTopicID
        self.userRemovedTopic = userRemovedTopic
        self.label = label
        self.unlinked = thread == nil ? unlinked : nil
    }

    /// The History row's dictation, mapped exactly as the Journal reads it so
    /// memory and the Journal never disagree about one utterance.
    public init(_ session: RecentSession) {
        let entry = JournalEntry(session)
        self.init(
            id: entry.id,
            createdAt: entry.createdAt,
            kind: entry.kind,
            text: entry.text,
            appBundleId: entry.app?.bundleId,
            appName: entry.app?.name,
            thread: entry.thread,
            captureSeconds: entry.captureSeconds,
            unlinked: entry.unlinked
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // A kind a later build introduced still loads, as the plain dictation
        // every kind started as.
        let rawKind = try? container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(JournalEntry.Kind.init(rawValue:)) ?? .dictation
        text = try container.decode(String.self, forKey: .text)
        // Only the id, the date and the text are required. A field of the wrong
        // type reads as absent: one bad value must never make a whole month of
        // the user's words unreadable.
        appBundleId = try? container.decodeIfPresent(String.self, forKey: .appBundleId)
        appName = try? container.decodeIfPresent(String.self, forKey: .appName)
        thread = try? container.decodeIfPresent(JournalThreadRef.self, forKey: .thread)
        captureSeconds = (try? container.decodeIfPresent(Double.self, forKey: .captureSeconds)) ?? 0
        userTopicID = try? container.decodeIfPresent(String.self, forKey: .userTopicID)
        userRemovedTopic = (try? container.decodeIfPresent(Bool.self, forKey: .userRemovedTopic)) ?? false
        label = try? container.decodeIfPresent(EntryLabel.self, forKey: .label)
        // A miss a later build named reads as unknown; an entry stored with
        // both a thread and a miss reads as linked.
        let unlinked = try? container.decodeIfPresent(AgentLinkMiss.self, forKey: .unlinked)
        self.unlinked = thread == nil ? unlinked : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(appBundleId, forKey: .appBundleId)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(thread, forKey: .thread)
        try container.encode(captureSeconds, forKey: .captureSeconds)
        try container.encodeIfPresent(userTopicID, forKey: .userTopicID)
        try container.encode(userRemovedTopic, forKey: .userRemovedTopic)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(unlinked, forKey: .unlinked)
    }

    /// The topic this entry counts under: the user's choice when it names a known topic; nil when the user removed it;
    /// else the label's topic when it is known and its confidence >= 0.6; else nil.
    ///
    /// A user choice that names a topic since deleted gives nil rather than
    /// falling back to the label: the user decided where this entry goes, and
    /// a model guess must not quietly overrule that decision.
    public func effectiveTopicID(known: Set<String>) -> String? {
        if let userTopicID {
            return known.contains(userTopicID) ? userTopicID : nil
        }
        if userRemovedTopic {
            return nil
        }
        guard let label, let topicID = label.topicID, known.contains(topicID),
            let confidence = label.topicConfidence, confidence >= OrganizerPolicy.topicConfidence
        else {
            return nil
        }
        return topicID
    }
}

extension JournalEntry {
    /// The memory entry as the Journal lenses read it, filed under its
    /// effective topic among `knownTopicIDs`.
    public init(_ entry: MemoryEntry, knownTopicIDs: Set<String>) {
        self.init(
            id: entry.id,
            createdAt: entry.createdAt,
            kind: entry.kind,
            text: entry.text,
            app: entry.appBundleId.map { DictationAppIdentity(bundleId: $0, name: entry.appName) },
            thread: entry.thread,
            captureSeconds: entry.captureSeconds,
            topicID: entry.effectiveTopicID(known: knownTopicIDs),
            label: entry.label,
            unlinked: entry.unlinked
        )
    }
}
