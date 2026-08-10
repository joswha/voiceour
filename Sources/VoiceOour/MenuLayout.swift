import SwiftUI

enum MenuLayout {
    /// A named measure rather than `Space.section * 7`: nothing about this
    /// popover follows from seven section gaps, and tuning the spacing scale
    /// must not silently resize the menu bar. Belongs beside `Content.form` /
    /// `Content.table` once `DesignTokens` is in scope for this change.
    static let popoverWidth: CGFloat = 280

    /// Everything full-bleed inside the popover's `Space.md` padding derives its
    /// radius concentrically: 16 − 12 = 4. Row-radius children inside a
    /// window-radius container bulge 1.65 pt wider at the corners than along the
    /// straight edges.
    static let innerRadius = VoiceOourMetrics.Radius.nested(
        VoiceOourMetrics.Radius.window,
        inset: VoiceOourMetrics.Space.md
    )

    static var popoverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VoiceOourMetrics.Radius.window, style: .continuous)
    }

    static var innerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
    }
}
