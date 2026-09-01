import Foundation

public struct RepairVocabulary: Codable {
    public static let currentSchema = "voiceour-repair-vocabulary-v1"

    public var ordinaryWords: [String]
    public var ordinaryWordsSHA256: String
    public var phoneticThreshold: Double
    public var protectedSurfaces: [String]
    public var provenance: [String: String]
    public var schema: String
    public var singleLetterWords: [String]
    public var surfaces: [String]

    public init(
        surfaces: [String],
        protectedSurfaces: [String] = [],
        phoneticThreshold: Double = 0.95,
        ordinaryWords: [String] = [],
        ordinaryWordsSHA256: String = "",
        singleLetterWords: [String] = ["a", "i"],
        provenance: [String: String] = [:],
        schema: String = RepairVocabulary.currentSchema
    ) {
        self.ordinaryWords = ordinaryWords
        self.ordinaryWordsSHA256 = ordinaryWordsSHA256
        self.phoneticThreshold = phoneticThreshold
        self.protectedSurfaces = protectedSurfaces
        self.provenance = provenance
        self.schema = schema
        self.singleLetterWords = singleLetterWords
        self.surfaces = surfaces
    }

    enum CodingKeys: String, CodingKey {
        case ordinaryWords = "ordinary_words"
        case ordinaryWordsSHA256 = "ordinary_words_sha256"
        case phoneticThreshold = "phonetic_threshold"
        case protectedSurfaces = "protected_surfaces"
        case provenance
        case schema
        case singleLetterWords = "single_letter_words"
        case surfaces
    }
}

public struct RepairEvent: Codable, Equatable {
    public var start: Int
    public var end: Int
    public var before: String
    public var after: String
    public var kind: String
    public var score: Double

    public init(start: Int, end: Int, before: String, after: String, kind: String, score: Double) {
        self.start = start
        self.end = end
        self.before = before
        self.after = after
        self.kind = kind
        self.score = score
    }
}

public struct RepairOutcome: Codable, Equatable {
    public var text: String
    public var events: [RepairEvent]

    public init(text: String, events: [RepairEvent]) {
        self.text = text
        self.events = events
    }
}

/// Deterministic vocabulary-only transcript repair.
///
/// Construction performs all vocabulary-dependent work. `repair(_:)` has no I/O or
/// externally observable state and can therefore be reused for every utterance in a run.
public struct VocabularyRepairEngine {
    private static let epsilon = 1e-12
    private static let maximumWindowWords = 5

    private let surfaces: [Surface]
    private let lexicalPatterns: [LexicalPattern]
    private let protectedPatterns: [ProtectedPattern]
    private let ordinaryWords: Set<String>
    private let singleLetterWords: Set<String>
    private let phoneticThreshold: Double
    private let tokenPattern: NSRegularExpression

    public init(vocabulary: RepairVocabulary) {
        let orderedCanonicals = Array(Set(vocabulary.surfaces)).sorted()
        var canonicalOwners: [String: Set<String>] = [:]
        var rawAliases: [String: [String]] = [:]

        for canonical in orderedCanonicals {
            canonicalOwners[Self.casefold(Self.normalizedWhitespace(canonical)), default: []].insert(canonical)
            rawAliases[canonical] = Self.derivedAliases(for: canonical)
        }

        var aliasOwners = canonicalOwners
        for canonical in orderedCanonicals {
            for alias in rawAliases[canonical, default: []] {
                aliasOwners[Self.casefold(alias), default: []].insert(canonical)
            }
        }

        var compiledSurfaces: [Surface] = []
        var compiledLexicalPatterns: [LexicalPattern] = []
        compiledSurfaces.reserveCapacity(orderedCanonicals.count)

        for (rank, canonical) in orderedCanonicals.enumerated() {
            let aliases = rawAliases[canonical, default: []]
                .filter { aliasOwners[Self.casefold($0)] == Set([canonical]) }
                .sorted { left, right in
                    if left.count != right.count { return left.count > right.count }
                    let leftFolded = Self.casefold(left)
                    let rightFolded = Self.casefold(right)
                    if leftFolded != rightFolded { return leftFolded < rightFolded }
                    return left < right
                }

            var profiles: [KeyPair] = []
            var seenProfiles: Set<KeyPair> = []
            for surface in [canonical] + aliases {
                let profile = Self.keys(for: surface)
                if !profile.grapheme.isEmpty, seenProfiles.insert(profile).inserted {
                    profiles.append(profile)
                }
            }
            compiledSurfaces.append(Surface(canonical: canonical, rank: rank, profiles: profiles))

            compiledLexicalPatterns.append(
                LexicalPattern(
                    canonical: canonical,
                    canonicalRank: rank,
                    kind: "canonical",
                    expression: Self.aliasPattern(for: canonical)
                )
            )
            for alias in aliases {
                compiledLexicalPatterns.append(
                    LexicalPattern(
                        canonical: canonical,
                        canonicalRank: rank,
                        kind: "alias",
                        expression: Self.aliasPattern(for: alias)
                    )
                )
            }
        }

        let orderedProtected = Array(Set(vocabulary.protectedSurfaces)).sorted()
        self.protectedPatterns = orderedProtected.enumerated().map { discoveryOrder, surface in
            ProtectedPattern(
                canonical: surface,
                discoveryOrder: discoveryOrder,
                expression: Self.aliasPattern(for: surface)
            )
        }
        self.surfaces = compiledSurfaces
        self.lexicalPatterns = compiledLexicalPatterns
        self.ordinaryWords = Set(vocabulary.ordinaryWords.lazy.map(Self.casefold))
        self.singleLetterWords = Set(vocabulary.singleLetterWords.lazy.map(Self.casefold))
        self.phoneticThreshold = vocabulary.phoneticThreshold
        self.tokenPattern = try! NSRegularExpression(
            pattern: #"[A-Za-z0-9+#/_-]+(?:\.[A-Za-z0-9+#/_-]+)*"#
        )
    }

