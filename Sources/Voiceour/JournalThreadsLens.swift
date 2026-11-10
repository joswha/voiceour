import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Threads: every agent session the user dictated into, listed by the project folder
/// the session ran in and read as one page each.
///
/// The list names each session and the page reads it. The page leads with what the
/// session's own agent reported about the work, because that answer is what a reader
/// comes back for; then everything said into it, oldest first, because a session is
/// read the way it was spoken. Its id and folder sit folded under Details, because
/// they identify the session for a machine more than for the reader.
struct JournalThreadsLens: View {
    private let entries: [JournalEntry]
    private let historyIDs: Set<UUID>
    /// The tab owns which thread is selected, so another lens or the sidebar can open
    /// one and the choice survives a lens switch.
    @Binding private var openThread: AgentSessionKey?
    private let navigation: JournalNavigation
    /// Whether new dictations link to agent sessions; picks what the empty lens tells
    /// the reader to do, since with linking on the setting is no longer the next step.
    private let bindingEnabled: Bool
    /// Removes an entry History no longer holds; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?
    /// The topics an entry's "File Under" submenu offers.
    private let topics: [MemoryTopic]
    /// Files an entry under a topic or under none; nil offers no submenu.
    private let file: ((UUID, String?) -> Void)?
    /// Every note agents saved under `agents/`; the selected thread shows the ones that name it.
    private let agentNotes: [AgentNote]
    /// The ids of the entries memory keeps: a thread's page exists only when it holds
    /// one of them, so the outcome prompt that points an agent at it is offered only then.
    private let memoryIDs: Set<UUID>
    /// The memory folder the outcome prompt points an agent at; nil offers no prompt.
    private let memoryRoot: URL?

    @State private var searchText = ""
    /// Every thread the entries carry, newest first, whatever the query: the page looks
    /// its thread up here, so a search that hides the selected row keeps its page.
    @State private var allThreads: [JournalThread] = []
    /// The project groups for the current entries and query, cached as a snapshot and
    /// rebuilt only when either changes: grouping walks every entry, and a body pass
    /// happens on every selection and copy confirmation.
    @State private var groups: [JournalProjectGroup] = []
    /// The listed threads in reading order, which the arrow keys walk.
    @State private var order: [AgentSessionKey] = []
    /// The selected thread and what its page shows, refreshed when the selection, the
    /// entries, History's or memory's ids, or the agent notes change, never in `body`.
    @State private var selected: JournalThread?
    @State private var pageLines: [PageLine] = []
    @State private var selectedIsInTimeline = false
    @State private var selectedIsInMemory = false
    /// The agent notes whose `session` names the selected thread, newest modification first.
    @State private var openThreadNotes: [AgentNote] = []
    /// Whether the page's Details fold is open; shut again whenever another thread is
    /// selected, so every page starts with the same reading.
    @State private var showsDetails = false
    /// The row a key press or another lens selected, scrolled into view.
    @State private var reveal: AgentSessionKey?
    @State private var flash = Kit.Flash()
    @FocusState private var listFocused: Bool

    private var a11y = A11y()

    init(
        entries: [JournalEntry],
        historyIDs: Set<UUID>,
        openThread: Binding<AgentSessionKey?>,
        navigation: JournalNavigation,
        bindingEnabled: Bool,
        delete: ((UUID) async -> Bool)? = nil,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil,
        agentNotes: [AgentNote] = [],
        memoryIDs: Set<UUID> = [],
        memoryRoot: URL? = nil
    ) {
        self.entries = entries
        self.historyIDs = historyIDs
        self._openThread = openThread
        self.navigation = navigation
        self.bindingEnabled = bindingEnabled
        self.delete = delete
        self.topics = topics
        self.file = file
        self.agentNotes = agentNotes
        self.memoryIDs = memoryIDs
        self.memoryRoot = memoryRoot
    }

    var body: some View {
        content
            .onAppear {
                reload()
                reveal = openThread
            }
            .onDisappear {
                flash.dismiss()
            }
            .onChange(of: entries) {
                reload()
            }
            .onChange(of: searchText) {
                regroup()
            }
            .onChange(of: openThread) {
                showsDetails = false
                reveal = openThread
                refreshPage()
            }
            .onChange(of: agentNotes) {
                refreshNotes()
            }
            .onChange(of: historyIDs) {
                refreshPage()
            }
            .onChange(of: memoryIDs) {
                refreshPage()
            }
    }

