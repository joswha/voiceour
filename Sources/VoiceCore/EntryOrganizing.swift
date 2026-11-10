import Foundation

/// Labels one entry with the sorting model. Implementations run off the main actor.
///
/// The model only sorts the user's words: a label is evidence about an entry,
/// never text the model wrote, so memory keeps the user's text verbatim.
public protocol EntryOrganizing: Sendable {
    /// Nil when no label could be made: no key, a transport failure, an invalid reply. Never throws.
    func label(text: String, topics: [MemoryTopic]) async -> EntryLabel?
}

/// The organizer used while sorting is off: it labels nothing, so no entry
/// leaves the Mac.
public struct NoEntryOrganizing: EntryOrganizing {
    public init() {}

    public func label(text: String, topics: [MemoryTopic]) async -> EntryLabel? {
        nil
    }
}

/// The fixed limits and names every organizer request and reply share.
public enum OrganizerPolicy {
    /// The sorting model every request names.
    public static let model = "jev-1.14.0"
    /// The least confidence at which a topic label files an entry under that topic.
    public static let topicConfidence: Double = 0.6
    /// One choice holds 255 options and one of them is the none option.
    public static let maximumTopics = 254
    /// Longer text is cut at this many characters for the request only; memory keeps the whole text.
    public static let maximumTextCharacters = 8_000
    /// The topic option that says no offered topic fits. No topic id may take this value.
    public static let noneOption = "none"
}
