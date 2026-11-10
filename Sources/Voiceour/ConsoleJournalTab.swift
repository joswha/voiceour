import SwiftUI
import VoiceCore

/// The ways the Journal reads the same record of what was said.
///
/// Timeline is History: one row per dictation, newest first, with the open transcript
/// and its evidence. Rewind reads one day as runs of work on one subject, Threads reads
/// everything said into each agent session, Topics reads everything filed under each of
/// the user's topics, and Notes lists what was saved and pasted nowhere. Ordered as the
/// sidebar lists them.
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

    var symbol: String {
        switch self {
        case .timeline: "clock"
        case .rewind: "calendar"
        case .threads: "bubble.left.and.text.bubble.right"
        case .topics: "tag"
        case .notes: "note.text"
        }
    }
}

/// What a lens asks the tab to do.
///
/// A lens shows entries and never owns the tab's state, so every move from one lens to
/// another is a request the tab carries out: the lens says where the reader wants to
/// go, and the tab is the one place that knows how to get there.
struct JournalNavigation {
    /// Switches to Timeline with this History row selected.
    var showInTimeline: (UUID) -> Void
    /// Switches to Timeline filtered to this agent session.
    var showThreadInTimeline: (AgentSessionKey) -> Void
    /// Switches to Threads with this thread selected.
    var openThread: (AgentSessionKey) -> Void
}

/// One move into Timeline, carried out once and then consumed.
///
/// Equatable so Timeline can react to it with `onChange`; Timeline sets it back to nil
/// after applying it, so asking for the same row twice selects it twice.
enum JournalTimelineRequest: Equatable {
    /// Select this History row, with every filter cleared so it is listed.
    case row(UUID)
    /// Narrow the list to the rows bound to this agent session.
    case agentSession(AgentSessionKey)
}

/// The Journal tab: a dim sidebar of lenses and recent threads beside the lens on screen,
/// all on the theme's ground.
///
/// The tab holds the lens, builds `[JournalEntry]` once per change, and hosts one lens
/// at a time. The entries are cached rather than derived in `body`: memory is uncapped,
/// and Rewind and Threads each group the whole list, so rebuilding it on every body pass
/// would repeat that work on every selection and keystroke. Timeline reads the
/// coordinator's rows directly.
struct ConsoleJournalTab: View {
    var coordinator: DictationCoordinator

    /// Pinned by the harness so a scene renders one lens directly.
    @State private var lens = RenderOverrides.journalInitialLens ?? .timeline
    /// The thread Threads shows. Kept here rather than in the lens, so a trip to Timeline
    /// and back returns to the thread the reader left, and the sidebar can mark it.
    @State private var openThread = RenderOverrides.journalInitialThread
    /// A move into Timeline that another lens asked for and Timeline has not carried out.
    @State private var timelineRequest: JournalTimelineRequest?
    @State private var entries: [JournalEntry] = []
    /// The ids of the rows History still holds, so a lens offers "Show in Timeline" only
    /// for an entry Timeline can actually open.
    @State private var historyIDs: Set<UUID> = []
    /// The ids of the entries memory keeps, so Rewind and Threads offer a prompt only when
    /// the day or thread page it points an agent at exists.
    @State private var memoryIDs: Set<UUID> = []
    /// Every thread, newest first: the sidebar's count and its recent threads.
    @State private var threads: [JournalThread] = []
    @State private var noteCount = 0
    /// The New Topic draft, kept here so its typed text survives a trip to another lens.
    @State private var topicDraft = JournalTopicDraft()
    /// True while the tab is narrower than `Kit.Metrics.railBelow`, so the sidebar folds
    /// to its rail of glyphs and the page keeps its reading width.
    @State private var isNarrow = false

