enum Phonetics {
    /// Produces a deterministic, lightweight pronunciation for a surface form.
    ///
    /// The mapper is intentionally small rather than linguistically complete. It
    /// separates camel-case, acronym, and digit boundaries, expands acronyms and
    /// digits as spoken names, and applies common English grapheme rules.
    static func phones(for surface: String) -> [String] {
        var result: [String] = []

        for token in splitTokens(surface) {
            if token.allSatisfy({ $0.isNumber }) {
                for digit in token {
                    result.append(contentsOf: digitPhones[digit] ?? ["DIGIT_" + String(digit)])
                }
            } else if token.allSatisfy({ $0.isUppercase }) {
                for letter in token {
                    result.append(contentsOf: letterNamePhones[letter] ?? phonesForWord(String(letter)))
                }
            } else {
                result.append(contentsOf: phonesForWord(String(token)))
            }
        }

        return result
    }

    /// Weighted Levenshtein distance over phone sequences.
    ///
    /// Insertions and deletions are slightly cheaper for vowels, while substitutions
    /// between nearby consonants or two vowels cost less than unrelated substitutions.
    static func alignmentDistance(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty else { return b.reduce(0) { $0 + phoneWeight($1) } }
        guard !b.isEmpty else { return a.reduce(0) { $0 + phoneWeight($1) } }

        var previous = [Double](repeating: 0, count: b.count + 1)
        for column in b.indices {
            previous[column + 1] = previous[column] + phoneWeight(b[column])
        }

        var current = [Double](repeating: 0, count: b.count + 1)
        for row in a.indices {
            current[0] = previous[0] + phoneWeight(a[row])

            for column in b.indices {
                let deletion = previous[column + 1] + phoneWeight(a[row])
                let insertion = current[column] + phoneWeight(b[column])
                let substitution = previous[column] + substitutionCost(a[row], b[column])
                current[column + 1] = min(deletion, min(insertion, substitution))
            }

            swap(&previous, &current)
        }

        return previous[b.count]
    }

    /// Returns normalized phonetic similarity in the closed interval `0...1`.
    static func similarity(_ a: String, _ b: String) -> Double {
        let aPhones = phones(for: a)
        let bPhones = phones(for: b)
        let scale = max(
            aPhones.reduce(0) { $0 + phoneWeight($1) },
            bPhones.reduce(0) { $0 + phoneWeight($1) }
        )

        guard scale > 0 else { return 1 }
        let normalized = 1 - alignmentDistance(aPhones, bPhones) / scale
        return min(1, max(0, normalized))
    }

    private enum CharacterKind: Equatable {
        case uppercaseLetter
        case lowercaseLetter
        case digit
        case separator
    }

    private static func splitTokens(_ surface: String) -> [[Character]] {
        let characters = Array(surface)
        var tokens: [[Character]] = []
        var token: [Character] = []

        func finishToken() {
            if !token.isEmpty {
                tokens.append(token)
                token.removeAll(keepingCapacity: true)
            }
        }

        for index in characters.indices {
            let character = characters[index]
            let currentKind = kind(of: character)
            guard currentKind != .separator else {
                finishToken()
                continue
            }

            if let previous = token.last {
                let previousKind = kind(of: previous)
                let nextKind: CharacterKind? = {
                    let nextIndex = characters.index(after: index)
                    guard nextIndex < characters.endIndex else { return nil }
                    return kind(of: characters[nextIndex])
                }()

                let changesBetweenLetterAndDigit =
                    (currentKind == .digit && previousKind != .digit)
                    || (currentKind != .digit && previousKind == .digit)
                let startsCamelCase =
                    previousKind == .lowercaseLetter && currentKind == .uppercaseLetter
                let endsAcronym =
                    previousKind == .uppercaseLetter && currentKind == .uppercaseLetter && nextKind == .lowercaseLetter

                if changesBetweenLetterAndDigit || startsCamelCase || endsAcronym {
                    finishToken()
                }
            }

            token.append(character)
        }

        finishToken()
        return tokens
    }

