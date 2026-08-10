import SwiftUI

/// Secondary description line under a control (a field hint, a toggle's
/// explanation). Every settings pane now sits on a bounded column instead
/// of the full window, so a caption's natural single-line width routinely
/// exceeds the space it is given — a bare `Text` clips to one line with an
/// ellipsis instead of wrapping unless told explicitly to grow vertically.
struct CaptionText: View {
    var text: String
    var color: Color?
    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(VoiceOourTypography.caption)
            .foregroundStyle(foreground)
            .recordTextRole(.caption, foreground: foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A disabled caption drops its semantic override. The override exists to
    /// say "this is an error, this is advice"; a switched-off block has no
    /// live advice to give, and a crimson sentence inside a receded group
    /// would be the loudest thing on a surface the user just turned off.
    /// The whole group recedes together, in the primitive, once.
    private var foreground: Color {
        isEnabled ? (color ?? a11y.textLow) : a11y.textLow
    }
}
