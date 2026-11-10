import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Rewind: one day replayed in the order it was spoken, or every day searched at once.
///
/// The list column is the day picker: every day that holds an entry, grouped by month,
/// so no choice can land on an empty page. The page reads the day as runs of one
/// subject — an agent session, an app, notes — because that is how a reader remembers a
/// day: "the morning in that session, then mail". The search covers every day rather
/// than the one on screen, since a reader who types a phrase rarely knows which day they
/// said it; choosing a match opens its day with that entry marked.
///
/// Every derived value is cached in state and rebuilt on appear and when the entries,
/// the day or the query changes, never in `body`: the memory store is uncapped, and a
/// body pass that re-bucketed months of entries would run on every keystroke.
struct JournalRewindLens: View {
    private let entries: [JournalEntry]
    private let historyIDs: Set<UUID>
    private let navigation: JournalNavigation
    /// Removes an entry History no longer holds; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?
    /// The topics an entry's "File Under" submenu offers.
    private let topics: [MemoryTopic]
    /// Files an entry under a topic or under none; nil offers no submenu.
    private let file: ((UUID, String?) -> Void)?
    /// The ids of the entries memory keeps. The recap prompt names the day's page in the
    /// memory folder, which exists only for a day that holds one of them.
    private let memoryIDs: Set<UUID>
    /// Every note agents saved under `agents/`; the lens shows the selected day's.
    private let agentNotes: [AgentNote]
    /// The memory folder the recap prompt points an agent at; nil offers no prompt.
    private let memoryRoot: URL?

    /// The start of the day on screen. Seeded from the harness pin so a golden opens on
    /// a fixed day; a day that holds no entry falls back to the newest one.
    @State private var selectedDay: Date? = RenderOverrides.journalInitialDay
    /// Start-of-day dates that hold an entry, newest first.
    @State private var days: [Date] = []
    /// The list column's rows: `days` grouped by calendar month, newest first.
    @State private var months: [RewindMonth] = []
    /// Every day's rewind, built once per entries change. The list's row facts need each
    /// day's figures anyway, so stepping between days reads them here instead of
    /// filtering the whole store again.
    @State private var rewinds: [Date: RewindDay] = [:]
    @State private var rewind: RewindDay?
    @State private var searchText = ""
    /// The trimmed query the cached matches answer. The list switches between days and
    /// matches on this rather than on the field, so a keystroke never shows a frame of
    /// "no matches" before the matches for it are built.
    @State private var matchQuery = ""
    /// Every match, before the display limit, so the subtitle can state the real total.
    @State private var matchCount = 0
    @State private var matchDays: [RewindMatchDay] = []
    /// The search match the page was opened on, washed with the selection tint.
    @State private var highlightedEntry: UUID?
    /// The match to scroll the page to once its day is on screen.
    @State private var pendingReveal: UUID?
    @State private var listReveal: AnyHashable?
    @State private var pageReveal: AnyHashable?
    /// Whether the day on screen holds an entry memory keeps.
    @State private var dayIsInMemory = false
    /// The agent notes whose `day` is the day on screen, newest modification first.
    @State private var dayNotes: [AgentNote] = []
    @State private var flash = Kit.Flash()
    @FocusState private var listFocused: Bool

    private var a11y = A11y()

    /// How many matches the lens renders. A one-word query over an uncapped store can
    /// match thousands of entries.
    private static let matchLimit = 200

