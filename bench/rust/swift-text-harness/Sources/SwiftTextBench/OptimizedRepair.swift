import Darwin
import Foundation
import VoiceCore

extension Optimized {
    /// `VocabularyRepairEngine` (Sources/VoiceCore/VocabularyRepair.swift:144-808), copied with the
    /// same construction, matching, window scan, scoring, acceptance and tie-breaks. Changed:
    ///
    /// - Profile keys live in one flat byte table, and `normalizedLevenshteinSimilarity` runs the
    ///   same dynamic program over raw pointers with two rows allocated once per engine.
    ///   Production allocates two `[Int]` per comparison, about 2 x 1,000 comparisons per window.
    /// - `phoneticKey` replaces byte runs in an `[UInt8]` instead of calling
    ///   `String.replacingOccurrences` (bridged to `CFStringFindWithOptionsAndLocale`) 16 times.
    /// - `graphemeKey` skips `decomposedStringWithCompatibilityMapping` for ASCII, whose NFKD is
    ///   itself, and appends the symbol words' letters directly.
    /// - A window's substring and keys are made only after the window clears the lexical and
    ///   protected spans (production makes them first and discards them).
    /// - With `memoizeConstants`, the constant expressions (`canonicalTokens`' five, the token
    ///   pattern) compile once per process; production compiles them per canonical per build.
    ///
    /// Not thread-safe: `repair` reuses the scratch rows. The harness drives it from one thread.
    final class RepairEngine {
        private static let epsilon = 1e-12
        private static let maximumWindowWords = 5

        private struct Profile {
            var graphemeStart: Int
            var graphemeCount: Int
            var phoneStart: Int
            var phoneCount: Int
        }

        /// Surface canonicals by rank.
        private let canonicals: [String]
        /// Surface `s` owns profiles `profileStart[s]..<profileStart[s + 1]`.
        private let profileStart: UnsafeMutablePointer<Int>
        private let profiles: UnsafeMutablePointer<Profile>
        private let keyBytes: UnsafeMutablePointer<UInt8>
        /// Two Levenshtein rows of the longest profile key plus one.
        private let scratch: UnsafeMutablePointer<Int>
        private let profileCount: Int
        private let keyByteCount: Int
        private let lexicalPatterns: [LexicalPattern]
        private let protectedPatterns: [ProtectedPattern]
        private let ordinaryWords: Set<String>
        private let singleLetterWords: Set<String>
        private let phoneticThreshold: Double
        private let tokenPattern: NSRegularExpression

        /// `repairEngine(for:)`'s cache miss: `RepairVocabulary.fromActiveTerms` with the bundled
        /// words, then the engine.
        convenience init(activeTerms: [ProtectedTerm], memoizeConstants: Bool) {
            let words = RepairVocabulary.bundledOrdinaryWords
            let partition = Optimized.partition(activeTerms, ordinaryWords: words)
            self.init(
                surfaces: partition.surfaces,
                protectedSurfaces: partition.protected,
                ordinaryWords: words,
                memoizeConstants: memoizeConstants
            )
        }

