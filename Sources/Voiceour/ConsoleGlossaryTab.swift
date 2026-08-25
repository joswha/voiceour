import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

/// Glossary: the spellings dictation is held to, the spoken forms that map onto
/// them, and the corrections the last dictation proposed.
///
/// A searchable list of records with exactly one open at a time — History's
/// shape, with one group where History has days. The open term keeps its row as
/// the heading and puts `ConsoleTermEditor` on a plate of its own directly
/// under it; every other row recedes, so the page has one subject.
///
/// The table this replaced put a permanent unbordered field in every row, under
/// a static title that read as a value and was false as well: a term with no
/// spoken forms is still matched by the case and spacing variants of its own
/// spelling. That sentence now has one place to live, the editor's
/// `Also matched` readout, and the row says what it holds instead.
struct ConsoleGlossaryTab: View {
    var coordinator: DictationCoordinator

    /// The open term, or nil for a closed list. A lexicon opens as a list: the
    /// reader came to find one spelling among many, not to edit the first.
    @State private var selectedTermId: String?
    /// Whether a new term is being composed, and the term it is so far. Three
    /// plain properties rather than one optional struct: a non-optional binding
    /// derived from optional state (`Binding($draft)`) is force-unwrapping, and
    /// SwiftUI reads it once more after Save clears it — measured as a trap in
    /// `BindingOperations.ForceUnwrapping.get`.
    @State private var isComposing = false
    @State private var draftTerm = ""
    @State private var draftForms: [String] = []
    @State private var searchText = ""
    @State private var originFilter: TermOrigin?
    /// The refusal the last commit published, held so the editor can stay open
    /// on the text the reader typed. Read from `glossaryNotice` only when a
    /// commit actually refused, so a stale notice is never reported as this
    /// edit's problem.
    @State private var refusal: String?
    @State private var pendingRemoval: ProtectedTerm?
    @State private var importOutcome: ImportOutcome?
    @FocusState private var searchFocused: Bool

    /// The open term's editable copy, seeded when a term opens and written back
    /// only by Save. Escape closes the editor, which discards it.
    @State private var editedTerm = ""
    @State private var editedForms: [String] = []

    /// Derived data cached as snapshots, recomputed when the ledger, the query
    /// or the filter changes. An imported lexicon is hundreds of rows, and
    /// filtering and sorting them inside `body` would redo that work on every
    /// keystroke and every selection read.
    @State private var matchingTerms: [ProtectedTerm] = []
    @State private var originFacets: [TermOriginFacet] = []
    @State private var liveTermCount = 0

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    private static let editorCaption =
        "Add a spoken form only when dictation heard something else. Case and spacing variants are "
        + "matched automatically."
    private static let termsFooter =
        "Click a term to edit it. Case and spacing variants of a term are matched automatically."

