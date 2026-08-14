import Foundation
import VoiceCore

/// Recent-session history: normalization, append, outcome update, statistics
/// folding, the serialized snapshot-write FIFO, and the destructive
/// clear/delete paths.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// `recentSessions`, `statsLedger` and `insights` state, which stays on the main
/// actor with the rest of the UI state. Members that were `private` are now
/// `internal`: Swift scopes `private` to one file, so an extension in another
/// file cannot see them.
///
/// Two durable files move together here. `recent-sessions.json` is the capped
/// transcript corpus the user can re-read and delete; `dictation-stats.json` is
/// the uncapped tally. Every mutation below updates both and writes both
/// through one FIFO, so the pair can never disagree about what happened.
@MainActor
extension DictationCoordinator {
    @discardableResult
    public func clearRecentSessions() async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = []
        // Clearing history clears the tally with it. A lifetime word count, a
        // per-app breakdown and a quoted personal best are still a record of
        // what the user just asked to erase.
        statsLedger.reset()
        refreshInsights()
        return await enqueueJournalSnapshot().value
    }

    @discardableResult
    public func deleteRecentSession(id: RecentSession.ID) async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = recentSessionStore.normalized(recentSessions.filter { $0.id != id })
        // Counts stay — a dictation that happened still happened — but anything
        // quoting this transcript goes with it.
        statsLedger.forget(sessionID: id)
        refreshInsights()
        return await enqueueJournalSnapshot().value
    }

    @discardableResult
    func recordRecentSession(
        text: String,
        rawTranscript: String? = nil,
        refinement: RefinementTrace? = nil,
        mutedDuringCapture: Bool,
        stages: SessionStageTimings? = nil
    ) async -> RecentSession.ID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let session = RecentSession(
            id: runtime.makeUUID(),
            createdAt: runtime.now(),
            text: text,
            mutedDuringCapture: mutedDuringCapture,
            outcome: nil,
            rawTranscript: rawTranscript,
            refinement: refinement,
            stages: stages
        )
        recentSessions = recentSessionStore.normalized([session] + recentSessions)
        foldStatistics()
        _ = await enqueueJournalSnapshot().value
        return session.id
    }

    func updateRecentSessionOutcome(
        id: RecentSession.ID?,
        outcome: RecentSessionOutcomeMetadata,
        insertMs: Int? = nil,
        stopReleaseToInsertionOutcomeMs: Int? = nil
    ) async {
        guard let id else { return }

        let updatedSessions = recentSessionStore.normalized(
            recentSessions.map { session in
                guard session.id == id else { return session }
                var session = session
                session.outcome = outcome
                if session.stages == nil,
                    insertMs != nil || stopReleaseToInsertionOutcomeMs != nil
                {
                    session.stages = SessionStageTimings()
                }
                if let insertMs {
                    session.stages?.insertMs = insertMs
                }
                if let stopReleaseToInsertionOutcomeMs {
                    session.stages?.stopReleaseToInsertionOutcomeMs = stopReleaseToInsertionOutcomeMs
                }
                return session
            })
        recentSessions = updatedSessions
        // The destination app and the post-speech wait only exist on this
        // second write. Folding here is what keeps TOP APPS and the time
        // economy current instead of one dictation behind.
        foldStatistics()
        _ = await enqueueJournalSnapshot().value
    }

    /// Folds whatever the ledger has not counted yet, then republishes the
    /// digest. Idempotent by session id, so calling it after both journal
    /// writes of one dictation counts that dictation once.
    func foldStatistics() {
        statsLedger.ingest(recentSessions, calendar: runtime.calendar())
        refreshInsights()
    }

    /// Recomputes the Home digest against the current clock.
    ///
    /// Also called when Home appears: the streak and the fourteen-day window
    /// are relative to "now", so a console left open across midnight would
    /// otherwise keep yesterday's frame until the next dictation.
    public func refreshInsights() {
        insights = DictationInsights(
            ledger: statsLedger,
            keptSessions: recentSessions,
            calendar: runtime.calendar(),
            now: runtime.now()
        )
    }

    @discardableResult
    func enqueueJournalSnapshot() -> Task<Bool, Never> {
        enqueueJournalSnapshot(sessions: recentSessions, ledger: statsLedger)
    }

    /// Serializes both durable writes behind the same tail so a later snapshot
    /// can never land before an earlier one, and a destructive write can never
    /// be resurrected by a checkpoint queued behind it.
    ///
    /// The acknowledgement is the conjunction: "durable" has to mean both files
    /// took the change, or a `clearRecentSessions()` that erased the
    /// transcripts and failed to erase the tally would report success.
    @discardableResult
    func enqueueJournalSnapshot(
        sessions: [RecentSession],
        ledger: DictationStatsLedger
    ) -> Task<Bool, Never> {
        let snapshot = sessions
        let ledgerSnapshot = ledger
        let previous = recentSessionPersistenceTail
        let store = recentSessionStore
        let save = recentSessionSnapshotSave
        let statsStore = statsStore
        let saveStats = statsSnapshotSave
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            var durable = true
            do {
                try save(store, snapshot)
            } catch {
                // Persistence is best-effort for the live dictation path. Each
                // failure is isolated so subsequent snapshots still execute.
                durable = false
            }
            do {
                try saveStats(statsStore, ledgerSnapshot)
            } catch {
                // The ledger is written whole every time, so the next snapshot
                // carries everything this one dropped.
                durable = false
            }
            return durable
        }
        recentSessionPersistenceTail = next
        return next
    }

    /// Ledger-only write, used at launch when the seed fold discovers sessions
    /// the tally had never counted.
    @discardableResult
    func enqueueStatsSnapshot(_ ledger: DictationStatsLedger) -> Task<Bool, Never> {
        let snapshot = ledger
        let previous = recentSessionPersistenceTail
        let store = statsStore
        let save = statsSnapshotSave
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try save(store, snapshot)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        return next
    }
}
