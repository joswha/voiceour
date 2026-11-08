import Darwin
import Foundation
import Synchronization
import VoiceCore

/// Reads the prompts omp, Claude Code and Codex record in the user's home
/// folder:
///
/// - omp: `~/.omp/agent/sessions/<project>/*.jsonl`, one file per session,
///   titled by its first line. Subagent transcripts in deeper directories are
///   not prompts the user sent and are not read.
/// - Claude Code: `~/.claude/history.jsonl`, with pasted-text placeholders
///   expanded.
/// - Codex: `~/.codex/history.jsonl`, titled by `~/.codex/session_index.jsonl`.
///   Its per-session rollouts are zstd-compressed and macOS has no system
///   zstd, so they are not read.
///
/// Reads are incremental: each file's complete lines are parsed once and a
/// later call reads only the bytes appended since. A replaced or shrunk file
/// is parsed again from the start. Files are read with `pread`, not mapped,
/// so a log another process truncates mid-read ends the read instead of
/// faulting. Missing or unreadable sources contribute nothing.
public final class AgentPromptLogReader: AgentPromptReading {
    private let home: URL
    private let state = Mutex(ReaderState())

    public init(homeDirectory: URL) {
        home = homeDirectory
    }

    public func prompts(sentSince since: Date) -> [AgentPrompt] {
        state.withLock { state in
            var prompts: [AgentPrompt] = []
            readOmp(since: since, state: &state, into: &prompts)
            readClaudeCode(since: since, state: &state, into: &prompts)
            readCodex(since: since, state: &state, into: &prompts)
            return prompts
        }
    }

    // MARK: Sources

