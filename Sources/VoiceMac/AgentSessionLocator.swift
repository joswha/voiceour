import Darwin
import Foundation
import VoiceCore

/// File access for agent session records. Every read is bounded; tests
/// inject their own to observe which paths are read.
struct AgentSessionFileSystem: Sendable {
    /// Up to `limit` bytes of the regular file at `path`, starting at
    /// `offset`; nil when it cannot be opened as a regular file.
    var read: @Sendable (_ path: String, _ offset: Int, _ limit: Int) -> Data?
    /// The size of the regular file at `path`; nil when there is none.
    var fileSize: @Sendable (_ path: String) -> Int?
    var modificationDate: @Sendable (_ path: String) -> Date?
    var contentsOfDirectory: @Sendable (_ path: String) -> [String]?
    /// `path` with every symbolic link resolved; nil when it does not exist.
    var realPath: @Sendable (_ path: String) -> String?

    static let live = AgentSessionFileSystem(
        read: { path, offset, limit in
            guard offset >= 0, limit >= 0 else { return nil }
            // Non-blocking so a FIFO planted at the path cannot stall the open.
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            var data = Data(count: limit)
            var filled = 0
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                while filled < limit {
                    let count = pread(descriptor, buffer.baseAddress! + filled, limit - filled, off_t(offset + filled))
                    if count < 0 { return false }
                    if count == 0 { break }
                    filled += count
                }
                return true
            }
            guard ok else { return nil }
            data.count = filled
            return data
        },
        fileSize: { path in
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Int(info.st_size)
        },
        modificationDate: { path in
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        },
        contentsOfDirectory: { path in
            try? FileManager.default.contentsOfDirectory(atPath: path)
        },
        realPath: { path in
            guard let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    )
}

/// The agents' own session records under the home folder, and the rule that
/// keeps every read inside them: a file is opened only when its canonical path
/// lies under `<home>/.omp/agent` or `<home>/.claude`, both canonical too.
struct AgentSessionFiles: Sendable {
    enum Root {
        case omp
        case claude
    }

    /// Where a path resolves relative to an allowed root.
    enum Location: Equatable {
        /// Inside the root, at this canonical path.
        case inside(String)
        /// Present, but resolving outside the root.
        case outside
        case missing
    }

    static let headLimit = 64 * 1_024
    static let tailLimit = 256 * 1_024

    let home: URL
    let fileSystem: AgentSessionFileSystem

    func path(_ root: Root, _ components: String...) -> String {
        var url =
            switch root {
            case .omp: home.appending(path: ".omp/agent", directoryHint: .isDirectory)
            case .claude: home.appending(path: ".claude", directoryHint: .isDirectory)
            }
        for component in components {
            url.append(path: component)
        }
        return url.path
    }

    func location(of path: String, under root: Root) -> Location {
        guard let canonical = fileSystem.realPath(path) else { return .missing }
        guard let rootPath = fileSystem.realPath(self.path(root)), canonical.hasPrefix(rootPath + "/") else {
            return .outside
        }
        return .inside(canonical)
    }

    /// A form of `path` that two spellings of the same file share: canonical
    /// when the file exists, else its canonical folder plus its name, else
    /// the path standardized.
    func comparablePath(_ path: String) -> String {
        if let canonical = fileSystem.realPath(path) { return canonical }
        let url = URL(fileURLWithPath: path).standardized
        if let folder = fileSystem.realPath(url.deletingLastPathComponent().path) {
            return folder + "/" + url.lastPathComponent
        }
        return url.path
    }

    func head(_ canonicalPath: String) -> Data? {
        fileSystem.read(canonicalPath, 0, Self.headLimit)
    }

    // MARK: omp

    /// Title and working directory from the head of an omp session file:
    /// an optional `{"type":"title"}` line, then `{"type":"session"}`.
    func ompHead(_ canonicalPath: String) -> (title: String?, workingDirectory: String?) {
        guard let head = head(canonicalPath) else { return (nil, nil) }
        var title: String?
        var workingDirectory: String?
        for line in Self.completeLines(head).prefix(2) {
            guard let record = try? JSONDecoder().decode(OmpHeadRecord.self, from: line) else { continue }
            switch record.type ?? "" {
            case "title": title = record.title.flatMap(Self.ompTitle)
            case "session": workingDirectory = record.cwd.flatMap(Self.nonBlank)
            default: continue
            }
        }
        return (title, workingDirectory)
    }

