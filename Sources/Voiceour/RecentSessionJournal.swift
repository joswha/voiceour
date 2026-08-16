import Foundation
import VoiceCore

/// Recent-session history: normalization, append, outcome update, the serialized
/// snapshot-write FIFO, and the destructive clear/delete paths.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// `recentSessions` state, which stays on the main actor with the rest of the UI
/// state. Members that were `private` are now `internal`: Swift scopes `private`
/// to one file, so an extension in another file cannot see them.
///
/// One durable file, `recent-sessions.json`: the capped transcript corpus the
/// user can re-read and delete. Every mutation below writes it through one FIFO,
/// so a later snapshot can never land before an earlier one and a destructive
/// write can never be resurrected by a checkpoint queued behind it.
@MainActor
extension DictationCoordinator {
    @discardableResult
    public func clearRecentSessions() async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = []
        return await enqueueJournalSnapshot().value
    }

    @discardableResult
    public func deleteRecentSession(id: RecentSession.ID) async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = recentSessionStore.normalized(recentSessions.filter { $0.id != id })
        return await enqueueJournalSnapshot().value
    }

    @discardableResult
    func recordRecentSession(
        text: String,
        rawTranscript: String? = nil,
        mutedDuringCapture: Bool,
        stages: SessionStageTimings? = nil,
        leastConfidentWord: LeastConfidentWord? = nil
    ) async -> RecentSession.ID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let session = RecentSession(
            id: runtime.makeUUID(),
            createdAt: runtime.now(),
            text: text,
            mutedDuringCapture: mutedDuringCapture,
            outcome: nil,
            rawTranscript: rawTranscript,
            stages: stages,
            leastConfidentWord: leastConfidentWord
        )
        recentSessions = recentSessionStore.normalized([session] + recentSessions)
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
        _ = await enqueueJournalSnapshot().value
    }

    @discardableResult
    func enqueueJournalSnapshot() -> Task<Bool, Never> {
        enqueueJournalSnapshot(sessions: recentSessions)
    }

    /// Serializes the durable write behind the same tail so a later snapshot can
    /// never land before an earlier one.
    @discardableResult
    func enqueueJournalSnapshot(sessions: [RecentSession]) -> Task<Bool, Never> {
        let snapshot = sessions
        let previous = recentSessionPersistenceTail
        let store = recentSessionStore
        let save = recentSessionSnapshotSave
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try save(store, snapshot)
                return true
            } catch {
                // Persistence is best-effort for the live dictation path. Each
                // failure is isolated so subsequent snapshots still execute.
                return false
            }
        }
        recentSessionPersistenceTail = next
        return next
    }
}
