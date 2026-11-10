import SwiftUI
import VoiceCore

/// The three ways the Journal reads the same record of what was said.
///
/// Timeline is History as it always was: one row per dictation, newest first,
/// with the open transcript and its evidence. Rewind reads one day as runs of
/// work on one subject, and Threads reads everything said into each agent
/// session. Ordered as the segmented picker renders them.
enum JournalLens: String, CaseIterable, Hashable {
    case timeline
    case rewind
    case threads

    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .rewind: "Rewind"
        case .threads: "Threads"
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
/// The entries are cached rather than derived in `body`: History retains up to
/// 500 rows, and Rewind and Threads each group the whole list, so rebuilding it
/// on every body pass would repeat that work on every selection and keystroke.
/// Timeline reads the coordinator's rows directly, exactly as History did, so it
/// renders the same list whether or not it is hosted here.
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

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        lensContent
            .onAppear(perform: reloadEntries)
            .onChange(of: coordinator.recentSessions.map(\.id)) {
                reloadEntries()
            }
            // A binding or a send check changes a row without changing its id, and
            // the entries are copies, so a thread lands in them only through this.
            .onChange(of: coordinator.recentSessions.map(\.agentSession)) {
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
                navigation: navigation
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
                navigation: navigation
            )
            .onAppear { coordinator.refreshAgentSessions() }
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

    private func reloadEntries() {
        entries = journalEntries()
        historyIDs = Set(coordinator.recentSessions.map(\.id))
    }

    /// The one place the Journal's entries come from, so a different source
    /// changes this function and nothing that reads the entries.
    private func journalEntries() -> [JournalEntry] {
        coordinator.recentSessions.map(JournalEntry.init)
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
