import Foundation
import VoiceCore

/// Caps applied when importing an untrusted word list. Bounds the number of
/// accepted terms, the length of any single term, and how many spoken forms one
/// term may claim, so a hostile or accidentally huge file cannot flood the
/// active vocabulary.
public struct WordListLimits: Equatable, Sendable {
    public var maxTerms: Int
    public var maxTermLength: Int
    public var maxAliasesPerTerm: Int

    public init(maxTerms: Int, maxTermLength: Int, maxAliasesPerTerm: Int = 8) {
        self.maxTerms = maxTerms
        self.maxTermLength = maxTermLength
        self.maxAliasesPerTerm = maxAliasesPerTerm
    }

    public static var `default`: WordListLimits {
        WordListLimits(maxTerms: 500, maxTermLength: 64, maxAliasesPerTerm: 8)
    }
}

/// Failures raised while importing a word list.
enum WordListImportError: Error, Equatable, LocalizedError {
    /// The selected file is (or points through) a symlink whose target resolves
    /// outside the selected file's own parent directory.
    case symlinkEscapesParentDirectory(selected: URL, resolved: URL, parent: URL)
    /// The file could not be read or decoded as UTF-8 text.
    case unreadableFile(URL)

    var errorDescription: String? {
        switch self {
        case .symlinkEscapesParentDirectory(let selected, let resolved, let parent):
            return
                "Refusing to import \"\(selected.lastPathComponent)\": it resolves to \(resolved.path), which is outside its parent directory \(parent.path)."
        case .unreadableFile(let url):
            return "Could not read the word list at \(url.path) as UTF-8 text."
        }
    }
}

/// Deterministic, injectable importer for user-selected word lists.
///
/// The core entry point is URL-based and side-effect-free beyond reading the
/// referenced file, so it is fully unit-testable with temp files. File selection
/// (e.g. `NSOpenPanel`) lives in the UI layer and is deliberately not part of
/// this type.
///
/// Imported terms are tagged `source == .manualImport` and `protected == false`:
/// an untrusted list is ordinary learned vocabulary, never a curated protected
/// term.
public enum WordListImporter {
    /// Reads a word list from `url`, sanitizes and caps the entries, and returns
    /// them as unprotected manual-import terms.
    ///
    /// Three shapes are accepted, in this order: a JSON array of spellings, a
    /// JSON array of `{"term": ..., "heard_as": [...]}` rows, and a
    /// newline-delimited list of spellings. The middle shape exists because a
    /// spelling alone cannot fix a term the model mishears rather than merely
    /// respaces: `Glossary.derivedAliases` recovers `Swift UI` from `SwiftUI`
    /// for free, but nothing derives `Qbectal` from `kubectl`, so the surfaces
    /// have to come from the file. `heard_as` is the field name the Glossary
    /// tab shows, so a hand-edited file reads like the editor it is edited in.
    ///
    /// - Throws: `WordListImportError.symlinkEscapesParentDirectory` if the file
    ///   resolves outside its parent directory, or
    ///   `WordListImportError.unreadableFile` if it cannot be read/decoded.
    public static func importWordList(
        from url: URL,
        limits: WordListLimits = .default
    ) throws -> [ProtectedTerm] {
        try rejectSymlinkEscape(url)

        guard let data = try? Data(contentsOf: url) else {
            throw WordListImportError.unreadableFile(url)
        }

        let rawEntries = try parseEntries(from: data, url: url)
        return buildTerms(from: rawEntries, limits: limits)
    }

    // MARK: - Symlink containment

