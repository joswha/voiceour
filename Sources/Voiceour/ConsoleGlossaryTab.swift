import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

/// What the Glossary's sidebar has chosen: the terms of one origin (nil for every
/// term), or the corrections the last dictation suggested.
enum GlossaryShelf: Hashable {
    case terms(TermOrigin?)
    case suggestions
}

/// Glossary: the spellings dictation is held to, the spoken forms that map onto
/// them, and the corrections the last dictation proposed.
///
/// Three panes, the Journal's shape: a glass sidebar of origins and Suggestions,
/// a list column of terms, and a page for the selected term with
/// `ConsoleTermEditor` in an island. Add Term opens a "New term" page; a
/// selected suggestion's page offers Teach, Ignore and Never Suggest This.
///
/// A row says what it holds: the spelling, then the spoken forms that reach it,
/// or that it is matched by its spelling only. The case and spacing variants a
/// term is matched by without anyone typing them live in the editor's
/// `Also matched` readout.
struct ConsoleGlossaryTab: View {
    var coordinator: DictationCoordinator

    @State private var shelf: GlossaryShelf = .terms(nil)
    /// The open term, or nil. A lexicon opens as a list: the reader came to find
    /// one spelling among many, not to edit the first.
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
    /// The refusal the last commit published, held so the editor can stay open
    /// on the text the reader typed. Read from `glossaryNotice` only when a
    /// commit actually refused, so a stale notice is never reported as this
    /// edit's problem.
    @State private var refusal: String?
    @State private var pendingRemoval: ProtectedTerm?
    /// Why the last import failed, shown under the list bar until the next import
    /// or search. A successful import confirms in the page toast instead.
    @State private var importFailure: String?
    @State private var flash = Kit.Flash()
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// The row a key press or a move selected, scrolled into view.
    @State private var reveal: String?
    /// True while the tab is narrower than `Kit.Metrics.railBelow`, so the sidebar
    /// folds to its rail of glyphs and the page keeps its reading width.
    @State private var isNarrow = false

    /// The open term's editable copy, seeded when a term opens and written back
    /// only by Save. Escape closes the editor, which discards it.
    @State private var editedTerm = ""
    @State private var editedForms: [String] = []

    /// Derived data cached as snapshots, recomputed when the ledger, the query or
    /// the shelf changes. An imported lexicon is hundreds of rows, and filtering
    /// and sorting them inside `body` would redo that work on every keystroke and
    /// every selection read.
    @State private var matchingTerms: [ProtectedTerm] = []
    @State private var originFacets: [TermOriginFacet] = []
    @State private var liveTermCount = 0
    /// The open term as stored, its spoken forms and its derived variants.
    @State private var openTerm: ProtectedTerm?
    @State private var openTermForms: [String] = []
    @State private var openTermDerived: [String] = []
    @State private var draftDerived: [String] = []

    /// Suggestions the reader ignored. Ignore hides one and teaches nothing, so it
    /// lives here rather than in the coordinator, and it is pruned to the
    /// suggestions still pending.
    @State private var dismissedSuggestionIDs: Set<String> = []
    @State private var visibleSuggestions: [TermSuggestion] = []
    @State private var selectedSuggestionId: String?

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    private static let editorCaption =
        "Add a spoken form only when dictation heard something else. Case and spacing variants are "
        + "matched automatically."
    private static let termsFooter =
        "Click a term to edit it. Case and spacing variants of a term are matched automatically."
    private static let wordListHint =
        "Import a newline- or JSON-array word list. Terms stay on this Mac, and duplicates are merged."
    private static let suggestionsHeading = "From your last dictation"

