import Foundation
import Testing

@testable import VoiceCore

/// The memory switch decides whether delivered dictations are kept, so an absent
/// key must never turn it on; the agent paragraph and the agent skill must name
/// the folder an agent can open as written, and the install command must link
/// the skill without ever replacing a real entry in an agent's skills folder.
@Suite("Memory settings")
struct MemorySettingsTests {
    private let root = URL(
        fileURLWithPath: "/Users/someone/Library/Application Support/Voiceour/memory", isDirectory: true)

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: Setting

    @Test func anAbsentKeyLeavesMemoryOff() throws {
        let settings = try decode("{}")

        #expect(settings.memoryEnabled == false)
        #expect(Settings().memoryEnabled == false)
    }

    @Test func theMemoryKeyTurnsMemoryOn() throws {
        let settings = try decode(#"{"memory_enabled": true}"#)

        #expect(settings.memoryEnabled)
    }

    @Test func theFlagSurvivesAnEncodeDecodeRoundTrip() throws {
        let settings = Settings(memoryEnabled: true)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.memoryEnabled)
        #expect(decoded == settings)
    }

    /// The memory switch is its own key: turning on agent session binding never
    /// starts keeping dictations.
    @Test func theBindingSettingDoesNotTurnMemoryOn() throws {
        let settings = try decode(#"{"agent_session_binding_enabled": true}"#)

        #expect(settings.agentSessionBindingEnabled)
        #expect(settings.memoryEnabled == false)
    }

    // MARK: Agent instructions

    @Test func theInstructionsReadExactly() {
        #expect(
            MemoryPages.agentInstructions(root: root)
                == "Voiceour keeps what I dictate and note in "
                + "\"/Users/someone/Library/Application Support/Voiceour/memory\". "
                + "When I refer to something I said, noted or decided, or ask what I worked on, "
                + "read MEMORY.md in that folder first and follow its rules. "
                + "Write only inside its agents/ folder."
        )
    }

    @Test func theInstructionsQuoteTheRootPathOnce() {
        let text = MemoryPages.agentInstructions(root: root)
        let quoted = "\"\(root.path)\""

        #expect(text.components(separatedBy: root.path).count == 2)
        #expect(text.contains(quoted))
        #expect(!text.contains("file://"))
        #expect(!text.contains("%20"))
    }

    @Test func theInstructionsNameTheIndexAndTheAgentsFolder() {
        let text = MemoryPages.agentInstructions(root: root)

        #expect(text.contains("MEMORY.md"))
        #expect(text.contains("agents/"))
    }

