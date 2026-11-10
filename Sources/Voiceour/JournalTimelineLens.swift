import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Timeline: the transcripts this Mac kept, and what can be done with one.
///
/// A list of dictations grouped by day beside the page of the selected one. The list
/// is for finding a dictation — by its words, its day, its app or its agent session —
/// and the page is for using it: the words first, then the line that names the
/// gestures on them, the teach editor when it is open, and the folds that hold the
/// evidence. The page's glass bar carries the actions the transcript's own gestures
/// also reach, so a reader who never right-clicks still finds them.
///
/// The first visit selects the newest dictation, because a lens whose reason to exist
/// is the transcript should not open on a list of timestamps.
struct JournalTimelineLens: View {
    private let coordinator: DictationCoordinator
    /// A move another lens asked for, consumed once carried out. Nil wherever Timeline
    /// is hosted without the Journal.
    private let request: Binding<JournalTimelineRequest?>?
    /// The way back to the other lenses; nil hides Open Thread.
    private let navigation: JournalNavigation?

    @State private var selectedSessionID: RecentSession.ID?
    /// The selected row itself, which a query may hide from the list while the page
    /// keeps showing it. Cached, because finding it scans up to 500 rows.
    @State private var selectedSession: RecentSession?
    /// False until the lens has decided what to select once. After that only the
    /// reader moves the selection, and no reload selects behind their back.
    @State private var hasSeededSelection = RenderOverrides.historyStartsDeselected
    @State private var searchText = ""
    /// The one app the list is narrowed to, or nil for every app. Pinned by the
    /// harness because an `NSMenu` popup cannot be driven offscreen.
    @State private var appFilter: String? = RenderOverrides.historyInitialAppFilter
    /// The one agent session the list is narrowed to, or nil for every row. Engaged
    /// from a menu the offscreen harness cannot open, so the harness pins it.
    @State private var agentSessionFilter: AgentSessionKey? = RenderOverrides.historyInitialAgentSession
    @State private var appFacets: [RecentSessionAppFacet] = []
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// The row an arrow key or a request just selected, scrolled into view.
    @State private var revealedRowID: RecentSession.ID?
    /// The page element to scroll into view: the teach editor once it opens.
    @State private var pageReveal: String?

    // Derived data cached as @State snapshots, rebuilt on appear and when the rows,
    // their bindings, the query or a filter change (reloadDerivedData), so no body
    // pass re-sorts or re-filters the retained 500.
    @State private var filteredSessions: [RecentSession] = []
    @State private var dayGroups: [RecentSessionDayGroup] = []
    /// One collapsed preview line per session, built with the day groups. Collapsing
    /// newlines and trimming per row per body pass would cost a full pass over the
    /// retained 500 on every keystroke and every selection change.
    @State private var previews: [RecentSession.ID: String] = [:]

    @State private var pendingDeleteSession: RecentSession?
    @State private var deleteError: String?
    @State private var flash = Kit.Flash()
    @State private var isTeaching = false
    @State private var pendingFixTeachPrefill: ConsoleTeachPrefill?
    /// The words selected in the transcript, which ⌘T teaches.
    @State private var selectedSurface: String?
    /// The three folds under the transcript. Independent of one another, and all shut
    /// on every newly selected dictation: a reader who asked one of their questions
    /// has not asked the others.
    @State private var showsSentText = false
    @State private var showsRawTranscript = false
    @State private var showsSessionDetails = false

    private var a11y = A11y()

    /// The `.id` of the teach editor's island, which the page scrolls to when it opens.
    private static let teachAnchor = "sessions.teach.anchor"

    init(
        coordinator: DictationCoordinator,
        request: Binding<JournalTimelineRequest?>? = nil,
        navigation: JournalNavigation? = nil
    ) {
        self.coordinator = coordinator
        self.request = request
        self.navigation = navigation
    }

