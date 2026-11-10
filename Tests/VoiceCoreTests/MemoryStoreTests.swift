import Foundation
import Testing

@testable import VoiceCore

/// A whole-second instant from an ISO 8601 string with an explicit zone, so
/// the fixture survives the store's ISO 8601 round trip exactly.
private func memoryInstant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func memoryEntryID(_ number: Int) -> UUID {
    let digits = String(number)
    return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
}

private func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = try #require(attributes[.posixPermissions] as? Int)
    return mode & 0o777
}

@Suite("Memory store")
struct MemoryStoreTests {
    private let thread = JournalThreadRef(
        agent: .omp,
        sessionId: "01a1c154-ce7b-70a7-9d17-da6c0eb43054",
        title: "Check agent session storage",
        workingDirectory: "/Users/vlad/Desktop/voiceoour",
        resumable: true,
        sent: true
    )
    private let topic = MemoryTopic(
        id: "memory-system",
        name: "Memory system",
        summary: "Design of the persistent store.",
        createdAt: memoryInstant("2026-10-01T08:00:00Z")
    )

    /// A store under a fresh temporary directory, and that directory, which
    /// the test removes.
    private func temporaryStore() -> (store: MemoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (MemoryStore(root: directory.appendingPathComponent("memory", isDirectory: true)), directory)
    }

    private func fixture() -> [MemoryEntry] {
        [
            MemoryEntry(
                id: memoryEntryID(1),
                createdAt: memoryInstant("2026-10-31T22:15:00Z"),
                text: "October words.",
                appBundleId: "com.apple.mail",
                appName: "Mail",
                captureSeconds: 2.5
            ),
            MemoryEntry(
                id: memoryEntryID(2),
                createdAt: memoryInstant("2026-11-10T09:27:19Z"),
                text: "Testing.",
                thread: thread,
                label: EntryLabel(
                    kind: .decision,
                    kindConfidence: 0.9,
                    topicID: "memory-system",
                    topicConfidence: 0.7,
                    keep: 2,
                    model: "jev-1.14.0",
                    labeledAt: memoryInstant("2026-11-10T09:27:21Z")
                )
            ),
            MemoryEntry(
                id: memoryEntryID(3),
                createdAt: memoryInstant("2026-11-10T11:02:40Z"),
                kind: .note,
                text: "The memory folder should be plain files.\nAnd readable.",
                userTopicID: "memory-system"
            ),
        ]
    }

    private func writeRaw(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Round trip

    @Test func everyEntryAndTopicLoadsBackOldestFirst() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = fixture()

        try store.apply(MemoryPlanner.rebuild(entries: entries.reversed(), topics: [topic], calendar: utc))
        let load = store.load()

        #expect(load.entries == entries)
        #expect(load.topics == [topic])
        #expect(load.unreadable.isEmpty)
    }

    @Test func entriesAtTheSameInstantKeepTheirOrderAcrossMonths() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let same = memoryInstant("2026-11-10T09:00:00Z")
        let first = MemoryEntry(id: memoryEntryID(9), createdAt: same, text: "First.")
        let second = MemoryEntry(id: memoryEntryID(4), createdAt: same, text: "Second.")
        let earlier = MemoryEntry(
            id: memoryEntryID(7),
            createdAt: memoryInstant("2026-09-01T00:00:00Z"),
            text: "Earlier."
        )

        try store.apply(MemoryWrite(months: ["2026-11": [first, second], "2026-09": [earlier]]))

