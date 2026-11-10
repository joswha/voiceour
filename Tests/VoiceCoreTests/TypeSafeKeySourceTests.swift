import Foundation
import Testing

@testable import VoiceCore

/// The key's precedence decides which account the sorting model bills, and the
/// file's permissions decide who else on the Mac can read it. Every key here is
/// a fake value and every file lives in a temporary directory.
@Suite("TypeSafeKeySource")
struct TypeSafeKeySourceTests {
    private func writeKeyFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test func theEnvironmentWinsOverTheKeyFile() throws {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeKeyFile("file-key-456", to: url)
        let source = TypeSafeKeySource(environment: [TypeSafeKeySource.variable: "test-key-123"], keyFile: url)
        #expect(source.key() == "test-key-123")
        #expect(source.origin() == .environment)
    }

    @Test func anEnvironmentKeyNeedsNoKeyFile() {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        let source = TypeSafeKeySource(
            environment: [TypeSafeKeySource.variable: "  test-key-123\n"], keyFile: url)
        #expect(source.key() == "test-key-123")
        #expect(source.origin() == .environment)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aBlankEnvironmentValueFallsThroughToTheTrimmedFile() throws {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeKeyFile("\n  test-key-123  \n", to: url)
        let source = TypeSafeKeySource(environment: [TypeSafeKeySource.variable: "  \n"], keyFile: url)
        #expect(source.key() == "test-key-123")
        #expect(source.origin() == .keyFile)
    }

    @Test func noSourceGivesNoKeyAndNoOrigin() throws {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        defer { try? FileManager.default.removeItem(at: directory) }
        let absent = TypeSafeKeySource(environment: [:], keyFile: url)
        #expect(absent.key() == nil)
        #expect(absent.origin() == nil)

        try writeKeyFile(" \n\t", to: url)
        let blank = TypeSafeKeySource(environment: [TypeSafeKeySource.variable: ""], keyFile: url)
        #expect(blank.key() == nil)
        #expect(blank.origin() == nil)
    }

    @Test func saveWritesTheTrimmedKeyOwnerOnly() throws {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TypeSafeKeySource(environment: [:], keyFile: url)
        try source.save("  test-key-123\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "test-key-123")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(source.key() == "test-key-123")
        #expect(source.origin() == .keyFile)
    }

    @Test func aBlankSaveRemovesTheKeyFile() throws {
        let (directory, url) = temporaryCoreTestFile(named: "typesafe.key")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TypeSafeKeySource(environment: [:], keyFile: url)
        try source.save("test-key-123")
        try source.save("   \n")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(source.key() == nil)
        // Forgetting a key that is already gone is not an error.
        try source.save("")
        #expect(source.origin() == nil)
    }
}