    var body: some View {
        // Resolved once per body pass rather than once per row: rows recede only
        // while the open term is actually on screen, so a query that hides it
        // must not dim every row it left visible with no subject to dim them for.
        let selectedID = selectedTermId
        let recedes = selectedID.map { id in matchingTerms.contains { $0.termId == id } } ?? false

        Form {
            // First, not last: a suggestion is about the dictation that just
            // happened, and under hundreds of imported terms it is invisible.
            if !coordinator.pendingSuggestions.isEmpty {
                Section {
                    ConsoleSuggestionsList(coordinator: coordinator)
                } header: {
                    Text("From your last dictation")
                } footer: {
                    ConsoleCaption(
                        "Accept teaches future dictation only — the text you already pasted is never changed."
                    )
                }
            }

            Section {
                controlsRow
            }

            // Pinned above the list: a draft is on screen regardless of where
            // its spelling will sort once it exists.
            if isComposing {
                Section {
                    draftEditor
                } header: {
                    Text("New term")
                }
            }

            if liveTermCount == 0 {
                Section {
                    emptyTerms
                }
            } else if matchingTerms.isEmpty {
                Section {
                    noMatches
                }
            } else {
                termSections(selectedID: selectedID, recedes: recedes)
            }

            Section("Word list") {
                wordListRow
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadDerivedData)
        .onChange(of: coordinator.settings.glossary) {
            reloadDerivedData()
        }
        .onChange(of: searchText) {
            reloadDerivedData()
        }
        .onChange(of: originFilter) {
            reloadDerivedData()
        }
        .onChange(of: selectedTermId) {
            seedEditor()
        }
        .confirmationDialog(
            "Remove this term?",
            isPresented: removalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Term", role: .destructive) {
                if let term = pendingRemoval { remove(term) }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(
                "Dictation stops holding \u{201C}\(pendingRemoval?.canonical ?? "")\u{201D} to this spelling. "
                    + "Text you already pasted is not affected."
            )
        }
    }

    // MARK: Derived data

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tombstoned terms are retired from cleanup, vocabulary compilation and
    /// candidate retrieval, so they are not live, editable rows here either.
    private var liveTerms: [ProtectedTerm] {
        coordinator.settings.glossary.filter { $0.tombstonedAt == nil }
    }

    private func reloadDerivedData() {
        let terms = coordinator.settings.glossary
        liveTermCount = terms.reduce(into: 0) { count, term in
            if term.tombstonedAt == nil { count += 1 }
        }
        originFacets = GlossaryQuery.originFacets(in: terms)
        // A filter whose last term was just removed or cleared would narrow the
        // list to nothing with no offered way back, so it falls away with it.
        if let engaged = originFilter, !originFacets.contains(where: { $0.origin == engaged }) {
            originFilter = nil
        }
        matchingTerms = GlossaryQuery.matches(in: terms, query: query, origin: originFilter)
        if let open = selectedTermId, !terms.contains(where: { $0.termId == open && $0.tombstonedAt == nil }) {
            selectedTermId = nil
        }
    }

    // MARK: Controls

    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search terms and spoken forms", text: $searchText)
                    .focused($searchFocused)
                    .onSubmit(selectFirstMatch)
                    .accessibilityIdentifier("glossary.search.field")

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
                    .accessibilityIdentifier("glossary.search.clear")
                }

                if originFacets.count > 1 {
                    originFilterMenu
                }

