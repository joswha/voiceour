import SwiftUI
import VoiceCore

/// Topics: the subjects the user named, each read as one page of everything filed
/// under it.
///
/// Topics belong to the user, so the lens is where they are made, renamed and
/// removed, and where the sorting model is asked to file what the user has not.
/// One grouped form with at most one topic open, the Threads shape: the open topic's
/// page takes its own plate directly under the row that opened it, so the page reads
/// as one thing rather than as more index. The page leads with the topic's own words
/// (its name and the one line the sorting model reads as the rubric), then everything
/// filed under it, newest day first, because a topic is consulted for where it stands
/// now.
///
/// The topic rows are cached in state and rebuilt on appear and when the entries or
/// the topics change, never in `body`: memory is uncapped, and a body pass that
/// re-bucketed every entry by topic would run on every keystroke in the editor.
struct JournalTopicsLens: View {
    private let coordinator: DictationCoordinator
    private let entries: [JournalEntry]
    private let lens: Binding<JournalLens>
    private let navigation: JournalNavigation
    /// Removes an entry History no longer holds; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?

    /// Every topic with the entries filed under it, most entries first.
    @State private var rows: [TopicRow] = []
    /// The ids of the rows History still holds, so an entry offers "Show in
    /// Timeline" only when Timeline can open it and "Delete Entry…" only when it
    /// cannot.
    @State private var historyIDs: Set<UUID> = []
    @State private var openTopicID: String?

    @State private var newName = ""
    @State private var newSummary = ""
    @State private var addRefusal: String?

    /// The open topic's editable copy, seeded when a topic opens and written back
    /// only by Save, so typing never renames a topic the reader has not confirmed.
    @State private var editedName = ""
    @State private var editedSummary = ""
    @State private var saveRefusal: String?

    @State private var pendingDeletion: MemoryTopic?