    /// Throws if `url` resolves (through any symlink) to a location outside its own
    /// parent directory. The parent and target are both resolved so the comparison
    /// is immune to macOS path aliasing (e.g. `/tmp` -> `/private/tmp`).
    private static func rejectSymlinkEscape(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath()
        let resolvedFile = url.resolvingSymlinksInPath()

        let parentComponents = resolvedParent.pathComponents
        let fileComponents = resolvedFile.pathComponents

        let containedInParent =
            fileComponents.count > parentComponents.count
            && Array(fileComponents.prefix(parentComponents.count)) == parentComponents

        if !containedInParent {
            throw WordListImportError.symlinkEscapesParentDirectory(
                selected: url,
                resolved: resolvedFile,
                parent: resolvedParent
            )
        }
    }

    // MARK: - Parsing

    /// One parsed row: the spelling, and the surfaces the file claims dictation
    /// produces for it.
    private struct ParsedEntry {
        let canonical: String
        let heardAs: [String]
    }

    /// The JSON object row. `heardAs` is optional so a row that only names a
    /// spelling stays as valid as the bare-string form it is mixed with.
    private struct WordListRow: Decodable {
        let term: String
        let heardAs: [String]?

        enum CodingKeys: String, CodingKey {
            case term
            case heardAs = "heard_as"
        }
    }

    /// Accepts a JSON array of strings, then a JSON array of `heard_as` rows,
    /// otherwise falls back to a newline-delimited list. Blank lines are dropped
    /// by the caller during sanitization.
    ///
    /// The string array is tried first so a file that parsed before parses
    /// identically now: an array of strings cannot decode as an array of rows,
    /// and neither JSON shape can be mistaken for newline-delimited text.
    private static func parseEntries(from data: Data, url: URL) throws -> [ParsedEntry] {
        if let jsonEntries = try? JSONDecoder().decode([String].self, from: data) {
            return jsonEntries.map { ParsedEntry(canonical: $0, heardAs: []) }
        }
        if let rows = try? JSONDecoder().decode([WordListRow].self, from: data) {
            return rows.map { ParsedEntry(canonical: $0.term, heardAs: $0.heardAs ?? []) }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WordListImportError.unreadableFile(url)
        }
        return
            text
            .split(whereSeparator: { $0.isNewline })
            .map { ParsedEntry(canonical: String($0), heardAs: []) }
    }

    // MARK: - Term construction

    private static func buildTerms(
        from rawEntries: [ParsedEntry],
        limits: WordListLimits
    ) -> [ProtectedTerm] {
        var terms: [ProtectedTerm] = []
        var seen: Set<String> = []

        for entry in rawEntries {
            if terms.count >= limits.maxTerms { break }

            let trimmed = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop empty and unsafe entries; drop anything over the length cap.
            guard !trimmed.isEmpty else { continue }
            guard VocabularySanitizer.isSafe(trimmed) else { continue }
            guard trimmed.count <= limits.maxTermLength else { continue }
            guard seen.insert(trimmed).inserted else { continue }

            terms.append(
                ProtectedTerm(
                    canonical: trimmed,
                    spokenAliases: spokenAliases(from: entry.heardAs, canonical: trimmed, limits: limits),
                    casePolicy: .exact,
                    protected: false,
                    source: .manualImport
                )
            )
        }

        return terms
    }

    /// The heard-as forms one row may contribute: trimmed, safe, length-capped,
    /// count-capped, and deduplicated case-insensitively.
    ///
    /// The canonical is excluded because a term already matches its own surface
    /// case-insensitively, so repeating it as an alias adds a rule that can only
    /// fire where the term already fired. Each surface is filtered rather than
    /// cleaned, matching how the canonical is handled: a row carrying one
    /// unusable form still contributes its usable ones.
    private static func spokenAliases(
        from heardAs: [String],
        canonical: String,
        limits: WordListLimits
    ) -> [String] {
        var aliases: [String] = []
        var seen: Set<String> = [canonical.lowercased()]

        for candidate in heardAs {
            if aliases.count >= limits.maxAliasesPerTerm { break }

            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard VocabularySanitizer.isSafe(trimmed) else { continue }
            guard trimmed.count <= limits.maxTermLength else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }

            aliases.append(trimmed)
        }

        return aliases
    }
}
