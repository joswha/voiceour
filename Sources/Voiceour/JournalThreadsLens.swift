import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Threads: every agent session the user dictated into, read as one page each and
/// grouped by the project folder the session ran in.
///
/// One grouped form with exactly one thread open, the History shape: the open
/// thread takes its own plate inside its project, directly under the row that
/// opened it, so the page reads as one thing rather than as more index. The page
/// leads with what a reader can do with the session, then everything said into
/// it, oldest first, because a session is read the way it was spoken; its id and
/// folder sit folded under Details, because they identify the session for a
/// machine more than for the reader. It ends with what the session's own agent
/// reported about the work, attributed and dated, and the prompt that asks for
/// that report, so the answer sits under the requests it answers.
struct JournalThreadsLens: View {
    private let entries: [JournalEntry]
    private let historyIDs: Set<UUID>
    @Binding private var lens: JournalLens
    /// The tab owns which thread is open, so another lens can open one and the
    /// choice survives a lens switch.
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
    /// Every note agents saved under `agents/`; the open thread shows the ones that name it.
    private let agentNotes: [AgentNote]
    /// The ids of the entries memory keeps: a thread's page exists only when it holds
    /// one of them, so the outcome prompt that points an agent at it is offered only then.
    private let memoryIDs: Set<UUID>
    /// The memory folder the outcome prompt points an agent at; nil offers no prompt.
    private let memoryRoot: URL?

    @State private var searchText = ""
    /// The project groups for the current entries and query, cached as a snapshot
    /// and rebuilt only when either changes: grouping walks every entry, and a body
    /// pass happens on every open, close and copy confirmation.
    @State private var groups: [JournalProjectGroup] = []
    @State private var copiedThreadID: AgentSessionKey?
    @State private var resetCopyFeedbackTask: Task<Void, Never>?
    /// The agent notes whose `session` names the open thread, newest modification first.
    /// Cached and refiltered only when the open thread or the notes change, never in `body`.
    @State private var openThreadNotes: [AgentNote] = []
    /// Whether the open thread's Details fold is open; closed again whenever a
    /// thread opens, so every page starts with the same reading.
    @State private var showsDetails = false

    private var a11y = A11y()

