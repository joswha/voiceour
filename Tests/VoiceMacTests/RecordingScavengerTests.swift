import Foundation
import Testing

@testable import VoiceMac

@Suite("RecordingScavengerTests")
struct RecordingScavengerTests {
    @Test func sweepDeletesOnlyStaleRegularFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "RecordingScavengerTests-\(UUID().uuidString)"
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let oldFile = directory.appendingPathComponent("old.wav")
        let freshFile = directory.appendingPathComponent("fresh.wav")
        try Data("old".utf8).write(to: oldFile)
        try Data("fresh".utf8).write(to: freshFile)

        let now = Date()
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7200)],
            ofItemAtPath: oldFile.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshFile.path
        )

        RecordingScavenger.sweep(directory: directory, olderThan: 3600, now: now)

        #expect(!fileManager.fileExists(atPath: oldFile.path))
        #expect(fileManager.fileExists(atPath: freshFile.path))
    }

    @Test func sweepTreatsMissingDirectoryAsNoOp() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingScavengerTests-missing-\(UUID().uuidString)"
        )

        RecordingScavenger.sweep(directory: directory)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
