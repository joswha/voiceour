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
    @State private var searchText = ""
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
    /// One collapsed preview line per session, built with the day groups.
    /// Collapsing newlines and trimming is two string copies, and recomputing it
    /// per row per body pass costs a full pass over the retained 500 on every
    /// keystroke and every selection change.
    @State private var previews: [RecentSession.ID: String] = [:]

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        // Resolved once per body pass rather than once per row: the row used to ask
        // `selectedSession`, which scans the filtered list, and history retains up
        // to 500 transcripts.
        let selectedID = selectedSessionID

        Form {
            if hasSessions {
                Section {
                    searchRow
                }

                ForEach(dayGroups) { group in
                    daySections(group, selectedID: selectedID)
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
        .onAppear(perform: reloadDerivedData)
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            reloadDerivedData()
        }
        .onChange(of: searchText) {
            reloadDerivedData()
        }
        .onChange(of: selectedSessionID) { _, newSelection in
            pendingFixTeachPrefill = nil
            isTeaching = false
            deleteError = nil
            selectedSurface = nil
            // A row's own Copy command selects the row it copied, so retiring the
            // confirmation unconditionally here would erase the mark that copy just
            // asked for. Only a move to a different transcript retires it.
            guard copiedSessionID != newSelection else { return }
            resetCopyFeedbackTask?.cancel()
            copiedSessionID = nil
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
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
        let filtered = RecentSessionQuery.matches(
            in: coordinator.recentSessions,
            query: query,
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

    private func validateSelection() {
        let sessionIDs = filteredSessions.map(\.id)
        if let selectedSessionID, sessionIDs.contains(selectedSessionID) {
            return
        }
        selectedSessionID = sessionIDs.first
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
            }

            if !query.isEmpty {
                ConsoleCaption("\(filteredSessions.count) of \(coordinator.recentSessions.count) sessions match")
            }
        }
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

    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over transcript text, timestamps and day names.")
        } actions: {
            Button("Clear Search") { searchText = "" }
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
    private func daySections(_ group: RecentSessionDayGroup, selectedID: RecentSession.ID?) -> some View {
        let header = SessionsFormatters.dayHeader.string(from: group.day)
        let sessions = group.sessions

        if let open = sessions.firstIndex(where: { $0.id == selectedID }) {
            let before = sessions[..<open]
            let after = sessions[(open + 1)...]

            if before.isEmpty {
                Section(header) { openRecord(sessions[open]) }
            } else {
                Section(header) { rows(before) }
                Section { openRecord(sessions[open]) }
            }

            if !after.isEmpty {
                Section { rows(after) }
            }
        } else {
            Section(header) { rows(sessions[...]) }
        }
    }

    private func rows(_ sessions: ArraySlice<RecentSession>) -> some View {
        ForEach(sessions) { session in
            row(for: session, isSelected: false)
        }
    }

    @ViewBuilder
    private func openRecord(_ session: RecentSession) -> some View {
        row(for: session, isSelected: true)
        detail(for: session)
    }

    /// How far a closed row recedes while another transcript is open.
    private var closedRowOpacity: Double {
        a11y.contrast == .increased ? 0.8 : 0.45
    }

    private func row(for session: RecentSession, isSelected: Bool) -> some View {
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

                    Spacer(minLength: VoiceourMetrics.Space.sm)
                }

                // Two lines, not one: one line of a dictated sentence is rarely
                // enough to recognise it by, and the whole text is one row below
                // for the selected session anyway. Full text in every row would
                // turn 500 retained transcripts into 500 paragraphs.
                Text(previewText(for: session))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .opacity(isSelected || selectedSessionID == nil ? 1 : closedRowOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: session))
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
    private func accessibilityLabel(for session: RecentSession) -> String {
        var parts = [SessionsFormatters.timestamp.string(from: session.createdAt)]
        if let outcome = session.outcome {
            parts.append(outcome.chip.label)
        }
        parts.append(SessionsFormatters.wordCountLabel(session.wordCount, pluralOnly: true))
        if session.mutedDuringCapture {
            parts.append("recorded with system audio muted")
        }
        parts.append(previewText(for: session))
        return parts.joined(separator: ", ")
    }

    // MARK: Detail

    /// The open transcript, emitted under its row inside the plate they share.
    ///
    /// It states nothing the row above it already states. A stamp, an outcome mark
    /// and a word count were repeated one line under the row that had just shown
    /// all three; what is left is what the row cannot hold — the actions, the whole
    /// text, and the evidence behind it. The action bar sits *above* the transcript
    /// deliberately: as the detail's last row, a long dictation pushed Copy and
    /// Teach off the bottom of the window, which is exactly where a reader who has
    /// just finished reading needs them.
    @ViewBuilder
    private func detail(for session: RecentSession) -> some View {
        if let deleteError {
            ConsoleCaption(deleteError, color: .red)
        }

        // Only the class of the delivery target, and only when it was not ordinary
        // text: that is the one chip the row does not carry, and it is the reason a
        // transcript that reads as pasted was in fact only copied.
        if let targetSafety = session.outcome?.targetSafety, targetSafety != .normalText {
            LabeledContent {
                ConsoleStateMark(targetSafety.displayLabel, .neutral)
            } label: {
                Text("Target")
            }
        }

        actions(for: session)

        transcript(for: session)

        // The one gesture in this window that is not a control. It was documented
        // only in a hover tooltip on a button that hid itself as soon as the reader
        // selected anything, which is how a shipped feature became invisible.
        ConsoleCaption(
            "Select any part of the transcript, or just right-click a word, to teach a correction "
                + "(\u{2318}T). Teaching changes future dictation only."
        )

        if let stages = session.stages {
            metadataRow("Timings", stages.detailLine)
        }

        if let raw = rawTranscript(for: session) {
            metadataRow("Raw", raw, mono: true)
        }

        if let leastSure = session.leastConfidentWord {
            leastSureRow(leastSure)
        }

        if isTeaching {
            ConsoleTeachEditor(
                coordinator: coordinator,
                session: session,
                externalPrefill: $pendingFixTeachPrefill,
                isEditing: $isTeaching
            )
            .id(session.id)
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
            onSelectionChange: { selectedSurface = $0 }
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
    }

    /// The recessed ground under the transcript. Reduce Transparency deletes the
    /// material that was bounding it, so the well becomes the opaque ground macOS
    /// uses for text content rather than a translucent panel over the form's own.
    private var transcriptGround: AnyShapeStyle {
        a11y.reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .textBackgroundColor))
            : AnyShapeStyle(HierarchicalShapeStyle.quaternary)
    }

    /// The title of the one teach control. With a selection it names exactly what
    /// pressing it teaches; with none it is the plain invitation. This used to be
    /// two controls: a button that hid itself the moment text was selected, and a
    /// separate "Detected as" bar that appeared elsewhere in its place.
    private var teachTitle: String {
        guard let surface = selectedSurface, !surface.isEmpty else { return "Fix / Teach\u{2026}" }
        return "Teach \u{201C}\(Self.shortened(surface))\u{201D}"
    }

    private var teachHelp: String {
        guard let surface = selectedSurface, !surface.isEmpty else {
            return "Teach a correction for a word in this transcript."
        }
        return "Teach a correction for \u{201C}\(surface)\u{201D}."
    }

    private var teachAccessibilityLabel: String {
        guard let surface = selectedSurface, !surface.isEmpty else {
            return "Fix or teach a word in this transcript"
        }
        return "Teach correction for selected text \(surface)"
    }

    /// A selection is arbitrary user text and the title belongs to a control in a
    /// row, so it is trimmed in the middle at a fixed budget instead of stretching
    /// the action bar to the width of a paragraph.
    private static func shortened(_ surface: String, budget: Int = 28) -> String {
        // `count` walks the whole string and a selection can be the whole
        // transcript; this stops one character past the budget.
        guard surface.index(surface.startIndex, offsetBy: budget + 1, limitedBy: surface.endIndex) != nil
        else { return surface }
        let head = (budget - 1) / 2
        return "\(surface.prefix(head))\u{2026}\(surface.suffix(budget - 1 - head))"
    }

    /// Opens the teach editor, prefilled with `surface` when one is known. Only an
    /// explicit press or menu choice reaches here; no automatic path teaches.
    private func beginTeaching(surface: String?) {
        if let surface, !surface.isEmpty {
            pendingFixTeachPrefill = ConsoleTeachPrefill(word: surface)
        }
        isTeaching = true
    }

    /// The decoder's least sure word for this dictation, with its per-token
    /// probability. Not calibrated — the row exists so a reader who spots a
    /// wrong word can teach it with the evidence attached, not as a quality
    /// score.
    private func leastSureRow(_ leastSure: LeastConfidentWord) -> some View {
        LabeledContent {
            Button("Teach…") { beginTeaching(surface: leastSure.text) }
                .accessibilityIdentifier("sessions.leastSure.teach")
                .accessibilityLabel("Teach correction for least sure word \(leastSure.text)")
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text("Least sure")
                    .foregroundStyle(.secondary)
                Text("\(leastSure.text) · \(Int(leastSure.score * 100))%")
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(leastSure.text)
            }
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

    private func metadataRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
        }
    }

    /// Everything that can be done to this transcript, on one row above the text.
    ///
    /// The confirmation mark is inserted *after* the button that produces it: this
    /// bar is leading-aligned, so a mark inserted before Copy would slide Copy out
    /// from under the pointer that just pressed it. (The System tab's diagnostics
    /// row is the mirror image — trailing-aligned, so its mark goes before its
    /// button.) The word is spelled out rather than reusing that tab's bare COPIED
    /// because `.copiedOnly` delivery already paints an amber COPIED outcome mark on
    /// the row above, and the same word in two colours is not a state.
    ///
    /// Delete sits across the spacer: it is the one action here that cannot be
    /// undone, and it must not be adjacent to the one that is pressed most.
    private func actions(for session: RecentSession) -> some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Button("Copy") { copy(session) }
                .help("Copy the full transcript to the clipboard.")
                .accessibilityLabel("Copy transcript")
                .accessibilityIdentifier("sessions.detail.copy")

            if copiedSessionID == session.id {
                ConsoleStateMark("COPIED TO CLIPBOARD", .ok)
                    .accessibilityIdentifier("sessions.detail.copied")
            }

            Button(teachTitle) { beginTeaching(surface: selectedSurface) }
                .keyboardShortcut("t", modifiers: .command)
                .help(teachHelp)
                .accessibilityLabel(teachAccessibilityLabel)
                .accessibilityIdentifier("sessions.detail.teach")

            Spacer(minLength: VoiceourMetrics.Space.sm)

            Button("Delete") {
                deleteError = nil
                pendingDeleteSession = session
            }
            .disabled(isDeletePersistencePending)
            .help("Remove this transcript from this Mac.")
            .accessibilityLabel("Delete transcript")
            .accessibilityIdentifier("sessions.detail.delete")
        }
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
/// Teaching writes the user's glossary and nothing else: it never edits text
/// that was already inserted, which is why the caption says so and why the
/// editor sits below the transcript rather than over it.
struct ConsoleTeachEditor: View {
    var coordinator: DictationCoordinator
    var session: RecentSession
    @Binding var externalPrefill: ConsoleTeachPrefill?
    @Binding var isEditing: Bool

