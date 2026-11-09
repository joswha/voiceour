import Foundation
import Synchronization
import Testing

@testable import VoiceCore
@testable import VoiceMac

// MARK: Shared agent-session fixtures

/// A temporary home folder holding fake omp and Claude Code records. Tests
/// never read the real `~/.omp` or `~/.claude`.
struct FakeAgentHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentSessionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The path of `relative` under the home, spelled as the agents spell it.
    func path(_ relative: String) -> String {
        url.appending(path: relative).path
    }

    /// The same file with every symbolic link resolved, as the kernel names
    /// an open file.
    func canonicalPath(_ relative: String) -> String {
        let spelled = path(relative)
        let live = AgentSessionFileSystem.live
        if let canonical = live.realPath(spelled) { return canonical }
        let file = URL(fileURLWithPath: spelled)
        guard let folder = live.realPath(file.deletingLastPathComponent().path) else { return spelled }
        return folder + "/" + file.lastPathComponent
    }

    @discardableResult
    func write(_ relative: String, lines: [String]) throws -> String {
        try write(relative, text: lines.map { $0 + "\n" }.joined())
    }

    @discardableResult
    func write(_ relative: String, text: String) throws -> String {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
        return file.path
    }

    func append(_ relative: String, text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appending(path: relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func setModified(_ relative: String, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }

    func size(_ relative: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path(relative))[.size] as? Int)
    }
}

/// Records every path the agent-session code reads bytes from.
final class AgentFileReadLog: Sendable {
    private let paths = Mutex<[String]>([])

    var readPaths: [String] {
        paths.withLock { $0 }
    }

    var fileSystem: AgentSessionFileSystem {
        var fileSystem = AgentSessionFileSystem.live
        let read = fileSystem.read
        fileSystem.read = { [self] path, offset, limit in
            paths.withLock { $0.append(path) }
            return read(path, offset, limit)
        }
        return fileSystem
    }
}

enum AgentFixtures {
    static let uid: UInt32 = 501
    static let terminal: UInt32 = 0x1000_0006
    static let ompExecutable = "/Users/v/Library/Application Support/Tern/omp/versions/18.18.3"
    static let claudeExecutable = "/Users/v/.local/share/claude/versions/2.1.319"

    /// The live case: a fresh session omp named before writing it, and the
    /// next session in the same pane.
    static let freshSessionId = "01a1c16e-5f2b-7c41-8d3a-2b9e4f6a7c10"
    static let freshSessionFile =
        ".omp/agent/sessions/-Users-vlad-Desktop-voiceoour/2026-11-09T17-50-35-019Z_\(freshSessionId).jsonl"
    static let nextSessionId = "01a1c16f-0a3c-7d52-9e4b-3c0f5a7b8d21"
    static let nextSessionFile =
        ".omp/agent/sessions/-Users-vlad-Desktop-voiceoour/2026-11-09T17-51-31-004Z_\(nextSessionId).jsonl"

    static let claudeSessionId = "391aefbb-e3e8-4906-9860-e6cd3b884abb"
    static let claudeJobSessionId = "b453f5e2-1c7d-4e8f-9a0b-2d3c4e5f6a7b"

    static let started = Date(timeIntervalSince1970: 1_794_246_224)

    static func process(
        pid: Int32,
        name: String,
        executablePath: String?,
        uid: UInt32 = uid,
        terminal: UInt32? = terminal,
        group: Int32? = nil,
        foregroundGroup: Int32? = nil,
        started: Date = started
    ) -> ProcessFacts {
        ProcessFacts(
            pid: pid,
            uid: uid,
            processGroup: group ?? pid,
            terminalForegroundGroup: foregroundGroup ?? group ?? pid,
            terminalDevice: terminal,
            terminalName: terminal.map { _ in "ttys006" },
            startTime: started,
            executablePath: executablePath,
            name: name
        )
    }

    static func omp(pid: Int32 = 200, started: Date = started) -> ProcessFacts {
        process(pid: pid, name: "18.18.3", executablePath: ompExecutable, started: started)
    }

