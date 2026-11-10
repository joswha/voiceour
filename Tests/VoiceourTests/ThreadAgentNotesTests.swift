import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// Covers which agent notes an open thread's page shows and how each note is dated:
/// a note joins a thread only by the exact file stem the outcome prompt dictates, and
/// its caption carries its own modification time in the calendar the lens is given.
@Suite("Thread agent notes")
struct ThreadAgentNotesTests {
    private static let key = AgentSessionKey(agent: .omp, sessionId: "01JABCDEF")
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func note(
        _ id: String,
        session: String? = nil,
        day: String? = nil,
        topicID: String? = nil,
        modifiedAt: Date = epoch
    ) -> AgentNote {
        AgentNote(
            id: id,
            author: "fixture-agent",
            title: nil,
            day: day,
            topicID: topicID,
            session: session,
            body: "Fixture body.",
            modifiedAt: modifiedAt
        )
    }

    @Test("A note shows on the thread whose stem it names, in the order given")
    func matchesByStem() {
        let stem = MemoryPages.threadFileStem(Self.key)
        let newer = Self.note("newer.md", session: stem, modifiedAt: Self.epoch.addingTimeInterval(60))
        let older = Self.note("older.md", session: stem, modifiedAt: Self.epoch)

        let shown = JournalThreadsLens.notes([newer, older], forThread: Self.key)

        #expect(shown.map(\.id) == ["newer.md", "older.md"])
    }

    @Test("Another session, a bare session id, or no session shows nothing")
    func otherNotesAreNotShown() {
        let stem = MemoryPages.threadFileStem(Self.key)
        let other = AgentSessionKey(agent: .claudeCode, sessionId: Self.key.sessionId)
        let notes = [
            Self.note("other-agent.md", session: MemoryPages.threadFileStem(other)),
            Self.note("bare-id.md", session: Self.key.sessionId),
            Self.note("prefix.md", session: stem + "-2"),
            // A day or topic that happens to spell the stem places nothing on a thread.
            Self.note("none.md", day: stem, topicID: stem),
        ]

        #expect(JournalThreadsLens.notes(notes, forThread: Self.key).isEmpty)
    }

    @Test("The caption carries the note's own time in the given calendar")
    func captionTimeIsTheNotesOwn() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let modifiedAt = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 5, minute: 6))
        )
        var titled = Self.note("outcome.md", modifiedAt: modifiedAt)
        titled.title = "Fixture outcome"
        let untitled = Self.note("untitled.md", modifiedAt: modifiedAt)

        #expect(
            JournalAgentNoteRow.caption(of: titled, calendar: calendar)
                == "Fixture outcome \u{00B7} by fixture-agent \u{00B7} 2026-03-04 05:06"
        )
        #expect(
            JournalAgentNoteRow.caption(of: untitled, calendar: calendar)
                == "untitled.md \u{00B7} by fixture-agent \u{00B7} 2026-03-04 05:06"
        )

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(
            JournalAgentNoteRow.caption(of: untitled, calendar: utc)
                == "untitled.md \u{00B7} by fixture-agent \u{00B7} 2026-03-03 20:06"
        )
    }
}
