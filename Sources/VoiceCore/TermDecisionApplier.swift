/// Turns authorizer `.replace` verdicts into concrete, fail-safe text edits.
///
/// The applier is a pure function that bridges `RiskAuthorizer` decisions to
/// `TermPatchRenderer`. It:
///
/// 1. Pairs each decision with its candidate positionally (`decisions[i]`
///    describes `candidates[i]`); a count mismatch is an inconsistency and the
///    transcript is returned untouched.
/// 2. Acts only on `.replace` decisions — `.keep` and `.suggest` never mutate
///    text.
/// 3. Re-validates every span against the *current* transcript (stale-span
///    rejection): the span must be in range and must still designate a whole,
///    non-empty word run. A span left over from an earlier transcript that now
///    runs out of bounds or cuts into a word is dropped rather than applied at
///    the wrong place.
/// 4. Resolves each term's stored `renderedCanonical` from the supplied resolved
///    term list. The replacement text is *always* the stored canonical; the
///    applier never emits the candidate's raw canonical, the misheard surface,
///    or any model-authored string. An unresolvable term id is dropped.
/// 5. Resolves overlaps *before* rendering by keeping the strongest authorized
///    patch for a region and dropping the weaker ones it covers. Retrieval
///    enumerates every 1...5-word run, so a real alias hit ("neuro doc") is
///    routinely accompanied by weaker superset spans ("use neuro doc"); handing
///    all of them to the renderer would trip its overlap veto and silently drop
///    every authorized correction.
/// 6. Delegates the actual substitution to `TermPatchRenderer`, which rejects
///    overlapping or out-of-range patch sets and returns the original transcript
///    on any inconsistency — so overlaps can never produce a partial rewrite.
public enum TermDecisionApplier {
    private struct CandidateKey: Hashable {
        let termId: String
        let spanStart: Int
        let spanLength: Int
    }

    /// Applies the `.replace` decisions to `transcript`, using `terms` to resolve
    /// canonical text, and returns the rewritten transcript (or the original,
    /// unchanged, on any inconsistency).
    ///
    /// - Parameters:
    ///   - decisions: one verdict per candidate, positionally aligned with
    ///     `candidates`.
    ///   - candidates: the candidates the decisions were made about; each
    ///     supplies the span to edit.
    ///   - terms: the resolved term list used to look up `renderedCanonical` by
    ///     `termId`.
    ///   - transcript: the current transcript to edit.
    public static func apply(
        decisions: [AuthorizerDecision],
        candidates: [TermCandidate],
        terms: [ProtectedTerm],
        to transcript: String
    ) -> String {
        // A misaligned pairing cannot be safely interpreted; leave text as-is.
        guard decisions.count == candidates.count else { return transcript }

        // termId -> stored canonical. The resolved list is trust-ordered, so the
        // first entry for a duplicated id wins.
        var canonicalById: [String: String] = [:]
        for term in terms where canonicalById[term.termId] == nil {
            canonicalById[term.termId] = term.renderedCanonical
        }

        let characters = Array(transcript)
        var patches: [TermPatch] = []

        for (decision, candidate) in zip(decisions, candidates) {
            guard case .replace(let termId) = decision else { continue }

            // The decision must describe this candidate.
            guard termId == candidate.termId else { continue }

            // Resolve the stored canonical; without it we would have to author
            // text, so we drop the edit.
            guard let replacement = canonicalById[termId] else { continue }

            // Stale-span rejection: the span must still designate a valid,
            // whole-word run on the current transcript.
            guard
                spanIsCurrent(
                    characters,
                    start: candidate.spanStart,
                    length: candidate.spanLength
                )
            else { continue }

            patches.append(
                TermPatch(
                    spanStart: candidate.spanStart,
                    spanLength: candidate.spanLength,
                    replacement: replacement,
                    termId: termId
                )
            )
        }

        // The renderer is the single fail-safe gate for overlaps / out-of-range.
        return TermPatchRenderer.apply(resolvingOverlaps(patches, candidates: candidates), to: transcript)
    }

    /// Deterministically reduces `patches` to a non-overlapping set.
    ///
    /// Patches are ranked by the blended acoustic/textual signal of the
    /// candidate that produced them — the same measure the retriever ranks with
    /// — then by longer span, earlier start, and term id, so the selection is a
    /// total order and never depends on input ordering. A patch is kept only
    /// when it overlaps nothing already kept; the renderer still vetoes any set
    /// that slips through, so this can only ever narrow what is applied.
    private static func resolvingOverlaps(
        _ patches: [TermPatch],
        candidates: [TermCandidate]
    ) -> [TermPatch] {
        guard patches.count > 1 else { return patches }
        var signalByCandidateKey: [CandidateKey: Double] = [:]
        for candidate in candidates {
            let key = CandidateKey(
                termId: candidate.termId,
                spanStart: candidate.spanStart,
                spanLength: candidate.spanLength
            )
            let signal = CandidateRetriever.matchSignal(
                phone: candidate.phoneSimilarity,
                text: candidate.textSimilarity
            )
            signalByCandidateKey[key] = max(signalByCandidateKey[key] ?? signal, signal)
        }

        func signal(for patch: TermPatch) -> Double {
            signalByCandidateKey[
                CandidateKey(
                    termId: patch.termId,
                    spanStart: patch.spanStart,
                    spanLength: patch.spanLength
                )
            ] ?? 0
        }

        let ranked = patches.sorted { lhs, rhs in
            let lhsSignal = signal(for: lhs)
            let rhsSignal = signal(for: rhs)
            if lhsSignal != rhsSignal { return lhsSignal > rhsSignal }
            if lhs.spanLength != rhs.spanLength { return lhs.spanLength > rhs.spanLength }
            if lhs.spanStart != rhs.spanStart { return lhs.spanStart < rhs.spanStart }
            return lhs.termId < rhs.termId
        }

        var kept: [TermPatch] = []
        kept.reserveCapacity(ranked.count)
        for patch in ranked {
            let start = patch.spanStart
            let end = patch.spanStart + patch.spanLength
            let overlaps = kept.contains { other in
                start < other.spanStart + other.spanLength && other.spanStart < end
            }
            if !overlaps { kept.append(patch) }
        }
        return kept
    }

    /// Whether `[start, start+length)` still designates a whole, non-empty word
    /// run in `characters`. A stale span from a mutated transcript typically runs
    /// out of range or lands mid-word; both are rejected here.
    private static func spanIsCurrent(_ characters: [Character], start: Int, length: Int) -> Bool {
        guard start >= 0, length > 0, start + length <= characters.count else { return false }
        let end = start + length

        // Edges must be word characters (the surface is a real token run, not
        // whitespace or punctuation).
        guard isWordCharacter(characters[start]), isWordCharacter(characters[end - 1]) else {
            return false
        }
        // Neighbours must not be word characters, i.e. the span is not a fragment
        // of a larger word created by a transcript edit.
        if start > 0, isWordCharacter(characters[start - 1]) { return false }
        if end < characters.count, isWordCharacter(characters[end]) { return false }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
