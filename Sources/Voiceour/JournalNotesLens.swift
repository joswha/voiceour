import SwiftUI
import VoiceCore

/// Notes: every note the user took, newest day first, with the control that takes one.
///
/// A note is saved to memory and pasted nowhere, so this lens is the one place its
/// words can be read back; the button that starts a note sits on the same page so the
/// reader who comes looking for notes also finds how to make one. The search covers
/// every note rather than one day, since a reader who types a phrase rarely knows
/// which day they noted it.
///
/// The day groups are cached in state and rebuilt on appear and when the entries or
/// the query changes, never in `body`: the memory store is uncapped, and a body pass
/// that re-filtered and re-bucketed it would run on every keystroke and every state
/// change of the recording the button drives.
struct JournalNotesLens: View {
    private let coordinator: DictationCoordinator
    private let entries: [JournalEntry]
    private let lens: Binding<JournalLens>
    private let navigation: JournalNavigation
    /// Removes a note from memory; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?
    /// The topics a note's "File Under" submenu offers.
    private let topics: [MemoryTopic]
    /// Files a note under a topic or under none; nil offers no submenu.
    private let file: ((UUID, String?) -> Void)?

    @State private var searchText = ""
    /// Whether any note exists before the search narrows them, so an empty store and
    /// a search that matches nothing say different things.
    @State private var hasNotes = false
    @State private var noteDays: [NoteDay] = []

    init(
        coordinator: DictationCoordinator,
        entries: [JournalEntry],
        lens: Binding<JournalLens>,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)?,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.entries = entries
        self.lens = lens
        self.navigation = navigation
        self.delete = delete
        self.topics = topics
        self.file = file
    }

    var body: some View {
        Form {
            JournalLensHeader(lens: lens)

            Section {
                takeNoteRow
            }

            if hasNotes {
                Section {
                    searchRow
                }

                if noteDays.isEmpty {
                    Section {
                        noMatches
                    }
                } else {
                    ForEach(noteDays) { noteDay in
                        Section(SessionsFormatters.dayHeader.string(from: noteDay.day)) {
                            LazyVStack(spacing: Self.rowSpacing) {
                                ForEach(noteDay.entries) { entry in
                                    entryRow(entry)
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text(
                            "Take a note from here or from the menu, or say \u{201C}note to self\u{201D} "
                                + "at the start of a dictation."
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadNotes)
        .onChange(of: entries) {
            reloadNotes()
        }
        .onChange(of: searchText) {
            reloadNotes()
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

    private var takeNoteRow: some View {
        let recordingNote = isRecordingNote
        let title = recordingNote ? "Finish Note" : "Take a Note"
        let help = recordingNote ? "Stop recording and save the note" : "Record a note that is saved here"

        return VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Button {
                // Acts on the title the reader saw: a "Finish Note" tapped after the
                // recording already ended asks to stop, which the coordinator ignores,
                // rather than starting a second note.
                if recordingNote {
                    coordinator.stopAndProcess()
                } else {
                    coordinator.startNote()
                }
            } label: {
                Text(title)
            }
            .disabled(isOtherSessionBusy)
            .help(help)
            .accessibilityIdentifier("journal.notes.take")

            ConsoleCaption(
                "Or say \u{201C}note to self\u{201D} at the start of a dictation. "
                    + "A note is saved here and pasted nowhere."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Search

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRow: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search notes", text: $searchText)
                .accessibilityIdentifier("journal.notes.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(
                            width: VoiceourMetrics.Control.mini,
                            height: VoiceourMetrics.Control.mini
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("journal.notes.search.clear")
            }
        }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Text("No note matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over every note's text and the agent session it was taken in.")
        } actions: {
            Button("Clear Search") { searchText = "" }
                .accessibilityIdentifier("journal.notes.no-matches.clear")
        }
    }

    // MARK: Rows

    /// A note never has a History row, so the row offers neither Show in Timeline nor
    /// History's delete, and "Delete Entry…" removes it from memory instead.
    private func entryRow(_ entry: JournalEntry) -> some View {
        JournalEntryRow(
            entry: entry,
            isInHistory: false,
            showsThreadAction: true,
            navigation: navigation,
            delete: delete,
            topics: topics,
            file: file
        )
    }

    // MARK: Derived data

    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds the day groups from the notes the query matches, newest first, with
    /// the id breaking a tie so two notes saved in the same instant keep one order.
    private func reloadNotes() {
        let notes = entries.filter { $0.kind == .note }
        hasNotes = !notes.isEmpty

        let matches = JournalQuery.matches(in: notes, query: query).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

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
    }

    // MARK: Text

    private static let rowSpacing = VoiceourMetrics.Space.lg + VoiceourMetrics.Space.xs
}

/// One day of notes, newest first.
private struct NoteDay: Identifiable {
    let day: Date
    var entries: [JournalEntry]
    var id: Date { day }
}
