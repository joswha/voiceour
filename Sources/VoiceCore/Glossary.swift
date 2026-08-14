import Foundation

private func aliasKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

public enum Glossary {
    public static func derivedAliases(for canonical: String) -> [String] {
        let tokens = canonicalTokens(in: canonical)
        guard tokens.count >= 2 else { return [] }

        let spaced = tokens.joined(separator: " ").lowercased()
        let letterSpaced = tokens.map { token in
            guard token.count >= 2, token.allSatisfy(\.isUppercase) else {
                return token.lowercased()
            }
            return token.map(String.init).joined(separator: " ").lowercased()
        }.joined(separator: " ")

        let canonicalKey = canonical.lowercased()
        var seen = Set<String>()
        return [spaced, letterSpaced].filter { alias in
            let key = alias.lowercased()
            return key != canonicalKey && seen.insert(key).inserted
        }
    }

    /// Every surface the user authored or confirmed for this term.
    ///
    /// Spoken aliases retain their order, followed by unrejected labeled
    /// aliases. Values are trimmed and de-duplicated case-insensitively with
    /// the first occurrence winning. The canonical is excluded, and automatic
    /// aliases from `derivedAliases(for:)` are not added.
    public static func userAliases(for term: ProtectedTerm) -> [String] {
        let canonicalKey = aliasKey(term.canonical)
        let labeled = term.labeledAliases
            .filter { $0.rejectedAt == nil }
            .map(\.surface)
        var aliases: [String] = []
        var seen = Set<String>()
        for alias in term.spokenAliases + labeled {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = aliasKey(alias)
            guard key != canonicalKey, seen.insert(key).inserted else { continue }
            aliases.append(trimmed)
        }
        return aliases
    }

    public static func canonicalize(_ text: String, terms: [ProtectedTerm]) -> String {
        var result = text
        for term in terms {
            for alias in matchingAliases(for: term) {
                result = replaceAlias(alias, in: result, with: term.renderedCanonical)
            }
        }
        return result
    }

    static func lockedCanonicals(presentIn text: String, terms: [ProtectedTerm]) -> Set<String> {
        let canonicalized = canonicalize(text, terms: terms)
        return Set(
            terms.filter { term in
                guard term.protected, term.tombstonedAt == nil else { return false }
                return containsTerm(term.renderedCanonical, in: canonicalized)
            }.map(\.renderedCanonical))
    }

    static func validateTermLock(original: String, candidate: String, terms: [ProtectedTerm]) -> Bool {
        let locked = lockedCanonicals(presentIn: original, terms: terms)
        guard !locked.isEmpty else { return true }
        return locked.allSatisfy { containsTerm($0, in: candidate) }
    }

