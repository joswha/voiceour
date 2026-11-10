import Foundation

/// The rules for the topics the user owns. Pure: every change returns a new
/// list, so a refused change leaves the caller's topics exactly as they were and
/// the memory store sees only lists that already passed these checks.
public enum TopicCatalog {
    /// Why a topic name was not accepted. `duplicate` carries the name of the
    /// topic already holding it, so the user is told which one collides.
    public enum Refusal: Error, Equatable, Sendable {
        case emptyName
        case duplicate(String)
        case reserved
        case tooMany
    }

    /// The stable id a name produces: lower-case ASCII letters and digits, with
    /// every run of anything else collapsed into one `-` and none at either end.
    ///
    /// Diacritics fold before filtering so "Café" and "Cafe" name the same topic
    /// instead of one losing its last letter. A name with no letter or digit that
    /// survives the fold gives "", which no topic may use as its id.
    public static func slug(for name: String) -> String {
        let folded = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var slug = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            guard isSlugScalar(scalar) else {
                pendingSeparator = true
                continue
            }
            if pendingSeparator, !slug.isEmpty {
                slug.append("-")
            }
            pendingSeparator = false
            slug.unicodeScalars.append(scalar)
        }
        return slug
    }

    /// Appends a topic whose id is the slug of its trimmed name.
    ///
    /// The id is fixed at creation, so later renames never move the files and
    /// labels that already point at it.
    public static func adding(
        name: String, summary: String, to topics: [MemoryTopic], now: Date
    ) throws -> [MemoryTopic] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = try acceptedSlug(for: trimmedName, against: topics)
        guard topics.count < OrganizerPolicy.maximumTopics else {
            throw Refusal.tooMany
        }
        var result = topics
        result.append(
            MemoryTopic(id: slug, name: trimmedName, summary: oneLine(summary), createdAt: now))
        return result
    }

    /// Renames the topic `id` and replaces its summary. The id and creation date
    /// never change; an unknown id returns `topics` unchanged.
    ///
    /// The name rules compare against the other topics only, so a topic may keep
    /// its own name or change only its case.
    public static func updating(
        id: String, name: String, summary: String, in topics: [MemoryTopic]
    ) throws -> [MemoryTopic] {
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return topics }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var others = topics
        others.remove(at: index)
        _ = try acceptedSlug(for: trimmedName, against: others)
        var result = topics
        result[index].name = trimmedName
        result[index].summary = oneLine(summary)
        return result
    }

    /// Drops the topic `id`; every other topic keeps its place.
    public static func removing(id: String, from topics: [MemoryTopic]) -> [MemoryTopic] {
        topics.filter { $0.id != id }
    }

    /// The slug of an already-trimmed name, or the refusal that name earns.
    ///
    /// A collision is checked against both the existing ids and the slugs of the
    /// existing names: after a rename the two can differ, and either one
    /// matching would make two topics indistinguishable to the user or on disk.
    private static func acceptedSlug(for name: String, against topics: [MemoryTopic]) throws -> String {
        let candidate = Self.slug(for: name)
        guard !candidate.isEmpty else { throw Refusal.emptyName }
        guard candidate != OrganizerPolicy.noneOption else { throw Refusal.reserved }
        if let existing = topics.first(where: {
            $0.id == candidate
                || Self.slug(for: $0.name) == candidate
                || $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            throw Refusal.duplicate(existing.name)
        }
        return candidate
    }

    /// A summary is the one-line rubric the sorting model reads, so every line
    /// break becomes a space before the ends are trimmed.
    private static func oneLine(_ summary: String) -> String {
        String(summary.map { $0.isNewline ? " " : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9":
            return true
        default:
            return false
        }
    }
}
