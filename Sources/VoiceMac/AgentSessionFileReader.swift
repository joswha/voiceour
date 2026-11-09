import Foundation
import VoiceCore

/// Reads a bound session's own records under the home folder: its title,
/// whether its record file exists, and the prompts it recorded around and
/// after the binding's prompt-log offset.
///
/// - omp: the bound session file, or the file with the bound id directly in a
///   `sessions` project folder when it moved. Prompts are its user messages.
/// - Claude Code: `history.jsonl` lines of the bound session, pasted text
///   expanded. The title is the name in the session's live
///   `sessions/<pid>.json` record unless Claude Code derived it, else the
///   transcript tail's last `custom-title` or `ai-title`.
///
/// Only canonical paths under `<home>/.omp/agent` and `<home>/.claude` are
/// opened, and only complete lines are parsed. The offset is measured just
/// after the paste, so reading starts 256 KiB before it; an offset the file no
/// longer matches (shorter, or not at a line start) reads the last 16 MiB
/// instead. Either way only prompts sent from one second before the binding
/// are kept: the binding precedes the paste, so a matching prompt sent earlier
/// is an earlier prompt with the same words.
public struct AgentSessionFileReader: AgentSessionReading {
    private let files: AgentSessionFiles

    public init(homeDirectory: URL) {
        files = AgentSessionFiles(home: homeDirectory, fileSystem: .live)
    }

    public func read(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
        guard AgentSessionFiles.isSessionId(binding.sessionId) else { return nil }
        switch binding.agent {
        case .omp: return readOmp(binding)
        case .claudeCode: return readClaudeCode(binding)
        }
    }

    /// How far before the binding a prompt may have been sent. The prompt is
    /// sent after the paste, but a timestamp kept in whole seconds reads up to
    /// a second early.
    static let promptLeeway: TimeInterval = 1
    /// How many bytes before a valid offset reading starts, for prompts sent
    /// between the paste and the offset's measurement.
    static let promptLookback = 256 << 10
    /// The most bytes read in one call.
    static let promptReadLimit = 16 << 20
    /// The most bytes read at once.
    static let promptChunkSize = 1 << 20

    // MARK: omp

    private func readOmp(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
        var sessionFile: String?
        if let bound = binding.sessionFile {
            switch files.location(of: bound, under: .omp) {
            case .inside(let canonical): sessionFile = canonical
            case .outside: return nil
            case .missing: break
            }
        }
        guard
            let path = sessionFile ?? files.ompSessionFile(id: binding.sessionId),
            let size = files.fileSystem.fileSize(path)
        else { return AgentSessionSnapshot(title: nil, sessionFileExists: false, prompts: []) }
        return AgentSessionSnapshot(
            title: files.ompHead(path).title,
            sessionFileExists: true,
            prompts: prompts(in: path, size: size, binding: binding, needle: Self.ompUserNeedle, parse: Self.ompPrompt)
        )
    }