    var body: some View {
        Group {
            if coordinator.recentSessions.isEmpty {
                emptyHistory
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Kit.Split {
                    listColumn
                } page: {
                    pageColumn
                }
            }
        }
        .onAppear {
            applyJournalRequest()
            reloadDerivedData()
            coordinator.refreshAgentSessions()
        }
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            reloadDerivedData()
            coordinator.refreshAgentSessions()
        }
        // Rows are copied into the derived lists, and neither a binding nor a refresh
        // pass changes an id, so a binding lands on screen only through this reload.
        .onChange(of: coordinator.recentSessions.map(\.agentSession)) {
            reloadDerivedData()
        }
        .onChange(of: searchText) {
            reloadDerivedData()
        }
        .onChange(of: appFilter) {
            reloadDerivedData()
        }
        .onChange(of: agentSessionFilter) {
            reloadDerivedData()
        }
        .onChange(of: request?.wrappedValue) {
            applyJournalRequest()
        }
        .onChange(of: selectedSessionID) { _, newSelection in
            refreshSelectedSession()
            // A selected transcript's prompt may have been sent since the last pass.
            if newSelection != nil {
                coordinator.refreshAgentSessions()
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Transcript", role: .destructive) {
                if let session = pendingDeleteSession { confirmDelete(session) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: {
            Text("The transcript is removed from this Mac. Text you already pasted is not affected.")
        }
    }

    // MARK: Derived data

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNarrowed: Bool {
        !query.isEmpty || appFilter != nil || agentSessionFilter != nil
    }

    private func reloadDerivedData() {
        // Ordered by the label the menu will actually show, which the installed app
        // can rename out from under the persisted one ("Visual Studio Code" resolves
        // to "Code"). VoiceCore's own sort is the same total order over persisted
        // names, and stays that for its pure consumers.
        appFacets = Self.sortedByResolvedLabel(
            RecentSessionQuery.appFacets(in: coordinator.recentSessions)
        )
        // A filtered app whose every row was just deleted or cleared would leave the
        // list narrowed to nothing with no offered way back, so the filter falls away
        // with its last row.
        if let appFilter, !appFacets.contains(where: { $0.bundleId == appFilter }) {
            self.appFilter = nil
        }
        // Same for an agent session whose last bound row is gone, or whose bindings
        // were removed with the setting.
        if let agentSessionFilter,
            !coordinator.recentSessions.contains(where: { $0.agentSession?.key == agentSessionFilter })
        {
            self.agentSessionFilter = nil
        }
        let previous = filteredSessions
        let filtered = RecentSessionQuery.matches(
            in: coordinator.recentSessions,
            query: query,
            appBundleId: appFilter,
            agentSession: agentSessionFilter,
            timestamp: { SessionsFormatters.timestamp.string(from: $0) },
            dayHeader: { SessionsFormatters.dayHeader.string(from: $0) }
        )
        filteredSessions = filtered
        var collapsed = [RecentSession.ID: String](minimumCapacity: filtered.count)
        for session in filtered {
            collapsed[session.id] = Self.preview(of: session)
        }
        previews = collapsed
        dayGroups = RecentSessionQuery.dayGroups(
            of: filtered,
            calendar: RenderOverrides.calendar ?? Calendar.current
        )
        validateSelection(previous: previous)
        refreshSelectedSession()
    }

    /// Three rules. The first visit selects the newest dictation. After that only the
    /// reader moves the selection: a reload never selects what they left, and a query
    /// is a lens rather than an edit, so a search that hides the selected dictation
    /// keeps it on the page and clearing the query lists it again. The one exception
    /// is a dictation that no longer exists — deleted here, or erased with the whole
    /// history in System — whose list position passes to the row that took it.
    private func validateSelection(previous: [RecentSession]) {
        guard hasSeededSelection else {
            hasSeededSelection = true
            select(filteredSessions.first?.id)
            return
        }
        guard let selectedSessionID,
            !coordinator.recentSessions.contains(where: { $0.id == selectedSessionID })
        else { return }
        if let index = previous.firstIndex(where: { $0.id == selectedSessionID }), !filteredSessions.isEmpty {
            select(filteredSessions[min(index, filteredSessions.count - 1)].id)
        } else {
            select(nil)
        }
    }

    private func refreshSelectedSession() {
        selectedSession = selectedSessionID.flatMap { id in
            coordinator.recentSessions.first { $0.id == id }
        }
    }

    /// The one way the selection moves. Everything scoped to the page — the teach
    /// editor, the folds, the selected words, a failed delete's sentence — belongs to
    /// the dictation it was opened on, so a move to another dictation shuts it here,
    /// before any command that selected the row acts on it.
    private func select(_ id: RecentSession.ID?) {
        guard id != selectedSessionID else { return }
        pendingFixTeachPrefill = nil
        isTeaching = false
        deleteError = nil
        selectedSurface = nil
        pageReveal = nil
        showsSentText = false
        showsRawTranscript = false
        showsSessionDetails = false
        selectedSessionID = id
    }

    /// Carries out a move another Journal lens asked for, then consumes it, so the
    /// same request made again is carried out again. A row is selected with every
    /// filter cleared, because a filter that hid it would select a dictation the
    /// reader cannot find in the list. An agent session replaces the query and the
    /// app filter, because the reader asked for that session's rows and nothing
    /// narrower.
    private func applyJournalRequest() {
        guard let request, let pending = request.wrappedValue else { return }
        searchText = ""
        appFilter = nil
        switch pending {
        case .row(let id):
            agentSessionFilter = nil
            hasSeededSelection = true
            select(id)
            revealedRowID = id
        case .agentSession(let key):
            agentSessionFilter = key
        }
        request.wrappedValue = nil
    }

    // MARK: List column

    private var listColumn: some View {
        Kit.ListColumn(
            "Timeline",
            subtitle: listSubtitle,
            reveal: revealedRowID.map { AnyHashable($0) },
            focus: $listFocused,
            onMove: moveSelection
        ) {
            listBar
        } content: {
            if dayGroups.isEmpty {
                noMatches
                    .padding(.top, VoiceourMetrics.Space.xl)
            } else {
                ForEach(dayGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            row(for: session)
                        }
                    } header: {
                        Kit.GroupHeader(
                            SessionsFormatters.dayHeader.string(from: group.day),
                            detail: String(group.sessions.count)
                        )
                    }
                }
            }
        }
    }

