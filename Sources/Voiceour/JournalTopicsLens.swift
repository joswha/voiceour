import SwiftUI
import VoiceCore

/// Topics: the subjects the user named, each read as one page of everything filed
/// under it.
///
/// Topics belong to the user, so the lens is where they are made, renamed and
/// removed, and where the sorting model is asked to file what the user has not. The
/// list column holds the topics and the controls that make or sort them; the page
/// column reads the selected topic. The page leads with the topic's own words (its
/// name and the one line the sorting model reads as the rubric), then everything
/// filed under it, newest day first, because a topic is consulted for where it stands
/// now.
///
/// The topic rows are cached in state and rebuilt on appear and when the entries or
/// the topics change, never in `body`: memory is uncapped, and a body pass that
/// re-bucketed every entry by topic would run on every keystroke in the editor.
struct JournalTopicsLens: View {
    private let coordinator: DictationCoordinator
    private let entries: [JournalEntry]
    private let navigation: JournalNavigation
    /// Removes an entry History no longer holds; nil offers no delete.
    private let delete: ((UUID) async -> Bool)?
    /// Every note agents saved under `agents/`; a topic's page shows the ones that name it.
    private let agentNotes: [AgentNote]
    /// The memory folder the synthesis prompt points an agent at; nil offers no prompt.
    private let memoryRoot: URL?

    /// Every topic with the entries filed under it, most entries first.
    @State private var rows: [TopicRow] = []
    /// The ids of the rows History still holds, so an entry offers "Show in
    /// Timeline" only when Timeline can open it and "Delete Entry…" only when it
    /// cannot.
    @State private var historyIDs: Set<UUID> = []
    @State private var selectedTopicID: String?
    /// The row an arrow key selected, scrolled into view.
    @State private var reveal: String?
    /// The agent notes that name the selected topic, newest modification first.
    @State private var selectedTopicNotes: [AgentNote] = []

    /// Whether the reader asked for the creation card. With no topics it shows anyway,
    /// since making one is the only thing the lens can do then.
    @State private var isCreating = false
    @State private var newName = ""
    @State private var newSummary = ""
    @State private var addRefusal: String?

    /// The selected topic's editable copy, seeded when a topic is selected and written
    /// back only by Save, so typing never renames a topic the reader has not confirmed.
    @State private var editedName = ""
    @State private var editedSummary = ""
    @State private var saveRefusal: String?

    @State private var pendingDeletion: MemoryTopic?
    @State private var flash = Kit.Flash()

    @FocusState private var isListFocused: Bool
    @FocusState private var isNewNameFocused: Bool

