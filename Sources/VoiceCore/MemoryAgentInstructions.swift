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
}