                Button("Add Term", action: beginDraft)
                    .accessibilityIdentifier("glossary.add-term")
            }

            controlsCaption
        }
    }

    /// One line under the controls, in precedence order: an import that failed,
    /// an import that landed, then how far the query and filter narrowed the
    /// list. They never compete — an import is the newer answer to the newer
    /// gesture, and the next search clears it.
    @ViewBuilder
    private var controlsCaption: some View {
        if let importFailure {
            ConsoleCaption(importFailure, color: .red)
        } else if let importedLabel {
            ConsoleStateMark(importedLabel, .ok)
        } else if !query.isEmpty || originFilter != nil {
            ConsoleCaption("\(matchingTerms.count) of \(liveTermCount) terms match")
        }
    }

    /// Narrows the list to terms the reader authored, or to the ones this build
    /// shipped. A menu rather than a row of chips, for the same reason History
    /// uses one: the control keeps its width whatever it offers.
    private var originFilterMenu: some View {
        Menu {
            Picker("Filter by origin", selection: $originFilter) {
                Text("All Terms").tag(TermOrigin?.none)
                ForEach(originFacets) { facet in
                    Text("\(Self.originTitle(facet.origin)) (\(facet.count))")
                        .tag(TermOrigin?.some(facet.origin))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                Image(
                    systemName: originFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
                if let originFilter {
                    Text(Self.originTitle(originFilter)).lineLimit(1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show terms of one origin")
        .accessibilityLabel(
            originFilter.map { "Filtering by \(Self.originTitle($0))" } ?? "Filter by origin"
        )
        .accessibilityIdentifier("glossary.filter")
    }

    private static func originTitle(_ origin: TermOrigin) -> String {
        switch origin {
        case .yours: "Yours"
        case .builtIn: "Built-in"
        }
    }

    /// Return in the search field opens the first match and hands focus back to
    /// the list, instead of re-running the filter every keystroke already ran.
    private func selectFirstMatch() {
        guard let first = matchingTerms.first else { return }
        endDraft()
        selectedTermId = first.termId
        searchFocused = false
    }

    // MARK: Empty states

    private var emptyTerms: some View {
        // Says what a term is rather than reporting that a list is empty.
        ContentUnavailableView {
            Text("No terms yet")
        } description: {
            Text(
                "A term is the spelling Voiceour holds a word to when dictation keeps hearing it wrong. "
                    + "Add one, or import a word list."
            )
        } actions: {
            Button("Add Term", action: beginDraft)
        }
    }

    /// Empty results imply a non-empty query: a filter validated against the
    /// facets can never rule out every term on its own. It can still be the
    /// reason a query found nothing, so it is offered back.
    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over terms and their spoken forms.")
        } actions: {
            Button("Clear Search") { searchText = "" }
            if originFilter != nil {
                Button("Show All Terms") { originFilter = nil }
            }
        }
    }

    // MARK: List

    /// The terms, as one to three grouped plates: the rows above the open term,
    /// the open term itself, and the rows below it. The open record gets its own
    /// plate because an editor emitted inside the index's plate reads as more
    /// index, and the heading stays on whichever plate comes first so the list
    /// is named exactly once.
    @ViewBuilder
    private func termSections(selectedID: String?, recedes: Bool) -> some View {
        let terms = matchingTerms

        if let open = terms.firstIndex(where: { $0.termId == selectedID }) {
            let before = terms[..<open]
            let after = terms[(open + 1)...]

            if before.isEmpty {
                Section {
                    openRecord(terms[open])
                } header: {
                    Text("Terms")
                } footer: {
                    if after.isEmpty { footerCaption }
                }
            } else {
                Section("Terms") { rows(before, recedes: recedes) }
                Section {
                    openRecord(terms[open])
                } footer: {
                    if after.isEmpty { footerCaption }
                }
            }

            if !after.isEmpty {
                Section {
                    rows(after, recedes: recedes)
                } footer: {
                    footerCaption
                }
            }
        } else {
            Section {
                rows(terms[...], recedes: recedes)
            } header: {
                Text("Terms")
            } footer: {
                footerCaption
            }
        }
    }

    private var footerCaption: some View {
        ConsoleCaption(Self.termsFooter)
    }

    private func rows(_ terms: ArraySlice<ProtectedTerm>, recedes: Bool) -> some View {
        // A Section otherwise treats every term as an eager Form row, and one
        // import can add hundreds of them, each with its own Button, label and
        // context menu. One lazy child keeps the native plate while
        // materializing only the rows near the viewport.
        LazyVStack(spacing: VoiceourMetrics.Space.lg + VoiceourMetrics.Space.xs) {
            ForEach(terms) { term in
                row(for: term, isSelected: false, recedes: recedes)
            }
        }
    }

    @ViewBuilder
    private func openRecord(_ term: ProtectedTerm) -> some View {
        row(for: term, isSelected: true, recedes: false)
        ConsoleTermEditor(
            term: $editedTerm,
            spokenForms: $editedForms,
            derivedForms: Glossary.derivedAliases(for: term.canonical),
            offersAdditionalForms: true,
            failure: refusal,
            caption: Self.editorCaption,
            submit: ConsoleTermEditor.Command(
                title: "Save",
                identifier: "glossary.term.save",
                isEnabled: canSave(term),
                perform: { save(term) }
            ),
            cancel: closeTerm,
            destructive: ConsoleTermEditor.Command(
                title: "Remove Term\u{2026}",
                identifier: "glossary.term.remove",
                isEnabled: true,
                perform: { pendingRemoval = term }
            ),
            identifierPrefix: "glossary.term"
        )
        .id(term.termId)
    }

    /// How far a closed row recedes while a term is open.
    private var closedRowOpacity: Double {
        a11y.contrast == .increased ? 0.8 : 0.45
    }

    private func row(for term: ProtectedTerm, isSelected: Bool, recedes: Bool) -> some View {
        let forms = Glossary.userAliases(for: term)

        return Button {
            select(term)
        } label: {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                    Text(term.canonical)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(term.canonical)

                    Spacer(minLength: VoiceourMetrics.Space.sm)
                }

                // The forms themselves, not a count of them: the whole question
                // a reader scans this list with is which spelling caught the
                // phrase they keep having to fix. The open row drops the line
                // because the editor one row below lists every form as its own
                // removable row.
                if !isSelected {
                    Text(Self.summary(of: forms))
                        .font(forms.isEmpty ? .body : .body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        // A closed row beside an open one is context, not content. The
        // escalation inverts under Increase Contrast: a reader who asked for
        // more contrast must not be handed less.
        .opacity(recedes ? closedRowOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: term, forms: forms))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("glossary.term.\(term.termId)")
        .contextMenu {
            Button("Remove Term\u{2026}", role: .destructive) {
                select(term)
                pendingRemoval = term
            }
        }
    }

    private static func summary(of forms: [String]) -> String {
        forms.isEmpty ? "Matched by its spelling only" : "Heard as " + forms.joined(separator: " · ")
    }

    private static func accessibilityLabel(for term: ProtectedTerm, forms: [String]) -> String {
        var parts = [term.canonical]
        parts.append(
            forms.isEmpty
                ? "matched by its spelling only"
                : "heard as \(forms.joined(separator: ", "))"
        )
        return parts.joined(separator: ", ")
    }

    /// Increase Contrast escalates the wash: at 0.18 the accent tint is a hint,
    /// which is the right weight for a selection that is also marked
    /// `.isSelected`, and the wrong weight for a reader who asked for more.
    private func selectionFill(isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        return Color.accentColor.opacity(a11y.contrast == .increased ? 0.34 : 0.18)
    }

    // MARK: Editing

    private func select(_ term: ProtectedTerm) {
        // Pressing a row is an answer to the draft as well: a two-field draft is
        // not worth a confirmation, and Save is the default action.
        endDraft()
        selectedTermId = term.termId
    }

    private func closeTerm() {
        selectedTermId = nil
    }

    private func seedEditor() {
        refusal = nil
        guard let open = selectedTermId,
            let term = coordinator.settings.glossary.first(where: { $0.termId == open })
        else {
            editedTerm = ""
            editedForms = []
            return
        }
        seedEditor(with: term)
    }

    private func seedEditor(with term: ProtectedTerm) {
        editedTerm = term.canonical
        editedForms = Glossary.userAliases(for: term)
    }

    /// Save answers a change. Offering it against an unchanged row would make a
    /// no-op look like a write, and an empty spelling is not a term.
    private func canSave(_ term: ProtectedTerm) -> Bool {
        guard !editedTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return editedTerm != term.canonical
            || editedForms != Glossary.userAliases(for: term)
    }

    /// The row's editor lists the whole form set, so it commits with the term's
    /// id: what it shows is what the record becomes, and a form deleted here is
    /// deleted. A refusal keeps the editor open on the text that caused it.
    private func save(_ term: ProtectedTerm) {
        var accepted = false
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.standard) {
            accepted = coordinator.commitTerm(
                termId: term.termId,
                canonical: editedTerm,
                spokenForms: editedForms
            )
        }
        guard accepted else {
            refusal = coordinator.glossaryNotice
            return
        }
        refusal = nil
        // Reseeded from what was stored: the sanitizer can drop characters the
        // editor still shows, and the row must not disagree with the record.
        if let stored = coordinator.settings.glossary.first(where: { $0.termId == term.termId }) {
            seedEditor(with: stored)
        }
    }

    private func beginDraft() {
        refusal = nil
        selectedTermId = nil
        draftTerm = ""
        draftForms = []
        isComposing = true
    }

    private func endDraft() {
        guard isComposing else { return }
        isComposing = false
        draftTerm = ""
        draftForms = []
    }

    private var draftEditor: some View {
        ConsoleTermEditor(
            term: $draftTerm,
            spokenForms: $draftForms,
            derivedForms: Glossary.derivedAliases(for: draftTerm),
            offersAdditionalForms: true,
            failure: refusal,
            caption: Self.editorCaption,
            submit: ConsoleTermEditor.Command(
                title: "Save",
                identifier: "glossary.draft.save",
                isEnabled: !draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                perform: saveDraft
            ),
            cancel: endDraft,
            destructive: nil,
            identifierPrefix: "glossary.draft"
        )
    }

    /// A new term is refused rather than merged when the spelling already
    /// exists: `commitTerm` would fold the forms into the term that holds it,
    /// which is a silent edit of a record the reader cannot see from here.
    private func saveDraft() {
        let trimmed = draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = liveTerms.first(where: {
            $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            refusal =
                "\u{201C}\(existing.canonical)\u{201D} is already a term. Open it to add a spoken form."
            return
        }

        let before = Set(coordinator.settings.glossary.map(\.termId))
        var accepted = false
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.standard) {
            accepted = coordinator.commitTerm(
                termId: nil,
                canonical: trimmed,
                spokenForms: draftForms
            )
        }
        guard accepted else {
            refusal = coordinator.glossaryNotice
            return
        }
        refusal = nil
        endDraft()
        selectedTermId = coordinator.settings.glossary.first { !before.contains($0.termId) }?.termId
    }

    // MARK: Removal

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                guard !isPresented else { return }
                pendingRemoval = nil
            }
        )
    }

    /// Removal is not a proposal to validate: dropping a term can never make the
    /// surviving spoken forms ambiguous, so it writes and saves directly rather
    /// than going through the sanitizer that guards edits and additions.
    private func remove(_ term: ProtectedTerm) {
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.standard) {
            coordinator.settings.glossary.removeAll { $0.termId == term.termId }
        }
        coordinator.saveSettings()
        if selectedTermId == term.termId {
            selectedTermId = nil
        }
        pendingRemoval = nil
    }

    // MARK: Word list

    private var wordListRow: some View {
        // A failure is the more urgent sentence and it occupies the same slot:
        // the standing hint has nothing to add while an import is broken, and the
        // next `importWordList()` clears it.
        ConsoleRow(
            caption: importFailure
                ?? "Import a newline- or JSON-array word list. Terms stay on this Mac, and duplicates are merged.",
            captionColor: importFailure.map { _ in Color.red }
        ) {
            LabeledContent {
                Button("Import Word List\u{2026}") { importWordList() }
            } label: {
                Text("Word list")
            }
        }
    }

    private func importWordList() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [.plainText, .json]
        panel.prompt = "Import"
        panel.message = "Choose a word list (.txt or .json)."
        importOutcome = nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `importWordList` merges synchronously and reports failures on
        // `glossaryNotice`, the glossary-local channel. The surface that owns
        // the action reports its own outcome.
        let before = coordinator.settings.glossary.count
        coordinator.importWordList(from: url)
        if let message = coordinator.glossaryNotice {
            importOutcome = .failed(message)
        } else {
            importOutcome = .added(coordinator.settings.glossary.count - before)
        }
    }

    private enum ImportOutcome: Equatable {
        case added(Int)
        case failed(String)
    }

    private var importedLabel: String? {
        guard case .added(let count) = importOutcome else { return nil }
        return count == 1 ? "IMPORTED 1 TERM" : "IMPORTED \(count) TERMS"
    }

    private var importFailure: String? {
        if case .failed(let message) = importOutcome { return message }
        return nil
    }
}

