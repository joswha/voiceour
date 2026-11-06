import Foundation

/// The languages the default recognizer transcribes, as ISO 639-1 codes.
///
/// Granite takes no language prompt and emits no language tag, so a transcript's language is read
/// from its own text: Japanese by script, the others by function words. The text stage runs its
/// English-only steps only for English or an undetermined language.
public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case japanese = "ja"

    /// Whether a transcript in `language` gets the English-only text rules: spoken formatting
    /// commands, filler removal, phonetic vocabulary repair and term suggestions. Their words are
    /// ordinary words elsewhere (Portuguese *um* is "a", Spanish *capital* is "capital"), so only
    /// English and an undetermined transcript keep them.
    public static func usesEnglishRules(_ language: DictationLanguage?) -> Bool {
        language == nil || language == .english
    }

    /// The language of `text`, or nil when its words do not settle it.
    ///
    /// Kana, or a mostly Han text, is Japanese. Otherwise every word found in a language's
    /// function-word list adds `1/n` to each of the `n` languages listing it, and a few letters only
    /// some of these languages use add half that; the winner needs at least 1.5, so no single word
    /// decides, and a lead of 0.5. Short or code-like text (`OK`, `kubectl apply`, spelled letters)
    /// stays undetermined.
    public static func detect(_ text: String) -> DictationLanguage? {
        if isJapanese(text) { return .japanese }
        var scores: [DictationLanguage: Double] = [:]
        for word in words(in: text) {
            if let languages = functionWords[word] {
                for language in languages { scores[language, default: 0] += 1 / Double(languages.count) }
            }
            for (letter, languages) in distinctiveLetters where word.contains(letter) {
                for language in languages { scores[language, default: 0] += 0.5 / Double(languages.count) }
            }
        }
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        guard let best = ranked.first, best.value >= 1.5 else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        return best.value - runnerUp >= 0.5 ? best.key : nil
    }

    /// Kana anywhere, or Han for at least 30% of the letters: Granite's only CJK language.
    private static func isJapanese(_ text: String) -> Bool {
        var han = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: han += 1
            default: break
            }
        }
        return letters > 0 && han * 10 >= letters * 3
    }

    /// Lowercased words split at anything but letters and apostrophes. An elided French or Italian
    /// article keeps its apostrophe (`l'homme` → `l'`, `homme`); an English contraction becomes its
    /// stem and tail (`don't` → `don`, `'t`). Lone letters without an apostrophe are spelled letters,
    /// not words, so only those that are words on their own (`i`, `o`, `e`, `y`) can score.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for piece in normalized.split(whereSeparator: { !($0.isLetter || $0 == "'") }) {
            let token = piece.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard let apostrophe = token.firstIndex(of: "'") else {
                if !token.isEmpty { words.append(token) }
                continue
            }
            let head = String(token[..<apostrophe])
            let tail = String(token[token.index(after: apostrophe)...])
            if contractionTails.contains(tail) {
                words.append(head)
                words.append("'" + tail)
            } else if elisionHeads.contains(head) {
                words.append(head + "'")
                words.append(contentsOf: tail.split(separator: "'").map(String.init))
            } else {
                words.append(contentsOf: token.split(separator: "'").map(String.init))
            }
        }
        return words
    }

    private static let elisionHeads: Set<String> = [
        "l", "d", "j", "qu", "n", "c", "s", "m", "t", "jusqu", "lorsqu", "puisqu", "un", "dell", "all", "nell",
        "dall", "sull", "quell",
    ]
    private static let contractionTails: Set<String> = ["t", "s", "m", "re", "ve", "ll", "d"]

    private static let distinctiveLetters: [(Character, [DictationLanguage])] = [
        ("ñ", [.spanish]), ("ã", [.portuguese]), ("õ", [.portuguese]), ("ß", [.german]), ("ä", [.german]),
        ("ö", [.german]), ("ü", [.german]), ("ç", [.french, .portuguese]), ("ù", [.french, .italian]),
        ("è", [.french, .italian]), ("ì", [.italian]), ("ò", [.italian]), ("â", [.french, .portuguese]),
        ("ê", [.french, .portuguese]), ("î", [.french]), ("û", [.french]),
    ]

    private static let lists: [DictationLanguage: [String]] = [
        .english: [
            "the", "and", "of", "to", "is", "that", "it", "for", "with", "this", "you", "are", "was", "have", "be",
            "on", "not", "what", "but", "they", "we", "at", "or", "by", "from", "he", "she", "his", "her", "there",
            "their", "would", "can", "will", "just", "so", "if", "about", "which", "do", "my", "me", "all", "has",
            "been", "were", "how", "when", "your", "our", "an", "i", "in", "no", "as", "come", "yeah", "okay", "ok",
            "plus",
            "right", "well", "like", "think", "know", "really", "then", "than", "them", "these", "those", "who",
            "why", "where", "out", "up", "now", "one", "some", "more", "very", "could", "should", "did", "does",
            "had", "get", "got", "going", "because", "here", "us", "him", "its", "into", "after", "before",
            "other", "only", "any", "um", "uh", "uhm", "erm", "hmm", "mmm", "'t", "'s", "'m", "'re", "'ve", "'ll",
            "'d",
        ],
        .french: [
            "le", "la", "les", "des", "du", "une", "est", "et", "en", "que", "qui", "dans", "pour", "pas", "sur",
            "au", "aux", "avec", "ce", "cette", "il", "elle", "nous", "vous", "ils", "elles", "sont", "mais", "ou",
            "où", "je", "ne", "plus", "par", "son", "sa", "ses", "leur", "été", "être", "très", "aussi", "comme",
            "tout", "fait", "on", "un", "me", "se", "l'", "d'", "j'", "qu'", "n'", "c'", "s'", "m'", "t'",
            "jusqu'", "lorsqu'", "puisqu'", "de", "à", "ces", "lui", "ont", "était", "peut", "notre", "votre",
            "alors", "donc", "car", "bien", "entre", "sans", "sous", "chez", "quand", "si",
        ],
        .german: [
            "der", "die", "das", "und", "ist", "nicht", "ein", "eine", "einen", "zu", "den", "dem", "des", "mit",
            "von", "auf", "für", "sich", "auch", "es", "ich", "sie", "wir", "ihr", "sind", "wird", "werden", "war",
            "wurde", "im", "bei", "nach", "aus", "wie", "oder", "aber", "noch", "nur", "dass", "kann", "über",
            "haben", "hat", "in", "so", "an", "was", "will", "bin", "wo", "wer",
        ],
        .spanish: [
            "el", "la", "los", "las", "de", "del", "que", "y", "en", "un", "una", "es", "por", "con", "para", "se",
            "no", "lo", "al", "como", "más", "pero", "sus", "su", "le", "ya", "este", "esta", "son", "ha", "fue",
            "muy", "también", "porque", "cuando", "donde", "está", "están", "hay", "yo", "nos", "me", "han", "otra",
            "otras", "otro", "otros", "unos", "unas", "sin", "ser", "tiene", "tienen", "puede", "ellos", "ellas",
            "aquí", "ahora", "entonces", "dos", "entre", "sobre", "desde", "hasta", "según", "qué", "quién", "cuál",
            "si",
        ],
        .portuguese: [
            "o", "os", "as", "de", "do", "da", "dos", "das", "que", "e", "em", "um", "uma", "é", "não", "para",
            "com", "por", "se", "na", "no", "nos", "nas", "mais", "ao", "como", "mas", "foi", "são", "está",
            "também", "muito", "ele", "ela", "isso", "este", "esta", "pelo", "pela", "eu", "você", "tem", "têm",
            "há", "ainda", "até", "seu", "sua", "seus", "suas", "aqui", "agora", "então", "sem", "à", "às", "aos",
            "nesse", "nessa", "neste", "nesta", "deste", "desta", "num", "numa", "pelos", "pelas", "lhe", "porém",
            "entanto", "embora", "onde", "quando", "após", "já", "entre", "sobre",
        ],
        .italian: [
            "il", "lo", "la", "gli", "le", "di", "del", "della", "dei", "delle", "che", "e", "è", "in", "un",
            "una", "per", "con", "non", "si", "da", "al", "alla", "sono", "ma", "come", "anche", "più", "questo",
            "questa", "nel", "nella", "ha", "era", "molto", "perché", "quando", "dove", "i", "io", "ci", "o", "l'",
            "c'", "un'", "dell'", "all'", "nell'", "dall'", "sull'", "quell'", "ad", "ed", "nei", "negli", "agli",
            "sul", "sulla", "tra", "fra", "loro", "suo", "sua", "suoi", "essere", "stato", "stati", "stata", "sia",
            "ancora", "dopo", "poi", "così", "solo", "tutto", "tutti",
        ],
    ]

    private static let functionWords: [String: [DictationLanguage]] = {
        var table: [String: [DictationLanguage]] = [:]
        for language in DictationLanguage.allCases {
            for word in lists[language] ?? [] where !(table[word]?.contains(language) ?? false) {
                table[word, default: []].append(language)
            }
        }
        return table
    }()
}
