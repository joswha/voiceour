import SwiftUI

/// One command in the popover's action container.
///
/// Rest carries no fill and no rim: the container owns the single boundary, and
/// a permanent plate per row is the noise this structure exists to remove. The
/// row is one row pitch (32 pt) tall and opens with the command's glyph on a mini
/// ``Kit/IconTile``; its title is the `body` role in sentence case — these are
/// menu rows, not status pills.
struct MenuCommandRow: View {
    enum Accessory {
        case none
        /// The command leaves the popover (System Settings, the console).
        case chevron
        /// The command's key equivalent.
        case keys(String)
    }

    let title: String
    /// The SF Symbol the leading tile draws.
    let systemImage: String
    var accessory: Accessory = .none
    /// A row that is followed by another closes itself with a rule drawn as an
    /// overlay, so the rule costs no layout height and the row pitch stays
    /// exactly 32 pt. The last row in the container closes nothing.
    var closingRule: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(
            MenuCommandButtonStyle(
                systemImage: systemImage,
                accessory: accessory,
                closingRule: closingRule
            )
        )
        .accessibilityLabel(title)
    }
}

/// Lays the row out around the title the button supplies, so the title's colour
/// can follow the interaction state through its text role.
private struct MenuCommandButtonStyle: ButtonStyle {
    let systemImage: String
    let accessory: MenuCommandRow.Accessory
    let closingRule: Bool

    func makeBody(configuration: Configuration) -> some View {
        MenuCommandBody(
            configuration: configuration,
            systemImage: systemImage,
            accessory: accessory,
            closingRule: closingRule
        )
    }
}

private struct MenuCommandBody: View {
    let configuration: ButtonStyle.Configuration
    let systemImage: String
    let accessory: MenuCommandRow.Accessory
    let closingRule: Bool

    init(
        configuration: ButtonStyle.Configuration,
        systemImage: String,
        accessory: MenuCommandRow.Accessory,
        closingRule: Bool
    ) {
        self.configuration = configuration
        self.systemImage = systemImage
        self.accessory = accessory
        self.closingRule = closingRule
    }

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.surfaceGround) private var inheritedGround
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            isEnabled: isEnabled,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering
        )
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Kit.IconTile(systemImage: systemImage, size: .mini)

            // One modifier for role and state colour: a colour applied after the
            // role would be shadowed by the role's own.
            configuration.label
                .roleStyle(.body, color: isEnabled ? theme.text1 : theme.textDisabled)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: VoiceourMetrics.Space.sm)

            accessoryView
        }
        .padding(.horizontal, VoiceourMetrics.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Kit.Metrics.rowHeightOne)
        // Square, not rounded: the container's clip supplies the two outer
        // corners and a middle row has none. Pressed is carried by the fill
        // alone, since a scaled full-bleed row would expose the container edge.
        .background(Rectangle().fill(fill))
        // The wash sits under the title, so the contrast lint measures the title
        // against it.
        .environment(\.surfaceGround, inheritedGround.painting(fill))
        .overlay {
            // Inside the row, because the container clips anything outset; dropped
            // while pressed so focus and press never read as one state.
            if state == .focused {
                RoundedRectangle(cornerRadius: Kit.Metrics.controlRadius, style: .continuous)
                    .strokeBorder(theme.focusRing, lineWidth: 2)
                    .padding(VoiceourMetrics.Space.hair)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if closingRule {
                Kit.Rule()
                    .padding(.leading, MenuLayout.commandTitleInset)
            }
        }
        .contentShape(Rectangle())
        .focusEffectDisabled()
        .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                .foregroundStyle(theme.text3)
                .accessibilityHidden(true)
        case .keys(let equivalent):
            Kit.KeyCap(equivalent)
                .accessibilityHidden(true)
        }
    }

    /// Opaque, so the rule and the title are measured against what is painted.
    /// Rest is the container's own `raised`, which `inheritedGround` already holds.
    private var fill: Color {
        switch state {
        case .pressed: theme.pressed
        case .hover, .focused, .selected: theme.hover
        case .rest, .disabled, .inFlight: theme.raised
        }
    }
}