    var body: some View {
        Kit.Screen {
            content
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.width < Kit.Metrics.railBelow
                } action: { narrow in
                    isNarrow = narrow
                }
        }
        .onAppear {
            reloadDerivedData()
            reloadSuggestions()
            openInitialShelf()
        }
        .onDisappear {
            flash.dismiss()
        }
        .onChange(of: coordinator.settings.glossary) {
            reloadDerivedData()
        }
        .onChange(of: coordinator.pendingSuggestions) {
            reloadSuggestions()
        }
        .onChange(of: searchText) {
            importFailure = nil
            // Search runs over terms; a query typed while Suggestions is open is
            // a request to find a term.
            if shelf == .suggestions && !query.isEmpty {
                shelf = .terms(nil)
            }
            reloadDerivedData()
        }
        .onChange(of: shelf) {
            reloadDerivedData()
            if shelf == .suggestions {
                ensureSuggestionSelection()
            }
        }
        .onChange(of: selectedTermId) {
            refreshOpenTerm()
            seedEditor()
        }
        .onChange(of: draftTerm) {
            draftDerived = Glossary.derivedAliases(for: draftTerm)
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

    @ViewBuilder
    private var content: some View {
        if liveTermCount == 0 && !isComposing && visibleSuggestions.isEmpty {
            emptyTerms
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: Kit.Metrics.gutter) {
                sidebar
                    .environment(\.kitCompactControls, isNarrow)
                    .frame(width: isNarrow ? Kit.Metrics.railWidth : Kit.Metrics.sidebarWidth)

                Kit.Split {
                    listColumn
                } page: {
                    page
                        .kitToast(flash, identifier: "glossary.imported")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding([.leading, .vertical], Kit.Metrics.gutter)
        }
    }

    // MARK: Derived data

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var originFilter: TermOrigin? {
        if case .terms(let origin) = shelf { return origin }
        return nil
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
        // An origin whose last term was just removed or cleared would narrow the
        // list to nothing with no offered way back, so it falls away with it.
        if let engaged = originFilter, !originFacets.contains(where: { $0.origin == engaged }) {
            shelf = .terms(nil)
        }
        matchingTerms = GlossaryQuery.matches(in: terms, query: query, origin: originFilter)
        if let open = selectedTermId, !terms.contains(where: { $0.termId == open && $0.tombstonedAt == nil }) {
            selectedTermId = nil
        }
        refreshOpenTerm()
    }

    private func refreshOpenTerm() {
        let term = selectedTermId.flatMap { id in
            coordinator.settings.glossary.first { $0.termId == id && $0.tombstonedAt == nil }
        }
        openTerm = term
        openTermForms = term.map { Glossary.userAliases(for: $0) } ?? []
        openTermDerived = term.map { Glossary.derivedAliases(for: $0.canonical) } ?? []
    }

    /// Rebuilds the suggestions the reader has not ignored. Suggestions emptied
    /// from elsewhere — the next recording, Clear Vocabulary — return the sidebar
    /// to All Terms.
    private func reloadSuggestions() {
        let pending = coordinator.pendingSuggestions
        dismissedSuggestionIDs.formIntersection(pending.map(\.id))
        visibleSuggestions = pending.filter { !dismissedSuggestionIDs.contains($0.id) }
        guard shelf == .suggestions else { return }
        if visibleSuggestions.isEmpty {
            shelf = .terms(nil)
        } else {
            ensureSuggestionSelection()
        }
    }

    /// A suggestion is about the dictation that just happened, so the tab opens
    /// on Suggestions while any are pending, with the first one's page showing.
    private func openInitialShelf() {
        if !visibleSuggestions.isEmpty {
            endDraft()
            shelf = .suggestions
            selectedSuggestionId = visibleSuggestions.first?.id
            reveal = selectedSuggestionId
        } else if shelf == .suggestions {
            shelf = .terms(nil)
        }
    }

    private func ensureSuggestionSelection() {
        guard !visibleSuggestions.contains(where: { $0.id == selectedSuggestionId }) else { return }
        selectedSuggestionId = visibleSuggestions.first?.id
        reveal = selectedSuggestionId
    }

    private var selectedSuggestion: TermSuggestion? {
        visibleSuggestions.first { $0.id == selectedSuggestionId }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Kit.Sidebar {
            Kit.SidebarItem(
                "All Terms",
                systemImage: "character.book.closed",
                count: liveTermCount,
                isSelected: shelf == .terms(nil)
            ) {
                selectShelf(.terms(nil))
            }
            .accessibilityIdentifier("glossary.origin.all")

            // Only the origins some live term carries: an origin whose only effect
            // is to empty the list is not a choice.
            ForEach(originFacets) { facet in
                Kit.SidebarItem(
                    Self.originTitle(facet.origin),
                    systemImage: Self.originSymbol(facet.origin),
                    count: facet.count,
                    isSelected: shelf == .terms(facet.origin)
                ) {
                    selectShelf(.terms(facet.origin))
                }
                .accessibilityIdentifier("glossary.origin.\(Self.originKey(facet.origin))")
            }

            if !visibleSuggestions.isEmpty {
                if !isNarrow {
                    Kit.SidebarHeading(Self.suggestionsHeading)
                        .padding(.top, VoiceourMetrics.Space.md)
                }
                Kit.SidebarItem(
                    "Suggestions",
                    systemImage: "sparkles",
                    count: visibleSuggestions.count,
                    isSelected: shelf == .suggestions
                ) {
                    selectShelf(.suggestions)
                }
                .accessibilityIdentifier("glossary.suggestions")
            }
        }
    }

    private func selectShelf(_ choice: GlossaryShelf) {
        if choice == .suggestions {
            endDraft()
        }
        shelf = choice
    }

    private static func originTitle(_ origin: TermOrigin) -> String {
        switch origin {
        case .yours: "Yours"
        case .builtIn: "Built-in"
        }
    }

    private static func originSymbol(_ origin: TermOrigin) -> String {
        switch origin {
        case .yours: "person"
        case .builtIn: "shippingbox"
        }
    }

    private static func originKey(_ origin: TermOrigin) -> String {
        switch origin {
        case .yours: "yours"
        case .builtIn: "builtin"
        }
    }

    // MARK: List

    private var listColumn: some View {
        Kit.ListColumn(
            "Glossary",
            subtitle: listSubtitle,
            reveal: reveal,
            focus: $listFocused,
            onMove: move
        ) {
            listBar
        } content: {
            if shelf == .suggestions {
                ForEach(visibleSuggestions) { suggestion in
                    suggestionRow(suggestion)
                        .id(suggestion.id)
                }
            } else if matchingTerms.isEmpty && liveTermCount > 0 {
                noMatches
                    .padding(.top, VoiceourMetrics.Space.xl)
            } else {
                ForEach(matchingTerms) { term in
                    row(for: term)
                        .id(term.termId)
                }
            }
        }
    }

    /// "7 terms", or "2 of 7 terms match" while a query or an origin narrows the
    /// list; with Suggestions open, how many are pending.
    private var listSubtitle: String {
        if shelf == .suggestions {
            let count = visibleSuggestions.count
            return count == 1 ? "1 suggestion" : "\(count) suggestions"
        }
        guard query.isEmpty && originFilter == nil else {
            return "\(matchingTerms.count) of \(liveTermCount) terms match"
        }
        return liveTermCount == 1 ? "1 term" : "\(liveTermCount) terms"
    }

    /// The search field, then Add Term and Import as glyph buttons — the list is
    /// too narrow for their titles beside the field, and each keeps its title as
    /// its accessibility label. A failed import's reason sits under them.
    private var listBar: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.SearchField(
                    "Search terms and spoken forms",
                    text: $searchText,
                    identifier: "glossary.search.field",
                    clearIdentifier: "glossary.search.clear",
                    focus: $searchFocused,
                    onSubmit: selectFirstMatch
                )
                Kit.GlassGroup {
                    addTermButton
                    importButton
                }
                .environment(\.kitCompactControls, true)
            }
            if let importFailure {
                importFailureCaption(importFailure)
                    .padding(.horizontal, VoiceourMetrics.Space.sm)
            }
        }
    }

    private var addTermButton: some View {
        Kit.ActionButton("Add Term", systemImage: "plus", action: beginDraft)
            .help("Add Term")
            .accessibilityIdentifier("glossary.add-term")
    }

    private var importButton: some View {
        Kit.ActionButton("Import\u{2026}", systemImage: "square.and.arrow.down", action: importWordList)
            .help(Self.wordListHint)
            .accessibilityIdentifier("glossary.import")
    }

    private func importFailureCaption(_ message: String) -> some View {
        Text(message)
            .roleStyle(.caption)
            .foregroundStyle(VoiceourPalette.Signal.crimson)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for term: ProtectedTerm) -> some View {
        let forms = Glossary.userAliases(for: term)
        return Kit.TitleRow(
            term.canonical,
            subtitle: Self.summary(of: forms),
            isSelected: shelf != .suggestions && !isComposing && term.termId == selectedTermId,
            monospacedTitle: true,
            action: { select(term) }
        ) {
            if GlossaryQuery.origin(of: term) == .builtIn {
                Kit.Mark("BUILT-IN")
            }
        }
        .help(term.canonical)
        .accessibilityLabel(Self.accessibilityLabel(for: term, forms: forms))
        .accessibilityIdentifier("glossary.term.\(term.termId)")
        .contextMenu {
            Button("Remove Term\u{2026}", role: .destructive) {
                select(term)
                pendingRemoval = term
            }
        }
    }

    private func suggestionRow(_ suggestion: TermSuggestion) -> some View {
        Kit.TitleRow(
            "\(suggestion.misheard) \u{2192} \(suggestion.canonical)",
            subtitle: "Suggested correction",
            isSelected: suggestion.id == selectedSuggestionId,
            monospacedTitle: true,
            action: { selectSuggestion(suggestion.id) }
        ) {
            EmptyView()
        }
        .accessibilityLabel(Self.suggestionLabel(suggestion))
        .accessibilityIdentifier("glossary.suggestion.\(suggestion.id)")
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

    private static func suggestionLabel(_ suggestion: TermSuggestion) -> String {
        "Suggested correction: \(suggestion.misheard) becomes \(suggestion.canonical)"
    }

    /// Empty results imply a non-empty query: an origin offered by the sidebar can
    /// never rule out every term on its own. It can still be the reason a query
    /// found nothing, so it is offered back.
    private var noMatches: some View {
        ContentUnavailableView {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
        } description: {
            Text("Search runs over terms and their spoken forms.")
        } actions: {
            Kit.ActionButton("Clear Search") { searchText = "" }
            if originFilter != nil {
                Kit.ActionButton("Show All Terms") { shelf = .terms(nil) }
            }
        }
    }

    // MARK: Selection

    private func select(_ term: ProtectedTerm) {
        // Pressing a row is an answer to the draft as well: a two-field draft is
        // not worth a confirmation, and Save is the default action.
        endDraft()
        selectedTermId = term.termId
        listFocused = true
    }

    private func selectSuggestion(_ id: String) {
        selectedSuggestionId = id
        listFocused = true
    }

    /// Steps through the listed rows; a selection the list does not show starts
    /// from the top.
    private func move(_ direction: MoveCommandDirection) {
        let ids =
            shelf == .suggestions
            ? visibleSuggestions.map(\.id)
            : matchingTerms.map(\.termId)
        guard !ids.isEmpty else { return }
        let current = shelf == .suggestions ? selectedSuggestionId : selectedTermId
        let target: Int
        if let current, let index = ids.firstIndex(of: current) {
            switch direction {
            case .up: target = max(index - 1, 0)
            case .down: target = min(index + 1, ids.count - 1)
            default: return
            }
        } else {
            target = 0
        }
        if shelf == .suggestions {
            selectedSuggestionId = ids[target]
        } else {
            endDraft()
            selectedTermId = ids[target]
        }
        reveal = ids[target]
    }

    /// Return in the search field opens the first match and hands focus to the
    /// list, instead of re-running the filter every keystroke already ran.
    private func selectFirstMatch() {
        guard shelf != .suggestions, let first = matchingTerms.first else { return }
        endDraft()
        selectedTermId = first.termId
        reveal = first.termId
        searchFocused = false
        listFocused = true
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        if shelf == .suggestions, let suggestion = selectedSuggestion {
            suggestionPage(suggestion)
        } else if isComposing {
            draftPage
        } else if let term = openTerm {
            termPage(term)
        } else {
            ContentUnavailableView(
                "No term selected",
                systemImage: "character.book.closed",
                description: Text(Self.termsFooter)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func termPage(_ term: ProtectedTerm) -> some View {
        Kit.PageColumn(identity: term.termId) {
            Kit.ActionButton("Remove Term\u{2026}", systemImage: "trash", role: .destructive) {
                pendingRemoval = term
            }
            .help("Remove this term from the glossary")
            .accessibilityIdentifier("glossary.term.remove")
        } content: {
            Kit.PageHeader(
                eyebrow: Self.originTitle(GlossaryQuery.origin(of: term)),
                title: term.canonical,
                subtitle: Self.summary(of: openTermForms),
                monospacedTitle: true
            )
            editorIsland {
                ConsoleTermEditor(
                    term: $editedTerm,
                    spokenForms: $editedForms,
                    derivedForms: openTermDerived,
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
                    destructive: nil,
                    identifierPrefix: "glossary.term"
                )
                .id(term.termId)
            }
        }
    }

    private var draftPage: some View {
        Kit.PageColumn(identity: AnyHashable("glossary.draft")) {
            EmptyView()
        } content: {
            Kit.PageHeader(title: "New term")
            editorIsland {
                ConsoleTermEditor(
                    term: $draftTerm,
                    spokenForms: $draftForms,
                    derivedForms: draftDerived,
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
        }
    }

    private func editorIsland<Editor: View>(@ViewBuilder editor: () -> Editor) -> some View {
        Kit.Island {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                Kit.SectionTitle("Spelling and spoken forms")
                editor()
            }
        }
    }

    /// Teach and Ignore, because Keep and Reject were two words for outcomes a
    /// reader could not tell apart: one hid the row, the other taught the
    /// glossary never to offer it. Never Suggest This is that second answer, and
    /// the only one that writes a rejection.
    private func suggestionPage(_ suggestion: TermSuggestion) -> some View {
        Kit.PageColumn(identity: suggestion.id) {
            Kit.GlassGroup {
                Kit.ActionButton("Teach", systemImage: "checkmark", prominence: .primary) {
                    teach(suggestion)
                }
                .help(
                    "Teach Voiceour to use \u{201C}\(suggestion.canonical)\u{201D} next time. "
                        + "Your pasted text is unchanged."
                )
                // The closure form replaces the label the kit button derives from
                // its title, whatever order the modifiers resolve in.
                .accessibilityLabel { _ in
                    Text("Teach correction from \(suggestion.misheard) to \(suggestion.canonical)")
                }
                .accessibilityIdentifier("suggestion.\(suggestion.id).accept")

                Kit.ActionButton("Ignore", systemImage: "eye.slash") {
                    ignore(suggestion)
                }
                .help("Hide this suggestion. Nothing is taught and the pasted text is unchanged.")
                .accessibilityLabel { _ in Text("Ignore suggestion for \(suggestion.misheard)") }
                .accessibilityIdentifier("suggestion.\(suggestion.id).ignore")

                Kit.ActionButton("Never Suggest This", systemImage: "hand.raised") {
                    neverSuggest(suggestion)
                }
                .help("Never offer this correction again. The pasted text is unchanged.")
                .accessibilityIdentifier("suggestion.\(suggestion.id).reject")
            }
        } content: {
            Kit.PageHeader(
                eyebrow: Self.suggestionsHeading,
                title: suggestion.canonical,
                subtitle: "Heard as \(suggestion.misheard)",
                monospacedTitle: true
            )
            Kit.Island {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    Kit.SectionTitle("Suggested correction")
                    HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                        Text(suggestion.misheard)
                            .roleStyle(.tileValue)
                            .foregroundStyle(a11y.textMid)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(VoiceourPalette.Alien.bloom)
                            .accessibilityHidden(true)
                        Text(suggestion.canonical)
                            .roleStyle(.tileValue)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.suggestionLabel(suggestion))
                    Text("Accept teaches future dictation only — the text you already pasted is never changed.")
                        .roleStyle(.caption)
                        .foregroundStyle(a11y.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Suggestions

    /// A refused teach leaves the suggestion pending, and its page stays.
    private func teach(_ suggestion: TermSuggestion) {
        let order = visibleSuggestions.map(\.id)
        coordinator.acceptSuggestion(id: suggestion.id)
        guard !coordinator.pendingSuggestions.contains(where: { $0.id == suggestion.id }) else { return }
        advance(past: suggestion.id, in: order, landingOn: suggestion.termId)
    }

    private func ignore(_ suggestion: TermSuggestion) {
        let order = visibleSuggestions.map(\.id)
        dismissedSuggestionIDs.insert(suggestion.id)
        advance(past: suggestion.id, in: order, landingOn: nil)
    }

    private func neverSuggest(_ suggestion: TermSuggestion) {
        let order = visibleSuggestions.map(\.id)
        coordinator.rejectSuggestion(id: suggestion.id)
        advance(past: suggestion.id, in: order, landingOn: nil)
    }

    /// Selects the suggestion that took an answered one's place: the next one
    /// still pending, else the previous. With none left the sidebar returns to All
    /// Terms, on the term a teach just changed, or on nothing.
    private func advance(past id: String, in order: [String], landingOn termId: String?) {
        let remaining = Set(
            coordinator.pendingSuggestions.map(\.id).filter { !dismissedSuggestionIDs.contains($0) }
        )
        let next: String? = order.firstIndex(of: id).flatMap { index in
            order[(index + 1)...].first { remaining.contains($0) }
                ?? order[..<index].last { remaining.contains($0) }
        }
        if let next {
            selectedSuggestionId = next
            reveal = next
            reloadSuggestions()
            return
        }
        shelf = .terms(nil)
        reloadSuggestions()
        selectedSuggestionId = nil
        if let termId, selectedTermId == termId {
            // The teach changed the open term's forms; the editor's copy must
            // not save the set it held before.
            refreshOpenTerm()
            seedEditor()
        } else {
            selectedTermId = termId
        }
        reveal = termId
    }

    // MARK: Editing

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

    /// Save answers a change. Offering it against an unchanged term would make a
    /// no-op look like a write, and an empty spelling is not a term.
    private func canSave(_ term: ProtectedTerm) -> Bool {
        guard !editedTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return editedTerm != term.canonical || editedForms != openTermForms
    }

    /// The editor lists the whole form set, so it commits with the term's id:
    /// what it shows is what the record becomes, and a form deleted here is
    /// deleted. A refusal keeps the editor open on the text that caused it.
    private func save(_ term: ProtectedTerm) {
        var accepted = false
        withAnimation(Kit.Motion.standard(a11y)) {
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
        // editor still shows, and the page must not disagree with the record.
        reloadDerivedData()
        if let stored = coordinator.settings.glossary.first(where: { $0.termId == term.termId }) {
            seedEditor(with: stored)
        }
    }

    private func beginDraft() {
        refusal = nil
        if shelf == .suggestions {
            shelf = .terms(nil)
        }
        selectedTermId = nil
        draftTerm = ""
        draftForms = []
        draftDerived = []
        isComposing = true
    }

    private func endDraft() {
        guard isComposing else { return }
        isComposing = false
        draftTerm = ""
        draftForms = []
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
        withAnimation(Kit.Motion.standard(a11y)) {
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
        // A new term is the reader's own, so a Built-in list would hide it.
        if shelf == .terms(.builtIn) {
            shelf = .terms(nil)
        }
        let created = coordinator.settings.glossary.first { !before.contains($0.termId) }?.termId
        selectedTermId = created
        reveal = created
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
        withAnimation(Kit.Motion.standard(a11y)) {
            coordinator.settings.glossary.removeAll { $0.termId == term.termId }
        }
        coordinator.saveSettings()
        if selectedTermId == term.termId {
            selectedTermId = nil
        }
        pendingRemoval = nil
    }

    // MARK: Empty state

    /// Says what a term is rather than reporting that a list is empty, and offers
    /// both ways a first term arrives.
    private var emptyTerms: some View {
        ContentUnavailableView {
            Text("No terms yet")
        } description: {
            Text(
                "A term is the spelling Voiceour holds a word to when dictation keeps hearing it wrong. "
                    + "Add one, or import a word list."
            )
        } actions: {
            VStack(spacing: VoiceourMetrics.Space.md) {
                Kit.GlassGroup {
                    Kit.ActionButton("Add Term", systemImage: "plus", prominence: .primary, action: beginDraft)
                        .accessibilityIdentifier("glossary.add-term")
                    importButton
                }
                if let importFailure {
                    importFailureCaption(importFailure)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: Kit.Metrics.listWidth)
                }
            }
        }
    }

    // MARK: Word list

    private func importWordList() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [.plainText, .json]
        panel.prompt = "Import"
        panel.message = "Choose a word list (.txt or .json)."
        importFailure = nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `importWordList` merges synchronously and reports failures on
        // `glossaryNotice`, the glossary-local channel. The surface that owns
        // the action reports its own outcome, and confirms a success only after
        // the merge landed.
        let before = coordinator.settings.glossary.count
        coordinator.importWordList(from: url)
        if let message = coordinator.glossaryNotice {
            importFailure = message
        } else {
            let count = coordinator.settings.glossary.count - before
            flash.show(count == 1 ? "Imported 1 term" : "Imported \(count) terms", animation: Kit.Motion.quick(a11y))
        }
    }
}
