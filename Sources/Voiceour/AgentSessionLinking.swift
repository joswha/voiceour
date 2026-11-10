import Foundation
import VoiceCore

/// Binds History rows to the coding-agent session that received their paste.
///
/// Opt-in through `Settings.agentSessionBindingEnabled`. Only a dictation
/// pasted into Tern binds: the pipeline captures Tern's focused pane before
/// the paste, and once the row's outcome reads `.pasteAttempted` a binding
/// task asks `AgentSessionResolving` which session the same pane runs after
/// it. The answer is exact or a miss, and a miss leaves the row unbound for
/// good with its one closed reason, so History can say why instead of
/// guessing. A row never holds both. Nothing here delays delivery: each
/// binding runs in its own task, owned per row so a later dictation never
/// cancels an earlier one's binding.
///
/// A refresh pass then fills what the binding could not know yet — the
/// session's title, whether it can be resumed, and whether the dictation was
/// sent — from `AgentSessionReading` off the main actor, one pass at a time.
/// Every write goes through the journal's one FIFO and is discarded once
/// binding is turned off, History is cleared, or the app is terminating.
@MainActor
extension DictationCoordinator {
    /// The one host whose panes a dictation binds to.
    static let agentSessionHostBundleId = "so.stencil.tern"

    /// Whether a delivery to `target` may capture the host's focused pane:
    /// binding is on and the paste goes to Tern's normal-text input.
    func agentSessionBindingApplies(to target: TargetSnapshot) -> Bool {
        settings.agentSessionBindingEnabled
            && !isPreparingForTermination
            && target.safety == .normalText
            && target.bundleId == Self.agentSessionHostBundleId
    }

    /// Turns binding on or off. Off discards every binding and refresh in
    /// flight and deletes every binding and every recorded miss, in memory
    /// and on disk, and every memory entry's thread and miss with them; a
    /// miss names what ran in the pane as surely as a binding does. Nothing
    /// is rebuilt when it is turned back on.
    public func setAgentSessionBinding(_ enabled: Bool) {
        guard settings.agentSessionBindingEnabled != enabled else { return }
        settings.agentSessionBindingEnabled = enabled
        saveSettings()
        guard !enabled else { return }
        generations.invalidate(.agentLinking)
        cancelAgentSessionWork()
        if recentSessions.contains(where: { $0.agentSession != nil || $0.unlinked != nil }) {
            recentSessions = recentSessions.map { session in
                var session = session
                session.agentSession = nil
                session.unlinked = nil
                return session
            }
            _ = enqueueJournalSnapshot()
        }
        stripMemoryAgentLinks()
    }

    /// Cancels every binding task and the refresh pass. Their landings are
    /// discarded by the caller's own gate: an invalidated `.agentLinking`
    /// token, or termination.
    func cancelAgentSessionWork() {
        for entry in agentBindingTasks.values {
            entry.task.cancel()
        }
        agentBindingTasks.removeAll()
        agentRefreshTask?.cancel()
        agentRefreshTask = nil
        agentRefreshRerunRequested = false
    }

    /// Cancels the binding task of a row that no longer exists.
    func cancelAgentSessionBinding(rowID: RecentSession.ID) {
        agentBindingTasks.removeValue(forKey: rowID)?.task.cancel()
    }

    /// Hands the pre-paste capture `before` to a binding task for row
    /// `rowID`, or cancels it when any gate fails: binding off, no row, a
    /// paste that was not attempted, or a target other than Tern's
    /// normal-text input. Returns at once. A delivery that fails a gate
    /// records no miss: it was never eligible, and absent means exactly that.
    func startAgentSessionBinding(
        rowID: RecentSession.ID?,
        target: TargetSnapshot,
        outcome: InsertionOutcome,
        boundAt: Date,
        before: Task<Result<AgentFocusCapture, AgentLinkMiss>, Never>
    ) {
        guard agentSessionBindingApplies(to: target),
            outcome == .pasteAttempted,
            let rowID,
            recentSessions.contains(where: { $0.id == rowID && $0.agentSession == nil })
        else {
            before.cancel()
            return
        }
        // Observed, never begun: a binding must not invalidate another
        // delivery's binding or a refresh pass.
        let token = generations.currentToken(.agentLinking)
        let identity = runtime.makeUUID()
        let sessions = agentSessions
        let task = Task { [weak self] in
            let result = await Self.resolveAgentSession(target: target, before: before, sessions: sessions)
            self?.applyAgentSessionBinding(result, rowID: rowID, identity: identity, token: token, boundAt: boundAt)
        }
        agentBindingTasks[rowID] = (identity: identity, task: task)
    }

    /// Awaits the pre-paste capture `before`, then asks which session the
    /// same pane runs now. A capture miss is the link's miss: the resolve
    /// cannot be exact without the pane it compares against. Nil when the
    /// calling task was cancelled before resolving, because a cancelled link
    /// writes nothing, not even a reason. Shared by row bindings and note
    /// links.
    static func resolveAgentSession(
        target: TargetSnapshot,
        before: Task<Result<AgentFocusCapture, AgentLinkMiss>, Never>,
        sessions: AgentSessionResolving
    ) async -> Result<ResolvedAgentSession, AgentLinkMiss>? {
        let capture = await withTaskCancellationHandler {
            await before.value
        } onCancel: {
            before.cancel()
        }
        guard !Task.isCancelled else { return nil }
        switch capture {
        case .success(let pane):
            return await sessions.resolve(target: target, before: pane)
        case .failure(let miss):
            return .failure(miss)
        }
    }

