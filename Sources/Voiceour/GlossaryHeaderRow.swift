import SwiftUI

struct GlossaryHeaderRow: View {
    var showsPolicy: Bool
    var showsScope: Bool

    var body: some View {
        HStack(spacing: GlossaryColumn.gutter) {
            HeaderCell("CANONICAL", width: GlossaryColumn.canonical)
            HeaderCell("DETECTED AS", width: GlossaryColumn.aliases)
            if showsPolicy {
                HeaderCell("POLICY", width: GlossaryColumn.policy)
            }
            // The frame survives the label: dropping the child entirely would
            // walk the action column left, which is the defect the fixed
            // `scope(policy:)` measure exists to prevent.
            if showsScope {
                HeaderCell("SCOPE", width: GlossaryColumn.scope(policy: showsPolicy))
            } else {
                Color.clear.frame(width: GlossaryColumn.scope(policy: showsPolicy))
            }
            Color.clear.frame(width: GlossaryColumn.action)
        }
        .glossaryBand()
    }
}

private struct HeaderCell: View {
    var label: String
    var width: CGFloat
    private var a11y = A11y()

    init(_ label: String, width: CGFloat) {
        self.label = label
        self.width = width
    }

    var body: some View {
        Text(label)
            .font(VoiceourTypography.micro)
            .foregroundStyle(a11y.textLow)
            .glossaryCell(width: width)
    }
}
