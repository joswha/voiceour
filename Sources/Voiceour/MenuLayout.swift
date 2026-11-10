import SwiftUI

enum MenuLayout {
    /// A named measure rather than a multiple of the spacing scale: nothing
    /// about this popover follows from a count of section gaps, and tuning the
    /// scale must not silently resize the menu bar.
    static let popoverWidth: CGFloat = 280

    /// The radius of the two bounded objects inside the popover, the transcript
    /// well and the command container: the console's well radius, so a well
    /// reads the same in the menu as on a Journal page.
    static let innerRadius: CGFloat = 10

    static var innerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
    }

    /// Where a command row's title starts: 12 pt padding, the 16 pt icon tile and
    /// an 8 pt gap. The rule between rows starts here, under the title rather than
    /// under the glyph, so the glyph column reads as one column.
    static let commandTitleInset: CGFloat =
        VoiceourMetrics.Space.md + Kit.Metrics.iconTileMini + VoiceourMetrics.Space.sm
}
