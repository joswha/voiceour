// Exercises the offscreen UI harness, which is compiled out unless `UI_HARNESS`
// is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`; a bare
// `swift test` compiles this file away rather than failing to resolve the harness.
#if UI_HARNESS

    import Foundation
    import Testing
    @testable import VoiceOour

    /// App-target smoke coverage for the offscreen harness catalog, in the same
    /// spirit as `ConsoleSectionTests`: a scene id is the artifact basename on both
    /// sides of the golden diff, so a collision never fails loudly — it silently
    /// makes two scenes share one golden and lets the later render win.
    ///
    /// `UISceneCatalog.all()` installs `UIFixtures.pinProcessSeams()` as a side
    /// effect, which is why these assertions are grouped in one suite: the pins are
    /// all the standard presentation values, and nothing else in this target reads
    /// `RenderOverrides`.
    ///
    /// The selection matches `make ui-snap` — `all()` drops `os26` scenes for any
    /// caller that passes neither `--list` nor `--only`, which a test runner does not.
    @MainActor
    struct UISceneCatalogTests {
        @Test func sceneIdsAreUnique() {
            let ids = UISceneCatalog.all().map(\.id)
            #expect(Set(ids).count == ids.count)
        }

        @Test func sceneIdsAreFilesystemSafeBasenames() {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
            for scene in UISceneCatalog.all() {
                #expect(!scene.id.isEmpty)
                #expect(scene.id.allSatisfy(allowed.contains), "unsafe artifact basename: \(scene.id)")
            }
        }

        @Test func everySceneCarriesATitleAndAMeasure() {
            for scene in UISceneCatalog.all() {
                #expect(!scene.title.isEmpty, "untitled scene: \(scene.id)")
                #expect(scene.size.width > 0, "empty measure: \(scene.id)")
                #expect(scene.size.height > 0, "empty measure: \(scene.id)")
            }
        }

        /// The Refinement pane branches hard on the provider — Apple hides the
        /// endpoint, model and credential rows, Oh My Pi hides the credentials, and
        /// Custom is the only one that edits its own base URL — and its two failure
        /// verdicts are the states a user actually files a bug about. One configured
        /// shape cannot stand in for any of them.
        @Test func refinementCoversEveryProviderShapeAndBothFailures() {
            let ids = Set(UISceneCatalog.all().map(\.id))
            let expected = [
                "console.refinement.off",
                "console.refinement.configured",
                "console.refinement.apple",
                "console.refinement.omp",
                "console.refinement.omp-login-failed",
                "console.refinement.custom",
                "console.refinement.unauthorized",
                "console.refinement.unreachable",
            ]
            for identifier in expected {
                #expect(ids.contains(identifier), "missing refinement scene: \(identifier)")
            }
        }
    }

#endif
