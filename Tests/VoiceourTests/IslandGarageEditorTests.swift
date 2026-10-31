import Foundation
import Testing
import VoiceCore

@testable import Voiceour

/// Settings ▸ Island's undo steps, driven against a standalone `UndoManager`: no harness flow
/// can press ⌘Z, which AppKit offers only to the key window, and the harness window never
/// becomes key.
///
/// The window's undo manager groups by event: the first registration in a pass of the run
/// loop opens a top-level group, and the end of the pass closes it. Tests of one control's
/// gesture turn that off and bracket the gesture in an explicit group of their own. The test
/// of a click that commits twice keeps it on, because the event's group is the one that
/// click's two commits would share.
@MainActor
@Suite("IslandGarageEditor")
struct IslandGarageEditorTests {
    /// ⌘Z inside a color well's quiet spell undoes the step before the pick without losing
    /// the pick: the pending draft lands first, so Redo brings that step back with the pick
    /// on it, in settings and on disk.
    @Test func undoInsideAColorWellsQuietSpellKeepsThePickForRedo() async throws {
        let (coordinator, settingsStore, directory) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let editor = IslandGarageEditor(coordinator: coordinator)

        // Candy, clicked: committed at once, as one step.
        undoManager.beginUndoGrouping()
        editor.apply("Change Coat", undoManager: undoManager) { $0.select(coat: .candy) }
        undoManager.endUndoGrouping()

        // A pick in the candy color well, still inside its quiet spell.
        editor.stage("Change Candy Color", undoManager: undoManager) {
            $0.candyHue = 210
            $0.candySaturation = 70
            $0.candyBrightness = 60
        }
        let picked = try #require(coordinator.islandDraft)

        undoManager.undo()
        #expect(coordinator.islandDraft == nil)
        #expect(coordinator.settings.island == .stock)
        #expect(undoManager.redoActionName == "Change Coat")

        undoManager.redo()
        #expect(coordinator.settings.island == picked)
        let write = try #require(coordinator.recentSessionPersistenceTail)
        let saved = await write.value
        #expect(saved)
        #expect(try settingsStore.load().island == picked)
    }

    /// A choice clicked while another control's draft is still in flight commits that draft
    /// first, in the same event, and the two stay separate steps: Undo returns to the tuned
    /// color, a second Undo to the look before it, and Redo walks both steps forward again.
    @Test func aChoiceThatSettlesAnotherControlsDraftIsAStepOfItsOwn() throws {
        let (coordinator, _, directory) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Grouping by event, as the window's undo manager does: the click's first
        // registration opens the event's group. Nothing here returns to the run loop, so that
        // group is still open when the first Undo closes it, which `undo()` does at level 1.
        let undoManager = UndoManager()
        let editor = IslandGarageEditor(coordinator: coordinator)
        var candy = IslandAppearance.stock
        candy.select(coat: .candy)
        coordinator.settings.island = candy

        // A pick in the candy color well, then a look chosen inside the pick's quiet spell.
        editor.stage("Change Candy Color", undoManager: undoManager) {
            $0.candyHue = 210
            $0.candySaturation = 70
            $0.candyBrightness = 60
        }
        let tuned = try #require(coordinator.islandDraft)
        let look = IslandLook.neonKit.appearance
        editor.apply("Choose Look", undoManager: undoManager) { $0 = look }
        #expect(coordinator.settings.island == look)
        #expect(undoManager.undoActionName == "Choose Look")

        undoManager.undo()
        #expect(coordinator.settings.island == tuned)
        #expect(undoManager.undoActionName == "Change Candy Color")

        undoManager.undo()
        #expect(coordinator.settings.island == candy)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(coordinator.settings.island == tuned)
        undoManager.redo()
        #expect(coordinator.settings.island == look)
    }

    /// A slider stages every step of its drag and commits once, on the main-actor turn after
    /// its release: one undo step, named for the slider, back to the look before the drag.
    @Test func aSliderDragIsOneUndoStepNamedForItsSlider() async {
        let (coordinator, _, directory) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: directory) }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let editor = IslandGarageEditor(coordinator: coordinator)

        undoManager.beginUndoGrouping()
        editor.sliderEditingChanged(true, undoManager: undoManager)
        editor.stage("Change Size", undoManager: undoManager) { $0.size = 95 }
        editor.stage("Change Size", undoManager: undoManager) { $0.size = 90 }
        // Held, the drag only stages: no step lands for a value it passes through.
        #expect(coordinator.settings.island == .stock)
        #expect(coordinator.islandDraft?.size == 90)

        editor.sliderEditingChanged(false, undoManager: undoManager)
        #expect(coordinator.islandDraft != nil, "the release commits on the next turn")
        await waitUntil { coordinator.islandDraft == nil }
        undoManager.endUndoGrouping()

        var sized = IslandAppearance.stock
        sized.size = 90
        #expect(coordinator.settings.island == sized)
        #expect(undoManager.undoCount == 1)
        #expect(undoManager.undoActionName == "Change Size")

        undoManager.undo()
        #expect(coordinator.settings.island == .stock)
        #expect(!undoManager.canUndo)
    }

    /// A commit with nothing in flight — the section going away, a control moved back to where
    /// it started — saves nothing and leaves no step.
    @Test func aCommitWithNothingPendingSavesNothingAndLeavesNoStep() {
        let (coordinator, _, directory) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Grouping by event, so a stray registration opens a group here rather than throwing.
        let undoManager = UndoManager()
        let editor = IslandGarageEditor(coordinator: coordinator)

        editor.commit(undoManager: undoManager)
        // 2 % snaps to stock's 0 % finish, so the draft is dropped as it is staged.
        editor.stage("Change Finish", undoManager: undoManager) { $0.finish = 2 }
        #expect(coordinator.islandDraft == nil)
        editor.finishEditing(undoManager: undoManager)

        #expect(coordinator.settings.island == .stock)
        #expect(coordinator.recentSessionPersistenceTail == nil)
        #expect(undoManager.groupingLevel == 0)
        #expect(!undoManager.canUndo)
    }

    // MARK: Helpers

    /// A coordinator as `DictationCoordinatorTests` builds one, with its three stores in one
    /// scratch directory: a commit saves settings, and the default store is the user's own
    /// file.
    private func makeCoordinator() -> (
        coordinator: DictationCoordinator,
        settingsStore: SettingsStore,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voiceour-island-editor-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let settingsStore = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        let coordinator = DictationCoordinator(
            recorder: FakeRecorder(),
            asr: FakeASR(behavior: .text("unused")),
            tracker: FakeTracker(),
            inserter: FakeInserter(outcome: .pasteAttempted),
            permissions: FakePermissions(),
            hotkey: FakeHotkey(),
            activeASRBackend: "fake",
            settingsStore: settingsStore,
            recentSessionStore: RecentSessionStore(
                url: directory.appendingPathComponent("recent-sessions.json")
            ),
            dictationStatsStore: DictationStatsStore(
                url: directory.appendingPathComponent("dictation-activity.json")
            )
        )
        return (coordinator, settingsStore, directory)
    }
}