    private static func kind(of character: Character) -> CharacterKind {
        if character.isNumber { return .digit }
        if character.isUppercase { return .uppercaseLetter }
        if character.isLetter { return .lowercaseLetter }
        return .separator
    }

    private static func phonesForWord(_ rawWord: String) -> [String] {
        let word = rawWord.lowercased()
        if let known = wordPhones[word] {
            return known
        }

        let letters = Array(word)
        var result: [String] = []
        var index = 0

        while index < letters.count {
            let letter = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            let next2 = index + 2 < letters.count ? letters[index + 2] : nil
            let next3 = index + 3 < letters.count ? letters[index + 3] : nil

            if letter == "t", next == "i", next2 == "o", next3 == "n" {
                result.append(contentsOf: ["SH", "AH", "N"])
                index += 4
                continue
            }
            if letter == "t", next == "c", next2 == "h" {
                result.append("CH")
                index += 3
                continue
            }
            if letter == "d", next == "g", next2 == "e" {
                result.append("JH")
                index += 3
                continue
            }
            if letter == "i", next == "g", next2 == "h" {
                result.append("AY")
                index += 3
                continue
            }

            if let pairPhones = phonesForPair(letter, next) {
                result.append(contentsOf: pairPhones)
                index += 2
                continue
            }

            if letter == "e", index == letters.count - 1, letters.count > 2 {
                index += 1
                continue
            }

            if index > 0,
                letter == letters[index - 1],
                !isVowelLetter(letter)
            {
                index += 1
                continue
            }

            if isVowelLetter(letter),
                index + 2 == letters.count - 1,
                next.map({ !isVowelLetter($0) }) == true,
                letters.last == "e"
            {
                result.append(contentsOf: longVowelPhones[letter] ?? [])
                index += 1
                continue
            }

            result.append(contentsOf: phonesForLetter(letter, followedBy: next))
            index += 1
        }

        return result
    }

    private static func phonesForPair(_ first: Character, _ second: Character?) -> [String]? {
        switch (first, second) {
        case ("c", "h"): return ["CH"]
        case ("s", "h"): return ["SH"]
        case ("t", "h"): return ["TH"]
        case ("p", "h"): return ["F"]
        case ("n", "g"): return ["NG"]
        case ("q", "u"): return ["K", "W"]
        case ("c", "k"): return ["K"]
        case ("w", "h"): return ["W"]
        case ("w", "r"): return ["R"]
        case ("k", "n"): return ["N"]
        case ("e", "e"), ("e", "a"): return ["IY"]
        case ("o", "o"): return ["UW"]
        case ("a", "i"), ("a", "y"): return ["EY"]
        case ("o", "i"), ("o", "y"): return ["OY"]
        case ("o", "u"), ("o", "w"): return ["AW"]
        case ("a", "u"), ("a", "w"): return ["AO"]
        case ("e", "r"), ("i", "r"), ("u", "r"): return ["ER"]
        default: return nil
        }
    }

    private static func phonesForLetter(_ letter: Character, followedBy next: Character?) -> [String] {
        switch letter {
        case "a": return ["AE"]
        case "b": return ["B"]
        case "c": return next == "e" || next == "i" || next == "y" ? ["S"] : ["K"]
        case "d": return ["D"]
        case "e": return ["EH"]
        case "f": return ["F"]
        case "g": return next == "e" || next == "i" || next == "y" ? ["JH"] : ["G"]
        case "h": return ["HH"]
        case "i": return ["IH"]
        case "j": return ["JH"]
        case "k": return ["K"]
        case "l": return ["L"]
        case "m": return ["M"]
        case "n": return ["N"]
        case "o": return ["AA"]
        case "p": return ["P"]
        case "q": return ["K"]
        case "r": return ["R"]
        case "s": return ["S"]
        case "t": return ["T"]
        case "u": return ["AH"]
        case "v": return ["V"]
        case "w": return ["W"]
        case "x": return ["K", "S"]
        case "y": return next.map({ isVowelLetter($0) }) == true ? ["Y"] : ["IY"]
        case "z": return ["Z"]
        default: return ["LETTER_" + String(letter).uppercased()]
        }
    }