    init(
        coordinator: DictationCoordinator,
        entries: [JournalEntry],
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)?,
        agentNotes: [AgentNote] = [],
        memoryRoot: URL? = nil
    ) {
        self.coordinator = coordinator
        self.entries = entries
        self.navigation = navigation
        self.delete = delete
        self.agentNotes = agentNotes
        self.memoryRoot = memoryRoot
    }

    var body: some View {
        Kit.Split {
            listColumn
        } page: {
            pageColumn
        }
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
        .onChange(of: selectedTopicID) {
            seedEditor()
            reloadSelectedTopicNotes()
            flash.dismiss()
        }
        .onChange(of: agentNotes) {
            reloadSelectedTopicNotes()
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

    // MARK: List

    private var listColumn: some View {
        Kit.ListColumn(
            "Topics",
            subtitle: Self.counted(rows.count, "topic", "topics"),
            reveal: reveal.map { AnyHashable($0) },
            focus: $isListFocused,
            onMove: move
        ) {
            Kit.ActionButton("New Topic", systemImage: "plus") {
                toggleCreating()
            }
            .help(isCreating ? "Close the new topic card" : "Name a new topic")
            .accessibilityIdentifier("journal.topics.new")
        } content: {
            if isCreating || rows.isEmpty {
                newTopicCard
                    .padding(.bottom, VoiceourMetrics.Space.sm)
            }

            ForEach(rows) { row in
                topicRow(row)
                    .id(row.id)
            }

            if showsSorting {
                sortingCard
                    .padding(.top, VoiceourMetrics.Space.md)
            }
        }
    }

    private func toggleCreating() {
        isCreating.toggle()
        isNewNameFocused = isCreating
    }

    private func topicRow(_ row: TopicRow) -> some View {
        let detail = Self.detailParts(for: row)
        let isSelected = row.id == selectedTopicID

        return Kit.TitleRow(
            row.topic.name,
            subtitle: detail.joined(separator: " \u{00B7} "),
            isSelected: isSelected,
            action: { select(row.id) },
            leading: { Kit.Glyph(systemImage: "tag.fill", tint: .teal) },
            trailing: { EmptyView() }
        )
        .accessibilityLabel(([row.topic.name] + detail).joined(separator: ", "))
        .accessibilityAction(named: "Open topic") {
            select(row.id)
        }
        .accessibilityIdentifier("journal.topics.row")
    }

    /// A press also gives the list focus, so the arrow keys move on from the row the
    /// reader clicked.
    private func select(_ id: String) {
        selectedTopicID = id
        isListFocused = true
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let target = Self.step(direction, from: selectedTopicID, in: rows.map(\.id)) else { return }
        selectedTopicID = target
        reveal = target
    }

    // MARK: New topic

    private var newTopicCard: some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.SectionTitle("New Topic")

                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNewNameFocused)
                    .onSubmit(addTopic)
                    .accessibilityIdentifier("journal.topics.new.name")

                TextField("What belongs here, in one line", text: $newSummary)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTopic)
                    .accessibilityIdentifier("journal.topics.new.summary")

                Kit.ActionButton("Add Topic", systemImage: "plus", action: addTopic)
                    .disabled(Self.isBlank(newName))
                    .accessibilityIdentifier("journal.topics.add")

                // A refusal is said under the button that asked, in words that name
                // what to change, rather than leaving the fields filled and unexplained.
                if let addRefusal {
                    ConsoleCaption(addRefusal, color: .red)
                        .accessibilityIdentifier("journal.topics.new.refusal")
                }
            }
        }
    }

    /// A new topic is what the reader came to read next, so it becomes the selection
    /// and the card closes behind it.
    private func addTopic() {
        guard !Self.isBlank(newName) else { return }
        let existing = Set(coordinator.memoryTopics.map(\.id))
        do {
            try coordinator.addTopic(name: newName, summary: newSummary)
            newName = ""
            newSummary = ""
            addRefusal = nil
            isCreating = false
            if let added = coordinator.memoryTopics.first(where: { !existing.contains($0.id) }) {
                selectedTopicID = added.id
                reveal = added.id
            }
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

    private var sortingCard: some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.SectionTitle("Sorting")

                if isSorting {
                    Kit.ActionButton("Stop Sorting", systemImage: "stop.fill") {
                        coordinator.cancelSortEntries()
                    }
                    .help("Stop labelling entries; the ones already filed stay filed")
                    .accessibilityIdentifier("journal.topics.sort.stop")
                } else {
                    Kit.ActionButton("Sort Entries", systemImage: "wand.and.stars") {
                        coordinator.sortEntries()
                    }
                    .help("File every entry that has no topic of yours")
                    .accessibilityIdentifier("journal.topics.sort")
                }

                ConsoleCaption(sortingCaption)
                    .accessibilityIdentifier("journal.topics.sort.status")
            }
        }
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

    // MARK: Page

    @ViewBuilder
    private var pageColumn: some View {
        if let row = rows.first(where: { $0.id == selectedTopicID }) {
            page(row)
                .kitToast(flash, identifier: "journal.topics.copied")
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No topics yet",
                systemImage: "tag",
                description: Text(
                    "Name a topic, then file a dictation or a note under it from the entry's menu."
                )
            )
        } else {
            ContentUnavailableView(
                "No topic selected",
                systemImage: "tag",
                description: Text("Select a topic to read everything filed under it.")
            )
        }
    }

    private func page(_ row: TopicRow) -> some View {
        Kit.PageColumn(identity: row.id) {
            Kit.GlassGroup {
                if let memoryRoot {
                    JournalPromptCopyButton(
                        "Copy Synthesis Prompt",
                        help: "Copy a prompt that asks your coding agent to synthesize this topic",
                        announcement: "Synthesis prompt copied to clipboard",
                        identifier: "journal.topics.synthesis-prompt",
                        prominence: .primary,
                        flash: flash,
                        prompt: { MemoryPages.synthesisPrompt(topic: row.topic, root: memoryRoot) }
                    )
                }

                Kit.ActionButton("Delete Topic\u{2026}", systemImage: "trash", role: .destructive) {
                    pendingDeletion = row.topic
                }
                .help("Delete this topic; its entries stay in memory")
                .accessibilityIdentifier("journal.topics.delete")
            }
        } content: {
            Kit.PageHeader(
                eyebrow: "Topic",
                title: row.topic.name,
                subtitle: row.topic.summary.isEmpty
                    ? Self.counted(row.entryCount, "entry", "entries")
                    : row.topic.summary
            )

            if !selectedTopicNotes.isEmpty {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Kit.SectionTitle("From your agents")
                    ForEach(selectedTopicNotes) { note in
                        JournalAgentNoteRow(note)
                            .accessibilityIdentifier("journal.topics.agent-note")
                    }
                }
            }

            entriesSection(row)

            // Last, because a topic is read far more often than it is renamed.
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.SectionTitle("Name and summary")
                editCard(row.topic)
            }
        }
    }

    private func editCard(_ topic: MemoryTopic) -> some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.Fact("Name") {
                    TextField("Name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(topic) }
                        .accessibilityIdentifier("journal.topics.name")
                }

                Kit.Fact("Summary") {
                    TextField("Summary", text: $editedSummary, prompt: Text("What belongs here, in one line"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(topic) }
                        .accessibilityIdentifier("journal.topics.summary")
                }

                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
                    Kit.ActionButton("Save", systemImage: "checkmark") {
                        save(topic)
                    }
                    .disabled(!isEdited(topic))
                    .accessibilityIdentifier("journal.topics.save")

                    if let saveRefusal {
                        ConsoleCaption(saveRefusal, color: .red)
                            .accessibilityIdentifier("journal.topics.refusal")
                    }
                }
                .padding(.leading, Kit.Metrics.factLabel + VoiceourMetrics.Space.md)
            }
        }
    }

    @ViewBuilder
    private func entriesSection(_ row: TopicRow) -> some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Kit.SectionTitle("Entries")

            if row.days.isEmpty {
                ConsoleCaption("Nothing is filed under this topic yet. File an entry from its menu in any lens.")
            } else {
                ForEach(row.days) { day in
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                        ConsoleCaption(SessionsFormatters.dayHeader.string(from: day.day))
                            .padding(.horizontal, VoiceourMetrics.Space.md)
                        ForEach(day.entries) { entry in
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
                    .padding(.bottom, VoiceourMetrics.Space.sm)
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

    /// Fills the editor from the selected topic as memory holds it, discarding any
    /// unsaved edit to the topic the reader left.
    private func seedEditor() {
        let topic = selectedTopicID.flatMap { id in coordinator.memoryTopics.first { $0.id == id } }
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

    /// The reload that follows the removal moves the selection to the topic that took
    /// its place in the list.
    private func remove(_ topic: MemoryTopic) {
        pendingDeletion = nil
        coordinator.removeTopic(id: topic.id)
    }

    // MARK: Derived data

    /// Every date on this page is bucketed in one calendar, the one the harness
    /// pins, so a day boundary never depends on this Mac's settings.
    private var calendar: Calendar {
        RenderOverrides.calendar ?? Calendar.current
    }

    /// Rebuilds every topic row and keeps the selection on a topic that exists. Topics
    /// come from the coordinator rather than from the entries, so a topic with nothing
    /// filed under it still has a row.
    private func reload() {
        let calendar = self.calendar
        let topics = coordinator.memoryTopics

        var filed: [String: [JournalEntry]] = [:]
        for entry in entries {
            if let topicID = entry.topicID {
                filed[topicID, default: []].append(entry)
            }
        }

        let previous = rows.map(\.id)
        rows = topics.map { topic in
            let topicEntries = (filed[topic.id] ?? []).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return TopicRow(
                topic: topic,
                entryCount: topicEntries.count,
                days: Self.days(of: topicEntries, calendar: calendar)
            )
        }
        .sorted(by: Self.listOrder)

        historyIDs = Set(coordinator.recentSessions.map(\.id))

        let ids = rows.map(\.id)
        if let selected = selectedTopicID {
            if !ids.contains(selected) {
                selectedTopicID = Self.successor(at: previous.firstIndex(of: selected), in: ids)
            }
        } else {
            selectedTopicID = ids.first
        }
        reloadSelectedTopicNotes()
    }

    /// Picks the notes whose `topic` names the selected topic; none while no topic is
    /// selected.
    private func reloadSelectedTopicNotes() {
        guard let selectedTopicID else {
            selectedTopicNotes = []
            return
        }
        selectedTopicNotes = agentNotes.filter { $0.topicID == selectedTopicID }
    }

    /// Most entries first, then by name compared without the locale so the order is
    /// the same on every Mac, then by id so two equal names keep one order.
    private static func listOrder(_ lhs: TopicRow, _ rhs: TopicRow) -> Bool {
        if lhs.entryCount != rhs.entryCount { return lhs.entryCount > rhs.entryCount }
        let order = lhs.topic.name.compare(rhs.topic.name, options: [.caseInsensitive, .diacriticInsensitive])
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// The topic's entries, already newest first, split at each day boundary.
    private static func days(of entries: [JournalEntry], calendar: Calendar) -> [TopicDay] {
        var days: [TopicDay] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = days.indices.last, days[last].day == day {
                days[last].entries.append(entry)
            } else {
                days.append(TopicDay(day: day, entries: [entry]))
            }
        }
        return days
    }

    /// The row an arrow key lands on: the neighbour in `direction`, the first row when
    /// nothing listed is selected, nil past either end.
    private static func step(_ direction: MoveCommandDirection, from current: String?, in ids: [String]) -> String? {
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

    /// The row that took a removed row's place: the one now at its index, else the new
    /// last row; nil when the list is empty.
    private static func successor(at index: Int?, in ids: [String]) -> String? {
        guard let last = ids.indices.last else { return nil }
        guard let index else { return ids.first }
        return ids[min(index, last)]
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
    /// The page's entries by day, newest day first.
    let days: [TopicDay]
    var id: String { topic.id }
}

/// One day of a topic's entries, newest first.
private struct TopicDay: Identifiable {
    let day: Date
    var entries: [JournalEntry]
    var id: Date { day }
}
