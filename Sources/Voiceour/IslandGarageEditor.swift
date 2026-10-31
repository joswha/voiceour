import Foundation
import VoiceCore

/// Settings ▸ Island's commits and undo steps: when a staged change lands in settings, and
/// what Undo then puts back.
///
/// Controls stage the coordinator's draft and the editor commits it once per gesture: a
/// discrete choice at once, a slider when it is released, a change that reports no editing —
/// a color well, a slider moved from the keyboard — after 300 ms without another, and
/// whatever is still in flight when the section goes away. Each commit is one
/// `saveSettings()` and one undo step that restores the whole previous look.
///
/// A class of its own rather than state on the view, so its undo steps can be driven against
/// a standalone `UndoManager`: no harness flow can press ⌘Z, which AppKit offers only to the
/// key window. The section keeps one for its lifetime and passes the undo manager its
/// environment holds with every call, so a step always lands in the window's manager as it
/// stands; nil commits without a step.
@MainActor
final class IslandGarageEditor {
    /// How long a change without editing callbacks waits for the next one before it commits.
    private static let quietInterval: Duration = .milliseconds(300)

    private let coordinator: DictationCoordinator

    /// The undo step's name for the draft in flight, or nil when nothing is staged.
    private var pendingAction: String?
    /// A slider sits between its editing begin and end; it commits on its own release.
    private var isSliderHeld = false
    private var quietCommit: Task<Void, Never>?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: Writes

    /// Stages `change` and commits it at once: one save and one undo step.
    func apply(
        _ action: String,
        undoManager: UndoManager?,
        _ change: (inout IslandAppearance) -> Void
    ) {
        let settledAnother = settle(before: action, undoManager: undoManager)
        stageChange(action, change)
        commit(undoManager: undoManager, inOwnGroup: settledAnother)
    }

    /// Stages `change` on the coordinator's draft, which the showroom draws at once and nothing
    /// saves yet. Another control's change still in flight commits first, under its own name,
    /// so two controls never share an undo step.
    func stage(
        _ action: String,
        undoManager: UndoManager?,
        _ change: (inout IslandAppearance) -> Void
    ) {
        settle(before: action, undoManager: undoManager)
        stageChange(action, change)
    }

    /// Commits the draft in flight, if there is one: one `saveSettings()` and one undo step
    /// named for the control that moved it.
    func commit(undoManager: UndoManager?) {
        commit(undoManager: undoManager, inOwnGroup: false)
    }

    /// The section is going away, and a held slider's release will not reach it: whatever is
    /// still in flight commits now.
    func finishEditing(undoManager: UndoManager?) {
        isSliderHeld = false
        commit(undoManager: undoManager)
    }

    // MARK: Gestures

    /// A slider stages every step and commits once, when it is released: on the next
    /// main-actor turn, so a value the control sets alongside its release lands in that same
    /// step. An accessibility increment brackets its one step with begin and end, so it
    /// commits exactly like a released drag.
    func sliderEditingChanged(_ editing: Bool, undoManager: UndoManager?) {
        isSliderHeld = editing
        quietCommit?.cancel()
        quietCommit = nil
        guard !editing else { return }
        Task { @MainActor in self.commit(undoManager: undoManager) }
    }

    /// Commits a change that arrives without editing callbacks — a color well, a slider moved
    /// from the keyboard — once it has been quiet for 300 ms. A held slider waits for its own
    /// release instead. The section calls this on every change of the draft.
    func scheduleQuietCommit(undoManager: UndoManager?) {
        quietCommit?.cancel()
        quietCommit = nil
        guard coordinator.islandDraft != nil, !isSliderHeld else { return }
        quietCommit = Task { @MainActor in
            try? await Task.sleep(for: Self.quietInterval)
            guard !Task.isCancelled, !self.isSliderHeld else { return }
            self.commit(undoManager: undoManager)
        }
    }

    // MARK: Steps

    /// Commits another control's change still in flight, under that control's name.
    ///
    /// - Returns: Whether the commit left an undo step.
    @discardableResult
    private func settle(before action: String, undoManager: UndoManager?) -> Bool {
        guard pendingAction != action, coordinator.islandDraft != nil else { return false }
        return commit(undoManager: undoManager, inOwnGroup: false)
    }

    private func stageChange(_ action: String, _ change: (inout IslandAppearance) -> Void) {
        var next = coordinator.effectiveIsland
        change(&next)
        coordinator.stageIsland(next)
        pendingAction = action
    }

    /// - Parameter inOwnGroup: Whether this event already left an undo step — another
    ///   control's draft the choice settled — that this one must not join.
    /// - Returns: Whether the commit left an undo step.
    @discardableResult
    private func commit(undoManager: UndoManager?, inOwnGroup: Bool) -> Bool {
        quietCommit?.cancel()
        quietCommit = nil
        let action = pendingAction ?? "Change Island"
        pendingAction = nil
        guard let change = coordinator.commitIsland(), let undoManager else { return false }
        if inOwnGroup {
            Self.beginNextEventGroup(in: undoManager)
        }
        Self.registerUndo(action, restoring: change.before, on: coordinator, in: undoManager)
        return true
    }

    /// Ends the undo group this event has open and begins another, so the step registered
    /// next is undone on its own.
    ///
    /// The window's undo manager groups by event: the first registration in a pass of the run
    /// loop opens a top-level group, and the end of the pass closes whichever one is open. A
    /// click that settles another control's draft commits twice in one pass, and a shared
    /// group would make Undo skip the look between the two and Redo reapply both. The next
    /// group is begun here rather than left to the next registration, because the manager
    /// opens its own group only once per pass and throws on a registration with none open.
    /// Anything deeper than level 1 is a caller's explicit group, which stays whole, and a
    /// manager that does not group by event has no group of its own to split.
    private static func beginNextEventGroup(in undoManager: UndoManager) {
        guard undoManager.groupsByEvent, undoManager.groupingLevel == 1 else { return }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
    }

    /// One undo step that puts `snapshot` back whole, so a look, a restore or Surprise Me
    /// undoes atomically; running it registers the matching redo the same way.
    ///
    /// A draft still in flight when the step runs — ⌘Z inside a color well's quiet spell —
    /// lands first, without a step of its own, so it is the look the matching redo restores;
    /// staging `snapshot` over it would lose that change for good. The step holds only the
    /// coordinator, so it still works once the section and its editor are gone; a draft it
    /// lands leaves the editor's bookkeeping to the editor's next commit, which finds nothing
    /// pending.
    private static func registerUndo(
        _ action: String,
        restoring snapshot: IslandAppearance,
        on coordinator: DictationCoordinator,
        in undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: coordinator) { [weak undoManager] coordinator in
            coordinator.commitIsland()
            coordinator.stageIsland(snapshot)
            guard let change = coordinator.commitIsland(), let undoManager else { return }
            Self.registerUndo(action, restoring: change.before, on: coordinator, in: undoManager)
        }
        undoManager.setActionName(action)
    }
}
