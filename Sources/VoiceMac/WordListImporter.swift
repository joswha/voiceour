import Foundation
import VoiceCore

/// Caps applied when importing an untrusted word list. Bounds both the number of
/// accepted terms and the length of any single term so a hostile or accidentally
/// huge file cannot flood the active vocabulary.
public struct WordListLimits: Equatable, Sendable {
    public var maxTerms: Int
    public var maxTermLength: Int

    public init(maxTerms: Int, maxTermLength: Int) {
        self.maxTerms = maxTerms
        self.maxTermLength = maxTermLength
    }

    public static var `default`: WordListLimits {
        WordListLimits(maxTerms: 500, maxTermLength: 64)
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
    /// Reads a newline- or JSON-array word list from `url`, sanitizes and caps the
    /// entries, and returns them as unprotected manual-import terms.
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

    /// Accepts a JSON array of strings, otherwise falls back to a newline-delimited
    /// list. Blank lines are dropped by the caller during sanitization.
    private static func parseEntries(from data: Data, url: URL) throws -> [String] {
        if let jsonEntries = try? JSONDecoder().decode([String].self, from: data) {
            return jsonEntries
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WordListImportError.unreadableFile(url)
        }
        return text.split(whereSeparator: { $0.isNewline }).map(String.init)
    }

    // MARK: - Term construction

    private static func buildTerms(
        from rawEntries: [String],
        limits: WordListLimits
    ) -> [ProtectedTerm] {
        var terms: [ProtectedTerm] = []
        var seen: Set<String> = []

        for raw in rawEntries {
            if terms.count >= limits.maxTerms { break }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop empty and unsafe entries; drop anything over the length cap.
            guard !trimmed.isEmpty else { continue }
            guard VocabularySanitizer.isSafe(trimmed) else { continue }
            guard trimmed.count <= limits.maxTermLength else { continue }
            guard seen.insert(trimmed).inserted else { continue }

            terms.append(
                ProtectedTerm(
                    canonical: trimmed,
                    spokenAliases: [],
                    casePolicy: .exact,
                    protected: false,
                    source: .manualImport
                )
            )
        }

        return terms
    }
}