    init(
        entries: [JournalEntry],
        historyIDs: Set<UUID>,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)? = nil,
        topics: [MemoryTopic] = [],
        file: ((UUID, String?) -> Void)? = nil,
        memoryIDs: Set<UUID> = [],
        agentNotes: [AgentNote] = [],
        memoryRoot: URL? = nil
    ) {
        self.entries = entries
        self.historyIDs = historyIDs
        self.navigation = navigation
        self.delete = delete
        self.topics = topics
        self.file = file
        self.memoryIDs = memoryIDs
        self.agentNotes = agentNotes
        self.memoryRoot = memoryRoot
    }

    var body: some View {
        Group {
            if days.isEmpty {
                ContentUnavailableView(
                    "Nothing to rewind yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Dictate something, then come back to replay your day.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Kit.Split {
                    listColumn
                } page: {
                    pageColumn
                        .kitToast(flash, identifier: "journal.rewind.copied")
                }
            }
        }
        .onAppear {
            reloadDays()
            reloadMatches()
        }
        .onChange(of: entries) {
            reloadDays()
            reloadMatches()
        }
        .onChange(of: selectedDay) {
            reloadRewind()
        }
        .onChange(of: searchText) {
            reloadMatches()
        }
        .onChange(of: memoryIDs) {
            reloadAgentDay()
        }
        .onChange(of: agentNotes) {
            reloadAgentDay()
        }
    }

    // MARK: List column

    private var listColumn: some View {
        Kit.ListColumn(
            "Rewind",
            subtitle: listSubtitle,
            reveal: listReveal,
            focus: $listFocused,
            onMove: move
        ) {
            Kit.SearchField(
                "Search everything you said",
                text: $searchText,
                identifier: "journal.rewind.search",
                clearIdentifier: "journal.rewind.search.clear",
                onSubmit: selectFirstMatch
            )
        } content: {
            if matchQuery.isEmpty {
                dayRows
            } else if matchDays.isEmpty {
                noMatches
                    .frame(maxWidth: .infinity)
                    .padding(.top, VoiceourMetrics.Space.xl)
            } else {
                matchRows
            }
        }
    }

    /// "12 days", or while searching the match count, capped the way the list is.
    private var listSubtitle: String {
        matchQuery.isEmpty ? Self.counted(days.count, "day", "days") : Self.matchCaption(count: matchCount)
    }

    private var dayRows: some View {
        ForEach(months) { month in
            Section {
                ForEach(month.days) { row in
                    Kit.TitleRow(
                        row.title,
                        subtitle: row.subtitle,
                        isSelected: row.day == selectedDay,
                        action: {
                            listFocused = true
                            selectDay(row.day)
                        },
                        trailing: { EmptyView() }
                    )
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityIdentifier("journal.rewind.day-row")
                    .id(row.day)
                }
            } header: {
                Kit.GroupHeader(month.name, detail: String(month.days.count))
            }
        }
    }

    private var matchRows: some View {
        ForEach(matchDays) { matchDay in
            Section {
                ForEach(matchDay.matches) { match in
                    matchRow(match)
                }
            } header: {
                Kit.GroupHeader(matchDay.title, detail: String(matchDay.matches.count))
            }
        }
    }

    /// A match previews its words under the time and where they went. Its label is the
    /// one a reading row gives the same entry, so a flow finds the entry by the same
    /// words in the list and on the page.
    private func matchRow(_ match: RewindMatch) -> some View {
        let entry = match.entry
        let kind = JournalEntryRow.highlightKind(of: entry)
        return Kit.PreviewRow(
            entry.text,
            isSelected: match.id == highlightedEntry,
            action: {
                listFocused = true
                selectMatch(entry)
            }
        ) {
            Text(match.stamp)
                .font(Kit.Fonts.stamp)
            if let subject = match.subject {
                Kit.AppLabel(subject, icon: match.icon)
            }
        } marks: {
            if entry.kind == .note {
                Kit.Mark("NOTE", tone: .info)
            }
            if entry.thread?.sent == false {
                Kit.Mark("NOT SENT", tone: .caution)
            }
            if let kind {
                Kit.Mark(kind.displayName.uppercased())
            }
        }
        .accessibilityLabel(match.accessibilityLabel)
        .id(match.id)
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(matchQuery)\u{201D}")
        } description: {
            Text("Search runs over what you said, agent session titles, projects and app names, on every day.")
        } actions: {
            Button("Clear Search") { searchText = "" }
                .accessibilityIdentifier("journal.rewind.no-matches.clear")
        }
    }

    // MARK: Page column

    @ViewBuilder
    private var pageColumn: some View {
        if let rewind {
            dayPage(rewind)
        } else {
            ContentUnavailableView(
                "No day selected",
                systemImage: "calendar",
                description: Text("Select a day to replay what you said on it.")
            )
        }
    }

    private func dayPage(_ rewind: RewindDay) -> some View {
        let earlier = neighbour(of: rewind.day, olderBy: 1)
        let later = neighbour(of: rewind.day, olderBy: -1)
        let offersRecap = dayIsInMemory && memoryRoot != nil
        return Kit.PageColumn(identity: rewind.day, reveal: pageReveal) {
            Kit.GlassGroup {
                Kit.ActionButton("Earlier Day", systemImage: "chevron.left") {
                    if let earlier { selectDay(earlier) }
                }
                .disabled(earlier == nil)
                .help("Earlier Day")
                .accessibilityIdentifier("journal.rewind.earlier")

                Kit.ActionButton("Later Day", systemImage: "chevron.right") {
                    if let later { selectDay(later) }
                }
                .disabled(later == nil)
                .help("Later Day")
                .accessibilityIdentifier("journal.rewind.later")
            }

            if dayIsInMemory, let memoryRoot {
                JournalPromptCopyButton(
                    "Copy Recap Prompt",
                    help: "Copy a prompt that asks your coding agent to recap this day",
                    announcement: "Recap prompt copied to clipboard",
                    identifier: "journal.rewind.recap-prompt",
                    prominence: .primary,
                    flash: flash,
                    // The day page is named in the memory calendar, so the prompt is too.
                    prompt: {
                        MemoryPages.recapPrompt(
                            day: rewind.day,
                            root: memoryRoot,
                            calendar: DictationCoordinator.memoryCalendar(timeZone: calendar.timeZone)
                        )
                    }
                )
            }
        } content: {
            // The span is the last figure, so the header names the day alone.
            Kit.PageHeader(eyebrow: "Rewind", title: Self.pageTitle(of: rewind.day, calendar: calendar))

            figures(rewind)

            if offersRecap {
                ConsoleCaption(
                    "Paste it into your coding agent. The agent reads this day in the memory folder and saves "
                        + "a recap there."
                )
            }

            if !rewind.highlights.isEmpty {
                Kit.Island {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                        Kit.SectionTitle("Highlights")
                        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                            ForEach(rewind.highlights) { highlight in
                                entryRow(highlight.entry)
                            }
                        }
                    }
                }
            }

            if !dayNotes.isEmpty {
                Kit.Island {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                        Kit.SectionTitle("From your agents")
                        ForEach(dayNotes) { note in
                            if note.id != dayNotes.first?.id {
                                Kit.Rule()
                            }
                            JournalAgentNoteRow(note)
                                .accessibilityIdentifier("journal.rewind.agent-note")
                        }
                    }
                }
            }

            ForEach(rewind.blocks) { block in
                blockSection(block)
            }
        }
    }

    /// The day's figures, two to a row so a place list or a span reads whole at the
    /// page's width. Where names the first kind of place as the tile's value and the rest
    /// as its detail, so VoiceOver still hears the whole list as the value.
    private func figures(_ rewind: RewindDay) -> some View {
        let places = Self.whereParts(rewind)
        let columns = [
            GridItem(.flexible(), spacing: VoiceourMetrics.Space.sm, alignment: .top),
            GridItem(.flexible(), spacing: VoiceourMetrics.Space.sm, alignment: .top),
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Kit.MetricTile(
                "Entries",
                value: String(rewind.entryCount),
                detail: SessionsFormatters.wordCountLabel(rewind.wordCount)
            )
            .accessibilityIdentifier("journal.rewind.entries")

            if rewind.captureSeconds >= 1 {
                Kit.MetricTile("Speaking time", value: Self.durationText(seconds: rewind.captureSeconds))
                    .accessibilityIdentifier("journal.rewind.speaking-time")
            }

            if let first = places.first {
                Kit.MetricTile(
                    "Where",
                    value: first,
                    detail: places.count > 1 ? places.dropFirst().joined(separator: " \u{00B7} ") : nil
                )
                .accessibilityIdentifier("journal.rewind.where")
            }

            if let span = Self.spanText(rewind) {
                Kit.MetricTile("Span", value: span)
                    .accessibilityIdentifier("journal.rewind.span")
            }
        }
    }

    /// The day `offset` steps older than `day` among the days that hold an entry, or nil
    /// past either end. `days` runs newest first, so a positive offset is earlier.
    private func neighbour(of day: Date, olderBy offset: Int) -> Date? {
        guard let index = days.firstIndex(of: day) else { return nil }
        let target = index + offset
        return days.indices.contains(target) ? days[target] : nil
    }

    // MARK: Blocks

    /// One island per block: its heading, with Open Thread beside it on a session
    /// block, then the session's title and the block's entries.
    private func blockSection(_ block: RewindBlock) -> some View {
        Kit.Island {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.SectionTitle(Self.blockHeader(block)) {
                    if case .thread(let ref) = block.subject {
                        Button {
                            navigation.openThread(ref.key)
                        } label: {
                            Text("Open Thread")
                                .frame(minHeight: Kit.Metrics.control)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Open this agent session in Threads")
                    }
                }

                if case .thread(let ref) = block.subject {
                    threadTitleRow(ref)
                }

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    ForEach(block.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
            }
        }
    }

    /// Names the agent session a thread block was spoken into. The commands live on the
    /// row's context menu and are repeated as named accessibility actions, because a
    /// context menu alone is a gesture VoiceOver cannot discover.
    private func threadTitleRow(_ ref: JournalThreadRef) -> some View {
        Text(ref.title ?? "\(ref.agent.displayName) session")
            .font(Kit.Fonts.rowTitle)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Open Thread") { navigation.openThread(ref.key) }
                if ref.resumable {
                    Button("Copy Resume Command") { copyResumeCommand(ref) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Open Thread") { navigation.openThread(ref.key) }
            .accessibilityActions {
                if ref.resumable {
                    Button("Copy Resume Command") { copyResumeCommand(ref) }
                }
            }
    }

    private func entryRow(_ entry: JournalEntry) -> some View {
        JournalEntryRow(
            entry: entry,
            isInHistory: historyIDs.contains(entry.id),
            showsThreadAction: true,
            isHighlighted: entry.id == highlightedEntry,
            navigation: navigation,
            delete: delete,
            topics: topics,
            file: file
        )
    }

    /// The toast is a claim about the clipboard, so a refused write says nothing.
    private func copyResumeCommand(_ ref: JournalThreadRef) {
        let command = AgentSessionBinding.resumeCommand(
            agent: ref.agent,
            sessionId: ref.sessionId,
            workingDirectory: ref.workingDirectory
        )
        guard GeneralPasteboard.copy(command) != nil else { return }
        flash.show("Resume command copied to clipboard", animation: Kit.Motion.quick(a11y))
    }

    // MARK: Selection

    /// Opens a day from its row, the page's day buttons or the arrow keys. A day chosen
    /// directly is read whole, so no search match stays marked on it.
    private func selectDay(_ day: Date) {
        highlightedEntry = nil
        pendingReveal = nil
        pageReveal = nil
        selectedDay = day
        listReveal = day
    }

    /// Opens a match's day with the match marked and scrolled into view. A match on
    /// another day waits for that day's page, so the reveal names a row that exists.
    private func selectMatch(_ entry: JournalEntry) {
        let day = calendar.startOfDay(for: entry.createdAt)
        highlightedEntry = entry.id
        listReveal = entry.id
        if rewind?.day == day {
            pendingReveal = nil
            pageReveal = entry.id
        } else {
            pendingReveal = entry.id
            pageReveal = nil
            selectedDay = day
        }
    }

    /// Return in the search field opens the newest match and hands the arrows to the list.
    private func selectFirstMatch() {
        guard let first = matchDays.first?.matches.first else { return }
        listFocused = true
        selectMatch(first.entry)
    }

    /// Up and down step through the days, or through the matches while searching, in
    /// list order.
    private func move(_ direction: MoveCommandDirection) {
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }
        if matchQuery.isEmpty {
            let index = selectedDay.flatMap { days.firstIndex(of: $0) }
            let target = index.map { $0 + step } ?? 0
            guard days.indices.contains(target) else { return }
            selectDay(days[target])
        } else {
            let matches = matchDays.flatMap(\.matches)
            let index = highlightedEntry.flatMap { id in matches.firstIndex { $0.id == id } }
            let target = index.map { $0 + step } ?? 0
            guard matches.indices.contains(target) else { return }
            selectMatch(matches[target].entry)
        }
    }

    // MARK: Derived data

    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds the days, their rewinds and the month groups, then keeps the day on
    /// screen while it still holds an entry. A day that emptied hands the page to the day
    /// that took its place in the list, the next older one, else the next newer one; a
    /// pinned day that never held an entry falls back to the newest day.
    private func reloadDays() {
        let calendar = self.calendar
        let previousDays = days
        let days = JournalQuery.days(in: entries, calendar: calendar)

        var buckets: [Date: [JournalEntry]] = [:]
        for entry in entries {
            buckets[calendar.startOfDay(for: entry.createdAt), default: []].append(entry)
        }
        var rewinds: [Date: RewindDay] = [:]
        var months: [RewindMonth] = []
        for day in days {
            let dayRewind = JournalQuery.rewind(day: day, in: buckets[day] ?? [], calendar: calendar)
            rewinds[day] = dayRewind
            let row = Self.dayRow(dayRewind, calendar: calendar)
            let components = calendar.dateComponents([.year, .month], from: day)
            let year = components.year ?? 0
            let month = components.month ?? 0
            let id = "\(year)-\(month)"
            if let last = months.indices.last, months[last].id == id {
                months[last].days.append(row)
            } else {
                months.append(RewindMonth(id: id, name: Self.monthTitle(year: year, month: month), days: [row]))
            }
        }
        self.days = days
        self.rewinds = rewinds
        self.months = months

        // The tab hands the entries over one turn after the lens first appears. A day
        // chosen before they arrive must survive that empty first pass, or a pinned
        // day would be traded for the newest one.
        guard let newest = days.first else {
            rewind = nil
            reloadAgentDay()
            return
        }

        let wanted = selectedDay.map { calendar.startOfDay(for: $0) }
        let resolved: Date
        if let wanted, rewinds[wanted] != nil {
            resolved = wanted
        } else if let wanted, let successor = Self.successor(of: wanted, in: previousDays, among: rewinds) {
            resolved = successor
        } else {
            resolved = newest
        }
        if selectedDay != resolved {
            selectedDay = resolved
        }
        rewind = rewinds[resolved]
        applyPendingReveal()
        reloadAgentDay()
    }

    /// Follows a day chosen from the list or the page. `reloadDays` has already set the
    /// rewind for a day it resolved itself, so that change is not applied twice.
    private func reloadRewind() {
        guard rewind?.day != selectedDay else { return }
        rewind = selectedDay.flatMap { rewinds[$0] }
        applyPendingReveal()
        reloadAgentDay()
    }

    /// Scrolls the page to the match it was opened for, in the same update that puts
    /// the match's day on the page.
    private func applyPendingReveal() {
        guard let pendingReveal else { return }
        self.pendingReveal = nil
        pageReveal = pendingReveal
    }

    /// Rebuilds what the day on screen shows beside its entries: whether memory keeps any
    /// of them, and the notes agents saved for it.
    private func reloadAgentDay() {
        guard let rewind else {
            dayIsInMemory = false
            dayNotes = []
            return
        }
        dayIsInMemory = rewind.blocks.contains { block in
            block.entries.contains { memoryIDs.contains($0.id) }
        }
        // The same `YYYY-MM-DD` an agent note names its day in, and locale-proof.
        let day = DictationStatsLedger.dayKey(for: rewind.day, calendar: calendar)
        dayNotes = agentNotes.filter { $0.day == day }
    }

    private func reloadMatches() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasSearching = !matchQuery.isEmpty
        matchQuery = query
        guard !query.isEmpty else {
            matchCount = 0
            matchDays = []
            // Back on the days, the list scrolls to the day on screen. The reveal was
            // cleared when the search began, so this is a change that scrolls.
            if wasSearching, let selectedDay {
                listReveal = selectedDay
            }
            return
        }
        if !wasSearching {
            listReveal = nil
        }
        let found = JournalQuery.matches(in: entries, query: query).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        matchCount = found.count

        let calendar = self.calendar
        var grouped: [RewindMatchDay] = []
        for entry in found.prefix(Self.matchLimit) {
            let day = calendar.startOfDay(for: entry.createdAt)
            let match = Self.match(for: entry)
            if let last = grouped.indices.last, grouped[last].day == day {
                grouped[last].matches.append(match)
            } else {
                grouped.append(
                    RewindMatchDay(
                        day: day,
                        title: SessionsFormatters.dayHeader.string(from: day),
                        matches: [match]
                    )
                )
            }
        }
        matchDays = grouped
    }

    /// The first day after `day` in `previous` that still holds an entry, else the
    /// nearest one before it: the day that took `day`'s place in the list.
    private static func successor(of day: Date, in previous: [Date], among rewinds: [Date: RewindDay]) -> Date? {
        guard let index = previous.firstIndex(of: day) else { return nil }
        if let later = previous[(index + 1)...].first(where: { rewinds[$0] != nil }) {
            return later
        }
        return previous[..<index].last(where: { rewinds[$0] != nil })
    }

    private static func dayRow(_ rewind: RewindDay, calendar: Calendar) -> RewindDayRow {
        let parts =
            [
                counted(rewind.entryCount, "entry", "entries"),
                SessionsFormatters.wordCountLabel(rewind.wordCount),
            ] + whereParts(rewind)
        let title = listTitle(of: rewind.day, calendar: calendar)
        return RewindDayRow(
            day: rewind.day,
            title: title,
            subtitle: parts.joined(separator: " \u{00B7} "),
            accessibilityLabel: ([title] + parts).joined(separator: ", ")
        )
    }

    private static func match(for entry: JournalEntry) -> RewindMatch {
        let stamp = SessionsFormatters.timestamp.string(from: entry.createdAt)
        var subject: String?
        var icon: NSImage?
        if let thread = entry.thread {
            subject =
                thread.title
                ?? thread.project.map { "\(thread.agent.displayName) \u{00B7} \($0)" }
                ?? thread.agent.displayName
        } else if entry.kind == .note {
            subject = "Notes"
        } else if let app = entry.app {
            let identity = AppIdentity.resolve(bundleId: app.bundleId, persistedName: app.name)
            subject = identity.label
            icon = identity.icon
        }

        // The label a reading row gives the same entry: the time, the states, the kind,
        // then the words.
        var parts = [stamp]
        if entry.kind == .note { parts.append("note") }
        if entry.thread?.sent == false { parts.append("not sent") }
        if let kind = JournalEntryRow.highlightKind(of: entry) { parts.append(kind.displayName.lowercased()) }
        parts.append(entry.text)

        return RewindMatch(
            entry: entry,
            stamp: stamp,
            subject: subject,
            icon: icon,
            accessibilityLabel: parts.joined(separator: ", ")
        )
    }

    // MARK: Text

    /// English names, indexed by the calendar's weekday and month numbers minus one.
    /// Fixed rather than read from a locale-dependent formatter, so a day renders the
    /// same words on every Mac and in every golden.
    private static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    private static let shortMonthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "June 2025".
    private static func monthTitle(year: Int, month: Int) -> String {
        guard monthNames.indices.contains(month - 1) else { return String(year) }
        return "\(monthNames[month - 1]) \(year)"
    }

    /// "Sunday, Jun 15".
    private static func listTitle(of day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .month, .day], from: day)
        guard let weekday = parts.weekday, let month = parts.month, let date = parts.day,
            weekdayNames.indices.contains(weekday - 1), shortMonthNames.indices.contains(month - 1)
        else { return SessionsFormatters.dayHeader.string(from: day) }
        return "\(weekdayNames[weekday - 1]), \(shortMonthNames[month - 1]) \(date)"
    }

    /// "Sunday, June 15, 2025".
    private static func pageTitle(of day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .year, .month, .day], from: day)
        guard let weekday = parts.weekday, let year = parts.year, let month = parts.month, let date = parts.day,
            weekdayNames.indices.contains(weekday - 1), monthNames.indices.contains(month - 1)
        else { return SessionsFormatters.dayHeader.string(from: day) }
        return "\(weekdayNames[weekday - 1]), \(monthNames[month - 1]) \(date), \(year)"
    }

    private static func matchCaption(count: Int) -> String {
        if count > matchLimit {
            return "Showing the newest \(matchLimit) of \(count) matches"
        }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    /// Whole seconds as the two largest units, e.g. "6 min 12 s" or "1 h 5 min".
    private static func durationText(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
        }
        if minutes > 0 {
            return remainder > 0 ? "\(minutes) min \(remainder) s" : "\(minutes) min"
        }
        return "\(remainder) s"
    }

    /// Where the day's words went, e.g. ["3 agent sessions", "2 apps", "1 note"]. Empty
    /// when every entry went to a target that was never recorded.
    private static func whereParts(_ rewind: RewindDay) -> [String] {
        var parts: [String] = []
        if rewind.threadCount > 0 {
            parts.append(counted(rewind.threadCount, "agent session", "agent sessions"))
        }
        if rewind.appCount > 0 {
            parts.append(counted(rewind.appCount, "app", "apps"))
        }
        if rewind.noteCount > 0 {
            parts.append(counted(rewind.noteCount, "note", "notes"))
        }
        return parts
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// The day's first to last time, nil for a day with no entry.
    private static func spanText(_ rewind: RewindDay) -> String? {
        guard let firstAt = rewind.firstAt, let lastAt = rewind.lastAt else { return nil }
        return spanText(from: firstAt, to: lastAt)
    }

    /// "09:27 – 18:42", or one "09:27" when both ends fall in the same minute.
    private static func spanText(from start: Date, to end: Date) -> String {
        let first = RewindFormatters.minute.string(from: start)
        let last = RewindFormatters.minute.string(from: end)
        return first == last ? first : "\(first) \u{2013} \(last)"
    }

    private static func blockHeader(_ block: RewindBlock) -> String {
        let subject: String
        switch block.subject {
        case .thread(let ref):
            subject = ref.project.map { "\(ref.agent.displayName) · \($0)" } ?? ref.agent.displayName
        case .app(let identity):
            subject = AppIdentity.resolve(bundleId: identity.bundleId, persistedName: identity.name).label
        case .notes:
            subject = "Notes"
        case .unknown:
            subject = "Unknown target"
        }
        let header = "\(spanText(from: block.startAt, to: block.endAt)) · \(subject)"
        return block.isContinuation ? "\(header) · continued" : header
    }
}