    public func repair(_ text: String) -> RepairOutcome {
        guard !surfaces.isEmpty else { return RepairOutcome(text: text, events: []) }

        let protected = protectedSpans(in: text)
        let lexical = Self.resolveLongest(lexicalMatches(in: text, protected: protected))
        let tokens = tokenMatches(in: text)
        var fuzzy: [Candidate] = []
        var discoveryOrder = (lexical.map(\.discoveryOrder).max() ?? -1) + 1

        let maximumWidth = min(Self.maximumWindowWords, tokens.count)
        if maximumWidth > 0 {
            for width in 1...maximumWidth {
                for startIndex in 0...(tokens.count - width) {
                    let endIndex = startIndex + width - 1
                    let start = tokens[startIndex].start
                    let end = tokens[endIndex].end
                    let matched = Self.substring(text, start: start, end: end)
                    let probe = Candidate(
                        start: start,
                        end: end,
                        canonical: "",
                        canonicalRank: 0,
                        kind: "phonetic",
                        score: 0,
                        discoveryOrder: 0,
                        matched: matched
                    )
                    if Self.overlaps(probe, any: lexical) || Self.overlaps(probe, any: protected) {
                        continue
                    }

                    let leftKeys = Self.keys(for: matched)
                    var bestSurface: Surface?
                    var bestScore = 0.0
                    for surface in surfaces {
                        let score = Self.score(leftKeys, against: surface.profiles)
                        if score > bestScore + Self.epsilon {
                            bestSurface = surface
                            bestScore = score
                        } else if abs(score - bestScore) <= Self.epsilon,
                                  let current = bestSurface,
                                  surface.rank < current.rank {
                            bestSurface = surface
                        }
                    }

                    if let bestSurface, bestScore + Self.epsilon >= phoneticThreshold {
                        fuzzy.append(
                            Candidate(
                                start: start,
                                end: end,
                                canonical: bestSurface.canonical,
                                canonicalRank: bestSurface.rank,
                                kind: "phonetic",
                                score: bestScore,
                                discoveryOrder: discoveryOrder,
                                matched: matched
                            )
                        )
                        discoveryOrder += 1
                    }
                }
            }
        }

        var accepted = lexical
        let eligible = fuzzy
            .filter { !isOrdinarySpan(text: $0.matched) }
            .sorted(by: Self.precedesForPhoneticAcceptance)
        for candidate in eligible where !Self.overlaps(candidate, any: accepted) {
            accepted.append(candidate)
        }
        return Self.apply(accepted, to: text)
    }

    private func protectedSpans(in text: String) -> [Candidate] {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var spans: [Candidate] = []
        for protectedPattern in protectedPatterns {
            for match in protectedPattern.expression.matches(in: text, range: searchRange) {
                spans.append(
                    Candidate(
                        start: match.range.location,
                        end: match.range.location + match.range.length,
                        canonical: protectedPattern.canonical,
                        canonicalRank: 0,
                        kind: "protected",
                        score: 1,
                        discoveryOrder: protectedPattern.discoveryOrder,
                        matched: Self.substring(text, range: match.range)
                    )
                )
            }
        }
        return spans
    }

