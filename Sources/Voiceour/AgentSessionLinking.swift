import Foundation
import VoiceCore

/// Links History rows to the coding-agent sessions their text was sent into.
///
/// Opt-in through `Settings.agentSessionLinkingEnabled`. A pass reads the
/// agents' prompt logs and runs `AgentSessionLinker` off the main actor over
/// every row not resolved yet, then writes the results through the journal's
/// one FIFO. A row resolves once: linked, or unmatched after its send window
/// closes; a row still inside its window stays pending for a later pass. One
/// pass runs at a time, and a request made during it reruns once it lands.
@MainActor
extension DictationCoordinator {
    /// Turns linking on or off. On resolves every pending row; off discards
    /// any pass in flight and removes every link.
    public func setAgentSessionLinking(_ enabled: Bool) {
        guard settings.agentSessionLinkingEnabled != enabled else { return }
        settings.agentSessionLinkingEnabled = enabled
        saveSettings()
        if enabled {
            resolveAgentSessionLinks()
            return
        }
        generations.invalidate(.agentLinking)
        agentLinkRerunRequested = false
        guard recentSessions.contains(where: { $0.agentLink != nil }) else { return }
        recentSessions = recentSessions.map { session in
            var session = session
            session.agentLink = nil
            return session
        }
        _ = enqueueJournalSnapshot()
    }

    /// Starts a link pass over the rows not resolved yet, or asks the pass in
    /// flight to run again when it lands.
    public func resolveAgentSessionLinks() {
        guard settings.agentSessionLinkingEnabled, !isPreparingForTermination else { return }
        guard agentLinkTask == nil else {
            agentLinkRerunRequested = true
            return
        }
        let dictations = recentSessions.compactMap { session in
            session.agentLink == nil
                ? AgentSessionLinker.Dictation(id: session.id, createdAt: session.createdAt, text: session.text)
                : nil
        }
        guard let since = AgentSessionLinker.earliestSend(for: dictations) else { return }
        let token = generations.begin(.agentLinking)
        let now = runtime.now()
        let reader = agentPrompts
        agentLinkTask = Task { [weak self] in
            // Never cancelled: a pass the token no longer matches lands and is
            // discarded, which a cancelled log read could not report anyway.
            let results = await Task.detached(priority: .utility) {
                AgentSessionLinker.resolve(dictations, prompts: reader.prompts(sentSince: since), now: now)
            }.value
            self?.applyAgentSessionLinks(results, token: token)
        }
    }

    /// Writes a pass's links onto the rows that still exist and are still
    /// unresolved, unless linking was turned off or History cleared meanwhile.
    func applyAgentSessionLinks(_ results: [UUID: AgentSessionLink], token: AsyncGenerationGate.Token) {
        agentLinkTask = nil
        let rerun = agentLinkRerunRequested
        agentLinkRerunRequested = false
        if generations.isCurrent(token), settings.agentSessionLinkingEnabled {
            var changed = false
            let linked = recentSessions.map { session in
                guard session.agentLink == nil, let link = results[session.id] else { return session }
                var session = session
                session.agentLink = link
                changed = true
                return session
            }
            if changed {
                recentSessions = linked
                _ = enqueueJournalSnapshot()
            }
        }
        if rerun {
            resolveAgentSessionLinks()
        }
    }
}
