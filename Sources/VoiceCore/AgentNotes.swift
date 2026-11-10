import Foundation

/// A Markdown file an agent saved directly under `agents/`, as Voiceour shows it: plain text with
/// its author, under the day or the topic its front matter names. It is never one of the owner's
/// entries, so it is never searched, labelled or sent anywhere.
public struct AgentNote: Equatable, Identifiable, Sendable {
    /// The file name, unique within `agents/`.
    public var id: String
    public var author: String
    public var title: String?
    /// `YYYY-MM-DD`.
    public var day: String?
    public var topicID: String?
    /// The Markdown after the front matter, trimmed of surrounding blank lines.
    public var body: String
    public var modifiedAt: Date

    public init(
        id: String,
        author: String,
        title: String? = nil,
        day: String? = nil,
        topicID: String? = nil,
        body: String,
        modifiedAt: Date
    ) {
        self.id = id
        self.author = author
        self.title = title
        self.day = day
        self.topicID = topicID
        self.body = body
        self.modifiedAt = modifiedAt
    }
}

/// Reads one agent file. Anything that does not follow the folder's rule (a front matter block
/// naming `author` and a `day` or a `topic`) is not a note, because Voiceour cannot place it.
public enum AgentNoteParser {
    /// A larger file is ignored, so one runaway agent cannot stall the Journal.
    public static let maximumBytes = 262_144
    /// At most this many notes load, newest modification first.
    public static let maximumFiles = 500

    /// The note `text` holds, or nil when it is not one. Never throws and never reads a file.
    ///
    /// The text must open with a line that is exactly `---`, and the front matter runs to the next
    /// such line. Each front matter line is `key: value`, split at the first colon; other lines are
    /// ignored. The body keeps its own bytes, line endings included, minus the blank lines around it.
    public static func parse(fileName: String, text: String, modifiedAt: Date) -> AgentNote? {
        let lines = lineRanges(of: text)
        guard let opening = lines.first, text[opening] == "---" else { return nil }
        guard let closing = lines.indices.dropFirst().first(where: { text[lines[$0]] == "---" }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            let content = text[line]
            guard let colon = content.firstIndex(of: ":") else { continue }
            let key = content[..<colon].trimmingCharacters(in: .whitespaces)
            let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquoted(value)
        }

        guard let author = nonBlank(fields["author"]) else { return nil }
        let day = nonBlank(fields["day"]).flatMap { isCalendarDay($0) ? $0 : nil }
        let topicID = nonBlank(fields["topic"])
        guard day != nil || topicID != nil else { return nil }

        let bodyLines = lines[(closing + 1)...].filter { !text[$0].allSatisfy(\.isWhitespace) }
        let body = bodyLines.first.flatMap { first in
            bodyLines.last.map { last in String(text[first.lowerBound..<last.upperBound]) }
        }

        return AgentNote(
            id: fileName,
            author: author,
            title: nonBlank(fields["title"]),
            day: day,
            topicID: topicID,
            body: body ?? "",
            modifiedAt: modifiedAt
        )
    }

    /// Each line's range without its terminator. A CRLF pair is one `Character`, so it ends one
    /// line, and a trailing terminator leaves a final empty line.
    private static func lineRanges(of text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index].isNewline {
                ranges.append(start..<index)
                start = next
            }
            index = next
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    /// Drops one pair of matching single or double quotes, which agents add to YAML values by habit.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else {
            return value
        }
        return value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `YYYY-MM-DD` naming a day that exists in the proleptic Gregorian calendar, checked by hand so
    /// the answer never depends on the current calendar or locale.
    static func isCalendarDay(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let dash = UInt8(ascii: "-")
        let zero = UInt8(ascii: "0")
        guard bytes.count == 10, bytes[4] == dash, bytes[7] == dash else { return false }
        let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digitPositions.allSatisfy({ (zero...UInt8(ascii: "9")).contains(bytes[$0]) }) else { return false }

        func number(_ positions: Range<Int>) -> Int {
            positions.reduce(0) { $0 * 10 + Int(bytes[$1] - zero) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        guard (1...12).contains(month) else { return false }

        let isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLengths = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...monthLengths[month - 1]).contains(day)
    }
}

