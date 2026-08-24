import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// History: the transcripts this Mac kept, and what can be done with one.
///
/// One scrolling grouped form with exactly one transcript open. The open one takes
/// its own plate inside its day, directly under the row that selected it, and
/// carries its actions above the text: what you can do with it, then the words,
/// then the evidence. Every closed row recedes while it is open, so the page has
/// one subject rather than a detail wedged into an undifferentiated list.
///
/// The detail used to be a single `Section("Transcript")` emitted after every day
/// group, which put it below the entire list — with the nine-session fixture at
/// the app's own launch height the transcript started 211 pt under the fold, and a
/// real history of 500 transcripts puts it a page-down away.
///
/// The two-column master/detail card layout that preceded that existed to give the
/// detail a fixed reading window beside a fixed-height list; a form scrolls as one
/// document, so the transcript sizes to its own text instead of scrolling inside a
/// nested viewport.
struct ConsoleHistoryTab: View {
    var coordinator: DictationCoordinator

    @State private var selectedSessionID: RecentSession.ID?
    /// False until the tab has decided what to open once. After that a nil
    /// selection is the reader's own answer — they closed the transcript — and no
    /// later reload may reopen one behind their back.
    @State private var hasSeededSelection = RenderOverrides.historyStartsDeselected
    @State private var searchText = ""
    /// The one app history is narrowed to, or nil for every app. Pinned by the
    /// harness because an `NSMenu` popup cannot be driven offscreen.
    @State private var appFilter: String? = RenderOverrides.historyInitialAppFilter
    @State private var appFacets: [RecentSessionAppFacet] = []
    @FocusState private var searchFocused: Bool

    // Derived data cached as @State snapshots, recomputed on appear and when the
    // session list or search text changes (reloadDerivedData). Prevents
    // re-sorting/re-filtering the full list on every body pass and every per-row
    // selection read.
    @State private var filteredSessions: [RecentSession] = []
    @State private var dayGroups: [RecentSessionDayGroup] = []

    @State private var pendingDeleteSession: RecentSession?
    @State private var isDeletePersistencePending = false
    @State private var deleteError: String?
    @State private var copiedSessionID: RecentSession.ID?
    @State private var resetCopyFeedbackTask: Task<Void, Never>?
    @State private var isTeaching = false
    @State private var pendingFixTeachPrefill: ConsoleTeachPrefill?
    @State private var selectedSurface: String?
    /// Whether the open transcript's raw text is unfolded. Detail-scoped, so it
    /// closes again with the transcript it was opened on.
    @State private var showsRawTranscript = false
    /// One collapsed preview line per session, built with the day groups.
    /// Collapsing newlines and trimming is two string copies, and recomputing it
    /// per row per body pass costs a full pass over the retained 500 on every
    /// keystroke and every selection change.
    @State private var previews: [RecentSession.ID: String] = [:]

    /// Reports the three inputs SwiftUI cannot see in a grouped form: a click beside
    /// the plates, Escape, and Command-T. Held as state so the tab installs exactly
    /// one monitor.
    @State private var inputMonitor = HistoryInputMonitor()

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        // Both resolved once per body pass rather than once per row: the row used to
        // ask `selectedSession`, which scans the filtered list, and history retains
        // up to 500 transcripts. Rows recede only while the open transcript is
        // actually on screen — a query that hides it must not dim every row it left
        // visible with no subject to dim them for.
        let selectedID = selectedSessionID
        let recedes = selectedID.map { id in filteredSessions.contains { $0.id == id } } ?? false

