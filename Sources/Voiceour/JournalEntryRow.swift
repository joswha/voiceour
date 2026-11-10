import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// One entry, readable in full: a timestamp gutter and the whole text. A click copies
/// the text.
///
/// Rewind, Threads, Topics and Notes pages are read rather than scanned, so a row holds
/// the whole text instead of a list row's two-line preview, and the timestamp sits in a
/// gutter of its own so the text's left edge lines up from row to row. The row is the
/// control: a click copies the text, and a transient "Copied" pill in the gutter and a
/// VoiceOver announcement confirm the write where the click landed.
///
/// An entry that only memory holds has no Timeline row to delete it from, so the row
/// itself offers "Delete Entry…" for it, behind the same titled confirmation Timeline
/// uses for a transcript.
struct JournalEntryRow: View {
    private let entry: JournalEntry
    private let isInHistory: Bool
    private let showsThreadAction: Bool
    private let isHighlighted: Bool
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
    @Environment(\.theme) private var theme

    /// `isInHistory` offers "Show in Timeline", which only a row History still holds can
    /// answer. `showsThreadAction` offers "Open Thread", which a page already showing the
    /// entry's thread has no use for. `isHighlighted` lights the row as selected: the
    /// search match a Rewind page was opened on. `delete` offers "Delete Entry…"
    /// only on an entry History no longer holds: an entry still in History is deleted from
    /// Timeline, where its transcript is. It returns false when the entry could not be
    /// removed. `file` offers "File Under", which files the entry under one of `topics` or,
    /// with nil, under none.
    init(
        entry: JournalEntry,
        isInHistory: Bool,
        showsThreadAction: Bool,
        isHighlighted: Bool = false,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)? = nil,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil
    ) {
        self.entry = entry
        self.isInHistory = isInHistory
        self.showsThreadAction = showsThreadAction
        self.isHighlighted = isHighlighted
        self.navigation = navigation
        self.delete = delete
        self.topics = topics
        self.file = file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            entryButton
            // A destructive action that fails must say so under the row that asked for
            // it, rather than leave the entry on screen unexplained.
            if deleteFailed {
                Text("The entry could not be deleted.")
                    .roleStyle(.meta)
                    .foregroundStyle(theme.critical.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Kit.Metrics.stampGutter + Self.gap + Self.horizontalPadding)
                    .accessibilityIdentifier("journal.entry.delete-error")
            }
        }
    }

    /// The space between the gutter, the text and the pills.
    private static let gap: CGFloat = 12
    private static let horizontalPadding: CGFloat = 12

    /// The space above and below a row's content, inside the rhythm's step.
    private static let verticalPadding: CGFloat = 8

    /// The reading face's own line height, `ascender − descender + leading` from NSFont:
    /// the box the pills centre in on the first line.
    private static let textLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: TextRole.reading.pointSize)
        return font.ascender - font.descender + font.leading
    }()

    /// The first line's baseline below the text's top, where the pills align.
    private static let textAscent: CGFloat = NSFont.systemFont(ofSize: TextRole.reading.pointSize).ascender

    private var entryButton: some View {
        Button(action: copyText) {
            ReadingRowRhythm {
                entryContent
            }
        }
        .buttonStyle(Kit.RowButtonStyle(isSelected: isHighlighted))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
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

    /// The gutter, the words and the pills, padded inside the row.
    private var entryContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
            // The copy confirmation takes the timestamp's place rather than a line
            // of its own, so a click never moves the rows below it.
            Text(timestamp)
                .monospacedDigit()
                .roleStyle(.meta)
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .opacity(showsCopied ? 0 : 1)
                .overlay(alignment: .leading) {
                    if showsCopied {
                        Kit.Pill("Copied", tone: .success)
                            .fixedSize()
                    }
                }
                .frame(width: Kit.Metrics.stampGutter, alignment: .leading)

            Text(entry.text)
                .roleStyle(.reading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The pills close the first line, as they close a list row's meta line,
            // so a marked entry is no taller than its words: they centre in the first
            // line's box, whose top meets the text's.
            if hasMarks {
                HStack(spacing: 4) {
                    if isNote {
                        Kit.Pill("Note", tone: .info)
                    }
                    if isNotSent {
                        Kit.Pill("Not sent", tone: .caution)
                    }
                    if let highlightKind {
                        Kit.Pill(highlightKind.displayName)
                    }
                }
                .fixedSize()
                .frame(height: Self.textLineHeight)
                .alignmentGuide(.firstTextBaseline) { [ascent = Self.textAscent] _ in ascent }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
    }

    // MARK: Derived

    private var timestamp: String {
        SessionsFormatters.timestamp.string(from: entry.createdAt)
    }

    private var isNote: Bool {
        entry.kind == .note
    }

    /// Only an answered send check counts: a pending one (`nil`) says nothing about the
    /// prompt yet, and a row must not claim a failure it has not seen.
    private var isNotSent: Bool {
        entry.thread?.sent == false
    }

    /// The kinds Rewind lifts into its highlights, under the same confidence bar, so a row
    /// marks exactly the entries a day's highlights would name.
    private var highlightKind: UtteranceKind? {
        JournalEntryRow.highlightKind(of: entry)
    }

    /// The kind a row marks: one of the four Rewind lifts into highlights, labelled at or
    /// above `JournalQuery.highlightConfidence`; nil for any other entry.
    static func highlightKind(of entry: JournalEntry) -> UtteranceKind? {
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

    /// The time, then the states a reader acts on and the kind the row marks, then the
    /// words. The pills are words on screen, so VoiceOver hears them as words too.
    private var accessibilityLabel: String {
        var parts = [timestamp]
        if isNote { parts.append("note") }
        if isNotSent { parts.append("not sent") }
        if let highlightKind { parts.append(highlightKind.displayName.lowercased()) }
        parts.append(entry.text)
        return parts.joined(separator: ", ")
    }

    // MARK: Copy

    /// The pill and the announcement are claims about the clipboard, so a refused write
    /// leaves the row exactly as it was.
    private func copyText() {
        guard GeneralPasteboard.copy(entry.text) != nil else { return }
        Kit.announce("Text copied to clipboard")
        resetCopyFeedbackTask?.cancel()
        withAnimation(Kit.Motion.quick(a11y)) {
            showsCopied = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: Kit.Flash.hold)
            guard !Task.isCancelled else { return }
            withAnimation(Kit.Motion.quick(a11y)) {
                showsCopied = false
            }
        }
    }

    // MARK: Delete

    /// The outcome is reported on the row that asked for it, and a removal that did not
    /// reach disk says so.
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

    /// One item per topic, the entry's current topic checked, then "No Topic". Choosing an
    /// item is an explicit request, so the checked topic files the entry again rather than
    /// unfiling it; "No Topic" is the one way out. With no topics the submenu still opens,
    /// to say why it offers nothing.
    @ViewBuilder
    private func fileUnderMenu(_ file: @escaping (UUID, String?) -> Void) -> some View {
        JournalFileUnderItems(entry: entry, topics: topics, file: file)
    }
}

/// The "File Under" submenu: one item per topic, the entry's topic checked, then "No
/// Topic". Shared by a reading row's context menu and a note page's File Under menu, so
/// both file the same way.
struct JournalFileUnderItems: View {
    private let entry: JournalEntry
    private let topics: [MemoryTopic]
    private let file: (UUID, String?) -> Void

    init(entry: JournalEntry, topics: [MemoryTopic], file: @escaping (UUID, String?) -> Void) {
        self.entry = entry
        self.topics = topics
        self.file = file
    }

    var body: some View {
        Menu("File Under") {
            JournalFileUnderChoices(entry: entry, topics: topics, file: file)
        }
        .accessibilityIdentifier("journal.entry.file")
    }
}

/// The choices a File Under menu offers, without the menu around them, for a page whose
/// own menu button is the File Under control.
struct JournalFileUnderChoices: View {
    private let entry: JournalEntry
    private let topics: [MemoryTopic]
    private let file: (UUID, String?) -> Void

    init(entry: JournalEntry, topics: [MemoryTopic], file: @escaping (UUID, String?) -> Void) {
        self.entry = entry
        self.topics = topics
        self.file = file
    }

    var body: some View {
        if topics.isEmpty {
            Button("No topics yet") {}
                .disabled(true)
        } else {
            ForEach(topics) { topic in
                Toggle(topic.name, isOn: binding(topic.id))
            }
            Divider()
            Button("No Topic") {
                file(entry.id, nil)
            }
        }
    }

    /// Reads as checked for the entry's topic; any choice files the entry under that topic,
    /// whichever way the menu says it flipped.
    private func binding(_ topicID: String) -> Binding<Bool> {
        let entry = entry
        let file = file
        return Binding(
            get: { entry.topicID == topicID },
            set: { _ in file(entry.id, topicID) }
        )
    }
}

/// Stands a reading row on a 20 pt rhythm from 44 pt: its content, centred, in the smallest
/// of 44, 64, 84, 104… points that holds it. Every row height then sits on the control
/// scale's row pitches or on the 4 pt grid, whatever line height the reading face measures
/// on this Mac, and a list of rows keeps one vertical rhythm.
private struct ReadingRowRhythm: Layout {
    /// The one-line row, the row scale's 44 pt.
    static let first: CGFloat = 44
    /// Each step past one line: one reading line of 15 pt type.
    static let step: CGFloat = 20

    static func snapped(_ height: CGFloat) -> CGFloat {
        guard height > first else { return first }
        return first + ((height - first) / step).rounded(.up) * step
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return CGSize(width: proposal.width ?? 0, height: Self.first) }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: Self.snapped(natural.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let natural = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        content.place(
            at: CGPoint(x: bounds.minX, y: (bounds.midY - natural.height / 2).rounded(.down)),
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }
}
