import Foundation

public enum RefinementGuards {
    /// True when the ordered numeric-token sequence is identical in both strings.
    ///
    /// Commas are ignored so equivalent thousands grouping remains valid, but
    /// numbers may not be dropped, changed, reordered, duplicated, or added.
    public static func numbersPreserved(original: String, candidate: String) -> Bool {
        digitRuns(in: original.replacingOccurrences(of: ",", with: ""))
            == digitRuns(in: candidate.replacingOccurrences(of: ",", with: ""))
    }

    private static func digitRuns(in text: String) -> [String] {
        var runs: [String] = []
        var currentRun = ""

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                currentRun.unicodeScalars.append(scalar)
            } else if !currentRun.isEmpty {
                runs.append(currentRun)
                currentRun.removeAll(keepingCapacity: true)
            }
        }

        if !currentRun.isEmpty {
            runs.append(currentRun)
        }

        return runs
    }

    /// Structural markers used to recognize opaque technical spans without
    /// treating ordinary words or punctuation as protected identifiers.
    private static let technicalLeadingDelimiters: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{2018}", "`", "(", "[", "{", "<",
    ]

    private static let technicalTrailingDelimiters: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", "`", ")", "]", "}", ">", ".", ",", ";", ":", "!", "?",
    ]

    /// Conversational prefixes a refiner must never prepend to cleaned dictation.
    /// A candidate is only flagged when the ORIGINAL does not itself start with the
    /// same word, so faithfully cleaned "sure here's the plan" still passes.
    private static let assistantPreamblePrefixes = [
        "sure", "certainly", "of course", "here's", "here is", "i'm sorry", "im sorry",
        "i am sorry", "sorry,", "i cannot", "i can't", "i cant", "as a chatbot",
        "as an ai", "as a language model", "i'd be happy", "id be happy",
        "unfortunately", "i apologize", "understood",
    ]

    private static let interrogativeOpeners: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres", "who", "whos", "whom",
        "why", "how", "hows", "is", "are", "am", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "should", "shall", "may", "might",
    ]

    private static let whQuestionOpeners: Set<String> = [
        "what", "when", "where", "who", "whom", "why", "how",
    ]

    private static let questionAuxiliaries: Set<String> = [
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "may", "might",
    ]

    private static let contractedQuestionForms: [String: [String]] = [
        "whats": ["what", "is"],
        "whens": ["when", "is"],
        "wheres": ["where", "is"],
        "whos": ["who", "is"],
        "hows": ["how", "is"],
    ]

    private static let howQuestionContinuations: Set<String> = questionAuxiliaries.union([
        "many", "much", "long", "far", "old", "often", "soon",
    ])

    /// Leading disfluencies skipped when locating the transcript's content opener:
    /// dictated questions usually begin "um what ..." and must still be recognized.
    private static let leadingFillers: Set<String> = [
        "um", "uh", "er", "uhm", "hmm", "so", "okay", "ok", "well", "like",
        "basically", "actually", "hey", "yeah", "and",
    ]

    /// True when the candidate looks like assistant chatter instead of cleaned
    /// dictation. Two measured failure modes (Apple on-device model, 2026-07):
    /// 1. Preamble/refusal chatter: "Sure, here's the cleaned text: ..." or
    ///    "I'm sorry, but as a chatbot ..." prepended or substituted.
    /// 2. Answered question: an interrogative transcript ("whats the capital of
    ///    france") rewritten as its answer ("The capital of France is Paris."),
    ///    which drops both the question mark and the interrogative opener.
    public static func looksLikeAssistantArtifact(original: String, candidate: String) -> Bool {
        let normalizedCandidate = normalizedForMatching(candidate)
        let originalOpener = contentOpener(of: original)
        let candidateWords = wordsForMatching(candidate)

        if let firstCandidateWord = candidateWords.first {
            for prefix in assistantPreamblePrefixes {
                guard normalizedCandidate.hasPrefix(prefix) else { continue }
                let prefixFirstWord = wordsForMatching(prefix).first ?? prefix
                if originalOpener != prefixFirstWord || firstCandidateWord != originalOpener {
                    return true
                }
            }
        }

        if let originalQuestionForm = questionForm(of: original) {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if questionForm(of: candidate) != originalQuestionForm
                || trimmedCandidate.last != "?"
                || candidate.lazy.filter({ $0 == "?" }).count != 1
            {
                return true
            }
        }

        return false
    }

    /// First word of the transcript once leading disfluency fillers are skipped.
    private static func contentOpener(of text: String) -> String? {
        wordsForMatching(text).first { !leadingFillers.contains($0) }
    }

    /// Normalized leading syntax that distinguishes one question shape from
    /// another while allowing casing, punctuation, and common contractions.
    private static func questionForm(of text: String) -> [String]? {
        let words = contentWords(of: text)
        guard let opener = words.first else { return nil }

        if let contractedForm = contractedQuestionForms[opener] {
            return contractedForm
        }

        let explicitlyPunctuated = text.contains("?")
        guard interrogativeOpeners.contains(opener) || explicitlyPunctuated else { return nil }

        let secondWord = words.dropFirst().first
        if !explicitlyPunctuated {
            if opener == "what", secondWord == "a" || secondWord == "an" {
                return nil
            }
            if opener == "how",
                secondWord.map({ howQuestionContinuations.contains($0) }) != true
            {
                return nil
            }
            if questionAuxiliaries.contains(opener), secondWord == "not" {
                return nil
            }
        }

        if whQuestionOpeners.contains(opener),
            let secondWord,
            questionAuxiliaries.contains(secondWord)
        {
            return [opener, secondWord]
        }
        return [opener]
    }

    private static func contentWords(of text: String) -> ArraySlice<String> {
        wordsForMatching(text).drop { leadingFillers.contains($0) }
    }

    /// True when the candidate is substantially built from the original's words.
    ///
    /// Faithful cleanup only removes disfluencies, resolves corrections, and
    /// fixes punctuation, so nearly every candidate content word must already
    /// appear in the transcript. A refiner that echoes prompt scaffolding
    /// instead (measured Apple on-device failure: the PROTECTED TERMS list
    /// pasted verbatim, sharing zero words with the utterance) scores near zero
    /// here. A glossary term's canonical words count as matched only when the
    /// transcript actually contains support for that term (its canonical or a
    /// spoken alias), so "om pi" -> "OMPi" passes while an unprompted glossary
    /// dump does not.
    public static func sharesEnoughContent(original: String, candidate: String, glossary: [ProtectedTerm]) -> Bool {
        let originalWords = Set(wordsForMatching(original))
        guard !originalWords.isEmpty else { return true }

        var supportedGlossaryWords: Set<String> = []
        for term in glossary {
            let supportWords = wordsForMatching(
                ([term.canonical] + Glossary.userAliases(for: term)).joined(separator: " ")
            )
            guard supportWords.contains(where: { $0.count >= 2 && originalWords.contains($0) }) else { continue }
            supportedGlossaryWords.formUnion(wordsForMatching(term.canonical))
        }

        let candidateContentWords = wordsForMatching(candidate).filter { $0.count >= 3 }
        // Too few measurable words to judge (e.g. "OK.").
        guard candidateContentWords.count >= 3 else { return true }

        let matched = candidateContentWords.filter {
            originalWords.contains($0) || supportedGlossaryWords.contains($0)
        }.count
        return Double(matched) / Double(candidateContentWords.count) >= 0.6
    }

    /// True when every conservatively recognized technical span is byte-for-byte
    /// identical and appears in the same order in both strings.
    private static func technicalSpansPreserved(original: String, candidate: String) -> Bool {
        technicalSpans(in: original) == technicalSpans(in: candidate)
    }

    private static func technicalSpans(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { rawToken in
            var token = String(rawToken)
            while let first = token.first, technicalLeadingDelimiters.contains(first) {
                token.removeFirst()
            }
            while let last = token.last, technicalTrailingDelimiters.contains(last) {
                token.removeLast()
            }

            guard !token.isEmpty,
                isWebURL(token)
                    || isEmailAddress(token)
                    || isFilesystemPath(token)
                    || isCLIFlag(token)
            else {
                return nil
            }
            return token
        }
    }

    private static func isWebURL(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        let prefix: String
        if lowercased.hasPrefix("https://") {
            prefix = "https://"
        } else if lowercased.hasPrefix("http://") {
            prefix = "http://"
        } else {
            return false
        }

        let remainder = token.dropFirst(prefix.count)
        let authority = remainder.prefix { !"/?#".contains($0) }
        return !authority.isEmpty
    }

    private static func isEmailAddress(_ token: String) -> Bool {
        let pieces = token.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let local = pieces[0]
        let domain = pieces[1]
        guard !local.isEmpty,
            local.first != ".",
            local.last != ".",
            local.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
                    || $0.value == 46
                    || $0.value == 95
                    || $0.value == 37
                    || $0.value == 43
                    || $0.value == 45
            })
        else {
            return false
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2
            && labels.allSatisfy { label in
                !label.isEmpty
                    && label.first != "-"
                    && label.last != "-"
                    && label.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0.value == 45
                    }
            }
    }

    private static func isFilesystemPath(_ token: String) -> Bool {
        if (token.hasPrefix("/") && token.count > 1)
            || (token.hasPrefix("~/") && token.count > 2)
            || (token.hasPrefix("./") && token.count > 2)
            || (token.hasPrefix("../") && token.count > 3)
            || (token.hasPrefix("\\\\") && token.count > 2)
        {
            return true
        }

        let relativeSegments = token.split(separator: "/", omittingEmptySubsequences: false)
        if relativeSegments.count >= 2,
            relativeSegments.allSatisfy({ !$0.isEmpty }),
            let lastSegment = relativeSegments.last,
            lastSegment.contains(".")
        {
            return true
        }

        let scalars = token.unicodeScalars
        guard let firstIndex = scalars.indices.first else { return false }
        let secondIndex = scalars.index(after: firstIndex)
        guard secondIndex < scalars.endIndex else { return false }
        let thirdIndex = scalars.index(after: secondIndex)
        guard thirdIndex < scalars.endIndex else { return false }

        let first = scalars[firstIndex]
        return ((65...90).contains(first.value) || (97...122).contains(first.value))
            && scalars[secondIndex].value == 58
            && (scalars[thirdIndex].value == 47 || scalars[thirdIndex].value == 92)
    }

    private static func isCLIFlag(_ token: String) -> Bool {
        let body: Substring
        if token.hasPrefix("--") {
            body = token.dropFirst(2)
        } else if token.hasPrefix("-") {
            body = token.dropFirst()
        } else {
            return false
        }
        guard let first = body.first, first.isLetter else { return false }
        return !body.contains(where: \.isWhitespace)
    }

    private static func normalizedForMatching(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func wordsForMatching(_ text: String) -> [String] {
        normalizedForMatching(text)
            .replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Faithfulness gate shared by all refiner backends: the candidate is at most twice the
    /// original length, preserves every glossary protected term, preserves the exact numeric
    /// and technical-span sequences, is not assistant chatter (preamble, refusal, or an
    /// answered question), and is substantially built from the transcript's own words.
    public static func passesFaithfulnessGuards(original: String, candidate: String, glossary: [ProtectedTerm]) -> Bool
    {
        candidate.count <= max(original.count * 2, 1)
            && Glossary.validateTermLock(original: original, candidate: candidate, terms: glossary)
            && numbersPreserved(original: original, candidate: candidate)
            && technicalSpansPreserved(original: original, candidate: candidate)
            && !looksLikeAssistantArtifact(original: original, candidate: candidate)
            && sharesEnoughContent(original: original, candidate: candidate, glossary: glossary)
    }
}
