import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// One entry, readable in full: a timestamp gutter and the whole text. A click
/// copies the text.
///
/// Rewind and Threads are read rather than scanned, so a row holds the whole
/// text instead of History's two-line preview, and the timestamp sits in a
/// gutter of its own so the text's left edge lines up from row to row. The text
/// is the control, as it is in History's open transcript: a click copies it, and
/// a transient COPIED mark and a VoiceOver announcement confirm the write.
///
/// An entry that only memory holds has no Timeline row to delete it from, so
/// the row itself offers "Delete Entry…" for it, behind the same titled
/// confirmation History uses for a transcript.
struct JournalEntryRow: View {
    private let entry: JournalEntry
    private let isInHistory: Bool
    private let showsThreadAction: Bool
    private let navigation: JournalNavigation
    private let delete: ((UUID) async -> Bool)?
    /// The topics the "File Under" submenu offers, in the order memory holds them.
    private let topics: [MemoryTopic]
    /// Files the entry under a topic, or under none; nil offers no submenu.
    private let file: ((UUID, String?) -> Void)?

    @State private var showsCopied = false
    @State private var resetCopyFeedbackTask: Task<Void, Never>?
    @State private var confirmsDelete = false
    /// True while a confirmed delete is in flight, so a second confirmation
    /// cannot start a second removal of the same entry.
    @State private var isDeleting = false
    @State private var deleteFailed = false

    private var a11y = A11y()

