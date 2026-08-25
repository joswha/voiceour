import Foundation
import VoiceCore

/// Recent-session history: normalization, the delivered-dictation append that is
/// also the lifetime ledger's one fold site, outcome update, the serialized
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
/// write can never be resurrected by a checkpoint queued behind it. The ledger's
/// own file is written through the same FIFO, and folded here rather than a step
/// later, so the two durable records cannot disagree — not on disk, and not for
/// one main-actor turn either.
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

    /// Journals one delivered dictation: the transcript row, and the same
    /// dictation folded into the lifetime ledger, published together.
    ///
    /// One method rather than two calls because `recentSessions` publishes
    /// before its own snapshot is awaited. A ledger folded on the far side of
    /// that await sat a whole main-actor suspension behind the journal, and Home
    /// reads both: `owesFirstRunGuidance` retires on either record, so the
    /// first-run card left while every figure still read zero and the caption
    /// that names the gesture appeared under the hero — to a reader who had just
    /// used it. A termination arriving inside that window dropped the fold
    /// outright and left the two files permanently disagreeing. Both folds now
    /// land in one turn with no suspension between them, and the two snapshots
    /// drain through the one ordered tail in the order they were folded.
    ///
    /// Returns nil and folds nothing for a transcript that is only whitespace:
    /// there is no dictation to record. A secure delivery target never arrives
    /// here at all — it reaches neither record.
    @discardableResult
    func recordDeliveredDictation(
        text: String,
        rawTranscript: String? = nil,
        mutedDuringCapture: Bool,
        stages: SessionStageTimings? = nil,
        leastConfidentWord: LeastConfidentWord? = nil,
        deliveredTo app: DictationAppIdentity?
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
        foldDictationStats(for: session, deliveredTo: app)

        let journal = enqueueJournalSnapshot()
        let ledger = enqueueDictationStatsSnapshot()
        _ = await journal.value
        _ = await ledger.value
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
