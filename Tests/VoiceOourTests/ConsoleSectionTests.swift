import Testing

@testable import VoiceOour

/// App-target smoke coverage for the console's navigation contract: every
/// section carries complete header metadata, and identifiers stay unique so
/// rail selection and deep-links (`LaunchOptions.consoleSection`) never alias.
struct ConsoleSectionTests {
    @Test(arguments: ConsoleSection.allCases)
    func allSectionsCarryCompleteHeaderMetadata(section: ConsoleSection) {
        #expect(!section.label.isEmpty)
        #expect(!section.eyebrow.isEmpty)
        #expect(!section.subtitle.isEmpty)
        #expect(!section.symbol.isEmpty)
    }

    @Test func sectionIdsAreUnique() {
        let ids = ConsoleSection.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Hiding a pane from the rail is a product decision, not a default. Diagnostics
    /// is the only machine-facing pane; anything else added to `.debug` would
    /// silently disappear from a normal launch.
    @Test func diagnosticsIsTheOnlyPaneHiddenFromANormalLaunch() {
        #expect(ConsolePaneRegistry.debugRailDescriptors.map(\.id) == [.diagnostics])
        #expect(!ConsolePaneRegistry.standardRailDescriptors.contains { $0.id == .diagnostics })
        #expect(ConsolePaneRegistry.isDebug(.diagnostics))
        #expect(!ConsolePaneRegistry.isDebug(.system))
    }

    /// The destructive rows moved to System with the pane gating; a debug-only home
    /// would put them behind a launch argument.
    @Test func theRailAlwaysReachesEverySectionThatOwnsADestructiveAction() {
        let reachable = [ConsolePaneRegistry.primaryRailDescriptor] + ConsolePaneRegistry.standardRailDescriptors
        #expect(reachable.contains { $0.id == .system })
    }
}
