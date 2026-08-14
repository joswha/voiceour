import Foundation

public enum CleanupEngine {
    static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "mmm", "hmm"]

    public static func clean(_ raw: String, glossary: [ProtectedTerm]) -> String {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return "" }
        let fragile = fragileSurfaces(in: glossary)
        let noFillers = removeFillers(from: normalized, glossary: glossary, fragile: fragile)
        let deduped = collapseAdjacentRepeats(in: noFillers, fragile: fragile)
        let recased = restoreSentenceCase(
            in: deduped,
            original: normalized,
            glossary: glossary,
            fragile: fragile
        )
        let canonical = Glossary.canonicalize(recased, terms: glossary)
        return canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-capitalizes a word that one of the deletion passes promoted to the start
    /// of a sentence.
    ///
    /// `removeFillers` and `collapseAdjacentRepeats` only delete tokens, so a
    /// survivor can inherit a sentence-initial position it never had. The recogniser
    /// capitalized the word it *did* put there, and deleting that word left the
    /// successor in lower case. Measured on 218 refinement-skipped real sessions,
    /// 16 of them (7.3%) came out with a lower-case opening letter the raw
    /// transcript did not have:
    ///
    ///     "Uh let's do a cleanup over the surfaces"  ->  "let's do a cleanup ..."
    ///     "... concept of a thread. Um basically our platform"
    ///                                            ->  "... a thread. basically our platform"
    ///
    /// Only all-lower-case tokens are touched, and only those `shouldSkipToken`
    /// already declines to treat as ordinary words, so identifiers, paths, numbers,
    /// internally-capitalised names like `iPhone` and every glossary surface are left
    /// exactly as they were. This runs before canonicalization so a term's own casing
    /// still has the final word.
    private static func restoreSentenceCase(
        in text: String,
        original: String,
        glossary: [ProtectedTerm],
        fragile: [[String]]
    ) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return text }
        let source = original.split(separator: " ").map(String.init)
        let sheltered = shelteredIndices(in: tokens, fragile: fragile)

        // Both deletion passes preserve order and never rewrite a survivor, so the
        // output is a subsequence of the input and a greedy walk recovers where each
        // survivor came from. That is what makes the repair surgical: a token is only
        // touched when the cleanup itself moved it to the front of a sentence.
        var sourceIndex = 0
        for index in tokens.indices {
            while sourceIndex < source.count, source[sourceIndex] != tokens[index] {
                sourceIndex += 1
            }
            guard sourceIndex < source.count else { break }
            let origin = sourceIndex
            sourceIndex += 1

            let initialNow = index == 0 || endsSentence(tokens[index - 1])
            let initialBefore = origin == 0 || endsSentence(source[origin - 1])
            guard initialNow, !initialBefore, !sheltered.contains(index) else { continue }

            // Take the casing convention from the word that used to hold this slot
            // rather than imposing one. If the recogniser capitalised it, the text
            // capitalises sentences and the survivor should too; if it was already
            // lower case, the text is not using sentence case and must be left alone.
            guard startsCapitalized(sentenceOpener(of: origin, in: source)) else { continue }

            let token = tokens[index]
            guard !shouldSkipToken(token, glossary: glossary) else { continue }
            guard token.contains(where: \.isLowercase), !token.contains(where: \.isUppercase) else {
                continue
            }
            tokens[index] = capitalizingFirstLetter(token)
        }

        return tokens.joined(separator: " ")
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last(where: { !$0.isWhitespace }) else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// The token that opened the sentence containing `index`, in the pre-cleanup
    /// token list. That is the word whose capitalization records what convention the
    /// recogniser was using for this sentence.
    private static func sentenceOpener(of index: Int, in source: [String]) -> String? {
        var start = index
        while start > 0, !endsSentence(source[start - 1]) {
            start -= 1
        }
        return start < source.count ? source[start] : nil
    }

    private static func startsCapitalized(_ token: String?) -> Bool {
        guard let letter = token?.first(where: \.isLetter) else { return false }
        return letter.isUppercase
    }

    /// Uppercases the first letter and leaves everything after it alone, so a
    /// leading quote or bracket survives and no other character is disturbed.
    private static func capitalizingFirstLetter(_ token: String) -> String {
        guard let position = token.firstIndex(where: \.isLetter) else { return token }
        return token.replacingCharacters(
            in: position...position,
            with: token[position].uppercased()
        )
    }

    static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeFillers(
        from text: String,
        glossary: [ProtectedTerm],
        fragile: [[String]]
    ) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        let sheltered = shelteredIndices(in: tokens, fragile: fragile)
        return tokens.enumerated().compactMap { index, value -> String? in
            guard !sheltered.contains(index) else { return value }
            guard !shouldSkipToken(value, glossary: glossary) else { return value }
            let stripped = strippedToken(value)
            return fillers.contains(stripped) ? nil : value
        }.joined(separator: " ")
    }

    /// Glossary surfaces that the passes ahead of canonicalization would themselves
    /// damage, tokenized so their occurrences can be found in a transcript.
    ///
    /// A surface taught from a transcript carries whatever the recogniser put in
    /// it — a hesitation ("cube uh cuddle") or a stutter ("the the Ubun"). Filler
    /// removal and repeat collapsing both run before `Glossary.canonicalize`, so
    /// left alone they rewrite the very span the surface needs in order to match,
    /// and the correction the user taught can never fire again. `shouldSkipToken`
    /// cannot cover this: it compares one token against whole surfaces, so it only
    /// ever shelters a one-word entry.
    ///
    /// Fragility is decided by running the passes, not by restating their rules —
    /// a predicate spelled out here would drift the first time either pass learns
    /// a new trick. Ordinary vocabulary is not fragile, so this is empty in the
    /// common case and both passes skip the span scan entirely.
    private static func fragileSurfaces(in glossary: [ProtectedTerm]) -> [[String]] {
        var fragile: [[String]] = []
        for term in glossary {
            for surface in [term.canonical] + Glossary.userAliases(for: term) {
                let normalized = normalize(surface)
                guard normalized.contains(" ") else { continue }
                guard
                    removeFillers(from: normalized, glossary: [], fragile: []) != normalized
                        || collapseAdjacentRepeats(in: normalized, fragile: []) != normalized
                else { continue }
                let words =
                    normalized
                    .split(separator: " ")
                    .map { strippedToken(String($0)) }
                guard !words.contains(where: \.isEmpty) else { continue }
                fragile.append(words)
            }
        }
        return fragile
    }

    /// Token positions covered by an occurrence of a fragile surface.
    private static func shelteredIndices(in tokens: [String], fragile: [[String]]) -> Set<Int> {
        guard !fragile.isEmpty else { return [] }
        let haystack = tokens.map { strippedToken($0) }
        var sheltered: Set<Int> = []
        for words in fragile where haystack.count >= words.count {
            for start in 0...(haystack.count - words.count)
            where Array(haystack[start..<(start + words.count)]) == words {
                sheltered.formUnion(start..<(start + words.count))
            }
        }
        return sheltered
    }

    private static func collapseAdjacentRepeats(in text: String, fragile: [[String]]) -> String {
        let pieces = text.split(separator: " ").map(String.init)
        let sheltered = shelteredIndices(in: pieces, fragile: fragile)
        var result: [String] = []
        var index = 0

        while index < pieces.count {
            let maximumLength = min(4, (pieces.count - index) / 2)
            var repeatedLength: Int?

            if maximumLength > 0 {
                for length in stride(from: maximumLength, through: 1, by: -1) {
                    // A repeat that reaches into a taught surface is that surface's
                    // own stutter. Shorter lengths are still tried, so a genuine
                    // repeat clear of the span still collapses.
                    guard !(index..<index + (2 * length)).contains(where: sheltered.contains) else { continue }
                    let first = pieces[index..<index + length].map {
                        normalizedRepeatToken($0, phraseLength: length)
                    }
                    guard !first.contains(where: \.isEmpty) else { continue }
                    let second = pieces[index + length..<index + (2 * length)].map {
                        normalizedRepeatToken($0, phraseLength: length)
                    }
                    if first == second {
                        repeatedLength = length
                        break
                    }
                }
            }

            if let repeatedLength {
                result.append(contentsOf: pieces[index + repeatedLength..<index + (2 * repeatedLength)])
                index += 2 * repeatedLength
            } else {
                result.append(pieces[index])
                index += 1
            }
        }

        return result.joined(separator: " ")
    }

    private static func normalizedRepeatToken(_ token: String, phraseLength: Int) -> String {
        guard phraseLength > 1 else {
            var normalized = token.lowercased()
            while normalized.last == "," || normalized.last == "." {
                normalized.removeLast()
            }
            return normalized
        }
        return token.components(separatedBy: .punctuationCharacters).joined().lowercased()
    }

    private static func strippedToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)).lowercased()
    }

    private static func shouldSkipToken(_ token: String, glossary: [ProtectedTerm]) -> Bool {
        if token.hasPrefix("-") { return true }
        if token.contains("/") || token.contains("~") || token.contains("_") { return true }
        if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        if hasInternalCapital(token) { return true }
        let stripped = strippedToken(token)
        for term in glossary {
            // Filler removal runs before canonicalization, so a surface whose own
            // words include a filler ("cube uh cuddle") is only reachable if that
            // token is protected here first. Both alias stores count: an alias the
            // user taught lives in `labeledAliases`, not `spokenAliases`.
            let surfaces = [term.canonical] + Glossary.userAliases(for: term)
            if surfaces.contains(where: { $0.lowercased() == stripped }) {
                return true
            }
        }
        return false
    }

    private static func hasInternalCapital(_ token: String) -> Bool {
        let letters = Array(token)
        guard letters.count > 1 else { return false }
        for char in letters.dropFirst() where char.isUppercase {
            return true
        }
        return false
    }
}