    static func claude(pid: Int32 = 61208, started: Date = started) -> ProcessFacts {
        process(pid: pid, name: "claude", executablePath: claudeExecutable, started: started)
    }

    static func shell(pid: Int32 = 100, terminal: UInt32? = terminal) -> ProcessFacts {
        process(pid: pid, name: "zsh", executablePath: "/bin/zsh", terminal: terminal, foregroundGroup: 200)
    }

    static func ompHead(id: String, title: String = "", cwd: String = "/Users/vlad/Desktop/voiceoour") -> [String] {
        [
            #"{"type":"title","v":1,"title":"\#(title)","source":"auto","pad":"                "}"#,
            #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-11-09T17:51:31.004Z","cwd":"\#(cwd)"}"#,
        ]
    }

    static func ompUser(_ text: String, at timestamp: String) -> String {
        #"{"type":"message","id":"m","timestamp":"\#(timestamp)","message":{"role":"user","content":"\#(text)"}}"#
    }

    /// Claude Code's `procStart`: `ps`'s `lstart`, here in UTC.
    static func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    static func claudeRecord(
        pid: Int32,
        sessionId: String,
        started: Date = started,
        kind: String = "interactive",
        extra: String = ""
    ) -> String {
        #"{"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"/Users/v/project","startedAt":1794246224000,"#
            + #""procStart":"\#(procStart(started))","kind":"\#(kind)","status":"idle"\#(extra)}"#
    }
}

