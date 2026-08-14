import SwiftUI

/// The ledger's last row: an inline composer on the same grid as the rows above
/// it, so adding an entry is filling in the next line rather than working a form
/// bolted underneath. Its submit is a row action, so it closes on the trailing
/// edge every row action closes on instead of floating in a data column.
struct GlossaryAddRow: View {
    @Binding var newTerm: String
    @Binding var newAliases: String
    var showsPolicy: Bool
    var canAdd: Bool
    var addTerm: () -> Void

    var body: some View {
        HStack(spacing: GlossaryColumn.gutter) {
            TextField("Canonical term", text: $newTerm)
                .textFieldStyle(GlassTextFieldStyle(font: VoiceourTypography.bodyMono))
                .frame(width: GlossaryColumn.canonical)
                .autocorrectionDisabled(true)
                .onSubmit(addTerm)

            TextField("Detected as (comma-separated)", text: $newAliases)
                .textFieldStyle(GlassTextFieldStyle(font: VoiceourTypography.bodyMono))
                .frame(width: GlossaryColumn.aliases)
                .autocorrectionDisabled(true)
                .onSubmit(addTerm)

            if showsPolicy {
                Color.clear.frame(width: GlossaryColumn.policy)
            }

            Button(action: addTerm) {
                Label("ADD TERM", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(GlassButtonStyle(kind: .accent))
            .disabled(!canAdd)
            .frame(width: GlossaryColumn.actionSpan(policy: showsPolicy), alignment: .trailing)
        }
        .glossaryBand()
    }
}
