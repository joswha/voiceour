import Foundation
import Testing

@testable import VoiceCore

private func skillFileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = try #require(attributes[.posixPermissions] as? Int)
    return mode & 0o777
}

private func skillFileModified(_ url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.modificationDate] as? Date)
}

/// Covers the agent skill the store keeps at `skills/voiceour-memory/SKILL.md`:
/// written owner-only when missing or stale, left alone when current, written
/// by every `apply` that writes something and by none that writes nothing,
/// always before the `pages-format` stamp, and removed by Clear Memory.
@Suite("Memory skill file")
struct MemorySkillFileTests {
    /// A store whose root holds a space, as the real support folder does.
    private func temporaryStore() -> (store: MemoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (MemoryStore(root: directory.appendingPathComponent("Voiceour memory", isDirectory: true)), directory)
    }

    private func expectedSkill(_ store: MemoryStore) -> Data {
        Data(MemoryPages.agentSkill(root: store.root).utf8)
    }

    @Test func theSkillIsWrittenOwnerOnlyWithTheRenderedBytes() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.writeAgentSkill()

        let skillFolder = store.agentSkillURL.deletingLastPathComponent()
        #expect(store.agentSkillURL == store.root.appendingPathComponent("skills/voiceour-memory/SKILL.md"))
        #expect(try Data(contentsOf: store.agentSkillURL) == expectedSkill(store))
        #expect(try skillFileMode(store.agentSkillURL) == 0o600)
        #expect(try skillFileMode(skillFolder) == 0o700)
        #expect(try skillFileMode(skillFolder.deletingLastPathComponent()) == 0o700)
        #expect(try skillFileMode(store.root) == 0o700)
    }

    @Test func aCurrentSkillIsNotRewritten() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.writeAgentSkill()
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: store.agentSkillURL.path)

        try store.writeAgentSkill()
        try store.apply(MemoryWrite(pages: [MemoryPage(path: "days/2026-11-10.md", text: "# 2026-11-10, Tuesday\n")]))

        #expect(try skillFileModified(store.agentSkillURL) == earlier)
    }

    @Test func aSkillNamingAnotherRootIsRewritten() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.writeAgentSkill()
        let moved = MemoryStore(root: directory.appendingPathComponent("Moved memory", isDirectory: true))
        try FileManager.default.moveItem(at: store.root, to: moved.root)
        #expect(try Data(contentsOf: moved.agentSkillURL) == expectedSkill(store))

        try moved.writeAgentSkill()

        #expect(try Data(contentsOf: moved.agentSkillURL) == expectedSkill(moved))
        #expect(expectedSkill(moved) != expectedSkill(store))
    }

    @Test func anApplyThatWritesSomethingWritesTheSkill() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.apply(MemoryWrite(pages: [MemoryPage(path: "days/2026-11-10.md", text: "# 2026-11-10, Tuesday\n")]))

        #expect(try Data(contentsOf: store.agentSkillURL) == expectedSkill(store))
        #expect(try skillFileMode(store.agentSkillURL) == 0o600)
    }

    @Test func anApplyThatWritesNothingCreatesNothing() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.apply(MemoryWrite())

        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    /// A rebuild whose skill cannot be written leaves the stamp unwritten, so
    /// the stamp still names a format only once everything before it landed.
    @Test func theSkillIsWrittenBeforeTheStamp() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let blocker = store.root.appendingPathComponent("skills")
        try Data("not a folder\n".utf8).write(to: blocker)
        let page = MemoryPage(path: "days/2026-11-10.md", text: "# 2026-11-10, Tuesday\n")

        #expect(throws: (any Error).self) {
            try store.apply(MemoryWrite(pages: [page], pagesFormat: "2 gregorian GMT"))
        }

        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(page.path).path))
        #expect(!FileManager.default.fileExists(atPath: store.pagesFormatURL.path))

        try FileManager.default.removeItem(at: blocker)
        try store.apply(MemoryWrite(pages: [page], pagesFormat: "2 gregorian GMT"))

        #expect(try Data(contentsOf: store.agentSkillURL) == expectedSkill(store))
        #expect(store.pagesFormat() == "2 gregorian GMT")
    }

    @Test func clearRemovesTheSkill() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.writeAgentSkill()

        try store.clear()

        #expect(!FileManager.default.fileExists(atPath: store.agentSkillURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }
}
