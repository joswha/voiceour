import Foundation
import SwiftUI
import VoiceCore

func parsedGlossaryAliases(_ text: String) -> [String] {
    var seen: Set<String> = []
    return
        text
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { alias in
            guard !alias.isEmpty else { return false }
            return seen.insert(alias.lowercased()).inserted
        }
}

/// One glossary entry on the shared grid. POLICY collapses while every term
/// shares one policy, and the lock disappears while every term is protected, so
/// either one that remains can tell rows apart. SCOPE paints only for a
/// non-global term, while its frame remains present to hold the action column.
struct GlossaryTermRow: View {
    var term: ProtectedTerm
    var showsPolicy: Bool
    var showsProtected: Bool
    var updateAliases: ([String]) -> Void
    var remove: () -> Void

    @State private var aliasText: String
    @FocusState private var aliasFieldFocused: Bool
    @State private var isHoveringAlias = false
    @State private var isHoveringRow = false
    private var a11y = A11y()

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
        HStack(spacing: GlossaryColumn.gutter) {
            canonicalCell
            aliasCell
            if showsPolicy {
                Text(term.casePolicy.rawValue.uppercased())
                    .font(VoiceOourTypography.bodyMono)
                    .foregroundStyle(a11y.textMid)
                    .glossaryCell(width: GlossaryColumn.policy)
            }
            scopeCell
            RowIconButton(
                systemName: "xmark",
                kind: .danger,
                accessibilityLabel: "Remove \(term.canonical)",
                accessibilityIdentifier: "remove.\(term.termId)",
                action: remove
            )
        }
        .glossaryBand()
        .background {
            Rectangle()
                .fill(isHoveringRow ? VoiceOourPalette.Plate.hover : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { isHoveringRow = $0 }
        .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: isHoveringRow)
    }

    private var canonicalCell: some View {
        HStack(spacing: VoiceOourMetrics.Space.xs) {
            Text(term.canonical)
                .font(VoiceOourTypography.bodyMono)
                .foregroundStyle(VoiceOourPalette.Text.monoStrong)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(term.canonical)
            if showsProtected && term.protected {
                Image(systemName: "lock.fill")
                    .font(VoiceOourTypography.micro)
                    .foregroundStyle(a11y.textLow)
                    .help("Protected — never rewritten by the refiner")
                    .accessibilityLabel("Protected term \(term.canonical)")
                    .accessibilityIdentifier("protected.\(term.termId)")
            }
        }
        .glossaryCell(width: GlossaryColumn.canonical)
    }

    private var aliasCell: some View {
        TextField("No alternate detections", text: $aliasText)
            .font(VoiceOourTypography.bodyMono)
            .textFieldStyle(.plain)
            .foregroundStyle(VoiceOourPalette.Text.mono)
            .autocorrectionDisabled(true)
            .padding(.horizontal, GlossaryColumn.textInset)
            .frame(
                width: GlossaryColumn.aliases,
                height: VoiceOourMetrics.Control.medium,
                alignment: .leading
            )
            .background {
                RoundedRectangle(cornerRadius: aliasRadius, style: .continuous)
                    .fill(aliasFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: aliasRadius, style: .continuous)
                    .strokeBorder(
                        aliasFieldFocused ? VoiceOourPalette.Line.focus : Color.clear,
                        lineWidth: VoiceOourMetrics.Stroke.selected(a11y.contrast)
                    )
            }
            .focused($aliasFieldFocused)
            .onHover { isHoveringAlias = $0 }
            .help(
                aliasText.isEmpty
                    ? "No alternate speech-to-text detections for \(term.canonical)"
                    : "Speech-to-text detected \(term.canonical) as \(aliasText)"
            )
            .accessibilityLabel("Speech-to-text detections for \(term.canonical)")
            .accessibilityIdentifier("aliases.\(term.termId)")
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: aliasFieldFocused)
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: isHoveringAlias)
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
                    commitAliases()
                }
            }
            .onChange(of: Glossary.userAliases(for: term)) { _, aliases in
                if !aliasFieldFocused {
                    aliasText = aliases.joined(separator: ", ")
                }
            }
    }

    /// The flexible column. It claims its width from an always-present base so
    /// an unbadged row cannot collapse it and walk the action column left.
    private var scopeCell: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let scopeLabel {
                StatusChip(label: scopeLabel, mode: .neutral, size: .compact)
            }
        }
        .glossaryCell(width: GlossaryColumn.scope(policy: showsPolicy))
    }

    private var aliasRadius: CGFloat {
        VoiceOourMetrics.Radius.nested(
            VoiceOourMetrics.Radius.card,
            inset: VoiceOourMetrics.Space.md
        )
    }

    private var aliasFill: Color {
        if aliasFieldFocused {
            return VoiceOourPalette.Plate.rest
        }
        return isHoveringAlias ? VoiceOourPalette.Plate.hover : Color.clear
    }

    /// A global term needs no scope badge because it is available everywhere.
    private var scopeLabel: String? {
        guard term.scope != .global else { return nil }
        return term.scope.displayLabel
    }

    private func commitAliases() {
        let aliases = parsedGlossaryAliases(aliasText)
        aliasText = aliases.joined(separator: ", ")
        guard aliases != Glossary.userAliases(for: term) else { return }
        updateAliases(aliases)
    }
}