    /// How many threads the sidebar lists under Recent Threads.
    private static let recentThreadLimit = 5

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Kit.Screen {
            HStack(spacing: 0) {
                JournalSidebar(
                    lens: lens,
                    counts: counts,
                    recentThreads: Array(threads.prefix(Self.recentThreadLimit)),
                    openThread: lens == .threads ? openThread : nil,
                    select: { lens = $0 },
                    open: navigation.openThread
                )
                .environment(\.kitCompactControls, isNarrow)

                lensContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < Kit.Metrics.railBelow
        } action: { narrow in
            isNarrow = narrow
        }
        .onAppear {
            reloadEntries()
            coordinator.refreshAgentNotes()
            // After the reload, so the request names a thread the lens can find.
            openRequestedThread()
        }
        // The menu's thread line asks while the console may already be open on this tab,
        // so the request is read on change as well as on appear.
        .onChange(of: coordinator.pendingJournalThread) {
            openRequestedThread()
        }
        // An agent saves a note whenever it is asked to, so the folder is read again each
        // time the reader moves to another lens.
        .onChange(of: lens) {
            coordinator.refreshAgentNotes()
        }
        // The open thread's page shows the outcome its agent saved, which may have landed
        // since the folder was last read.
        .onChange(of: openThread) {
            if openThread != nil {
                coordinator.refreshAgentNotes()
            }
        }
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            reloadEntries()
        }
        // A binding or a send check changes a row without changing its id, and the
        // entries are copies, so a thread lands in them only through this.
        .onChange(of: coordinator.recentSessions.map(\.agentSession)) {
            reloadEntries()
        }
        // Every memory change bumps the revision, so an entry memory adds, relabels or
        // removes reaches the lenses without comparing the store.
        .onChange(of: coordinator.memoryRevision) {
            reloadEntries()
        }
    }

    @ViewBuilder
    private var lensContent: some View {
        switch lens {
        case .timeline:
            JournalTimelineLens(
                coordinator: coordinator,
                request: $timelineRequest,
                navigation: navigation
            )
        case .rewind:
            JournalRewindLens(
                entries: entries,
                historyIDs: historyIDs,
                navigation: navigation,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry,
                memoryIDs: memoryIDs,
                agentNotes: coordinator.agentNotes,
                memoryRoot: coordinator.memoryStore.root
            )
            // Both lenses name each entry's agent session and whether its prompt was sent,
            // which only a refresh pass brings up to date.
            .onAppear { coordinator.refreshAgentSessions() }
        case .threads:
            JournalThreadsLens(
                entries: entries,
                historyIDs: historyIDs,
                openThread: $openThread,
                navigation: navigation,
                bindingEnabled: coordinator.settings.agentSessionBindingEnabled,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry,
                agentNotes: coordinator.agentNotes,
                memoryIDs: memoryIDs,
                memoryRoot: coordinator.memoryStore.root
            )
            .onAppear { coordinator.refreshAgentSessions() }
        case .topics:
            JournalTopicsLens(
                coordinator: coordinator,
                entries: entries,
                navigation: navigation,
                delete: deleteEntry,
                agentNotes: coordinator.agentNotes,
                memoryRoot: coordinator.memoryStore.root,
                draft: topicDraft
            )
        case .notes:
            JournalNotesLens(
                coordinator: coordinator,
                entries: entries,
                navigation: navigation,
                delete: deleteEntry,
                topics: coordinator.memoryTopics,
                file: fileEntry
            )
        }
    }

    /// What each lens holds, as the sidebar counts it. Rewind counts nothing: its list
    /// is of days, and a day count beside item counts would read as one more of them.
    private var counts: [JournalLens: Int] {
        [
            .timeline: coordinator.recentSessions.count,
            .threads: threads.count,
            .topics: coordinator.memoryTopics.count,
            .notes: noteCount,
        ]
    }

    /// Captures the bindings rather than the view, so a lens holding this value always
    /// writes the tab's current state.
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

    /// Removes the History row and the memory entry with this id, whichever exist; false
    /// when the removal did not reach disk.
    private var deleteEntry: (UUID) async -> Bool {
        let coordinator = coordinator
        return { id in await coordinator.deleteRecentSession(id: id) }
    }

    /// Files an entry under one of the user's topics, or under none. Filing is a request
    /// to keep the entry, so the coordinator adds a History-only entry to memory first.
    private var fileEntry: (UUID, String?) -> Void {
        let coordinator = coordinator
        return { id, topicID in coordinator.fileEntry(id: id, underTopic: topicID) }
    }

    private func reloadEntries() {
        entries = coordinator.journalEntries
        historyIDs = Set(coordinator.recentSessions.map(\.id))
        memoryIDs = Set(coordinator.memoryEntries.map(\.id))
        threads = JournalQuery.threads(in: entries)
        noteCount = entries.count(where: { $0.kind == .note })
    }

    /// Carries out the menu's request through the same move a lens makes, then consumes
    /// it, so asking for the same thread again opens it again. A key no entry carries
    /// lands on Threads on its newest thread: the lens selects past a thread that is gone.
    private func openRequestedThread() {
        guard let key = coordinator.pendingJournalThread else { return }
        coordinator.pendingJournalThread = nil
        navigation.openThread(key)
    }
}

/// The Journal's sidebar: the five lenses with what each holds, then the agent sessions
/// most recently dictated into.
///
/// Recent threads is the Journal's shortcut into delegated work: the sessions a reader
/// most likely wants to check on are one click from any lens. A session one of whose
/// dictations never reached its agent carries the loud caution badge instead of a quiet
/// count, because it is the one that needs the reader.
struct JournalSidebar: View {
    private let lens: JournalLens
    private let counts: [JournalLens: Int]
    private let recentThreads: [JournalThread]
    private let openThread: AgentSessionKey?
    private let select: (JournalLens) -> Void
    private let open: (AgentSessionKey) -> Void

    init(
        lens: JournalLens,
        counts: [JournalLens: Int],
        recentThreads: [JournalThread],
        openThread: AgentSessionKey?,
        select: @escaping (JournalLens) -> Void,
        open: @escaping (AgentSessionKey) -> Void
    ) {
        self.lens = lens
        self.counts = counts
        self.recentThreads = recentThreads
        self.openThread = openThread
        self.select = select
        self.open = open
    }

    var body: some View {
        Kit.Sidebar {
            ForEach(JournalLens.allCases, id: \.self) { option in
                Kit.SidebarItem(
                    option.label,
                    systemImage: option.symbol,
                    count: counts[option],
                    isSelected: option == lens
                ) {
                    select(option)
                }
                .accessibilityIdentifier("journal.lens.\(option.rawValue)")
            }

            if !recentThreads.isEmpty {
                Kit.SidebarSection("Recent threads")
                ForEach(recentThreads) { thread in
                    threadItem(thread)
                }
            }
        }
    }

    /// The item keeps the label it has always had — the title, the agent, and "not
    /// sent" while a dictation was not — so VoiceOver names the agent the glyph cannot.
    private func threadItem(_ thread: JournalThread) -> some View {
        let title = JournalThreadsLens.title(of: thread)
        let isNotSent = thread.notSentCount > 0
        return Kit.SidebarItem(
            title,
            systemImage: "terminal",
            isSelected: thread.id == openThread,
            attention: isNotSent ? .caution : nil
        ) {
            open(thread.id)
        }
        .help(isNotSent ? "\(title). A dictation in this session was not sent" : title)
        .accessibilityLabel(
            isNotSent
                ? "\(title), \(thread.ref.agent.displayName), not sent"
                : "\(title), \(thread.ref.agent.displayName)"
        )
        .accessibilityIdentifier("journal.sidebar.thread")
    }
}