// MARK: - Suggested corrections

/// The corrections the last dictation proposed. Teaching one changes future
/// dictation; nothing here ever edits text that was already inserted.
struct ConsoleSuggestionsList: View {
    var coordinator: DictationCoordinator
    @State private var dismissedIDs: Set<String> = []

    private var visible: [TermSuggestion] {
        coordinator.pendingSuggestions.filter { !dismissedIDs.contains($0.id) }
    }

    var body: some View {
        ForEach(visible) { suggestion in
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    // Teach and Ignore, because Keep and Reject were two words
                    // for outcomes a reader could not tell apart: one hid the
                    // row, the other taught the glossary never to offer it.
                    Button("Teach") { coordinator.acceptSuggestion(id: suggestion.id) }
                        .help(
                            "Teach Voiceour to use \u{201C}\(suggestion.canonical)\u{201D} next time. "
                                + "Your pasted text is unchanged."
                        )
                        .accessibilityLabel(
                            "Teach correction from \(suggestion.misheard) to \(suggestion.canonical)"
                        )
                        .accessibilityIdentifier("suggestion.\(suggestion.id).accept")

                    Button("Ignore") { dismissedIDs.insert(suggestion.id) }
                        .help("Hide this suggestion. Nothing is taught and the pasted text is unchanged.")
                        .accessibilityLabel("Ignore suggestion for \(suggestion.misheard)")
                        .accessibilityIdentifier("suggestion.\(suggestion.id).ignore")
                }
            } label: {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    Text(suggestion.misheard)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(suggestion.canonical)
                        .font(.body.monospaced())
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Suggested correction: \(suggestion.misheard) becomes \(suggestion.canonical)"
                )
            }
            // Never offering this pairing again is a rarer answer than the two
            // on the row, and it is the only one that writes a rejection.
            .contextMenu {
                Button("Never Suggest This") { coordinator.rejectSuggestion(id: suggestion.id) }
                    .accessibilityIdentifier("suggestion.\(suggestion.id).reject")
            }
        }
    }
}