    /// The canonical path of omp session `id` in any project folder directly
    /// under `sessions`; subagent transcripts lie deeper and never match.
    func ompSessionFile(id: String) -> String? {
        let sessions = path(.omp, "sessions")
        guard let projects = fileSystem.contentsOfDirectory(sessions) else { return nil }
        let suffix = "_\(id).jsonl"
        for project in projects.sorted() {
            let folder = sessions + "/" + project
            guard let names = fileSystem.contentsOfDirectory(folder) else { continue }
            for name in names.sorted() where name.hasSuffix(suffix) {
                if case .inside(let canonical) = location(of: folder + "/" + name, under: .omp),
                    fileSystem.fileSize(canonical) != nil
                {
                    return canonical
                }
            }
        }
        return nil
    }

    /// The session id an omp session file name carries: the UUID after the
    /// timestamp's `Z_`.
    static func ompSessionId(fileName: String) -> String? {
        guard fileName.hasSuffix(".jsonl"), let marker = fileName.range(of: "Z_", options: .backwards) else {
            return nil
        }
        let id = String(fileName[marker.upperBound...].dropLast(".jsonl".count))
        return isSessionId(id) ? id : nil
    }

    /// The title without the leading icon glyph (a private-use scalar) omp
    /// prefixes some titles with; nil when nothing is left.
    static func ompTitle(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.drop { scalar in
            scalar.properties.isWhitespace
                || (0xE000...0xF8FF).contains(scalar.value)
                || (0xF0000...0x10FFFF).contains(scalar.value)
        }
        return nonBlank(String(String.UnicodeScalarView(scalars)))
    }

    // MARK: Claude Code

    /// The canonical path of Claude Code transcript `sessionId`, directly in
    /// one of the `projects` folders.
    func claudeTranscript(sessionId: String) -> String? {
        let projects = path(.claude, "projects")
        guard let folders = fileSystem.contentsOfDirectory(projects) else { return nil }
        for folder in folders.sorted() {
            if case .inside(let canonical) = location(
                of: projects + "/" + folder + "/" + sessionId + ".jsonl",
                under: .claude
            ), fileSystem.fileSize(canonical) != nil {
                return canonical
            }
        }
        return nil
    }