@Suite("AgentSessionLocator")
struct AgentSessionLocatorTests {
    private func locator(
        _ home: FakeAgentHome,
        processes: [ProcessFacts] = [],
        openFiles: [String] = [],
        terminalPids: [Int32] = [],
        fileSystem: AgentSessionFileSystem = .live
    ) -> AgentSessionLocator {
        let facts = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return AgentSessionLocator(
            files: AgentSessionFiles(home: home.url, fileSystem: fileSystem),
            processFacts: { facts[$0] },
            openFilePaths: { _ in openFiles },
            pidsOnTerminal: { device, uid in
                device == AgentFixtures.terminal && uid == AgentFixtures.uid ? terminalPids : []
            },
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    // MARK: omp

    @Test func ternVariableAndOpenFileThatAgreeBindTheSession() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(
            file,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "\u{F0339} BIND: Voice")
                + [AgentFixtures.ompUser("testing", at: "2026-11-09T17:51:29.712Z")]
        )
        let subagent = file.replacingOccurrences(of: ".jsonl", with: "/binding-research-1.jsonl")
        try home.write(subagent, lines: [AgentFixtures.ompUser("task", at: "2026-11-09T17:51:30.000Z")])

        let size = try home.size(file)
        let resolved = locator(
            home,
            openFiles: [
                home.canonicalPath(".omp/run/session-owners/\(AgentFixtures.nextSessionId).lock"),
                home.canonicalPath(file),
                home.canonicalPath(subagent),
            ]
        ).locate(foreground: AgentFixtures.omp(), ternSessionFile: home.path(file))

        #expect(
            resolved
                == ResolvedAgentSession(
                    agent: .omp,
                    sessionId: AgentFixtures.nextSessionId,
                    sessionFile: home.path(file),
                    workingDirectory: "/Users/vlad/Desktop/voiceoour",
                    sessionTitle: "BIND: Voice",
                    promptLogOffset: size,
                    resumable: true
                )
        )
    }

    /// The live case: omp names a fresh session to Tern before writing it, so
    /// the Tern variable is the only source.
    @Test func aFreshSessionNamedOnlyByTernBindsUnresumableFromOffsetZero() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try home.write(
            ".omp/agent/terminal-sessions/ttys006",
            lines: ["/Users/vlad/Desktop/voiceoour", home.path(AgentFixtures.freshSessionFile), "fresh"]
        )

        let resolved = locator(home)
            .locate(foreground: AgentFixtures.omp(), ternSessionFile: home.path(AgentFixtures.freshSessionFile))

        #expect(
            resolved
                == ResolvedAgentSession(
                    agent: .omp,
                    sessionId: AgentFixtures.freshSessionId,
                    sessionFile: home.path(AgentFixtures.freshSessionFile),
                    workingDirectory: "/Users/vlad/Desktop/voiceoour",
                    sessionTitle: nil,
                    promptLogOffset: 0,
                    resumable: false
                )
        )
    }

    @Test func theOpenSessionFileAloneBindsTheSession() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let file = AgentFixtures.nextSessionFile
        try home.write(file, lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "Next"))

        let resolved = try #require(
            locator(home, openFiles: [home.canonicalPath(file)])
                .locate(foreground: AgentFixtures.omp(), ternSessionFile: nil)
        )

        #expect(resolved.sessionId == AgentFixtures.nextSessionId)
        #expect(resolved.sessionTitle == "Next")
        #expect(resolved.resumable)
    }

    @Test func sourcesThatDisagreeBindNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try home.write(AgentFixtures.nextSessionFile, lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId))

        let resolved = locator(home, openFiles: [home.canonicalPath(AgentFixtures.nextSessionFile)])
            .locate(foreground: AgentFixtures.omp(), ternSessionFile: home.path(AgentFixtures.freshSessionFile))

        #expect(resolved == nil)
    }

    @Test func aSubagentTranscriptIsNeverTheSession() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let subagent = AgentFixtures.nextSessionFile.replacingOccurrences(
            of: ".jsonl",
            with: "/2026-11-09T17-52-00-000Z_\(AgentFixtures.freshSessionId).jsonl"
        )
        try home.write(subagent, lines: AgentFixtures.ompHead(id: AgentFixtures.freshSessionId))
        let openFiles = [home.canonicalPath(subagent)]

        let withTern = locator(home, openFiles: openFiles)
            .locate(foreground: AgentFixtures.omp(), ternSessionFile: home.path(AgentFixtures.nextSessionFile))
        let alone = locator(home, openFiles: openFiles)
            .locate(foreground: AgentFixtures.omp(), ternSessionFile: nil)

        #expect(withTern?.sessionId == AgentFixtures.nextSessionId)
        #expect(alone == nil)
    }

    @Test func theTerminalBreadcrumbIsAcceptedWhenNothingElseNamesTheSession() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try home.write(
            ".omp/agent/terminal-sessions/ttys006",
            lines: ["/Users/vlad/Desktop/voiceoour", home.path(AgentFixtures.freshSessionFile), "fresh"]
        )
        let omp = AgentFixtures.omp(started: Date().addingTimeInterval(-60))

        let resolved = locator(
            home,
            processes: [omp, AgentFixtures.shell()],
            terminalPids: [100, omp.pid]
        ).locate(foreground: omp, ternSessionFile: nil)

        #expect(resolved?.sessionId == AgentFixtures.freshSessionId)
        #expect(resolved?.workingDirectory == "/Users/vlad/Desktop/voiceoour")
        #expect(resolved?.resumable == false)
    }

    @Test func aBreadcrumbOlderThanTheProcessIsRejected() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let breadcrumb = ".omp/agent/terminal-sessions/ttys006"
        try home.write(breadcrumb, lines: ["/Users/v", home.path(AgentFixtures.freshSessionFile)])
        let omp = AgentFixtures.omp(started: Date().addingTimeInterval(-60))
        try home.setModified(breadcrumb, to: omp.startTime.addingTimeInterval(-120))

        let resolved = locator(home, processes: [omp], terminalPids: [omp.pid])
            .locate(foreground: omp, ternSessionFile: nil)

        #expect(resolved == nil)
    }

    @Test func aBreadcrumbOnATerminalAnotherOmpSharesIsRejected() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        try home.write(
            ".omp/agent/terminal-sessions/ttys006",
            lines: ["/Users/v", home.path(AgentFixtures.freshSessionFile)]
        )
        let omp = AgentFixtures.omp(started: Date().addingTimeInterval(-60))
        let suspended = AgentFixtures.omp(pid: 4242, started: Date().addingTimeInterval(-600))

        let resolved = locator(home, processes: [omp, suspended], terminalPids: [omp.pid, suspended.pid])
            .locate(foreground: omp, ternSessionFile: nil)

        #expect(resolved == nil)
    }

    @Test func aForegroundProcessThatIsNoAgentBindsNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }

        let resolved = locator(home)
            .locate(foreground: AgentFixtures.shell(), ternSessionFile: home.path(AgentFixtures.nextSessionFile))

        #expect(resolved == nil)
    }

    @Test func agentsAreRecognizedByExecutablePathAndName() {
        func agent(_ name: String, _ path: String?) -> CodingAgent? {
            AgentSessionLocator.agent(of: AgentFixtures.process(pid: 1, name: name, executablePath: path))
        }
        #expect(agent("18.18.3", AgentFixtures.ompExecutable) == .omp)
        #expect(agent("omp", nil) == .omp)
        #expect(agent("claude", nil) == .claudeCode)
        #expect(agent("2.1.319", AgentFixtures.claudeExecutable) == .claudeCode)
        #expect(agent("node", "/opt/homebrew/bin/claude") == .claudeCode)
        #expect(agent("codex", "/opt/homebrew/bin/codex") == nil)
        #expect(agent("zsh", "/bin/zsh") == nil)
    }

    /// An omp session file outside `~/.omp/agent` binds by the id its name
    /// carries; not a byte of it is read.
    @Test func anOmpSessionFileOutsideTheAllowedRootsBindsByIdAndIsNeverRead() throws {
        let home = try FakeAgentHome()
        let elsewhere = try FakeAgentHome()
        defer {
            home.remove()
            elsewhere.remove()
        }
        let file = try elsewhere.write(
            "sessions/2026-11-09T17-51-31-004Z_\(AgentFixtures.nextSessionId).jsonl",
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "Secret")
        )
        let log = AgentFileReadLog()

        let resolved = locator(home, fileSystem: log.fileSystem)
            .locate(foreground: AgentFixtures.omp(), ternSessionFile: file)

        #expect(
            resolved
                == ResolvedAgentSession(
                    agent: .omp,
                    sessionId: AgentFixtures.nextSessionId,
                    sessionFile: file,
                    workingDirectory: nil,
                    sessionTitle: nil,
                    promptLogOffset: nil,
                    resumable: false
                )
        )
        let outside = try #require(AgentSessionFileSystem.live.realPath(elsewhere.url.path))
        #expect(!log.readPaths.contains { $0.hasPrefix(outside) || $0.hasPrefix(elsewhere.url.path) })
    }

    @Test func anOmpSessionFileNameWithoutAUUIDBindsNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }

        let resolved = locator(home).locate(
            foreground: AgentFixtures.omp(),
            ternSessionFile: home.path(".omp/agent/sessions/-x/2026-11-09T17-51-31-004Z_not-a-uuid.jsonl")
        )

        #expect(resolved == nil)
    }

    // MARK: Claude Code

    @Test func theClaudeCodeRegistryBindsTheSession() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(
                pid: claude.pid,
                sessionId: AgentFixtures.claudeSessionId,
                extra: #","name":"Fix login","nameSource":"user""#
            )
        )
        let transcript = try home.write(
            ".claude/projects/-Users-v-project/\(AgentFixtures.claudeSessionId).jsonl",
            lines: [#"{"type":"ai-title","aiTitle":"Generated"}"#]
        )
        try home.write(".claude/history.jsonl", lines: [#"{"display":"old","timestamp":1,"sessionId":"x"}"#])

        let historySize = try home.size(".claude/history.jsonl")
        let resolved = locator(home).locate(foreground: claude, ternSessionFile: nil)

        #expect(
            resolved
                == ResolvedAgentSession(
                    agent: .claudeCode,
                    sessionId: AgentFixtures.claudeSessionId,
                    sessionFile: AgentSessionFileSystem.live.realPath(transcript),
                    workingDirectory: "/Users/v/project",
                    sessionTitle: "Fix login",
                    promptLogOffset: historySize,
                    resumable: true
                )
        )
    }

    @Test func aDerivedClaudeCodeNameFallsBackToTheTranscriptsLastTitle() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(
                pid: claude.pid,
                sessionId: AgentFixtures.claudeSessionId,
                extra: #","name":"fix-login","nameSource":"derived""#
            )
        )
        try home.write(
            ".claude/projects/-Users-v-project/\(AgentFixtures.claudeSessionId).jsonl",
            lines: [
                #"{"type":"ai-title","aiTitle":"First"}"#,
                #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
                #"{"type":"custom-title","customTitle":"Renamed"}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":"ok"}}"#,
            ]
        )

        let resolved = locator(home).locate(foreground: claude, ternSessionFile: nil)

        #expect(resolved?.sessionTitle == "Renamed")
        #expect(resolved?.promptLogOffset == 0)
    }

    @Test func aClaudeCodeSessionWithoutATranscriptBindsUnresumable() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(pid: claude.pid, sessionId: AgentFixtures.claudeSessionId)
        )

        let resolved = locator(home).locate(foreground: claude, ternSessionFile: nil)

        #expect(resolved?.sessionId == AgentFixtures.claudeSessionId)
        #expect(resolved?.sessionFile == nil)
        #expect(resolved?.resumable == false)
    }

    @Test func aRegistryRecordFromAnEarlierProcessWithThePidBindsNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(
                pid: claude.pid,
                sessionId: AgentFixtures.claudeSessionId,
                started: claude.startTime.addingTimeInterval(-5)
            )
        )

        #expect(locator(home).locate(foreground: claude, ternSessionFile: nil) == nil)
    }

    @Test func aParkedSessionFollowsToItsBackgroundJob() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        let job = AgentFixtures.process(
            pid: 72136,
            name: "claude",
            executablePath: AgentFixtures.claudeExecutable,
            started: AgentFixtures.started.addingTimeInterval(300)
        )
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(
                pid: claude.pid,
                sessionId: AgentFixtures.claudeSessionId,
                extra: #","parkedJobId":"b453f5e2""#
            )
        )
        try home.write(
            ".claude/sessions/72136.json",
            text: AgentFixtures.claudeRecord(
                pid: job.pid,
                sessionId: AgentFixtures.claudeJobSessionId,
                started: job.startTime,
                kind: "bg",
                extra: #","jobId":"b453f5e2""#
            )
        )
        try home.write(
            ".claude/sessions/72139.json",
            text: AgentFixtures.claudeRecord(
                pid: 72139,
                sessionId: "1cdd2b79-0000-4000-8000-000000000000",
                kind: "bg",
                extra: #","jobId":"1cdd2b79","spare":true"#
            )
        )
        try home.write(".claude/sessions/72136.key", text: "secret")
        let log = AgentFileReadLog()

        let resolved = locator(home, processes: [job], fileSystem: log.fileSystem)
            .locate(foreground: claude, ternSessionFile: nil)

        #expect(resolved?.sessionId == AgentFixtures.claudeJobSessionId)
        #expect(!log.readPaths.contains { $0.hasSuffix(".key") })
    }

    @Test func aParkedSessionWhoseJobIsGoneBindsNothing() throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let claude = AgentFixtures.claude()
        let job = AgentFixtures.process(pid: 72136, name: "claude", executablePath: AgentFixtures.claudeExecutable)
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(
                pid: claude.pid,
                sessionId: AgentFixtures.claudeSessionId,
                extra: #","parkedJobId":"b453f5e2""#
            )
        )

        // No record carries the job.
        #expect(locator(home, processes: [job]).locate(foreground: claude, ternSessionFile: nil) == nil)

        // A record carries it, but its process is gone.
        try home.write(
            ".claude/sessions/72136.json",
            text: AgentFixtures.claudeRecord(
                pid: job.pid,
                sessionId: AgentFixtures.claudeJobSessionId,
                kind: "bg",
                extra: #","jobId":"b453f5e2""#
            )
        )
        #expect(locator(home).locate(foreground: claude, ternSessionFile: nil) == nil)
    }

    @Test func procStartParsesTheLstartFormat() {
        let parsed = AgentSessionLocator.processStart(
            "Mon Nov  9 17:43:44 2026",
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(parsed == Date(timeIntervalSince1970: 1_794_246_224))
    }
}
