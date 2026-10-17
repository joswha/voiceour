import Darwin
import Foundation
import VoiceCore

/// Optimized copies of the production text path: bet B3's `swift-opt` arms.
///
/// Each function keeps the shipped algorithm (the same passes, iteration orders, comparisons and
/// tie-breaks) and must stay byte-identical to VoiceCore; `scripts/b3-parity.sh` checks every
/// stage of every parity case against the production arm. What changes is only what the profile
/// (bench/rust/voiceour-text/README.md) blames:
///
/// - representation (both arms): the repair engine's Levenshtein runs on flat byte tables with
///   preallocated rows instead of allocating two `[Int]` per call; phonetic keys are rewritten as
///   bytes instead of through `String.replacingOccurrences`; ASCII skips NFKD; the compiler sorts
///   precomputed keys instead of moving whole `ProtectedTerm`s; the repair partition does not
///   copy the 234,456-word set into an array the engine never reads.
/// - memoization (`swift-opt` only): values that depend only on the active terms (fragile
///   surfaces, the skip-token surfaces, `canonicalize`'s alias expressions) or on nothing (the
///   constant expressions of `canonicalTokens`) are derived once instead of on every call.
///
/// `swift-opt-repr` (`memoize == false`) keeps production's per-call work, the same work the
/// Rust port does, so `rust` vs `swift-opt-repr` compares languages at equal work and
/// `swift-opt` vs `swift-opt-repr` prices the memoization.
enum Optimized {
    /// `DictationCoordinator`'s cleanup stage (see `ProductionTextPath`) over the optimized parts.
    final class TextPath {
        let memoize: Bool
        private var cachedEngine: (canonicals: [String], engine: RepairEngine)?
        private var prepared: PreparedGlossary?

        init(memoize: Bool) {
            self.memoize = memoize
        }

        /// `repairEngine(for:)`, the same cache check as production.
        func repairEngine(for activeTerms: [ProtectedTerm]) -> RepairEngine? {
            guard !activeTerms.isEmpty else { return nil }
            let canonicals = activeTerms.map(\.canonical)
            if let cachedEngine, cachedEngine.canonicals == canonicals {
                return cachedEngine.engine
            }
            let engine = RepairEngine(activeTerms: activeTerms, memoizeConstants: memoize)
            cachedEngine = (canonicals, engine)
            return engine
        }

        /// `CleanupEngine.clean(_:glossary:)`: the shipped function when not memoizing.
        func clean(_ composed: String, activeTerms: [ProtectedTerm]) -> String {
            guard memoize else { return CleanupEngine.clean(composed, glossary: activeTerms) }
            return Cleanup.clean(composed, glossary: preparedGlossary(for: activeTerms))
        }

        /// The per-glossary derivations, rebuilt whenever the active terms differ in any byte
        /// that `clean` reads. The check runs on every call, inside the timed unit.
        private func preparedGlossary(for activeTerms: [ProtectedTerm]) -> PreparedGlossary {
            if let prepared, prepared.isPrepared(for: activeTerms) {
                return prepared
            }
            let fresh = PreparedGlossary(terms: activeTerms)
            prepared = fresh
            return fresh
        }

        /// The state a warm process carries from an earlier utterance: the cached engine and,
        /// when memoizing, the prepared glossary.
        func warm(activeTerms: [ProtectedTerm]) {
            _ = repairEngine(for: activeTerms)
            if memoize {
                _ = preparedGlossary(for: activeTerms)
            }
        }

        /// The timed unit, as `ProductionTextPath.process`.
        @inline(never)
        func process(_ rawTranscript: String, activeTerms: [ProtectedTerm]) -> String {
            let composed = LiteralComposition.apply(rawTranscript)
            let cleaned = clean(composed, activeTerms: activeTerms)
            if let engine = repairEngine(for: activeTerms) {
                return engine.repair(cleaned).text
            }
            return cleaned
        }

        func processStages(_ rawTranscript: String, activeTerms: [ProtectedTerm]) -> (
            composed: String, cleaned: String, outcome: RepairOutcome?
        ) {
            let composed = LiteralComposition.apply(rawTranscript)
            let cleaned = clean(composed, activeTerms: activeTerms)
            let outcome = repairEngine(for: activeTerms).map { $0.repair(cleaned) }
            return (composed, cleaned, outcome)
        }
    }

    // MARK: - VocabularyCompiler.compile (Vocabulary.swift:86-142)

    /// Plain values only. `Date` is a resilient Foundation type: a key holding one is copied
    /// through runtime value witnesses on every move of the sort, so the recency is kept as the
    /// `TimeInterval` that `Date`'s `==` and `<` compare.
    private struct SortKey {
        var trust: Int
        var recency: TimeInterval
        var offset: Int
        var priority: Bool
    }

