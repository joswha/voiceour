import SwiftUI

/// One command in the popover's action container.
///
/// Rest carries no fill and no rim: the container owns the single boundary, and
/// a permanent rim per row is the noise this structure exists to remove. The row
/// is `Control.medium` tall, its label is `label` 13 pt SF Pro in sentence case —
/// these are menu rows, not status chips — and its trailing slot always carries
/// something, so the plate's width means "this row has a right-hand payload"
/// instead of committing 40–85 % of its area to nothing.
struct MenuCommandRow: View {
    enum Accessory {
        case none
        case chevron
        case keys(String)
    }

    let title: String
    var accessory: Accessory = .none
    /// A row that is followed by another closes itself with an inset rule drawn
    /// as an overlay, so the rule costs no layout height and the row pitch stays
    /// exactly `Control.medium`. The last row in the container closes nothing.
    var closingRule: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VoiceOourMetrics.Space.sm) {
                Text(title)
                    .font(VoiceOourTypography.label)
                    .lineLimit(1)

                Spacer(minLength: VoiceOourMetrics.Space.sm)

                accessoryView
            }
        }
        .buttonStyle(MenuCommandButtonStyle(closingRule: closingRule))
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: VoiceOourMetrics.Icon.mark, weight: .semibold))
                .foregroundStyle(VoiceOourPalette.Text.low)
                .accessibilityHidden(true)
        case .keys(let equivalent):
            KeyCap(equivalent)
                .accessibilityHidden(true)
        }
    }
}

private struct MenuCommandButtonStyle: ButtonStyle {
    let closingRule: Bool

    func makeBody(configuration: Configuration) -> some View {
        MenuCommandBody(configuration: configuration, closingRule: closingRule)
    }
}

private struct MenuCommandBody: View {
    let configuration: ButtonStyle.Configuration
    let closingRule: Bool

    init(configuration: ButtonStyle.Configuration, closingRule: Bool) {
        self.configuration = configuration
        self.closingRule = closingRule
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
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
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, VoiceOourMetrics.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: VoiceOourMetrics.Control.medium)
            // Square, not rounded: the container's clip supplies the two outer
            // corners and a middle row has none. A full-bleed row inside a clip
            // also cannot take the shared pressed `scaleEffect` without exposing
            // the container edge, so pressed is carried by the fill alone.
            .background(Rectangle().fill(fill))
            .overlay {
                if state == .focused {
                    RoundedRectangle(
                        cornerRadius: VoiceOourMetrics.Radius.keycap,
                        style: .continuous
                    )
                    .strokeBorder(
                        VoiceOourPalette.Line.focus,
                        lineWidth: VoiceOourMetrics.Stroke.selected(a11y.contrast)
                    )
                    .padding(VoiceOourMetrics.Space.hair)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if closingRule {
                    HairlineDivider()
                        .padding(.horizontal, VoiceOourMetrics.Space.md)
                }
            }
            .contentShape(Rectangle())
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        switch state {
        case .pressed:
            VoiceOourPalette.Plate.pressed
        case .hover, .focused, .selected:
            VoiceOourPalette.Plate.hover
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
            VoiceOourPalette.Text.high
        }
    }
}
