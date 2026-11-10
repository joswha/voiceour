import Foundation
import Testing

@testable import VoiceCore

/// The Journal lenses regroup what the user said by session, project and day.
/// These pin the orderings a reader sees, the day and block boundaries, and the
/// wire format memory files rely on.
@Suite("Journal")
struct JournalTests {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func ref(
        _ sessionId: String,
        agent: CodingAgent = .omp,
        title: String? = nil,
        directory: String? = nil,
        sent: Bool? = nil
    ) -> JournalThreadRef {
        JournalThreadRef(agent: agent, sessionId: sessionId, title: title, workingDirectory: directory, sent: sent)
    }

    private func entry(
        _ text: String,
        at iso: String,
        kind: JournalEntry.Kind = .dictation,
        app: DictationAppIdentity? = nil,
        thread: JournalThreadRef? = nil,
        captureSeconds: Double = 0,
        label: EntryLabel? = nil
    ) -> JournalEntry {
        JournalEntry(
            id: UUID(),
            createdAt: date(iso),
            kind: kind,
            text: text,
            app: app,
            thread: thread,
            captureSeconds: captureSeconds,
            label: label
        )
    }

    private func label(_ kind: UtteranceKind?, confidence: Double?) -> EntryLabel {
        EntryLabel(kind: kind, kindConfidence: confidence, model: "jev-1.14.0", labeledAt: date("2026-11-10T12:00:00Z"))
    }

    // MARK: Threads

    @Test func threadRefComesFromTheNewestEntryWhenInputIsUnordered() throws {
        let entries = [
            entry("newest", at: "2026-11-10T12:00:00Z", thread: ref("s1", title: "New", directory: "/w/new")),
            entry("oldest", at: "2026-11-10T10:00:00Z", thread: ref("s1", title: "Old", directory: "/w/old")),
            entry("unbound", at: "2026-11-10T13:00:00Z"),
            entry("middle", at: "2026-11-10T11:00:00Z", thread: ref("s1", title: "Mid")),
        ]

        let threads = JournalQuery.threads(in: entries)

        let thread = try #require(threads.first)
        #expect(threads.count == 1)
        #expect(thread.ref.title == "New")
        #expect(thread.ref.workingDirectory == "/w/new")
        #expect(thread.entries.map(\.text) == ["oldest", "middle", "newest"])
        #expect(thread.firstAt == date("2026-11-10T10:00:00Z"))
        #expect(thread.lastAt == date("2026-11-10T12:00:00Z"))
    }

    @Test func threadRefTieGoesToTheLaterInputElement() throws {
        let entries = [
            entry("first", at: "2026-11-10T12:00:00Z", thread: ref("s1", title: "Earlier row")),
            entry("second", at: "2026-11-10T12:00:00Z", thread: ref("s1", title: "Later row")),
        ]

        let thread = try #require(JournalQuery.threads(in: entries).first)

        #expect(thread.ref.title == "Later row")
        #expect(thread.entries.map(\.text) == ["first", "second"])
    }

    @Test func threadsAreNewestFirstWithTiesBySessionId() {
        let entries = [
            entry("a", at: "2026-11-10T09:00:00Z", thread: ref("aaa")),
            entry("c", at: "2026-11-10T11:00:00Z", thread: ref("ccc")),
            entry("b", at: "2026-11-10T11:00:00Z", thread: ref("bbb")),
            entry("d", at: "2026-11-10T10:00:00Z", thread: ref("ddd")),
        ]

        let ids = JournalQuery.threads(in: entries).map(\.ref.sessionId)

        #expect(ids == ["bbb", "ccc", "ddd", "aaa"])
    }

    @Test func threadCountsSentAndNotSentEntries() throws {
        let entries = [
            entry("one", at: "2026-11-10T09:00:00Z", thread: ref("s1", sent: true)),
            entry("two", at: "2026-11-10T09:01:00Z", thread: ref("s1", sent: false)),
            entry("three", at: "2026-11-10T09:02:00Z", thread: ref("s1", sent: nil)),
            entry("four five", at: "2026-11-10T09:03:00Z", thread: ref("s1", sent: true)),
        ]

        let thread = try #require(JournalQuery.threads(in: entries).first)

        #expect(thread.sentCount == 2)
        #expect(thread.notSentCount == 1)
        #expect(thread.wordCount == 5)
    }