extension MemoryStore {
    /// The notes agents saved directly under `agents/`, newest modification first. Never throws: an
    /// absent or unreadable folder is no notes, and a file that cannot be read or parsed is skipped.
    ///
    /// Only regular, visible `.md` files count; a symbolic link is skipped so an agent file can never
    /// pull a file from outside the folder into the Journal.
    public func loadAgentNotes() -> [AgentNote] {
        loadAgentNotes(maximumFiles: AgentNoteParser.maximumFiles)
    }

    /// `loadAgentNotes()` with its file limit as a parameter, so the limit is testable on a small folder.
    func loadAgentNotes(maximumFiles: Int) -> [AgentNote] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: agentsDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let candidates = urls.compactMap { (url: URL) -> (url: URL, modifiedAt: Date)? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".md"), !name.hasPrefix("."),
                let values = try? url.resourceValues(forKeys: keys),
                values.isSymbolicLink != true, values.isRegularFile == true,
                let size = values.fileSize, size <= AgentNoteParser.maximumBytes
            else { return nil }
            return (url: url, modifiedAt: values.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        var notes: [AgentNote] = []
        for candidate in candidates {
            guard notes.count < maximumFiles else { break }
            // The size is checked again on the bytes read, because the file may have grown since it was listed.
            guard let data = try? Data(contentsOf: candidate.url), data.count <= AgentNoteParser.maximumBytes,
                let text = String(data: data, encoding: .utf8),
                let note = AgentNoteParser.parse(
                    fileName: candidate.url.lastPathComponent,
                    text: text,
                    modifiedAt: candidate.modifiedAt
                )
            else { continue }
            notes.append(note)
        }
        return notes
    }
}

extension MemoryPages {
    /// The prompt a user copies into their own agent to have it recap one day. Voiceour never calls a
    /// writing model itself; the agent reads the day page, writes under `agents/`, and the recap
    /// returns to the Journal as an agent note under that day.
    ///
    /// Paths are quoted so a root with spaces still reads as one value, and the prompt stays one
    /// paragraph so it pastes into any agent's input as is.
    public static func recapPrompt(day: Date, root: URL, calendar: Calendar) -> String {
        let date = MemoryDateText.day(day, calendar: calendar)
        let page = promptPath(dayPath(day, calendar: calendar), root: root)
        let rules = promptPath(indexPath, root: root)
        let recap = promptPath("agents/\(date)-recap.md", root: root)
        return """
            Read "\(page)", the record of what I dictated and noted that day, and "\(rules)" for the folder's \
            rules. Write a recap of the day: what I worked on, what I decided, and what is still open. Quote my \
            words exactly wherever you quote. Save it as "\(recap)", starting with a front matter block that names \
            author (your own name), day: \(date) and a title.
            """
    }

    /// The prompt a user copies into their own agent to have it synthesize one topic; the result
    /// returns to the Journal as an agent note under that topic.
    public static func synthesisPrompt(topic: MemoryTopic, root: URL) -> String {
        let page = promptPath(topicPath(topic.id), root: root)
        let rules = promptPath(indexPath, root: root)
        let synthesis = promptPath("agents/topic-\(topicFileStem(topic.id)).md", root: root)
        return """
            Read "\(page)", everything I filed under the topic "\(topic.name)", and "\(rules)" for the folder's \
            rules. Write a synthesis: what I concluded, what changed over time, and what is still undecided. \
            Quote my words exactly wherever you quote. Save it as "\(synthesis)", starting with a front matter \
            block that names author (your own name), topic: \(topic.id) and a title.
            """
    }

    private static func promptPath(_ relativePath: String, root: URL) -> String {
        root.appendingPathComponent(relativePath).path
    }

    /// The topic page's file name without its folder and extension. It is the same sanitized name
    /// the page uses, so a hand-edited topic id can never steer the agent's file outside `agents/`.
    private static func topicFileStem(_ topicID: String) -> String {
        String(topicPath(topicID).dropFirst("topics/".count).dropLast(".md".count))
    }
}