        /// `VocabularyRepairEngine(vocabulary:)` for a vocabulary whose prepared ordinary-word
        /// set is `ordinaryWords` (what `RepairVocabulary.fromActiveTerms` produces).
        init(
            surfaces vocabularySurfaces: [String],
            protectedSurfaces: [String],
            ordinaryWords: Set<String>,
            singleLetterWords: [String] = ["a", "i"],
            phoneticThreshold: Double = RepairVocabulary.frozenPhoneticThreshold,
            memoizeConstants: Bool
        ) {
            let orderedCanonicals = Array(Set(vocabularySurfaces)).sorted()
            var canonicalOwners: [String: Set<String>] = [:]
            var rawAliases: [String: [String]] = [:]

            for canonical in orderedCanonicals {
                canonicalOwners[Self.casefold(Self.normalizedWhitespace(canonical)), default: []].insert(canonical)
                rawAliases[canonical] = Self.derivedAliases(for: canonical, memoizeConstants: memoizeConstants)
            }

            var aliasOwners = canonicalOwners
            for canonical in orderedCanonicals {
                for alias in rawAliases[canonical, default: []] {
                    aliasOwners[Self.casefold(alias), default: []].insert(canonical)
                }
            }

            var compiledProfiles: [[KeyPair]] = []
            var compiledLexicalPatterns: [LexicalPattern] = []
            compiledProfiles.reserveCapacity(orderedCanonicals.count)

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

                var surfaceProfiles: [KeyPair] = []
                var seenProfiles: Set<KeyPair> = []
                for surface in [canonical] + aliases {
                    let profile = Self.keys(for: surface)
                    if !profile.grapheme.isEmpty, seenProfiles.insert(profile).inserted {
                        surfaceProfiles.append(profile)
                    }
                }
                compiledProfiles.append(surfaceProfiles)

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

            let orderedProtected = Array(Set(protectedSurfaces)).sorted()
            self.protectedPatterns = orderedProtected.enumerated().map { discoveryOrder, surface in
                ProtectedPattern(
                    canonical: surface,
                    discoveryOrder: discoveryOrder,
                    expression: Self.aliasPattern(for: surface)
                )
            }
            self.canonicals = orderedCanonicals
            self.lexicalPatterns = compiledLexicalPatterns
            self.ordinaryWords = ordinaryWords
            self.singleLetterWords = Set(singleLetterWords.lazy.map(Self.casefold))
            self.phoneticThreshold = phoneticThreshold
            self.tokenPattern =
                memoizeConstants ? Self.sharedTokenPattern : try! NSRegularExpression(pattern: Self.tokenPatternSource)

            // Flatten the profiles: surface by surface, grapheme then phone bytes per profile.
            let profileCount = compiledProfiles.reduce(0) { $0 + $1.count }
            let keyByteCount = compiledProfiles.reduce(0) { total, surface in
                surface.reduce(total) { $0 + $1.grapheme.count + $1.phone.count }
            }
            let profileStart = UnsafeMutablePointer<Int>.allocate(capacity: compiledProfiles.count + 1)
            let profiles = UnsafeMutablePointer<Profile>.allocate(capacity: max(profileCount, 1))
            let keyBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: max(keyByteCount, 1))
            var profileIndex = 0
            var byteIndex = 0
            var longest = 0
            for (surface, surfaceProfiles) in compiledProfiles.enumerated() {
                profileStart[surface] = profileIndex
                for profile in surfaceProfiles {
                    let graphemeStart = byteIndex
                    for byte in profile.grapheme {
                        keyBytes[byteIndex] = byte
                        byteIndex += 1
                    }
                    let phoneStart = byteIndex
                    for byte in profile.phone {
                        keyBytes[byteIndex] = byte
                        byteIndex += 1
                    }
                    (profiles + profileIndex).initialize(
                        to: Profile(
                            graphemeStart: graphemeStart,
                            graphemeCount: profile.grapheme.count,
                            phoneStart: phoneStart,
                            phoneCount: profile.phone.count
                        ))
                    profileIndex += 1
                    longest = max(longest, profile.grapheme.count, profile.phone.count)
                }
            }
            profileStart[compiledProfiles.count] = profileIndex
            self.profileStart = profileStart
            self.profiles = profiles
            self.keyBytes = keyBytes
            self.profileCount = profileCount
            self.keyByteCount = keyByteCount
            self.scratch = .allocate(capacity: 2 * (longest + 1))
        }

        deinit {
            profileStart.deallocate()
            profiles.deinitialize(count: profileCount)
            profiles.deallocate()
            keyBytes.deallocate()
            scratch.deallocate()
        }

