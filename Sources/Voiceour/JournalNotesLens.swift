import SwiftUI
import VoiceCore
import VoiceMac

/// Notes: every note the user took, newest day first, with the control that takes one.
///
/// A note is saved to memory and pasted nowhere, so this lens is the one place its
/// words can be read back; the button that starts a note heads the list so the reader
/// who comes looking for notes also finds how to make one. The search covers every
/// note rather than one day, since a reader who types a phrase rarely knows which day
/// they noted it. The page column reads the selected note whole, with what can be done
/// to it.
///
/// The day groups are cached in state and rebuilt on appear and when the entries or
/// the query changes, never in `body`: the memory store is uncapped, and a body pass
/// that re-filtered and re-bucketed it would run on every keystroke and every state
/// change of the recording the button drives.
struct JournalNotesLens: View {
    private let coordinator: DictationCoordinator
    private let entries: [JournalEntry]
    private let navigation: JournalNavigation
    /// Removes a note from memory; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?
    /// The topics the page's File Under menu offers.
    private let topics: [MemoryTopic]
    /// Files a note under a topic or under none; nil offers no menu.
    private let file: ((UUID, String?) -> Void)?

    @State private var searchText = ""
    /// Every note before the search narrows them, newest first, by id: the page's lookup
    /// and the order a removed note's successor is taken from.
    @State private var notes: [UUID: JournalEntry] = [:]
    @State private var noteOrder: [UUID] = []
    @State private var noteDays: [NoteDay] = []
    /// The notes the query matches, flattened newest first: the order the arrow keys walk.
    @State private var matchOrder: [UUID] = []

    @State private var selectedID: UUID?
    /// The row an arrow key selected, scrolled into view.
    @State private var reveal: UUID?

    @State private var pendingDeletion: UUID?
    /// True while a confirmed delete is in flight, so a second confirmation cannot
    /// start a second removal of the same note.
    @State private var isDeleting = false
    @State private var deleteFailed = false
    @State private var flash = Kit.Flash()

    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    @Environment(\.theme) private var theme
    private var a11y = A11y()