        Form {
            if hasSessions {
                Section {
                    searchRow
                }

                ForEach(dayGroups) { group in
                    daySections(group, selectedID: selectedID, recedes: recedes)
                }

                if dayGroups.isEmpty {
                    Section {
                        noMatches
                    }
                }
            } else {
                Section {
                    emptyHistory
                }
            }
        }
        .formStyle(.grouped)
        // The margin click, Escape and Command-T are AppKit's to report: a grouped
        // form swallows all three before SwiftUI can offer them to a gesture.
        // `HistoryInputMonitor` records what was measured.
        .onAppear {
            inputMonitor.onDeselect = deselect
            inputMonitor.onTeach = { beginTeaching(surface: selectedSurface) }
            inputMonitor.start()
            reloadDerivedData()
        }
        .onDisappear {
            inputMonitor.stop()
            resetCopyFeedbackTask?.cancel()
        }
        .onChange(of: isTeaching) { _, teaching in
            inputMonitor.defersEscape = teaching
        }
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            reloadDerivedData()
        }
        .onChange(of: searchText) {
            reloadDerivedData()
        }
        .onChange(of: appFilter) {
            reloadDerivedData()
        }
        .onChange(of: selectedSessionID) { _, newSelection in
            pendingFixTeachPrefill = nil
            isTeaching = false
            deleteError = nil
            selectedSurface = nil
            showsRawTranscript = false
            // A row's own Copy command selects the row it copied, so retiring the
            // confirmation unconditionally here would erase the mark that copy just
            // asked for. Only a move to a different transcript retires it.
            guard copiedSessionID != newSelection else { return }
            resetCopyFeedbackTask?.cancel()
            copiedSessionID = nil
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

    private var hasSessions: Bool {
        !coordinator.recentSessions.isEmpty
    }

    private func reloadDerivedData() {
        // Ordered by the label the menu will actually show, which the installed
        // app can rename out from under the persisted one ("Visual Studio Code"
        // resolves to "Code"). VoiceCore's own sort is the same total order over
        // persisted names, and stays that for its pure consumers.
        appFacets = Self.sortedByResolvedLabel(
            RecentSessionQuery.appFacets(in: coordinator.recentSessions)
        )
        // A filtered app whose every row was just deleted or cleared would leave
        // the list narrowed to nothing with no offered way back, so the filter
        // falls away with its last row.
        if let appFilter, !appFacets.contains(where: { $0.bundleId == appFilter }) {
            self.appFilter = nil
        }
        let filtered = RecentSessionQuery.matches(
            in: coordinator.recentSessions,
            query: query,
            appBundleId: appFilter,
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
        validateSelection()
    }

    /// Three rules. The first visit opens the newest transcript, because a tab whose
    /// reason to exist is the transcript should not open on a list of timestamps.
    /// After that only the reader moves the selection — a reload never reopens what
    /// they closed, and a query is a lens rather than an edit, so a search that hides
    /// the open transcript leaves it open behind the query and clearing the query
    /// shows it again. The one exception is a transcript that no longer exists:
    /// deleted here, or erased with the whole history in System.
    private func validateSelection() {
        guard hasSeededSelection else {
            hasSeededSelection = true
            selectedSessionID = filteredSessions.first?.id
            return
        }
        guard let selectedSessionID,
            !coordinator.recentSessions.contains(where: { $0.id == selectedSessionID })
        else { return }
        self.selectedSessionID = nil
    }

    /// Closes the open transcript. Nothing is open, nothing is dimmed, and the list
    /// reads as a list until the reader picks a record again.
    private func deselect() {
        guard selectedSessionID != nil else { return }
        selectedSessionID = nil
    }

    // MARK: Search

    private var searchRow: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search transcripts or timestamps", text: $searchText)
                    .focused($searchFocused)
                    .onSubmit(selectFirstMatch)
                    .accessibilityIdentifier("sessions.search.field")

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
                    .accessibilityIdentifier("sessions.search.clear")
                }

                if !appFacets.isEmpty {
                    appFilterMenu
                }
            }

            if !query.isEmpty || appFilter != nil {
                ConsoleCaption("\(filteredSessions.count) of \(coordinator.recentSessions.count) sessions match")
            }
        }
        // The search row shares its plate with every other row, so its own width is
        // the column's width. Measured here rather than on the form, whose frame is
        // the whole tab: the margin the click has to land in is the difference.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { publishColumn(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in publishColumn(frame) }
            }
        )
    }

    /// Narrows the list to one delivery target. A menu rather than a row of
    /// chips: the number of apps a reader dictates into is theirs, not this
    /// layout's, and the control keeps one width whether it offers two apps or
    /// twenty.
    private var appFilterMenu: some View {
        Menu {
            Picker("Filter by app", selection: $appFilter) {
                Text("All Apps").tag(String?.none)
                ForEach(appFacets) { facet in
                    Text("\(facetLabel(facet)) (\(facet.count))").tag(String?.some(facet.bundleId))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                Image(
                    systemName: appFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
                if let appFilter {
                    Text(activeFilterLabel(appFilter)).lineLimit(1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show sessions from one app")
        .accessibilityLabel(appFilter.map { "Filtering by \(activeFilterLabel($0))" } ?? "Filter by app")
        .accessibilityIdentifier("sessions.filter")
    }

    @MainActor
    private func facetLabel(_ facet: RecentSessionAppFacet) -> String {
        AppIdentity.resolve(bundleId: facet.bundleId, persistedName: facet.name).label
    }

    /// `RecentSessionQuery.appFacets`' own total order — count desc, then label,
    /// then bundle id — re-applied over the labels this surface displays. Only
    /// the middle key can differ, and only for an installed app whose own name
    /// is not the one the row persisted.
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

    /// The engaged filter's label, resolved through the facets so it names the
    /// app the same way the menu just did.
    @MainActor
    private func activeFilterLabel(_ bundleId: String) -> String {
        AppIdentity.resolve(
            bundleId: bundleId,
            persistedName: appFacets.first { $0.bundleId == bundleId }?.name
        ).label
    }

    /// The plates' x range, widened by one row inset so the few points between a
    /// plate's edge and its row's edge still read as inside the record rather than
    /// beside it.
    private func publishColumn(_ rowFrame: CGRect) {
        let inset = VoiceourMetrics.Space.md
        inputMonitor.columnX = (rowFrame.minX - inset)...(rowFrame.maxX + inset)
    }

    /// Return in the search field moves the selection to the first match and
    /// hands focus back to the results, instead of re-running the filter that
    /// every keystroke has already run.
    private func selectFirstMatch() {
        guard let first = filteredSessions.first else { return }
        selectedSessionID = first.id
        searchFocused = false
    }

    // MARK: Empty states

    private var emptyHistory: some View {
        ContentUnavailableView {
            Text("No sessions yet")
        } description: {
            Text("Completed dictations are kept here with their transcripts, timestamps and word counts.")
        } actions: {
            ConsoleHotkeyHint()
        }
    }

    /// Empty results imply a non-empty query: a filter validated against the
    /// facets can never rule out every row on its own. It can still be the
    /// reason a query found nothing, so it is named and offered back.
    private var noMatches: some View {
        ContentUnavailableView {
            if let appFilter {
                Text("Nothing matches \u{201C}\(query)\u{201D} in \(activeFilterLabel(appFilter))")
            } else {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
            }
        } description: {
            Text("Search runs over transcript text, timestamps and day names.")
        } actions: {
            Button("Clear Search") { searchText = "" }
            if appFilter != nil {
                Button("Show All Apps") { appFilter = nil }
            }
        }
    }

    // MARK: List

    /// One day, as one to three grouped plates: the rows above the open transcript,
    /// the open transcript itself, and the rows below it.
    ///
    /// The open record gets its own plate because a record's detail emitted inside
    /// the index's plate reads as more index — the rows under it looked like part of
    /// the transcript above them. A plate boundary is the form's own way of saying
    /// "this is one thing", and the day's heading stays on whichever plate comes
    /// first so the day is still named exactly once.
    @ViewBuilder
    private func daySections(
        _ group: RecentSessionDayGroup,
        selectedID: RecentSession.ID?,
        recedes: Bool
    ) -> some View {
        let header = SessionsFormatters.dayHeader.string(from: group.day)
        let sessions = group.sessions

        if let open = sessions.firstIndex(where: { $0.id == selectedID }) {
            let before = sessions[..<open]
            let after = sessions[(open + 1)...]

            if before.isEmpty {
                Section(header) { openRecord(sessions[open]) }
            } else {
                Section(header) { rows(before, recedes: recedes) }
                Section { openRecord(sessions[open]) }
            }

            if !after.isEmpty {
                Section { rows(after, recedes: recedes) }
            }
        } else {
            Section(header) { rows(sessions[...], recedes: recedes) }
        }
    }

    private func rows(_ sessions: ArraySlice<RecentSession>, recedes: Bool) -> some View {
        // A Section otherwise treats every session as an eager Form row. At the
        // retained limit that builds 500 complete Button/accessibility/context-menu
        // responder trees, then revisits all of them when one transcript opens.
        // One lazy child keeps the native day plate while materializing only rows
        // near the scroll viewport.
        LazyVStack(spacing: VoiceourMetrics.Space.lg + VoiceourMetrics.Space.xs) {
            ForEach(sessions) { session in
                row(for: session, isSelected: false, recedes: recedes)
            }
        }
    }

    @ViewBuilder
    private func openRecord(_ session: RecentSession) -> some View {
        row(for: session, isSelected: true, recedes: false)
        detail(for: session)
    }

    /// How far a closed row recedes while another transcript is open.
    private var closedRowOpacity: Double {
        a11y.contrast == .increased ? 0.8 : 0.45
    }

    private func row(for session: RecentSession, isSelected: Bool, recedes: Bool) -> some View {
        Button {
            select(session)
        } label: {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                    Text(SessionsFormatters.timestamp.string(from: session.createdAt))
                        .font(.body.monospaced())
                        .fixedSize(horizontal: true, vertical: false)

                    if session.mutedDuringCapture {
                        Image(systemName: "mic.slash.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .help("System audio muted for this recording.")
                            .accessibilityLabel("Recorded with system audio muted")
                    }

                    if let outcome = session.outcome {
                        ConsoleStateMark(outcome.chip.label, outcome.severity)
                    }

                    // A measurement, not a state: the marks beside it grade the
                    // capture, and a word count has nothing to grade.
                    Text(SessionsFormatters.wordCountLabel(session.wordCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Where it went. The outcome mark beside it says how the
                    // text was delivered; this says what received it — with the
                    // app's own icon when this Mac still has the app, because a
                    // reader recognises a scanned list of destinations by icon
                    // faster than by reading five small words.
                    if let bundleId = session.outcome?.targetBundleId {
                        let identity = appIdentity(for: session, bundleId: bundleId)
                        // Centre-aligned inside the outer `.firstTextBaseline`
                        // row: the nested stack publishes its Text's baseline, so
                        // the label still sits on the row's baseline while the
                        // icon centres on that label rather than on the stamp.
                        HStack(alignment: .center, spacing: VoiceourMetrics.Space.xs) {
                            if let icon = identity.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(
                                        width: VoiceourMetrics.Control.inlineIcon,
                                        height: VoiceourMetrics.Control.inlineIcon
                                    )
                                    .accessibilityHidden(true)
                            }
                            Text(identity.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: VoiceourMetrics.Space.sm)
                }

                // Two lines on a closed row: one line of a dictated sentence is
                // rarely enough to recognise it by, and the full text in every row
                // would turn 500 retained transcripts into 500 paragraphs. The open
                // row carries none, because the well one row below holds the whole
                // text — the preview above it was the same sentence twice.
                if !isSelected {
                    Text(previewText(for: session))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, VoiceourMetrics.Space.xs)
            .padding(.horizontal, VoiceourMetrics.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectionFill(isSelected: isSelected),
                in: RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.row, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A closed row beside an open one is context, not content: with a transcript
        // open, every other row recedes so the page has one subject. The escalation
        // is inverted under Increase Contrast — a reader who asked for more contrast
        // must not be handed less.
        .opacity(recedes ? closedRowOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: session, includesPreview: !isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // The record-level commands, on the record. They used to sit on the
        // transcript, where they competed with the text view's own menu — the one
        // that can actually teach the word under the pointer. Each one opens the
        // row it acts on, so its result is visible where the click landed.
        .contextMenu {
            Button("Copy Transcript") {
                select(session)
                copy(session)
            }
            Button("Fix / Teach a Word\u{2026}") {
                select(session)
                beginTeaching(surface: nil)
            }
            if let bundleId = session.outcome?.targetBundleId {
                Button("Show Only \(appLabel(for: session, bundleId: bundleId))") {
                    appFilter = bundleId
                }
            }
            Button("Delete Transcript\u{2026}", role: .destructive) {
                select(session)
                deleteError = nil
                pendingDeleteSession = session
            }
        }
    }

    private func select(_ session: RecentSession) {
        selectedSessionID = session.id
    }

    /// Increase Contrast escalates the wash: at 0.18 the accent tint is a hint,
    /// which is the right weight for a selection that is also marked
    /// `.isSelected`, and the wrong weight for a reader who asked for more.
    private func selectionFill(isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        return Color.accentColor.opacity(a11y.contrast == .increased ? 0.34 : 0.18)
    }

    private func previewText(for session: RecentSession) -> String {
        previews[session.id] ?? Self.preview(of: session)
    }

    /// The row's destination, as its icon and the name a reader would use for
    /// it: the installed app's own name, else the name persisted with the row,
    /// else its bundle id humanized, so no row shows a reverse-DNS string and no
    /// row shows a name the app has since changed.
    @MainActor
    private func appIdentity(for session: RecentSession, bundleId: String) -> AppIdentity {
        .resolve(bundleId: bundleId, persistedName: session.outcome?.targetAppName)
    }

    /// The same destination where only the name is wanted: the filter command,
    /// the open transcript's Target row, and the row's spoken label.
    @MainActor
    private func appLabel(for session: RecentSession, bundleId: String) -> String {
        appIdentity(for: session, bundleId: bundleId).label
    }

    /// Collapses a transcript to the index's one preview string.
    private static func preview(of session: RecentSession) -> String {
        let collapsed = session.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty transcript" : collapsed
    }

    /// The whole row in one sentence, in the order a reader would say it. It
    /// carries the outcome word because the row is now the transcript's only
    /// heading: the detail below it no longer repeats the stamp, the outcome or the
    /// word count that are already here.
    ///
    /// The preview belongs to that sentence only while the row is closed. The open
    /// row's well publishes the entire transcript as its own value one element
    /// later, so appending the preview here would read the same words twice.
    private func accessibilityLabel(for session: RecentSession, includesPreview: Bool) -> String {
        var parts = [SessionsFormatters.timestamp.string(from: session.createdAt)]
        if let outcome = session.outcome {
            parts.append(outcome.chip.label)
            if let bundleId = outcome.targetBundleId {
                parts.append("to \(appLabel(for: session, bundleId: bundleId))")
            }
        }
        parts.append(SessionsFormatters.wordCountLabel(session.wordCount, pluralOnly: true))
        if session.mutedDuringCapture {
            parts.append("recorded with system audio muted")
        }
        if includesPreview {
            parts.append(previewText(for: session))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Detail

    /// The open transcript, emitted under its row inside the plate they share.
    ///
    /// It carries no action buttons. The transcript is the subject and the gestures
    /// are on it: a plain click copies the whole thing, a selection plus Command-T
    /// (or a right-click) teaches a correction, and the record-level commands live in
    /// the row's own context menu. What is left to draw is the text, one line that
    /// says what to do or what just happened, and the small measurements behind the
    /// dictation — of which only the raw text is a fold, because it alone is long
    /// enough to bury everything under it.
    @ViewBuilder
    private func detail(for session: RecentSession) -> some View {
        if let deleteError {
            ConsoleCaption(deleteError, color: .red)
        }

        // What received the text, and — only when it was not ordinary text — the
        // class of that target: the one chip the row does not carry, and the
        // reason a transcript that reads as pasted was in fact only copied.
        if let outcome = session.outcome,
            outcome.targetBundleId != nil || (outcome.targetSafety ?? .normalText) != .normalText
        {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if let bundleId = outcome.targetBundleId {
                        Text(appLabel(for: session, bundleId: bundleId))
                    }
                    if let targetSafety = outcome.targetSafety, targetSafety != .normalText {
                        ConsoleStateMark(targetSafety.displayLabel, .neutral)
                    }
                }
            } label: {
                Text("Target")
            }
        }

        transcript(for: session)

        footer(for: session)

        if let stages = session.stages {
            metadataRow("Timings", stages.detailLine)
        }

        if let raw = rawTranscript(for: session) {
            rawRow(raw)
        }

        if let leastSure = session.leastConfidentWord {
            leastSureRow(leastSure)
        }

        if isTeaching {
            ConsoleTeachHost(
                coordinator: coordinator,
                session: session,
                externalPrefill: $pendingFixTeachPrefill,
                isEditing: $isTeaching
            )
            .id(session.id)
        }
    }

    /// One line under the transcript: what just happened, what pressing Command-T
    /// will teach, or how to reach either. It replaces a bar of four buttons — the
    /// gestures it names are on the text itself, and a line of prose can say which
    /// words the next keystroke will teach, which a button title cannot without
    /// becoming a paragraph.
    @ViewBuilder
    private func footer(for session: RecentSession) -> some View {
        if copiedSessionID == session.id {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                ConsoleStateMark("COPIED TO CLIPBOARD", .ok)
                    .accessibilityIdentifier("sessions.detail.copied")
                Spacer(minLength: 0)
            }
        } else if let surface = selectedSurface, !surface.isEmpty {
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

    /// The transcript block. It gets its own surface because it is the one place
    /// in this window that holds arbitrary user text and supports selection —
    /// Reduce Transparency swaps the material for the opaque text ground rather
    /// than laying a translucent panel over the form's own.
    private func transcript(for session: RecentSession) -> some View {
        SelectableTranscriptText(
            identity: session.id,
            text: session.text.isEmpty ? "Empty transcript" : session.text,
            onFixTeach: { word in
                beginTeaching(surface: word)
            },
            onSelectionChange: { selectedSurface = $0 },
            onPlainClick: { copy(session) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiceourMetrics.Space.sm)
        .background(
            transcriptGround,
            in: RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.row, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
        .accessibilityValue(
            "\(SessionsFormatters.wordCountLabel(session.wordCount)), "
                + "recorded \(SessionsFormatters.detailStamp.string(from: session.createdAt))"
        )
        .accessibilityIdentifier("sessions.detail.transcript")
        // The gestures are on the text, so VoiceOver — which cannot click into a
        // text view to copy it or drag a selection to teach from it — gets both as
        // named actions on the same element instead.
        .accessibilityAction(named: "Copy transcript") { copy(session) }
        .accessibilityAction(named: "Teach a correction") { beginTeaching(surface: selectedSurface) }
    }

    /// The recessed ground under the transcript. Reduce Transparency deletes the
    /// material that was bounding it, so the well becomes the opaque ground macOS
    /// uses for text content rather than a translucent panel over the form's own.
    private var transcriptGround: AnyShapeStyle {
        a11y.reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .textBackgroundColor))
            : AnyShapeStyle(HierarchicalShapeStyle.quaternary)
    }

    /// Trims an arbitrary user selection for the footer line. A selection can be the
    /// whole transcript, and the line that names it is one sentence.
    private static func shortened(_ surface: String, budget: Int = 28) -> String {
        // `count` walks the whole string and a selection can be the whole
        // transcript; this stops one character past the budget.
        guard surface.index(surface.startIndex, offsetBy: budget + 1, limitedBy: surface.endIndex) != nil
        else { return surface }
        let head = (budget - 1) / 2
        return "\(surface.prefix(head))\u{2026}\(surface.suffix(budget - 1 - head))"
    }

    /// Opens the teach editor, prefilled with `surface` when one is known. Only an
    /// explicit gesture — Command-T, the transcript's own menu item, or the row's —
    /// reaches here; no automatic path teaches.
    private func beginTeaching(surface: String?) {
        if let surface, !surface.isEmpty {
            pendingFixTeachPrefill = ConsoleTeachPrefill(word: surface)
        }
        isTeaching = true
    }

    /// The decoder's least sure word for this dictation, with its per-token
    /// probability. Not calibrated, and not a control: a reader who wants to correct
    /// it selects it in the transcript above and presses Command-T, like any other
    /// word.
    private func leastSureRow(_ leastSure: LeastConfidentWord) -> some View {
        LabeledContent {
            Text("\(leastSure.text) · \(Int(leastSure.score * 100))%")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(leastSure.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Least sure")
        }
    }

    /// Only shown when cleanup actually changed the text: a raw line identical to
    /// the final one is not evidence of anything.
    private func rawTranscript(for session: RecentSession) -> String? {
        guard let raw = session.rawTranscript,
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                != session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return raw
    }

    /// The pre-cleanup text, folded shut. It answers one narrow question — what
    /// cleanup and the glossary changed — and at dictation length it is a wall of
    /// monospaced text several times the height of every other evidence row, which
    /// pushed the least sure word and the teach editor off the page for a reading
    /// almost nobody asks for. So the row states that raw text exists and differs,
    /// and unfolds it only when asked. Every newly opened transcript starts folded.
    private func rawRow(_ raw: String) -> some View {
        DisclosureGroup(isExpanded: $showsRawTranscript) {
            metadataText(raw, mono: true)
        } label: {
            Text("Raw")
                .accessibilityIdentifier("sessions.detail.raw")
                // Measured: the triangle SwiftUI publishes answers an accessibility
                // press with success and does not change its own state, so a VoiceOver
                // reader could see the fold and never open it. The default action is
                // the one an accessibility press performs.
                .accessibilityAction {
                    showsRawTranscript.toggle()
                }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            metadataText(value, mono: false)
        } label: {
            Text(label)
        }
    }

    /// One styling site for every measured value under the transcript.
    private func metadataText(_ value: String, mono: Bool) -> some View {
        Text(value)
            .font(mono ? .callout.monospaced() : .callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func copy(_ session: RecentSession) {
        GeneralPasteboard.copy(session.text)
        announceCopy()
        resetCopyFeedbackTask?.cancel()
        // Both directions of the confirmation run through one curve and one
        // Reduce Motion branch; the arrival used to snap and only the exit faded.
        withAnimation(feedbackAnimation) {
            copiedSessionID = session.id
        }

        let copiedID = session.id
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, copiedSessionID == copiedID else { return }
            withAnimation(feedbackAnimation) {
                copiedSessionID = nil
            }
        }
    }

    /// The mark is the confirmation a reader sees; VoiceOver hears the same
    /// sentence, because a mark that appears beside a button the cursor has already
    /// left confirms nothing. A no-op when VoiceOver is not running.
    private func announceCopy() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Transcript copied to clipboard",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private var feedbackAnimation: Animation? {
        a11y.reduceMotion ? nil : .easeInOut(duration: VoiceourMotion.quickDuration)
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
        isDeletePersistencePending = true
        Task {
            let isDurable = await coordinator.deleteRecentSession(id: session.id)
            isDeletePersistencePending = false
            pendingDeleteSession = nil
            // A destructive action that half-succeeds must say so: the row that
            // asked for it reports that the transcript survived on disk instead
            // of reporting nothing.
            guard isDurable else {
                deleteError = "Could not delete this session — it is still on disk. Try again."
                return
            }
        }
    }
}

// MARK: - Outcome severity

extension RecentSessionOutcomeMetadata {
    /// The severity the outcome's word carries, on the window's one ladder.
    var severity: ConsoleStateMark.Severity {
        switch disposition {
        case .pasteAttempted: .ok
        case .copiedOnly: .warn
        case .failed: .crit
        }
    }
}

// MARK: - Fix / Teach

/// One-shot command to open the Fix/Teach editor prefilled from a transcript
/// right-click. Equatable so `.onChange` fires; consumed (set to nil) once
/// applied.
struct ConsoleTeachPrefill: Equatable {
    let word: String
}

/// Teaches a correction for a word the last dictation heard wrong.
///
/// The fields are `ConsoleTermEditor`, the one term editor, so a term taught
/// from a transcript names the same two things the Glossary row names. What is
/// session-shaped stays here: the scopes this transcript can offer, the
/// surfaces its raw text held and its final text did not, the one-shot prefill
/// from a right-click, and the write itself.
///
/// Teaching writes the user's glossary and nothing else: it never edits text
/// that was already inserted, which is why the caption says so and why the
/// editor sits below the transcript rather than over it.
struct ConsoleTeachHost: View {
    var coordinator: DictationCoordinator
    var session: RecentSession
    @Binding var externalPrefill: ConsoleTeachPrefill?
    @Binding var isEditing: Bool

    @State private var canonical = ""
    @State private var spokenForms: [String] = []
    @State private var scope: VocabularyScope = .global
    /// The reason the last teach was refused, kept so the editor can stay open
    /// on the text the user typed. A refusal used to close the editor silently
    /// and throw the term away.
    @State private var refusal: String?

    var body: some View {
        ConsoleTermEditor(
            term: $canonical,
            spokenForms: $spokenForms,
            scope: $scope,
            scopeOptions: scopeOptions,
            derivedForms: [],
            candidateForms: mishearingCandidates,
            failure: refusal,
            caption: "Teaches future dictation only — this never edits text already pasted.",
            submit: ConsoleTermEditor.Command(
                title: "Teach",
                identifier: "sessions.teach.submit",
                isEnabled: canSubmit,
                perform: submit
            ),
            cancel: cancel,
            destructive: nil,
            identifierPrefix: "sessions.teach"
        )
        .onAppear(perform: applyExternalPrefill)
        .onChange(of: externalPrefill) {
            applyExternalPrefill()
        }
    }

    /// Global always; the delivery target and the active project only when this
    /// transcript has one. A scope the session cannot name is not offered.
    private var scopeOptions: [(scope: VocabularyScope, title: String)] {
        var options: [(scope: VocabularyScope, title: String)] = [(.global, "Global")]
        if let appBundleId {
            options.append((.bundleID(appBundleId), "This App"))
        }
        if let projectId {
            options.append(
                (.projectID(projectId), "Project · \(coordinator.activeProjectName ?? "This Project")")
            )
        }
        return options
    }

    private var appBundleId: String? {
        let id = session.outcome?.targetBundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private var projectId: String? {
        let id = coordinator.activeProjectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    /// Words present in the raw pre-cleanup transcript but not in the final text
    /// — the likely mishearing surfaces the user may want to map to a term.
    private var mishearingCandidates: [String] {
        guard let raw = session.rawTranscript else { return [] }
        let finalWords = Set(
            session.text
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
        )
        var seen: Set<String> = []
        var candidates: [String] = []
        for token in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(token)
            let key = word.lowercased()
            guard !finalWords.contains(key), seen.insert(key).inserted else { continue }
            candidates.append(word)
            if candidates.count >= 12 { break }
        }
        return candidates
    }

    private var canSubmit: Bool {
        !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seeds the editor from a transcript right-click: the highlighted surface
    /// becomes the spoken form the user is teaching. An already-open draft keeps
    /// its typed term and chosen scope — only the form is replaced. Consumes the
    /// one-shot binding so a repeat right-click of the same word re-triggers.
    private func applyExternalPrefill() {
        guard let prefill = externalPrefill else { return }
        spokenForms = [prefill.word]
        externalPrefill = nil
    }

    /// History lists no form set — it names a term the glossary may already hold
    /// — so it commits with a nil `termId`, and its form is added to that term
    /// rather than substituted for the forms the term already carries.
    private func submit() {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard
            coordinator.commitTerm(
                termId: nil,
                canonical: trimmed,
                spokenForms: spokenForms,
                scope: scope
            )
        else {
            refusal = coordinator.glossaryNotice
            return
        }
        reset()
    }

    private func cancel() {
        reset()
    }

    private func reset() {
        canonical = ""
        spokenForms = []
        scope = .global
        refusal = nil
        isEditing = false
        externalPrefill = nil
    }
}
