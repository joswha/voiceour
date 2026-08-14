import SwiftUI

// MARK: - DependentGroup

/// A block of sections that only mean anything while one upstream switch is
/// on.
///
/// Surface-free by design. Wrapping dependent rows in their own card or plate
/// would say "this is a different kind of thing", when the only thing that
/// changed is whether it currently applies — and it would nest a content
/// surface inside a pane that has exactly one surface layer. The recession is
/// carried by the primitives instead: `StatusChip`, `CaptionText`,
/// `PropertyRow` and the shared control ladder all read `isEnabled`, so no
/// call site paints a disabled tone and no two of them can disagree about it.
///
/// One contained accessibility region, so VoiceOver announces the group's
/// active/inactive state once rather than having every child row re-report it.
struct DependentGroup<Content: View>: View {
    var isEnabled: Bool
    var label: String
    let content: Content

    init(isEnabled: Bool, label: String, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.label = label
        self.content = content()
    }

    var body: some View {
        // `Space.lg` is `SettingsPaneScroll`'s own inter-surface step, so a
        // group of sections stacks identically to the ungrouped sections
        // above and below it. The group is invisible to layout.
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(isEnabled ? "Active" : "Inactive")
    }
}