    /// `VocabularyCompiler.compile(persistent:ephemeral: [], limit:now:).terms`.
    ///
    /// Production sorts `(offset, ProtectedTerm)` pairs, so every merge step copies a term (about
    /// ten reference-counted fields and an optional `Date`) and every comparison re-derives
    /// `recency(of:)`: 90% of a 5,000-term compile. This sorts the same keys, computed once per
    /// term, under the same comparator from the same initial order, so the sort yields the same
    /// permutation; the three passes then read the keys in that order.
    static func compile(persistent: [ProtectedTerm], limit: Int = 100, now: Date = Date()) -> [ProtectedTerm] {
        persistent.withUnsafeBufferPointer { terms in
            var keys: [SortKey] = []
            keys.reserveCapacity(terms.count)
            for offset in terms.indices where terms[offset].tombstonedAt.map({ $0 > now }) ?? true {
                var latest = Date.distantPast
                for alias in terms[offset].labeledAliases where alias.rejectedAt == nil {
                    if let confirmed = alias.confirmedAt, confirmed > latest {
                        latest = confirmed
                    }
                }
                keys.append(
                    SortKey(
                        trust: trustRank(terms[offset].source),
                        recency: latest.timeIntervalSinceReferenceDate,
                        offset: offset,
                        priority: terms[offset].source == .explicitCorrection || terms[offset].protected
                    ))
            }
            keys.sort { lhs, rhs in
                if lhs.trust != rhs.trust { return lhs.trust > rhs.trust }
                if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
                return lhs.offset < rhs.offset
            }

            let effectiveLimit = max(0, limit)
            var selected: [ProtectedTerm] = []
            selected.reserveCapacity(min(effectiveLimit, keys.count))
            // `sourceQuota`, indexed by trust rank: bundled, appProfile, manualImport, explicitCorrection.
            let quota = [40, 40, 60, Int.max]
            var perSource = [0, 0, 0, 0]
            var deferred: [Int] = []

            for key in keys where key.priority {
                guard selected.count < effectiveLimit else { break }
                selected.append(terms[key.offset])
            }
            for key in keys where !key.priority {
                guard selected.count < effectiveLimit else { break }
                let used = perSource[key.trust]
                if used < quota[key.trust] {
                    perSource[key.trust] = used + 1
                    selected.append(terms[key.offset])
                } else {
                    deferred.append(key.offset)
                }
            }
            if selected.count < effectiveLimit {
                for offset in deferred {
                    guard selected.count < effectiveLimit else { break }
                    selected.append(terms[offset])
                }
            }
            return selected
        }
    }

    /// `TermSource.trustRank` (internal in VoiceCore).
    private static func trustRank(_ source: TermSource) -> Int {
        switch source {
        case .explicitCorrection: 3
        case .manualImport: 2
        case .appProfile: 1
        case .bundled: 0
        }
    }

    // MARK: - RepairVocabulary.fromActiveTerms (VocabularyRepair.swift:38-65)

    /// The partition `RepairVocabulary.fromActiveTerms` computes, without the
    /// `Array(ordinaryWords)` copy of the 234,456-word set that the engine never reads when the
    /// prepared set is supplied (the app always supplies it).
    static func partition(_ activeTerms: [ProtectedTerm], ordinaryWords: Set<String>) -> (
        surfaces: [String], protected: [String]
    ) {
        var eligible: [String] = []
        var protected: [String] = []
        eligible.reserveCapacity(activeTerms.count)
        protected.reserveCapacity(activeTerms.count)
        for term in activeTerms {
            let canonical = term.canonical
            if ordinaryWords.contains(canonical.lowercased()) || canonical.count <= 2 {
                protected.append(canonical)
            } else {
                eligible.append(canonical)
            }
        }
        return (eligible, protected)
    }

    // MARK: - Byte-exact comparison

    /// Whether two strings hold the same UTF-8 bytes. `==` is canonical equivalence, which would
    /// let a cache keep a composed canonical after an edit to its decomposed spelling.
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        let contiguous = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                left.count == right.count
                    && (left.isEmpty || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0)
            }
        }
        if let contiguous, let answer = contiguous {
            return answer
        }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
}

extension Optimized {
    /// One term's `Glossary.canonicalize` work: its escaped template and the compiled expression
    /// of every matching alias, in production order.
    struct CanonicalizeRule {
        let template: String
        let expressions: [NSRegularExpression]
    }

    /// What `CleanupEngine.clean` re-derives from the glossary on every call, derived once.
    final class PreparedGlossary {
        let terms: [ProtectedTerm]
        /// `CleanupEngine.fragileSurfaces(in:)`.
        let fragile: [[String]]
        /// `shouldSkipToken`'s glossary scan (`([canonical] + userAliases).lowercased()` of every
        /// term) as one set: `Set<String>` hashes consistently with `==`, the comparison the scan
        /// makes, so membership answers exactly what the scan answered.
        let skipSurfaces: Set<String>
        let rules: [CanonicalizeRule]

        init(terms: [ProtectedTerm]) {
            self.terms = terms
            var skipSurfaces: Set<String> = []
            for term in terms {
                for surface in [term.canonical] + Glossary.userAliases(for: term) {
                    skipSurfaces.insert(surface.lowercased())
                }
            }
            self.skipSurfaces = skipSurfaces
            self.fragile = Cleanup.fragileSurfaces(in: terms)
            self.rules = terms.map { term in
                CanonicalizeRule(
                    template: NSRegularExpression.escapedTemplate(for: term.renderedCanonical),
                    expressions: Cleanup.matchingAliases(for: term).compactMap(Cleanup.aliasRegex)
                )
            }
        }

        /// Equal in every field `clean` reads: canonical (and with it the rendered canonical),
        /// case policy, spoken aliases, labeled alias surfaces and whether each is rejected.
        func isPrepared(for other: [ProtectedTerm]) -> Bool {
            guard terms.count == other.count else { return false }
            for (lhs, rhs) in zip(terms, other) {
                guard lhs.casePolicy == rhs.casePolicy,
                    Optimized.sameBytes(lhs.canonical, rhs.canonical),
                    lhs.spokenAliases.count == rhs.spokenAliases.count,
                    lhs.labeledAliases.count == rhs.labeledAliases.count
                else { return false }
                for (left, right) in zip(lhs.spokenAliases, rhs.spokenAliases) where !Optimized.sameBytes(left, right) {
                    return false
                }
                for (left, right) in zip(lhs.labeledAliases, rhs.labeledAliases) {
                    guard (left.rejectedAt == nil) == (right.rejectedAt == nil),
                        Optimized.sameBytes(left.surface, right.surface)
                    else { return false }
                }
            }
            return true
        }
    }
}