    init(
        entries: [JournalEntry],
        historyIDs: Set<UUID>,
        lens: Binding<JournalLens>,
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
        self._lens = lens
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
        Form {
            JournalLensHeader(lens: $lens)

            if !groups.isEmpty || !searchText.isEmpty {
                Section {
                    searchRow
                }
            }

            ForEach(groups) { group in
                groupSections(group)
            }

            if groups.isEmpty {
                Section {
                    if query.isEmpty {
                        noThreads
                    } else {
                        noMatches
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            reloadOpenThreadNotes()
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
            resetCopyFeedbackTask = nil
            copiedThreadID = nil
        }
        .onChange(of: entries) {
            reload()
        }
        .onChange(of: searchText) {
            reload()
        }
        .onChange(of: openThread) {
            showsDetails = false
            reloadOpenThreadNotes()
        }
        .onChange(of: agentNotes) {
            reloadOpenThreadNotes()
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

    /// Rebuilds the groups and closes a thread that is gone.
    ///
    /// "Gone" means no entry carries it any more, not that the query hides it: a
    /// search narrows what is shown, and clearing it must bring the reader back to
    /// the page they had open. An empty entry list closes nothing, because the tab
    /// may hand this lens its entries after the lens appears, and a thread named
    /// before they arrive (by another lens or by the harness) must survive that
    /// first pass.
    private func reload() {
        groups = JournalQuery.projectGroups(
            of: JournalQuery.threads(in: JournalQuery.matches(in: entries, query: query))
        )
        if let open = openThread, !entries.isEmpty,
            !entries.contains(where: { $0.thread?.key == open })
        {
            openThread = nil
        }
    }

    /// Picks the notes for the open thread; none while no thread is open.
    private func reloadOpenThreadNotes() {
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

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search threads", text: $searchText)
                .accessibilityIdentifier("journal.threads.search")

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
                .accessibilityIdentifier("journal.threads.search.clear")
            }
        }
    }

    // MARK: Empty states

    /// Says how a thread comes to exist, because an empty lens is otherwise
    /// indistinguishable from a broken one: with linking off the setting is the
    /// next step, with it on only a paste into an agent's pane in Tern is.
    private var noThreads: some View {
        ContentUnavailableView(
            "No agent sessions yet",
            systemImage: "bubble.left.and.text.bubble.right",
            description: Text(
                bindingEnabled
                    ? "Paste a dictation into an omp or Claude Code pane in Tern."
                    : "Turn on Link dictations to agent sessions in Settings \u{25B8} Privacy. "
                        + "A dictation that you paste into Tern then joins its session here."
            )
        )
    }

    /// The query is the only thing that can hide every thread, so it is named
    /// and offered back.
    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over what was said, thread titles, project folders and app names.")
        } actions: {
            Button("Clear Search") { searchText = "" }
                .accessibilityIdentifier("journal.threads.nomatch.clear")
        }
    }

    // MARK: List

    /// One project, as one to three grouped plates: the threads above the open
    /// one, the open thread with its page, and the threads below it. The project's
    /// name stays on whichever plate comes first so it is named exactly once.
    @ViewBuilder
    private func groupSections(_ group: JournalProjectGroup) -> some View {
        let header = group.project ?? "No project folder"
        let threads = group.threads

        if let open = threads.firstIndex(where: { $0.id == openThread }) {
            let before = threads[..<open]
            let after = threads[(open + 1)...]

            if before.isEmpty {
                Section(header) { openPage(threads[open]) }
            } else {
                Section(header) { rows(before) }
                Section { openPage(threads[open]) }
            }

            if !after.isEmpty {
                Section { rows(after) }
            }
        } else {
            Section(header) { rows(threads[...]) }
        }
    }

    private func rows(_ threads: ArraySlice<JournalThread>) -> some View {
        ForEach(threads) { thread in
            row(for: thread, isOpen: false)
        }
    }

    private func row(for thread: JournalThread, isOpen: Bool) -> some View {
        let summary = summaryLine(for: thread)

        return Button {
            toggle(thread)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(Self.title(of: thread))
                        .fontWeight(isOpen ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(summary.joined(separator: " \u{00B7} "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The open state's non-colour carrier for a sighted reader;
                // VoiceOver hears the selected trait instead.
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Two lines of text come to 35 pt; the row takes the next control height
            // instead of padding to a height that sits between two of them.
            .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Control.large, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([Self.title(of: thread)] + summary).joined(separator: ", "))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityAction(named: isOpen ? "Close thread" : "Open thread") {
            toggle(thread)
        }
        .accessibilityIdentifier("journal.threads.row")
    }

    private func toggle(_ thread: JournalThread) {
        openThread = openThread == thread.id ? nil : thread.id
    }

    /// The row's second line as its parts, so the visible line and the spoken
    /// label say the same facts in the same order.
    private func summaryLine(for thread: JournalThread) -> [String] {
        let count = thread.entries.count
        var parts = [
            thread.ref.agent.displayName,
            "\(count) \(count == 1 ? "dictation" : "dictations")",
            Self.span(from: thread.firstAt, to: thread.lastAt, calendar: calendar),
        ]
        if thread.notSentCount > 0 {
            parts.append("\(thread.notSentCount) not sent")
        }
        return parts
    }

    /// The name a reader knows the session by: its own title, else the folder it
    /// ran in, else its agent's, because an id prefix names nothing a reader knows.
    /// The row and the page heading it opens both read it here, so they never differ.
    private static func title(of thread: JournalThread) -> String {
        thread.ref.title ?? thread.ref.project ?? "\(thread.ref.agent.displayName) session"
    }

    // MARK: Page

    @ViewBuilder
    private func openPage(_ thread: JournalThread) -> some View {
        row(for: thread, isOpen: true)

        detailsRow(for: thread)

        let isInTimeline = thread.entries.contains { historyIDs.contains($0.id) }
        if thread.ref.resumable || isInTimeline {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                if thread.ref.resumable {
                    Button("Copy Resume Command") {
                        copyResumeCommand(of: thread)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("journal.threads.resume")
                }

                if isInTimeline {
                    Button("Show in Timeline") {
                        navigation.showThreadInTimeline(thread.id)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("journal.threads.timeline")
                }

                if copiedThreadID == thread.id {
                    ConsoleStateMark("COPIED TO CLIPBOARD", .ok)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(Self.lines(of: thread, calendar: calendar)) { line in
            switch line {
            case .day(let day):
                ConsoleCaption(SessionsFormatters.dayHeader.string(from: day))
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

        if !openThreadNotes.isEmpty {
            ConsoleCaption("From the session")
            ForEach(openThreadNotes) { note in
                JournalAgentNoteRow(note)
                    .accessibilityIdentifier("journal.threads.agent-note")
            }
        }

        if let memoryRoot, thread.entries.contains(where: { memoryIDs.contains($0.id) }) {
            JournalPromptCopyButton(
                "Copy Outcome Prompt",
                help: "Copy a prompt that asks this session's agent to record what came of the work",
                announcement: "Outcome prompt copied to clipboard",
                identifier: "journal.threads.outcome-prompt",
                prompt: {
                    MemoryPages.outcomePrompt(
                        thread: thread.id,
                        day: thread.lastAt,
                        root: memoryRoot,
                        calendar: memoryCalendar
                    )
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The session's id and folder, folded shut: the reader rarely needs them, and a
    /// resumable session's resume command already carries both. Every newly opened
    /// thread starts folded.
    private func detailsRow(for thread: JournalThread) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            LabeledContent("Session") {
                monospacedReadout(thread.ref.sessionId)
                    .accessibilityIdentifier("journal.threads.session")
            }

            if let directory = thread.ref.workingDirectory {
                LabeledContent("Folder") {
                    monospacedReadout(directory)
                        .accessibilityIdentifier("journal.threads.folder")
                }
            }
        } label: {
            Text("Details")
                .accessibilityIdentifier("journal.threads.details")
                // The triangle SwiftUI publishes answers an accessibility press with
                // success and does not change its own state, so the label carries the
                // default action a VoiceOver press performs.
                .accessibilityAction {
                    showsDetails.toggle()
                }
        }
    }

    private func monospacedReadout(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            // Keep mouse selection while exposing the text once, not both the
            // native selection wrapper and its identical accessibility child.
            .accessibilityRepresentation { Text(value) }
    }

    /// One line of the open page: a day's caption, or one entry under it.
    /// Flattened so every element of the page's `ForEach` is exactly one form row.
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
    /// first entry. Built for the open thread only, so its cost is one session's
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

    private func copyResumeCommand(of thread: JournalThread) {
        // The mark and the announcement are claims about the clipboard, so a
        // refused write leaves the page exactly as it was instead of confirming
        // nothing.
        guard GeneralPasteboard.copy(thread.resumeCommand) != nil else { return }
        announce("Resume command copied to clipboard")
        resetCopyFeedbackTask?.cancel()
        withAnimation(feedbackAnimation) {
            copiedThreadID = thread.id
        }

        let copiedID = thread.id
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, copiedThreadID == copiedID else { return }
            withAnimation(feedbackAnimation) {
                copiedThreadID = nil
            }
        }
    }

    /// VoiceOver hears the sentence the mark shows, because a mark that appears
    /// beside a button the cursor has already left confirms nothing. A no-op when
    /// VoiceOver is not running.
    private func announce(_ sentence: String) {
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
}
