import SwiftUI

/// The popover's primary action: a full-width 32 pt capsule in the theme's accent,
/// the same fill, label colour and state ladder as `Kit.Button(.primary)` in the
/// capsule shape the popover's one floating action has always worn.
///
/// Painted rather than `.glassProminent`: the system prominent style paints the
/// Mac's accent instead of the one the reader chose in Settings, and the offscreen
/// harness cannot rasterise glass, so the capsule would vanish from every golden.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionBody(configuration: configuration)
    }
}

private struct PrimaryActionBody: View {
    let configuration: ButtonStyle.Configuration

    init(configuration: ButtonStyle.Configuration) {
        self.configuration = configuration
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

    /// `onAccent` is verified against all three accent steps, so the label keeps
    /// its contrast through hover and press.
    private var fill: Color {
        switch state {
        case .disabled: theme.hover
        case .pressed: theme.accentPressed
        case .hover, .focused, .selected: theme.accentHover
        case .rest, .inFlight: theme.accent
        }
    }

    private var foreground: Color {
        state == .disabled ? theme.textDisabled : theme.onAccent
    }

    var body: some View {
        configuration.label
            .roleStyle(.rowTitle, color: foreground)
            .lineLimit(1)
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .frame(height: Kit.Metrics.rowHeightOne)
            .background(Capsule(style: .continuous).fill(fill))
            .environment(\.surfaceGround, inheritedGround.painting(fill))
            .overlay {
                // A 2 pt ring outset by 1 pt, so it reads against both the fill and
                // the popover ground; dropped while pressed so focus and press never
                // read as one state.
                if state == .focused {
                    Capsule(style: .continuous)
                        .strokeBorder(theme.focusRing, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }
}