    private var listSubtitle: String {
        let total = coordinator.recentSessions.count
        if isNarrowed {
            return "\(filteredSessions.count) of \(total) dictations match"
        }
        return total == 1 ? "1 dictation" : "\(total) dictations"
    }

    @ViewBuilder
    private var listBar: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Kit.GlassGroup {
                Kit.SearchField(
                    "Search dictations",
                    text: $searchText,
                    identifier: "sessions.search.field",
                    clearIdentifier: "sessions.search.clear",
                    focus: $searchFocused,
                    onSubmit: selectFirstMatch
                )

                if !appFacets.isEmpty {
                    appFilterMenu
                }
            }

            if appFilter != nil || agentSessionFilter != nil {
                Kit.GlassGroup {
                    if let appFilter {
                        Kit.FilterChip(
                            activeFilterLabel(appFilter),
                            systemImage: "app",
                            clearLabel: "Show all apps",
                            clearIdentifier: "sessions.app-filter.clear"
                        ) {
                            self.appFilter = nil
                        }
                    }
                    if let agentSessionFilter {
                        Kit.FilterChip(
                            agentSessionLabel(agentSessionFilter),
                            systemImage: "bubble.left.and.text.bubble.right",
                            clearLabel: "Show all agent sessions",
                            clearIdentifier: "sessions.agent-filter.clear"
                        ) {
                            self.agentSessionFilter = nil
                        }
                    }
                }
            }
        }
    }

    /// Narrows the list to one delivery target. A menu rather than a row of chips:
    /// the number of apps a reader dictates into is theirs, not this layout's, and the
    /// control keeps one width whether it offers two apps or twenty. The engaged
    /// filter is named by its chip under the search field.
    private var appFilterMenu: some View {
        Kit.MenuButton(
            "Filter by app",
            systemImage: appFilter == nil
                ? "line.3.horizontal.decrease"
                : "line.3.horizontal.decrease.circle.fill",
            showsTitle: false,
            help: "Show dictations from one app",
            identifier: "sessions.filter"
        ) {
            Picker("Filter by app", selection: $appFilter) {
                Text("All Apps").tag(String?.none)
                ForEach(appFacets) { facet in
                    Text("\(facetLabel(facet)) (\(facet.count))").tag(String?.some(facet.bundleId))
                }
            }
            .pickerStyle(.inline)
        }
    }

    @MainActor
    private func facetLabel(_ facet: RecentSessionAppFacet) -> String {
        AppIdentity.resolve(bundleId: facet.bundleId, persistedName: facet.name).label
    }

    /// The newest bound row's name for an agent session, which carries the session's
    /// latest title; the agent's name if no row is bound to it.
    private func agentSessionLabel(_ key: AgentSessionKey) -> String {
        coordinator.recentSessions.lazy
            .compactMap(\.agentSession)
            .first { $0.key == key }?
            .displayTitle ?? key.agent.displayName
    }

    /// `RecentSessionQuery.appFacets`' own total order — count desc, then label, then
    /// bundle id — re-applied over the labels this surface displays. Only the middle
    /// key can differ, and only for an installed app whose own name is not the one the
    /// row persisted.
    @MainActor
    private static func sortedByResolvedLabel(
        _ facets: [RecentSessionAppFacet]
    ) -> [RecentSessionAppFacet] {
        facets
            .map { (facet: $0, label: AppIdentity.resolve(bundleId: $0.bundleId, persistedName: $0.name).label) }
            .sorted { lhs, rhs in
                if lhs.facet.count != rhs.facet.count { return lhs.facet.count > rhs.facet.count }
                let comparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.facet.bundleId < rhs.facet.bundleId
            }
            .map(\.facet)
    }

    /// The engaged filter's label, resolved through the facets so it names the app
    /// the same way the menu just did.
    @MainActor
    private func activeFilterLabel(_ bundleId: String) -> String {
        AppIdentity.resolve(
            bundleId: bundleId,
            persistedName: appFacets.first { $0.bundleId == bundleId }?.name
        ).label
    }

    /// Return in the search field selects the first match and hands focus to the
    /// list, so the arrow keys move on from there, instead of re-running the filter
    /// every keystroke has already run.
    private func selectFirstMatch() {
        guard let first = filteredSessions.first else { return }
        select(first.id)
        revealedRowID = first.id
        searchFocused = false
        listFocused = true
    }

    /// Up and Down step through the listed rows, newest first. A selection the query
    /// hides has no place in the list, so the first key press starts at the top.
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredSessions.isEmpty else { return }
        let current = selectedSessionID.flatMap { id in filteredSessions.firstIndex { $0.id == id } }
        let next: Int
        switch direction {
        case .up: next = current.map { max($0 - 1, 0) } ?? 0
        case .down: next = current.map { min($0 + 1, filteredSessions.count - 1) } ?? 0
        default: return
        }
        let id = filteredSessions[next].id
        select(id)
        revealedRowID = id
    }

    // MARK: Empty states

    private var emptyHistory: some View {
        ContentUnavailableView {
            Text("No dictations yet")
        } description: {
            Text("Completed dictations are kept here with their transcripts, timestamps and word counts.")
        } actions: {
            ConsoleHotkeyHint()
        }
    }

    /// Each filter is validated against the rows, so neither can rule out every row on
    /// its own; a query can, and so can the app and agent-session filters together.
    /// Whatever narrowed the list is named and offered back.
    private var noMatches: some View {
        ContentUnavailableView {
            if query.isEmpty {
                Text("Nothing matches these filters")
            } else if let appFilter {
                Text("Nothing matches \u{201C}\(query)\u{201D} in \(activeFilterLabel(appFilter))")
            } else {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
            }
        } description: {
            Text("Search runs over transcript text, timestamps and day names.")
        } actions: {
            if !query.isEmpty {
                Button("Clear Search") { searchText = "" }
            }
            if appFilter != nil {
                Button("Show All Apps") { appFilter = nil }
            }
            if agentSessionFilter != nil {
                Button("Show All Agent Sessions") { agentSessionFilter = nil }
            }
        }
    }

    // MARK: Rows

    private func row(for session: RecentSession) -> some View {
        Kit.PreviewRow(
            previewText(for: session),
            isSelected: session.id == selectedSessionID,
            action: {
                select(session.id)
                listFocused = true
            }
        ) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Text(SessionsFormatters.timestamp.string(from: session.createdAt))
                    .font(Kit.Fonts.stamp)

                if session.mutedDuringCapture {
                    mutedGlyph
                }

                // Where it went, with the app's own icon while this Mac still has the
                // app: a reader recognises a scanned list of destinations by icon
                // faster than by reading five small words.
                if let bundleId = session.outcome?.targetBundleId {
                    let identity = appIdentity(for: session, bundleId: bundleId)
                    Kit.AppLabel(Self.destinationName(for: session, appLabel: identity.label), icon: identity.icon)
                }
            }
        } marks: {
            if let outcome = session.outcome {
                Kit.Mark(outcome.outcomeMark.label, tone: outcome.outcomeMark.tone)
            }
            // The paste reached the pane but the agent never took it as a prompt:
            // without this mark the row reads PASTED and looks done.
            if session.agentSession?.isNotSent == true {
                Kit.Mark("NOT SENT", tone: .caution)
            }
        }
        .accessibilityLabel(accessibilityLabel(for: session))
        // The record-level commands, on the record. Each one selects the row it acts
        // on, so its result shows on the page beside where the click landed.
        .contextMenu {
            Button("Copy Transcript") {
                select(session.id)
                copy(session.text, announcement: "Transcript copied to clipboard")
            }
            Button("Fix / Teach a Word\u{2026}") {
                select(session.id)
                beginTeaching(surface: nil)
            }
            if let bundleId = session.outcome?.targetBundleId {
                Button("Show Only \(appLabel(for: session, bundleId: bundleId))") {
                    appFilter = bundleId
                }
            }
            if let binding = session.agentSession {
                if let navigation {
                    Button("Open Thread") {
                        navigation.openThread(binding.key)
                    }
                }
                Button("Show Only This Agent Session") {
                    agentSessionFilter = binding.key
                }
                if binding.resumable {
                    Button("Copy Resume Command") {
                        select(session.id)
                        copy(binding.resumeCommand, announcement: "Resume command copied to clipboard")
                    }
                }
                // No confirmation: the row keeps its text, and its Agent fact changes
                // at once, so the result is plain where the click landed.
                Button("Unlink from Thread") {
                    select(session.id)
                    coordinator.unlinkThread(rowID: session.id)
                }
            }
            Button("Delete Transcript\u{2026}", role: .destructive) {
                requestDelete(session)
            }
        }
        .id(session.id)
    }

    private var mutedGlyph: some View {
        Image(systemName: "mic.slash.fill")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help("System audio muted for this recording.")
            .accessibilityLabel("Recorded with system audio muted")
    }

    private func previewText(for session: RecentSession) -> String {
        previews[session.id] ?? Self.preview(of: session)
    }

    /// The row's destination, as its icon and the name a reader would use for it: the
    /// installed app's own name, else the name persisted with the row, else its bundle
    /// id humanized, so no row shows a reverse-DNS string and no row shows a name the
    /// app has since changed.
    @MainActor
    private func appIdentity(for session: RecentSession, bundleId: String) -> AppIdentity {
        .resolve(bundleId: bundleId, persistedName: session.outcome?.targetAppName)
    }

    /// The same destination where only the name is wanted: the filter command, the
    /// page's title and Target fact, and the row's spoken label.
    @MainActor
    private func appLabel(for session: RecentSession, bundleId: String) -> String {
        appIdentity(for: session, bundleId: bundleId).label
    }

    /// A bound row names its thread rather than its app: every bound row went to the
    /// same terminal, so the app name tells rows apart by nothing, while the thread
    /// names the conversation the words joined.
    private static func destinationName(for session: RecentSession, appLabel: String) -> String {
        session.agentSession?.displayTitle ?? appLabel
    }

    /// Collapses a transcript to the list's one preview string.
    private static func preview(of session: RecentSession) -> String {
        let collapsed = session.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty transcript" : collapsed
    }

    /// The whole row in one sentence, in the order a reader would say it, ending with
    /// the preview the row shows.
    private func accessibilityLabel(for session: RecentSession) -> String {
        var parts = [SessionsFormatters.timestamp.string(from: session.createdAt)]
        if let outcome = session.outcome {
            parts.append(outcome.outcomeMark.label)
            if session.agentSession?.isNotSent == true {
                parts.append("NOT SENT")
            }
            if let bundleId = outcome.targetBundleId {
                let destination = Self.destinationName(
                    for: session,
                    appLabel: appLabel(for: session, bundleId: bundleId)
                )
                parts.append("to \(destination)")
            }
        }
        parts.append(SessionsFormatters.wordCountLabel(session.wordCount, pluralOnly: true))
        if session.mutedDuringCapture {
            parts.append("recorded with system audio muted")
        }
        parts.append(previewText(for: session))
        return parts.joined(separator: ", ")
    }

    // MARK: Page column

    private var pageColumn: some View {
        Group {
            if let session = selectedSession {
                page(for: session)
            } else {
                ContentUnavailableView(
                    "No dictation selected",
                    systemImage: "text.quote",
                    description: Text("Select a dictation to read it, copy it or teach a word from it.")
                )
            }
        }
        .kitToast(flash, identifier: "sessions.detail.copied")
    }

    private func page(for session: RecentSession) -> some View {
        Kit.PageColumn(identity: AnyHashable(session.id), reveal: pageReveal.map { AnyHashable($0) }) {
            pageBar(for: session)
        } content: {
            pageHeader(for: session)

            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                transcript(for: session)
                gestureCaption
                if let deleteError {
                    ConsoleCaption(deleteError, color: .red)
                }
            }

            if isTeachingOpen {
                Kit.Island {
                    ConsoleTeachHost(
                        coordinator: coordinator,
                        session: session,
                        externalPrefill: $pendingFixTeachPrefill,
                        isEditing: $isTeaching
                    )
                    .id(session.id)
                }
                .id(Self.teachAnchor)
            }

            folds(for: session)
        }
    }

    private func pageBar(for session: RecentSession) -> some View {
        Kit.GlassGroup {
            Kit.ActionButton("Copy", systemImage: "doc.on.doc", prominence: .primary) {
                copy(session.text, announcement: "Transcript copied to clipboard")
            }
            .help("Copy the transcript")
            .accessibilityIdentifier("sessions.detail.copy")

            Kit.ActionButton("Fix / Teach", systemImage: "character.cursor.ibeam") {
                beginTeaching(surface: selectedSurface)
            }
            .keyboardShortcut("t", modifiers: .command)
            .help("Teach a correction for the selected words (\u{2318}T)")
            .accessibilityIdentifier("sessions.detail.teach")

            if let binding = session.agentSession, let navigation {
                Kit.ActionButton("Open Thread", systemImage: "bubble.left.and.text.bubble.right") {
                    navigation.openThread(binding.key)
                }
                .help("Open this dictation's agent session in Threads")
                .accessibilityIdentifier("sessions.detail.thread")
            }

            Kit.MenuButton("More", systemImage: "ellipsis", showsTitle: false, identifier: "sessions.detail.more") {
                moreMenuItems(for: session)
            }
        }
    }

    @ViewBuilder
    private func moreMenuItems(for session: RecentSession) -> some View {
        if let bundleId = session.outcome?.targetBundleId {
            Button("Show Only \(appLabel(for: session, bundleId: bundleId))") {
                appFilter = bundleId
            }
        }
        if let binding = session.agentSession {
            Button("Show Only This Agent Session") {
                agentSessionFilter = binding.key
            }
            if binding.resumable {
                Button("Copy Resume Command") {
                    copy(binding.resumeCommand, announcement: "Resume command copied to clipboard")
                }
            }
            Button("Unlink from Thread") {
                coordinator.unlinkThread(rowID: session.id)
            }
        }
        Divider()
        Button("Delete Transcript\u{2026}", role: .destructive) {
            requestDelete(session)
        }
    }

    /// When, what and how much: the day and time, the thread or app the words went
    /// to, and how they were delivered, then the marks the row carries.
    private func pageHeader(for session: RecentSession) -> some View {
        Kit.PageHeader(
            eyebrow: "\(SessionsFormatters.dayHeader.string(from: session.createdAt)) at "
                + SessionsFormatters.timestamp.string(from: session.createdAt),
            title: pageTitle(for: session),
            subtitle: pageSubtitle(for: session)
        ) {
            if hasHeaderMarks(session) {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    if let outcome = session.outcome {
                        Kit.Mark(outcome.outcomeMark.label, tone: outcome.outcomeMark.tone)
                        if let targetSafety = outcome.targetSafety, targetSafety != .normalText {
                            Kit.Mark(targetSafety.displayLabel)
                        }
                    }
                    if session.agentSession?.isNotSent == true {
                        Kit.Mark("NOT SENT", tone: .caution)
                    }
                    if session.mutedDuringCapture {
                        mutedGlyph
                    }
                }
            }
        }
    }

    private func hasHeaderMarks(_ session: RecentSession) -> Bool {
        session.outcome != nil || session.agentSession?.isNotSent == true || session.mutedDuringCapture
    }

    private func pageTitle(for session: RecentSession) -> String {
        if let binding = session.agentSession {
            return binding.displayTitle
        }
        if let bundleId = session.outcome?.targetBundleId {
            return appLabel(for: session, bundleId: bundleId)
        }
        return "Dictation"
    }

    /// How the words were delivered, as a sentence rather than the mark's one word.
    private func deliverySentence(for session: RecentSession) -> String {
        guard let outcome = session.outcome else { return "Dictation" }
        let app = outcome.targetBundleId.map { appLabel(for: session, bundleId: $0) }
        switch outcome.disposition {
        case .pasteAttempted: return app.map { "Pasted into \($0)" } ?? "Pasted"
        case .copiedOnly: return app.map { "Copied for \($0)" } ?? "Copied to the clipboard"
        case .failed: return "Delivery failed"
        }
    }

    /// The word count, after the delivery sentence on a bound row, whose title names the
    /// thread rather than the app the words were pasted into. An unbound row's title is
    /// already that app, and its mark already says how they arrived.
    private func pageSubtitle(for session: RecentSession) -> String {
        let words = SessionsFormatters.wordCountLabel(session.wordCount)
        guard session.agentSession != nil else { return words }
        return "\(deliverySentence(for: session)) \u{00B7} \(words)"
    }

    /// The transcript, on its own island. A plain click copies it, and a selection plus
    /// ⌘T (or a right-click) teaches a correction. Under Reduce Transparency the island
    /// is opaque, so the one place in the window that holds arbitrary user text and
    /// supports selection never sits on a translucent surface.
    private func transcript(for session: RecentSession) -> some View {
        Kit.Island {
            SelectableTranscriptText(
                identity: session.id,
                text: session.text.isEmpty ? "Empty transcript" : session.text,
                fontSize: Kit.Fonts.readingLarge,
                onFixTeach: { word in
                    beginTeaching(surface: word)
                },
                onSelectionChange: { selectedSurface = $0 },
                onPlainClick: { copy(session.text, announcement: "Transcript copied to clipboard") }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
        .accessibilityValue(
            "\(SessionsFormatters.wordCountLabel(session.wordCount)), "
                + "recorded \(SessionsFormatters.detailStamp.string(from: session.createdAt))"
        )
        .accessibilityIdentifier("sessions.detail.transcript")
        // VoiceOver cannot click into a text view to copy it or drag a selection to
        // teach from it, so both gestures are named actions on the same element.
        .accessibilityAction(named: "Copy transcript") {
            copy(session.text, announcement: "Transcript copied to clipboard")
        }
        .accessibilityAction(named: "Teach a correction") { beginTeaching(surface: selectedSurface) }
    }

    /// One line under the transcript: what ⌘T will teach, or how to reach either
    /// gesture. A line of prose can say which words the next keystroke will teach,
    /// which a button title cannot without becoming a paragraph.
    @ViewBuilder
    private var gestureCaption: some View {
        if let surface = selectedSurface, !surface.isEmpty {
            ConsoleCaption(
                "Press \u{2318}T to teach a correction for \u{201C}\(Self.shortened(surface))\u{201D}. "
                    + "Teaching changes future dictation only."
            )
        } else {
            ConsoleCaption(
                "Click the transcript to copy it. Select any words, or right-click one, then press "
                    + "\u{2318}T to teach a correction."
            )
        }
    }

    /// Trims an arbitrary user selection for the caption. A selection can be the whole
    /// transcript, and the line that names it is one sentence.
    private static func shortened(_ surface: String, budget: Int = 28) -> String {
        // `count` walks the whole string and a selection can be the whole transcript;
        // this stops one character past the budget.
        guard surface.index(surface.startIndex, offsetBy: budget + 1, limitedBy: surface.endIndex) != nil
        else { return surface }
        let head = (budget - 1) / 2
        return "\(surface.prefix(head))\u{2026}\(surface.suffix(budget - 1 - head))"
    }

    /// Opens the teach editor, prefilled with `surface` when one is known, and
    /// scrolls it into view. Only an explicit gesture — ⌘T, Fix / Teach, or a
    /// transcript or row menu item — reaches here; no automatic path teaches.
    private func beginTeaching(surface: String?) {
        if let surface, !surface.isEmpty {
            pendingFixTeachPrefill = ConsoleTeachPrefill(word: surface)
        }
        isTeaching = true
        // The editor joins the page in this update, so the scroll waits for the next
        // one, and clearing first lets a second ⌘T scroll to it again.
        pageReveal = nil
        Task { @MainActor in
            pageReveal = Self.teachAnchor
        }
    }

    /// Whether the teach editor sits under the transcript. The harness pins it open
    /// because ⌘T cannot be delivered to a window that never becomes key, and seeding
    /// the state instead would not survive: selecting a dictation closes the editor,
    /// and Timeline selects its newest one on arrival. Production reads the seam as
    /// nil and answers with the state the reader put it in.
    private var isTeachingOpen: Bool {
        isTeaching || RenderOverrides.historyTeachSurface != nil
    }

    // MARK: Folds

    /// The evidence about the transcript, each fold shut until asked for: the prompt
    /// as its agent received it, the pre-cleanup text, and the record's measurements.
    @ViewBuilder
    private func folds(for session: RecentSession) -> some View {
        let sent = session.agentSession?.sentText
        let raw = rawTranscript(for: session)
        let hasDetails = hasSessionDetails(for: session)
        if sent != nil || raw != nil || hasDetails {
            Kit.Island {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    // Only where the prompt differs from the delivered text: edited, or
                    // with words added around it.
                    if let sent {
                        Kit.Disclosure("Sent", isExpanded: $showsSentText, identifier: "sessions.detail.sent") {
                            metadataText(sent, mono: false)
                        }
                    }

                    // Only where cleanup changed the text. At dictation length it is a wall
                    // of monospaced text several times the height of any other fold, read
                    // to answer one narrow question.
                    if let raw {
                        Kit.Disclosure("Raw", isExpanded: $showsRawTranscript, identifier: "sessions.detail.raw") {
                            metadataText(raw, mono: true)
                        }
                    }

                    if hasDetails {
                        Kit.Disclosure(
                            "Details",
                            isExpanded: $showsSessionDetails,
                            identifier: "sessions.detail.details"
                        ) {
                            details(for: session)
                        }
                    }
                }
            }
        }
    }

    private func details(for session: RecentSession) -> some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            targetFact(for: session)

            if let binding = session.agentSession {
                agentFact(binding)
            } else if let miss = session.unlinked {
                unlinkedFact(miss)
            }

            if let stages = session.stages {
                Kit.Fact("Timings") {
                    metadataText(stages.detailLine, mono: false)
                }
            }

            if let leastSure = session.leastConfidentWord {
                leastSureFact(leastSure)
            }
        }
    }

    /// Whether this record knows anything about where its text went: a destination
    /// app, or a safety class that was not ordinary text — the reason a transcript
    /// that reads as pasted was only copied.
    private func hasTargetDetails(for session: RecentSession) -> Bool {
        guard let outcome = session.outcome else { return false }
        return outcome.targetBundleId != nil || (outcome.targetSafety ?? .normalText) != .normalText
    }

    /// Whether anything at all sits behind the Details fold. A record with no target,
    /// no agent session or missed link, no stage timings and no least sure word draws
    /// no empty fold.
    private func hasSessionDetails(for session: RecentSession) -> Bool {
        hasTargetDetails(for: session) || session.agentSession != nil || session.unlinked != nil
            || session.stages != nil || session.leastConfidentWord != nil
    }

    /// What received the text, and — only when it was not ordinary text — the class of
    /// that target.
    @ViewBuilder
    private func targetFact(for session: RecentSession) -> some View {
        if let outcome = session.outcome, hasTargetDetails(for: session) {
            Kit.Fact("Target") {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if let bundleId = outcome.targetBundleId {
                        Text(appLabel(for: session, bundleId: bundleId))
                            .font(Kit.Fonts.rowBody)
                    }
                    if let targetSafety = outcome.targetSafety, targetSafety != .normalText {
                        Kit.Mark(targetSafety.displayLabel)
                    }
                }
            }
        }
    }

    /// The agent session the text was pasted into: its name, then the working
    /// directory and session id a resume needs, and whether the dictation was never
    /// sent from it. Nothing is said while the send check is pending.
    private func agentFact(_ binding: AgentSessionBinding) -> some View {
        Kit.Fact("Agent") {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(binding.displayTitle)
                    .font(Kit.Fonts.rowBody)
                    .accessibilityIdentifier("sessions.detail.agent")
                Text(binding.isNotSent ? "\(binding.locationLine) · Not sent" : binding.locationLine)
                    .font(Kit.Fonts.meta.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(binding.workingDirectory ?? binding.sessionId)
                if binding.evidence == .words {
                    // A words link was found later in the agent's own prompt log, not
                    // seen in the focused pane, so the reader is told which.
                    Text("Linked by its words")
                        .font(Kit.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sessions.detail.evidence")
                }
            }
        }
    }

    /// Why a paste that was eligible for linking has no agent session, under the label
    /// a bound row uses, so a reader looking for the session finds the reason in the
    /// same place.
    private func unlinkedFact(_ miss: AgentLinkMiss) -> some View {
        Kit.Fact("Agent") {
            Text("Not linked. \(miss.sentence)")
                .font(Kit.Fonts.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sessions.detail.unlinked")
        }
    }

    /// The decoder's least sure word for this dictation, with its per-token
    /// probability. Not calibrated, and not a control: a reader who wants to correct
    /// it selects it in the transcript and presses ⌘T, like any other word.
    private func leastSureFact(_ leastSure: LeastConfidentWord) -> some View {
        Kit.Fact("Least sure") {
            Text("\(leastSure.text) · \(Int(leastSure.score * 100))%")
                .font(Kit.Fonts.meta.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(leastSure.text)
        }
    }

    /// Only where cleanup actually changed the text: a raw line identical to the final
    /// one is not evidence of anything.
    private func rawTranscript(for session: RecentSession) -> String? {
        guard let raw = session.rawTranscript,
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                != session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return raw
    }

    /// One styling site for every measured value and folded text on the page.
    private func metadataText(_ value: String, mono: Bool) -> some View {
        Text(value)
            .font(mono ? Kit.Fonts.rowBody.monospaced() : Kit.Fonts.rowBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            // Keep mouse selection while exposing the text once, not both the native
            // selection wrapper and its identical accessibility child.
            .accessibilityRepresentation { Text(value) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    /// The toast and the announcement are claims about the clipboard, so a refused
    /// write shows neither.
    private func copy(_ text: String, announcement: String) {
        guard GeneralPasteboard.copy(text) != nil else { return }
        flash.show(announcement, animation: Kit.Motion.quick(a11y))
    }

    private func requestDelete(_ session: RecentSession) {
        select(session.id)
        deleteError = nil
        pendingDeleteSession = session
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteSession != nil },
            set: { isPresented in
                guard !isPresented else { return }
                pendingDeleteSession = nil
            }
        )
    }

    private func confirmDelete(_ session: RecentSession) {
        deleteError = nil
        Task {
            let isDurable = await coordinator.deleteRecentSession(id: session.id)
            pendingDeleteSession = nil
            // A destructive action that half-succeeds must say so: the page that asked
            // for it reports that the transcript survived on disk instead of reporting
            // nothing.
            guard isDurable else {
                deleteError = "Could not delete this dictation — it is still on disk. Try again."
                return
            }
        }
    }
}