    @Test func theInstructionsAreOneParagraph() {
        let text = MemoryPages.agentInstructions(root: root)

        // Evaluated outside the macro: `#expect` cannot expand a `rethrows` call.
        let holdsLineBreak = text.contains { $0.isNewline }

        #expect(!holdsLineBreak)
        #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Agent skill

    @Test func theSkillReadsExactly() {
        #expect(
            MemoryPages.agentSkill(root: root)
                == #"""
                ---
                name: voiceour-memory
                description: The owner's dictation history, kept verbatim by Voiceour on this Mac. Use when the owner refers to something they said, dictated, noted or decided earlier, asks what they worked on, or when a task they dictated to this session ends.
                ---
                # Voiceour memory

                ## Where it is
                Voiceour keeps what the owner dictated and noted, verbatim, in this folder. Quote the path in a shell; it can hold a space:

                    "/Users/someone/Library/Application Support/Voiceour/memory"

                Read `MEMORY.md` there first. It gives the folder's layout and rules, the recent days, the agent sessions and the topics. Every path below is relative to this folder.

                ## This session's page
                Voiceour keeps a page for an agent session only when the owner dictated into it while linking was on.
                - omp: `threads/omp-<id>.md`. Get `<id>` from `$PI_SESSION_FILE` with this command; never use `$PI_SESSION_ID`, which in a subagent names no page:
                  `printf '%s' "$PI_SESSION_FILE" | sed -E 's#^.*/sessions/[^/]+/[^/_]*_([0-9a-f-]{36})(\.jsonl|/.*)$#\1#'`
                  If it prints anything but a UUID, there is no page.
                - Claude Code: `threads/claude-code-$CLAUDE_CODE_SESSION_ID.md`.

                No page means Voiceour linked nothing to this session. Read today's day page, `days/YYYY-MM-DD.md`, instead.

                ## Rules
                - Read any file in the folder.
                - Quote the owner's words exactly.
                - Write only inside `agents/`, and create it if it is absent. Voiceour overwrites or deletes every other file.
                - Never copy the owner's words into commits, issues or messages unless the owner asks.

                ## Record an outcome
                Record an outcome only when all of these hold:
                - This session's page exists.
                - A task the owner dictated in this session has ended.
                - You are not a subagent, and no other agent gave you the task.

                Write `agents/<agent>-<id>.md`, the same file name as this session's page in `threads/`, and replace that file if it exists. Start it with this front matter, replacing each `<...>`:

                    ---
                    author: <your own name>
                    day: <today's date, YYYY-MM-DD>
                    session: <agent>-<id>
                    title: <a few words>
                    ---

                Then write what you did, what is still open, and what you need from the owner.

                If writing outside your workspace needs approval, ask once or skip it.

                """#
        )
    }

    @Test func theSkillNamesTheRootOnce() {
        let text = MemoryPages.agentSkill(root: root)

        #expect(text.components(separatedBy: root.path).count == 2)
        #expect(text.contains("\"\(root.path)\""))
        #expect(!text.contains("file://"))
        #expect(!text.contains("%20"))
    }

    /// Every agent that loads skills refuses or misfiles one whose name differs from its folder.
    @Test func theSkillNameEqualsItsFolderName() throws {
        let folder = try #require(MemoryPages.agentSkillPath.split(separator: "/").dropLast().last)

        #expect(frontMatterValue("name", in: MemoryPages.agentSkill(root: root)) == MemoryPages.agentSkillName)
        #expect(String(folder) == MemoryPages.agentSkillName)
        #expect(MemoryPages.agentSkillPath.hasSuffix("/SKILL.md"))
    }

    /// Codex caps the description at 1,024 characters and Claude Code escapes angle brackets in it.
    @Test func theDescriptionFitsEveryAgent() throws {
        let description = try #require(frontMatterValue("description", in: MemoryPages.agentSkill(root: root)))

        #expect(!description.isEmpty)
        #expect(description.count <= 1_024)
        #expect(!description.contains("<"))
        #expect(!description.contains(">"))
    }

    // MARK: Install command

    @Test func theInstallCommandQuotesASpaceAndAnApostrophe() {
        let spaced = MemoryPages.skillInstallCommand(root: root)
        let apostrophe = MemoryPages.skillInstallCommand(
            root: URL(fileURLWithPath: "/Users/someone/it's mine/memory", isDirectory: true))

        #expect(spaced.contains("'/Users/someone/Library/Application Support/Voiceour/memory/skills/voiceour-memory'"))
        #expect(apostrophe.contains(#"'/Users/someone/it'\''s mine/memory/skills/voiceour-memory'"#))
        // Evaluated outside the macro: `#expect` cannot expand a `rethrows` call.
        let holdsLineBreak = spaced.contains { $0.isNewline }
        #expect(!holdsLineBreak)
    }

    /// The command runs against a temporary HOME only: two of the three skills folders exist and one
    /// already holds a real `voiceour-memory` folder, so only the free slot may gain a link. A second
    /// run replaces its own link and still leaves the real folder alone.
    @Test func theInstallCommandLinksOnlyTheFreeSlot() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home dir", isDirectory: true)
        let memoryRoot = directory.appendingPathComponent("Voiceour's memory", isDirectory: true)
        let ompSkills = home.appendingPathComponent(".omp/agent/skills", isDirectory: true)
        let claudeSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let realSkill = claudeSkills.appendingPathComponent("voiceour-memory", isDirectory: true)
        let skillFile = memoryRoot.appendingPathComponent(MemoryPages.agentSkillPath)
        let skillText = MemoryPages.agentSkill(root: memoryRoot)

        try fileManager.createDirectory(at: ompSkills, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realSkill, withIntermediateDirectories: true)
        try "the owner's own skill\n".write(
            to: realSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skillText.write(to: skillFile, atomically: true, encoding: .utf8)

        let command = MemoryPages.skillInstallCommand(root: memoryRoot)
        let first = try runShell(command, home: home)
        let second = try runShell(command, home: home)

        let expected = "Linked \(ompSkills.path)\n"
        #expect(first.status == 0)
        #expect(first.output == expected)
        #expect(second.status == 0)
        #expect(second.output == expected)

        let link = ompSkills.appendingPathComponent("voiceour-memory")
        #expect(
            try fileManager.destinationOfSymbolicLink(atPath: link.path)
                == skillFile.deletingLastPathComponent().path)
        #expect(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8) == skillText)

        let realType = try fileManager.attributesOfItem(atPath: realSkill.path)[.type] as? FileAttributeType
        #expect(realType == .typeDirectory)
        #expect(try fileManager.contentsOfDirectory(atPath: realSkill.path) == ["SKILL.md"])
        #expect(
            try String(contentsOf: realSkill.appendingPathComponent("SKILL.md"), encoding: .utf8)
                == "the owner's own skill\n")
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent(".agents").path))
    }

    // MARK: Helpers

    /// The value of one `key: value` line in the skill's front matter.
    private func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let prefix = "\(key): "
        return lines[1..<end].first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Runs `command` with `/bin/sh -c` in an environment holding only `HOME` and a system `PATH`,
    /// so the command can never reach the real home folder.
    private func runShell(_ command: String, home: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