        #expect(store.load().entries == [earlier, first, second])
    }

    @Test func filesAreOwnerOnlyAndDirectoriesPrivate() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.apply(MemoryPlanner.rebuild(entries: fixture(), topics: [topic], calendar: utc))

        #expect(try posixMode(store.root) == 0o700)
        #expect(try posixMode(store.entriesDirectory) == 0o700)
        #expect(try posixMode(store.root.appendingPathComponent("days")) == 0o700)
        #expect(try posixMode(store.monthURL("2026-11")) == 0o600)
        #expect(try posixMode(store.topicsURL) == 0o600)
        #expect(try posixMode(store.root.appendingPathComponent("days/2026-11-10.md")) == 0o600)
        #expect(try posixMode(store.root.appendingPathComponent(MemoryPages.indexPath)) == 0o600)
    }

    @Test func pagesLandAtTheirRelativePaths() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = MemoryPage(path: "days/2026-11-10.md", text: "# 2026-11-10, Tuesday\n")

        try store.apply(MemoryWrite(pages: [page]))

        let onDisk = try String(contentsOf: store.root.appendingPathComponent("days/2026-11-10.md"), encoding: .utf8)
        #expect(onDisk == page.text)
    }

    @Test func theMonthKeyFollowsTheCalendarsTimeZone() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(secondsFromGMT: -5 * 3600))
        let boundary = memoryInstant("2026-12-01T03:00:00Z")

        #expect(MemoryStore.monthKey(for: boundary, calendar: utc) == "2026-12")
        #expect(MemoryStore.monthKey(for: boundary, calendar: newYork) == "2026-11")
        #expect(MemoryStore.monthKey(for: memoryInstant("2026-01-01T00:00:00Z"), calendar: utc) == "2026-01")
    }

    @Test func anEmptyMonthRemovesItsFile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = fixture()
        try store.apply(MemoryPlanner.rebuild(entries: entries, topics: [], calendar: utc))

        try store.apply(MemoryWrite(months: ["2026-10": []]))

        #expect(!FileManager.default.fileExists(atPath: store.monthURL("2026-10").path))
        #expect(store.load().entries == Array(entries.dropFirst()))
    }

    @Test func removingAnAbsentFileSucceeds() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.apply(MemoryWrite(months: ["2026-10": []], topics: [], removedPages: ["days/2026-10-01.md"]))

        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    @Test func clearRemovesTheWholeRootAndAgainSucceeds() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.apply(MemoryPlanner.rebuild(entries: fixture(), topics: [topic], calendar: utc))
        try writeRaw("---\nauthor: omp\n---\n", to: store.agentsDirectory.appendingPathComponent("summary.md"))

        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.root.path))

        try store.clear()
        #expect(store.load() == MemoryLoad())
    }

    // MARK: Pages rebuild

    /// A pages rebuild removes the derived pages it did not write and nothing
    /// else: not the records, an agent's note, a symlink, a set-aside file or a
    /// subfolder. The stamp lands last, owner-only.
    @Test func aSweepRemovesOnlyStaleDerivedPages() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let entries = fixture()
        try store.apply(MemoryPlanner.rebuild(entries: entries, topics: [topic], calendar: utc))
        let root = store.root
        let outside = directory.appendingPathComponent("outside.md")
        let note = store.agentsDirectory.appendingPathComponent("recap.md")
        let staleThread = root.appendingPathComponent("threads/x.md")
        let otherZoneDay = root.appendingPathComponent("days/2026-11-11.md")
        let setAside = root.appendingPathComponent("days/2026-11-09.md.corrupt-2026-11-10T09:00:00Z")
        let setAsidePage = root.appendingPathComponent("topics/old.corrupt-2026-11-10T09:00:00Z.md")
        let nested = root.appendingPathComponent("notes/folder.md/inner.md")
        let link = root.appendingPathComponent("threads/link.md")
        try writeRaw("Outside.\n", to: outside)
        try writeRaw("---\nauthor: omp\nday: 2026-11-10\n---\n", to: note)
        try writeRaw("Old layout.\n", to: staleThread)
        try writeRaw("Another zone.\n", to: otherZoneDay)
        try writeRaw("Set aside.\n", to: setAside)
        try writeRaw("Set aside.\n", to: setAsidePage)
        try writeRaw("Nested.\n", to: nested)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        try writeRaw("1 gregorian Asia/Tokyo\n", to: store.pagesFormatURL)
        let month = try Data(contentsOf: store.monthURL("2026-11"))
        let topics = try Data(contentsOf: store.topicsURL)

        try store.apply(MemoryPlanner.rebuildPages(entries: entries, topics: [topic], calendar: utc, sweep: true))

        #expect(!fileManager.fileExists(atPath: staleThread.path))
        #expect(!fileManager.fileExists(atPath: otherZoneDay.path))
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent("days/2026-11-10.md").path))
        #expect(fileManager.fileExists(atPath: note.path))
        #expect(fileManager.fileExists(atPath: setAside.path))
        #expect(fileManager.fileExists(atPath: setAsidePage.path))
        #expect(fileManager.fileExists(atPath: nested.path))
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(fileManager.fileExists(atPath: outside.path))
        #expect(try Data(contentsOf: store.monthURL("2026-11")) == month)
        #expect(try Data(contentsOf: store.topicsURL) == topics)
        #expect(
            try String(contentsOf: store.pagesFormatURL, encoding: .utf8) == "2 gregorian \(utc.timeZone.identifier)\n"
        )
        #expect(store.pagesFormat() == "2 gregorian \(utc.timeZone.identifier)")
        #expect(try posixMode(store.pagesFormatURL) == 0o600)
        #expect(try posixMode(root) == 0o700)
    }

    /// Without a sweep a write leaves pages it does not name alone, and a diff
    /// write never stamps.
    @Test func aWriteWithoutASweepKeepsOtherPagesAndWritesNoStamp() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = fixture()
        let stale = store.root.appendingPathComponent("threads/x.md")
        try writeRaw("Old layout.\n", to: stale)

        try store.apply(MemoryPlanner.rebuildPages(entries: entries, topics: [topic], calendar: utc, sweep: false))
        try FileManager.default.removeItem(at: store.pagesFormatURL)
        try store.apply(
            MemoryPlanner.write(before: [], after: entries, topicsBefore: [], topicsAfter: [topic], calendar: utc)
        )

        #expect(FileManager.default.fileExists(atPath: stale.path))
        #expect(store.pagesFormat() == nil)
    }

    @Test func aPageWriteThatFailsLeavesTheStampUnwritten() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A folder where a page belongs makes that page's write throw.
        try writeRaw("Blocker.\n", to: store.root.appendingPathComponent("days/2026-11-10.md/blocker"))

        #expect(throws: (any Error).self) {
            try store.apply(MemoryPlanner.rebuildPages(entries: fixture(), topics: [topic], calendar: utc, sweep: true))
        }
        #expect(!FileManager.default.fileExists(atPath: store.pagesFormatURL.path))
        #expect(store.pagesFormat() == nil)
    }

    // MARK: Damage

    @Test func aCorruptMonthIsListedAndTheOtherMonthsStillLoad() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = fixture()
        try store.apply(MemoryPlanner.rebuild(entries: entries, topics: [topic], calendar: utc))

        try writeRaw("[{\"id\": ", to: store.monthURL("2026-10"))
        let load = store.load()

        #expect(load.unreadable == [store.monthURL("2026-10")])
        #expect(load.entries == Array(entries.dropFirst()))
        #expect(load.topics == [topic])
    }

    @Test func aCorruptTopicsFileIsListedAndLoadsNoTopics() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = fixture()
        try store.apply(MemoryPlanner.rebuild(entries: entries, topics: [topic], calendar: utc))

        try writeRaw("{}", to: store.topicsURL)
        let load = store.load()

        #expect(load.unreadable == [store.topicsURL])
        #expect(load.topics.isEmpty)
        #expect(load.entries == entries)
    }

    @Test func anUnknownKindLoadsAsADictationAndAMalformedThreadOrLabelAsNil() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(
            """
            [
              {
                "id": "00000000-0000-0000-0000-000000000005",
                "created_at": "2026-11-10T09:27:19Z",
                "kind": "memo",
                "text": "Written by a later version.",
                "thread": {"agent": "codex", "session_id": "abc"},
                "label": {"kind": "idea"}
              }
            ]
            """,
            to: store.monthURL("2026-11")
        )

        let load = store.load()

        #expect(load.unreadable.isEmpty)
        #expect(
            load.entries
                == [
                    MemoryEntry(
                        id: memoryEntryID(5),
                        createdAt: memoryInstant("2026-11-10T09:27:19Z"),
                        kind: .dictation,
                        text: "Written by a later version."
                    )
                ]
        )
    }

    @Test func aFieldOfTheWrongTypeReadsAsAbsentAndKeepsTheEntry() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(
            """
            [
              {
                "id": "00000000-0000-0000-0000-000000000006",
                "created_at": "2026-11-10T09:27:19Z",
                "kind": "note",
                "text": "Kept whatever its other fields hold.",
                "app_bundle_id": 7,
                "app_name": ["Mail"],
                "capture_seconds": "long",
                "user_topic_id": 3,
                "user_removed_topic": "yes"
              }
            ]
            """,
            to: store.monthURL("2026-11")
        )

        let load = store.load()

        #expect(load.unreadable.isEmpty)
        #expect(
            load.entries
                == [
                    MemoryEntry(
                        id: memoryEntryID(6),
                        createdAt: memoryInstant("2026-11-10T09:27:19Z"),
                        kind: .note,
                        text: "Kept whatever its other fields hold."
                    )
                ]
        )
    }

    @Test func aMissRoundTripsUnderItsRawValue() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unlinked = MemoryEntry(
            id: memoryEntryID(7),
            createdAt: memoryInstant("2026-11-10T09:30:00Z"),
            text: "Pasted into a pane that moved.",
            unlinked: .focusMoved
        )

        try store.apply(MemoryPlanner.rebuild(entries: [unlinked], topics: [], calendar: utc))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.monthURL("2026-11")))
        let records = try #require(json as? [[String: Any]])

        #expect(records.map { $0["unlinked"] as? String } == ["focus_moved"])
        #expect(store.load().entries == [unlinked])
    }

    /// A miss a later build named, or a value of the wrong type, costs only
    /// the miss; an entry stored with a thread and a miss reads as linked.
    @Test func anUnknownMissReadsAsUnknownAndAThreadWinsOverAMiss() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRaw(
            """
            [
              {
                "id": "00000000-0000-0000-0000-000000000008",
                "created_at": "2026-11-10T09:27:19Z",
                "text": "Unknown miss.",
                "unlinked": "pane_closed"
              },
              {
                "id": "00000000-0000-0000-0000-000000000009",
                "created_at": "2026-11-10T09:28:19Z",
                "text": "Wrong type.",
                "unlinked": 3
              },
              {
                "id": "00000000-0000-0000-0000-000000000010",
                "created_at": "2026-11-10T09:29:19Z",
                "text": "Linked and missed.",
                "thread": {"agent": "omp", "session_id": "\(thread.sessionId)", "title": null},
                "unlinked": "busy"
              }
            ]
            """,
            to: store.monthURL("2026-11")
        )

        let load = store.load()

        #expect(load.unreadable.isEmpty)
        #expect(load.entries.map(\.text) == ["Unknown miss.", "Wrong type.", "Linked and missed."])
        #expect(load.entries.map(\.unlinked) == [nil, nil, nil])
        #expect(load.entries.last?.thread?.sessionId == thread.sessionId)
    }

    @Test func anEntryNeverHoldsBothAThreadAndAMiss() {
        var entry = MemoryEntry(id: memoryEntryID(11), createdAt: memoryInstant("2026-11-10T09:30:00Z"), text: "x")
        entry.unlinked = .noAgent
        #expect(entry.unlinked == .noAgent)
        #expect(JournalEntry(entry, knownTopicIDs: []).unlinked == .noAgent)

        entry.thread = thread
        #expect(entry.unlinked == nil)

        entry.unlinked = .busy
        #expect(entry.unlinked == nil)
        #expect(entry.thread == thread)

        #expect(
            MemoryEntry(
                id: memoryEntryID(12),
                createdAt: memoryInstant("2026-11-10T09:30:00Z"),
                text: "x",
                thread: thread,
                unlinked: .codex
            ).unlinked == nil
        )
    }

    @Test func theMonthFileHoldsISO8601DateStrings() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.apply(MemoryPlanner.rebuild(entries: fixture(), topics: [], calendar: utc))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.monthURL("2026-11")))
        let records = try #require(json as? [[String: Any]])

        #expect(records.map { $0["created_at"] as? String } == ["2026-11-10T09:27:19Z", "2026-11-10T11:02:40Z"])
        let label = try #require(records[0]["label"] as? [String: Any])
        #expect(label["labeled_at"] as? String == "2026-11-10T09:27:21Z")
    }
}

