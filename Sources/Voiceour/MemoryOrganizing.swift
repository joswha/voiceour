import Foundation
import VoiceCore

/// The progress of one Sort Entries run, as Settings shows it.
public struct OrganizerRun: Equatable, Sendable {
    /// Entries answered so far, labelled or not.
    public var done: Int
    /// Entries the run set out to label.
    public var total: Int
    /// Answered entries the sorting model could not label.
    public var failed: Int
    /// True once the run ended, whether it ran out of entries or was cancelled.
    public var isFinished: Bool
}

/// One entry a labelling request reads. The text travels with the id so a
/// label lands only on the entry exactly as it was when the request was made.
struct OrganizerCandidate: Sendable {
    let id: UUID
    let text: String
}

/// One answered request of a Sort Entries run; a nil label is a failure.
struct OrganizerAnswer: Sendable {
    let candidate: OrganizerCandidate
    let label: EntryLabel?
}

/// Topics and the sorting model: the user's topic list, filing an entry under
/// one, the TypeSafe key, and the background labelling of memory entries.
///
/// Opt-in through `Settings.organizerEnabled`, and inert without a TypeSafe
/// key. The model only labels: a label is evidence about an entry, written
/// through `commitMemory` beside the user's text, which it never touches.
/// Nothing here delays delivery or a state change. Each new entry is labelled
/// by its own task, owned per entry so a later entry never cancels an earlier
/// one, and Sort Entries is one owned run at a time. Every landing observes
/// the `.organizing` generation and is discarded once sorting is turned off,
/// memory is cleared, the app is terminating, or the entry is gone or its text
/// changed. A request carries the entry's text and the topics' ids, names and
/// summaries; nothing here logs or stores the key or an entry's text.
@MainActor
extension DictationCoordinator {
    /// The most entries one Sort Entries run labels, newest first.
    static let sortRunLimit = 500
    /// The most requests a Sort Entries run keeps in flight at once.
    static let sortConcurrency = 4
    /// Labels a run collects before one commit, so a full run rewrites the
    /// memory files 25 times rather than once per entry.
    static let sortCommitBatch = 20

    // MARK: - The switch and the key

    /// Turns sorting on or off. Off cancels every labelling task and the run
    /// in flight and invalidates `.organizing`, so a label already on its way
    /// back writes nothing. On starts nothing by itself: new entries are
    /// labelled from then on, and existing ones only by Sort Entries.
    public func setOrganizerEnabled(_ enabled: Bool) {
        guard settings.organizerEnabled != enabled, !isPreparingForTermination else { return }
        settings.organizerEnabled = enabled
        saveSettings()
        guard !enabled else { return }
        generations.invalidate(.organizing)
        cancelOrganizerWork()
    }

    /// Where the TypeSafe key comes from, or nil when none is set. Never the
    /// key itself.
    ///
    /// Reads `typeSafeKeyRevision` so a view showing this re-reads it after
    /// every save: the key file is not observable state.
    public var typeSafeKeyOrigin: TypeSafeKeySource.Origin? {
        _ = typeSafeKeyRevision
        return typeSafeKeys.origin()
    }

    /// Saves the TypeSafe key to the owner-only key file; a blank key removes
    /// the file. False, with a reported failure, when the file could not be
    /// written or removed. The key is never logged or kept anywhere else.
    @discardableResult
    public func saveTypeSafeKey(_ key: String) -> Bool {
        defer { typeSafeKeyRevision += 1 }
        do {
            try typeSafeKeys.save(key)
            return true
        } catch {
            errorMessage = "The TypeSafe key could not be saved."
            return false
        }
    }

    // MARK: - Labelling new entries

    /// Hands an entry that just entered memory to its own labelling task, when
    /// sorting is on. Returns at once; the commit that added the entry is
    /// already queued.
    ///
    /// The key is checked inside the request, off the main actor, because
    /// reading the key file has no place on the delivery path. A missing key
    /// makes no request at all.
    func organizeNewMemoryEntry(_ entry: MemoryEntry) {
        guard settings.organizerEnabled, !isPreparingForTermination else { return }
        // Observed, never begun: one entry's label must not discard another's
        // or a Sort Entries run's.
        let token = generations.currentToken(.organizing)
        let identity = runtime.makeUUID()
        let candidate = OrganizerCandidate(id: entry.id, text: entry.text)
        let topics = memoryTopics
        let organizer = organizer
        let keys = typeSafeKeys
        let task = Task { [weak self] in
            let label = await DictationCoordinator.requestLabel(
                text: candidate.text,
                topics: topics,
                organizer: organizer,
                keys: keys
            )
            self?.applyOrganizerLabel(label, candidate: candidate, identity: identity, token: token)
        }
        organizerTasks[entry.id] = (identity: identity, task: task)
    }