    /// `isInHistory` offers "Show in Timeline", which only a row History still
    /// holds can answer. `showsThreadAction` offers "Open Thread", which a lens
    /// already showing the entry's thread has no use for. `delete` offers
    /// "Delete Entry…" only on an entry History no longer holds: an entry still
    /// in History is deleted from Timeline, where its transcript is. It returns
    /// false when the entry could not be removed. `file` offers "File Under", which
    /// files the entry under one of `topics` or, with nil, under none.
    init(
        entry: JournalEntry,
        isInHistory: Bool,
        showsThreadAction: Bool,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)? = nil,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil
    ) {
        self.entry = entry
        self.isInHistory = isInHistory
        self.showsThreadAction = showsThreadAction
        self.navigation = navigation
        self.delete = delete
        self.topics = topics
        self.file = file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            entryButton
            // A destructive action that fails must say so under the row that
            // asked for it, rather than leave the entry on screen unexplained.
            if deleteFailed {
                ConsoleCaption("The entry could not be deleted.", color: .red)
                    .accessibilityIdentifier("journal.entry.delete-error")
            }
        }
    }

    private var entryButton: some View {
        Button(action: copyText) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                // The copy confirmation takes the timestamp's place rather than a
                // line of its own, so a click never moves the rows below it.
                Text(timestamp)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(showsCopied ? 0 : 1)
                    .overlay(alignment: .leading) {
                        if showsCopied {
                            ConsoleStateMark("COPIED", .ok)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(entry.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if hasMarks {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            if isNote {
                                ConsoleStateMark("NOTE", .neutral)
                            }
                            if isNotSent {
                                ConsoleStateMark("NOT SENT", .warn)
                            }
                            if let highlightKind {
                                ConsoleStateMark(highlightKind.displayName.uppercased(), .neutral)
                            }
                        }
                    }
                }
            }
            // One line of text is 16 pt tall and a line of marks brings it to 33 pt;
            // the row takes the control height above each, so a short entry is still
            // a full click target and no height falls between two of the scale's.
            .frame(
                maxWidth: .infinity,
                minHeight: hasMarks ? VoiceourMetrics.Control.large : VoiceourMetrics.Control.mini,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Copy text", copyText)
        .contextMenu {
            Button("Copy Text", action: copyText)
            if isInHistory {
                Button("Show in Timeline") {
                    navigation.showInTimeline(entry.id)
                }
            }
            if showsThreadAction, let thread = entry.thread {
                Button("Open Thread") {
                    navigation.openThread(thread.key)
                }
            }
            if let file {
                fileUnderMenu(file)
            }
            if offersDelete {
                Button("Delete Entry\u{2026}", role: .destructive) {
                    deleteFailed = false
                    confirmsDelete = true
                }
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entry is removed from this Mac's memory. Text you already pasted is not affected.")
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
        }
    }

    // MARK: Derived

    private var timestamp: String {
        SessionsFormatters.timestamp.string(from: entry.createdAt)
    }

    private var isNote: Bool {
        entry.kind == .note
    }

    /// Only an answered send check counts: a pending one (`nil`) says nothing
    /// about the prompt yet, and a row must not claim a failure it has not seen.
    private var isNotSent: Bool {
        entry.thread?.sent == false
    }

    /// The kinds Rewind lifts into its highlights, under the same confidence bar,
    /// so a row marks exactly the entries a day's highlights would name.
    private var highlightKind: UtteranceKind? {
        guard let label = entry.label, let kind = label.kind,
            let confidence = label.kindConfidence,
            confidence >= JournalQuery.highlightConfidence
        else { return nil }
        switch kind {
        case .decision, .idea, .todo, .question:
            return kind
        case .instruction, .observation, .chatter:
            return nil
        }
    }

    private var hasMarks: Bool {
        isNote || isNotSent || highlightKind != nil
    }

    private var offersDelete: Bool {
        delete != nil && !isInHistory
    }

    /// The time, then the states a reader acts on and the kind the row marks,
    /// then the words. The marks are words on screen, so VoiceOver hears them
    /// as words too.
    private var accessibilityLabel: String {
        var parts = [timestamp]
        if isNote { parts.append("note") }
        if isNotSent { parts.append("not sent") }
        if let highlightKind { parts.append(highlightKind.displayName.lowercased()) }
        parts.append(entry.text)
        return parts.joined(separator: ", ")
    }

    // MARK: Copy

    /// Mirrors History's copy: the mark and the announcement are claims about the
    /// clipboard, so a refused write leaves the row exactly as it was.
    private func copyText() {
        guard GeneralPasteboard.copy(entry.text) != nil else { return }
        announceCopy("Text copied to clipboard")
        resetCopyFeedbackTask?.cancel()
        withAnimation(feedbackAnimation) {
            showsCopied = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(feedbackAnimation) {
                showsCopied = false
            }
        }
    }

    /// A mark that appears beside a row the VoiceOver cursor has already left
    /// confirms nothing, so the same sentence is spoken. A no-op when VoiceOver
    /// is not running.
    private func announceCopy(_ sentence: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private var feedbackAnimation: Animation? {
        a11y.reduceMotion ? nil : .easeInOut(duration: VoiceourMotion.quickDuration)
    }

    // MARK: Delete

    /// Mirrors History's delete: the outcome is reported on the row that asked
    /// for it, and a removal that did not reach disk says so.
    private func confirmDelete() {
        guard let delete, !isDeleting else { return }
        deleteFailed = false
        isDeleting = true
        let id = entry.id
        Task {
            let isDeleted = await delete(id)
            isDeleting = false
            deleteFailed = !isDeleted
        }
    }

    // MARK: File

    /// One item per topic, the entry's current topic checked, then "No Topic".
    /// Choosing an item is an explicit request, so the checked topic files the
    /// entry again rather than unfiling it; "No Topic" is the one way out. With
    /// no topics the submenu still opens, to say why it offers nothing.
    @ViewBuilder
    private func fileUnderMenu(_ file: @escaping (UUID, String?) -> Void) -> some View {
        Menu("File Under") {
            if topics.isEmpty {
                Button("No topics yet") {}
                    .disabled(true)
            } else {
                ForEach(topics) { topic in
                    Toggle(topic.name, isOn: fileBinding(topic.id))
                }
                Divider()
                Button("No Topic") {
                    file(entry.id, nil)
                }
            }
        }
        .accessibilityIdentifier("journal.entry.file")
    }

    /// Reads as checked for the entry's topic; any choice files the entry under
    /// that topic, whichever way the menu says it flipped.
    private func fileBinding(_ topicID: String) -> Binding<Bool> {
        Binding(
            get: { entry.topicID == topicID },
            set: { _ in file?(entry.id, topicID) }
        )
    }
}
