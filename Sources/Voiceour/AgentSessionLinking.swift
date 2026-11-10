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
///
/// Link Earlier Dictations, on the person's press, links rows the pane could
/// not: the one local session whose own prompt log holds a row's whole text
/// inside its window, read by `AgentPromptEvidenceReading`. Several sessions
/// holding it link nothing. A row the person unlinked keeps `.removedByYou`
/// and is never linked again by either path.
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
        linkEarlierTask?.task.cancel()
        linkEarlierTask = nil
        // The run counted rows that are gone or about to lose their links.
        linkEarlierRun = nil
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

    /// Links earlier History rows by their words: each row with no binding,
    /// not unlinked by the person, and at least `PromptEvidence.minimumWords`
    /// words is looked for in the local agents' own prompt logs off the main
    /// actor, and linked only when exactly one session held its whole text.
    /// One run at a time; refused while binding is off or the app is quitting.
    /// Turning binding off, Clear History and quit cancel it and drop what it
    /// found.
    public func linkEarlierDictations() {
        guard linkEarlierTask == nil,
            settings.agentSessionBindingEnabled,
            !isPreparingForTermination
        else { return }
        let queries = recentSessions.compactMap { session -> PromptEvidenceQuery? in
            guard session.agentSession == nil,
                session.unlinked != .removedByYou,
                PromptEvidence.words(session.text) >= PromptEvidence.minimumWords
            else { return nil }
            return PromptEvidenceQuery(id: session.id, text: session.text, at: session.createdAt)
        }
        guard !queries.isEmpty else {
            linkEarlierRun = LinkEarlierRun(isRunning: false)
            return
        }
        // Observed, never begun: a run must not invalidate a delivery's
        // binding or a refresh pass.
        let token = generations.currentToken(.agentLinking)
        let identity = runtime.makeUUID()
        let reader = promptEvidence
        linkEarlierRun = LinkEarlierRun(isRunning: true)
        let task = Task { [weak self] in
            // Detached so the reading leaves the main actor; cancelling this
            // task cancels it, and the reader stops between files.
            let reading = Task.detached(priority: .utility) {
                Self.linkEarlierFindings(queries, reader: reader)
            }
            let findings = await withTaskCancellationHandler {
                await reading.value
            } onCancel: {
                reading.cancel()
            }
            self?.applyLinkEarlierDictations(findings, queries: queries, identity: identity, token: token)
        }
        linkEarlierTask = (identity: identity, task: task)
    }

    /// Reads the prompt logs once for every query, then which matched
    /// sessions' files exist now. Runs off the main actor: both touch files.
    nonisolated static func linkEarlierFindings(
        _ queries: [PromptEvidenceQuery],
        reader: AgentPromptEvidenceReading
    ) -> LinkEarlierFindings {
        let run = reader.evidence(for: queries)
        let existing = Set(
            run.matches.values.compactMap(\.sessionFile).filter { FileManager.default.fileExists(atPath: $0) }
        )
        return LinkEarlierFindings(run: run, existingSessionFiles: existing)
    }

    /// Lands a Link Earlier Dictations run. A cancelled run touches nothing:
    /// its canceller already released the slot, and the reader's empty answer
    /// after cancellation means nothing. Otherwise, under the gates a binding
    /// uses, links each row exactly one session held whose row still exists
    /// unbound, not unlinked by the person and with the text that was read,
    /// in one journal snapshot and one memory commit, then publishes the
    /// counts.
    func applyLinkEarlierDictations(
        _ findings: LinkEarlierFindings,
        queries: [PromptEvidenceQuery],
        identity: UUID,
        token: AsyncGenerationGate.Token
    ) {
        guard linkEarlierTask?.identity == identity else { return }
        linkEarlierTask = nil
        guard !Task.isCancelled,
            generations.isCurrent(token),
            settings.agentSessionBindingEnabled,
            !isPreparingForTermination
        else {
            linkEarlierRun = nil
            return
        }
        let run = findings.run
        var sessions = recentSessions
        var linked: [RecentSession.ID: AgentSessionBinding] = [:]
        var ambiguous = 0
        var found = 0
        for query in queries {
            if run.ambiguous.contains(query.id) {
                ambiguous += 1
                continue
            }
            guard let match = run.matches[query.id] else { continue }
            found += 1
            guard let index = sessions.firstIndex(where: { $0.id == query.id }),
                sessions[index].agentSession == nil,
                sessions[index].unlinked != .removedByYou,
                sessions[index].text == query.text
            else { continue }
            let binding = AgentSessionBinding(
                agent: match.agent,
                sessionId: match.sessionId,
                sessionFile: match.sessionFile,
                workingDirectory: match.workingDirectory,
                sessionTitle: match.title,
                boundAt: sessions[index].createdAt,
                resumable: match.sessionFile.map(findings.existingSessionFiles.contains) ?? false,
                send: .sent(sentAt: match.sentAt, text: nil),
                evidence: .words
            )
            sessions[index].agentSession = binding
            linked[query.id] = binding
        }
        if !linked.isEmpty {
            recentSessions = sessions
            _ = enqueueJournalSnapshot()
            mirrorAgentSessionBindings(linked)
        }
        linkEarlierRun = LinkEarlierRun(
            isRunning: false,
            linked: linked.count,
            notFound: queries.count - found - ambiguous,
            ambiguous: ambiguous
        )
    }

    /// Removes row `rowID`'s thread for good. The row keeps `.removedByYou`,
    /// so neither a refresh pass nor Link Earlier Dictations links it again;
    /// the memory entry with the same id loses its thread and gets the same
    /// reason. A row with no binding needs nothing.
    public func unlinkThread(rowID: RecentSession.ID) {
        guard !isPreparingForTermination,
            let index = recentSessions.firstIndex(where: { $0.id == rowID }),
            recentSessions[index].agentSession != nil
        else { return }
        recentSessions[index].agentSession = nil
        recentSessions[index].unlinked = .removedByYou
        _ = enqueueJournalSnapshot()
        mirrorAgentLinkRemoval(entryID: rowID)
    }

    /// Clears the thread of the memory entry with id `entryID` and records
    /// that the person removed it. An entry memory does not hold needs
    /// nothing.
    func mirrorAgentLinkRemoval(entryID: UUID) {
        guard let index = memoryEntries.firstIndex(where: { $0.id == entryID }) else { return }
        var entries = memoryEntries
        entries[index].thread = nil
        entries[index].unlinked = .removedByYou
        commitMemory(entries: entries)
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

/// The result of one Link Earlier Dictations run, as Settings shows it.
public struct LinkEarlierRun: Equatable, Sendable {
    /// True while the agents' prompt logs are being read.
    public var isRunning: Bool
    /// Rows the run linked.
    public var linked: Int
    /// Rows no local session's prompts held.
    public var notFound: Int
    /// Rows several sessions' prompts held, left unlinked.
    public var ambiguous: Int

    public init(isRunning: Bool, linked: Int = 0, notFound: Int = 0, ambiguous: Int = 0) {
        self.isRunning = isRunning
        self.linked = linked
        self.notFound = notFound
        self.ambiguous = ambiguous
    }

    /// Fixed sentences built only from the counts, so showing them can leak
    /// no text, title or id. A count of zero adds no sentence, except that the
    /// first always says how many were linked; a run with nothing to look for
    /// says why instead.
    public var summary: String {
        guard linked + notFound + ambiguous > 0 else {
            return "Every earlier dictation is already linked, was unlinked by you, "
                + "or has fewer than \(PromptEvidence.minimumWords) words."
        }
        var sentences = [linked == 1 ? "Linked 1 earlier dictation." : "Linked \(linked) earlier dictations."]
        if notFound > 0 {
            sentences.append("\(notFound) \(notFound == 1 ? "was" : "were") not found in any local agent's prompts.")
        }
        if ambiguous > 0 {
            sentences.append(
                "\(ambiguous) matched several sessions and \(ambiguous == 1 ? "was" : "were") left unlinked.")
        }
        return sentences.joined(separator: " ")
    }
}

/// What a Link Earlier Dictations reading found, with the matched session
/// files that exist, checked off the main actor.
struct LinkEarlierFindings: Sendable {
    let run: PromptEvidenceRun
    let existingSessionFiles: Set<String>
}
