import Foundation
import Testing

@testable import VoiceMac

@Suite("RetiredModelCacheSweepTests")
struct RetiredModelCacheSweepTests {
    private func temporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RetiredModelCacheSweepTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func sweepRemovesExactlyTheRetiredDirectories() throws {
        let fileManager = FileManager.default
        let root = try temporaryCacheRoot()
        defer { try? fileManager.removeItem(at: root) }
        for name in ["parakeet-tdt-0.6b-v3-ggml", "parakeet-tdt-0.6b-v3-ggml-q8_0"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        }
        let granite = root.appendingPathComponent("granite-speech-5.0-470m-turboctc-q8_0", isDirectory: true)
        try fileManager.createDirectory(at: granite, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: granite.appendingPathComponent("manifest.json"))
        // A similarly named directory is not a retired cache: matching is by exact name.
        let lookalike = root.appendingPathComponent("parakeet-tdt-0.6b-v3-ggml-keep", isDirectory: true)
        try fileManager.createDirectory(at: lookalike, withIntermediateDirectories: true)

        var failures: [String] = []
        RetiredModelCacheSweep.sweep(cacheRoot: root, logFailure: { failures.append($0) })

        #expect(failures.isEmpty)
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("parakeet-tdt-0.6b-v3-ggml").path))
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("parakeet-tdt-0.6b-v3-ggml-q8_0").path))
        #expect(fileManager.fileExists(atPath: granite.appendingPathComponent("manifest.json").path))
        #expect(fileManager.fileExists(atPath: lookalike.path))
    }

    @Test func sweepOfACacheWithoutRetiredDirectoriesIsANoOp() throws {
        let root = try temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        var failures: [String] = []
        RetiredModelCacheSweep.sweep(cacheRoot: missing, logFailure: { failures.append($0) })

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// A directory that cannot be removed is logged and left in place; the sweep never throws.
    @Test func aRemovalFailureIsLoggedAndDoesNotStopTheSweep() throws {
        let fileManager = FileManager.default
        let root = try temporaryCacheRoot()
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fileManager.removeItem(at: root)
        }
        let retired = root.appendingPathComponent("parakeet-tdt-0.6b-v3-ggml", isDirectory: true)
        try fileManager.createDirectory(at: retired, withIntermediateDirectories: true)
        // Entries of a read-only directory cannot be unlinked.
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        var failures: [String] = []
        RetiredModelCacheSweep.sweep(cacheRoot: root, logFailure: { failures.append($0) })

        #expect(failures.count == 1)
        #expect(failures.first?.contains("parakeet-tdt-0.6b-v3-ggml") == true)
        #expect(fileManager.fileExists(atPath: retired.path))
    }
}
