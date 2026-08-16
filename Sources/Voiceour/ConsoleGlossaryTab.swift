import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

/// Glossary: the canonical spellings dictation is held to, the speech-to-text
/// detections that map onto them, and the corrections the last dictation
/// proposed.
struct ConsoleGlossaryTab: View {
    var coordinator: DictationCoordinator

    @State private var newTerm = ""
    @State private var newAliases = ""
    @State private var duplicate: String?
    /// The refusal `commitGlossary` published for the edit that was just
    /// attempted. Read from `glossaryNotice` only when the commit returned
    /// false, so a stale notice from an earlier action can never be reported
    /// here as this edit's problem.
    @State private var refusal: String?
    @State private var importOutcome: ImportOutcome?
    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        let terms = visibleTerms
        let showsPolicy = Set(terms.map(\.casePolicy)).count > 1
        let showsProtected = terms.contains { !$0.protected }

        Form {
            Section("Project lexicon") {
                projectLexiconRow
            }

            Section {
                if terms.isEmpty {
                    // Says what a canonical term is rather than reporting that a
                    // list is empty.
                    ContentUnavailableView {
                        Text("No canonical terms yet")
                    } description: {
                        Text(
                            "A canonical term is the spelling Voiceour holds a word to when dictation keeps hearing "
                                + "it wrong. Add the first one below, or import a project word list."
                        )
                    }
                } else {
                    ForEach(terms) { term in
                        ConsoleGlossaryTermRow(
                            term: term,
                            showsPolicy: showsPolicy,
                            showsProtected: showsProtected,
                            updateAliases: { aliases in commitAliases(aliases, on: term) },
                            remove: { remove(term) }
                        )
                        .transition(.opacity)
                    }
                }
            } header: {
                Text("Terms")
            } footer: {
                ConsoleCaption(
                    "Case and spacing variants (\u{201C}ns pasteboard\u{201D}, \u{201C}n s pasteboard\u{201D}) are "
                        + "matched automatically from the canonical. Add DETECTED AS entries only when "
                        + "speech-to-text heard a genuinely different phrase (\u{201C}cube cuddle\u{201D} for kubectl)."
                )
            }

            Section("Add a term") {
                addRow
            }

            if !coordinator.pendingSuggestions.isEmpty {
                Section {
                    ConsoleSuggestionsList(coordinator: coordinator)
                } header: {
                    Text("Suggested corrections")
                } footer: {
                    ConsoleCaption(
                        "From your last dictation. Accept teaches future dictation only — the text you already "
                            + "pasted is never changed."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: newTerm) { _, _ in
            duplicate = nil
            refusal = nil
        }
    }

    /// Tombstoned terms are retired from cleanup, vocabulary compilation, and
    /// candidate retrieval, so they are not live, editable rows here either.
    private var visibleTerms: [ProtectedTerm] {
        coordinator.settings.glossary.filter { $0.tombstonedAt == nil }
    }

    // MARK: Project lexicon

    private var projectLexiconRow: some View {
        // A failure is the more urgent sentence and it occupies the same slot:
        // the standing hint has nothing to add while an import is broken, and the
        // next `importLexicon()` clears it.
        ConsoleRow(
            caption: importFailure
                ?? "Import a newline- or JSON-array word list. Terms are added project-scoped, stay on this Mac, "
                + "and duplicates are merged.",
            captionColor: importFailure.map { _ in Color.red }
        ) {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if let importedLabel {
                        ConsoleStateMark(importedLabel, .ok)
                    }
                    Button("Import Word List…") { importLexicon() }
                }
            } label: {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Text("Word list")
                    if let projectName = coordinator.activeProjectName {
                        ConsoleStateMark("PROJECT · \(projectName)", .neutral)
                    }
                }
            }
        }
    }

    private func importLexicon() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [.plainText, .json]
        panel.prompt = "Import"
        panel.message = "Choose a project word list (.txt or .json)."
        importOutcome = nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `importProjectLexicon` merges synchronously and reports failures on
        // `glossaryNotice`, the glossary-local channel. The surface that owns
        // the action reports its own outcome.
        let before = coordinator.settings.glossary.count
        coordinator.importProjectLexicon(from: url)
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

    // MARK: Add a term

    private var addRow: some View {
        ConsoleRow(caption: addFailure, captionColor: addFailure.map { _ in Color.orange }) {
            LabeledContent {
                TextField("Canonical term", text: $newTerm)
                    .autocorrectionDisabled(true)
                    .frame(width: VoiceourMetrics.Column.glossaryCanonical)
                    .onSubmit(addTerm)
                    .accessibilityIdentifier("glossary.add-term.canonical")
            } label: {
                Text("Canonical")
            }

            LabeledContent {
                TextField("Detected as (comma-separated)", text: $newAliases)
                    .autocorrectionDisabled(true)
                    .frame(width: VoiceourMetrics.Column.glossaryAliases)
                    .onSubmit(addTerm)
                    .accessibilityIdentifier("glossary.add-term.aliases")
            } label: {
                Text("Detected as")
            }

            HStack {
                Spacer(minLength: 0)
                Button {
                    addTerm()
                } label: {
                    Label("Add Term", systemImage: "plus")
                }
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("glossary.add-term.submit")
            }
        }
    }

    /// The duplicate refusal and the ambiguous-alias refusal are the same kind of
    /// answer to the same gesture, so they share one line rather than stacking
    /// two warnings under one composer.
    private var addFailure: String? {
        if let duplicate { return "\(duplicate) is already in the ledger." }
        return refusal
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep the typed text and name the collision: a silent wipe is
        // indistinguishable from a no-op.
        if let existing = coordinator.settings.glossary.first(where: {
            $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            duplicate = existing.canonical
            refusal = nil
            return
        }
        duplicate = nil
        // A term typed here remains user-authored so `clearLearnedVocabulary()`
        // can reach it; the composer makes it globally available.
        let term = ProtectedTerm(
            canonical: trimmed,
            spokenAliases: parsedGlossaryAliases(newAliases),
            protected: false,
            source: .manualImport,
            scope: .global
        )
        // Refused rather than added when one of its spoken forms already names
        // another term: the ledger keeps the text so the user can edit it.
        var accepted = false
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.standard) {
            accepted = commit(coordinator.settings.glossary + [term])
        }
        guard accepted else { return }
        newTerm = ""
        newAliases = ""
    }

    // MARK: Mutations

    /// Every alias edit and every addition goes through `commitGlossary`, which
    /// refuses a proposal whose spoken forms are ambiguous — an alias that also
    /// names another term's canonical or alias makes canonicalization depend on
    /// term order. The refusal is published on `glossaryNotice`, the
    /// glossary-local channel, and this tab lifts it onto the row that caused it.
    @discardableResult
    private func commit(_ proposed: [ProtectedTerm]) -> Bool {
        guard coordinator.commitGlossary(proposed) else {
            refusal = coordinator.glossaryNotice
            return false
        }
        refusal = nil
        return true
    }

    private func commitAliases(_ aliases: [String], on term: ProtectedTerm) {
        guard let index = coordinator.settings.glossary.firstIndex(where: { $0.termId == term.termId })
        else { return }
        var proposed = coordinator.settings.glossary
        proposed[index] = TermMutation.settingAliases(aliases, on: proposed[index])
        commit(proposed)
    }

    /// Removal is not a proposal to validate: dropping a term can never make the
    /// surviving aliases ambiguous, so it writes and saves directly rather than
    /// going through the sanitizer that guards edits and additions.
    private func remove(_ term: ProtectedTerm) {
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.standard) {
            coordinator.settings.glossary.removeAll { $0.termId == term.termId }
        }
        coordinator.saveSettings()
    }
}