    @Test func displayTitleFallsBackFromTitleToProjectToSessionIdPrefix() throws {
        let titled = try #require(
            JournalQuery.threads(in: [
                entry("x", at: "2026-11-10T09:00:00Z", thread: ref("s1", title: "Fix the hotkey", directory: "/w/app"))
            ]).first
        )
        let blankTitle = try #require(
            JournalQuery.threads(in: [
                entry(
                    "x",
                    at: "2026-11-10T09:00:00Z",
                    thread: ref("s2", agent: .claudeCode, title: "   ", directory: "/Users/v/voiceour")
                )
            ]).first
        )
        let bare = try #require(
            JournalQuery.threads(in: [
                entry("x", at: "2026-11-10T09:00:00Z", thread: ref("0123456789abcdef", directory: ""))
            ]).first
        )

        #expect(titled.displayTitle == "omp · Fix the hotkey")
        #expect(blankTitle.displayTitle == "Claude Code · voiceour")
        #expect(bare.displayTitle == "omp · 01234567")
    }

    @Test(arguments: CodingAgent.allCases, [nil, "/Users/v/proj", "/Users/v/My Project"] as [String?])
    func threadResumeCommandMatchesTheBinding(agent: CodingAgent, directory: String?) throws {
        let thread = try #require(
            JournalQuery.threads(in: [
                entry("x", at: "2026-11-10T09:00:00Z", thread: ref("abc-123", agent: agent, directory: directory))
            ]).first
        )
        let binding = AgentSessionBinding(
            agent: agent,
            sessionId: "abc-123",
            workingDirectory: directory,
            boundAt: date("2026-11-10T09:00:00Z")
        )

        #expect(thread.resumeCommand == binding.resumeCommand)
        #expect(
            thread.resumeCommand
                == AgentSessionBinding.resumeCommand(agent: agent, sessionId: "abc-123", workingDirectory: directory)
        )
    }

    @Test func resumeCommandQuotesADirectoryWithASpace() {
        let command = AgentSessionBinding.resumeCommand(
            agent: .claudeCode,
            sessionId: "abc-123",
            workingDirectory: "/Users/v/My Project"
        )

        #expect(command == "cd '/Users/v/My Project' && claude --resume abc-123")
    }

    // MARK: Project groups

    @Test func projectGroupsOrderByNewestThreadWithNoDirectoryLast() {
        let entries = [
            entry("a old", at: "2026-11-10T10:00:00Z", thread: ref("a1", directory: "/w/a")),
            entry("b", at: "2026-11-10T12:00:00Z", thread: ref("b1", directory: "/w/b")),
            entry("none", at: "2026-11-10T13:00:00Z", thread: ref("n1")),
            entry("a new", at: "2026-11-10T11:00:00Z", thread: ref("a2", directory: "/w/a")),
        ]

        let groups = JournalQuery.projectGroups(of: JournalQuery.threads(in: entries))

        #expect(groups.map(\.directory) == ["/w/b", "/w/a", nil])
        #expect(groups.map(\.project) == ["b", "a", nil])
        #expect(groups.map(\.id) == ["/w/b", "/w/a", ""])
        #expect(groups[1].threads.map(\.ref.sessionId) == ["a2", "a1"])
    }

    // MARK: Days

    @Test func anEntryLateInTheLocalEveningStaysOnItsLocalDay() {
        let pacific = calendar("America/Los_Angeles")
        // 23:30 in Los Angeles on 10 November is 07:30 UTC on 11 November.
        let late = entry("late", at: "2026-11-10T23:30:00-08:00")
        let entries = [late, entry("morning", at: "2026-11-10T08:00:00-08:00")]

        let tenth = JournalQuery.rewind(day: date("2026-11-10T12:00:00-08:00"), in: entries, calendar: pacific)
        let eleventh = JournalQuery.rewind(day: date("2026-11-11T12:00:00-08:00"), in: entries, calendar: pacific)

        #expect(tenth.day == date("2026-11-10T00:00:00-08:00"))
        #expect(tenth.entryCount == 2)
        #expect(tenth.lastAt == late.createdAt)
        #expect(eleventh.entryCount == 0)
        #expect(JournalQuery.days(in: entries, calendar: pacific) == [date("2026-11-10T00:00:00-08:00")])
    }

    @Test func daysAreUniqueAndNewestFirst() {
        let utc = calendar("UTC")
        let entries = [
            entry("a", at: "2026-11-08T09:00:00Z"),
            entry("b", at: "2026-11-10T09:00:00Z"),
            entry("c", at: "2026-11-08T18:00:00Z"),
        ]

        #expect(
            JournalQuery.days(in: entries, calendar: utc) == [
                date("2026-11-10T00:00:00Z"), date("2026-11-08T00:00:00Z"),
            ]
        )
    }

    @Test func aDayWithNoEntriesIsEmpty() {
        let utc = calendar("UTC")
        let rewind = JournalQuery.rewind(
            day: date("2026-11-09T15:00:00Z"),
            in: [entry("other day", at: "2026-11-10T09:00:00Z")],
            calendar: utc
        )

        #expect(rewind.day == date("2026-11-09T00:00:00Z"))
        #expect(rewind.blocks.isEmpty)
        #expect(rewind.highlights.isEmpty)
        #expect(rewind.entryCount == 0)
        #expect(rewind.wordCount == 0)
        #expect(rewind.captureSeconds == 0)
        #expect(rewind.threadCount == 0)
        #expect(rewind.appCount == 0)
        #expect(rewind.noteCount == 0)
        #expect(rewind.firstAt == nil)
        #expect(rewind.lastAt == nil)
    }

    // MARK: Blocks

    @Test func aBlockSplitsOnAGapLongerThan1800SecondsOnly() {
        let thread = ref("s1")
        let entries = [
            entry("start", at: "2026-11-10T09:00:00Z", thread: thread),
            entry("exactly 1800 later", at: "2026-11-10T09:30:00Z", thread: thread),
            entry("1801 later", at: "2026-11-10T10:00:01Z", thread: thread),
        ]

        let blocks = JournalQuery.rewind(day: date("2026-11-10T12:00:00Z"), in: entries, calendar: calendar("UTC"))
            .blocks

        #expect(blocks.map(\.entries.count) == [2, 1])
        #expect(blocks.map(\.isContinuation) == [false, true])
        #expect(blocks[0].startAt == date("2026-11-10T09:00:00Z"))
        #expect(blocks[0].endAt == date("2026-11-10T09:30:00Z"))
    }

    @Test func aBlockSplitsOnASubjectChangeAndMarksTheReturnAsAContinuation() {
        let entries = [
            entry("in thread", at: "2026-11-10T09:00:00Z", thread: ref("s1", title: "Old title")),
            entry("in app", at: "2026-11-10T09:01:00Z", app: DictationAppIdentity(bundleId: "com.apple.Notes")),
            entry("back in thread", at: "2026-11-10T09:02:00Z", thread: ref("s1", title: "New title")),
            entry("still in thread", at: "2026-11-10T09:03:00Z", thread: ref("s1", title: "Newest title")),
        ]

        let blocks = JournalQuery.rewind(day: date("2026-11-10T12:00:00Z"), in: entries, calendar: calendar("UTC"))
            .blocks

        #expect(blocks.map(\.entries.count) == [1, 1, 2])
        #expect(blocks.map(\.isContinuation) == [false, false, true])
        #expect(blocks[2].subject == .thread(ref("s1", title: "Newest title")))
        #expect(blocks[2].id == entries[2].id)
    }

    @Test func aNoteJoinsItsThreadAndAnUnboundNoteMakesANotesBlock() {
        let thread = ref("s1")
        let entries = [
            entry("dictated", at: "2026-11-10T09:00:00Z", thread: thread),
            entry("noted in thread", at: "2026-11-10T09:05:00Z", kind: .note, thread: thread),
            entry("loose note", at: "2026-11-10T09:10:00Z", kind: .note),
            entry("unknown target", at: "2026-11-10T09:15:00Z"),
        ]

        let blocks = JournalQuery.rewind(day: date("2026-11-10T12:00:00Z"), in: entries, calendar: calendar("UTC"))
            .blocks

        #expect(blocks.map(\.subject) == [.thread(thread), .notes, .unknown])
        #expect(blocks.map(\.entries.count) == [2, 1, 1])
    }

    @Test func appBlocksKeyOnBundleIdAlone() {
        let entries = [
            entry("one", at: "2026-11-10T09:00:00Z", app: DictationAppIdentity(bundleId: "com.x", name: "X")),
            entry("two", at: "2026-11-10T09:01:00Z", app: DictationAppIdentity(bundleId: "com.x", name: "X Renamed")),
            entry("three", at: "2026-11-10T09:02:00Z", app: DictationAppIdentity(bundleId: "com.y", name: "X")),
        ]

        let blocks = JournalQuery.rewind(day: date("2026-11-10T12:00:00Z"), in: entries, calendar: calendar("UTC"))
            .blocks

        #expect(blocks.map(\.entries.count) == [2, 1])
        #expect(
            blocks.map(\.subject) == [
                .app(DictationAppIdentity(bundleId: "com.x", name: "X Renamed")),
                .app(DictationAppIdentity(bundleId: "com.y", name: "X")),
            ]
        )
    }

    @Test func dayTotalsCountThreadsAppsNotesAndCaptureTime() {
        let entries = [
            entry("one two", at: "2026-11-10T09:00:00Z", thread: ref("s1"), captureSeconds: 1.5),
            entry(
                "three",
                at: "2026-11-10T09:01:00Z",
                app: DictationAppIdentity(bundleId: "com.bound"),
                thread: ref("s1"),
                captureSeconds: 2.25
            ),
            entry("four", at: "2026-11-10T09:02:00Z", thread: ref("s2", agent: .claudeCode)),
            entry("five", at: "2026-11-10T09:03:00Z", thread: ref("s1", agent: .claudeCode)),
            entry(
                "six", at: "2026-11-10T09:04:00Z", app: DictationAppIdentity(bundleId: "com.x"), captureSeconds: 0.25),
            entry("seven", at: "2026-11-10T09:05:00Z", app: DictationAppIdentity(bundleId: "com.x")),
            entry("eight", at: "2026-11-10T09:06:00Z", app: DictationAppIdentity(bundleId: "com.y")),
            entry("nine ten", at: "2026-11-10T09:07:00Z", kind: .note),
            entry("other day", at: "2026-11-11T09:07:00Z", kind: .note, captureSeconds: 8),
        ]

        let rewind = JournalQuery.rewind(day: date("2026-11-10T12:00:00Z"), in: entries, calendar: calendar("UTC"))

        #expect(rewind.entryCount == 8)
        #expect(rewind.wordCount == 10)
        #expect(rewind.captureSeconds == 4.0)
        #expect(rewind.threadCount == 3)
        #expect(rewind.appCount == 2)
        #expect(rewind.noteCount == 1)
        #expect(rewind.firstAt == date("2026-11-10T09:00:00Z"))
        #expect(rewind.lastAt == date("2026-11-10T09:07:00Z"))
    }

    // MARK: Highlights

    @Test func highlightsKeepConfidentDecisionsIdeasTodosAndQuestionsInTimeOrder() {
        let entries = [
            entry("question", at: "2026-11-10T09:05:00Z", label: label(.question, confidence: 1.0)),
            entry("decision at threshold", at: "2026-11-10T09:00:00Z", label: label(.decision, confidence: 0.6)),
            entry("idea below threshold", at: "2026-11-10T09:01:00Z", label: label(.idea, confidence: 0.59)),
            entry("todo", at: "2026-11-10T09:02:00Z", label: label(.todo, confidence: 0.9)),
            entry("instruction", at: "2026-11-10T09:03:00Z", label: label(.instruction, confidence: 0.99)),
            entry("observation", at: "2026-11-10T09:04:00Z", label: label(.observation, confidence: 0.99)),
            entry("chatter", at: "2026-11-10T09:06:00Z", label: label(.chatter, confidence: 0.99)),
            entry("no confidence", at: "2026-11-10T09:07:00Z", label: label(.decision, confidence: nil)),
            entry("no kind", at: "2026-11-10T09:08:00Z", label: label(nil, confidence: 0.99)),
            entry("unlabelled", at: "2026-11-10T09:09:00Z"),
        ]

        let highlights = JournalQuery.rewind(
            day: date("2026-11-10T12:00:00Z"),
            in: entries,
            calendar: calendar("UTC")
        ).highlights

        #expect(highlights.map(\.kind) == [.decision, .todo, .question])
        #expect(highlights.map(\.entry.text) == ["decision at threshold", "todo", "question"])
    }

    // MARK: Search

    @Test func matchesIgnoreCaseAndDiacriticsAcrossTextTitleProjectAndApp() {
        let entries = [
            entry("Café plans", at: "2026-11-10T09:00:00Z"),
            entry("x", at: "2026-11-10T09:01:00Z", thread: ref("s1", title: "Résumé builder")),
            entry("x", at: "2026-11-10T09:02:00Z", thread: ref("s2", directory: "/Users/v/Voiceour")),
            entry(
                "x", at: "2026-11-10T09:03:00Z",
                app: DictationAppIdentity(bundleId: "com.apple.dt.Xcode", name: "Xcode")),
        ]

        #expect(JournalQuery.matches(in: entries, query: "CAFE").map(\.id) == [entries[0].id])
        #expect(JournalQuery.matches(in: entries, query: "resume").map(\.id) == [entries[1].id])
        #expect(JournalQuery.matches(in: entries, query: "voiceOUR").map(\.id) == [entries[2].id])
        #expect(JournalQuery.matches(in: entries, query: "xcode").map(\.id) == [entries[3].id])
        #expect(JournalQuery.matches(in: entries, query: "zzz").isEmpty)
        #expect(JournalQuery.matches(in: entries, query: "") == entries)
    }

    @Test func matchesKeepInputOrder() {
        let entries = [
            entry("plan b", at: "2026-11-10T12:00:00Z"),
            entry("plan a", at: "2026-11-10T09:00:00Z"),
            entry("other", at: "2026-11-10T10:00:00Z"),
            entry("plan c", at: "2026-11-10T11:00:00Z"),
        ]

        #expect(JournalQuery.matches(in: entries, query: "plan").map(\.text) == ["plan b", "plan a", "plan c"])
    }

    // MARK: History rows

    @Test(arguments: zip([nil, 0, -5, 1500] as [Int?], [0, 0, 0, 1.5] as [Double]))
    func entryFromSessionMeasuresOnlyPositiveCapture(captureMs: Int?, expected: Double) {
        let session = RecentSession(
            createdAt: date("2026-11-10T09:00:00Z"),
            text: "hello",
            stages: SessionStageTimings(captureMs: captureMs)
        )

        #expect(JournalEntry(session).captureSeconds == expected)
    }

    @Test func entryFromSessionWithoutStagesHasNoCaptureTime() {
        let session = RecentSession(createdAt: date("2026-11-10T09:00:00Z"), text: "hello")

        #expect(JournalEntry(session).captureSeconds == 0)
    }

    @Test(
        arguments: zip(
            [nil, .notSent, .sent(sentAt: Date(timeIntervalSince1970: 1_800_000_000), text: nil)] as [AgentPromptSend?],
            [nil, false, true] as [Bool?]
        )
    )
    func entryFromSessionMapsTheSendState(send: AgentPromptSend?, expected: Bool?) throws {
        let session = RecentSession(
            createdAt: date("2026-11-10T09:00:00Z"),
            text: "ship it",
            agentSession: AgentSessionBinding(
                agent: .claudeCode,
                sessionId: "abc",
                workingDirectory: "/w/app",
                sessionTitle: "Ship",
                boundAt: date("2026-11-10T09:00:01Z"),
                resumable: true,
                send: send
            )
        )

        let thread = try #require(JournalEntry(session).thread)

        #expect(thread.sent == expected)
        #expect(thread.key == AgentSessionKey(agent: .claudeCode, sessionId: "abc"))
        #expect(thread.title == "Ship")
        #expect(thread.workingDirectory == "/w/app")
        #expect(thread.resumable)
    }

    @Test func entryFromSessionCarriesIdentityAndTarget() {
        let session = RecentSession(
            createdAt: date("2026-11-10T09:00:00Z"),
            text: "two words",
            outcome: RecentSessionOutcomeMetadata(
                disposition: .pasteAttempted,
                targetSafety: .normalText,
                targetBundleId: "com.apple.Notes",
                targetAppName: "Notes"
            )
        )
        let untargeted = RecentSession(
            createdAt: date("2026-11-10T09:00:00Z"),
            text: "x",
            outcome: RecentSessionOutcomeMetadata(disposition: .failed, targetAppName: "Orphan name")
        )

        let entry = JournalEntry(session)

        #expect(entry.id == session.id)
        #expect(entry.createdAt == session.createdAt)
        #expect(entry.kind == .dictation)
        #expect(entry.text == "two words")
        #expect(entry.wordCount == 2)
        #expect(entry.app == DictationAppIdentity(bundleId: "com.apple.Notes", name: "Notes"))
        #expect(entry.thread == nil)
        #expect(JournalEntry(untargeted).app == nil)
    }

    // MARK: Wire format

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func keys(of data: Data) throws -> Set<String> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(object.keys)
    }

    @Test func entryLabelRoundTripsWithSnakeCaseKeys() throws {
        let label = EntryLabel(
            kind: .todo,
            kindConfidence: 0.75,
            topicID: "voiceour-journal",
            topicConfidence: 0.5,
            keep: 2,
            model: "jev-1.14.0",
            labeledAt: date("2026-11-10T09:27:19Z")
        )

        let data = try encoder().encode(label)

        #expect(try decoder().decode(EntryLabel.self, from: data) == label)
        #expect(
            try keys(of: data) == [
                "kind", "kind_confidence", "topic_id", "topic_confidence", "keep", "model", "labeled_at",
            ]
        )
    }

    @Test func entryLabelDecodesAnUnknownKindAsNilAndNeedsOnlyModelAndTime() throws {
        let json = #"{"kind":"rant","kind_confidence":"high","model":"jev-2","labeled_at":"2026-11-10T09:27:19Z"}"#

        let label = try decoder().decode(EntryLabel.self, from: Data(json.utf8))

        #expect(label == EntryLabel(model: "jev-2", labeledAt: date("2026-11-10T09:27:19Z")))
        #expect(throws: DecodingError.self) {
            try decoder().decode(EntryLabel.self, from: Data(#"{"labeled_at":"2026-11-10T09:27:19Z"}"#.utf8))
        }
    }

    @Test func threadRefRoundTripsWithSnakeCaseKeys() throws {
        let ref = JournalThreadRef(
            agent: .claudeCode,
            sessionId: "abc-123",
            title: "Ship the journal",
            workingDirectory: "/Users/v/My Project",
            resumable: true,
            sent: false
        )

        let data = try encoder().encode(ref)

        #expect(try decoder().decode(JournalThreadRef.self, from: data) == ref)
        #expect(try keys(of: data) == ["agent", "session_id", "title", "working_directory", "resumable", "sent"])
    }

    @Test func threadRefDecodesBlankFieldsAsNilAndDefaultsResumable() throws {
        let json = #"{"agent":"omp","session_id":"s1","title":"  ","working_directory":""}"#

        let ref = try decoder().decode(JournalThreadRef.self, from: Data(json.utf8))

        #expect(ref == JournalThreadRef(agent: .omp, sessionId: "s1"))
        #expect(ref.title == nil)
        #expect(ref.workingDirectory == nil)
        #expect(ref.project == nil)
        #expect(ref.resumable == false)
        #expect(ref.sent == nil)
        #expect(JournalThreadRef(agent: .omp, sessionId: "s1", title: "\n").title == nil)
    }
}