    /// With no thread at all the lens holds nothing to list or read, so one empty state
    /// spans both columns. A query never takes this branch: it narrows the list only.
    @ViewBuilder
    private var content: some View {
        if allThreads.isEmpty && query.isEmpty {
            noThreads
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Kit.Split {
                list
            } page: {
                page
                    .kitToast(flash, identifier: "journal.threads.copied")
            }
        }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every date on this page is bucketed and spelled in one calendar, the one
    /// the harness pins, so a day boundary never depends on this Mac's settings.
    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// The calendar the memory folder writes its pages in, so the outcome prompt names
    /// the day the way the thread's page does, whatever the user's calendar setting.
    private var memoryCalendar: Calendar {
        DictationCoordinator.memoryCalendar(timeZone: calendar.timeZone)
    }

    // MARK: Derived data

    /// Rebuilds the threads and groups, then keeps the selection on a thread that exists.
    ///
    /// "Gone" means no entry carries the thread any more, not that the query hides it: a
    /// search narrows what is listed, and clearing it must bring the reader back to the
    /// page they had open. An empty entry list closes nothing, because the tab may hand
    /// this lens its entries after the lens appears, and a thread named before they
    /// arrive (by another lens or by the harness) must survive that first pass.
    private func reload() {
        let previousOrder = order
        allThreads = JournalQuery.threads(in: entries)
        regroup()

        if let open = openThread, !entries.isEmpty, !allThreads.contains(where: { $0.id == open }) {
            openThread = successor(of: open, in: previousOrder) ?? order.first
        }
        refreshPage()
    }

    /// Regroups the threads the query matches. A query that hides the selected thread
    /// keeps it selected; with nothing selected, the newest listed thread is.
    private func regroup() {
        let threads =
            query.isEmpty
            ? allThreads
            : JournalQuery.threads(in: JournalQuery.matches(in: entries, query: query))
        groups = JournalQuery.projectGroups(of: threads)
        order = groups.flatMap { $0.threads.map(\.id) }
        if openThread == nil, let first = order.first {
            openThread = first
        }
    }

    /// The thread that took a vanished thread's place in the list: the next one that
    /// is still listed, else the previous one.
    private func successor(of key: AgentSessionKey, in previousOrder: [AgentSessionKey]) -> AgentSessionKey? {
        guard let index = previousOrder.firstIndex(of: key) else { return nil }
        let listed = Set(order)
        return previousOrder[(index + 1)...].first { listed.contains($0) }
            ?? previousOrder[..<index].last { listed.contains($0) }
    }

    /// Looks the selected thread up and builds what its page shows.
    private func refreshPage() {
        let thread = openThread.flatMap { key in allThreads.first { $0.id == key } }
        selected = thread
        pageLines = thread.map { Self.lines(of: $0, calendar: calendar) } ?? []
        selectedIsInTimeline = thread?.entries.contains { historyIDs.contains($0.id) } ?? false
        selectedIsInMemory = thread?.entries.contains { memoryIDs.contains($0.id) } ?? false
        refreshNotes()
    }

    /// Picks the notes for the selected thread; none while no thread is selected.
    private func refreshNotes() {
        guard let openThread else {
            openThreadNotes = []
            return
        }
        openThreadNotes = Self.notes(agentNotes, forThread: openThread)
    }

    /// The notes whose `session` is exactly `key`'s file stem, in the order given, which
    /// the coordinator loads newest modification first. Matched by the stem alone: a note
    /// is an agent's claim, so nothing but the stem the outcome prompt dictated may place
    /// it on a thread, and a note naming no session is never shown here.
    nonisolated static func notes(_ notes: [AgentNote], forThread key: AgentSessionKey) -> [AgentNote] {
        let stem = MemoryPages.threadFileStem(key)
        return notes.filter { $0.session == stem }
    }

    // MARK: Selection

    private func select(_ key: AgentSessionKey) {
        openThread = key
        listFocused = true
    }

    /// Steps through the listed threads; a selection the query hides starts from the top.
    private func move(_ direction: MoveCommandDirection) {
        guard !order.isEmpty else { return }
        let target: Int
        if let open = openThread, let index = order.firstIndex(of: open) {
            switch direction {
            case .up: target = max(index - 1, 0)
            case .down: target = min(index + 1, order.count - 1)
            default: return
            }
        } else {
            target = 0
        }
        openThread = order[target]
        reveal = order[target]
    }

    private func selectFirstMatch() {
        guard let first = order.first else { return }
        select(first)
    }

    // MARK: Empty states

    /// Says how a thread comes to exist, because an empty lens is otherwise
    /// indistinguishable from a broken one: with linking off the setting is the
    /// next step, with it on only a paste into an agent's pane in Tern is.
    private var noThreads: some View {
        Kit.EmptyState(
            systemImage: "bubble.left.and.text.bubble.right",
            title: "No agent sessions yet",
            message: bindingEnabled
                ? "Paste a dictation into an omp or Claude Code pane in Tern."
                : "Turn on Link dictations to agent sessions in Settings \u{25B8} Privacy. "
                    + "A dictation that you paste into Tern then joins its session here."
        )
    }

    /// The query is the only thing that can hide every thread, so it is named
    /// and offered back; the page keeps the thread it shows.
    private var noMatches: some View {
        Kit.EmptyState(
            systemImage: "magnifyingglass",
            title: "Nothing matches \u{201C}\(query)\u{201D}",
            message: "Search runs over what was said, thread titles, project folders and app names.",
            actionTitle: "Clear Search",
            actionIdentifier: "journal.threads.nomatch.clear",
            action: { searchText = "" }
        )
        .frame(maxWidth: .infinity)
        .padding(.top, VoiceourMetrics.Space.xl + VoiceourMetrics.Space.sm)
    }

    // MARK: List

    private var list: some View {
        Kit.ListColumn(
            "Threads",
            subtitle: listSubtitle,
            reveal: reveal,
            focus: $listFocused,
            onMove: move
        ) {
            Kit.SearchField(
                "Search threads",
                text: $searchText,
                identifier: "journal.threads.search",
                clearIdentifier: "journal.threads.search.clear",
                onSubmit: selectFirstMatch
            )
        } content: {
            if groups.isEmpty {
                noMatches
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.threads) { thread in
                            row(for: thread)
                                .id(thread.id)
                        }
                    } header: {
                        Kit.GroupHeader(group.project ?? "No project folder", detail: String(group.threads.count))
                    }
                }
            }
        }
    }

    /// "4 agent sessions", or "2 of 4 agent sessions match" while a query narrows the list.
    private var listSubtitle: String {
        let total = allThreads.count
        let noun = total == 1 ? "agent session" : "agent sessions"
        guard !query.isEmpty else { return "\(total) \(noun)" }
        return "\(order.count) of \(total) \(noun) match"
    }

    private func row(for thread: JournalThread) -> some View {
        let title = Self.title(of: thread)
        let summary = summaryLine(for: thread)
        let notSent = thread.notSentCount

        return Kit.TitleRow(
            title,
            subtitle: summary.joined(separator: " \u{00B7} "),
            isSelected: thread.id == openThread,
            action: { select(thread.id) }
        ) {
            Kit.IconTile(systemImage: "terminal.fill", size: .small)
        } trailing: {
            if notSent > 0 {
                Kit.Pill("\(notSent) not sent", tone: .caution)
            }
        }
        .accessibilityLabel(([title] + summary + notSentPart(of: thread)).joined(separator: ", "))
        .accessibilityAction(named: "Open thread") {
            select(thread.id)
        }
        .accessibilityIdentifier("journal.threads.row")
    }

    /// The row's second line as its parts, so the visible line and the spoken label say
    /// the same facts in the same order. The not-sent count is a pill beside the line,
    /// so it is spoken from ``notSentPart(of:)`` rather than printed here.
    private func summaryLine(for thread: JournalThread) -> [String] {
        let count = thread.entries.count
        return [
            thread.ref.agent.displayName,
            "\(count) \(count == 1 ? "dictation" : "dictations")",
            Self.span(from: thread.firstAt, to: thread.lastAt, calendar: calendar),
        ]
    }

    private func notSentPart(of thread: JournalThread) -> [String] {
        thread.notSentCount > 0 ? ["\(thread.notSentCount) not sent"] : []
    }

    /// The name a reader knows the session by: its own title, else the folder it
    /// ran in, else its agent's, because an id prefix names nothing a reader knows.
    /// The row, the page heading and the sidebar all read it here, so they never differ.
    static func title(of thread: JournalThread) -> String {
        thread.ref.title ?? thread.ref.project ?? "\(thread.ref.agent.displayName) session"
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        if let thread = selected {
            Kit.PageColumn(identity: AnyHashable(thread.id)) {
                pageBar(for: thread)
            } content: {
                pageContent(for: thread)
            }
        } else {
            Kit.EmptyState(
                systemImage: "bubble.left.and.text.bubble.right",
                title: "No thread selected",
                message: "Select a thread to read everything said into that agent session."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether memory keeps one of the thread's entries, so its thread page exists for
    /// the outcome prompt to point the agent at.
    private var offersOutcomePrompt: Bool {
        memoryRoot != nil && selectedIsInMemory
    }

    @ViewBuilder
    private func pageBar(for thread: JournalThread) -> some View {
        if thread.ref.resumable {
            Kit.Button("Copy Resume Command", systemImage: "terminal", prominence: .primary) {
                copyResumeCommand(of: thread)
            }
            .help("Copy the shell command that resumes this session in its folder")
            .accessibilityIdentifier("journal.threads.resume")
        }

        if selectedIsInTimeline {
            Kit.Button("Show in Timeline", systemImage: "clock") {
                navigation.showThreadInTimeline(thread.id)
            }
            .help("Show this session's dictations in Timeline")
            .accessibilityIdentifier("journal.threads.timeline")
        }

        if let memoryRoot, selectedIsInMemory {
            JournalPromptCopyButton(
                "Copy Outcome Prompt",
                help: "Copy a prompt that asks this session's agent to record what came of the work",
                announcement: "Outcome prompt copied to clipboard",
                identifier: "journal.threads.outcome-prompt",
                flash: flash,
                prompt: {
                    MemoryPages.outcomePrompt(
                        thread: thread.id,
                        day: thread.lastAt,
                        root: memoryRoot,
                        calendar: memoryCalendar
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func pageContent(for thread: JournalThread) -> some View {
        Kit.PageHeader(
            kicker: "\(thread.ref.agent.displayName) \u{00B7} \(thread.ref.project ?? "No project folder")",
            title: Self.title(of: thread),
            meta: pageSubtitle(for: thread)
        ) {
            EmptyView()
        }

        if !openThreadNotes.isEmpty {
            JournalSectionCard("From the session") {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    ForEach(openThreadNotes) { note in
                        if note.id != openThreadNotes.first?.id {
                            Kit.Rule()
                        }
                        JournalAgentNoteRow(note)
                            .accessibilityIdentifier("journal.threads.agent-note")
                    }
                }
            }
        } else if offersOutcomePrompt {
            Kit.Card {
                JournalCaption(
                    "No outcome recorded yet. Copy Outcome Prompt asks this session's agent to save "
                        + "what came of the work, and it shows here."
                )
            }
        }

        // Lazy, because one session can hold hundreds of dictations and the page builds
        // only the ones near the viewport.
        JournalSectionCard("Dictations") {
            LazyVStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                ForEach(pageLines) { line in
                    switch line {
                    case .day(let day):
                        JournalDayCaption(SessionsFormatters.dayHeader.string(from: day))
                            .padding(.top, line.id == pageLines.first?.id ? 0 : VoiceourMetrics.Space.md)
                    case .entry(let entry):
                        JournalEntryRow(
                            entry: entry,
                            isInHistory: historyIDs.contains(entry.id),
                            showsThreadAction: false,
                            navigation: navigation,
                            delete: delete,
                            topics: topics,
                            file: file
                        )
                    }
                }
            }
        }

        details(for: thread)
    }

    /// "12 dictations · Nov 10, 09:27 – 18:42 · 2 not sent".
    private func pageSubtitle(for thread: JournalThread) -> String {
        let count = thread.entries.count
        var parts = [
            "\(count) \(count == 1 ? "dictation" : "dictations")",
            Self.span(from: thread.firstAt, to: thread.lastAt, calendar: calendar),
        ]
        parts += notSentPart(of: thread)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The session's id and folder, folded shut in their own card: the reader rarely
    /// needs them, and a resumable session's resume command already carries both.
    private func details(for thread: JournalThread) -> some View {
        Kit.Card {
            Kit.Disclosure("Details", isExpanded: $showsDetails, identifier: "journal.threads.details") {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Kit.Property("Session") {
                        monospacedReadout(thread.ref.sessionId)
                            .accessibilityIdentifier("journal.threads.session")
                    }

                    if let directory = thread.ref.workingDirectory {
                        Kit.Property("Folder") {
                            monospacedReadout(directory)
                                .accessibilityIdentifier("journal.threads.folder")
                        }
                    }
                }
                .padding(.top, VoiceourMetrics.Space.sm)
            }
        }
    }

    /// An id or a path in the code face, wrapped whole: both are unbroken tokens, so
    /// they break at any character rather than run past the card.
    private func monospacedReadout(_ value: String) -> some View {
        Text(value)
            .roleStyle(.code)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            // Keep mouse selection while exposing the text once, not both the
            // native selection wrapper and its identical accessibility child.
            .accessibilityRepresentation { Text(value) }
    }

    /// One line of the page's Dictations section: a day's caption, or one entry under it.
    private enum PageLine: Identifiable {
        case day(Date)
        case entry(JournalEntry)

        enum ID: Hashable {
            case day(Date)
            case entry(UUID)
        }

        var id: ID {
            switch self {
            case .day(let day): .day(day)
            case .entry(let entry): .entry(entry.id)
            }
        }
    }

    /// The thread's entries oldest first, with a day caption before each day's
    /// first entry. Built for the selected thread only, so its cost is one session's
    /// entries rather than the journal's.
    private static func lines(of thread: JournalThread, calendar: Calendar) -> [PageLine] {
        var lines: [PageLine] = []
        lines.reserveCapacity(thread.entries.count + 1)
        var currentDay: Date?
        for entry in thread.entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if day != currentDay {
                lines.append(.day(day))
                currentDay = day
            }
            lines.append(.entry(entry))
        }
        return lines
    }

    // MARK: Span

    /// English month abbreviations, fixed so the row reads the same on every
    /// Mac and in every golden; the day header carries the locale's own spelling.
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// When the thread was spoken into: "Nov 10, 09:27 – 18:42" within one day,
    /// "Nov 10, 09:27" when that day's first and last entry share a minute, and
    /// "Nov 8 – Nov 10" across days, where the times would be noise.
    private static func span(from first: Date, to last: Date, calendar: Calendar) -> String {
        let start = calendar.dateComponents([.month, .day, .hour, .minute], from: first)
        guard calendar.isDate(first, inSameDayAs: last) else {
            let end = calendar.dateComponents([.month, .day], from: last)
            return "\(monthDay(start)) \u{2013} \(monthDay(end))"
        }
        let end = calendar.dateComponents([.hour, .minute], from: last)
        let startClock = clock(start)
        let endClock = clock(end)
        guard startClock != endClock else {
            return "\(monthDay(start)), \(startClock)"
        }
        return "\(monthDay(start)), \(startClock) \u{2013} \(endClock)"
    }

    /// "Nov 10". A calendar with more than twelve months spells the month as its
    /// number rather than borrowing a Gregorian name that would be wrong.
    private static func monthDay(_ components: DateComponents) -> String {
        let month = components.month ?? 0
        let name = monthNames.indices.contains(month - 1) ? monthNames[month - 1] : "\(month)"
        return "\(name) \(components.day ?? 0)"
    }

    /// "09:27", padded by hand so no formatter's locale can reach it.
    private static func clock(_ components: DateComponents) -> String {
        "\(twoDigits(components.hour ?? 0)):\(twoDigits(components.minute ?? 0))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    // MARK: Actions

    /// The toast and the announcement are claims about the clipboard, so a refused
    /// write leaves the page exactly as it was instead of confirming nothing.
    private func copyResumeCommand(of thread: JournalThread) {
        guard GeneralPasteboard.copy(thread.resumeCommand) != nil else { return }
        flash.show("Resume command copied to clipboard", animation: Kit.Motion.quick(a11y))
    }
}
