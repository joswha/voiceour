import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Rewind: one day replayed in the order it was spoken, or every day searched at once.
///
/// A day reads as runs of one subject — an agent session, an app, notes — because that
/// is how a reader remembers a day: "the morning in that session, then mail". The
/// search covers every day rather than the one on screen, since a reader who types a
/// phrase rarely knows which day they said it.
///
/// Every derived value is cached in state and rebuilt on appear and when the entries,
/// the day or the query changes, never in `body`: the memory store is uncapped, and a
/// body pass that re-bucketed months of entries would run on every keystroke.
struct JournalRewindLens: View {
    private let entries: [JournalEntry]
    private let historyIDs: Set<UUID>
    private let lens: Binding<JournalLens>
    private let navigation: JournalNavigation
    /// Removes an entry History no longer holds; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?

    /// The start of the day on screen. Seeded from the harness pin so a golden opens on
    /// a fixed day; any day that holds no entry falls back to the newest one.
    @State private var selectedDay: Date? = RenderOverrides.journalInitialDay
    /// Start-of-day dates that hold an entry, newest first.
    @State private var days: [Date] = []
    /// The days the picker lists directly; older days sit in one submenu per month.
    @State private var recentDays: [Date] = []
    @State private var olderMonths: [RewindMonth] = []
    @State private var rewind: RewindDay?
    @State private var searchText = ""
    /// Every match, before the display limit, so the caption can state the real total.
    @State private var matchCount = 0
    @State private var matchDays: [RewindMatchDay] = []

    /// How many days the picker lists before it switches to month submenus: two weeks
    /// is the range a reader names by weekday rather than by date.
    private static let recentDayLimit = 14
    /// How many matches the lens renders. A one-word query over an uncapped store can
    /// match thousands of entries, and each match is a full-text row.
    private static let matchLimit = 200

