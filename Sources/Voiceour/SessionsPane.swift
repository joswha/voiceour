import SwiftUI
import VoiceCore
import VoiceMac

struct SessionsPane: View {
    var coordinator: DictationCoordinator
    @State private var selectedSessionID: RecentSession.ID?
    @State private var searchText = ""
    @State private var pendingDeleteSession: RecentSession?
    @State private var isDeletePersistencePending = false
    @FocusState private var searchFocused: Bool

    // Derived data cached as @State snapshots, recomputed on appear and when
    // the session list or search text changes (reloadDerivedData). Prevents
    // re-sorting/re-filtering the full list on every body pass and every
    // per-row selection read.
    @State private var filteredSessions: [RecentSession] = []
    @State private var dayGroups: [RecentSessionDayGroup] = []

    private func makeFilteredSessions() -> [RecentSession] {
        RecentSessionQuery.matches(
            in: coordinator.recentSessions,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: { SessionsFormatters.timestamp.string(from: $0) },
            dayHeader: { SessionsFormatters.dayHeader.string(from: $0) }
        )
    }

    private func makeDayGroups(from sessions: [RecentSession]) -> [RecentSessionDayGroup] {
        RecentSessionQuery.dayGroups(
            of: sessions,
            calendar: RenderOverrides.calendar ?? Calendar.current
        )
    }

    private var selectedSession: RecentSession? {
        if let selectedSessionID,
            let session = filteredSessions.first(where: { $0.id == selectedSessionID })
        {
            return session
        }
        return filteredSessions.first
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSessions: Bool {
        !coordinator.recentSessions.isEmpty || pendingDeleteSession != nil
    }

    var body: some View {
        let selected = selectedSession
        let selectedID = selected?.id

        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
            HStack(alignment: .top, spacing: VoiceourMetrics.Space.xl) {
                listCard(selectedID: selectedID)
                    .frame(
                        minWidth: VoiceourMetrics.Space.section * 8,
                        maxWidth: VoiceourMetrics.Space.section * 11
                    )

                RecentSessionDetailPane(
                    coordinator: coordinator,
                    session: selected,
                    isFiltering: !query.isEmpty,
                    hasSessions: hasSessions,
                    pendingDeleteSession: $pendingDeleteSession,
                    isDeletePersistencePending: $isDeletePersistencePending,
                    delete: { await coordinator.deleteRecentSession(id: $0) },
                    copy: copyToPasteboard
                )
                .frame(minWidth: VoiceourMetrics.Space.section * 9, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: reloadDerivedData)
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            reloadDerivedData()
        }
        .onChange(of: searchText) {
            reloadDerivedData()
        }
    }

    /// The master column. Its shell survives every state: an empty history and a
    /// query that matches nothing both render inside the card rather than
    /// replacing the pane's structure with bare ground.
    private func listCard(selectedID: RecentSession.ID?) -> some View {
        ContentCard(eyebrow: "SESSIONS") {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                if hasSessions {
                    SessionSearchField(text: $searchText, focus: $searchFocused, submit: selectFirstMatch)

                    if !query.isEmpty {
                        Text("\(filteredSessions.count) OF \(coordinator.recentSessions.count) SESSIONS")
                            .roleStyle(.micro)
                            .accessibilityLabel(
                                "\(filteredSessions.count) of \(coordinator.recentSessions.count) sessions match"
                            )
                    }

                    if dayGroups.isEmpty {
                        noMatchesView
                    } else {
                        sessionList(selectedID: selectedID)
                    }
                } else {
                    // Keep an empty history inside the SESSIONS card instead of
                    // replacing the pane's structure with bare ground.
                    EmptyState(
                        glyph: "tray",
                        title: "No sessions yet",
                        body: "Completed dictations are kept here with their transcripts, timestamps and word counts."
                    ) {
                        DictationHotkeyHint()
                    }
                    .padding(.vertical, VoiceourMetrics.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func sessionList(selectedID: RecentSession.ID?) -> some View {
        // A day header can only know whether its rows survived the clip if it
        // knows where the clip is, and the scroll view is the only thing here
        // that does.
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                    ForEach(dayGroups) { group in
                        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                            SessionDayHeader(
                                title: SessionsFormatters.dayHeader.string(from: group.day).uppercased(),
                                viewportHeight: viewport.size.height
                            )

                            ForEach(group.sessions) { session in
                                Button {
                                    selectedSessionID = session.id
                                } label: {
                                    RecentSessionRow(session: session)
                                }
                                .buttonStyle(PlateButtonStyle(isSelected: selectedID == session.id))
                                .accessibilityAddTraits(selectedID == session.id ? .isSelected : [])
                            }
                        }
                    }
                }
                // The list is the one scroll view in this pane that runs past its
                // viewport, so the last row stops short of the clip line instead of
                // being sliced against it.
                .padding(.bottom, VoiceourMetrics.Space.md)
            }
            .coordinateSpace(name: sessionListSpace)
            .modifier(ListScrollEdge())
        }
    }

    private var noMatchesView: some View {
        EmptyState(
            glyph: "text.magnifyingglass",
            title: "Nothing matches \u{201C}\(query)\u{201D}",
            body: "Search runs over transcript text, timestamps and day names."
        ) {
            Button("CLEAR SEARCH") { searchText = "" }
                .buttonStyle(GlassButtonStyle(kind: .ghost))
        }
        .padding(.vertical, VoiceourMetrics.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reloadDerivedData() {
        let filtered = makeFilteredSessions()
        filteredSessions = filtered
        dayGroups = makeDayGroups(from: filtered)
        validateSelection()
    }

    private func validateSelection() {
        let sessionIDs = filteredSessions.map(\.id)
        if let selectedSessionID, sessionIDs.contains(selectedSessionID) {
            return
        }
        selectedSessionID = sessionIDs.first
    }

    /// Return in the search field moves the selection to the first match and
    /// hands focus back to the results, instead of re-running the filter that
    /// every keystroke has already run.
    private func selectFirstMatch() {
        guard let first = filteredSessions.first else { return }
        selectedSessionID = first.id
        searchFocused = false
    }

    private func copyToPasteboard(_ text: String) {
        GeneralPasteboard.copy(text)
    }
}