// MARK: - Term row

/// One glossary entry. POLICY collapses while every term shares one policy, and
/// the lock disappears while every term is protected, so either one that remains
/// can tell rows apart. SCOPE paints only for a non-global term, because a global
/// term is available everywhere and needs no badge to say so.
private struct ConsoleGlossaryTermRow: View {
    var term: ProtectedTerm
    var showsPolicy: Bool
    var showsProtected: Bool
    var updateAliases: ([String]) -> Void
    var remove: () -> Void

    @State private var aliasText: String
    @FocusState private var aliasFieldFocused: Bool

    init(
        term: ProtectedTerm,
        showsPolicy: Bool,
        showsProtected: Bool,
        updateAliases: @escaping ([String]) -> Void,
        remove: @escaping () -> Void
    ) {
        self.term = term
        self.showsPolicy = showsPolicy
        self.showsProtected = showsProtected
        self.updateAliases = updateAliases
        self.remove = remove
        _aliasText = State(initialValue: Glossary.userAliases(for: term).joined(separator: ", "))
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                aliasField

                Button {
                    remove()
                } label: {
                    // The glyph is 13 pt; the affordance has to be bigger than the ink.
                    // A borderless button is exactly its label's size, so without this the
                    // target was 13x13 — under this project's own 22x22 hit floor and well
                    // under what a trackpad can hit reliably. 24 is the first size that
                    // clears the floor AND sits on the control scale.
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(term.canonical)")
                .accessibilityLabel("Remove \(term.canonical)")
                .accessibilityIdentifier("remove.\(term.termId)")
            }
        } label: {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                Text(term.canonical)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(term.canonical)

                if showsProtected && term.protected {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("Protected — deterministic cleanup keeps this canonical spelling")
                        .accessibilityLabel("Protected term \(term.canonical)")
                        .accessibilityIdentifier("protected.\(term.termId)")
                }

                if showsPolicy {
                    Text(term.casePolicy.rawValue.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let scopeLabel {
                    ConsoleStateMark(scopeLabel, .neutral)
                }
            }
        }
    }

