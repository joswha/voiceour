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

        let calendar = runtime.calendar()
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
    }

    /// Turns the memory switch on or off.
    ///
    /// On also keeps every History row the folder does not hold yet, matched
    /// by id, so the dictations the user can still see are not the ones memory
    /// is missing. Off only stops new dictations from folding in: what the
    /// folder holds is the user's, and erasing it is Clear Memory's job alone.
    public func setMemoryEnabled(_ enabled: Bool) {
        guard settings.memoryEnabled != enabled, !isPreparingForTermination else { return }
        settings.memoryEnabled = enabled
        saveSettings()
        guard enabled else { return }
        let kept = Set(memoryEntries.map(\.id))
        let missing = recentSessions.filter { !kept.contains($0.id) }.map { MemoryEntry($0) }
        commitMemory(entries: memoryEntries + missing)
    }

    /// Erases the whole memory folder, `agents/` included.
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
        memoryEntries = []
        memoryTopics = []
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
    /// memory entries with the same ids, in one commit. A row memory does not
    /// hold needs nothing.
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

    /// Removes the thread from every memory entry, notes included, in one
    /// commit: binding was turned off, and memory must not keep a link History
    /// was made to forget.
    func stripMemoryThreads() {
        guard memoryEntries.contains(where: { $0.thread != nil }) else { return }
        commitMemory(
            entries: memoryEntries.map { entry in
                var entry = entry
                entry.thread = nil
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
