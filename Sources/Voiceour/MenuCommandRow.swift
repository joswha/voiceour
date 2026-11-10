import SwiftUI

/// One command in the popover's action container.
///
/// Rest carries no fill and no rim: the container owns the single boundary, and
/// a permanent rim per row is the noise this structure exists to remove. The row
/// is `Control.medium` tall and opens with the command's glyph on a mini
/// ``Kit/Badge`` disc, Home's green signal. Its label is the `label` role, 13 pt
/// SF Pro in sentence case — these are menu rows, not status chips — and its
/// trailing slot always carries something, so the plate's width means "this row
/// has a right-hand payload" instead of committing 40–85 % of its area to
/// nothing.
struct MenuCommandRow: View {
    enum Accessory {
        case none
        case chevron
        case keys(String)
    }

    let title: String
    /// The SF Symbol the leading badge draws.
    let systemImage: String
    var accessory: Accessory = .none
    /// A row that is followed by another closes itself with an inset rule drawn
    /// as an overlay, so the rule costs no layout height and the row pitch stays
    /// exactly `Control.medium`. The last row in the container closes nothing.
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
            Kit.Badge(systemImage: systemImage, size: .mini)

            // One modifier for role and state colour: a colour applied after the
            // role would be shadowed by the role's own.
            configuration.label
                .roleStyle(.label, color: foreground)
                .lineLimit(1)

            Spacer(minLength: VoiceourMetrics.Space.sm)

            accessoryView
        }
        .padding(.horizontal, VoiceourMetrics.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VoiceourMetrics.Control.medium)
        // Square, not rounded: the container's clip supplies the two outer
        // corners and a middle row has none. A full-bleed row inside a clip
        // also cannot take the shared pressed `scaleEffect` without exposing
        // the container edge, so pressed is carried by the fill alone.
        .background(Rectangle().fill(fill))
        // The wash sits under the title, so the contrast lint measures the
        // title against it.
        .environment(\.surfaceGround, inheritedGround.painting(fill))
        .overlay {
            if state == .focused {
                RoundedRectangle(
                    cornerRadius: VoiceourMetrics.Radius.keycap,
                    style: .continuous
                )
                .strokeBorder(
                    VoiceourPalette.Line.focus,
                    lineWidth: VoiceourMetrics.Stroke.selected(a11y.contrast)
                )
                .padding(VoiceourMetrics.Space.hair)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if closingRule {
                HairlineDivider()
                    .padding(.horizontal, VoiceourMetrics.Space.md)
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
                .foregroundStyle(VoiceourPalette.Text.low)
                .accessibilityHidden(true)
        case .keys(let equivalent):
            KeyCap(equivalent)
                .accessibilityHidden(true)
        }
    }

    private var fill: Color {
        switch state {
        case .pressed:
            VoiceourPalette.Plate.pressed
        case .hover, .focused, .selected:
            VoiceourPalette.Plate.hover
        case .rest, .disabled, .inFlight:
            Color.clear
        }
    }

    private var foreground: Color {
        switch state {
        case .disabled:
            a11y.textLow
        case .rest, .inFlight:
            a11y.textMid
        case .hover, .pressed, .focused, .selected:
            VoiceourPalette.Text.high
        }
    }
}