    init(
        coordinator: DictationCoordinator,
        entries: [JournalEntry],
        lens: Binding<JournalLens>,
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)?
    ) {
        self.coordinator = coordinator
        self.entries = entries
        self.lens = lens
        self.navigation = navigation
        self.delete = delete
    }

    var body: some View {
        Form {
            JournalLensHeader(lens: lens)

            Section("New topic") {
                newTopicRows
            }

            if rows.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No topics yet",
                        systemImage: "tag",
                        description: Text(
                            "Name a topic above. File a dictation or a note under it from the entry's menu."
                        )
                    )
                }
            }

            if showsSorting {
                Section("Sorting") {
                    sortingRow
                }
            }

            if !rows.isEmpty {
                topicSections
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onChange(of: entries) {
            reload()
        }
        .onChange(of: coordinator.memoryTopics) {
            reload()
        }
        // A History row can leave while memory keeps its entry, which changes no
        // entry, so the ids that decide each row's menu are followed on their own.
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            historyIDs = Set(coordinator.recentSessions.map(\.id))
        }
        .onChange(of: openTopicID) {
            seedEditor()
        }
        .onChange(of: newName) {
            addRefusal = nil
        }
        .onChange(of: editedName) {
            saveRefusal = nil
        }
        .confirmationDialog(
            "Delete this topic?",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { topic in
            Button("Delete Topic", role: .destructive) {
                remove(topic)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Its entries stay in memory and become unfiled.")
        }
    }

    // MARK: New topic

    @ViewBuilder
    private var newTopicRows: some View {
        TextField("Name", text: $newName)
            .onSubmit(addTopic)
            .accessibilityIdentifier("journal.topics.new.name")

        TextField("What belongs here, in one line", text: $newSummary)
            .onSubmit(addTopic)
            .accessibilityIdentifier("journal.topics.new.summary")

        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Button("Add Topic", action: addTopic)
                .disabled(Self.isBlank(newName))
                .accessibilityIdentifier("journal.topics.add")

            // A refusal is said under the button that asked, in words that name
            // what to change, rather than leaving the fields filled and unexplained.
            if let addRefusal {
                ConsoleCaption(addRefusal, color: .red)
                    .accessibilityIdentifier("journal.topics.new.refusal")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addTopic() {
        guard !Self.isBlank(newName) else { return }
        do {
            try coordinator.addTopic(name: newName, summary: newSummary)
            newName = ""
            newSummary = ""
            addRefusal = nil
        } catch {
            addRefusal = Self.refusalText(error)
        }
    }

    // MARK: Sorting

    /// The sorting model needs both the user's consent and a key, so the run is
    /// offered only when it could actually start.
    private var showsSorting: Bool {
        coordinator.settings.organizerEnabled && coordinator.typeSafeKeyOrigin != nil
    }

    private var isSorting: Bool {
        coordinator.organizerRun.map { !$0.isFinished } ?? false
    }

    private var sortingRow: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            if isSorting {
                Button("Stop Sorting") {
                    coordinator.cancelSortEntries()
                }
                .help("Stop labelling entries; the ones already filed stay filed")
                .accessibilityIdentifier("journal.topics.sort.stop")
            } else {
                Button("Sort Entries") {
                    coordinator.sortEntries()
                }
                .help("File every entry that has no topic of yours")
                .accessibilityIdentifier("journal.topics.sort")
            }

            ConsoleCaption(sortingCaption)
                .accessibilityIdentifier("journal.topics.sort.status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The run's state as a sentence. A finished run counts the entries that were
    /// labelled apart from the ones whose request failed, because a failure leaves
    /// its entry exactly as it was and the reader should know how many those are.
    private var sortingCaption: String {
        guard let run = coordinator.organizerRun else {
            return "Jev files each entry that has no topic of yours under the best match, or under none."
        }
        guard run.isFinished else {
            return "Sorting \(run.done) of \(run.total)\u{2026}"
        }
        let sorted = max(run.done - run.failed, 0)
        let summary = "Sorted \(Self.counted(sorted, "entry", "entries"))."
        guard run.failed > 0 else { return summary }
        return "\(summary) \(run.failed) could not be sorted."
    }

    // MARK: Topics

    /// The topic list as one to three grouped plates: the rows down to the open
    /// topic, the open topic's page, and the rows below it.
    @ViewBuilder
    private var topicSections: some View {
        if let open = rows.firstIndex(where: { $0.id == openTopicID }) {
            Section("Topics") {
                topicRows(rows[...open])
            }
            Section {
                page(rows[open])
            }
            if open + 1 < rows.count {
                Section {
                    topicRows(rows[(open + 1)...])
                }
            }
        } else {
            Section("Topics") {
                topicRows(rows[...])
            }
        }
    }

    private func topicRows(_ rows: ArraySlice<TopicRow>) -> some View {
        ForEach(rows) { row in
            topicRow(row, isOpen: row.id == openTopicID)
        }
    }

    private func topicRow(_ row: TopicRow, isOpen: Bool) -> some View {
        let detail = Self.detailParts(for: row)

        return Button {
            toggle(row.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(row.topic.name)
                        .fontWeight(isOpen ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(detail.joined(separator: " \u{00B7} "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        .accessibilityLabel(([row.topic.name] + detail).joined(separator: ", "))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityAction(named: isOpen ? "Close topic" : "Open topic") {
            toggle(row.id)
        }
        .accessibilityIdentifier("journal.topics.row")
    }

    private func toggle(_ id: String) {
        openTopicID = openTopicID == id ? nil : id
    }

    // MARK: Page

    @ViewBuilder
    private func page(_ row: TopicRow) -> some View {
        TextField("Name", text: $editedName)
            .onSubmit { save(row.topic) }
            .accessibilityIdentifier("journal.topics.name")

        TextField("Summary", text: $editedSummary, prompt: Text("What belongs here, in one line"))
            .onSubmit { save(row.topic) }
            .accessibilityIdentifier("journal.topics.summary")

        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Button("Save") {
                    save(row.topic)
                }
                .disabled(!isEdited(row.topic))
                .accessibilityIdentifier("journal.topics.save")

                Spacer(minLength: VoiceourMetrics.Space.sm)

                Button("Delete Topic\u{2026}", role: .destructive) {
                    pendingDeletion = row.topic
                }
                .accessibilityIdentifier("journal.topics.delete")
            }

            if let saveRefusal {
                ConsoleCaption(saveRefusal, color: .red)
                    .accessibilityIdentifier("journal.topics.refusal")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if row.lines.isEmpty {
            ConsoleCaption("Nothing is filed under this topic yet. File an entry from its menu in any lens.")
        } else {
            ForEach(row.lines) { line in
                switch line {
                case .day(let day):
                    ConsoleCaption(SessionsFormatters.dayHeader.string(from: day))
                case .entry(let entry):
                    JournalEntryRow(
                        entry: entry,
                        isInHistory: historyIDs.contains(entry.id),
                        showsThreadAction: true,
                        navigation: navigation,
                        delete: delete,
                        topics: coordinator.memoryTopics,
                        file: fileEntry
                    )
                }
            }
        }
    }

    /// Save is offered only when it would change something, compared the way the
    /// catalog stores a topic: trimmed, so a stray space is not an edit.
    private func isEdited(_ topic: MemoryTopic) -> Bool {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines) != topic.name
            || editedSummary.trimmingCharacters(in: .whitespacesAndNewlines) != topic.summary
    }

    private func save(_ topic: MemoryTopic) {
        guard isEdited(topic) else { return }
        do {
            try coordinator.updateTopic(id: topic.id, name: editedName, summary: editedSummary)
            // The catalog trims and joins lines, so the fields show what was kept.
            seedEditor()
        } catch {
            saveRefusal = Self.refusalText(error)
        }
    }

    /// Fills the editor from the open topic as memory holds it, discarding any
    /// unsaved edit to the topic the reader left.
    private func seedEditor() {
        let topic = openTopicID.flatMap { id in coordinator.memoryTopics.first { $0.id == id } }
        editedName = topic?.name ?? ""
        editedSummary = topic?.summary ?? ""
        saveRefusal = nil
    }

    private var fileEntry: (UUID, String?) -> Void {
        let coordinator = coordinator
        return { id, topicID in coordinator.fileEntry(id: id, underTopic: topicID) }
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

    private func remove(_ topic: MemoryTopic) {
        pendingDeletion = nil
        if openTopicID == topic.id {
            openTopicID = nil
        }
        coordinator.removeTopic(id: topic.id)
    }

    // MARK: Derived data

    /// Every date on this page is bucketed in one calendar, the one the harness
    /// pins, so a day boundary never depends on this Mac's settings.
    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds every topic row and closes a topic that is gone. Topics come from
    /// the coordinator rather than from the entries, so a topic with nothing filed
    /// under it still has a row.
    private func reload() {
        let calendar = self.calendar
        let topics = coordinator.memoryTopics

        var filed: [String: [JournalEntry]] = [:]
        for entry in entries {
            if let topicID = entry.topicID {
                filed[topicID, default: []].append(entry)
            }
        }

        rows = topics.map { topic in
            let topicEntries = (filed[topic.id] ?? []).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return TopicRow(
                topic: topic,
                entryCount: topicEntries.count,
                lines: Self.lines(of: topicEntries, calendar: calendar)
            )
        }
        .sorted(by: Self.listOrder)

        historyIDs = Set(coordinator.recentSessions.map(\.id))

        if let open = openTopicID, !topics.contains(where: { $0.id == open }) {
            openTopicID = nil
        }
    }

    /// Most entries first, then by name compared without the locale so the order is
    /// the same on every Mac, then by id so two equal names keep one order.
    private static func listOrder(_ lhs: TopicRow, _ rhs: TopicRow) -> Bool {
        if lhs.entryCount != rhs.entryCount { return lhs.entryCount > rhs.entryCount }
        let order = lhs.topic.name.compare(rhs.topic.name, options: [.caseInsensitive, .diacriticInsensitive])
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// The topic's entries, already newest first, with a day caption before each
    /// day's first entry. Flattened so every element of the page's `ForEach` is
    /// exactly one form row.
    private static func lines(of entries: [JournalEntry], calendar: Calendar) -> [TopicPageLine] {
        var lines: [TopicPageLine] = []
        lines.reserveCapacity(entries.count)
        var currentDay: Date?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if day != currentDay {
                lines.append(.day(day))
                currentDay = day
            }
            lines.append(.entry(entry))
        }
        return lines
    }

    // MARK: Text

    /// The row's second line as its parts, so the visible line and the spoken
    /// label say the same facts in the same order.
    private static func detailParts(for row: TopicRow) -> [String] {
        var parts = [counted(row.entryCount, "entry", "entries")]
        if !row.topic.summary.isEmpty {
            parts.append(row.topic.summary)
        }
        return parts
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The sentence for a refused add or rename. The coordinator refuses only with
    /// `TopicCatalog.Refusal`; the last sentence covers any other error its
    /// throwing signature admits, so a failure is never silent.
    private static func refusalText(_ error: any Error) -> String {
        guard let refusal = error as? TopicCatalog.Refusal else {
            return "The topic could not be saved."
        }
        switch refusal {
        case .emptyName:
            return "Give the topic a name with at least one letter or digit."
        case .duplicate(let existing):
            return "\u{201C}\(existing)\u{201D} already covers that name."
        case .reserved:
            return "\u{201C}None\u{201D} is reserved. Choose another name."
        case .tooMany:
            return "Voiceour keeps at most \(OrganizerPolicy.maximumTopics) topics."
        }
    }
}

/// One topic with what is filed under it.
private struct TopicRow: Identifiable {
    let topic: MemoryTopic
    let entryCount: Int
    /// The page's rows: day captions and entries, newest day first.
    let lines: [TopicPageLine]
    var id: String { topic.id }
}

/// One line of an open topic's page: a day's caption, or one entry under it.
private enum TopicPageLine: Identifiable {
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
