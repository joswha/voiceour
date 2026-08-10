import Foundation

public struct TranscriptAssessment: Equatable, Sendable {
    public let needsRefinement: Bool
    public let tooLong: Bool

    public init(needsRefinement: Bool, tooLong: Bool) {
        self.needsRefinement = needsRefinement
        self.tooLong = tooLong
    }
}

public enum DictationPolicy {}

extension DictationPolicy {
    private static let casualRefinementBundleIDs: Set<String> = [
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
    ]
    private static let formalRefinementBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
    ]

    public enum RefinementDecision: Equatable, Sendable {
        case refine
        case skip(reason: String)

        public var shouldRefine: Bool {
            self == .refine
        }

        public var skipReason: String? {
            switch self {
            case .refine:
                nil
            case .skip(let reason):
                reason
            }
        }
    }

    /// The three gates that do not depend on the transcript: refinement is
    /// enabled, the target is safe to rewrite for, and the provider is
    /// configured. Returns the skip reason, or nil to continue.
    ///
    /// Separated out because `VoiceMac.RefinerPolicy` needs exactly these three
    /// on the backend side. Two independent implementations of "may we refine
    /// this?" is the kind of thing that agrees today and drifts silently, so the
    /// backends forward here rather than restating it.
    public static func refinementPreflight(
        refinerEnabled: Bool,
        targetSafety: TargetSafetyClass,
        refinerConfigured: Bool
    ) -> String? {
        guard refinerEnabled else { return "disabled" }
        guard targetSafety == .normalText || targetSafety == .unknownRisky else {
            return "unsafe_target"
        }
        guard refinerConfigured else { return "unconfigured" }
        return nil
    }

    public static func refinementDecision(
        refinerEnabled: Bool,
        refinerConfigured: Bool,
        targetSafety: TargetSafetyClass,
        providerReadiness: RefinerReadiness,
        assessment: @autoclosure () -> TranscriptAssessment
    ) -> RefinementDecision {
        if let reason = refinementPreflight(
            refinerEnabled: refinerEnabled,
            targetSafety: targetSafety,
            refinerConfigured: refinerConfigured && providerReadiness.isReady
        ) {
            return .skip(reason: reason)
        }
        let assessment = assessment()
        guard !assessment.tooLong else { return .skip(reason: "transcript_too_long") }
        guard assessment.needsRefinement else { return .skip(reason: "clean_transcript") }
        return .refine
    }

    public static func assessTranscript(_ raw: String, glossary: [ProtectedTerm]) -> TranscriptAssessment {
        let words = normalizedWords(in: raw)
        let tooLong = words.count > 350
        let fillerCount = words.reduce(into: 0) { count, word in
            if CleanupEngine.fillers.contains(word) {
                count += 1
            }
        }
        let normalizedText = words.joined(separator: " ")
        let markers = ["no wait", "i mean", "actually", "scratch that", "sorry", "rather"]

        let needsRefinement =
            words.count >= 40
            || fillerCount >= 2
            || hasAdjacentRepeat(in: words)
            || markers.contains(where: normalizedText.contains)
            || hasPartialGlossaryCanonical(in: words, glossary: glossary)
            || hasPhoneticNearMiss(in: words, glossary: glossary)

        return TranscriptAssessment(needsRefinement: needsRefinement, tooLong: tooLong)
    }

    public static func refinementStyle(forBundleId bundleId: String?) -> RefinementStyle {
        guard let bundleId else { return .standard }
        if casualRefinementBundleIDs.contains(bundleId) {
            return .casual
        }
        if formalRefinementBundleIDs.contains(bundleId) {
            return .formal
        }
        return .standard
    }

    private static func normalizedWords(in text: String) -> [String] {
        text
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func hasAdjacentRepeat(in words: [String]) -> Bool {
        for length in 1...4 where words.count >= length * 2 {
            for index in 0...words.count - (length * 2) {
                if words[index..<index + length] == words[index + length..<index + (length * 2)] {
                    return true
                }
            }
        }
        return false
    }

    private static func hasPartialGlossaryCanonical(
        in words: [String],
        glossary: [ProtectedTerm]
    ) -> Bool {
        let transcriptWords = Set(words)
        for term in glossary {
            let canonicalWords = normalizedWords(in: term.canonical)
            guard canonicalWords.count > 1 else { continue }
            if contains(canonicalWords, in: words) {
                continue
            }
            if canonicalWords.contains(where: transcriptWords.contains) {
                return true
            }
        }
        return false
    }

    private static func hasPhoneticNearMiss(
        in words: [String],
        glossary: [ProtectedTerm]
    ) -> Bool {
        for term in glossary {
            let aliases = Glossary.matchingAliases(for: term)
            let aliasWords = aliases.map { normalizedWords(in: $0) }
            let exactAliases = Dictionary(grouping: aliasWords) { $0.count }
                .mapValues { Set($0.map { $0.joined() }) }
            let candidates = aliasWords.compactMap { parts -> (normalized: String, wordCount: Int)? in
                guard (1...4).contains(parts.count) else { return nil }
                let normalized = parts.joined()
                guard normalized.count >= 6 else { return nil }
                return (normalized, parts.count)
            }

            for candidate in candidates where candidate.wordCount <= words.count {
                let threshold = max(1, candidate.normalized.count / 4)
                for index in 0...words.count - candidate.wordCount {
                    let window = words[index..<index + candidate.wordCount].joined()
                    if exactAliases[candidate.wordCount]?.contains(window) == true {
                        continue
                    }
                    let distance = levenshteinDistance(window, candidate.normalized)
                    if (1...threshold).contains(distance) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        CandidateRetriever.levenshtein(Array(lhs), Array(rhs))
    }

    private static func contains(_ needle: [String], in haystack: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for index in 0...haystack.count - needle.count {
            if haystack[index..<index + needle.count].elementsEqual(needle) {
                return true
            }
        }
        return false
    }

    public static func shouldSkipTranscript(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