    init(
        coordinator: DictationCoordinator,
        entries: [JournalEntry],
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)?,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.entries = entries
        self.navigation = navigation
        self.delete = delete
        self.topics = topics
        self.file = file
    }

    var body: some View {
        content
            .onAppear(perform: reloadNotes)
            .onChange(of: entries) {
                reloadNotes()
            }
            .onChange(of: searchText) {
                reloadNotes()
            }
            .onChange(of: selectedID) {
                deleteFailed = false
                flash.dismiss()
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: deletionConfirmationPresented,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { id in
                Button("Delete Entry", role: .destructive) {
                    confirmDelete(id)
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { _ in
                Text("The entry is removed from this Mac's memory. Text you already pasted is not affected.")
            }
    }

    /// With no note at all the lens holds nothing to list or read, so one empty state
    /// spans both columns and still offers the button its words point at.
    @ViewBuilder
    private var content: some View {
        if noteOrder.isEmpty {
            noNotes
        } else {
            Kit.Split {
                listColumn
            } page: {
                pageColumn
            }
        }
    }

    // MARK: Take a note

    /// True while the recording in flight is a note, so the same button finishes it.
    private var isRecordingNote: Bool {
        coordinator.state == .recording && coordinator.captureIntent == .note
    }

    /// A dictation in flight owns the recorder, so the button waits for it rather than
    /// offering a start the coordinator would refuse.
    private var isOtherSessionBusy: Bool {
        !isRecordingNote && (coordinator.state.isActive || coordinator.isProcessingInFlight)
    }

    private var takeNoteTitle: String {
        isRecordingNote ? "Finish Note" : "Take a Note"
    }

    /// Acts on the title the reader saw: a "Finish Note" pressed after the recording
    /// already ended asks to stop, which the coordinator ignores, rather than starting a
    /// second note.
    private func takeOrFinishNote(recordingNote: Bool) {
        if recordingNote {
            coordinator.stopAndProcess()
        } else {
            coordinator.startNote()
        }
    }

    private var takeNoteButton: some View {
        let recordingNote = isRecordingNote

        return Kit.Button(
            takeNoteTitle,
            systemImage: recordingNote ? "stop.fill" : "mic.fill",
            prominence: .primary
        ) {
            takeOrFinishNote(recordingNote: recordingNote)
        }
        .disabled(isOtherSessionBusy)
        .help(recordingNote ? "Stop recording and save the note" : "Record a note that is saved here")
        .accessibilityIdentifier("journal.notes.take")
    }

    private var noNotes: some View {
        let recordingNote = isRecordingNote

        return Kit.EmptyState(
            systemImage: "note.text",
            title: "No notes yet",
            message: "Take a note from here or from the menu, or say \u{201C}note to self\u{201D} "
                + "at the start of a dictation.",
            actionTitle: takeNoteTitle,
            actionIdentifier: "journal.notes.take",
            action: { takeOrFinishNote(recordingNote: recordingNote) }
        )
        .disabled(isOtherSessionBusy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var listSubtitle: String {
        let total = noteOrder.count
        guard !query.isEmpty else { return Self.counted(total, "note", "notes") }
        return "\(matchOrder.count) of \(Self.counted(total, "note", "notes")) match"
    }

    private var listColumn: some View {
        Kit.ListColumn(
            "Notes",
            subtitle: listSubtitle,
            reveal: reveal.map { AnyHashable($0) },
            focus: $isListFocused,
            onMove: move
        ) {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                takeNoteButton
                Kit.SearchField(
                    "Search notes",
                    text: $searchText,
                    identifier: "journal.notes.search",
                    clearIdentifier: "journal.notes.search.clear",
                    focus: $isSearchFocused,
                    onSubmit: selectFirstMatch
                )
            }
        } content: {
            if noteDays.isEmpty {
                noMatches
            } else {
                ForEach(noteDays) { noteDay in
                    Section {
                        ForEach(noteDay.entries) { entry in
                            noteRow(entry)
                                .id(entry.id)
                        }
                    } header: {
                        Kit.GroupHeader(
                            SessionsFormatters.dayHeader.string(from: noteDay.day),
                            detail: String(noteDay.entries.count)
                        )
                    }
                }

                JournalCaption(
                    "Or say \u{201C}note to self\u{201D} at the start of a dictation. "
                        + "A note is saved here and pasted nowhere."
                )
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .padding(.top, VoiceourMetrics.Space.lg)
            }
        }
    }

    /// The query is the only thing that can empty the list, so it is echoed and
    /// offered back; the page keeps the note it shows.
    private var noMatches: some View {
        Kit.EmptyState(
            systemImage: "magnifyingglass",
            title: "No note matches \u{201C}\(query)\u{201D}",
            message: "Search runs over every note's text and the agent session it was taken in.",
            actionTitle: "Clear Search",
            actionIdentifier: "journal.notes.no-matches.clear",
            action: { searchText = "" }
        )
        .frame(maxWidth: .infinity)
        .padding(.top, VoiceourMetrics.Space.xl + VoiceourMetrics.Space.sm)
    }

    private func noteRow(_ entry: JournalEntry) -> some View {
        let stamp = SessionsFormatters.timestamp.string(from: entry.createdAt)
        let isNotSent = entry.thread?.sent == false
        let kind = JournalEntryRow.highlightKind(of: entry)

        return Kit.PreviewRow(entry.text, isSelected: entry.id == selectedID) {
            select(entry.id)
        } meta: {
            Text(stamp)
                .monospacedDigit()
            if let thread = entry.thread {
                Text(Self.threadTitle(thread))
                    .truncationMode(.tail)
            }
        } marks: {
            if isNotSent {
                Kit.Pill("Not sent", tone: .caution)
            }
            if let kind {
                Kit.Pill(Kit.Pill.sentence(kind.displayName))
            }
        }
        .accessibilityLabel(Self.accessibilityLabel(stamp: stamp, isNotSent: isNotSent, kind: kind, text: entry.text))
        // The page's actions, on the row too, so a reader can act on a note without
        // opening it first: the same commands a reading row's menu offers.
        .contextMenu {
            Button("Copy Text") {
                copy(entry)
            }
            if let thread = entry.thread {
                Button("Open Thread") {
                    navigation.openThread(thread.key)
                }
            }
            if let file {
                JournalFileUnderItems(entry: entry, topics: topics, file: file)
            }
            if delete != nil {
                Button("Delete Entry\u{2026}", role: .destructive) {
                    select(entry.id)
                    deleteFailed = false
                    pendingDeletion = entry.id
                }
            }
        }
    }

    /// The same words `JournalEntryRow` speaks for a note, so a flow that counts
    /// ", note, " finds every note row however it is drawn.
    private static func accessibilityLabel(stamp: String, isNotSent: Bool, kind: UtteranceKind?, text: String) -> String
    {
        var parts = [stamp, "note"]
        if isNotSent { parts.append("not sent") }
        if let kind { parts.append(kind.displayName.lowercased()) }
        parts.append(text)
        return parts.joined(separator: ", ")
    }

    /// A press also gives the list focus, so the arrow keys move on from the row the
    /// reader clicked.
    private func select(_ id: UUID) {
        selectedID = id
        isListFocused = true
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let target = Self.step(direction, from: selectedID, in: matchOrder) else { return }
        selectedID = target
        reveal = target
    }

    /// Return in the search field opens the newest match and hands the arrow keys to
    /// the list.
    private func selectFirstMatch() {
        guard let first = matchOrder.first else { return }
        selectedID = first
        reveal = first
        isListFocused = true
    }

    // MARK: Page

    @ViewBuilder
    private var pageColumn: some View {
        if let note = selectedID.flatMap({ notes[$0] }) {
            page(note)
                .kitToast(flash, identifier: "journal.notes.copied")
        } else {
            Kit.EmptyState(
                systemImage: "note.text",
                title: "No note selected",
                message: "Select a note to read it, copy it or file it under a topic."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func page(_ note: JournalEntry) -> some View {
        let isNotSent = note.thread?.sent == false
        let kind = JournalEntryRow.highlightKind(of: note)

        return Kit.PageColumn(identity: AnyHashable(note.id)) {
            Kit.Button("Copy", systemImage: "doc.on.doc", prominence: .primary) {
                copy(note)
            }
            .help("Copy the note's text")
            .accessibilityIdentifier("journal.notes.copy")

            if let file {
                Kit.MenuButton("File Under", systemImage: "tag", identifier: "journal.entry.file") {
                    JournalFileUnderChoices(entry: note, topics: topics, file: file)
                }
            }

            if let thread = note.thread {
                Kit.Button("Open Thread", systemImage: "bubble.left.and.text.bubble.right") {
                    navigation.openThread(thread.key)
                }
                .help("Open the agent session this note was taken in")
                .accessibilityIdentifier("journal.notes.thread")
            }

            if delete != nil {
                Kit.Button("Delete\u{2026}", systemImage: "trash", prominence: .destructive) {
                    deleteFailed = false
                    pendingDeletion = note.id
                }
                .disabled(isDeleting)
                .help("Delete this note from memory")
                .accessibilityIdentifier("journal.notes.delete")
            }
        } content: {
            Kit.PageHeader(
                kicker: SessionsFormatters.dayHeader.string(from: note.createdAt)
                    + " at " + SessionsFormatters.timestamp.string(from: note.createdAt),
                title: "Note",
                meta: note.thread.map(Self.threadTitle) ?? "Saved to memory. Nothing was pasted or copied."
            ) {
                if isNotSent || kind != nil {
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        if isNotSent {
                            Kit.Pill("Not sent", tone: .caution)
                        }
                        if let kind {
                            Kit.Pill(Kit.Pill.sentence(kind.displayName))
                        }
                    }
                }
            }

            Kit.Card {
                Text(note.text)
                    .roleStyle(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    // Keep mouse selection while exposing the text once, not both the
                    // native selection wrapper and its identical accessibility child.
                    .accessibilityRepresentation { Text(note.text) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A destructive action that fails must say so on the page that asked for
            // it, rather than leave the note on screen unexplained.
            if deleteFailed {
                JournalCaption("The entry could not be deleted.", color: theme.critical.text)
                    .accessibilityIdentifier("journal.entry.delete-error")
            }
        }
    }

    /// The toast is a claim about the clipboard, so a refused write shows and says
    /// nothing.
    private func copy(_ note: JournalEntry) {
        guard GeneralPasteboard.copy(note.text) != nil else { return }
        flash.show("Note copied to clipboard", animation: Kit.Motion.quick(a11y))
    }

    // MARK: Delete

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    /// The reload that follows a removal moves the selection to the note that took its
    /// place; a removal that did not reach disk says so on the page.
    private func confirmDelete(_ id: UUID) {
        pendingDeletion = nil
        guard let delete, !isDeleting else { return }
        deleteFailed = false
        isDeleting = true
        Task {
            let isDeleted = await delete(id)
            isDeleting = false
            deleteFailed = !isDeleted
        }
    }

    // MARK: Derived data

    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds the day groups from the notes the query matches, newest first, with
    /// the id breaking a tie so two notes saved in the same instant keep one order.
    /// The selection is checked against every note, so a query that hides it keeps it
    /// on the page; a note that is gone hands the selection to the note that took its
    /// place.
    private func reloadNotes() {
        let all = entries.filter { $0.kind == .note }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let previousOrder = noteOrder
        noteOrder = all.map(\.id)
        notes = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let matches = JournalQuery.matches(in: all, query: query)
        matchOrder = matches.map(\.id)

        let calendar = self.calendar
        var grouped: [NoteDay] = []
        for entry in matches {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = grouped.indices.last, grouped[last].day == day {
                grouped[last].entries.append(entry)
            } else {
                grouped.append(NoteDay(day: day, entries: [entry]))
            }
        }
        noteDays = grouped

        if let selected = selectedID {
            if notes[selected] == nil {
                selectedID = Self.successor(at: previousOrder.firstIndex(of: selected), in: noteOrder)
            }
        } else {
            selectedID = matchOrder.first
        }
    }

    /// The row an arrow key lands on: the neighbour in `direction`, the first row when
    /// nothing listed is selected, nil past either end.
    private static func step(_ direction: MoveCommandDirection, from current: UUID?, in ids: [UUID]) -> UUID? {
        let offset: Int
        switch direction {
        case .up: offset = -1
        case .down: offset = 1
        default: return nil
        }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let target = index + offset
        return ids.indices.contains(target) ? ids[target] : nil
    }

    /// The note that took a removed note's place: the one now at its index, else the
    /// new last note; nil when no note is left.
    private static func successor(at index: Int?, in ids: [UUID]) -> UUID? {
        guard let last = ids.indices.last else { return nil }
        guard let index else { return ids.first }
        return ids[min(index, last)]
    }

    // MARK: Text

    /// The agent session a note was taken in, named the way Timeline names a bound
    /// row: "<Agent> · <title>", else "<Agent> · <folder name>", else "<Agent> session".
    private static func threadTitle(_ thread: JournalThreadRef) -> String {
        guard let name = thread.title ?? thread.project else { return "\(thread.agent.displayName) session" }
        return "\(thread.agent.displayName) \u{00B7} \(name)"
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

/// One day of notes, newest first.
private struct NoteDay: Identifiable {
    let day: Date
    var entries: [JournalEntry]
    var id: Date { day }
}