    @State private var canonical = ""
    @State private var misheard = ""
    @State private var scope: Scope = .global
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case canonical
        case misheard
    }

    private enum Scope: Hashable {
        case global
        case app
        case project
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            // Stacked, bordered, full-measure wells, exactly like the glossary's
            // add-term composer. A `LabeledContent` here put a fixed-width unbordered
            // field in the trailing column of a 684 pt row, so the term the user was
            // typing sat unframed against the right edge of the window.
            teachField(
                title: "Canonical term",
                prompt: "kubectl",
                text: $canonical,
                field: .canonical,
                identifier: "sessions.teach.canonical"
            )
            teachField(
                title: "Detected as (optional)",
                prompt: "cube control",
                text: $misheard,
                field: .misheard,
                identifier: "sessions.teach.misheard"
            )

            if !mishearingCandidates.isEmpty {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    Text("Heard in the raw transcript")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            ForEach(mishearingCandidates, id: \.self) { candidate in
                                Button(candidate) { misheard = candidate }
                                    .accessibilityLabel("Use detected surface \(candidate)")
                            }
                        }
                    }
                }
            }

            Picker("Scope", selection: $scope) {
                Text("Global").tag(Scope.global)
                if appBundleId != nil {
                    Text("This App").tag(Scope.app)
                }
                if projectId != nil {
                    Text(coordinator.activeProjectName.map { "Project · \($0)" } ?? "This Project")
                        .tag(Scope.project)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: VoiceourMetrics.Space.sm) {
                Button("Teach") { submit() }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("sessions.teach.submit")
                Button("Cancel") { cancel() }
                    .accessibilityIdentifier("sessions.teach.cancel")
                Spacer(minLength: 0)
            }

            ConsoleCaption(
                "Teaches future dictation only — this never edits text already pasted. Case and spacing variants "
                    + "are matched automatically; add a detected surface only when dictation heard the term "
                    + "differently."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            applyExternalPrefill()
            focused = .canonical
        }
        .onExitCommand(perform: cancel)
        .onChange(of: externalPrefill) {
            applyExternalPrefill()
        }
    }

    /// One labelled, bordered well. The caption above the field is hidden from
    /// accessibility because the field itself already publishes the same title.
    private func teachField(
        title: String,
        prompt: String,
        text: Binding<String>,
        field: Field,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(prompt))
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .autocorrectionDisabled(true)
                .labelsHidden()
                .focused($focused, equals: field)
                .onSubmit(submit)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
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
    /// — the likely mishearing surfaces the user may want to map to a canonical
    /// term.
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

    private var resolvedScope: VocabularyScope {
        switch scope {
        case .global: .global
        case .app: appBundleId.map(VocabularyScope.bundleID) ?? .global
        case .project: projectId.map(VocabularyScope.projectID) ?? .global
        }
    }

    private var canSubmit: Bool {
        !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seeds the editor from a transcript right-click: the highlighted surface
    /// becomes the misheard alias and focus lands on the canonical field the user
    /// types. An already-open draft keeps its typed canonical and chosen scope —
    /// only the misheard surface is replaced. Consumes the one-shot binding so a
    /// repeat right-click of the same word re-triggers.
    private func applyExternalPrefill() {
        guard let prefill = externalPrefill else { return }
        misheard = prefill.word
        focused = .canonical
        externalPrefill = nil
    }

    private func submit() {
        let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCanonical.isEmpty else { return }
        let trimmedMisheard = misheard.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator.teachCorrection(
            canonical: trimmedCanonical,
            misheard: trimmedMisheard.isEmpty ? nil : trimmedMisheard,
            scope: resolvedScope
        )
        reset()
    }

    private func cancel() {
        reset()
    }

    private func reset() {
        canonical = ""
        misheard = ""
        scope = .global
        focused = nil
        isEditing = false
        externalPrefill = nil
    }
}
