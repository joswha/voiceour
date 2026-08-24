import Foundation

/// Whether a term was shipped with the app or is one the reader authored.
public enum TermOrigin: String, Equatable, Sendable, CaseIterable {
    case yours
    case builtIn
}

/// One origin the terms list can be filtered by, and how many live terms carry
/// it.
public struct TermOriginFacet: Identifiable, Equatable, Sendable {
    public var origin: TermOrigin
    public var count: Int

    public var id: TermOrigin { origin }

    public init(origin: TermOrigin, count: Int) {
        self.origin = origin
        self.count = count
    }
}

/// Searching, filtering and ordering glossary terms.
///
/// Extracted from the console's glossary surface so the logic is reachable
/// without a SwiftUI view: as private members of a `View` none of it could be
/// tested, and which strings a search covers is exactly the rule that drifts
/// silently.
///
/// Every entry point takes the whole ledger and returns what the reader should
/// see. Nothing here reads settings or the current selection implicitly.
public enum GlossaryQuery {
    /// Where `term` came from. Only a shipped term is built in; a correction, an
    /// import and an app profile are all terms the reader is answerable for.
    public static func origin(of term: ProtectedTerm) -> TermOrigin {
        term.source == .bundled ? .builtIn : .yours
    }

    /// The terms the list shows, alphabetically, narrowed to `origin` when one is
    /// given and then by `query` against each term's canonical and the spoken
    /// forms the user authored.
    ///
    /// Derived variants from `Glossary.derivedAliases(for:)` are deliberately not
    /// searched. They are matched by dictation but were never typed by anyone, so
    /// a hit on one could not be explained by the row it returned. Removed terms
    /// are dropped outright. Ordering is total — canonical case-insensitively,
    /// then term id — so a list holding one spelling twice does not reshuffle
    /// between reloads. `query` is expected pre-trimmed; an empty query and a nil
    /// origin match everything.
    public static func matches(
        in terms: [ProtectedTerm],
        query: String,
        origin: TermOrigin?
    ) -> [ProtectedTerm] {
        terms
            .filter { term in
                guard term.tombstonedAt == nil else { return false }
                guard origin == nil || Self.origin(of: term) == origin else { return false }
                guard !query.isEmpty else { return true }
                if contains(query, in: term.canonical) { return true }
                return Glossary.userAliases(for: term).contains { contains(query, in: $0) }
            }
            .sorted { lhs, rhs in
                let comparison = lhs.canonical.localizedCaseInsensitiveCompare(rhs.canonical)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.termId < rhs.termId
            }
    }

    /// The origins the terms list can be filtered by, the reader's own first.
    ///
    /// An origin no live term carries is omitted: a filter whose only effect is
    /// to empty the list is not a choice. The order is fixed rather than ranked
    /// by count, so the menu reads the same in every ledger.
    public static func originFacets(in terms: [ProtectedTerm]) -> [TermOriginFacet] {
        var counts: [TermOrigin: Int] = [:]
        for term in terms where term.tombstonedAt == nil {
            counts[origin(of: term), default: 0] += 1
        }
        return [TermOrigin.yours, .builtIn].compactMap { origin in
            counts[origin].map { TermOriginFacet(origin: origin, count: $0) }
        }
    }

    private static func contains(_ query: String, in value: String) -> Bool {
        value.range(of: query, options: .caseInsensitive) != nil
    }
}
