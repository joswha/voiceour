import SwiftUI

/// One designator -> control row on the console's shared grid: a fixed
/// label column, then content flush against the same left edge on every
/// pane. The enclosing `SettingsSectionBlock` rules between row bounds;
/// the row itself owns only its total pitch, so no divider changes layout.
/// That pitch is symmetric padding, which is right between two rows and is
/// dead space against the card's own padding — the row declares it as its
/// `settingsContentLead` and the section trims it at both card edges.
/// Content never claims more width than `SettingsPaneScroll`'s column, so
/// a lone toggle or a four-digit field stays anchored near its label
/// instead of drifting to the far edge of the window.
///
/// Two slots exist so panes stop hand-rolling the same composition. `status`
/// is a compact mark that closes the control line on the trailing rail, and
/// `statusAction` optionally turns that mark into a compact, keyboard-accessible
/// control when the status itself is the requested remediation. `footer`
/// is whatever explains the row, rendered at the **value-column origin** under
/// the control band. Before the footer slot, a caption written inside `content`
/// after a chip started wherever the chip happened to end and wrapped against a
/// ragged left edge; now every explanatory line in the app starts on the same
/// seam as the control it explains.
///
/// A footer holds `CaptionText` and static marks only — never a control. A
/// control below the band is a second row pretending to be one row, and the
/// section's divider would draw through the middle of it.
struct SettingsRow<Content: View, Footer: View>: View {
    var label: String
    var status: (label: String, mode: StatusChip.Mode)?
    var statusAction: (() -> Void)?
    var statusActionAccessibilityLabel: String?
    var statusActionAccessibilityIdentifier: String?
    let content: Content
    let footer: Footer

    init(
        label: String,
        status: (label: String, mode: StatusChip.Mode)? = nil,
        statusAction: (() -> Void)? = nil,
        statusActionAccessibilityLabel: String? = nil,
        statusActionAccessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.label = label
        self.status = status
        self.statusAction = statusAction
        self.statusActionAccessibilityLabel = statusActionAccessibilityLabel
        self.statusActionAccessibilityIdentifier = statusActionAccessibilityIdentifier
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        HStack(alignment: .top, spacing: VoiceOourMetrics.Space.xl) {
            Text(label)
                .font(VoiceOourTypography.label)
                .foregroundStyle(VoiceOourPalette.Text.high)
                .recordTextRole(.label, foreground: VoiceOourPalette.Text.high)
                .frame(width: VoiceOourMetrics.Column.settingsLabel, alignment: .leading)

            // The footer is a sibling of the control band, not a padded box
            // around it: `VStack` spacing is measured between flattened leaf
            // subviews, so a footer whose conditionals all resolve false costs
            // zero height AND zero gap, and a row with nothing to explain
            // keeps its exact 44pt pitch.
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                HStack(alignment: .center, spacing: VoiceOourMetrics.Space.sm) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let status {
                        if let statusAction {
                            SettingsStatusButton(
                                label: status.label,
                                mode: status.mode,
                                accessibilityLabel: statusActionAccessibilityLabel ?? status.label,
                                accessibilityIdentifier: statusActionAccessibilityIdentifier,
                                perform: statusAction
                            )
                        } else {
                            StatusChip(label: status.label, mode: status.mode, size: .compact)
                        }
                    }
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, VoiceOourMetrics.Space.sm)
        .frame(
            maxWidth: .infinity,
            minHeight: VoiceOourMetrics.Row.settings,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .anchorPreference(key: SettingsRowBoundsPreferenceKey.self, value: .bounds) { [$0] }
        .settingsContentLead(VoiceOourMetrics.Space.sm)
    }
}

/// A status mark that is also the remediation for the row. The warning fill
/// stays intact so the state remains legible, while the quiet rim and hover
/// response make the existing mark discoverable as a control.
private struct SettingsStatusButton: View {
    let label: String
    let mode: StatusChip.Mode
    let accessibilityLabel: String
    let accessibilityIdentifier: String?
    let perform: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    private var a11y = A11y()

    init(
        label: String,
        mode: StatusChip.Mode,
        accessibilityLabel: String,
        accessibilityIdentifier: String?,
        perform: @escaping () -> Void
    ) {
        self.label = label
        self.mode = mode
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.perform = perform
    }

    var body: some View {
        Button(action: perform) {
            StatusChip(label: label, mode: mode, size: .compact)
        }
        .buttonStyle(.plain)
        .padding(.vertical, VoiceOourMetrics.Space.xs)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: VoiceOourMetrics.Radius.chip, style: .continuous)
                .strokeBorder(
                    stroke,
                    lineWidth: VoiceOourMetrics.Stroke.hairline(a11y.contrast)
                )
                .padding(.vertical, VoiceOourMetrics.Space.xs)
                .allowsHitTesting(false)
        }
        .focusEffectDisabled()
        .onHover { hovering in
            if a11y.reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(VoiceOourMotion.quick) {
                    isHovered = hovering
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? label)
    }

    private var stroke: Color {
        guard isEnabled else { return a11y.lineRule }
        return isHovered ? VoiceOourPalette.Line.controlHover : a11y.lineControl
    }
}

extension SettingsRow where Footer == EmptyView {
    /// The original two-argument shape, unchanged for every caller that has
    /// nothing to say under its control.
    init(
        label: String,
        status: (label: String, mode: StatusChip.Mode)? = nil,
        statusAction: (() -> Void)? = nil,
        statusActionAccessibilityLabel: String? = nil,
        statusActionAccessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            label: label,
            status: status,
            statusAction: statusAction,
            statusActionAccessibilityLabel: statusActionAccessibilityLabel,
            statusActionAccessibilityIdentifier: statusActionAccessibilityIdentifier,
            content: content,
            footer: { EmptyView() }
        )
    }
}

extension SettingsRow where Footer == CaptionText? {
    /// One caption, which is what most rows want. `caption` carries no default
    /// on purpose: a defaulted one would make this overload ambiguous with the
    /// footer-less initializer above at every existing call site.
    init(
        label: String,
        caption: String?,
        captionColor: Color? = nil,
        status: (label: String, mode: StatusChip.Mode)? = nil,
        statusAction: (() -> Void)? = nil,
        statusActionAccessibilityLabel: String? = nil,
        statusActionAccessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            label: label,
            status: status,
            statusAction: statusAction,
            statusActionAccessibilityLabel: statusActionAccessibilityLabel,
            statusActionAccessibilityIdentifier: statusActionAccessibilityIdentifier,
            content: content,
            footer: { caption.map { CaptionText($0, color: captionColor) } }
        )
    }
}

/// Internal rather than file-private: `PropertyRow`'s ledger rows publish the
/// same anchors, so a section can stack both row families and
/// `SettingsSectionBlock` still rules between every pair of them.
struct SettingsRowBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct SettingsRowRules: View {
    let rowBounds: [Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ForEach(rowBounds.indices.dropLast(), id: \.self) { index in
                let row = proxy[rowBounds[index]]
                HairlineDivider()
                    .frame(width: row.width, height: row.height, alignment: .bottom)
                    .offset(x: row.minX, y: row.minY)
            }
        }
        .allowsHitTesting(false)
    }
}