@Suite("Memory entry topic")
struct MemoryEntryTopicTests {
    private let known: Set<String> = ["alpha", "beta"]

    private func entry(
        userTopicID: String? = nil,
        userRemovedTopic: Bool = false,
        labelTopic: String? = nil,
        confidence: Double? = nil
    ) -> MemoryEntry {
        MemoryEntry(
            id: memoryEntryID(1),
            createdAt: memoryInstant("2026-11-10T09:27:19Z"),
            text: "Words.",
            userTopicID: userTopicID,
            userRemovedTopic: userRemovedTopic,
            label: labelTopic.map {
                EntryLabel(
                    topicID: $0,
                    topicConfidence: confidence,
                    model: "jev-1.14.0",
                    labeledAt: memoryInstant("2026-11-10T09:27:21Z")
                )
            }
        )
    }

    @Test func theUsersTopicWinsOverAConfidentLabel() {
        let filed = entry(userTopicID: "alpha", labelTopic: "beta", confidence: 0.95)
        #expect(filed.effectiveTopicID(known: known) == "alpha")
    }

    /// A user's choice of a topic since deleted does not hand the entry to the
    /// model's guess.
    @Test func aUserTopicThatIsNoLongerKnownGivesNoTopic() {
        let orphaned = entry(userTopicID: "gone", labelTopic: "beta", confidence: 0.95)
        #expect(orphaned.effectiveTopicID(known: known) == nil)
    }