    /// Pure view of persistent terms for a capture context: drops tombstoned
    /// entries, activates global + matching bundle/project scopes, and orders by
    /// source trust (then original order for determinism).
    public static func activeTerms(
        _ terms: [ProtectedTerm],
        bundleId: String? = nil,
        projectId: String? = nil,
        now: Date = Date()
    ) -> [ProtectedTerm] {
        terms.enumerated().filter { _, term in
            if let tombstonedAt = term.tombstonedAt, tombstonedAt <= now { return false }
            switch term.scope {
            case .global: return true
            case .bundleID(let id): return bundleId == id
            case .projectID(let id): return projectId == id
            }
        }.sorted { lhs, rhs in
            let lt = lhs.element.source.trustRank
            let rt = rhs.element.source.trustRank
            if lt != rt { return lt > rt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Whether `alias` may stand in for `canonical` *wherever it appears*.
    ///
    /// A glossary alias is not a suggestion, it is an unconditional rewrite of
    /// every future utterance. The bar is therefore not "the user accepted this
    /// once" but "this surface means the canonical everywhere". Two shapes fail
    /// that test, and both were found corrupting real dictation history rather
    /// than imagined:
    ///
    /// - **A canonical that is a bare integer.** The suggestion engine offered
    ///   `one` as a mishearing of the canonical `1`, and four such rules were
    ///   accepted in a 22-second click-through. They then rewrote ordinary
    ///   speech: `one-to-one` became `1-to-1`, and `one two three four five six`
    ///   became `1 2 three four 5 6` — ragged because only 1, 2, 5 and 6 had
    ///   been taught. A digit is not an identifier, so a term protecting one
    ///   protects nothing while still being able to damage prose.
    /// - **A single-character alias.** One letter recurs constantly in ordinary
    ///   speech and cannot carry a canonical's meaning, so `Z` -> `Zed` fires on
    ///   every stray "z".
    ///
    /// This filters aliases only, never the canonical itself: a term still
    /// matches its own surface, so case normalisation is untouched and a term
    /// caught here degrades to inert rather than to broken.
    ///
    /// Deliberately not a common-word list. `RefinementPolicy` already records
    /// that a stopword list cannot separate these cases — the surfaces that did
    /// the damage here include `depth` and `Cloud`, which no stopword list
    /// contains, so a list would give false confidence while missing the cases
    /// that were actually measured.
    public static func aliasCanGeneralize(_ alias: String, canonical: String) -> Bool {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAlias.count > 1 else { return false }
        let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCanonical.isEmpty, trimmedCanonical.allSatisfy(\.isNumber) { return false }
        return true
    }

    static func matchingAliases(for term: ProtectedTerm) -> [String] {
        var aliases: [String] = []
        var seen = Set<String>()
        let generalizable =
            (userAliases(for: term) + derivedAliases(for: term.canonical))
            .filter { aliasCanGeneralize($0, canonical: term.canonical) }
        for alias in [term.canonical] + generalizable {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = aliasKey(alias)
            if seen.insert(key).inserted {
                aliases.append(trimmed)
            }
        }

        return aliases.enumerated().sorted { lhs, rhs in
            if lhs.element.count != rhs.element.count {
                return lhs.element.count > rhs.element.count
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func canonicalTokens(in canonical: String) -> [String] {
        var tokenized = canonical.replacingOccurrences(
            of: "[\\s._-]+",
            with: " ",
            options: .regularExpression
        )
        let boundaries = [
            ("([A-Z]+)([A-Z][a-z])", "$1 $2"),
            ("([a-z])([A-Z])", "$1 $2"),
            ("([A-Za-z])([0-9])", "$1 $2"),
            ("([0-9])([A-Za-z])", "$1 $2"),
        ]
        for (pattern, replacement) in boundaries {
            tokenized = tokenized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return tokenized.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func replaceAlias(_ alias: String, in text: String, with canonical: String) -> String {
        let parts = alias.split(whereSeparator: { $0.isWhitespace }).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !parts.isEmpty else { return text }
        let pattern = "(?i)(?<![A-Za-z0-9_])" + parts.joined(separator: "\\s+") + "(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: canonical)
    }

    private static func containsTerm(_ canonical: String, in text: String) -> Bool {
        replaceAlias(canonical, in: text, with: "__VOICEOUR_TERM__").contains("__VOICEOUR_TERM__")
    }
}

/// Pure privacy policy for vocabulary that may be sent to a cloud refiner.
public enum RefinerPrivacy {
    /// Returns live, explicitly cloud-eligible global and bundle-scoped terms.
    ///
    /// Project-scoped vocabulary is always device-local, regardless of its
    /// `cloudEligible` value.
    public static func cloudEligible(_ terms: [ProtectedTerm]) -> [ProtectedTerm] {
        terms.filter { term in
            guard term.tombstonedAt == nil, term.cloudEligible else { return false }
            if case .projectID = term.scope { return false }
            return true
        }
    }
}

/// Explicit, user-driven mutations for a `ProtectedTerm`. Only these helpers set
/// alias `confirmedAt`/`rejectedAt`, keeping those fields off any automatic
/// path.
public enum TermMutation {
    /// Reconciles both alias stores against one user-authored list.
    ///
    /// Spoken aliases become `aliases`. Labeled aliases absent from the list
    /// are rejected and unconfirmed; present labels have any rejection cleared.
    /// Label matching is case-insensitive.
    public static func settingAliases(
        _ aliases: [String],
        on term: ProtectedTerm,
        at date: Date = Date()
    ) -> ProtectedTerm {
        var updated = term
        updated.spokenAliases = aliases
        let aliasKeys = Set(aliases.map(aliasKey))
        for index in updated.labeledAliases.indices {
            let key = aliasKey(updated.labeledAliases[index].surface)
            if aliasKeys.contains(key) {
                updated.labeledAliases[index].rejectedAt = nil
            } else {
                updated.labeledAliases[index].rejectedAt = date
                updated.labeledAliases[index].confirmedAt = nil
            }
        }
        return updated
    }

    /// Records an explicit user confirmation of an alias surface, adding it (or
    /// clearing a prior rejection) and stamping the alias `confirmedAt`.
    public static func confirmingAlias(
        _ surface: String,
        on term: ProtectedTerm,
        at date: Date = Date()
    ) -> ProtectedTerm {
        var updated = term
        let key = surface.lowercased()
        if let index = updated.labeledAliases.firstIndex(where: { $0.surface.lowercased() == key }) {
            updated.labeledAliases[index].confirmedAt = date
            updated.labeledAliases[index].rejectedAt = nil
        } else {
            updated.labeledAliases.append(AliasLabel(surface: surface, confirmedAt: date))
        }
        return updated
    }

    /// Records an explicit user rejection of an alias surface, stamping its
    /// `rejectedAt`, clearing any confirmation, and dropping the same surface
    /// from `spokenAliases`.
    ///
    /// The spoken drop is what makes rejection actually hold. `settingAliases`
    /// writes the whole displayed list — labeled surfaces included — into
    /// `spokenAliases`, so a term the user has edited once carries the surface in
    /// both stores. Stamping only the label would leave `userAliases` still
    /// returning it from the spoken store, and "don't suggest this again" would
    /// quietly keep suggesting it.
    public static func rejectingAlias(
        _ surface: String,
        on term: ProtectedTerm,
        at date: Date = Date()
    ) -> ProtectedTerm {
        var updated = term
        let key = aliasKey(surface)
        updated.spokenAliases.removeAll {
            aliasKey($0) == key
        }
        if let index = updated.labeledAliases.firstIndex(where: { $0.surface.lowercased() == key }) {
            updated.labeledAliases[index].rejectedAt = date
            updated.labeledAliases[index].confirmedAt = nil
        } else {
            updated.labeledAliases.append(AliasLabel(surface: surface, rejectedAt: date))
        }
        return updated
    }
}
