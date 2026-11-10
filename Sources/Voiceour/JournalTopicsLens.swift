import SwiftUI
import VoiceCore

/// The unsaved new topic: a draft row at the head of the Topics list and the draft page
/// it opens.
///
/// The Journal tab owns it rather than the lens, because the tab hosts one lens at a time
/// and a lens's own state ends when the reader moves to another: what the reader typed
/// must still be there when they come back.
@MainActor
@Observable
final class JournalTopicDraft {
    /// True while the draft row and its page exist.
    private(set) var isOpen = false
    /// True while the draft, not a topic, is the list's selection.
    var isSelected = false
    var name = ""
    var summary = ""
    /// The sentence that says why the last Add Topic was refused; nil until one was.
    var refusal: String?
    /// The topic selected when the draft was opened; Cancel returns to it.
    private(set) var returnTopicID: String?

    init() {}

    /// Opens the draft, or returns to the one already open with its words intact.
    func open(returningTo topicID: String?) {
        if !isOpen {
            isOpen = true
            returnTopicID = topicID
        }
        isSelected = true
    }

    /// Ends the draft and forgets its words.
    func close() {
        isOpen = false
        isSelected = false
        name = ""
        summary = ""
        refusal = nil
        returnTopicID = nil
    }
}

/// Topics: the subjects the user named, each read as one page of everything filed
/// under it.
///
/// Topics belong to the user, so the lens is where they are made, renamed and
/// removed, and where the sorting model is asked to file what the user has not. The
/// list column holds the topics; the page column reads the selected one. A new topic is
/// made the way a new note is in Notes: a draft row at the head of the list, selected,
/// opening a draft page with the form, so creation never squeezes a form into the list.
/// The page leads with the topic's own words (its name and the one line the sorting
/// model reads as the rubric), then everything filed under it, newest day first,
/// because a topic is consulted for where it stands now.
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
    /// The tab's draft, so its words survive a lens switch.
    @Bindable private var draft: JournalTopicDraft

    @Environment(\.theme) private var theme

    /// Every topic with the entries filed under it, most entries first.
    @State private var rows: [TopicRow] = []
    /// The ids of the rows History still holds, so an entry offers "Show in
    /// Timeline" only when Timeline can open it and "Delete Entry…" only when it
    /// cannot.
    @State private var historyIDs: Set<UUID> = []
    /// The topic the page reads while the draft is not selected.
    @State private var selectedTopicID: String?
    /// The row an arrow key selected, scrolled into view.
    @State private var reveal: AnyHashable?
    /// The agent notes that name the selected topic, newest modification first.
    @State private var selectedTopicNotes: [AgentNote] = []

    /// The selected topic's editable copy, seeded when a topic is selected and written
    /// back only by Save, so typing never renames a topic the reader has not confirmed.
    @State private var editedName = ""
    @State private var editedSummary = ""
    @State private var saveRefusal: String?

    @State private var pendingDeletion: MemoryTopic?
    @State private var flash = Kit.Flash()

    @FocusState private var isListFocused: Bool
    @FocusState private var isDraftNameFocused: Bool

    /// The draft row's scroll identity, apart from every topic id.
    private static let draftRowID = "journal.topics.draft-row"

    init(
        coordinator: DictationCoordinator,
        entries: [JournalEntry],
        navigation: JournalNavigation,
        delete: ((UUID) async -> Bool)?,
        agentNotes: [AgentNote] = [],
        memoryRoot: URL? = nil,
        draft: JournalTopicDraft
    ) {
        self.coordinator = coordinator
        self.entries = entries
        self.navigation = navigation
        self.delete = delete
        self.agentNotes = agentNotes
        self.memoryRoot = memoryRoot
        self.draft = draft
    }

    var body: some View {
        content
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
            .onChange(of: draft.isSelected) {
                flash.dismiss()
            }
            .onChange(of: agentNotes) {
                reloadSelectedTopicNotes()
            }
            .onChange(of: draft.name) {
                draft.refusal = nil
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

    /// With no topic and no draft the lens holds nothing to list or read, so one empty
    /// state across both columns offers the one thing it can do.
    @ViewBuilder
    private var content: some View {
        if rows.isEmpty && !draft.isOpen {
            Kit.EmptyState(
                systemImage: "tag",
                title: "No topics yet",
                message: "Name a topic, then file dictations and notes under it from their menu.",
                actionTitle: "New Topic",
                actionIdentifier: "journal.topics.new",
                action: openDraft
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Kit.Split {
                listColumn
            } page: {
                pageColumn
            }
        }
    }

    // MARK: List

    private var listColumn: some View {
        Kit.ListColumn(
            "Topics",
            subtitle: Self.counted(rows.count, "topic", "topics"),
            reveal: reveal,
            focus: $isListFocused,
            onMove: move
        ) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.Button("New Topic", systemImage: "plus", action: openDraft)
                    .help("Name a new topic")
                    .accessibilityIdentifier("journal.topics.new")
                Spacer(minLength: 0)
            }
        } content: {
            if draft.isOpen {
                Kit.DraftRow("New topic", isSelected: draft.isSelected) {
                    draft.isSelected = true
                    isListFocused = true
                }
                .accessibilityIdentifier("journal.topics.draft")
                .id(Self.draftRowID)
            }

            ForEach(rows) { row in
                topicRow(row)
                    .id(row.id)
            }
        }
    }

    private func topicRow(_ row: TopicRow) -> some View {
        let detail = Self.detailParts(for: row)

        return Kit.TitleRow(
            row.topic.name,
            subtitle: detail.joined(separator: " \u{00B7} "),
            isSelected: !draft.isSelected && row.id == selectedTopicID,
            action: { select(row.id) },
            leading: { Kit.IconTile(systemImage: "tag.fill", size: .small) },
            trailing: { EmptyView() }
        )
        .accessibilityLabel(([row.topic.name] + detail).joined(separator: ", "))
        .accessibilityAction(named: "Open topic") {
            select(row.id)
        }
        .accessibilityIdentifier("journal.topics.row")
    }

    /// A press also gives the list focus, so the arrow keys move on from the row the
    /// reader clicked. Choosing a topic leaves the draft in its row, words kept.
    private func select(_ id: String) {
        draft.isSelected = false
        selectedTopicID = id
        isListFocused = true
    }

    /// Up and down walk the draft row, then the topics, in list order.
    private func move(_ direction: MoveCommandDirection) {
        var ids: [String] = draft.isOpen ? [Self.draftRowID] : []
        ids += rows.map(\.id)
        let current = draft.isSelected ? Self.draftRowID : selectedTopicID
        guard let target = Self.step(direction, from: current, in: ids) else { return }
        if target == Self.draftRowID {
            draft.isSelected = true
        } else {
            draft.isSelected = false
            selectedTopicID = target
        }
        reveal = AnyHashable(target)
    }

    // MARK: Draft

    /// Opens the draft selected with its name field focused, or returns to the draft
    /// already open, keeping what was typed.
    private func openDraft() {
        draft.open(returningTo: selectedTopicID)
        reveal = AnyHashable(Self.draftRowID)
        isDraftNameFocused = true
    }

    /// Removes the draft and its words and returns to the topic the reader left, or to
    /// the first topic when that one is gone.
    private func cancelDraft() {
        let returnID = draft.returnTopicID
        draft.close()
        if let returnID, rows.contains(where: { $0.id == returnID }) {
            selectedTopicID = returnID
        } else if selectedTopicID == nil || !rows.contains(where: { $0.id == selectedTopicID }) {
            selectedTopicID = rows.first?.id
        }
        if let selectedTopicID {
            reveal = AnyHashable(selectedTopicID)
        }
    }

    /// A new topic is what the reader came to read next, so it becomes the selection
    /// and the draft closes behind it.
    private func addTopic() {
        guard !Self.isBlank(draft.name) else { return }
        let existing = Set(coordinator.memoryTopics.map(\.id))
        do {
            try coordinator.addTopic(name: draft.name, summary: draft.summary)
            draft.close()
            if let added = coordinator.memoryTopics.first(where: { !existing.contains($0.id) }) {
                selectedTopicID = added.id
                reveal = AnyHashable(added.id)
            }
        } catch {
            draft.refusal = Self.refusalText(error)
        }
    }

    private var draftPage: some View {
        Kit.PageColumn(identity: AnyHashable(Self.draftRowID)) {
            EmptyView()
        } content: {
            Kit.PageHeader(title: "New topic") {
                EmptyView()
            }

            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    Kit.Property("Name") {
                        TextField("Name", text: $draft.name, prompt: Text("Name").foregroundStyle(theme.text3))
                            .textFieldStyle(.roundedBorder)
                            .focused($isDraftNameFocused)
                            .onSubmit(addTopic)
                            .onAppear { isDraftNameFocused = true }
                            .accessibilityIdentifier("journal.topics.new.name")
                    }

                    Kit.Property("Summary") {
                        TextField(
                            "What belongs here, in one line",
                            text: $draft.summary,
                            prompt: Text("What belongs here, in one line").foregroundStyle(theme.text3)
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTopic)
                        .accessibilityIdentifier("journal.topics.new.summary")
                    }

                    // A refusal is said under the fields that caused it, in words that
                    // name what to change, rather than leaving them filled and unexplained.
                    if let refusal = draft.refusal {
                        JournalCaption(refusal, color: theme.critical.text)
                            .accessibilityIdentifier("journal.topics.new.refusal")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: VoiceourMetrics.Space.sm) {
                Spacer(minLength: 0)
                Kit.Button("Cancel", action: cancelDraft)
                    .keyboardShortcut(.cancelAction)
                    .help("Discard this topic")
                    .accessibilityIdentifier("journal.topics.new.cancel")
                Kit.Button("Add Topic", systemImage: "plus", prominence: .primary, action: addTopic)
                    .disabled(Self.isBlank(draft.name))
                    .accessibilityIdentifier("journal.topics.add")
            }
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

    private var sortingSection: some View {
        JournalSectionCard("Sorting") {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                JournalCaption(sortingCaption)
                    .accessibilityIdentifier("journal.topics.sort.status")

                if isSorting {
                    Kit.Button("Stop Sorting", systemImage: "stop.fill") {
                        coordinator.cancelSortEntries()
                    }
                    .help("Stop labelling entries; the ones already filed stay filed")
                    .accessibilityIdentifier("journal.topics.sort.stop")
                } else {
                    Kit.Button("Sort Entries", systemImage: "wand.and.stars") {
                        coordinator.sortEntries()
                    }
                    .help("File every entry that has no topic of yours")
                    .accessibilityIdentifier("journal.topics.sort")
                }
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
        if draft.isOpen && draft.isSelected {
            draftPage
        } else if let row = rows.first(where: { $0.id == selectedTopicID }) {
            page(row)
                .kitToast(flash, identifier: "journal.topics.copied")
        } else {
            Kit.EmptyState(
                systemImage: "tag",
                title: "No topic selected",
                message: "Select a topic to read everything filed under it."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func page(_ row: TopicRow) -> some View {
        Kit.PageColumn(identity: AnyHashable(row.id)) {
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

            Kit.Button("Delete Topic\u{2026}", systemImage: "trash", prominence: .destructive) {
                pendingDeletion = row.topic
            }
            .help("Delete this topic; its entries stay in memory")
            .accessibilityIdentifier("journal.topics.delete")
        } content: {
            Kit.PageHeader(
                kicker: "Topic",
                title: row.topic.name,
                meta: row.topic.summary.isEmpty
                    ? Self.counted(row.entryCount, "entry", "entries")
                    : row.topic.summary
            ) {
                EmptyView()
            }

            if !selectedTopicNotes.isEmpty {
                JournalSectionCard("From your agents") {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                        ForEach(selectedTopicNotes) { note in
                            if note.id != selectedTopicNotes.first?.id {
                                Kit.Rule()
                            }
                            JournalAgentNoteRow(note)
                                .accessibilityIdentifier("journal.topics.agent-note")
                        }
                    }
                }
            }

            entriesSection(row)

            // After the entries, because a topic is read far more often than it is
            // renamed or sorted.
            editSection(row.topic)

            if showsSorting {
                sortingSection
            }
        }
    }

    private func editSection(_ topic: MemoryTopic) -> some View {
        JournalSectionCard("Name and summary") {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                Kit.Property("Name") {
                    TextField("Name", text: $editedName, prompt: Text("Name").foregroundStyle(theme.text3))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(topic) }
                        .accessibilityIdentifier("journal.topics.name")
                }

                Kit.Property("Summary") {
                    TextField(
                        "Summary",
                        text: $editedSummary,
                        prompt: Text("What belongs here, in one line").foregroundStyle(theme.text3)
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(topic) }
                    .accessibilityIdentifier("journal.topics.summary")
                }

                if let saveRefusal {
                    JournalCaption(saveRefusal, color: theme.critical.text)
                        .accessibilityIdentifier("journal.topics.refusal")
                }

                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Spacer(minLength: 0)
                    Kit.Button("Save", systemImage: "checkmark") {
                        save(topic)
                    }
                    .disabled(!isEdited(topic))
                    .accessibilityIdentifier("journal.topics.save")
                }
            }
        }
    }

    /// The topic's entries by day. Lazy, because a topic can hold hundreds of entries
    /// and the page builds only the ones near the viewport.
    private func entriesSection(_ row: TopicRow) -> some View {
        JournalSectionCard("Entries") {
            if row.days.isEmpty {
                JournalCaption(
                    "Nothing is filed under this topic yet. File an entry from its menu in any lens."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    ForEach(row.days) { day in
                        JournalDayCaption(SessionsFormatters.dayHeader.string(from: day.day))
                            .padding(.top, day.id == row.days.first?.id ? 0 : VoiceourMetrics.Space.md)
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
