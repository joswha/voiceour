import SwiftUI
import VoiceCore

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
/// session-shaped stays here: the one-shot prefill from a right-click, the
/// lookup that resolves it to a term the glossary already holds, and the write
/// itself.
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
    /// The live term the prefilled surface already belongs to, when it belongs to
    /// one. Non-nil makes the commit a full-set edit of that record.
    @State private var matchedTermId: String?
    /// The reason the last teach was refused, kept so the editor can stay open
    /// on the text the user typed. A refusal used to close the editor silently
    /// and throw the term away.
    @State private var refusal: String?

    var body: some View {
        ConsoleTermEditor(
            term: $canonical,
            spokenForms: $spokenForms,
            derivedForms: Glossary.derivedAliases(for: canonical),
            // The surface this was aimed at IS the form. An empty well for a
            // second one sat between the transcript and the Teach button asking
            // for a spelling the reader had not heard; the Glossary tab is where
            // a term gains forms it was never taught from.
            offersAdditionalForms: false,
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

    private var canSubmit: Bool {
        !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seeds the editor from a transcript right-click, on open and on re-aim
    /// both. A surface the glossary already owns opens that term: its spelling
    /// and every user-authored form it carries, so a prior teaching is visible
    /// rather than invisible. An unowned surface opens a blank spelling with the
    /// surface as its one form — the Glossary Add Term shape. Consumes the
    /// one-shot binding so a repeat right-click of the same word re-triggers.
    ///
    /// Re-aiming replaces a typed-but-uncommitted draft: the gesture means "open
    /// this word's record", and preserving the old term would show a spelling
    /// that has nothing to do with the word just clicked.
    private func applyExternalPrefill() {
        // The keystroke's word, or the surface the harness aimed the editor at —
        // the seam substitutes exactly the input Command-T carries. Production
        // reads it as nil, which is the guard below refusing an unaimed editor.
        guard let word = externalPrefill?.word ?? RenderOverrides.historyTeachSurface else { return }
        if let owner = GlossaryQuery.termOwning(surface: word, in: coordinator.settings.glossary) {
            matchedTermId = owner.termId
            canonical = owner.canonical
            var forms = Glossary.userAliases(for: owner)
            let isCanonical = word.caseInsensitiveCompare(owner.canonical) == .orderedSame
            let alreadyListed = forms.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
            if !isCanonical, !alreadyListed {
                forms.append(word)
            }
            spokenForms = forms
        } else {
            matchedTermId = nil
            canonical = ""
            spokenForms = [word]
        }
        externalPrefill = nil
    }

    /// Teaches whatever the prefill resolved to. A matched term commits with its
    /// own id, so the editor's form list IS the term's set and a row the user
    /// removed is removed — the same full-set semantics as Glossary Save. An
    /// unmatched spelling commits with a nil id, so its form is added to whatever
    /// term already holds that spelling rather than substituted for the forms
    /// that term already carries. A `matchedTermId` whose term vanished mid-edit
    /// falls through `commitTerm`'s canonical-match branch, which is additive.
    private func submit() {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard
            coordinator.commitTerm(
                termId: matchedTermId,
                canonical: trimmed,
                spokenForms: spokenForms
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
        matchedTermId = nil
        refusal = nil
        isEditing = false
        externalPrefill = nil
    }
}
