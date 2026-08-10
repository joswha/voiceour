import SwiftUI

/// The mute-scope either/or. `SegmentGroup` owns the rim, the `Space.xs` inset
/// and the radius-8 container shape its segments derive radius 4 from, so the
/// two segments no longer sit on a third plate of their own with two identical
/// hairlines 4pt apart.
struct ScopePicker: View {
    var isBuiltInSelected: Bool
    var selectBuiltIn: () -> Void
    var selectAll: () -> Void

    var body: some View {
        SegmentGroup {
            SegmentOption(label: "BUILT-IN OUTPUT ONLY", isSelected: isBuiltInSelected, action: selectBuiltIn)
            SegmentOption(label: "ALL OUTPUTS", isSelected: !isBuiltInSelected, action: selectAll)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mute scope")
    }
}