    /// The last `custom-title` or `ai-title` record in the transcript's tail.
    func claudeTranscriptTitle(_ canonicalPath: String) -> String? {
        guard let size = fileSystem.fileSize(canonicalPath) else { return nil }
        let start = max(0, size - Self.tailLimit)
        guard let tail = fileSystem.read(canonicalPath, start, size - start) else { return nil }
        var lines = Self.completeLines(tail + Data([0x0A]))
        // A tail that starts mid-file starts mid-line.
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        for line in lines.reversed() {
            guard
                line.range(of: Data(#""custom-title""#.utf8)) != nil
                    || line.range(of: Data(#""ai-title""#.utf8)) != nil,
                let record = try? JSONDecoder().decode(ClaudeTitleRecord.self, from: line)
            else { continue }
            let title =
                switch record.type ?? "" {
                case "custom-title": record.customTitle
                case "ai-title": record.aiTitle
                default: String?.none
                }
            if let title = title.flatMap(Self.nonBlank) {
                return title
            }
        }
        return nil
    }

    /// The name Claude Code gave session `sessionId` in a live
    /// `sessions/<pid>.json` record, unless it derived the name itself.
    func claudeRegistryName(sessionId: String) -> String? {
        guard
            case .inside(let folder) = location(of: path(.claude, "sessions"), under: .claude),
            let names = fileSystem.contentsOfDirectory(folder)
        else { return nil }
        for name in names.sorted() where Self.isClaudeRecordName(name) {
            guard
                case .inside(let canonical) = location(of: path(.claude, "sessions", name), under: .claude),
                let data = head(canonical),
                let record = try? JSONDecoder().decode(ClaudeNameRecord.self, from: data),
                record.sessionId == sessionId,
                record.nameSource != "derived",
                let title = record.name.flatMap(Self.nonBlank)
            else { continue }
            return title
        }
        return nil
    }

    /// Only `<digits>.json` records are read from Claude Code's `sessions`;
    /// the key files beside them are never opened.
    static func isClaudeRecordName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let digits = name.dropLast(".json".count)
        return !digits.isEmpty && digits.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    // MARK: Shared

    /// The newline-terminated lines of `data`; a final line without its
    /// newline is still being written and is left out.
    static func completeLines(_ data: Data) -> [Data] {
        guard let last = data.lastIndex(of: 0x0A) else { return [] }
        return data[..<last].split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    static func isSessionId(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text) != nil
    }

    static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct OmpHeadRecord: Decodable {
        var type: String?
        var title: String?
        var cwd: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case title
            case cwd
        }
    }

    private struct ClaudeTitleRecord: Decodable {
        var type: String?
        var customTitle: String?
        var aiTitle: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            customTitle = try? container.decodeIfPresent(String.self, forKey: .customTitle)
            aiTitle = try? container.decodeIfPresent(String.self, forKey: .aiTitle)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case customTitle
            case aiTitle
        }
    }

    /// A `sessions/<pid>.json` record, decoded only as far as its name.
    private struct ClaudeNameRecord: Decodable {
        var sessionId: String?
        var name: String?
        var nameSource: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            nameSource = try? container.decodeIfPresent(String.self, forKey: .nameSource)
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId
            case name
            case nameSource
        }
    }
}

/// Maps the foreground process of a pane to the agent session it runs, from
/// the agent's own records. Exact or nothing: every source that names a
/// session must name the same one.
///
/// - omp: Tern's `omp_session_file` for the pane and the session file the
///   process holds open, directly in a `sessions` project folder. Only when
///   both are absent, the terminal breadcrumb
///   `terminal-sessions/<tty>`, written no earlier than the process started,
///   on a terminal no other omp shares.
/// - Claude Code: `sessions/<pid>.json`, checked against the kernel's start
///   time, following a parked session to its background job.
struct AgentSessionLocator: Sendable {
    let files: AgentSessionFiles
    let processFacts: @Sendable (Int32) -> ProcessFacts?
    let openFilePaths: @Sendable (Int32) -> [String]
    let pidsOnTerminal: @Sendable (_ device: UInt32, _ uid: UInt32) -> [Int32]
    /// The zone Claude Code's `procStart` is written in. Live, it is
    /// `.autoupdatingCurrent`, and each parse builds its own formatter, so a
    /// zone change after launch is followed.
    let timeZone: TimeZone

    /// The session `foreground` runs. Codex is named as such; any other
    /// program that is no agent is `.noAgent`. Once the agent is known, every
    /// way its records fail to name one session is `.sessionUnconfirmed`, so
    /// the miss never depends on which record was missing or disagreed.
    func locate(foreground: ProcessFacts, ternSessionFile: String?) -> Result<ResolvedAgentSession, AgentLinkMiss> {
        let session: ResolvedAgentSession?
        switch Self.agent(of: foreground) {
        case .omp: session = ompSession(of: foreground, ternSessionFile: ternSessionFile)
        case .claudeCode: session = claudeSession(of: foreground)
        case nil: return .failure(Self.isCodex(foreground) ? .codex : .noAgent)
        }
        guard let session else { return .failure(.sessionUnconfirmed) }
        return .success(session)
    }

    /// The agent a process is, by its executable path and name only.
    static func agent(of process: ProcessFacts) -> CodingAgent? {
        let path = process.executablePath ?? ""
        if path.contains("/omp/versions/") || process.name == "omp" {
            return .omp
        }
        if process.name == "claude" || path.contains("/claude/versions/") || path.hasSuffix("/claude") {
            return .claudeCode
        }
        return nil
    }

    /// Whether a process is Codex, by the same evidence as `agent(of:)`: its
    /// name or its executable's file name is `codex`, or the platform-suffixed
    /// native build (`codex-aarch64-apple-darwin`) Homebrew and npm install.
    static func isCodex(_ process: ProcessFacts) -> Bool {
        let file = process.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        return [process.name, file].contains { name in
            guard let name else { return false }
            return name == "codex" || name.hasPrefix("codex-aarch64-") || name.hasPrefix("codex-x86_64-")
        }
    }

    // MARK: omp