    private static let ompUserNeedle = Data(#""role":"user""#.utf8)

    private static func ompPrompt(_ line: Data) -> AgentSessionPrompt? {
        guard
            let record = try? JSONDecoder().decode(OmpMessageRecord.self, from: line),
            record.type == "message",
            record.message?.role == "user",
            let timestamp = record.timestamp,
            let sentAt = isoDate(timestamp),
            let text = record.message?.text
        else { return nil }
        return AgentSessionPrompt(sentAt: sentAt, text: text)
    }

    // MARK: Claude Code

    private func readClaudeCode(_ binding: AgentSessionBinding) -> AgentSessionSnapshot? {
        let transcript = files.claudeTranscript(sessionId: binding.sessionId)
        var prompts: [AgentSessionPrompt] = []
        switch files.location(of: files.path(.claude, "history.jsonl"), under: .claude) {
        case .inside(let history):
            if let size = files.fileSystem.fileSize(history) {
                let sessionId = binding.sessionId
                prompts = self.prompts(
                    in: history,
                    size: size,
                    binding: binding,
                    needle: Data(sessionId.utf8),
                    parse: { Self.claudeCodePrompt($0, sessionId: sessionId) }
                )
            }
        case .outside:
            return nil
        case .missing:
            break
        }
        return AgentSessionSnapshot(
            title: files.claudeRegistryName(sessionId: binding.sessionId)
                ?? transcript.flatMap(files.claudeTranscriptTitle),
            sessionFileExists: transcript != nil,
            prompts: prompts
        )
    }

    private static func claudeCodePrompt(_ line: Data, sessionId: String) -> AgentSessionPrompt? {
        guard
            let record = try? JSONDecoder().decode(ClaudeHistoryRecord.self, from: line),
            record.sessionId == sessionId
        else { return nil }
        return AgentSessionPrompt(
            sentAt: Date(timeIntervalSince1970: record.timestamp / 1_000),
            text: expandingPastes(in: record.display, from: record.pastedContents)
        )
    }

    private static let pastePlaceholder = try! NSRegularExpression(
        pattern: #"\[Pasted text #(\d+)(?: \+\d+ lines)?\]"#
    )

    /// Claude Code shows a long paste as a placeholder and keeps its text
    /// beside the prompt. A placeholder whose text was not kept stays as is.
    private static func expandingPastes(in display: String, from pasted: [String: ClaudePaste]) -> String {
        guard !pasted.isEmpty else { return display }
        let source = display as NSString
        let matches = pastePlaceholder.matches(in: display, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return display }
        let expanded = NSMutableString(string: display)
        for match in matches.reversed() {
            guard
                let paste = pasted[source.substring(with: match.range(at: 1))],
                paste.type == "text",
                let content = paste.content
            else { continue }
            expanded.replaceCharacters(in: match.range, with: content)
        }
        return expanded as String
    }

    // MARK: Prompt lines

    /// The prompts `parse` finds in the complete lines around and after the
    /// binding's offset that contain `needle`, sent from one second before
    /// the binding, oldest first.
    private func prompts(
        in path: String,
        size: Int,
        binding: AgentSessionBinding,
        needle: Data,
        parse: (Data) -> AgentSessionPrompt?
    ) -> [AgentSessionPrompt] {
        let fileSystem = files.fileSystem
        let newline = Data([0x0A])
        var start = max(0, size - Self.promptReadLimit)
        if let offset = binding.promptLogOffset, offset >= 0, offset <= size,
            offset == 0 || fileSystem.read(path, offset - 1, 1) == newline
        {
            start = max(0, offset - Self.promptLookback)
        }
        let end = min(size, start + Self.promptReadLimit)
        // A start mid-file may fall inside a line, whose head is not read.
        var skipsFirstLine = start > 0 && fileSystem.read(path, start - 1, 1) != newline
        let earliest = binding.boundAt.addingTimeInterval(-Self.promptLeeway)
        var prompts: [AgentSessionPrompt] = []
        var pending = Data()
        var position = start
        while position < end {
            guard
                let chunk = fileSystem.read(path, position, min(Self.promptChunkSize, end - position)),
                !chunk.isEmpty
            else { break }
            position += chunk.count
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            var complete = pending[...lastNewline]
            // A line without its newline yet waits for the next chunk.
            pending = Data(pending[(lastNewline + 1)...])
            if skipsFirstLine, let firstNewline = complete.firstIndex(of: 0x0A) {
                complete = complete[(firstNewline + 1)...]
                skipsFirstLine = false
            }
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard line.range(of: needle) != nil, let prompt = parse(line), prompt.sentAt >= earliest else {
                    continue
                }
                prompts.append(prompt)
            }
        }
        return prompts.sorted { $0.sentAt < $1.sentAt }
    }

    // MARK: Decoding

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeISO8601 = Date.ISO8601FormatStyle()

    private static func isoDate(_ text: String) -> Date? {
        (try? fractionalISO8601.parse(text)) ?? (try? wholeISO8601.parse(text))
    }

    /// An omp session line, decoded as far as a user message needs.
    private struct OmpMessageRecord: Decodable {
        var type: String?
        var timestamp: String?
        var message: Message?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
            message = try? container.decodeIfPresent(Message.self, forKey: .message)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case timestamp
            case message
        }

        struct Message: Decodable {
            var role: String?
            /// The message's text: the content string, else its text parts
            /// joined by newlines.
            var text: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try? container.decodeIfPresent(String.self, forKey: .role)
                if let text = try? container.decode(String.self, forKey: .content) {
                    self.text = text
                } else if let parts = try? container.decode([Part].self, forKey: .content) {
                    let texts = parts.compactMap { $0.type == "text" ? $0.text : nil }
                    text = texts.isEmpty ? nil : texts.joined(separator: "\n")
                }
            }

            private enum CodingKeys: String, CodingKey {
                case role
                case content
            }
        }

        struct Part: Decodable {
            var type: String?
            var text: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                text = try? container.decodeIfPresent(String.self, forKey: .text)
            }

            private enum CodingKeys: String, CodingKey {
                case type
                case text
            }
        }
    }

    /// A Claude Code `history.jsonl` line: only the session, time, shown text
    /// and pasted text.
    private struct ClaudeHistoryRecord: Decodable {
        var sessionId: String
        /// Milliseconds since 1970.
        var timestamp: Double
        var display: String
        var pastedContents: [String: ClaudePaste]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            timestamp = try container.decode(Double.self, forKey: .timestamp)
            display = try container.decode(String.self, forKey: .display)
            pastedContents =
                (try? container.decodeIfPresent([String: ClaudePaste].self, forKey: .pastedContents)) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId
            case timestamp
            case display
            case pastedContents
        }
    }

    private struct ClaudePaste: Decodable {
        var type: String?
        var content: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            content = try? container.decodeIfPresent(String.self, forKey: .content)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case content
        }
    }
}
