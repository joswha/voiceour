import Foundation
import VoiceCore

/// Recent-session history: normalization, append, outcome update, the serialized
/// snapshot-write FIFO, and the destructive clear/delete paths.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// `recentSessions` state, which stays on the main actor with the rest of the UI
/// state. Members that were `private` are now `internal`: Swift scopes
/// `private` to one file, so an extension in another file cannot see them.
@MainActor
extension DictationCoordinator {
    @discardableResult
    public func clearRecentSessions() async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = []
        return await enqueueRecentSessionSnapshot(recentSessions).value
    }

    @discardableResult
    public func deleteRecentSession(id: RecentSession.ID) async -> Bool {
        guard !isPreparingForTermination else { return false }
        recentSessions = recentSessionStore.normalized(recentSessions.filter { $0.id != id })
        return await enqueueRecentSessionSnapshot(recentSessions).value
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
        _ = await enqueueRecentSessionSnapshot(recentSessions).value
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
        _ = await enqueueRecentSessionSnapshot(updatedSessions).value
    }

    @discardableResult
    func enqueueRecentSessionSnapshot(_ sessions: [RecentSession]) -> Task<Bool, Never> {
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
