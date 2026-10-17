import Foundation
import VoiceCore

/// Swift's answer, string by string, for every primitive the Rust port re-implements:
/// Characters and their properties, case mapping and folding, canonical equivalence and
/// ordering, Foundation trimming/splitting, the ICU alias and token patterns, and the
/// public VoiceCore helpers built on them. `text-bench oracle-check` recomputes each field
/// in Rust and reports every disagreement.
enum OracleCommand {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let tokenPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9+#/_-]+(?:\.[A-Za-z0-9+#/_-]+)*"#)

    /// Decoded with `JSONDecoder`: `JSONSerialization` drops a string's leading U+FEFF.
    private struct Row: Decodable {
        let s: String
        let t: String
        let alias: String
    }

    static func run(_ arguments: Arguments) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: try arguments.required("in")))
        let decoder = JSONDecoder()
        var lines: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            let row = try decoder.decode(Row.self, from: Data(line))
            lines.append(IO.jsonLine(answers(s: row.s, t: row.t, alias: row.alias)))
        }
        try IO.writeLines(lines, to: try arguments.required("out"))
        FileHandle.standardError.write(Data("oracle: \(lines.count) rows\n".utf8))
    }

    private static func ranges(_ matches: [NSTextCheckingResult]) -> [[Int]] {
        matches.map { [$0.range.location, $0.range.length] }
    }

    /// `Glossary.aliasRegex` / `VocabularyRepairEngine.aliasPattern`.
    private static func aliasRegex(_ alias: String) -> NSRegularExpression? {
        let parts = alias.split(whereSeparator: { $0.isWhitespace }).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !parts.isEmpty else { return nil }
        let pattern = "(?i)(?<![A-Za-z0-9_])" + parts.joined(separator: "\\s+") + "(?![A-Za-z0-9_])"
        return try? NSRegularExpression(pattern: pattern)
    }

    /// `canonicalTokens(in:)` (Glossary.swift:174-191), restated.
    private static func canonicalTokens(_ canonical: String) -> [String] {
        var tokenized = canonical.replacingOccurrences(of: "[\\s._-]+", with: " ", options: .regularExpression)
        for (pattern, replacement) in [
            ("([A-Z]+)([A-Z][a-z])", "$1 $2"), ("([a-z])([A-Z])", "$1 $2"),
            ("([A-Za-z])([0-9])", "$1 $2"), ("([0-9])([A-Za-z])", "$1 $2"),
        ] {
            tokenized = tokenized.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return tokenized.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `CleanupEngine.normalize(_:)` (internal), restated.
    private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func answers(s: String, t: String, alias: String) -> [String: Any] {
        let characters = Array(s)
        let props: [Int] = characters.map { c in
            (c.isLetter ? 1 : 0) | (c.isNumber ? 2 : 0) | (c.isWhitespace ? 4 : 0) | (c.isUppercase ? 8 : 0)
                | (c.isLowercase ? 16 : 0)
        }
        let fullRange = NSRange(s.startIndex..<s.endIndex, in: s)
        let aliasMatches = aliasRegex(alias).map { ranges($0.matches(in: s, range: fullRange)) }
        let nfkdASCII = String(
            String.UnicodeScalarView(s.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.value < 128 }))
        let term = ProtectedTerm(canonical: alias.isEmpty ? "x" : alias, spokenAliases: [t])
        return [
            "graphemes": characters.map { String($0).utf8.count },
            "props": props,
            "lower": s.lowercased(),
            "upper": s.uppercased(),
            "fold": s.folding(options: [.caseInsensitive], locale: posix),
            "nfkd_ascii": nfkdASCII,
            "eq": s == t,
            "lt": s < t,
            "gt": t < s,
            "has_prefix": [s.hasPrefix(t), s.hasPrefix("-")],
            // Literal needles, exactly as CleanupEngine spells them.
            "contains": [s.contains("/"), s.contains(" "), s.contains("~"), s.contains("_")],
            "trim_ws": s.trimmingCharacters(in: .whitespacesAndNewlines),
            "trim_ps": s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)),
            "components": s.components(separatedBy: .whitespacesAndNewlines),
            "strip_punct": s.components(separatedBy: .punctuationCharacters).joined(),
            "split_space": s.split(separator: " ").map(String.init),
            "split_ws": s.split(whereSeparator: \.isWhitespace).map(String.init),
            "count": s.count,
            "alias_matches": aliasMatches as Any,
            "token_matches": ranges(tokenPattern.matches(in: s, range: fullRange)),
            "canonical_tokens": canonicalTokens(s),
            "derived_aliases": Glossary.derivedAliases(for: s),
            "can_generalize": Glossary.aliasCanGeneralize(s, canonical: t),
            "normalize": normalize(s),
            "literal": LiteralComposition.apply(s),
            "clean": CleanupEngine.clean(s, glossary: []),
            "canonicalize": Glossary.canonicalize(s, terms: [term]),
        ]
    }
}
