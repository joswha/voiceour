import SwiftUI
import VoiceCore

/// The ways the Journal reads the same record of what was said.
///
/// Timeline is History as it always was: one row per dictation, newest first,
/// with the open transcript and its evidence. Rewind reads one day as runs of
/// work on one subject, Threads reads everything said into each agent session,
/// Topics reads everything filed under each of the user's topics, and Notes
/// lists what was saved and pasted nowhere. Ordered as the segmented picker
/// renders them.
enum JournalLens: String, CaseIterable, Hashable {
    case timeline
    case rewind
    case threads
    case topics
    case notes

    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .rewind: "Rewind"
        case .threads: "Threads"
        case .topics: "Topics"
        case .notes: "Notes"
        }
    }
}

/// What a lens asks the tab to do.
///
/// A lens shows entries and never owns the tab's state, so every move from one
/// lens to another is a request the tab carries out: the lens says where the
/// reader wants to go, and the tab is the one place that knows how to get there.
struct JournalNavigation {
    /// Switches to Timeline with this History row open.
    var showInTimeline: (UUID) -> Void
    /// Switches to Timeline filtered to this agent session.
    var showThreadInTimeline: (AgentSessionKey) -> Void
    /// Switches to Threads with this thread open.
    var openThread: (AgentSessionKey) -> Void
}

/// One move into Timeline, carried out once and then consumed.
///
/// Equatable so the History tab can react to it with `onChange`; the History
/// tab sets it back to nil after applying it, so asking for the same row twice
/// opens it twice.
enum JournalTimelineRequest: Equatable {
    /// Open this History row, with every filter cleared so it is listed.
    case row(UUID)
    /// Narrow the list to the rows bound to this agent session.
    case agentSession(AgentSessionKey)
}

/// The Journal tab. Holds the lens, builds `[JournalEntry]` once per change, and
/// hosts one lens at a time.
///
/// The entries are cached rather than derived in `body`: memory is uncapped, and
/// Rewind and Threads each group the whole list, so rebuilding it on every body
/// pass would repeat that work on every selection and keystroke. Timeline reads
/// the coordinator's rows directly, exactly as History did, so it renders the
/// same list whether or not it is hosted here.
struct ConsoleJournalTab: View {
    var coordinator: DictationCoordinator

    /// Pinned by the harness so a scene renders Rewind or Threads directly.
    @State private var lens = RenderOverrides.journalInitialLens ?? .timeline
    /// The thread Threads shows open. Kept here rather than in the lens, so a
    /// trip to Timeline and back returns to the thread the reader left.
    @State private var openThread = RenderOverrides.journalInitialThread
    /// A move into Timeline that another lens asked for and Timeline has not
    /// carried out yet.
    @State private var timelineRequest: JournalTimelineRequest?
    @State private var entries: [JournalEntry] = []
    /// The ids of the rows History still holds, so a lens offers "Show in
    /// Timeline" only for an entry Timeline can actually open.
    @State private var historyIDs: Set<UUID> = []
    /// The ids of the entries memory keeps, so Rewind offers a day's recap
    /// prompt only when the day page it points an agent at exists.
    @State private var memoryIDs: Set<UUID> = []

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        lensContent
            .onAppear {
                reloadEntries()
                coordinator.refreshAgentNotes()
            }
            // An agent saves a note whenever it is asked to, so the folder is read
            // again each time the reader moves to another lens.
            .onChange(of: lens) {
                coordinator.refreshAgentNotes()
            }
            .onChange(of: coordinator.recentSessions.map(\.id)) {
                reloadEntries()
            }
            // A binding or a send check changes a row without changing its id, and
            // the entries are copies, so a thread lands in them only through this.
            .onChange(of: coordinator.recentSessions.map(\.agentSession)) {
                reloadEntries()
            }
            // Every memory change bumps the revision, so an entry memory adds,
            // relabels or removes reaches the lenses without comparing the store.
            .onChange(of: coordinator.memoryRevision) {
                reloadEntries()
            }
    }

    @ViewBuilder
    private var lensContent: some View {
        switch lens {
        case .timeline:
            ConsoleHistoryTab(
                coordinator: coordinator,
                lens: $lens,
                request: $timelineRequest,
                navigation: navigation
            )
        case .rewind:
            JournalRewindLens(
                entries: entries,
                historyIDs: historyIDs,
                lens: $lens,
                navigation: navigation,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry,
                memoryIDs: memoryIDs,
                agentNotes: coordinator.agentNotes,
                memoryRoot: coordinator.memoryStore.root
            )
            // Both lenses name each entry's agent session and whether its prompt
            // was sent, which only a refresh pass brings up to date.
            .onAppear { coordinator.refreshAgentSessions() }
        case .threads:
            JournalThreadsLens(
                entries: entries,
                historyIDs: historyIDs,
                lens: $lens,
                openThread: $openThread,
                navigation: navigation,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry
            )
            .onAppear { coordinator.refreshAgentSessions() }
        case .topics:
            JournalTopicsLens(
                coordinator: coordinator,
                entries: entries,
                lens: $lens,
                navigation: navigation,
                delete: deleteEntry,
                agentNotes: coordinator.agentNotes,
                memoryRoot: coordinator.memoryStore.root
            )
        case .notes:
            JournalNotesLens(
                coordinator: coordinator,
                entries: entries,
                lens: $lens,
                navigation: navigation,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry
            )
        }
    }

    /// Captures the bindings rather than the view, so a lens holding this value
    /// always writes the tab's current state.
    private var navigation: JournalNavigation {
        let lens = $lens
        let request = $timelineRequest
        let openThread = $openThread
        return JournalNavigation(
            showInTimeline: { id in
                request.wrappedValue = .row(id)
                lens.wrappedValue = .timeline
            },
            showThreadInTimeline: { key in
                request.wrappedValue = .agentSession(key)
                lens.wrappedValue = .timeline
            },
            openThread: { key in
                openThread.wrappedValue = key
                lens.wrappedValue = .threads
            }
        )
    }

    /// Removes the History row and the memory entry with this id, whichever
    /// exist; false when the removal did not reach disk.
    private var deleteEntry: (UUID) async -> Bool {
        let coordinator = coordinator
        return { id in await coordinator.deleteRecentSession(id: id) }
    }

    /// Files an entry under one of the user's topics, or under none. Filing is a
    /// request to keep the entry, so the coordinator adds a History-only entry to
    /// memory first.
    private var fileEntry: (UUID, String?) -> Void {
        let coordinator = coordinator
        return { id, topicID in coordinator.fileEntry(id: id, underTopic: topicID) }
    }

    private func reloadEntries() {
        entries = journalEntries()
        historyIDs = Set(coordinator.recentSessions.map(\.id))
        memoryIDs = Set(coordinator.memoryEntries.map(\.id))
    }

    /// The one place the Journal's entries come from: every memory entry plus
    /// each History row memory does not hold, so a lens reads one list whether
    /// or not memory is on.
    private func journalEntries() -> [JournalEntry] {
        coordinator.journalEntries
    }
}

/// The first Section of every lens's Form: the segmented lens picker.
///
/// One view, so every lens puts the picker in the same place with the same
/// identifier, and switching lenses never moves the control the reader just used.
struct JournalLensHeader: View {
    @Binding private var lens: JournalLens

    init(lens: Binding<JournalLens>) {
        _lens = lens
    }

    var body: some View {
        Section {
            // The title is the control's spoken name. A second accessibility label
            // would be read after it, so the title alone names the picker.
            Picker("Journal view", selection: $lens) {
                ForEach(JournalLens.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("journal.lens")
        }
    }
}
