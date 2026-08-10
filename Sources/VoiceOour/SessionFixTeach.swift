import SwiftUI
import VoiceCore

/// One-shot command to open the Fix/Teach editor prefilled from a transcript
/// right-click. Equatable so `.onChange` fires; consumed (set to nil) once applied.
struct FixTeachPrefill: Equatable {
    let word: String
}

struct FixTeachControl: View {
    var coordinator: DictationCoordinator
    var session: RecentSession
    @Binding var externalPrefill: FixTeachPrefill?
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

    private var appBundleId: String? {
        let id = session.outcome?.targetBundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private var projectId: String? {
        let id = coordinator.activeProjectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    /// Words present in the raw pre-cleanup transcript but not in the final text —
    /// the likely mishearing surfaces the user may want to map to a canonical term.
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

    /// The collapsed trigger sits with the transcript it edits; this view is the
    /// expanded form only, an inline well below that block.
    var body: some View {
        editor
            .onAppear {
                applyExternalPrefill()
                canonicalFocused = true
            }
            .onExitCommand(perform: cancel)
            .onChange(of: externalPrefill) {
                applyExternalPrefill()
            }
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            Text("TEACH A CORRECTION")
                .roleStyle(.eyebrow)

            HStack(spacing: VoiceOourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.hair) {
                    Text("CANONICAL TERM")
                        .roleStyle(.micro)

                    TextField(
                        "e.g. kubectl",
                        text: $canonical,
                        prompt: Text("e.g. kubectl").foregroundStyle(VoiceOourPalette.Text.low)
                    )
                    .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                    .frame(width: VoiceOourMetrics.Column.glossaryCanonical)
                    .focused($canonicalFocused)
                    .onSubmit(submit)
                }

                VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.hair) {
                    Text("DETECTED AS (OPTIONAL)")
                        .roleStyle(.micro)

                    TextField(
                        "e.g. cube control",
                        text: $misheard,
                        prompt: Text("e.g. cube control").foregroundStyle(VoiceOourPalette.Text.low)
                    )
                    .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                    .frame(width: VoiceOourMetrics.Column.glossaryAliases)
                    .onSubmit(submit)
                }
            }

            if !mishearingCandidates.isEmpty {
                VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                    Text("DETECTED AS IN RAW")
                        .roleStyle(.micro)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VoiceOourMetrics.Space.xs) {
                            ForEach(mishearingCandidates, id: \.self) { candidate in
                                Button(candidate) { misheard = candidate }
                                    .buttonStyle(GlassButtonStyle(kind: .ghost))
                            }
                        }
                    }
                }
            }

            SegmentGroup {
                scopeOption("GLOBAL", .global)
                if appBundleId != nil {
                    scopeOption("THIS APP", .app)
                }
                if projectId != nil {
                    scopeOption(coordinator.activeProjectName.map { "PROJECT · \($0)" } ?? "THIS PROJECT", .project)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: VoiceOourMetrics.Space.sm) {
                Button("TEACH") { submit() }
                    .buttonStyle(GlassButtonStyle(kind: .accent))
                    .disabled(!canSubmit)
                Button("CANCEL") { cancel() }
                    .buttonStyle(GlassButtonStyle(kind: .ghost))
            }

            CaptionText(
                "Teaches future dictation only — this never edits text already pasted. Case and spacing variants are matched automatically; add a detected surface only when dictation heard the term differently."
            )
        }
        .padding(VoiceOourMetrics.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plateSurface(kind: .well, cornerRadius: sessionWellRadius)
    }

    private func scopeOption(_ label: String, _ value: Scope) -> some View {
        SegmentOption(label: label, isSelected: scope == value) { scope = value }
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

struct PendingSuggestionsCard: View {
    var coordinator: DictationCoordinator
    @State private var dismissedIDs: Set<String> = []

    private var visible: [TermSuggestion] {
        coordinator.pendingSuggestions.filter { !dismissedIDs.contains($0.id) }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
                HStack(spacing: VoiceOourMetrics.Space.sm) {
                    Text("SUGGESTED CORRECTIONS")
                        .roleStyle(.eyebrow)
                    StatusChip(label: "TEXT KEPT", mode: .neutral)
                }

                CaptionText(
                    "From your last dictation. Accept teaches future dictation only — the text you already pasted is never changed."
                )

                ForEach(visible) { suggestion in
                    PendingSuggestionRow(
                        suggestion: suggestion,
                        keep: { dismissedIDs.insert(suggestion.id) },
                        accept: { coordinator.acceptSuggestion(id: suggestion.id) },
                        reject: { coordinator.rejectSuggestion(id: suggestion.id) }
                    )
                }
            }
            .padding(VoiceOourMetrics.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plateSurface(kind: .well, cornerRadius: sessionWellRadius)
        }
    }
}

private struct PendingSuggestionRow: View {
    var suggestion: TermSuggestion
    var keep: () -> Void
    var accept: () -> Void
    var reject: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: VoiceOourMetrics.Space.md) {
            HStack(spacing: VoiceOourMetrics.Space.xs) {
                Text(suggestion.misheard)
                    .font(VoiceOourTypography.bodyMono)
                    .foregroundStyle(VoiceOourPalette.Text.mid)
                Image(systemName: "arrow.right")
                    .font(.system(size: VoiceOourMetrics.Icon.mark, weight: .semibold))
                    .foregroundStyle(VoiceOourPalette.Mark.faint)
                    .accessibilityHidden(true)
                Text(suggestion.canonical)
                    .font(VoiceOourTypography.bodyMono)
                    .foregroundStyle(VoiceOourPalette.Text.monoStrong)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Suggested correction: \(suggestion.misheard) becomes \(suggestion.canonical)")

            Spacer(minLength: VoiceOourMetrics.Space.sm)

            HStack(spacing: VoiceOourMetrics.Space.sm) {
                Button("KEEP", action: keep)
                    .buttonStyle(GlassButtonStyle(kind: .ghost))
                    .help("Keep the pasted text and hide this suggestion. Nothing is taught.")
                    .accessibilityLabel("Keep pasted text for \(suggestion.misheard)")
                    .accessibilityIdentifier("suggestion.\(suggestion.id).keep")
                Button("ACCEPT", action: accept)
                    .buttonStyle(GlassButtonStyle(kind: .accent))
                    .help(
                        "Teach VoiceOour to use \"\(suggestion.canonical)\" next time. Your pasted text is unchanged."
                    )
                    .accessibilityLabel("Accept correction from \(suggestion.misheard) to \(suggestion.canonical)")
                    .accessibilityIdentifier("suggestion.\(suggestion.id).accept")
                Button("REJECT", action: reject)
                    .buttonStyle(GlassButtonStyle(kind: .danger))
                    .help("Don't suggest this correction again.")
                    .accessibilityLabel("Reject correction from \(suggestion.misheard) to \(suggestion.canonical)")
                    .accessibilityIdentifier("suggestion.\(suggestion.id).reject")
            }
        }
        .padding(.horizontal, VoiceOourMetrics.Space.md)
        .padding(.vertical, VoiceOourMetrics.Space.sm)
        .plateSurface(kind: .row, cornerRadius: VoiceOourMetrics.Radius.row)
    }
}