    /// Lands one entry's label: drops its own task entry, then writes the
    /// label unless the task was cancelled or the write gates fail.
    func applyOrganizerLabel(
        _ label: EntryLabel?,
        candidate: OrganizerCandidate,
        identity: UUID,
        token: AsyncGenerationGate.Token
    ) {
        if organizerTasks[candidate.id]?.identity == identity {
            organizerTasks.removeValue(forKey: candidate.id)
        }
        guard let label, !Task.isCancelled else { return }
        writeOrganizerLabels([(candidate: candidate, label: label)], token: token)
    }

    // MARK: - Sort Entries

    /// Labels every memory entry the user has not filed, newest first, at most
    /// `sortRunLimit` per run and `sortConcurrency` requests at a time,
    /// publishing progress in `organizerRun`.
    ///
    /// Does nothing while a run is in flight, while sorting is off, or without
    /// a key: the key is read here because the user just asked, and a run that
    /// could only fail should not start.
    public func sortEntries() {
        guard organizerRunTask == nil,
            settings.organizerEnabled,
            !isPreparingForTermination,
            typeSafeKeys.key() != nil
        else { return }
        var candidates: [OrganizerCandidate] = []
        for entry in memoryEntries.reversed() where entry.userTopicID == nil {
            candidates.append(OrganizerCandidate(id: entry.id, text: entry.text))
            if candidates.count == Self.sortRunLimit { break }
        }
        guard !candidates.isEmpty else {
            organizerRun = OrganizerRun(done: 0, total: 0, failed: 0, isFinished: true)
            return
        }
        let token = generations.currentToken(.organizing)
        let identity = runtime.makeUUID()
        let topics = memoryTopics
        organizerRun = OrganizerRun(done: 0, total: candidates.count, failed: 0, isFinished: false)
        // `self?.run…` would make this a `Task<Void?, Never>`, which the stored
        // `Task<Void, Never>` cannot hold.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSortEntries(candidates, topics: topics, identity: identity, token: token)
        }
        organizerRunTask = (identity: identity, task: task)
    }

    /// Stops the run in flight. It ends marked finished with the progress it
    /// had published; labels it already received are still written, and no
    /// further request starts.
    public func cancelSortEntries() {
        guard let run = organizerRunTask else { return }
        run.task.cancel()
        organizerRunTask = nil
        organizerRun?.isFinished = true
    }

    /// Cancels every labelling task and the run in flight. Their landings are
    /// discarded by the caller's own gate: an invalidated `.organizing` token,
    /// or termination.
    func cancelOrganizerWork() {
        for entry in organizerTasks.values {
            entry.task.cancel()
        }
        organizerTasks.removeAll()
        cancelSortEntries()
    }

    /// One Sort Entries run. Keeps `sortConcurrency` requests in flight,
    /// counts each answer, and commits labels every `sortCommitBatch` and once
    /// at the end. Once cancelled it counts nothing more, writes what it had
    /// received, and leaves the rest of its requests to their cancellation.
    private func runSortEntries(
        _ candidates: [OrganizerCandidate],
        topics: [MemoryTopic],
        identity: UUID,
        token: AsyncGenerationGate.Token
    ) async {
        let organizer = organizer
        let keys = typeSafeKeys
        let request: @Sendable (OrganizerCandidate) async -> OrganizerAnswer = { candidate in
            let label = await DictationCoordinator.requestLabel(
                text: candidate.text,
                topics: topics,
                organizer: organizer,
                keys: keys
            )
            return OrganizerAnswer(candidate: candidate, label: label)
        }
        var done = 0
        var failed = 0
        await withTaskGroup(of: OrganizerAnswer.self) { group in
            var queue = candidates.makeIterator()
            for _ in 0..<Self.sortConcurrency {
                guard let candidate = queue.next() else { break }
                group.addTask { await request(candidate) }
            }
            var pending: [(candidate: OrganizerCandidate, label: EntryLabel)] = []
            while let answer = await group.next() {
                guard !Task.isCancelled else { break }
                done += 1
                if let label = answer.label {
                    pending.append((candidate: answer.candidate, label: label))
                } else {
                    failed += 1
                }
                if pending.count == Self.sortCommitBatch {
                    writeOrganizerLabels(pending, token: token)
                    pending.removeAll()
                }
                if organizerRunTask?.identity == identity {
                    organizerRun = OrganizerRun(done: done, total: candidates.count, failed: failed, isFinished: false)
                }
                if !Task.isCancelled, let candidate = queue.next() {
                    group.addTask { await request(candidate) }
                }
            }
            group.cancelAll()
            writeOrganizerLabels(pending, token: token)
        }
        guard organizerRunTask?.identity == identity else { return }
        organizerRunTask = nil
        organizerRun = OrganizerRun(done: done, total: candidates.count, failed: failed, isFinished: true)
    }

    /// Writes `labels` in one commit onto the entries that still exist with
    /// the text each request read, while the token is current, sorting is on
    /// and termination has not begun. Anything else is discarded.
    private func writeOrganizerLabels(
        _ labels: [(candidate: OrganizerCandidate, label: EntryLabel)],
        token: AsyncGenerationGate.Token
    ) {
        guard !labels.isEmpty,
            generations.isCurrent(token),
            settings.organizerEnabled,
            !isPreparingForTermination
        else { return }
        var entries = memoryEntries
        let positions = Dictionary(
            entries.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = false
        for (candidate, label) in labels {
            guard let index = positions[candidate.id], entries[index].text == candidate.text else { continue }
            entries[index].label = label
            changed = true
        }
        guard changed else { return }
        commitMemory(entries: entries)
    }

    /// Asks `organizer` for one label off the main actor. Nil without a key,
    /// which makes no request. Cancelling the caller cancels the request.
    nonisolated static func requestLabel(
        text: String,
        topics: [MemoryTopic],
        organizer: EntryOrganizing,
        keys: TypeSafeKeySource
    ) async -> EntryLabel? {
        let request = Task.detached(priority: .utility) { () -> EntryLabel? in
            guard keys.key() != nil else { return nil }
            return await organizer.label(text: text, topics: topics)
        }
        return await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
    }

    // MARK: - Topics

    /// Adds a topic the user named. Throws `TopicCatalog.Refusal` and changes
    /// nothing when the name is empty, taken, reserved, or one too many.
    public func addTopic(name: String, summary: String) throws {
        let topics = try TopicCatalog.adding(name: name, summary: summary, to: memoryTopics, now: runtime.now())
        commitMemory(entries: memoryEntries, topics: topics)
    }

    /// Renames topic `id` and replaces its summary; its id never changes.
    /// Throws `TopicCatalog.Refusal` and changes nothing on a refused name.
    public func updateTopic(id: String, name: String, summary: String) throws {
        let topics = try TopicCatalog.updating(id: id, name: name, summary: summary, in: memoryTopics)
        commitMemory(entries: memoryEntries, topics: topics)
    }

    /// Removes topic `id` and unfiles every entry the user filed under it, in
    /// one commit. A model's label naming the topic stays: it counts under no
    /// topic once the topic is unknown.
    public func removeTopic(id: String) {
        let topics = TopicCatalog.removing(id: id, from: memoryTopics)
        let entries = memoryEntries.map { entry in
            guard entry.userTopicID == id else { return entry }
            var entry = entry
            entry.userTopicID = nil
            return entry
        }
        commitMemory(entries: entries, topics: topics)
    }

    /// Files entry `id` under `topicID`, or removes it from every topic when
    /// `topicID` is nil. Filing is an explicit request to keep the entry, so a
    /// row only History holds is added to memory first. An unknown topic id,
    /// or an id neither memory nor History holds, changes nothing.
    public func fileEntry(id: UUID, underTopic topicID: String?) {
        if let topicID, !memoryTopics.contains(where: { $0.id == topicID }) { return }
        var entries = memoryEntries
        let index: Int
        if let kept = entries.firstIndex(where: { $0.id == id }) {
            index = kept
        } else if let session = recentSessions.first(where: { $0.id == id }) {
            entries.append(MemoryEntry(session))
            index = entries.count - 1
        } else {
            return
        }
        entries[index].userTopicID = topicID
        entries[index].userRemovedTopic = topicID == nil
        commitMemory(entries: entries)
    }
}
