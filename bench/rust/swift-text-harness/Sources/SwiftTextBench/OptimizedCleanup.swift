import Foundation
import VoiceCore

extension Optimized {
    /// `CleanupEngine` (Sources/VoiceCore/CleanupEngine.swift) and `Glossary.canonicalize`
    /// (Glossary.swift:58-112), copied pass for pass. The one change: the glossary-derived values
    /// come from a `PreparedGlossary` instead of being derived again on every call. Per call,
    /// production runs `fragileSurfaces(in:)` (every surface through `normalize`, `removeFillers`
    /// and `collapseAdjacentRepeats`), `Glossary.userAliases(for:)` for every term for every
    /// token `shouldSkipToken` checks, and, for every term, `matchingAliases(for:)` (five
    /// `.regularExpression` replacements in `canonicalTokens`) plus one `NSRegularExpression`
    /// compile per alias.
    enum Cleanup {
        static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "mmm", "hmm"]

        static func clean(_ raw: String, glossary: PreparedGlossary) -> String {
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return "" }
            let fragile = glossary.fragile
            let skip = glossary.skipSurfaces
            let noFillers = removeFillers(from: normalized, skipSurfaces: skip, fragile: fragile)
            let deduped = collapseAdjacentRepeats(in: noFillers, fragile: fragile)
            let recased = restoreSentenceCase(in: deduped, original: normalized, skipSurfaces: skip, fragile: fragile)
            return canonicalize(recased, rules: glossary.rules).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func restoreSentenceCase(
            in text: String,
            original: String,
            skipSurfaces: Set<String>,
            fragile: [[String]]
        ) -> String {
            var tokens = text.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return text }
            let source = original.split(separator: " ").map(String.init)
            let sheltered = shelteredIndices(in: tokens, fragile: fragile)

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
                guard startsCapitalized(sentenceOpener(of: origin, in: source)) else { continue }

                let token = tokens[index]
                guard !shouldSkipToken(token, skipSurfaces: skipSurfaces) else { continue }
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
            skipSurfaces: Set<String>,
            fragile: [[String]]
        ) -> String {
            let tokens = text.split(separator: " ").map(String.init)
            let sheltered = shelteredIndices(in: tokens, fragile: fragile)
            return tokens.enumerated().compactMap { index, value -> String? in
                guard !sheltered.contains(index) else { return value }
                guard !shouldSkipToken(value, skipSurfaces: skipSurfaces) else { return value }
                let stripped = strippedToken(value)
                return fillers.contains(stripped) ? nil : value
            }.joined(separator: " ")
        }

        /// `fragileSurfaces(in:)`, run once per glossary by `PreparedGlossary`. Its inner passes
        /// get an empty glossary, as in production.
        static func fragileSurfaces(in glossary: [ProtectedTerm]) -> [[String]] {
            var fragile: [[String]] = []
            for term in glossary {
                for surface in [term.canonical] + Glossary.userAliases(for: term) {
                    let normalized = normalize(surface)
                    guard normalized.contains(" ") else { continue }
                    guard
                        removeFillers(from: normalized, skipSurfaces: [], fragile: []) != normalized
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

        /// Production ends with a scan over every term's `[canonical] + userAliases(for:)`,
        /// lowercasing each surface; here that scan is one lookup in the prepared set.
        private static func shouldSkipToken(_ token: String, skipSurfaces: Set<String>) -> Bool {
            if token.hasPrefix("-") { return true }
            if token.contains("/") || token.contains("~") || token.contains("_") { return true }
            if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
            if hasInternalCapital(token) { return true }
            return skipSurfaces.contains(strippedToken(token))
        }

        private static func hasInternalCapital(_ token: String) -> Bool {
            let letters = Array(token)
            guard letters.count > 1 else { return false }
            for char in letters.dropFirst() where char.isUppercase {
                return true
            }
            return false
        }

        // MARK: - Glossary.canonicalize

        private struct AliasReplacement {
            let regex: NSRegularExpression
            let range: NSRange
            let replacementTemplate: String
            let discoveryOrder: Int
        }

        /// `Glossary.canonicalize(_:terms:)` over prepared rules: the same expressions in the same
        /// order, so the same matches, discovery order, acceptance and replacements.
        static func canonicalize(_ text: String, rules: [CanonicalizeRule]) -> String {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            var replacements: [AliasReplacement] = []
            var discoveryOrder = 0

            for rule in rules {
                for regex in rule.expressions {
                    for match in regex.matches(in: text, range: fullRange) {
                        replacements.append(
                            AliasReplacement(
                                regex: regex,
                                range: match.range,
                                replacementTemplate: rule.template,
                                discoveryOrder: discoveryOrder
                            )
                        )
                        discoveryOrder += 1
                    }
                }
            }

            replacements.sort { lhs, rhs in
                if lhs.range.length != rhs.range.length {
                    return lhs.range.length > rhs.range.length
                }
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.discoveryOrder < rhs.discoveryOrder
            }

            var accepted: [AliasReplacement] = []
            for replacement in replacements {
                let overlaps = accepted.contains {
                    NSIntersectionRange($0.range, replacement.range).length > 0
                }
                if !overlaps {
                    accepted.append(replacement)
                }
            }

            let result = NSMutableString(string: text)
            for replacement in accepted.sorted(by: { $0.range.location > $1.range.location }) {
                replacement.regex.replaceMatches(
                    in: result,
                    range: replacement.range,
                    withTemplate: replacement.replacementTemplate
                )
            }
            return result as String
        }

        /// `Glossary.matchingAliases(for:)` (internal in VoiceCore).
        static func matchingAliases(for term: ProtectedTerm) -> [String] {
            var aliases: [String] = []
            var seen = Set<String>()
            for alias in [term.canonical] + generalizableAliases(for: term) {
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

        private static func generalizableAliases(for term: ProtectedTerm) -> [String] {
            (Glossary.userAliases(for: term) + Glossary.derivedAliases(for: term.canonical))
                .filter { Glossary.aliasCanGeneralize($0, canonical: term.canonical) }
        }

        private static func aliasKey(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        /// `Glossary.aliasRegex(_:)` (private in VoiceCore).
        static func aliasRegex(_ alias: String) -> NSRegularExpression? {
            let parts = alias.split(whereSeparator: { $0.isWhitespace }).map {
                NSRegularExpression.escapedPattern(for: String($0))
            }
            guard !parts.isEmpty else { return nil }
            let pattern = "(?i)(?<![A-Za-z0-9_])" + parts.joined(separator: "\\s+") + "(?![A-Za-z0-9_])"
            return try? NSRegularExpression(pattern: pattern)
        }
    }
}
