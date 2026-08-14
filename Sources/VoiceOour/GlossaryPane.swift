import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

struct GlossaryPane: View {
    var coordinator: DictationCoordinator
    @State private var newTerm = ""
    @State private var newAliases = ""
    @State private var duplicate: String?
    @State private var importOutcome: ImportOutcome?
    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        let terms = visibleTerms
        let showsPolicy = Set(terms.map(\.casePolicy)).count > 1
        let showsProtected = terms.contains { !$0.protected }
        // The header names SCOPE only when at least one row paints a chip. Its
        // frame remains in every band so the trailing action column never moves.
        let showsScope = terms.contains { $0.scope != .global }

        SettingsPaneScroll(maxContentWidth: VoiceOourMetrics.Content.table) {
            SettingsSectionBlock(eyebrow: "PROJECT LEXICON") {
                // The affordance sits on the same label grid every other
                // settings card uses, so the Glossary's first card stops
                // speaking its own dialect: label at the rail, controls on one
                // band, and the single sentence that explains them starting on
                // the value-column seam instead of at the card's origin.
                SettingsRow(
                    label: "Word list",
                    // A failure is the more urgent sentence and it occupies the
                    // same slot: the standing hint has nothing to add while an
                    // import is broken, and the next `importLexicon()` clears it.
                    caption: importFailure
                        ?? "Import a newline- or JSON-array word list. Terms are added project-scoped, stay on this Mac, and duplicates are merged.",
                    captionColor: importFailure.map { _ in VoiceOourPalette.Signal.crimson },
                    status: importedStatus
                ) {
                    HStack(spacing: VoiceOourMetrics.Space.sm) {
                        Button("IMPORT WORD LIST…") { importLexicon() }
                            .buttonStyle(GlassButtonStyle(kind: .ghost))
                        if let projectName = coordinator.activeProjectName {
                            StatusChip(label: "PROJECT · \(projectName)", mode: .neutral)
                        }
                    }
                }
            }

            SettingsSectionBlock(eyebrow: "TERM LEDGER") {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if terms.isEmpty {
                        // Five row pitches say what a canonical term is without
                        // turning the empty ledger into an unbounded void.
                        EmptyState(
                            glyph: "character.book.closed",
                            title: "No canonical terms yet",
                            body:
                                "A canonical term is the spelling VoiceOour holds a word to when dictation keeps hearing it wrong. Add the first one below, or import a project word list."
                        )
                        .glossaryBand(height: VoiceOourMetrics.Row.table * 5, alignment: .leading)
                    } else {
                        GlossaryHeaderRow(showsPolicy: showsPolicy, showsScope: showsScope)
                        ForEach(terms) { term in
                            GlossaryTermRow(
                                term: term,
                                showsPolicy: showsPolicy,
                                showsProtected: showsProtected,
                                updateAliases: { aliases in
                                    guard
                                        let index = coordinator.settings.glossary.firstIndex(where: {
                                            $0.termId == term.termId
                                        })
                                    else { return }
                                    coordinator.settings.glossary[index] = TermMutation.settingAliases(
                                        aliases,
                                        on: coordinator.settings.glossary[index]
                                    )
                                    coordinator.saveSettings()
                                },
                                remove: { remove(term) }
                            )
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }

                    GlossaryAddRow(
                        newTerm: $newTerm,
                        newAliases: $newAliases,
                        showsPolicy: showsPolicy,
                        canAdd: !newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        addTerm: addTerm
                    )
                }
                .onChange(of: newTerm) { _, _ in duplicate = nil }
                // The header band centres a 13pt text inside a `Row.table` band, so the
                // card's first ink row sits half that slack below the frame. Declaring it
                // lets `SettingsSectionBlock` trim it and land the same eyebrow-to-ink
                // step as PROJECT LEXICON above, whose `SettingsRow` declares its own.
                .settingsContentLead((VoiceOourMetrics.Row.table - 13) / 2)

                if let duplicate {
                    CaptionText("\(duplicate) is already in the ledger.", color: VoiceOourPalette.Signal.amber)
                        .padding(.top, VoiceOourMetrics.Space.sm)
                }

                CaptionText(
                    "Case and spacing variants (\"ns pasteboard\", \"n s pasteboard\") are matched automatically from the canonical. Add DETECTED AS entries only when speech-to-text heard a genuinely different phrase (\"cube cuddle\" for kubectl)."
                )
                .padding(.top, VoiceOourMetrics.Space.md)
                .frame(maxWidth: VoiceOourMetrics.Content.form, alignment: .leading)
            }
        }
    }

    /// Every other consumer of this array reads it through a tombstone filter
    /// (`Glossary.lockedCanonicals`, `Glossary.activeTerms`, `VocabularyCompiler.compile`,
    /// `CandidateRetriever.retrieve`, and `RefinerPolicy.cloudEligible`). A term the
    /// engines treat as retired is not a live, editable row here either.
    private var visibleTerms: [ProtectedTerm] {
        coordinator.settings.glossary.filter { $0.tombstonedAt == nil }
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
        withAnimation(a11y.reduceMotion ? nil : VoiceOourMotion.standard) {
            coordinator.settings.glossary.append(term)
        }
        coordinator.saveSettings()
        newTerm = ""
        newAliases = ""
    }

    private func remove(_ term: ProtectedTerm) {
        withAnimation(a11y.reduceMotion ? nil : VoiceOourMotion.standard) {
            coordinator.settings.glossary.removeAll { $0.termId == term.termId }
        }
        coordinator.saveSettings()
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
        // `errorMessage`, which is only rendered in the menu-bar popover. The card
        // that owns the action reports its own outcome.
        let before = coordinator.settings.glossary.count
        coordinator.importProjectLexicon(from: url)
        if let message = coordinator.errorMessage {
            importOutcome = .failed(message)
        } else {
            importOutcome = .added(coordinator.settings.glossary.count - before)
        }
    }

    private enum ImportOutcome: Equatable {
        case added(Int)
        case failed(String)
    }

    /// A successful import is a compact mark, so it rides the row's trailing
    /// status rail rather than a third chip crowding the control band.
    private var importedStatus: (label: String, mode: StatusChip.Mode)? {
        guard case .added(let count) = importOutcome else { return nil }
        return (label: count == 1 ? "IMPORTED 1 TERM" : "IMPORTED \(count) TERMS", mode: .ok)
    }

    private var importFailure: String? {
        if case .failed(let message) = importOutcome { return message }
        return nil
    }
}
