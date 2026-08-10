public enum LiteralComposition {
    public static func apply(_ transcript: String) -> String {
        let tokens = tokenize(transcript)
        var output: [Token] = []
        var index = 0
        var changed = false

        while index < tokens.count {
            if let commandEnd = matchWords(["spell", "that"], from: index, in: tokens),
                let operand = wordOperand(after: commandEnd, in: tokens)
            {
                let sequence = wordSequence(from: operand, in: tokens)
                output.append(Token(text: spell(sequence.words), kind: .word))
                index = sequence.end
                changed = true
                continue
            }

            if spokenWord("spell", at: index, in: tokens),
                let operand = wordOperand(after: index + 1, in: tokens)
            {
                let sequence = wordSequence(from: operand, in: tokens)
                output.append(Token(text: spell(sequence.words), kind: .word))
                index = sequence.end
                changed = true
                continue
            }

            if let commandEnd = matchLetterByLetter(from: index, in: tokens),
                let operand = wordOperand(after: commandEnd, in: tokens)
            {
                let sequence = wordSequence(from: operand, in: tokens)
                output.append(Token(text: spell(sequence.words), kind: .word))
                index = sequence.end
                changed = true
                continue
            }

            if spokenWord("literal", at: index, in: tokens),
                let operand = wordOperand(after: index + 1, in: tokens)
            {
                output.append(Token(text: literal(tokens[operand].text), kind: .word))
                index = operand + 1
                changed = true
                continue
            }

            if let commandEnd = matchWords(["snake", "case"], from: index, in: tokens),
                let operand = wordOperand(after: commandEnd, in: tokens)
            {
                let sequence = wordSequence(from: operand, in: tokens)
                output.append(
                    Token(
                        text: sequence.words.map { $0.lowercased() }.joined(separator: "_"),
                        kind: .word
                    ))
                index = sequence.end
                changed = true
                continue
            }

            if let commandEnd = matchWords(["camel", "case"], from: index, in: tokens),
                let operand = wordOperand(after: commandEnd, in: tokens)
            {
                let sequence = wordSequence(from: operand, in: tokens)
                output.append(Token(text: camelCase(sequence.words), kind: .word))
                index = sequence.end
                changed = true
                continue
            }

            if spokenWord("capital", at: index, in: tokens) || spokenWord("uppercase", at: index, in: tokens),
                let operand = wordOperand(after: index + 1, in: tokens)
            {
                output.append(Token(text: tokens[operand].text.uppercased(), kind: .word))
                index = operand + 1
                changed = true
                continue
            }

            if let commandEnd = matchWords(["dash", "dash"], from: index, in: tokens) {
                appendSymbol("--", to: &output)
                index = skipWhitespace(after: commandEnd, in: tokens)
                changed = true
                continue
            }

            if spokenWord("dash", at: index, in: tokens) {
                appendSymbol("-", to: &output)
                index = skipWhitespace(after: index + 1, in: tokens)
                changed = true
                continue
            }

            if spokenWord("dot", at: index, in: tokens) {
                appendSymbol(".", to: &output)
                index = skipWhitespace(after: index + 1, in: tokens)
                changed = true
                continue
            }

            if spokenWord("underscore", at: index, in: tokens) {
                appendSymbol("_", to: &output)
                index = skipWhitespace(after: index + 1, in: tokens)
                changed = true
                continue
            }

            output.append(tokens[index])
            index += 1
        }

        guard changed else { return transcript }
        return output.map(\.text).joined()
    }

    private enum TokenKind {
        case word
        case whitespace
        case punctuation
    }

    private struct Token {
        let text: String
        let kind: TokenKind
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for character in text {
            let kind: TokenKind
            if character.isLetter || character.isNumber {
                kind = .word
            } else if character.isWhitespace {
                kind = .whitespace
            } else {
                kind = .punctuation
            }

            if let last = tokens.last, last.kind == kind {
                tokens[tokens.count - 1] = Token(text: last.text + String(character), kind: kind)
            } else {
                tokens.append(Token(text: String(character), kind: kind))
            }
        }
        return tokens
    }

    private static func word(_ expected: String, matches token: Token) -> Bool {
        token.kind == .word && token.text.lowercased() == expected
    }

    private static func spokenWord(_ expected: String, at index: Int, in tokens: [Token]) -> Bool {
        guard index < tokens.count,
            word(expected, matches: tokens[index]),
            index == 0 || tokens[index - 1].kind == .whitespace
        else {
            return false
        }
        return index + 1 == tokens.count || tokens[index + 1].kind == .whitespace
    }

    private static func matchWords(_ words: [String], from start: Int, in tokens: [Token]) -> Int? {
        guard !words.isEmpty,
            start < tokens.count,
            start == 0 || tokens[start - 1].kind == .whitespace
        else {
            return nil
        }
        var index = start
        for (offset, expected) in words.enumerated() {
            guard index < tokens.count, word(expected, matches: tokens[index]) else { return nil }
            index += 1
            if offset < words.count - 1 {
                guard index < tokens.count, tokens[index].kind == .whitespace else { return nil }
                index += 1
            }
        }
        guard index == tokens.count || tokens[index].kind == .whitespace else { return nil }
        return index
    }

    private static func matchLetterByLetter(from start: Int, in tokens: [Token]) -> Int? {
        if let end = matchWords(["letter", "by", "letter"], from: start, in: tokens) {
            return end
        }

        guard start + 4 < tokens.count,
            start == 0 || tokens[start - 1].kind == .whitespace,
            word("letter", matches: tokens[start]),
            tokens[start + 1].kind == .punctuation,
            tokens[start + 1].text == "-",
            word("by", matches: tokens[start + 2]),
            tokens[start + 3].kind == .punctuation,
            tokens[start + 3].text == "-",
            word("letter", matches: tokens[start + 4])
        else {
            return nil
        }
        let end = start + 5
        guard end == tokens.count || tokens[end].kind == .whitespace else { return nil }
        return end
    }

    private static func wordOperand(after commandEnd: Int, in tokens: [Token]) -> Int? {
        guard commandEnd + 1 < tokens.count,
            tokens[commandEnd].kind == .whitespace,
            tokens[commandEnd + 1].kind == .word
        else {
            return nil
        }
        return commandEnd + 1
    }

    private static func wordSequence(from start: Int, in tokens: [Token]) -> (words: [String], end: Int) {
        var words: [String] = []
        var index = start

        while index < tokens.count, tokens[index].kind == .word {
            words.append(tokens[index].text)
            index += 1
            guard index + 1 < tokens.count,
                tokens[index].kind == .whitespace,
                tokens[index + 1].kind == .word
            else {
                break
            }
            index += 1
        }

        return (words, index)
    }

    private static func spell(_ words: [String]) -> String {
        var result = ""
        var index = 0

        while index < words.count {
            let normalized = words[index].lowercased()
            if normalized == "capital" || normalized == "uppercase", index + 1 < words.count {
                result += words[index + 1].uppercased()
                index += 2
            } else if normalized == "dash", index + 1 < words.count, words[index + 1].lowercased() == "dash" {
                result += "--"
                index += 2
            } else if normalized == "dash" {
                result += "-"
                index += 1
            } else if normalized == "dot" {
                result += "."
                index += 1
            } else if normalized == "underscore" {
                result += "_"
                index += 1
            } else {
                result += words[index]
                index += 1
            }
        }

        return result
    }

    private static func literal(_ word: String) -> String {
        switch word.lowercased() {
        case "dash":
            return "-"
        case "dot":
            return "."
        case "underscore":
            return "_"
        default:
            return word
        }
    }

    private static func camelCase(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        return first.lowercased()
            + words.dropFirst().map { word in
                guard let initial = word.first else { return "" }
                return String(initial).uppercased() + word.dropFirst().lowercased()
            }.joined()
    }

    private static func appendSymbol(_ symbol: String, to output: inout [Token]) {
        if output.last?.kind == .whitespace {
            output.removeLast()
        }
        output.append(Token(text: symbol, kind: .punctuation))
    }

    private static func skipWhitespace(after index: Int, in tokens: [Token]) -> Int {
        guard index < tokens.count, tokens[index].kind == .whitespace else { return index }
        return index + 1
    }
}