    private static func isVowelLetter(_ letter: Character) -> Bool {
        letter == "a" || letter == "e" || letter == "i" || letter == "o" || letter == "u"
    }

    private static func phoneWeight(_ phone: String) -> Double {
        vowelPhones.contains(phone) ? 0.75 : 1
    }

    private static func substitutionCost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }

        let aIsVowel = vowelPhones.contains(a)
        let bIsVowel = vowelPhones.contains(b)
        if aIsVowel && bIsVowel { return 0.35 }
        if aIsVowel != bIsVowel { return 1 }
        if voicedPairs.contains(Pair(a, b)) { return 0.2 }
        if consonantFamily(a) == consonantFamily(b) { return 0.45 }
        return 0.9
    }

    private static func consonantFamily(_ phone: String) -> Int {
        if ["P", "B", "M", "F", "V"].contains(phone) { return 1 }
        if ["T", "D", "S", "Z", "N", "L", "R"].contains(phone) { return 2 }
        if ["K", "G", "NG"].contains(phone) { return 3 }
        if ["SH", "ZH", "CH", "JH"].contains(phone) { return 4 }
        if ["W", "Y", "HH"].contains(phone) { return 5 }
        return 0
    }

    private struct Pair: Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            if a <= b {
                first = a
                second = b
            } else {
                first = b
                second = a
            }
        }
    }

    private static let vowelPhones: Set<String> = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW",
    ]

    private static let voicedPairs: Set<Pair> = [
        Pair("P", "B"), Pair("T", "D"), Pair("K", "G"), Pair("F", "V"),
        Pair("S", "Z"), Pair("SH", "ZH"), Pair("CH", "JH"),
    ]

    private static let longVowelPhones: [Character: [String]] = [
        "a": ["EY"], "e": ["IY"], "i": ["AY"], "o": ["OW"], "u": ["Y", "UW"],
    ]

    private static let wordPhones: [String: [String]] = [
        "cache": ["K", "AE", "SH"],
        "cash": ["K", "AE", "SH"],
        "cube": ["K", "Y", "UW", "B"],
        "cuddle": ["K", "AH", "D", "AH", "L"],
        "kubectl": ["K", "Y", "UW", "B", "K", "AH", "D", "AH", "L"],
    ]

    private static let digitPhones: [Character: [String]] = [
        "0": ["Z", "IH", "R", "OW"],
        "1": ["W", "AH", "N"],
        "2": ["T", "UW"],
        "3": ["TH", "R", "IY"],
        "4": ["F", "AO", "R"],
        "5": ["F", "AY", "V"],
        "6": ["S", "IH", "K", "S"],
        "7": ["S", "EH", "V", "AH", "N"],
        "8": ["EY", "T"],
        "9": ["N", "AY", "N"],
    ]

    private static let letterNamePhones: [Character: [String]] = [
        "A": ["EY"], "B": ["B", "IY"], "C": ["S", "IY"], "D": ["D", "IY"],
        "E": ["IY"], "F": ["EH", "F"], "G": ["JH", "IY"], "H": ["EY", "CH"],
        "I": ["AY"], "J": ["JH", "EY"], "K": ["K", "EY"], "L": ["EH", "L"],
        "M": ["EH", "M"], "N": ["EH", "N"], "O": ["OW"], "P": ["P", "IY"],
        "Q": ["K", "Y", "UW"], "R": ["AA", "R"], "S": ["EH", "S"], "T": ["T", "IY"],
        "U": ["Y", "UW"], "V": ["V", "IY"], "W": ["D", "AH", "B", "AH", "L", "Y", "UW"],
        "X": ["EH", "K", "S"], "Y": ["W", "AY"], "Z": ["Z", "IY"],
    ]
}