        func repair(_ text: String) -> RepairOutcome {
            guard !canonicals.isEmpty else { return RepairOutcome(text: text, events: []) }

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
                        if Self.overlaps(start: start, end: end, any: lexical)
                            || Self.overlaps(start: start, end: end, any: protected)
                        {
                            continue
                        }

                        let matched = Self.substring(text, start: start, end: end)
                        let leftKeys = Self.keys(for: matched)
                        let (bestSurface, bestScore) = bestMatch(for: leftKeys)
                        if bestSurface >= 0, bestScore + Self.epsilon >= phoneticThreshold {
                            fuzzy.append(
                                Candidate(
                                    start: start,
                                    end: end,
                                    canonical: canonicals[bestSurface],
                                    canonicalRank: bestSurface,
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
            let eligible =
                fuzzy
                .filter { !isOrdinarySpan(text: $0.matched) }
                .sorted(by: Self.precedesForPhoneticAcceptance)
            for candidate in eligible where !Self.overlaps(start: candidate.start, end: candidate.end, any: accepted) {
                accepted.append(candidate)
            }
            return Self.apply(accepted, to: text)
        }

        /// The surface loop of the window scan: the best-scoring surface (index = rank) and its
        /// score, or -1. Surfaces run in rank order; a later surface wins a tie only with a lower
        /// rank, as in production.
        private func bestMatch(for left: KeyPair) -> (surface: Int, score: Double) {
            left.grapheme.withUnsafeBufferPointer { leftGrapheme in
                left.phone.withUnsafeBufferPointer { leftPhone in
                    var bestSurface = -1
                    var bestScore = 0.0
                    for surface in 0..<canonicals.count {
                        let score = score(leftGrapheme, leftPhone, surface: surface)
                        if score > bestScore + Self.epsilon {
                            bestSurface = surface
                            bestScore = score
                        } else if abs(score - bestScore) <= Self.epsilon, bestSurface >= 0, surface < bestSurface {
                            bestSurface = surface
                        }
                    }
                    return (bestSurface, bestScore)
                }
            }
        }

        /// `score(_:against:)` over the surface's flattened profiles.
        @inline(__always)
        private func score(
            _ leftGrapheme: UnsafeBufferPointer<UInt8>,
            _ leftPhone: UnsafeBufferPointer<UInt8>,
            surface: Int
        ) -> Double {
            var best = 0.0
            var index = profileStart[surface]
            let end = profileStart[surface + 1]
            while index < end {
                let right = profiles[index]
                index += 1
                guard !leftGrapheme.isEmpty, right.graphemeCount > 0 else { continue }
                let graphemeScore = Self.normalizedLevenshteinSimilarity(
                    leftGrapheme,
                    UnsafeBufferPointer(start: keyBytes + right.graphemeStart, count: right.graphemeCount),
                    scratch
                )
                let phoneScore = Self.normalizedLevenshteinSimilarity(
                    leftPhone,
                    UnsafeBufferPointer(start: keyBytes + right.phoneStart, count: right.phoneCount),
                    scratch
                )
                let blended = 0.35 * graphemeScore + 0.65 * phoneScore
                best = max(best, max(graphemeScore, blended))
            }
            return best
        }

        /// The production dynamic program, value for value: the left neighbour and the diagonal
        /// stay in registers, the two rows are `scratch` (room for `right.count + 1` each). Cells
        /// never exceed the longer key's length, so the wrapping `&+` computes what production's
        /// overflow-checked `+` does, minus the checks (Rust's release `+` has none either).
        @inline(__always)
        private static func normalizedLevenshteinSimilarity(
            _ left: UnsafeBufferPointer<UInt8>,
            _ right: UnsafeBufferPointer<UInt8>,
            _ scratch: UnsafeMutablePointer<Int>
        ) -> Double {
            let leftCount = left.count
            let rightCount = right.count
            if leftCount == rightCount,
                leftCount == 0 || memcmp(left.baseAddress!, right.baseAddress!, leftCount) == 0
            {
                return 1
            }
            let length = max(leftCount, rightCount)
            guard length > 0 else { return 1 }
            if leftCount == 0 || rightCount == 0 { return 0 }

            let leftBytes = left.baseAddress!
            let rightBytes = right.baseAddress!
            var previous = scratch
            var current = scratch + (rightCount &+ 1)
            for column in 0...rightCount {
                previous[column] = column
            }
            for row in 0..<leftCount {
                let leftByte = leftBytes[row]
                var leftValue = row &+ 1
                var diagonal = previous[0]
                current[0] = leftValue
                for column in 0..<rightCount {
                    let above = previous[column &+ 1]
                    // Production's three-argument `min` is the variadic overload; the minimum is the same.
                    let value = min(
                        min(leftValue &+ 1, above &+ 1),
                        diagonal &+ (leftByte == rightBytes[column] ? 0 : 1)
                    )
                    current[column &+ 1] = value
                    leftValue = value
                    diagonal = above
                }
                swap(&previous, &current)
            }
            return 1 - Double(previous[rightCount]) / Double(length)
        }

        // MARK: - Verbatim production helpers

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
                    let overlappingProtected = protected.filter {
                        candidate.start < $0.end && $0.start < candidate.end
                    }
                    if overlappingProtected.isEmpty
                        || Self.canSupersedeProtectedPrefix(
                            candidate,
                            protected: overlappingProtected
                        )
                    {
                        candidates.append(candidate)
                    }
                }
            }
            return candidates
        }

