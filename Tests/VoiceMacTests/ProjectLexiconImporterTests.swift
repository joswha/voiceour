import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("ProjectLexiconImporterTests")
struct ProjectLexiconImporterTests {
    // MARK: - Fixtures

    /// Creates an isolated temp directory that is torn down when `body` returns.
    private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "ProjectLexiconImporterTests-\(UUID().uuidString)"
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

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "proj-42")

            #expect(lexicon.projectId == "proj-42")
            #expect(lexicon.terms.map(\.canonical) == ["Kubernetes", "GraphQL", "Parakeet"])

            for term in lexicon.terms {
                #expect(term.source == .manualImport)
                #expect(term.scope == .projectID("proj-42"))
                #expect(term.cloudEligible == false)
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

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "p")

            #expect(lexicon.terms.map(\.canonical) == ["alpha", "beta"])
        }
    }

    @Test func handlesCarriageReturnLineEndings() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("gamma\r\ndelta\r\n", to: file)

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "p")

            #expect(lexicon.terms.map(\.canonical) == ["gamma", "delta"])
        }
    }

    // MARK: - JSON lists

    @Test func jsonArrayListImportsAndTagsTerms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.json")
            try write("[\"Postgres\", \"Redis\", \"Envoy\"]", to: file)

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "svc")

            #expect(lexicon.terms.map(\.canonical) == ["Postgres", "Redis", "Envoy"])
            for term in lexicon.terms {
                #expect(term.source == .manualImport)
                #expect(term.scope == .projectID("svc"))
                #expect(term.cloudEligible == false)
                #expect(term.protected == false)
            }
        }
    }

    // MARK: - Sanitization / caps

    @Test func unsafeEntriesAreDropped() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            // Backticks, angle-bracket delimiters, and control chars are unsafe.
            try write("safeTerm\nevil`code\n<script>\nbad\u{202E}term\nkeeper\n", to: file)

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "p")

            #expect(lexicon.terms.map(\.canonical) == ["safeTerm", "keeper"])
        }
    }

    @Test func oversizeEntriesAreDroppedByLengthCap() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            let long = String(repeating: "x", count: 10)
            try write("short\n\(long)\ntiny\n", to: file)

            let limits = ProjectLexiconLimits(maxTerms: 100, maxTermLength: 5)
            let lexicon = try ProjectLexiconImporter.importLexicon(
                from: file,
                projectId: "p",
                limits: limits
            )

            #expect(lexicon.terms.map(\.canonical) == ["short", "tiny"])
        }
    }

    @Test func termCountIsCappedByMaxTerms() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("one\ntwo\nthree\nfour\n", to: file)

            let limits = ProjectLexiconLimits(maxTerms: 2, maxTermLength: 64)
            let lexicon = try ProjectLexiconImporter.importLexicon(
                from: file,
                projectId: "p",
                limits: limits
            )

            #expect(lexicon.terms.map(\.canonical) == ["one", "two"])
        }
    }

    @Test func duplicateEntriesAreDeduplicated() throws {
        try withTempDirectory { directory in
            let file = directory.appendingPathComponent("words.txt")
            try write("repeat\nunique\nrepeat\n", to: file)

            let lexicon = try ProjectLexiconImporter.importLexicon(from: file, projectId: "p")

            #expect(lexicon.terms.map(\.canonical) == ["repeat", "unique"])
        }
    }

    // MARK: - Symlink containment

    @Test func symlinkWithinParentDirectoryIsFollowed() throws {
        try withTempDirectory { directory in
            let target = directory.appendingPathComponent("real.txt")
            try write("insideTerm\n", to: target)

            let link = directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let lexicon = try ProjectLexiconImporter.importLexicon(from: link, projectId: "p")

            #expect(lexicon.terms.map(\.canonical) == ["insideTerm"])
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
                    _ = try ProjectLexiconImporter.importLexicon(from: link, projectId: "p")
                    Issue.record("expected an escaping symlink to be rejected")
                } catch let error as ProjectLexiconImportError {
                    guard case .symlinkEscapesParentDirectory = error else {
                        Issue.record("unexpected error case: \(error)")
                        return
                    }
                }
            }
        }
    }
}