    init(
        entries: [JournalEntry],
        historyIDs: Set<UUID>,
        lens: Binding<JournalLens>,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)? = nil
    ) {
        self.entries = entries
        self.historyIDs = historyIDs
        self.lens = lens
        self.navigation = navigation
        self.delete = delete
    }

    var body: some View {
        Form {
            JournalLensHeader(lens: lens)

            Section {
                searchRow
            }

            if query.isEmpty {
                if let rewind {
                    navigatorSection(rewind)

                    if !rewind.highlights.isEmpty {
                        Section("Highlights") {
                            LazyVStack(spacing: Self.rowSpacing) {
                                ForEach(rewind.highlights) { highlight in
                                    entryRow(highlight.entry)
                                }
                            }
                        }
                    }

                    ForEach(rewind.blocks) { block in
                        blockSection(block)
                    }
                } else if entries.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nothing to rewind yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Dictate something, then come back to replay your day.")
                        )
                    }
                }
            } else if matchDays.isEmpty {
                Section {
                    noMatches
                }
            } else {
                ForEach(matchDays) { matchDay in
                    Section(SessionsFormatters.dayHeader.string(from: matchDay.day)) {
                        LazyVStack(spacing: Self.rowSpacing) {
                            ForEach(matchDay.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
    }

    // MARK: Search

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRow: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search everything you said", text: $searchText)
                    .accessibilityIdentifier("journal.rewind.search")

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
                    .accessibilityIdentifier("journal.rewind.search.clear")
                }
            }

            if !query.isEmpty, matchCount > 0 {
                ConsoleCaption(Self.matchCaption(count: matchCount))
            }
        }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over what you said, agent session titles, projects and app names, on every day.")
        } actions: {
            Button("Clear Search") { searchText = "" }
                .accessibilityIdentifier("journal.rewind.no-matches.clear")
        }
    }

    // MARK: Day

    @ViewBuilder
    private func navigatorSection(_ rewind: RewindDay) -> some View {
        let earlier = neighbour(olderBy: 1)
        let later = neighbour(olderBy: -1)

        Section {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Button {
                    selectedDay = earlier
                } label: {
                    Label("Earlier Day", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: VoiceourMetrics.Control.mini, height: VoiceourMetrics.Control.mini)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(earlier == nil)
                .help("Earlier Day")
                .accessibilityIdentifier("journal.rewind.earlier")

                Spacer(minLength: VoiceourMetrics.Space.sm)

                dayMenu(rewind.day)

                Spacer(minLength: VoiceourMetrics.Space.sm)

                Button {
                    selectedDay = later
                } label: {
                    Label("Later Day", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .frame(width: VoiceourMetrics.Control.mini, height: VoiceourMetrics.Control.mini)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(later == nil)
                .help("Later Day")
                .accessibilityIdentifier("journal.rewind.later")
            }

            LabeledContent("Entries") {
                Text(Self.entriesText(rewind))
            }
            .accessibilityIdentifier("journal.rewind.entries")

            if rewind.captureSeconds >= 1 {
                LabeledContent("Speaking time") {
                    Text(Self.durationText(seconds: rewind.captureSeconds))
                }
                .accessibilityIdentifier("journal.rewind.speaking-time")
            }

            let places = Self.whereText(rewind)
            if !places.isEmpty {
                LabeledContent("Where") {
                    Text(places)
                }
                .accessibilityIdentifier("journal.rewind.where")
            }

            if let firstAt = rewind.firstAt, let lastAt = rewind.lastAt {
                LabeledContent("Span") {
                    Text(Self.spanText(from: firstAt, to: lastAt))
                }
                .accessibilityIdentifier("journal.rewind.span")
            }
        }
    }

    /// The day picker. A menu rather than a date picker: only days that hold an entry
    /// are offered, so no choice can land on an empty page. The newest two weeks are
    /// listed directly; every earlier month folds into its own submenu so the menu keeps
    /// one screen's height however long the store has been kept.
    private func dayMenu(_ day: Date) -> some View {
        Menu {
            Picker("Day", selection: $selectedDay) {
                ForEach(recentDays, id: \.self) { recent in
                    Text(SessionsFormatters.dayHeader.string(from: recent)).tag(Date?.some(recent))
                }
            }
            .pickerStyle(.inline)

            ForEach(olderMonths) { month in
                Menu(month.name) {
                    Picker(month.name, selection: $selectedDay) {
                        ForEach(month.days, id: \.self) { older in
                            Text(SessionsFormatters.dayHeader.string(from: older)).tag(Date?.some(older))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Text(SessionsFormatters.dayHeader.string(from: day))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a day to rewind")
        .accessibilityIdentifier("journal.rewind.day")
    }

    /// The day `offset` steps older than the one on screen among the days that hold an
    /// entry, or nil past either end. `days` runs newest first, so a positive offset is
    /// earlier.
    private func neighbour(olderBy offset: Int) -> Date? {
        guard let selectedDay, let index = days.firstIndex(of: selectedDay) else { return nil }
        let target = index + offset
        return days.indices.contains(target) ? days[target] : nil
    }

    // MARK: Blocks

    private func blockSection(_ block: RewindBlock) -> some View {
        Section(Self.blockHeader(block)) {
            if case .thread(let ref) = block.subject {
                threadTitleRow(ref)
            }

            LazyVStack(spacing: Self.rowSpacing) {
                ForEach(block.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    /// Names the agent session a thread block was spoken into. The commands live on the
    /// row's context menu and are repeated as named accessibility actions, because a
    /// context menu alone is a gesture VoiceOver cannot discover.
    private func threadTitleRow(_ ref: JournalThreadRef) -> some View {
        Text(ref.title ?? String(ref.sessionId.prefix(8)))
            .font(.headline)
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
            .accessibilityIdentifier("journal.rewind.thread")
    }

    private func entryRow(_ entry: JournalEntry) -> some View {
        JournalEntryRow(
            entry: entry,
            isInHistory: historyIDs.contains(entry.id),
            showsThreadAction: true,
            navigation: navigation,
            delete: delete
        )
    }

    private func copyResumeCommand(_ ref: JournalThreadRef) {
        let command = AgentSessionBinding.resumeCommand(
            agent: ref.agent,
            sessionId: ref.sessionId,
            workingDirectory: ref.workingDirectory
        )
        // The announcement is a claim about the clipboard, so a refused write says nothing.
        guard GeneralPasteboard.copy(command) != nil else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Resume command copied to clipboard",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: Derived data

    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds the day list and the picker's grouping, then keeps the day on screen
    /// when it still holds an entry and falls back to the newest day when it does not.
    private func reloadDays() {
        let calendar = self.calendar
        let days = JournalQuery.days(in: entries, calendar: calendar)
        self.days = days
        recentDays = Array(days.prefix(Self.recentDayLimit))
        olderMonths = Self.months(of: days.dropFirst(Self.recentDayLimit), calendar: calendar)

        let wanted = selectedDay.map { calendar.startOfDay(for: $0) }
        let resolved = wanted.flatMap { days.contains($0) ? $0 : nil } ?? days.first
        if selectedDay != resolved {
            selectedDay = resolved
        }
        rewind = resolved.map { JournalQuery.rewind(day: $0, in: entries, calendar: calendar) }
    }

    /// Follows a day chosen from the navigator. `reloadDays` has already built the
    /// rewind for a day it resolved itself, so that change is not rebuilt twice.
    private func reloadRewind() {
        guard rewind?.day != selectedDay else { return }
        rewind = selectedDay.map { JournalQuery.rewind(day: $0, in: entries, calendar: calendar) }
    }

    private func reloadMatches() {
        let query = self.query
        guard !query.isEmpty else {
            matchCount = 0
            matchDays = []
            return
        }
        let matches = JournalQuery.matches(in: entries, query: query).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        matchCount = matches.count

        let calendar = self.calendar
        var grouped: [RewindMatchDay] = []
        for entry in matches.prefix(Self.matchLimit) {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = grouped.indices.last, grouped[last].day == day {
                grouped[last].entries.append(entry)
            } else {
                grouped.append(RewindMatchDay(day: day, entries: [entry]))
            }
        }
        matchDays = grouped
    }

    /// Groups days, newest first, into one entry per calendar month in the same order.
    private static func months(of days: ArraySlice<Date>, calendar: Calendar) -> [RewindMonth] {
        var months: [RewindMonth] = []
        for day in days {
            let components = calendar.dateComponents([.year, .month], from: day)
            guard let year = components.year, let month = components.month,
                Self.monthNames.indices.contains(month - 1)
            else { continue }
            let id = "\(year)-\(month)"
            if let last = months.indices.last, months[last].id == id {
                months[last].days.append(day)
            } else {
                months.append(RewindMonth(id: id, name: "\(Self.monthNames[month - 1]) \(year)", days: [day]))
            }
        }
        return months
    }

    // MARK: Text

    private static let rowSpacing = VoiceourMetrics.Space.lg + VoiceourMetrics.Space.xs

    /// English month names, indexed by the calendar's month number minus one. Fixed
    /// rather than read from a locale-dependent formatter, so a month submenu renders
    /// the same words on every Mac and in every golden.
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static func matchCaption(count: Int) -> String {
        if count > matchLimit {
            return "Showing the newest \(matchLimit) of \(count) matches"
        }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private static func entriesText(_ rewind: RewindDay) -> String {
        "\(rewind.entryCount) · \(SessionsFormatters.wordCountLabel(rewind.wordCount))"
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

    /// Where the day's words went, e.g. "3 agent sessions · 2 apps · 1 note". Empty
    /// when every entry went to a target that was never recorded.
    private static func whereText(_ rewind: RewindDay) -> String {
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
        return parts.joined(separator: " · ")
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
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

/// One calendar month of the picker's older days.
private struct RewindMonth: Identifiable {
    /// The calendar year and month number, e.g. "2026-10"; unique per month.
    let id: String
    /// "October 2026", from the fixed English month names.
    let name: String
    var days: [Date]
}

/// One day of search matches, newest first.
private struct RewindMatchDay: Identifiable {
    let day: Date
    var entries: [JournalEntry]
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