    private func lexicalMatches(in text: String, protected: [Candidate]) -> [Candidate] {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [Candidate] = []
        var discoveryOrder = 0

        for lexicalPattern in lexicalPatterns {
            for match in lexicalPattern.expression.matches(in: text, range: searchRange) {
                let candidate = Candidate(
                    start: match.range.location,
                    end: match.range.location + match.range.length,
                    canonical: lexicalPattern.canonical,
                    canonicalRank: lexicalPattern.canonicalRank,
                    kind: lexicalPattern.kind,
                    score: 1,
                    discoveryOrder: discoveryOrder,
                    matched: Self.substring(text, range: match.range)
                )
                discoveryOrder += 1
                if !Self.overlaps(candidate, any: protected) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private func tokenMatches(in text: String) -> [Token] {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return tokenPattern.matches(in: text, range: searchRange).map { match in
            Token(
                start: match.range.location,
                end: match.range.location + match.range.length,
                text: Self.substring(text, range: match.range)
            )
        }
    }

    private func isOrdinarySpan(text: String) -> Bool {
        let tokens = tokenMatches(in: text)
        guard tokens.count >= 2 else { return false }
        return tokens.allSatisfy { token in
            let folded = Self.casefold(token.text)
            guard Self.isASCIIAlpha(folded) else { return false }
            if folded.unicodeScalars.count == 1 {
                return singleLetterWords.contains(folded)
            }
            return ordinaryWords.contains(folded)
        }
    }

    private static func precedesForPhoneticAcceptance(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.score != right.score { return left.score > right.score }
        let leftLength = left.matched.unicodeScalars.count
        let rightLength = right.matched.unicodeScalars.count
        if leftLength != rightLength { return leftLength > rightLength }
        if left.start != right.start { return left.start < right.start }
        if left.canonicalRank != right.canonicalRank { return left.canonicalRank < right.canonicalRank }
        return left.discoveryOrder < right.discoveryOrder
    }

    private static func resolveLongest(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates.sorted { left, right in
            let leftLength = left.matched.unicodeScalars.count
            let rightLength = right.matched.unicodeScalars.count
            if leftLength != rightLength { return leftLength > rightLength }
            if left.start != right.start { return left.start < right.start }
            return left.discoveryOrder < right.discoveryOrder
        }
        var accepted: [Candidate] = []
        for candidate in ordered where !overlaps(candidate, any: accepted) {
            accepted.append(candidate)
        }
        return accepted
    }

    private static func overlaps(_ candidate: Candidate, any accepted: [Candidate]) -> Bool {
        accepted.contains { candidate.start < $0.end && $0.start < candidate.end }
    }

    private static func apply(_ candidates: [Candidate], to text: String) -> RepairOutcome {
        var output = text
        for candidate in candidates.sorted(by: { $0.start > $1.start }) {
            let range = NSRange(location: candidate.start, length: candidate.end - candidate.start)
            guard let stringRange = Range(range, in: output) else { continue }
            output.replaceSubrange(stringRange, with: candidate.canonical)
        }

        let events = candidates
            .sorted { $0.start < $1.start }
            .filter { $0.matched != $0.canonical }
            .map { candidate in
                RepairEvent(
                    start: scalarOffset(candidate.start, in: text),
                    end: scalarOffset(candidate.end, in: text),
                    before: candidate.matched,
                    after: candidate.canonical,
                    kind: candidate.kind,
                    score: candidate.score
                )
            }
        return RepairOutcome(text: output, events: events)
    }

    private static func scalarOffset(_ utf16Offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: utf16Offset, in: text)
        return text[..<index].unicodeScalars.count
    }

    private static func score(_ left: KeyPair, against profiles: [KeyPair]) -> Double {
        var best = 0.0
        for right in profiles {
            guard !left.grapheme.isEmpty, !right.grapheme.isEmpty else { continue }
            let graphemeScore = normalizedLevenshteinSimilarity(left.grapheme, right.grapheme)
            let phoneScore = normalizedLevenshteinSimilarity(left.phone, right.phone)
            let blended = 0.35 * graphemeScore + 0.65 * phoneScore
            best = max(best, max(graphemeScore, blended))
        }
        return best
    }

    private static func normalizedLevenshteinSimilarity(_ left: [UInt8], _ right: [UInt8]) -> Double {
        if left == right { return 1 }
        let length = max(left.count, right.count)
        guard length > 0 else { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for (leftIndex, leftByte) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightByte) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftByte == rightByte ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[right.count]) / Double(length)
    }

    private static func keys(for value: String) -> KeyPair {
        let grapheme = graphemeKey(value)
        return KeyPair(grapheme: grapheme, phone: phoneticKey(grapheme))
    }

    private static func graphemeKey(_ value: String) -> [UInt8] {
        let decomposed = value.decomposedStringWithCompatibilityMapping
        var ascii: [UInt8] = []
        ascii.reserveCapacity(decomposed.utf8.count)
        for scalar in decomposed.unicodeScalars where scalar.value < 128 {
            let byte = UInt8(scalar.value)
            ascii.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }

        var expanded: [UInt8] = []
        for byte in ascii {
            if let spoken = symbolWords[byte] {
                expanded.append(contentsOf: spoken)
            } else {
                expanded.append(byte)
            }
        }
        return expanded.filter { isASCIIAlphaNumeric($0) }
    }

    private static func phoneticKey(_ grapheme: [UInt8]) -> [UInt8] {
        var key = String(decoding: grapheme, as: UTF8.self)
        for (source, replacement) in phoneticReplacements {
            key = key.replacingOccurrences(of: source, with: replacement)
        }

        let bytes = Array(key.utf8)
        var transformed: [UInt8] = []
        transformed.reserveCapacity(bytes.count + 2)
        for index in bytes.indices {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == asciiC, next == asciiE || next == asciiI || next == asciiY {
                transformed.append(asciiS)
            } else if byte == asciiG, next == asciiE || next == asciiI || next == asciiY {
                transformed.append(asciiJ)
            } else {
                switch byte {
                case asciiX:
                    transformed.append(asciiK)
                    transformed.append(asciiS)
                case asciiQ, asciiC:
                    transformed.append(asciiK)
                case asciiZ:
                    transformed.append(asciiS)
                default:
                    transformed.append(byte)
                }
            }
        }

        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(transformed.count)
        for byte in transformed {
            let normalized = vowelBytes.contains(byte) ? asciiCapitalA : byte
            if collapsed.last != normalized {
                collapsed.append(normalized)
            }
        }
        return collapsed
    }

    private static func derivedAliases(for canonical: String) -> [String] {
        let tokens = canonicalTokens(canonical)
        var candidates: [String] = []

        if tokens.count >= 2 {
            candidates.append(tokens.joined(separator: " ").lowercased())
            candidates.append(
                tokens.map { token in
                    token.count >= 2 && isUppercaseASCII(token)
                        ? token.map(String.init).joined(separator: " ").lowercased()
                        : token.lowercased()
                }.joined(separator: " ")
            )

            let gapCount = tokens.count - 1
            let combinationCount = 1 << gapCount
            for combination in 0..<combinationCount {
                var value = ""
                for tokenIndex in tokens.indices {
                    value += tokens[tokenIndex]
                    if tokenIndex < gapCount {
                        let bit = gapCount - tokenIndex - 1
                        value += combination & (1 << bit) == 0 ? " " : ""
                    }
                }
                candidates.append(value.lowercased())
            }
        }

        let compactScalars = canonical.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let compact = String(String.UnicodeScalarView(compactScalars))
        if tokens.count == 1, compact.count >= 4, compact.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            let characters = Array(compact)
            if characters.count >= 4 {
                for split in 2..<(characters.count - 1) {
                    candidates.append(
                        (String(characters[..<split]) + " " + String(characters[split...])).lowercased()
                    )
                }
                candidates.append("\(characters[0])\(characters.count - 2)\(characters[characters.count - 1])".lowercased())
            }
        }

        let separatorForm = symbolVariant(canonical, nameSeparators: false)
        let spokenForm = symbolVariant(canonical, nameSeparators: true)
        candidates.append(separatorForm.lowercased())
        candidates.append(spokenForm.lowercased())
        candidates.append(digitSpoken(separatorForm).lowercased())
        candidates.append(digitSpoken(spokenForm).lowercased())

        let canonicalKey = casefold(normalizedWhitespace(canonical))
        var seen: Set<String> = [canonicalKey]
        var aliases: [String] = []
        for candidate in candidates {
            let alias = normalizedWhitespace(candidate)
            let key = casefold(alias)
            if !alias.isEmpty, seen.insert(key).inserted {
                aliases.append(alias)
            }
        }
        return aliases
    }