        private static func canSupersedeProtectedPrefix(
            _ candidate: Candidate,
            protected: [Candidate]
        ) -> Bool {
            guard surfaceShape(candidate.matched) == surfaceShape(candidate.canonical) else {
                return false
            }
            return protected.allSatisfy {
                candidate.canonical.count > $0.canonical.count
                    && candidate.canonical.hasPrefix($0.canonical)
            }
        }

        private static func surfaceShape(_ value: String) -> String {
            String(
                value.filter {
                    !$0.isWhitespace && $0 != "." && $0 != "_" && $0 != "-"
                }
            )
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
            for candidate in ordered where !overlaps(start: candidate.start, end: candidate.end, any: accepted) {
                accepted.append(candidate)
            }
            return accepted
        }

        private static func overlaps(start: Int, end: Int, any accepted: [Candidate]) -> Bool {
            accepted.contains { start < $0.end && $0.start < end }
        }

        private static func apply(_ candidates: [Candidate], to text: String) -> RepairOutcome {
            var output = text
            for candidate in candidates.sorted(by: { $0.start > $1.start }) {
                let range = NSRange(location: candidate.start, length: candidate.end - candidate.start)
                guard let stringRange = Range(range, in: output) else { continue }
                output.replaceSubrange(stringRange, with: candidate.canonical)
            }

            let events =
                candidates
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

        // MARK: - Keys

        private static func keys(for value: String) -> KeyPair {
            let grapheme = graphemeKey(value)
            return KeyPair(grapheme: grapheme, phone: phoneticKey(grapheme))
        }

        /// Production: NFKD, keep scalars below 128, lowercase A-Z, expand `# + / & @ %` to
        /// " sharp " etc., keep ASCII alphanumerics. Same bytes in one pass.
        private static func graphemeKey(_ value: String) -> [UInt8] {
            var key: [UInt8] = []
            key.reserveCapacity(value.utf8.count)
            if value.utf8.allSatisfy({ $0 < 0x80 }) {
                for byte in value.utf8 {
                    appendKeyByte(byte, to: &key)
                }
            } else {
                for scalar in value.decomposedStringWithCompatibilityMapping.unicodeScalars where scalar.value < 128 {
                    appendKeyByte(UInt8(scalar.value), to: &key)
                }
            }
            return key
        }

        @inline(__always)
        private static func appendKeyByte(_ byte: UInt8, to key: inout [UInt8]) {
            switch byte {
            case 65...90: key.append(byte + 32)
            case 48...57, 97...122: key.append(byte)
            case 35: key.append(contentsOf: [115, 104, 97, 114, 112])  // sharp
            case 43: key.append(contentsOf: [112, 108, 117, 115])  // plus
            case 47: key.append(contentsOf: [115, 108, 97, 115, 104])  // slash
            case 38: key.append(contentsOf: [97, 110, 100])  // and
            case 64: key.append(contentsOf: [97, 116])  // at
            case 37: key.append(contentsOf: [112, 101, 114, 99, 101, 110, 116])  // percent
            default: break
            }
        }

        /// Production's 16 replacements, each over the result of the previous one.
        private static let phoneticReplacements: [([UInt8], [UInt8])] = [
            ("tch", "C"), ("sch", "sk"), ("tion", "Sn"), ("sion", "Sn"),
            ("ough", "A"), ("ph", "f"), ("ght", "t"), ("ch", "C"),
            ("sh", "S"), ("th", "T"), ("qu", "kw"), ("ck", "k"),
            ("ng", "N"), ("wh", "w"), ("wr", "r"), ("kn", "n"),
        ].map { (Array($0.0.utf8), Array($0.1.utf8)) }

        private static func phoneticKey(_ grapheme: [UInt8]) -> [UInt8] {
            var key = grapheme
            for (source, replacement) in phoneticReplacements {
                replaceOccurrences(of: source, with: replacement, in: &key)
            }

            // Production's `transformed` then `collapsed` passes, fused.
            var collapsed: [UInt8] = []
            collapsed.reserveCapacity(key.count + 2)
            @inline(__always) func emit(_ byte: UInt8) {
                let normalized: UInt8
                switch byte {
                case 97, 101, 105, 111, 117, 121: normalized = 65  // a e i o u y -> "A"
                default: normalized = byte
                }
                if collapsed.last != normalized {
                    collapsed.append(normalized)
                }
            }
            for index in key.indices {
                let byte = key[index]
                let next = index + 1 < key.count ? key[index + 1] : 0
                let softens = next == 101 || next == 105 || next == 121  // e i y
                if byte == 99, softens {  // c
                    emit(115)  // s
                } else if byte == 103, softens {  // g
                    emit(106)  // j
                } else {
                    switch byte {
                    case 120:  // x
                        emit(107)  // k
                        emit(115)  // s
                    case 113, 99:  // q, c
                        emit(107)  // k
                    case 122:  // z
                        emit(115)  // s
                    default:
                        emit(byte)
                    }
                }
            }
            return collapsed
        }

        /// `String.replacingOccurrences(of:with:)` on an ASCII key: every non-overlapping match,
        /// leftmost first, replaced in one left-to-right pass.
        private static func replaceOccurrences(of source: [UInt8], with replacement: [UInt8], in value: inout [UInt8]) {
            let count = value.count
            let width = source.count
            guard count >= width else { return }
            var result: [UInt8] = []
            var copied = 0
            var index = 0
            while index <= count - width {
                var matches = true
                for offset in 0..<width where value[index + offset] != source[offset] {
                    matches = false
                    break
                }
                if matches {
                    if copied == 0 { result.reserveCapacity(count + replacement.count) }
                    result.append(contentsOf: value[copied..<index])
                    result.append(contentsOf: replacement)
                    index += width
                    copied = index
                } else {
                    index += 1
                }
            }
            guard copied > 0 else { return }
            result.append(contentsOf: value[copied...])
            value = result
        }

        // MARK: - Construction helpers (verbatim unless noted)

        private static func derivedAliases(for canonical: String, memoizeConstants: Bool) -> [String] {
            let tokens = canonicalTokens(canonical, memoizeConstants: memoizeConstants)
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
            if tokens.count == 1, compact.count >= 4,
                compact.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
            {
                let characters = Array(compact)
                if characters.count >= 4 {
                    for split in 2..<(characters.count - 1) {
                        candidates.append(
                            (String(characters[..<split]) + " " + String(characters[split...])).lowercased()
                        )
                    }
                    candidates.append(
                        "\(characters[0])\(characters.count - 2)\(characters[characters.count - 1])".lowercased())
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

        private static let separatorPattern = #"[\s._-]+"#
        private static let boundaries = [
            (#"([A-Z]+)([A-Z][a-z])"#, "$1 $2"),
            (#"([a-z])([A-Z])"#, "$1 $2"),
            (#"([A-Za-z])([0-9])"#, "$1 $2"),
            (#"([0-9])([A-Za-z])"#, "$1 $2"),
        ]
        private static let sharedSeparatorExpression = try! NSRegularExpression(pattern: separatorPattern)
        private static let sharedBoundaryExpressions = boundaries.map {
            (try! NSRegularExpression(pattern: $0.0), $0.1)
        }
        private static let tokenPatternSource = #"[A-Za-z0-9+#/_-]+(?:\.[A-Za-z0-9+#/_-]+)*"#
        private static let sharedTokenPattern = try! NSRegularExpression(pattern: tokenPatternSource)

        /// Production compiles each expression on every call (`replacingMatches(in:pattern:template:)`);
        /// with `memoizeConstants` the same expressions come compiled.
        private static func canonicalTokens(_ canonical: String, memoizeConstants: Bool) -> [String] {
            var tokenized: String
            if memoizeConstants {
                tokenized = replacingMatches(in: canonical, expression: sharedSeparatorExpression, template: " ")
                for (expression, template) in sharedBoundaryExpressions {
                    tokenized = replacingMatches(in: tokenized, expression: expression, template: template)
                }
            } else {
                tokenized = replacingMatches(
                    in: canonical, expression: try! NSRegularExpression(pattern: separatorPattern), template: " ")
                for (pattern, template) in boundaries {
                    tokenized = replacingMatches(
                        in: tokenized, expression: try! NSRegularExpression(pattern: pattern), template: template)
                }
            }
            return tokenized.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        private static func replacingMatches(in value: String, expression: NSRegularExpression, template: String)
            -> String
        {
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
            "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
        ]
        private static let symbolCharacterWords: [Character: String] = [
            "#": "sharp", "+": "plus", "/": "slash", "&": "and", "@": "at", "%": "percent",
        ]
        private static let separatorCharacterWords: [Character: String] = [
            ".": "dot", "-": "dash", "_": "underscore",
        ]
    }
}
