import Foundation
import VoiceCore

/// The durable memory folder as the coordinator keeps it: the switch that
/// folds new dictations in, the erase, the Journal's merged entries, and the
/// one mutation primitive every memory change goes through.
///
/// An extension on `DictationCoordinator` for the same reason the History and
/// ledger journals are: every member here publishes `memoryEntries`, which
/// stays on the main actor with the rest of the UI state.
///
/// Memory writes share the History journal's FIFO tail. A dictation folds into
/// History, the ledger and memory in one main-actor turn, and its three files
/// are written in that order behind every earlier write, so an erase can never
/// be resurrected by a write queued before it and termination drains memory
/// with everything else. Nothing here is awaited on the delivery path: a slow
/// or failed memory write costs the folder, never the paste.
@MainActor
extension DictationCoordinator {
    /// Publishes new memory state and enqueues the files its difference touches. Every memory mutation goes through here.
    ///
    /// The state publishes synchronously, so the Journal reads the change in
    /// the turn that made it. The plan is computed on the tail rather than
    /// here: diffing and rendering pages over an uncapped folder is work the
    /// main actor must not do, and the tail element runs after every earlier
    /// write, so the `before` it diffs against is what disk holds by then.
    /// `topics` nil keeps the current topics.
    ///
    /// A state identical to the current one enqueues nothing and returns the
    /// current tail, so a caller that awaits it still waits for every write
    /// already queued.
    @discardableResult
    func commitMemory(entries: [MemoryEntry], topics: [MemoryTopic]? = nil) -> Task<Bool, Never> {
        let before = memoryEntries
        let topicsBefore = memoryTopics
        let after = Self.oldestFirst(entries)
        let topicsAfter = topics ?? topicsBefore
        guard after != before || topicsAfter != topicsBefore else {
            return recentSessionPersistenceTail ?? Task { true }
        }

        memoryEntries = after
        memoryTopics = topicsAfter
        memoryRevision += 1

        let calendar = memoryCalendar
        let previous = recentSessionPersistenceTail
        let store = memoryStore
        let write = memoryWrite
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            let plan = MemoryPlanner.write(
                before: before,
                after: after,
                topicsBefore: topicsBefore,
                topicsAfter: topicsAfter,
                calendar: calendar
            )
            guard !plan.isEmpty else { return true }
            do {
                try write(store, plan)
                return true
            } catch {
                // A failed write does not prevent later writes from running;
                // the main-actor observer below reports the lost durability.
                return false
            }
        }
        recentSessionPersistenceTail = next
        Task { @MainActor [weak self] in
            guard await next.value == false, let self else { return }
            self.errorMessage = "Memory could not be saved."
        }
        return next
    }

    /// The calendar every memory page, file name and prompt is read in.
    ///
    /// Gregorian whatever the user's calendar setting, because the folder
    /// names its days and months `YYYY-MM-DD` and `YYYY-MM`, which only the
    /// Gregorian calendar fills correctly. The zone is the runtime calendar's,
    /// which is `TimeZone.current` in the app and a pinned zone under a test
    /// or a harness clock, so a page lands under the day the user lived it.
    var memoryCalendar: Calendar {
        Self.memoryCalendar(timeZone: runtime.calendar().timeZone)
    }

    /// The Gregorian calendar in `timeZone`; a lens that copies a prompt naming
    /// a page builds its calendar here so the prompt names the page's real path.
    nonisolated static func memoryCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Rebuilds every derived page once, at launch, when the folder's
    /// `pages-format` stamp, read through `pagesFormat`, names another format,
    /// calendar or zone than this build writes in. Called from `init` after
    /// memory loaded and its unreadable files were set aside, before anything
    /// else can queue a write, so the rebuild is the tail's first element and
    /// every diff after it starts from pages of the current format.
    ///
    /// Nothing waits for it: the plan is rendered and written on the tail.
    /// Only pages are written; `entries/` and `topics.json` stay as they are,
    /// because re-encoding them would drop what this build cannot decode. A
    /// load that set a file aside skips the sweep: the pages of the entries it
    /// could not read are all that is left of them. A failure reports like any
    /// memory write, and the stamp stays unwritten so the next launch retries.
    /// An empty state reads no stamp and writes nothing, so a rebuild never
    /// creates the folder.
    func enqueueMemoryPagesRebuild(pagesFormat: (MemoryStore) -> String?, sweep: Bool) {
        guard !memoryEntries.isEmpty || !memoryTopics.isEmpty else { return }
        let calendar = memoryCalendar
        guard pagesFormat(memoryStore) != MemoryPages.formatStamp(calendar: calendar) else { return }

        let entries = memoryEntries
        let topics = memoryTopics
        let previous = recentSessionPersistenceTail
        let store = memoryStore
        let write = memoryWrite
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            let plan = MemoryPlanner.rebuildPages(entries: entries, topics: topics, calendar: calendar, sweep: sweep)
            guard !plan.isEmpty else { return true }
            do {
                try write(store, plan)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        Task { @MainActor [weak self] in
            guard await next.value == false, let self else { return }
            self.errorMessage = "Memory could not be saved."
        }
    }

    /// Folds one journaled dictation into memory when the user keeps
    /// dictations there.
    ///
    /// Called by `recordDeliveredDictation` in the same main-actor turn that
    /// appended the History row, after the History and ledger snapshots were
    /// enqueued, so the three files land in that order. The app comes from the
    /// delivery target rather than the row: the row's outcome is not written
    /// until the paste returns, and memory must not wait for it.
    func foldMemory(for session: RecentSession, deliveredTo app: DictationAppIdentity?) {
        guard settings.memoryEnabled else { return }
        var entry = MemoryEntry(session)
        entry.appBundleId = app?.bundleId
        entry.appName = app?.name
        commitMemory(entries: memoryEntries + [entry])
        organizeNewMemoryEntry(entry)
    }

    /// Saves a note: what the user said, verbatim, as a memory entry that was
    /// delivered nowhere. Saved whatever `settings.memoryEnabled` says, because
    /// the user asked for this one to be kept. Returns the entry's id, or nil
    /// for whitespace-only text, which is no note at all.
    ///
    /// The write goes through `commitMemory` and is never awaited here.
    @discardableResult
    func recordNote(text: String, captureSeconds: Double) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = MemoryEntry(
            id: runtime.makeUUID(),
            createdAt: runtime.now(),
            kind: .note,
            text: text,
            captureSeconds: captureSeconds
        )
        commitMemory(entries: memoryEntries + [entry])
        organizeNewMemoryEntry(entry)
        return entry.id
    }

    /// Hands the capture `before`, taken right after the note's target
    /// snapshot, to a task that links note `noteID` to the agent session in
    /// that pane, or cancels it when binding no longer applies or the note is
    /// gone or already linked. Returns at once.
    ///
    /// The task lives in `agentBindingTasks` under the note's id, so it has a
    /// row binding's lifetime: quit and turning binding off cancel it, Clear
    /// Memory cancels it with every note, and a later dictation touches none.
    func startNoteSessionLink(
        noteID: UUID,
        target: TargetSnapshot,
        before: Task<Result<AgentFocusCapture, AgentLinkMiss>, Never>
    ) {
        guard agentSessionBindingApplies(to: target),
            memoryEntries.contains(where: { $0.id == noteID && $0.thread == nil })
        else {
            before.cancel()
            return
        }
        // Observed, never begun: a note's link must not invalidate a
        // delivery's binding or a refresh pass.
        let token = generations.currentToken(.agentLinking)
        let identity = runtime.makeUUID()
        let sessions = agentSessions
        let task = Task { [weak self] in
            let result = await Self.resolveAgentSession(target: target, before: before, sessions: sessions)
            self?.applyNoteSessionLink(result, noteID: noteID, identity: identity, token: token)
        }
        agentBindingTasks[noteID] = (identity: identity, task: task)
    }

    /// Lands one note link: drops its own task entry, then sets the note's
    /// thread, or its miss, unless the task was cancelled, binding was turned
    /// off or its token invalidated, the app is terminating, or the note is
    /// gone or already linked. A thread clears a miss. A note has no send
    /// check, so nothing refreshes afterwards.
    func applyNoteSessionLink(
        _ result: Result<ResolvedAgentSession, AgentLinkMiss>?,
        noteID: UUID,
        identity: UUID,
        token: AsyncGenerationGate.Token
    ) {
        if agentBindingTasks[noteID]?.identity == identity {
            agentBindingTasks.removeValue(forKey: noteID)
        }
        guard let result,
            !Task.isCancelled,
            generations.isCurrent(token),
            settings.agentSessionBindingEnabled,
            !isPreparingForTermination,
            let index = memoryEntries.firstIndex(where: { $0.id == noteID }),
            memoryEntries[index].thread == nil
        else { return }
        var entries = memoryEntries
        switch result {
        case .success(let resolved):
            entries[index].thread = JournalThreadRef(resolved)
        case .failure(let miss):
            entries[index].unlinked = miss
        }
        commitMemory(entries: entries)
    }

    /// Turns the memory switch on or off.
    ///
    /// On also keeps every History row the folder does not hold yet, matched
    /// by id, so the dictations the user can still see are not the ones memory
    /// is missing; each carries its row's binding and miss through
    /// `MemoryEntry(RecentSession)`. Off only stops new dictations from
    /// folding in: what the folder holds is the user's, and erasing it is
    /// Clear Memory's job alone.
    public func setMemoryEnabled(_ enabled: Bool) {
        guard settings.memoryEnabled != enabled, !isPreparingForTermination else { return }
        settings.memoryEnabled = enabled
        saveSettings()
        guard enabled else { return }
        let kept = Set(memoryEntries.map(\.id))
        let missing = recentSessions.filter { !kept.contains($0.id) }.map { MemoryEntry($0) }
        commitMemory(entries: memoryEntries + missing)
    }

    /// Erases the whole memory folder, `agents/` included, and the agent
    /// notes read from it.
    ///
    /// The one change that bypasses `commitMemory`: a plan can only rewrite
    /// the files this store owns, and the erase removes the folder whole. The
    /// empty state publishes at once; the removal runs behind every write
    /// already queued, so a write that was waiting cannot recreate a file the
    /// erase removed. Returns false while terminating or when the folder could
    /// not be removed.
    @discardableResult
    public func clearMemory() async -> Bool {
        guard !isPreparingForTermination else { return false }
        // A note's link would land on an entry this erase removes; a History
        // row's binding stays, because the row outlives memory.
        for entry in memoryEntries where entry.kind == .note {
            cancelAgentSessionBinding(rowID: entry.id)
        }
        // A label on its way back would land on an entry this erase removes,
        // and a Sort Entries run would keep labelling a folder that is gone.
        generations.invalidate(.organizing)
        cancelOrganizerWork()
        // A load in flight read a folder this erase removes; cancelling it
        // discards its landing.
        agentNotesTask?.cancel()
        agentNotesTask = nil
        agentNotesRerunRequested = false
        memoryEntries = []
        memoryTopics = []
        agentNotes = []
        memoryRevision += 1

        let previous = recentSessionPersistenceTail
        let store = memoryStore
        let clear = memoryClear
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try clear(store)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        let cleared = await next.value
        if !cleared {
            errorMessage = "Memory could not be erased."
        }
        return cleared
    }

    /// Writes the agent skill for Settings ▸ Memory ▸ Copy Install Command, so
    /// the links the copied command makes point at a file. Returns whether the
    /// skill is on disk: false while terminating, because a write enqueued after
    /// the termination drain would never land, or when the write failed.
    ///
    /// The press is an explicit action, so this is the one memory write that may
    /// create the folder with nothing else in it. It runs behind every write
    /// already queued: after a queued Clear Memory it writes into the emptied
    /// folder instead of being erased by it. A failure publishes nothing; the
    /// row that asked reports it in place.
    public func prepareAgentSkill() async -> Bool {
        guard !isPreparingForTermination else { return false }
        let previous = recentSessionPersistenceTail
        let store = memoryStore
        let write = memorySkillWrite
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try write(store)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        return await next.value
    }

    /// Starts a load of the notes agents saved under `agents/`, or asks the
    /// load in flight to run again when it lands. Nothing here writes under
    /// `agents/`: the folder is the agents' to write and Voiceour's to read.
    ///
    /// The read runs behind every write already queued, Clear Memory's
    /// included, so a load asked for after an erase never reads the folder
    /// the erase is about to remove.
    public func refreshAgentNotes() {
        guard !isPreparingForTermination else { return }
        guard agentNotesTask == nil else {
            agentNotesRerunRequested = true
            return
        }
        let previous = recentSessionPersistenceTail
        let store = memoryStore
        let load = memoryAgentNotesLoad
        agentNotesTask = Task { [weak self] in
            let notes = await Task.detached(priority: .utility) {
                _ = await previous?.value
                return load(store)
            }.value
            self?.applyAgentNotesLoad(notes)
        }
    }

    /// Lands a load. A cancelled load touches nothing: its canceller already
    /// released the slot. Otherwise publishes the notes unless termination has
    /// begun, then reruns if asked.
    func applyAgentNotesLoad(_ notes: [AgentNote]) {
        guard !Task.isCancelled else { return }
        agentNotesTask = nil
        let rerun = agentNotesRerunRequested
        agentNotesRerunRequested = false
        guard !isPreparingForTermination else { return }
        agentNotes = notes
        if rerun {
            refreshAgentNotes()
        }
    }

    /// Whether the memory folder exists, which is when Clear Memory has
    /// something to erase.
    public var memoryExistsOnDisk: Bool {
        FileManager.default.fileExists(atPath: memoryStore.root.path)
    }

    /// Everything the Journal lenses read: every memory entry, plus each
    /// History row memory does not hold, whatever the switch says. Oldest
    /// first; entries made in the same instant keep memory-then-History order.
    ///
    /// Memory wins for an id both hold, because it carries what History cannot:
    /// the entry's topic and label. A row the switch never folded still shows,
    /// so turning memory off never empties the Journal.
    public var journalEntries: [JournalEntry] {
        let known = Set(memoryTopics.map(\.id))
        var seen = Set<UUID>()
        var entries: [JournalEntry] = []
        entries.reserveCapacity(memoryEntries.count + recentSessions.count)
        for entry in memoryEntries {
            guard seen.insert(entry.id).inserted else { continue }
            entries.append(JournalEntry(entry, knownTopicIDs: known))
        }
        for session in recentSessions {
            guard seen.insert(session.id).inserted else { continue }
            entries.append(JournalEntry(session))
        }
        return entries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Copies the History bindings in `bindings`, keyed by row id, onto the
    /// memory entries with the same ids, in one commit; setting the thread
    /// clears any miss the entry held. A row memory does not hold needs
    /// nothing.
    func mirrorAgentSessionBindings(_ bindings: [RecentSession.ID: AgentSessionBinding]) {
        guard !bindings.isEmpty, memoryEntries.contains(where: { bindings[$0.id] != nil }) else { return }
        commitMemory(
            entries: memoryEntries.map { entry in
                guard let binding = bindings[entry.id] else { return entry }
                var entry = entry
                entry.thread = JournalThreadRef(binding)
                return entry
            })
    }

    /// Copies a History row's miss onto the memory entry with id `entryID`.
    /// An entry memory does not hold, or one already linked to a thread,
    /// needs nothing: a miss never overwrites a link.
    func mirrorAgentLinkMiss(_ miss: AgentLinkMiss, entryID: UUID) {
        guard let index = memoryEntries.firstIndex(where: { $0.id == entryID }),
            memoryEntries[index].thread == nil
        else { return }
        var entries = memoryEntries
        entries[index].unlinked = miss
        commitMemory(entries: entries)
    }

    /// Removes the thread and the miss from every memory entry, notes
    /// included, in one commit: binding was turned off, and memory must not
    /// keep a link, or a reason that names what ran in the pane, that History
    /// was made to forget.
    func stripMemoryAgentLinks() {
        guard memoryEntries.contains(where: { $0.thread != nil || $0.unlinked != nil }) else { return }
        commitMemory(
            entries: memoryEntries.map { entry in
                var entry = entry
                entry.thread = nil
                entry.unlinked = nil
                return entry
            })
    }

    /// Stable oldest-first order. Returns `entries` untouched when it is
    /// already in order, which every append of a new entry leaves it.
    private static func oldestFirst(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        let ordered = zip(entries, entries.dropFirst()).allSatisfy { $0.createdAt <= $1.createdAt }
        guard !ordered else { return entries }
        return entries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
