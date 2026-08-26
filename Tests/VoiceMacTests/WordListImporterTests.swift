import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("WordListImporterTests")
struct WordListImporterTests {
    // MARK: - Fixtures

    /// Creates an isolated temp directory that is torn down when `body` returns.
    private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "WordListImporterTests-\(UUID().uuidString)"
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        return try body(directory)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Plain newline lists

    @Test func plainNewlineListImportsAndTagsTerms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("Kubernetes\nGraphQL\nParakeet\n", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["Kubernetes", "GraphQL", "Parakeet"])

            for term in terms {
                #expect(term.source == .manualImport)
                #expect(term.protected == false)
                #expect(term.casePolicy == .exact)
                #expect(term.spokenAliases.isEmpty)
                #expect(term.termId == term.canonical)
            }
        }
    }

    @Test func blankAndWhitespaceLinesAreDropped() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("alpha\n\n   \nbeta\n\t\n", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["alpha", "beta"])
        }
    }

    @Test func handlesCarriageReturnLineEndings() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("gamma\r\ndelta\r\n", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["gamma", "delta"])
        }
    }

    // MARK: - JSON lists

    @Test func jsonArrayListImportsAndTagsTerms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write("[\"Postgres\", \"Redis\", \"Envoy\"]", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["Postgres", "Redis", "Envoy"])
            for term in terms {
                #expect(term.source == .manualImport)
                #expect(term.protected == false)
            }
        }
    }

    // MARK: - Heard-as rows

    @Test func jsonRowsCarryHeardAsForms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write(
                """
                [
                  {"term": "kubectl", "heard_as": ["Qbectal", "cubectal"]},
                  {"term": "worktree", "heard_as": ["work tree"]}
                ]
                """,
                to: file
            )

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["kubectl", "worktree"])
            #expect(terms[0].spokenAliases == ["Qbectal", "cubectal"])
            #expect(terms[1].spokenAliases == ["work tree"])
            for term in terms {
                #expect(term.source == .manualImport)
                #expect(term.protected == false)
                #expect(term.casePolicy == .exact)
                #expect(term.termId == term.canonical)
                #expect(term.labeledAliases.isEmpty)
            }
        }
    }

    @Test func rowWithoutHeardAsImportsAsBareTerm() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write("[{\"term\": \"SwiftUI\"}, {\"term\": \"ggml\", \"heard_as\": []}]", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["SwiftUI", "ggml"])
            #expect(terms.allSatisfy { $0.spokenAliases.isEmpty })
        }
    }

    /// A term already matches its own surface case-insensitively, so echoing the
    /// canonical back as a heard-as form would add a rule that can only fire
    /// where the term already fired.
    @Test func heardAsFormsDropTheCanonicalAndCaseDuplicates() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write(
                "[{\"term\": \"Ghostty\", \"heard_as\": [\"ghostty\", \"Ghosty\", \"GHOSTY\", \" Ghosty \"]}]",
                to: file
            )

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["Ghostty"])
            #expect(terms[0].spokenAliases == ["Ghosty"])
        }
    }

    @Test func unsafeHeardAsFormsAreDroppedWithoutLosingSiblings() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write(
                "[{\"term\": \"notarytool\", \"heard_as\": [\"evil`form\", \"<script>\", \"Natera tool\"]}]",
                to: file
            )

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["notarytool"])
            #expect(terms[0].spokenAliases == ["Natera tool"])
        }
    }

    /// One cap covers both, because a heard-as form is as much a surface as the
    /// spelling is: `maxTermLength` drops `toolong`, then `maxAliasesPerTerm`
    /// stops after two survivors.
    @Test func heardAsFormsObeyLengthAndCountCaps() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write(
                "[{\"term\": \"f16\", \"heard_as\": [\"toolong\", \"aaa\", \"bbb\", \"ccc\"]}]",
                to: file
            )

            let limits = WordListLimits(maxTerms: 100, maxTermLength: 5, maxAliasesPerTerm: 2)
            let terms = try WordListImporter.importWordList(from: file, limits: limits)

            #expect(terms.map(\.canonical) == ["f16"])
            #expect(terms[0].spokenAliases == ["aaa", "bbb"])
        }
    }

    /// The heard-as forms are what makes an imported term able to repair a real
    /// mishearing, so the whole path has to hold: import, then canonicalize.
    @Test func importedHeardAsFormsCanonicalizeDictatedText() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write("[{\"term\": \"kubectl\", \"heard_as\": [\"Qbectal\"]}]", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(Glossary.canonicalize("run qbectal apply now", terms: terms) == "run kubectl apply now")
        }
    }

    // MARK: - Sanitization / caps

    @Test func unsafeEntriesAreDropped() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            // Backticks, angle-bracket delimiters, and control chars are unsafe.
            try write("safeTerm\nevil`code\n<script>\nbad\u{202E}term\nkeeper\n", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["safeTerm", "keeper"])
        }
    }

    @Test func oversizeEntriesAreDroppedByLengthCap() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            let long = String(repeating: "x", count: 10)
            try write("short\n\(long)\ntiny\n", to: file)

            let limits = WordListLimits(maxTerms: 100, maxTermLength: 5)
            let terms = try WordListImporter.importWordList(from: file, limits: limits)

            #expect(terms.map(\.canonical) == ["short", "tiny"])
        }
    }

    @Test func termCountIsCappedByMaxTerms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("one\ntwo\nthree\nfour\n", to: file)

            let limits = WordListLimits(maxTerms: 2, maxTermLength: 64)
            let terms = try WordListImporter.importWordList(from: file, limits: limits)

            #expect(terms.map(\.canonical) == ["one", "two"])
        }
    }

    @Test func duplicateEntriesAreDeduplicated() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("repeat\nunique\nrepeat\n", to: file)

            let terms = try WordListImporter.importWordList(from: file)

            #expect(terms.map(\.canonical) == ["repeat", "unique"])
        }
    }

    // MARK: - Symlink containment

    @Test func symlinkWithinParentDirectoryIsFollowed() throws {
        try withTempDirectory { directory in
            let target = directory.appendingPathComponent("real.txt")
            try write("insideTerm\n", to: target)

            let link = directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let terms = try WordListImporter.importWordList(from: link)

            #expect(terms.map(\.canonical) == ["insideTerm"])
        }
    }

    @Test func symlinkEscapingParentDirectoryIsRejected() throws {
        try withTempDirectory { insideDirectory in
            try withTempDirectory { outsideDirectory in
                let secret = outsideDirectory.appendingPathComponent("secret.txt")
                try write("leaked\n", to: secret)

                let link = insideDirectory.appendingPathComponent("escape.txt")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

                do {
                    _ = try WordListImporter.importWordList(from: link)
                    Issue.record("expected an escaping symlink to be rejected")
                } catch let error as WordListImportError {
                    guard case .symlinkEscapesParentDirectory = error else {
                        Issue.record("unexpected error case: \(error)")
                        return
                    }
                }
            }
        }
    }
}