    private var aliasField: some View {
        TextField("No alternate detections", text: $aliasText)
            .font(.body.monospaced())
            .autocorrectionDisabled(true)
            .frame(width: VoiceourMetrics.Column.glossaryAliases)
            .focused($aliasFieldFocused)
            .help(
                aliasText.isEmpty
                    ? "No alternate speech-to-text detections for \(term.canonical)"
                    : "Speech-to-text detected \(term.canonical) as \(aliasText)"
            )
            .accessibilityLabel("Speech-to-text detections for \(term.canonical)")
            .accessibilityIdentifier("aliases.\(term.termId)")
            .onSubmit {
                aliasFieldFocused = false
            }
            .onExitCommand {
                // Escape restores the persisted value without writing it back.
                aliasText = Glossary.userAliases(for: term).joined(separator: ", ")
                aliasFieldFocused = false
            }
            .onChange(of: aliasFieldFocused) { _, isFocused in
                if !isFocused {
                    commit()
                }
            }
            .onChange(of: Glossary.userAliases(for: term)) { _, aliases in
                if !aliasFieldFocused {
                    aliasText = aliases.joined(separator: ", ")
                }
            }
    }

    /// A global term needs no scope badge because it is available everywhere.
    private var scopeLabel: String? {
        guard term.scope != .global else { return nil }
        return term.scope.displayLabel
    }

    private func commit() {
        let aliases = parsedGlossaryAliases(aliasText)
        aliasText = aliases.joined(separator: ", ")
        guard aliases != Glossary.userAliases(for: term) else { return }
        updateAliases(aliases)
    }
}

// MARK: - Suggested corrections

/// The corrections the last dictation proposed. Accepting one teaches future
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
                    Button("Keep") { dismissedIDs.insert(suggestion.id) }
                        .help("Keep the pasted text and hide this suggestion. Nothing is taught.")
                        .accessibilityLabel("Keep pasted text for \(suggestion.misheard)")
                        .accessibilityIdentifier("suggestion.\(suggestion.id).keep")

                    Button("Accept") { coordinator.acceptSuggestion(id: suggestion.id) }
                        .help(
                            "Teach Voiceour to use \u{201C}\(suggestion.canonical)\u{201D} next time. "
                                + "Your pasted text is unchanged."
                        )
                        .accessibilityLabel(
                            "Accept correction from \(suggestion.misheard) to \(suggestion.canonical)"
                        )
                        .accessibilityIdentifier("suggestion.\(suggestion.id).accept")

                    Button("Reject") { coordinator.rejectSuggestion(id: suggestion.id) }
                        .help("Don't suggest this correction again.")
                        .accessibilityLabel(
                            "Reject correction from \(suggestion.misheard) to \(suggestion.canonical)"
                        )
                        .accessibilityIdentifier("suggestion.\(suggestion.id).reject")
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
        }
    }
}
