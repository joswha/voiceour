import Foundation
import Testing

@testable import VoiceMac

/// The one impure part of the catalog is LaunchServices; the name it hands back
/// still has to be cleaned before a surface shows it.
@Suite("InstalledAppCatalog")
struct InstalledAppCatalogTests {
    @Test func theBundleExtensionIsStrippedWhenFinderLeaksIt() {
        #expect(InstalledAppCatalog.cleanedDisplayName("Claude.app") == "Claude")
        #expect(InstalledAppCatalog.cleanedDisplayName("Claude.APP") == "Claude")
        #expect(InstalledAppCatalog.cleanedDisplayName("Visual Studio Code.app") == "Visual Studio Code")
    }

    @Test func aNameWithoutTheExtensionIsUnchanged() {
        #expect(InstalledAppCatalog.cleanedDisplayName("Claude") == "Claude")
        // Only a trailing extension is a suffix; the word inside a name is not.
        #expect(InstalledAppCatalog.cleanedDisplayName("AppCleaner") == "AppCleaner")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(InstalledAppCatalog.cleanedDisplayName("  Terminal\n") == "Terminal")
    }

    @Test func aNameWithNothingLeftInItIsNoName() {
        #expect(InstalledAppCatalog.cleanedDisplayName("   ") == nil)
        #expect(InstalledAppCatalog.cleanedDisplayName(".app") == nil)
        #expect(InstalledAppCatalog.cleanedDisplayName("") == nil)
    }
}