    /// Lands one binding task: drops its own entry, then writes the binding
    /// or the miss onto its row unless the task was cancelled, binding was
    /// turned off, History cleared, the app is terminating, or the row is
    /// gone or already bound. A binding clears a miss; a miss is never
    /// written over a binding.
    func applyAgentSessionBinding(
        _ result: Result<ResolvedAgentSession, AgentLinkMiss>?,
        rowID: RecentSession.ID,
        identity: UUID,
        token: AsyncGenerationGate.Token,
        boundAt: Date
    ) {
        if agentBindingTasks[rowID]?.identity == identity {
            agentBindingTasks.removeValue(forKey: rowID)
        }
        guard let result,
            !Task.isCancelled,
            generations.isCurrent(token),
            settings.agentSessionBindingEnabled,
            !isPreparingForTermination,
            let index = recentSessions.firstIndex(where: { $0.id == rowID }),
            recentSessions[index].agentSession == nil
        else { return }
        switch result {
        case .success(let resolved):
            let binding = AgentSessionBinding(resolved, boundAt: boundAt)
            recentSessions[index].agentSession = binding
            _ = enqueueJournalSnapshot()
            mirrorAgentSessionBindings([rowID: binding])
            refreshAgentSessions()
        case .failure(let miss):
            recentSessions[index].unlinked = miss
            _ = enqueueJournalSnapshot()
            mirrorAgentLinkMiss(miss, entryID: rowID)
        }
    }

    /// Starts a refresh pass over the bound rows still waiting on something —
    /// a send decision, or a title or resumability inside the send window —
    /// or asks the pass in flight to run again when it lands.
    public func refreshAgentSessions() {
        guard settings.agentSessionBindingEnabled, !isPreparingForTermination else { return }
        guard agentRefreshTask == nil else {
            agentRefreshRerunRequested = true
            return
        }
        let now = runtime.now()
        let candidates = recentSessions.compactMap { session -> AgentSessionRefreshCandidate? in
            guard let binding = session.agentSession else { return nil }
            let windowOpen = now < binding.boundAt.addingTimeInterval(AgentPromptSendMatcher.sendWindow)
            let waiting = binding.send == nil || ((binding.sessionTitle == nil || !binding.resumable) && windowOpen)
            guard waiting else { return nil }
            return AgentSessionRefreshCandidate(id: session.id, text: session.text, binding: binding)
        }
        guard !candidates.isEmpty else { return }
        let token = generations.currentToken(.agentLinking)
        let reader = agentSessionReader
        let runtime = runtime
        agentRefreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                Self.refreshedBindings(candidates, reader: reader, runtime: runtime)
            }.value
            self?.applyAgentSessionRefresh(refreshed, token: token)
        }
    }

    /// Lands a refresh pass. A cancelled pass touches nothing: its canceller
    /// already released the slot. Otherwise writes each changed binding onto
    /// its row if the row still holds the binding the pass read, under the
    /// same gates as a binding, then reruns if asked.
    func applyAgentSessionRefresh(_ refreshed: [AgentSessionRefreshResult], token: AsyncGenerationGate.Token) {
        guard !Task.isCancelled else { return }
        agentRefreshTask = nil
        let rerun = agentRefreshRerunRequested
        agentRefreshRerunRequested = false
        if !refreshed.isEmpty,
            generations.isCurrent(token),
            settings.agentSessionBindingEnabled,
            !isPreparingForTermination
        {
            var sessions = recentSessions
            var changed: [RecentSession.ID: AgentSessionBinding] = [:]
            for result in refreshed {
                guard let index = sessions.firstIndex(where: { $0.id == result.id }),
                    sessions[index].agentSession == result.original
                else { continue }
                sessions[index].agentSession = result.updated
                changed[result.id] = result.updated
            }
            if !changed.isEmpty {
                recentSessions = sessions
                _ = enqueueJournalSnapshot()
                mirrorAgentSessionBindings(changed)
            }
        }
        if rerun {
            refreshAgentSessions()
        }
    }

    /// Reads each candidate's session and returns only the bindings that
    /// changed. Runs off the main actor: the reader opens files.
    nonisolated static func refreshedBindings(
        _ candidates: [AgentSessionRefreshCandidate],
        reader: AgentSessionReading,
        runtime: DictationRuntime
    ) -> [AgentSessionRefreshResult] {
        candidates.compactMap { candidate in
            let snapshot = reader.read(candidate.binding)
            var updated = candidate.binding
            if let snapshot {
                if let title = snapshot.title,
                    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    updated.sessionTitle = title
                }
                updated.resumable = snapshot.sessionFileExists
            }
            if updated.send == nil, let snapshot {
                // An unreadable session says nothing about the send: the row
                // stays pending and a later refresh reads it again.
                updated.send = AgentPromptSendMatcher.resolve(
                    dictation: candidate.text,
                    boundAt: candidate.binding.boundAt,
                    prompts: snapshot.prompts,
                    now: runtime.now()
                )
            }
            guard updated != candidate.binding else { return nil }
            return AgentSessionRefreshResult(id: candidate.id, original: candidate.binding, updated: updated)
        }
    }
}

/// One bound row a refresh pass reads.
struct AgentSessionRefreshCandidate: Sendable {
    let id: RecentSession.ID
    let text: String
    let binding: AgentSessionBinding
}

/// A binding a refresh pass changed, with the binding it read so the landing
/// can skip a row that changed meanwhile.
struct AgentSessionRefreshResult: Sendable {
    let id: RecentSession.ID
    let original: AgentSessionBinding
    let updated: AgentSessionBinding
}
