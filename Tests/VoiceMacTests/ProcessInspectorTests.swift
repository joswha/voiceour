import Darwin
import Foundation
import Testing

@testable import VoiceMac

/// Runs against the test process itself: no other process is inspected.
@Suite("ProcessInspector")
struct ProcessInspectorTests {
    @Test func theTestProcessReportsItsOwnIdentity() throws {
        let facts = try #require(ProcessInspector.facts(pid: getpid()))

        #expect(facts.pid == getpid())
        #expect(facts.uid == getuid())
        #expect(facts.processGroup == getpgrp())
        #expect(facts.startTime < Date())
        #expect(facts.startTime > Date(timeIntervalSince1970: 1_600_000_000))
        #expect(!facts.name.isEmpty)
        let executable = try #require(facts.executablePath)
        #expect(FileManager.default.isExecutableFile(atPath: executable))
        if facts.terminalDevice == nil {
            #expect(facts.terminalName == nil)
        }
    }

    @Test func noProcessAndAnotherUsersProcessReportNothing() {
        #expect(ProcessInspector.facts(pid: 0) == nil)
        #expect(ProcessInspector.facts(pid: -1) == nil)
        #expect(ProcessInspector.openFilePaths(pid: 0).isEmpty)
        if getuid() != 0 {
            // launchd runs as root.
            #expect(ProcessInspector.facts(pid: 1) == nil)
        }
    }

    @Test func openFilePathsListAFileTheProcessHoldsOpen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProcessInspectorTests-\(UUID().uuidString).jsonl"
        )
        try Data("{}\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let canonical = try #require(AgentSessionFileSystem.live.realPath(file.path))

        #expect(ProcessInspector.openFilePaths(pid: getpid()).contains(canonical))
    }

    @Test func theTestProcessIsAmongTheProcessesOnItsTerminal() throws {
        let facts = try #require(ProcessInspector.facts(pid: getpid()))
        // A test run without a controlling terminal has no terminal to list.
        guard let terminal = facts.terminalDevice else { return }

        #expect(facts.terminalName?.hasPrefix("tty") == true)
        #expect(ProcessInspector.pids(onTerminal: terminal, uid: facts.uid).contains(getpid()))
        #expect(!ProcessInspector.pids(onTerminal: terminal, uid: facts.uid &+ 1).contains(getpid()))
    }
}