    private func ompSession(of process: ProcessFacts, ternSessionFile: String?) -> ResolvedAgentSession? {
        var candidates: [String] = []
        if let ternSessionFile, !ternSessionFile.isEmpty {
            guard ternSessionFile.hasPrefix("/") else { return nil }
            candidates.append(ternSessionFile)
        }
        let openSessionFiles = openFilePaths(process.pid).filter(isTopLevelOmpSessionFile)
        guard Set(openSessionFiles.map(files.comparablePath)).count <= 1 else { return nil }
        candidates += openSessionFiles.prefix(1)

        let breadcrumb = breadcrumb(of: process)
        if candidates.isEmpty {
            guard let breadcrumb, acceptsBreadcrumb(breadcrumb, of: process) else { return nil }
            candidates.append(breadcrumb.sessionFile)
        }
        let comparable = Set(candidates.map(files.comparablePath))
        guard comparable.count == 1, let agreed = comparable.first, let sessionFile = candidates.first else {
            return nil
        }
        let standardized = URL(fileURLWithPath: sessionFile).standardized
        guard let sessionId = AgentSessionFiles.ompSessionId(fileName: standardized.lastPathComponent) else {
            return nil
        }
        let breadcrumbDirectory =
            breadcrumb.flatMap { files.comparablePath($0.sessionFile) == agreed ? $0.workingDirectory : nil }

        var resolved = ResolvedAgentSession(
            agent: .omp,
            sessionId: sessionId,
            sessionFile: standardized.path,
            workingDirectory: breadcrumbDirectory,
            sessionTitle: nil,
            promptLogOffset: 0,
            resumable: false
        )
        switch files.location(of: sessionFile, under: .omp) {
        case .inside(let canonical):
            let size = files.fileSystem.fileSize(canonical)
            let head = files.ompHead(canonical)
            resolved.sessionTitle = head.title
            resolved.workingDirectory = head.workingDirectory ?? breadcrumbDirectory
            resolved.promptLogOffset = size ?? 0
            resolved.resumable = size != nil
        case .outside:
            // Bound by the id its name carries; nothing is read from it.
            resolved.promptLogOffset = nil
        case .missing:
            // Not written yet: everything it records comes after the paste.
            break
        }
        return resolved
    }

    /// Whether `path` is a main session file: `<ISO>Z_<uuid>.jsonl` directly
    /// in a project folder under `sessions`. Subagent transcripts lie one
    /// level deeper.
    private func isTopLevelOmpSessionFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardized
        let name = url.lastPathComponent
        let sessions = url.deletingLastPathComponent().deletingLastPathComponent().path
        let root = files.path(.omp, "sessions")
        guard
            sessions == root || sessions == files.fileSystem.realPath(root),
            let marker = name.range(of: "Z_", options: .backwards),
            AgentSessionFiles.ompSessionId(fileName: name) != nil
        else { return false }
        return Self.isFileTimestamp(name[..<marker.lowerBound])
    }

    /// omp's file-name timestamp before `Z`: `2026-11-09T17-22-03-003`.
    private static func isFileTimestamp(_ text: Substring) -> Bool {
        let template = Array("0000-00-00T00-00-00-000".utf8)
        let bytes = Array(text.utf8)
        guard bytes.count == template.count else { return false }
        return zip(bytes, template).allSatisfy { byte, expected in
            expected == UInt8(ascii: "0") ? (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) : byte == expected
        }
    }

    private struct Breadcrumb {
        var workingDirectory: String?
        var sessionFile: String
        var modified: Date
    }

