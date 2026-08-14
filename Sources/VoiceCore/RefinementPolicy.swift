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

    /// A single word may stand in for a multi-word canonical only when it carries
    /// at least half of the term's letters.
    ///
    /// The feature this guards is real: glossary `NVIDIA Parakeet` against a
    /// transcript saying only "Parakeet" should ask the refiner to expand it, and
    /// `bareMultiWordGlossaryComponentNeedsRefinement` pins that. But matching *any*
    /// component made this the dominant refine trigger, because technical canonicals
    /// contain ordinary English. Simulated over 500 real local sessions the
    /// unrestricted rule fired on **83.0%** of dictations — `"the"` from
    /// `see the SSH config` matched 336 of them by itself, `"to"` from `end-to-end`
    /// another 230 — and every firing requests a refine costing ~1.9 s at p50.
    ///
    /// Character share separates the two cases where length and stopword lists both
    /// fail. `"parakeet"` is 57% of its canonical; `"the"` is 20%, `"pr"` 25%,
    /// `"to"` 40%, `"agent"` 45%. At half the letters the rule fires on **14.0%** of
    /// the same sessions and still expands Parakeet. A minimum length would have
    /// rejected genuinely distinctive short components — `SSH`, `TDT`, `DAG`, `lsp`,
    /// `PR` — and a stopword list would not have caught `agent` or `review`.
    ///
    /// The share is measured against the canonical's distinct words, so a repeated
    /// word like the `end` in `end-to-end` cannot inflate the denominator. A fully
    /// present canonical is skipped earlier, so this governs partial matches only.
    private static let minimumPartialCanonicalShare = 0.5

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
            let distinct = Set(canonicalWords)
            let letters = distinct.reduce(0) { $0 + $1.count }
            guard letters > 0 else { continue }
            for word in distinct where transcriptWords.contains(word) {
                if Double(word.count) / Double(letters) >= minimumPartialCanonicalShare {
                    return true
                }
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

    /// Floor on `CaptureTelemetry.snrDB` below which a capture is treated as
    /// containing no speech.
    ///
    /// Measured 2026-08-14 with the real `CaptureTelemetryAnalyzer` statistics.
    /// `snrDB` is the gap between the 90th and 10th percentile of 10 ms buffer RMS,
    /// so flat noise collapses toward zero while speech — however quiet — keeps a
    /// wide gap because it alternates with its own pauses:
    ///
    /// | capture | snrDB |
    /// | --- | ---: |
    /// | 8 s of digital zeros | 0.0 |
    /// | 8 s of quiet dither | 0.8 |
    /// | 8 s of hiss | 0.8 |
    /// | nine real speech clips | 20.4 – 52.8 |
    ///
    /// 6 dB sits 7.5x above the loudest noise sample and 3.4x below the quietest
    /// speech sample. Peak level is deliberately NOT used: three of those real
    /// clips peak at −44 to −49 dBFS, quieter than the hiss, so a peak gate would
    /// discard genuine quiet speech. `activeSpeechRatio` is likewise unusable —
    /// it reads 0.000 for those same clips because they never cross −40 dBFS.
    public static let minimumCaptureSNRDB = 6.0

    /// Whether a capture carries no speech and its transcript must be discarded.
    ///
    /// This exists because ASR models invent text from noise rather than returning
    /// nothing. Measured on this machine, 8 s of quiet dither through the shipping
    /// default backend produced `"Esta mañana está en su mayor mayor mayor."`, and
    /// through `ark-0.6b` produced `"嗯。"` — fabricated text in a language the user
    /// was not speaking, which `shouldSkipTranscript` cannot catch because it is not
    /// whitespace. A dictation app pastes that into the user's document.
    ///
    /// Fails open in both directions that matter. Absent telemetry proceeds, because
    /// suppressing a real dictation on no evidence is worse than passing noise
    /// through. Synthetic capture proceeds, because the fake recorder writes literal
    /// silence and its synthesised transcript is its contract, not a defect.
    public static func capturedSpeechIsAbsent(
        telemetry: CaptureTelemetry?,
        isSynthetic: Bool
    ) -> Bool {
        guard !isSynthetic, let telemetry else { return false }
        return telemetry.snrDB < minimumCaptureSNRDB
    }
}
