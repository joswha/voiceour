import Foundation
import Testing

@testable import VoiceCore

/// The memory switch decides whether delivered dictations are kept, so an absent
/// key must never turn it on, and the agent paragraph must name the folder an
/// agent can open as written.
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
}