    private static let ompNeedles = [Array(#""type":"session""#.utf8), Array(#""role":"user""#.utf8)]
    private static let claudeCodeNeedles = [Array(#""sessionId""#.utf8)]
    private static let codexNeedles = [Array(#""session_id""#.utf8)]

    private func readOmp(since: Date, state: inout ReaderState, into prompts: inout [AgentPrompt]) {
        let root = home.appending(path: ".omp/agent/sessions", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for project in projects {
            let directory = root.appending(path: project, directoryHint: .isDirectory)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                guard
                    let log = Self.refresh(
                        directory.appending(path: name, directoryHint: .notDirectory).path,
                        modifiedSince: since,
                        files: &state.files,
                        needles: Self.ompNeedles,
                        readsFirstLine: true,
                        parse: Self.parseOmpLine
                    )
                else { continue }
                // omp rewrites the title line in place, so it is read on every
                // call rather than cached with the prompts.
                let title = Self.ompTitle(log.firstLine)
                for var prompt in log.file.prompts where prompt.sentAt >= since {
                    prompt.sessionTitle = title
                    prompts.append(prompt)
                }
            }
        }
    }

    private static func parseOmpLine(_ line: Data, into file: inout LogFile) {
        guard let object = object(line) else { return }
        switch object["type"] as? String {
        case "session":
            guard let id = object["id"] as? String else { return }
            file.sessionId = id
            file.workingDirectory = object["cwd"] as? String
        case "message":
            guard
                let sessionId = file.sessionId,
                let message = object["message"] as? [String: Any],
                message["role"] as? String == "user",
                let timestamp = object["timestamp"] as? String,
                let sentAt = isoDate(timestamp),
                let text = ompText(message["content"])
            else { return }
            file.prompts.append(
                AgentPrompt(
                    agent: .omp,
                    sessionId: sessionId,
                    workingDirectory: file.workingDirectory,
                    sessionTitle: nil,
                    sentAt: sentAt,
                    text: text
                )
            )
        default:
            return
        }
    }

    private static func ompText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// The session title from omp's first line, without the leading icon
    /// glyph (a private-use scalar) omp prefixes some titles with.
    private static func ompTitle(_ firstLine: Data?) -> String? {
        guard
            let firstLine,
            let object = object(firstLine),
            object["type"] as? String == "title",
            let raw = object["title"] as? String
        else { return nil }
        let scalars = raw.unicodeScalars.drop { scalar in
            scalar.properties.isWhitespace
                || (0xE000...0xF8FF).contains(scalar.value)
                || (0xF0000...0x10FFFF).contains(scalar.value)
        }
        let title = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func readClaudeCode(since: Date, state: inout ReaderState, into prompts: inout [AgentPrompt]) {
        guard
            let log = Self.refresh(
                home.appending(path: ".claude/history.jsonl", directoryHint: .notDirectory).path,
                modifiedSince: since,
                files: &state.files,
                needles: Self.claudeCodeNeedles,
                parse: Self.parseClaudeCodeLine
            )
        else { return }
        prompts.append(contentsOf: log.file.prompts.lazy.filter { $0.sentAt >= since })
    }

    private static func parseClaudeCodeLine(_ line: Data, into file: inout LogFile) {
        guard
            let object = object(line),
            let sessionId = object["sessionId"] as? String,
            let milliseconds = (object["timestamp"] as? NSNumber)?.doubleValue,
            let display = object["display"] as? String
        else { return }
        file.prompts.append(
            AgentPrompt(
                agent: .claudeCode,
                sessionId: sessionId,
                workingDirectory: object["project"] as? String,
                sessionTitle: nil,
                sentAt: Date(timeIntervalSince1970: milliseconds / 1_000),
                text: expandingPastes(in: display, from: object["pastedContents"] as? [String: Any])
            )
        )
    }

    private static let pastePlaceholder = try! NSRegularExpression(
        pattern: #"\[Pasted text #(\d+)(?: \+\d+ lines)?\]"#
    )

    /// Claude Code shows a long paste as a placeholder and keeps its text
    /// beside the prompt. A placeholder whose text was not kept stays as is.
    private static func expandingPastes(in display: String, from pasted: [String: Any]?) -> String {
        guard let pasted, !pasted.isEmpty else { return display }
        let source = display as NSString
        let matches = pastePlaceholder.matches(in: display, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return display }
        let expanded = NSMutableString(string: display)
        for match in matches.reversed() {
            guard
                let paste = pasted[source.substring(with: match.range(at: 1))] as? [String: Any],
                paste["type"] as? String == "text",
                let content = paste["content"] as? String
            else { continue }
            expanded.replaceCharacters(in: match.range, with: content)
        }
        return expanded as String
    }

    private func readCodex(since: Date, state: inout ReaderState, into prompts: inout [AgentPrompt]) {
        let codex = home.appending(path: ".codex", directoryHint: .isDirectory)
        Self.refreshCodexTitles(
            codex.appending(path: "session_index.jsonl", directoryHint: .notDirectory),
            state: &state
        )
        guard
            let log = Self.refresh(
                codex.appending(path: "history.jsonl", directoryHint: .notDirectory).path,
                modifiedSince: since,
                files: &state.files,
                needles: Self.codexNeedles,
                parse: Self.parseCodexLine
            )
        else { return }
        for var prompt in log.file.prompts where prompt.sentAt >= since {
            prompt.sessionTitle = state.codexTitles[prompt.sessionId]
            prompts.append(prompt)
        }
    }

    private static func parseCodexLine(_ line: Data, into file: inout LogFile) {
        guard
            let object = object(line),
            let sessionId = object["session_id"] as? String,
            let seconds = (object["ts"] as? NSNumber)?.doubleValue,
            let text = object["text"] as? String
        else { return }
        file.prompts.append(
            AgentPrompt(
                agent: .codex,
                sessionId: sessionId,
                workingDirectory: nil,
                sessionTitle: nil,
                sentAt: Date(timeIntervalSince1970: seconds),
                text: text
            )
        )
    }

    /// Re-reads Codex's session index whenever it changes; the last name an
    /// id was given wins.
    private static func refreshCodexTitles(_ url: URL, state: inout ReaderState) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified != state.codexIndexModified else { return }
        state.codexIndexModified = modified
        state.codexTitles = [:]
        guard modified != nil, let data = try? Data(contentsOf: url) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = object(Data(line)),
                let id = object["id"] as? String,
                let name = object["thread_name"] as? String,
                !name.isEmpty
            else { continue }
            state.codexTitles[id] = name
        }
    }

    // MARK: Incremental reads

    private struct LogFile {
        var fileNumber: UInt64
        var consumedBytes = 0
        var sessionId: String?
        var workingDirectory: String?
        var prompts: [AgentPrompt] = []
    }

    private struct ReaderState {
        var files: [String: LogFile] = [:]
        var codexTitles: [String: String] = [:]
        var codexIndexModified: Date?
    }

    private static let chunkSize = 1 << 20
    private static let firstLineLimit = 4_096

    /// Parses the complete lines appended to `path` since the last call,
    /// handing each line that contains one of `needles` to `parse`. Nil when
    /// the file is missing, not a regular file, or last modified before
    /// `since`: such a file cannot hold a prompt sent since.
    private static func refresh(
        _ path: String,
        modifiedSince since: Date,
        files: inout [String: LogFile],
        needles: [[UInt8]],
        readsFirstLine: Bool = false,
        parse: (Data, inout LogFile) -> Void
    ) -> (file: LogFile, firstLine: Data?)? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified =
            TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        guard Date(timeIntervalSince1970: modified) >= since else { return nil }

        let fileNumber = UInt64(info.st_ino)
        let size = Int(info.st_size)
        var file = files[path] ?? LogFile(fileNumber: fileNumber)
        if file.fileNumber != fileNumber || size < file.consumedBytes {
            file = LogFile(fileNumber: fileNumber)
        }
        let consumed = readLines(descriptor, from: file.consumedBytes, to: size, needles: needles) { line in
            parse(line, &file)
        }
        file.consumedBytes = consumed
        files[path] = file
        return (file, readsFirstLine ? firstLine(descriptor) : nil)
    }

    /// Hands every complete line in `start..<end` containing one of `needles`
    /// to `line`, and returns the offset just past the last newline read.
    ///
    /// One buffer per call: a partial line moves to its front before the next
    /// read, and a line longer than the buffer doubles it.
    private static func readLines(
        _ descriptor: Int32,
        from start: Int,
        to end: Int,
        needles: [[UInt8]],
        line: (Data) -> Void
    ) -> Int {
        guard start < end else { return start }
        var consumed = start
        var position = start
        var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: min(chunkSize, end - start), alignment: 1)
        defer { buffer.deallocate() }
        // Bytes of a partial line at the front of `buffer`; they hold no newline.
        var carried = 0
        while position < end {
            if carried == buffer.count {
                let grown = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.count * 2, alignment: 1)
                grown.copyMemory(from: UnsafeRawBufferPointer(buffer))
                buffer.deallocate()
                buffer = grown
            }
            let base = buffer.baseAddress!
            let read = pread(descriptor, base + carried, min(buffer.count - carried, end - position), off_t(position))
            guard read > 0 else { break }
            position += read
            let filled = carried + read

            var lineStart = 0
            var searchFrom = carried
            while searchFrom < filled, let newline = memchr(base + searchFrom, 0x0A, filled - searchFrom) {
                let lineEnd = base.distance(to: newline)
                let bytes = UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart)
                if contains(bytes, anyOf: needles) {
                    line(Data(bytes))
                }
                lineStart = lineEnd + 1
                searchFrom = lineStart
            }
            consumed += lineStart
            carried = filled - lineStart
            if lineStart > 0, carried > 0 {
                memmove(base, base + lineStart, carried)
            }
        }
        return consumed
    }

    private static func contains(_ bytes: UnsafeRawBufferPointer, anyOf needles: [[UInt8]]) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return needles.contains { needle in
            needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, $0.count) != nil }
        }
    }

    private static func firstLine(_ descriptor: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: firstLineLimit)
        let read = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard read > 0, let newline = bytes[..<read].firstIndex(of: 0x0A) else { return nil }
        return Data(bytes[..<newline])
    }

    // MARK: Decoding

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeISO8601 = Date.ISO8601FormatStyle()

    private static func isoDate(_ text: String) -> Date? {
        (try? fractionalISO8601.parse(text)) ?? (try? wholeISO8601.parse(text))
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