    private static func canonicalTokens(_ canonical: String) -> [String] {
        var tokenized = replacingMatches(in: canonical, pattern: #"[\s._-]+"#, template: " ")
        let boundaries = [
            (#"([A-Z]+)([A-Z][a-z])"#, "$1 $2"),
            (#"([a-z])([A-Z])"#, "$1 $2"),
            (#"([A-Za-z])([0-9])"#, "$1 $2"),
            (#"([0-9])([A-Za-z])"#, "$1 $2")
        ]
        for (pattern, template) in boundaries {
            tokenized = replacingMatches(in: tokenized, pattern: pattern, template: template)
        }
        return tokenized.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func replacingMatches(in value: String, pattern: String, template: String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func digitSpoken(_ value: String) -> String {
        var result = ""
        for character in value {
            if let word = digitWords[character] {
                result += " \(word) "
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func symbolVariant(_ canonical: String, nameSeparators: Bool) -> String {
        var result = ""
        for character in canonical {
            if let word = symbolCharacterWords[character] {
                result += " \(word) "
            } else if let word = separatorCharacterWords[character] {
                result += nameSeparators ? " \(word) " : " "
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func aliasPattern(for surface: String) -> NSRegularExpression {
        let parts = surface.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        let pattern = #"(?<![A-Za-z0-9_])"# + parts.joined(separator: #"\s+"#) + #"(?![A-Za-z0-9_])"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func substring(_ text: String, range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        return String(text[stringRange])
    }

    private static func substring(_ text: String, start: Int, end: Int) -> String {
        substring(text, range: NSRange(location: start, length: end - start))
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func casefold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: casefoldLocale)
    }

    private static func isUppercaseASCII(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.allSatisfy { $0 >= 65 && $0 <= 90 }
    }

    private static func isASCIIAlpha(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private struct Surface {
        var canonical: String
        var rank: Int
        var profiles: [KeyPair]
    }

    private struct KeyPair: Hashable {
        var grapheme: [UInt8]
        var phone: [UInt8]
    }

    private struct Candidate {
        var start: Int
        var end: Int
        var canonical: String
        var canonicalRank: Int
        var kind: String
        var score: Double
        var discoveryOrder: Int
        var matched: String
    }

    private struct Token {
        var start: Int
        var end: Int
        var text: String
    }

    private struct LexicalPattern {
        var canonical: String
        var canonicalRank: Int
        var kind: String
        var expression: NSRegularExpression
    }

    private struct ProtectedPattern {
        var canonical: String
        var discoveryOrder: Int
        var expression: NSRegularExpression
    }

    private static let casefoldLocale = Locale(identifier: "en_US_POSIX")
    private static let digitWords: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine"
    ]
    private static let symbolCharacterWords: [Character: String] = [
        "#": "sharp", "+": "plus", "/": "slash", "&": "and", "@": "at", "%": "percent"
    ]
    private static let separatorCharacterWords: [Character: String] = [
        ".": "dot", "-": "dash", "_": "underscore"
    ]
    private static let symbolWords: [UInt8: [UInt8]] = [
        35: Array(" sharp ".utf8),
        43: Array(" plus ".utf8),
        47: Array(" slash ".utf8),
        38: Array(" and ".utf8),
        64: Array(" at ".utf8),
        37: Array(" percent ".utf8)
    ]
    private static let phoneticReplacements: [(String, String)] = [
        ("tch", "C"), ("sch", "sk"), ("tion", "Sn"), ("sion", "Sn"),
        ("ough", "A"), ("ph", "f"), ("ght", "t"), ("ch", "C"),
        ("sh", "S"), ("th", "T"), ("qu", "kw"), ("ck", "k"),
        ("ng", "N"), ("wh", "w"), ("wr", "r"), ("kn", "n")
    ]
    private static let vowelBytes: Set<UInt8> = [97, 101, 105, 111, 117, 121]
    private static let asciiCapitalA: UInt8 = 65
    private static let asciiC: UInt8 = 99
    private static let asciiE: UInt8 = 101
    private static let asciiG: UInt8 = 103
    private static let asciiI: UInt8 = 105
    private static let asciiJ: UInt8 = 106
    private static let asciiK: UInt8 = 107
    private static let asciiQ: UInt8 = 113
    private static let asciiS: UInt8 = 115
    private static let asciiX: UInt8 = 120
    private static let asciiY: UInt8 = 121
    private static let asciiZ: UInt8 = 122
}
