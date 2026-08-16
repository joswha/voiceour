import SwiftUI
import VoiceCore
import VoiceMac

/// History: the transcripts this Mac kept, and what can be done with one.
///
/// Search, day groups and the transcript detail all live on one scrolling form.
/// The two-column master/detail card layout this replaces existed to give the
/// detail a fixed reading window beside a fixed-height list; a form scrolls as
/// one document, so the transcript sizes to its own text instead of scrolling
/// inside a nested viewport.
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

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Form {
            if hasSessions {
                Section {
                    searchRow
                }

                ForEach(dayGroups) { group in
                    Section(SessionsFormatters.dayHeader.string(from: group.day)) {
                        ForEach(group.sessions) { session in
                            row(for: session)
                        }
                    }
                }

                if dayGroups.isEmpty {
                    Section {
                        noMatches
                    }
                }

                if let session = selectedSession {
                    Section("Transcript") {
                        detail(for: session)
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
        .onChange(of: selectedSession?.id) {
            pendingFixTeachPrefill = nil
            isTeaching = false
            deleteError = nil
            selectedSurface = nil
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

    private var selectedSession: RecentSession? {
        if let selectedSessionID,
            let session = filteredSessions.first(where: { $0.id == selectedSessionID })
        {
            return session
        }
        return filteredSessions.first
    }

    private func reloadDerivedData() {
        let filtered = RecentSessionQuery.matches(
            in: coordinator.recentSessions,
            query: query,
            timestamp: { SessionsFormatters.timestamp.string(from: $0) },
            dayHeader: { SessionsFormatters.dayHeader.string(from: $0) }
        )
        filteredSessions = filtered
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

    private func row(for session: RecentSession) -> some View {
        let isSelected = selectedSession?.id == session.id

        return Button {
            selectedSessionID = session.id
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

                Text(previewText(for: session))
                    .lineLimit(1)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: session))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Increase Contrast escalates the wash: at 0.18 the accent tint is a hint,
    /// which is the right weight for a selection that is also marked
    /// `.isSelected`, and the wrong weight for a reader who asked for more.
    private func selectionFill(isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        return Color.accentColor.opacity(a11y.contrast == .increased ? 0.34 : 0.18)
    }

    private func previewText(for session: RecentSession) -> String {
        let collapsed = session.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty transcript" : collapsed
    }

    private func accessibilityLabel(for session: RecentSession) -> String {
        let prefix =
            "\(SessionsFormatters.timestamp.string(from: session.createdAt)), "
            + SessionsFormatters.wordCountLabel(session.wordCount, pluralOnly: true)
        if session.mutedDuringCapture {
            return "\(prefix), recorded with system audio muted, \(previewText(for: session))"
        }
        return "\(prefix), \(previewText(for: session))"
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(for session: RecentSession) -> some View {
        LabeledContent {
            Button("Delete") {
                deleteError = nil
                pendingDeleteSession = session
            }
            .disabled(isDeletePersistencePending)
        } label: {
            Text(SessionsFormatters.detailStamp.string(from: session.createdAt))
                .font(.headline)
        }

        if let deleteError {
            ConsoleCaption(deleteError, color: .red)
        }

        chips(for: session)

        transcript(for: session)

        if let surface = visibleSelectedSurface {
            teachSelectionBar(surface)
        }

        if let stages = session.stages {
            metadataRow("Timings", stages.detailLine)
        }

        if let raw = rawTranscript(for: session) {
            metadataRow("Raw", raw, mono: true)
        }

        if let leastSure = session.leastConfidentWord {
            leastSureRow(leastSure)
        }

        actions(for: session)

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

    private func chips(for session: RecentSession) -> some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
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
            if let targetSafety = session.outcome?.targetSafety, targetSafety != .normalText {
                ConsoleStateMark("TARGET \(targetSafety.displayLabel)", .neutral)
            }
            Text(SessionsFormatters.wordCountLabel(session.wordCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
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
                pendingFixTeachPrefill = ConsoleTeachPrefill(word: word)
                isTeaching = true
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
        .contextMenu {
            Button("Copy Transcript") { copy(session) }
            Button("Fix / Teach a Word") { isTeaching = true }
            Button("Delete Session", role: .destructive) {
                deleteError = nil
                pendingDeleteSession = session
            }
        }
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

    private var visibleSelectedSurface: String? {
        isTeaching ? nil : selectedSurface
    }

    private func teachSelectionBar(_ surface: String) -> some View {
        LabeledContent {
            Button("Teach") {
                pendingFixTeachPrefill = ConsoleTeachPrefill(word: surface)
                isTeaching = true
            }
            .accessibilityIdentifier("sessions.transcript.teachSelection")
            .accessibilityLabel("Teach correction for detected surface \(surface)")
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text("Detected as")
                    .foregroundStyle(.secondary)
                Text(surface)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(surface)
            }
        }
    }

    /// The decoder's least sure word for this dictation, with its per-token
    /// probability. Not calibrated — the row exists so a reader who spots a
    /// wrong word can teach it with the evidence attached, not as a quality
    /// score.
    private func leastSureRow(_ leastSure: LeastConfidentWord) -> some View {
        LabeledContent {
            Button("Teach…") {
                pendingFixTeachPrefill = ConsoleTeachPrefill(word: leastSure.text)
                isTeaching = true
            }
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

    private func actions(for session: RecentSession) -> some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Button(copiedSessionID == session.id ? "Copied" : "Copy") { copy(session) }
                .help("Copy the full transcript to the clipboard.")
                .accessibilityLabel(copiedSessionID == session.id ? "Copied to clipboard" : "Copy transcript")

            if visibleSelectedSurface == nil {
                Button("Fix / Teach") { isTeaching = true }
                    .help("Teach a correction for a word in this transcript. Right-click a word to prefill it.")
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private func copy(_ session: RecentSession) {
        GeneralPasteboard.copy(session.text)
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
    @FocusState private var canonicalFocused: Bool

    private enum Scope: Hashable {
        case global
        case app
        case project
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            LabeledContent {
                TextField("e.g. kubectl", text: $canonical)
                    .font(.body.monospaced())
                    .frame(width: VoiceourMetrics.Column.glossaryCanonical)
                    .focused($canonicalFocused)
                    .onSubmit(submit)
            } label: {
                Text("Canonical term")
            }

            LabeledContent {
                TextField("e.g. cube control", text: $misheard)
                    .font(.body.monospaced())
                    .frame(width: VoiceourMetrics.Column.glossaryAliases)
                    .onSubmit(submit)
            } label: {
                Text("Detected as (optional)")
            }

            if !mishearingCandidates.isEmpty {
                LabeledContent {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            ForEach(mishearingCandidates, id: \.self) { candidate in
                                Button(candidate) { misheard = candidate }
                            }
                        }
                    }
                } label: {
                    Text("Detected as in raw")
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
                Button("Cancel") { cancel() }
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
            canonicalFocused = true
        }
        .onExitCommand(perform: cancel)
        .onChange(of: externalPrefill) {
            applyExternalPrefill()
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
        canonicalFocused = true
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
        canonicalFocused = false
        isEditing = false
        externalPrefill = nil
    }
}
