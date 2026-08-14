import SwiftUI

/// The ledger grid. Four columns are fixed and SCOPE is the single flexible
/// one, so the trailing action column lands on the same x in the header, in
/// every term row and in the composer regardless of what a row contains — the
/// whole reason a table has an action column. Both cases close exactly on the
/// card's inner measure (§2.6 C12):
///
///     5 columns  916 = 176 + 320 + 64 + 276 + 32 + 4 × 12
///     4 columns  916 = 176 + 320 +      352 + 32 + 3 × 12   (POLICY suppressed)
enum GlossaryColumn {
    static let canonical = VoiceourMetrics.Column.glossaryCanonical
    static let aliases = VoiceourMetrics.Column.glossaryAliases
    static let policy = VoiceourMetrics.Column.glossaryPolicy
    static let action = VoiceourMetrics.Column.rowAction
    static let gutter = VoiceourMetrics.Space.md

    /// The content surface's own measure less its padding. Every band in the
    /// ledger is exactly this wide, so a rule terminates where its row does.
    static let inner = VoiceourMetrics.Content.table - VoiceourMetrics.Space.md * 2

    /// One inset per column, carried by every occupant of that column — the
    /// header cell, the inline value and the editable cell's own plate.
    static let textInset = VoiceourMetrics.Space.xs

    /// SCOPE absorbs the remainder. No `Spacer`: a flexible spacer would let a
    /// row's own content move the action column again, which is the defect.
    static func scope(policy showsPolicy: Bool) -> CGFloat {
        let fixed = canonical + aliases + action + (showsPolicy ? policy : 0)
        let gutters = gutter * (showsPolicy ? 4 : 3)
        return max(inner - fixed - gutters, VoiceourMetrics.Column.glossaryScopeMin)
    }

    /// SCOPE + gutter + action: the composer's submit is a row action, so it
    /// closes on the same trailing edge every row action closes on.
    static func actionSpan(policy showsPolicy: Bool) -> CGFloat {
        scope(policy: showsPolicy) + gutter + action
    }
}

/// Every band in the ledger — column header, term row, composer, empty state —
/// is laid out on one measure at a pitch from the `Row` scale and closes itself
/// with a rule drawn as an **overlay**, so the rule costs no layout height and
/// every rule origin stays on a whole device pixel (§2.4 C10/C11).
private struct GlossaryBand: ViewModifier {
    var height: CGFloat
    var alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(width: GlossaryColumn.inner, height: height, alignment: alignment)
            .overlay(alignment: .bottom) { HairlineDivider() }
    }
}

extension View {
    func glossaryBand(
        height: CGFloat = VoiceourMetrics.Row.table,
        alignment: Alignment = .leading
    ) -> some View {
        modifier(GlossaryBand(height: height, alignment: alignment))
    }

    func glossaryCell(width: CGFloat, alignment: Alignment = .leading) -> some View {
        padding(.leading, GlossaryColumn.textInset)
            .frame(width: width, alignment: alignment)
    }
}
