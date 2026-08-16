import Foundation
import Testing

@testable import Voiceour

/// The console reopens on the tab it was last used on, unless a launch flag
/// pins one explicitly. The stored value is a raw tab name in UserDefaults;
/// junk in either source must degrade to "no answer", never crash or guess.
@Suite("Console tab persistence")
struct ConsoleTabPersistenceTests {
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "voiceour-tab-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func storedTabRoundTripsThroughDefaults() throws {
        let defaults = try scratchDefaults()

        #expect(ConsoleWindowView.storedTab(in: defaults) == nil)
        ConsoleWindowView.storeTab(.history, in: defaults)
        #expect(ConsoleWindowView.storedTab(in: defaults) == .history)
        ConsoleWindowView.storeTab(.system, in: defaults)
        #expect(ConsoleWindowView.storedTab(in: defaults) == .system)
    }

    @Test func junkStoredValueReadsAsNoAnswer() throws {
        let defaults = try scratchDefaults()

        defaults.set("left-rail-pane-3", forKey: ConsoleWindowView.lastTabKey)
        #expect(ConsoleWindowView.storedTab(in: defaults) == nil)
    }

    /// Explicit flag wins; absence and junk both mean "no override" so the
    /// stored last-used tab can decide. Junk used to fall back to `.general`.
    @Test func consoleSectionOverrideParsesFlagAbsenceAndJunk() {
        #expect(LaunchOptions.consoleSectionOverride(in: ["--console-section=system"]) == .system)
        #expect(LaunchOptions.consoleSectionOverride(in: ["--console-section=glossary"]) == .glossary)
        #expect(LaunchOptions.consoleSectionOverride(in: ["--debug"]) == nil)
        #expect(LaunchOptions.consoleSectionOverride(in: []) == nil)
        #expect(LaunchOptions.consoleSectionOverride(in: ["--console-section=diagnostics"]) == nil)
    }
}