    /// omp's record of the session its terminal last showed:
    /// `terminal-sessions/<tty>`, line 1 the working directory, line 2 the
    /// session file.
    private func breadcrumb(of process: ProcessFacts) -> Breadcrumb? {
        guard let tty = process.terminalName, !tty.hasPrefix(".") else { return nil }
        let key = tty.replacingOccurrences(of: "/", with: "-")
        guard
            case .inside(let canonical) = files.location(of: files.path(.omp, "terminal-sessions", key), under: .omp),
            let modified = files.fileSystem.modificationDate(canonical),
            let head = files.head(canonical)
        else { return nil }
        let lines = String(decoding: head, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[1].hasPrefix("/") else { return nil }
        return Breadcrumb(
            workingDirectory: AgentSessionFiles.nonBlank(String(lines[0])),
            sessionFile: String(lines[1]),
            modified: modified
        )
    }

    /// A breadcrumb names this process's session only when written since the
    /// process started, and only when no other omp shares the terminal: the
    /// last writer wins it.
    private func acceptsBreadcrumb(_ breadcrumb: Breadcrumb, of process: ProcessFacts) -> Bool {
        guard breadcrumb.modified >= process.startTime, let device = process.terminalDevice else { return false }
        return !pidsOnTerminal(device, process.uid).contains { pid in
            pid != process.pid && processFacts(pid).flatMap(Self.agent) == .omp
        }
    }

    // MARK: Claude Code

    private func claudeSession(of process: ProcessFacts) -> ResolvedAgentSession? {
        guard
            let record = claudeRecord(named: "\(process.pid).json"),
            record.pid == process.pid,
            startTimeMatches(record.procStart, process.startTime)
        else { return nil }
        var effective = record
        if let parkedJobId = record.parkedJobId.flatMap(AgentSessionFiles.nonBlank) {
            guard let job = parkedJob(parkedJobId, uid: process.uid) else { return nil }
            effective = job
        }
        guard let sessionId = effective.sessionId, AgentSessionFiles.isSessionId(sessionId) else { return nil }

        let transcript = files.claudeTranscript(sessionId: sessionId)
        let registryName =
            effective.nameSource == "derived" ? nil : effective.name.flatMap(AgentSessionFiles.nonBlank)
        var historySize = 0
        if case .inside(let history) = files.location(of: files.path(.claude, "history.jsonl"), under: .claude) {
            historySize = files.fileSystem.fileSize(history) ?? 0
        }
        return ResolvedAgentSession(
            agent: .claudeCode,
            sessionId: sessionId,
            sessionFile: transcript,
            workingDirectory: effective.cwd.flatMap(AgentSessionFiles.nonBlank),
            sessionTitle: registryName ?? transcript.flatMap(files.claudeTranscriptTitle),
            promptLogOffset: historySize,
            resumable: transcript != nil
        )
    }

    /// The one live background job a parked session handed its pane to.
    private func parkedJob(_ jobId: String, uid: UInt32) -> ClaudeSessionRecord? {
        guard
            case .inside(let folder) = files.location(of: files.path(.claude, "sessions"), under: .claude),
            let names = files.fileSystem.contentsOfDirectory(folder)
        else { return nil }
        let recordNames = names.filter(AgentSessionFiles.isClaudeRecordName)
        let jobs = recordNames.compactMap { name -> (String, ClaudeSessionRecord)? in
            guard let record = claudeRecord(named: name), record.jobId == jobId else { return nil }
            return (name, record)
        }
        guard
            jobs.count == 1,
            case (let name, let job)? = jobs.first,
            job.kind == "bg",
            job.spare != true,
            let pid = job.pid,
            name == "\(pid).json",
            let facts = processFacts(pid),
            facts.pid == pid,
            facts.uid == uid,
            startTimeMatches(job.procStart, facts.startTime)
        else { return nil }
        return job
    }

    private func claudeRecord(named name: String) -> ClaudeSessionRecord? {
        guard
            AgentSessionFiles.isClaudeRecordName(name),
            case .inside(let canonical) = files.location(of: files.path(.claude, "sessions", name), under: .claude),
            let data = files.head(canonical)
        else { return nil }
        return try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
    }

    /// Whether Claude Code's `procStart` (`ps`'s `lstart`, local time, whole
    /// seconds) names the kernel's start time within a second.
    private func startTimeMatches(_ procStart: String?, _ startTime: Date) -> Bool {
        guard let procStart, let recorded = Self.processStart(procStart, timeZone: timeZone) else { return false }
        return abs(recorded.timeIntervalSince(startTime)) <= 1
    }

    static func processStart(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // `lstart` pads a one-digit day with a second space.
        return formatter.date(from: text.split(separator: " ").joined(separator: " "))
    }

    /// The fields of a Claude Code `sessions/<pid>.json` record binding uses.
    private struct ClaudeSessionRecord: Decodable {
        var pid: Int32?
        var sessionId: String?
        var cwd: String?
        var procStart: String?
        var kind: String?
        var spare: Bool?
        var jobId: String?
        var parkedJobId: String?
        var name: String?
        var nameSource: String?
    }
}
