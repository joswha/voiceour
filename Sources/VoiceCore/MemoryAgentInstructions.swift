import Foundation

extension MemoryPages {
    /// The paragraph a user pastes into AGENTS.md or CLAUDE.md so an agent finds the memory folder.
    ///
    /// It names the folder by its file-system path, quoted so a path with spaces still reads as one
    /// value, and sends the agent to `MEMORY.md` first because that page states the folder's rules.
    /// It stays one line so it pastes into any instructions file without reflowing around it.
    public static func agentInstructions(root: URL) -> String {
        "Voiceour keeps what I dictate and note in \"\(root.path)\". "
            + "When I refer to something I said, noted or decided, or ask what I worked on, "
            + "read \(indexPath) in that folder first and follow its rules. "
            + "Write only inside its agents/ folder."
    }

    /// The skill's name. omp, Claude Code, Codex and Cursor all require it to equal the name of the
    /// folder that holds `SKILL.md`, so the folder and the links the install command makes use it too.
    public static let agentSkillName = "voiceour-memory"

    /// Where the skill lives, relative to the memory root. It sits inside the folder so Clear Memory
    /// removes it with everything else and Voiceour writes nothing outside its own folder.
    public static let agentSkillPath = "skills/\(agentSkillName)/SKILL.md"

    /// The page an agent loads on demand to find the memory folder, its own session's page, the
    /// folder's rules and the recipe for an outcome note.
    ///
    /// The root is its only variable, written once, so one folder renders the same bytes on every run.
    /// Nothing depends on the clock or the locale: the agent supplies the day itself. The omp id comes
    /// from `$PI_SESSION_FILE` because Voiceour names an omp thread by that file's UUID, and a
    /// subagent's `$PI_SESSION_ID` names no page. An outcome note carries `day` because a note
    /// without a usable `day` or `topic` is ignored, and `session` so it can join its thread.
    public static func agentSkill(root: URL) -> String {
        #"""
        ---
        name: \#(agentSkillName)
        description: The owner's dictation history, kept verbatim by Voiceour on this Mac. Use when the owner refers to something they said, dictated, noted or decided earlier, asks what they worked on, or when a task they dictated to this session ends.
        ---
        # Voiceour memory

        ## Where it is
        Voiceour keeps what the owner dictated and noted, verbatim, in this folder. Quote the path in a shell; it can hold a space:

            "\#(root.path)"

        Read `\#(indexPath)` there first. It gives the folder's layout and rules, the recent days, the agent sessions and the topics. Every path below is relative to this folder.

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
    }

    /// One line the user runs once in Terminal, under sh or zsh, to link the skill into every agent's
    /// personal skills folder that already exists.
    ///
    /// The user runs it, so Voiceour itself writes nothing outside its own folder. It never creates an
    /// agent's folder and never replaces a real entry of the same name, only a missing one or an
    /// earlier link, so running it again is harmless. The root is single-quoted because it holds a
    /// space and may hold any other character a shell would read.
    public static func skillInstallCommand(root: URL) -> String {
        let skillFolder = root.appendingPathComponent("skills/\(agentSkillName)", isDirectory: true).path
        let target = "'" + skillFolder.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let link = "\"$d/\(agentSkillName)\""
        return #"for d in "$HOME/.omp/agent/skills" "$HOME/.claude/skills" "$HOME/.agents/skills"; do "#
            + #"if [ -d "$d" ] && { [ -L \#(link) ] || [ ! -e \#(link) ]; }; then "#
            + #"ln -sfn \#(target) \#(link) && echo "Linked $d"; fi; done"#
    }
}
