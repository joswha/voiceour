import Foundation

/// The lifetime dictation ledger's one durable file.
///
/// Deliberately **not** `dictation-stats.json`. That name belongs to a deleted
/// subsystem — a per-day, per-app record with transcript quotes in it — which
/// `DictationCoordinator` still sweeps off disk at every launch. Reusing the
/// name would make this store load an incompatible document (quarantining it
/// under a `.corrupt-` suffix and reporting a failure the reader did nothing to
/// cause, while keeping the old per-app record on disk forever) and would cost
/// that sweep its whole purpose. A new tally gets a new name.
public struct DictationStatsStore: Sendable {
    public var url: URL

    public init(url: URL = DictationStatsStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL.voiceourSupportDirectory.appendingPathComponent("dictation-activity.json")
    }

    /// An absent file is an empty ledger, not a failure: it is exactly the state
    /// of a Mac that has not dictated yet.
    public func load() throws -> DictationStatsLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DictationStatsLedger()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DictationStatsLedger.self, from: data)
    }

    /// An empty ledger removes the file rather than writing a document full of
    /// zeroes, so clearing the stats leaves nothing behind to clear again.
    public func save(_ ledger: DictationStatsLedger) throws {
        guard ledger != DictationStatsLedger() else {
            try clear()
            return
        }

        try writeVoiceourPrivateJSON(ledger, to: url)
    }

    public func clear() throws {
        try removeVoiceourPrivateState(at: url)
    }
}