    @Test func removingTheTopicBeatsAConfidentLabel() {
        let removed = entry(userRemovedTopic: true, labelTopic: "beta", confidence: 0.95)
        #expect(removed.effectiveTopicID(known: known) == nil)
    }

    @Test func aLabelCountsFromConfidenceSixTenths() {
        #expect(entry(labelTopic: "beta", confidence: 0.6).effectiveTopicID(known: known) == "beta")
        #expect(entry(labelTopic: "beta", confidence: 0.59).effectiveTopicID(known: known) == nil)
        #expect(entry(labelTopic: "beta", confidence: nil).effectiveTopicID(known: known) == nil)
    }

    @Test func aLabelTopicThatIsNotKnownGivesNoTopic() {
        #expect(entry(labelTopic: "gamma", confidence: 0.95).effectiveTopicID(known: known) == nil)
    }

    @Test func theJournalEntryCarriesTheEffectiveTopicAndTheApp() {
        var memory = entry(labelTopic: "beta", confidence: 0.8)
        memory.appBundleId = "com.apple.mail"
        memory.appName = "Mail"

        let journal = JournalEntry(memory, knownTopicIDs: known)

        #expect(journal.topicID == "beta")
        #expect(journal.app == DictationAppIdentity(bundleId: "com.apple.mail", name: "Mail"))
        #expect(JournalEntry(memory, knownTopicIDs: []).topicID == nil)
    }
}
