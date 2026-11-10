import SwiftUI
import VoiceCore

/// Settings ▸ Danger: the erases the app owns.
///
/// They read directly on the Privacy and Memory pages: those pages state what is
/// kept locally, these rows are how a reader unkeeps it. Each is guarded by the
/// system's own destructive confirmation rather than a typed token — the dialog
/// names the subject, states the scope, and puts the destructive verb behind a
/// deliberate second press.
struct SettingsDangerPage: View {
    private let coordinator: DictationCoordinator
    private let erasure: SettingsErasure

    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingMemoryClear = false
    @State private var isConfirmingVocabularyClear = false

    init(coordinator: DictationCoordinator, erasure: SettingsErasure) {
        self.coordinator = coordinator
        self.erasure = erasure
    }

    var body: some View {
        SettingsPage(.danger) {
            SettingsIsland {
                clearHistoryRow
                Kit.Rule()
                clearMemoryRow
                Kit.Rule()
                clearVocabularyRow
            }
        }
    }

    // MARK: History

    private var clearHistoryRow: some View {
        Kit.SettingRow(
            "Clear history",
            caption: erasure.historyClearFailed
                ? "Transcript history could not be erased from disk — it will come back on relaunch."
                : Self.historyClearSentence,
            captionColor: erasure.historyClearFailed ? .red : nil
        ) {
            Kit.ActionButton(erasure.isClearingHistory ? "Clearing…" : "Clear History…", role: .destructive) {
                erasure.historyClearFailed = false
                isConfirmingHistoryClear = true
            }
            .disabled(hasNothingToClear || erasure.isClearingHistory)
            .accessibilityIdentifier("system.history.arm")
        }
        .confirmationDialog(
            "Clear transcript history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                erasure.clearHistory(includingMemory: false, coordinator: coordinator)
            }
            .accessibilityIdentifier("system.history.confirm")
            // Offered beside the plain clear, never folded into it: Clear History
            // leaves memory alone, and a reader erasing History to start over is
            // the one most likely to want the kept copy gone too.
            if hasMemoryToClear {
                Button("Clear History and Memory", role: .destructive) {
                    erasure.clearHistory(includingMemory: true, coordinator: coordinator)
                }
                .accessibilityIdentifier("system.history.confirm-with-memory")
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing transcript history")
                .accessibilityIdentifier("system.history.cancel")
        } message: {
            Text(Self.historyClearSentence)
        }
    }

    /// Named once because the row caption and the confirmation both state it,
    /// and a destructive action whose two sentences disagree about its scope is
    /// worse than one that says nothing.
    private static let historyClearSentence =
        "Clear local transcript history and the lifetime dictation stats on Home. "
        + "Settings and glossary terms are kept."

    /// The stats ledger outlives individual transcripts — a reader who deleted
    /// every row one at a time in History still has counts here — so an empty
    /// journal alone must not disarm the only control that erases them.
    private var hasNothingToClear: Bool {
        coordinator.recentSessions.isEmpty && coordinator.dictationStats == DictationStatsLedger()
    }

    // MARK: Memory

    private var clearMemoryRow: some View {
        Kit.SettingRow(
            "Clear memory",
            caption: erasure.memoryClearFailed
                ? "Memory could not be erased from disk — it will come back on relaunch."
                : Self.memoryClearSentence,
            captionColor: erasure.memoryClearFailed ? .red : nil
        ) {
            Kit.ActionButton(erasure.isClearingMemory ? "Clearing…" : "Clear Memory…", role: .destructive) {
                erasure.memoryClearFailed = false
                isConfirmingMemoryClear = true
            }
            .disabled(!hasMemoryToClear || erasure.isClearingMemory)
            .accessibilityIdentifier("system.memory.arm")
        }
        .confirmationDialog(
            "Clear memory?",
            isPresented: $isConfirmingMemoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear Memory", role: .destructive) {
                erasure.clearMemory(coordinator: coordinator)
            }
            .accessibilityIdentifier("system.memory.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing memory")
                .accessibilityIdentifier("system.memory.cancel")
        } message: {
            Text(Self.memoryClearSentence)
        }
    }

    /// Named once for the same reason as `historyClearSentence`: the caption and
    /// the confirmation must state one scope.
    private static let memoryClearSentence =
        "Erase the memory folder: every kept dictation and note, your topics, the Markdown pages, and "
        + "anything agents saved there. History and the Home figures are kept."

    /// The folder on disk, or entries whose first write is still queued behind
    /// it. The second half matters for one turn only: a memory switched on with
    /// History already present publishes its entries before the folder exists,
    /// and the disk check alone is not something this view observes.
    private var hasMemoryToClear: Bool {
        coordinator.memoryExistsOnDisk || !coordinator.memoryEntries.isEmpty
    }

    // MARK: Vocabulary

    /// Unlike `clearRecentSessions` this mutation is synchronous and publishes no
    /// durability result, so there is no failure state for the row to report.
    private var clearVocabularyRow: some View {
        Kit.SettingRow("Clear vocabulary", caption: Self.vocabularyClearSentence) {
            Kit.ActionButton("Clear Vocabulary…", role: .destructive) {
                isConfirmingVocabularyClear = true
            }
            .disabled(!coordinator.hasLearnedVocabulary)
            .accessibilityIdentifier("system.vocabulary.arm")
        }
        .confirmationDialog(
            "Clear learned vocabulary?",
            isPresented: $isConfirmingVocabularyClear,
            titleVisibility: .visible
        ) {
            Button("Clear Vocabulary", role: .destructive) {
                coordinator.clearLearnedVocabulary()
            }
            .accessibilityIdentifier("system.vocabulary.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing learned vocabulary")
                .accessibilityIdentifier("system.vocabulary.cancel")
        } message: {
            Text(Self.vocabularyClearSentence)
        }
    }

    /// The row caption and the confirmation's message, stated once.
    private static let vocabularyClearSentence =
        "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled "
        + "defaults back to their shipped surfaces."
}

/// The erases in flight and what they left behind, held by the Settings tab so a
/// clear keeps its guard while the reader visits another page and its failure is
/// still stated when they come back.
@MainActor
@Observable
final class SettingsErasure {
    var isClearingHistory = false
    var historyClearFailed = false
    var isClearingMemory = false
    var memoryClearFailed = false

    /// With `includingMemory` the memory erase runs after History and the ledger,
    /// and the row stays in its clearing state until all three have answered.
    /// Each failure is reported on the row that names what survived: a memory
    /// folder that could not be removed is the Clear memory row's caption, so the
    /// History row never claims transcripts survived when they did not.
    func clearHistory(includingMemory: Bool, coordinator: DictationCoordinator) {
        isClearingHistory = true
        historyClearFailed = false
        if includingMemory {
            isClearingMemory = true
            memoryClearFailed = false
        }
        Task {
            let historyCleared = await coordinator.clearRecentSessions()
            let statsCleared = await coordinator.clearDictationStats()
            if includingMemory {
                let memoryCleared = await coordinator.clearMemory()
                isClearingMemory = false
                memoryClearFailed = !memoryCleared
            }
            isClearingHistory = false
            // A destructive action that half-succeeds must say so: the row reports
            // that the data survived on disk instead of reporting nothing.
            historyClearFailed = !(historyCleared && statsCleared)
        }
    }

    func clearMemory(coordinator: DictationCoordinator) {
        isClearingMemory = true
        memoryClearFailed = false
        Task {
            let cleared = await coordinator.clearMemory()
            isClearingMemory = false
            // Mirrors the History row: an erase that left the folder says so.
            memoryClearFailed = !cleared
        }
    }
}