/// One calendar month of the list's days, newest first.
private struct RewindMonth: Identifiable {
    /// The calendar year and month number, e.g. "2026-10"; unique per month.
    let id: String
    /// "October 2026", from the fixed English month names.
    let name: String
    var days: [RewindDayRow]
}

/// One day's list row, its words built once per entries change.
private struct RewindDayRow: Identifiable {
    let day: Date
    /// "Sunday, Jun 15".
    let title: String
    /// "3 entries · 37 words · 2 apps".
    let subtitle: String
    let accessibilityLabel: String
    var id: Date { day }
}

/// One search match with the words its row shows, resolved once per query.
private struct RewindMatch: Identifiable {
    let entry: JournalEntry
    let stamp: String
    /// The thread, app or "Notes" the entry went to; nil for an unrecorded target.
    let subject: String?
    let icon: NSImage?
    let accessibilityLabel: String
    var id: UUID { entry.id }
}

/// One day of search matches, newest first.
private struct RewindMatchDay: Identifiable {
    let day: Date
    /// The day as `SessionsFormatters.dayHeader` writes it.
    let title: String
    var matches: [RewindMatch]
    var id: Date { day }
}

/// The hour-and-minute stamp `SessionsFormatters` does not provide, resolved through
/// the same calendar, locale and time zone seams as every other date formatter.
@MainActor
private enum RewindFormatters {
    static let minute: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
