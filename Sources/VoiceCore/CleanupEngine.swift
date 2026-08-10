import Foundation

public enum CleanupEngine {
    static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "mmm", "hmm"]

    public static func clean(_ raw: String, glossary: [ProtectedTerm]) -> String {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return "" }
        let fragile = fragileSurfaces(in: glossary)
        let noFillers = removeFillers(from: normalized, glossary: glossary, fragile: fragile)
        let deduped = collapseAdjacentRepeats(in: noFillers, fragile: fragile)
        let canonical = Glossary.canonicalize(deduped, terms: glossary)
        return canonical.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let stripped = strippedToken(value).lowercased()
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
                    .map { strippedToken(String($0)).lowercased() }
                guard !words.contains(where: \.isEmpty) else { continue }
                fragile.append(words)
            }
        }
        return fragile
    }

    /// Token positions covered by an occurrence of a fragile surface.
    private static func shelteredIndices(in tokens: [String], fragile: [[String]]) -> Set<Int> {
        guard !fragile.isEmpty else { return [] }
        let haystack = tokens.map { strippedToken($0).lowercased() }
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
        token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    private static func shouldSkipToken(_ token: String, glossary: [ProtectedTerm]) -> Bool {
        if token.hasPrefix("-") { return true }
        if token.contains("/") || token.contains("~") || token.contains("_") { return true }
        if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        if hasInternalCapital(token) { return true }
        let stripped = strippedToken(token).lowercased()
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
