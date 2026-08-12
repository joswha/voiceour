import Foundation

/// Durable home of `DictationStatsLedger`, a sibling of the transcript store.
public struct DictationStatsStore: Sendable {
    public var url: URL

    public init(url: URL = DictationStatsStore.defaultURL) {
        self.url = url
    }

    /// The stats file always sits beside the transcripts it counts, so a test
    /// or harness fixture that redirects one never leaves the other pointed at
    /// the user's real Application Support directory.
    public init(besideRecentSessionsAt sessionsURL: URL) {
        self.init(url: sessionsURL.deletingLastPathComponent().appendingPathComponent(DictationStatsStore.fileName))
    }

    /// A missing or future-versioned file reads as an empty ledger. The caller
    /// immediately re-ingests the retained corpus, so the worst case is a tally
    /// that restarts from the transcripts still on disk rather than a launch
    /// that fails on a stats file.
    public func load() throws -> DictationStatsLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DictationStatsLedger()
        }
        let data = try Data(contentsOf: url)
        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: data)
        guard ledger.version == DictationStatsLedger.currentVersion else {
            return DictationStatsLedger()
        }
        return ledger
    }

    /// An empty ledger removes the file rather than writing a husk of zeroes,
    /// mirroring `RecentSessionStore.save`: after "clear history" neither
    /// durable file should still be on disk.
    public func save(_ ledger: DictationStatsLedger) throws {
        guard !ledger.isEmpty else {
            try clear()
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeVoiceOourPrivateState(encoder.encode(ledger), to: url)
    }

    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                throw error
            }
        }
    }

    public static let fileName = "dictation-stats.json"

    public static var defaultURL: URL {
        URL.voiceOourSupportDirectory.appendingPathComponent(fileName)
    }
}
