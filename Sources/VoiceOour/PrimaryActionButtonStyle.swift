import SwiftUI

/// The popover's primary action. It is a painted capsule on every OS path:
/// `MenuView` sits inside the popover's glass chrome on macOS 26, so applying
/// `.glassProminent` here would create an independently composited glass
/// material on glass and can erase the capsule while inflating its hit frame.
/// Large controls keep the capsule geometry used for spacious emphasis.
struct PrimaryActionButtonStyle: PrimitiveButtonStyle {
    var isInFlight: Bool = false
    var harnessState: ControlState? = nil

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let effectiveInFlight = isInFlight || harnessState == .inFlight

        paintedBody(configuration: configuration, effectiveInFlight: effectiveInFlight)
    }

    private func paintedBody(
        configuration: Configuration,
        effectiveInFlight: Bool
    ) -> some View {
        Button {
            guard !effectiveInFlight else { return }
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(
            PrimaryActionVisualStyle(
                isInFlight: effectiveInFlight,
                harnessState: harnessState
            )
        )
        .disabled(effectiveInFlight || harnessState == .disabled)
        .accessibilityValue(effectiveInFlight ? "In progress" : "")
    }

}

private struct PrimaryActionVisualStyle: ButtonStyle {
    let isInFlight: Bool
    let harnessState: ControlState?

    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionBody(
            configuration: configuration,
            isInFlight: isInFlight,
            harnessState: harnessState
        )
    }
}

private struct PrimaryActionBody: View {
    let configuration: ButtonStyle.Configuration
    let isInFlight: Bool
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        isInFlight: Bool,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.isInFlight = isInFlight
        self.harnessState = harnessState
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.surfaceGround) private var inheritedGround
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            harnessState: harnessState,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering,
            isInFlight: isInFlight
        )
    }

    /// Cyan 0.42, not the 0.36 an earlier draft carried: at 0.36 the rim measured
    /// 2.63:1 against its own fill and failed the 3:1 non-text floor the rest of
    /// the control system is held to.
    private var stroke: Color {
        switch state {
        case .disabled: a11y.lineRule
        case .hover, .pressed, .focused, .selected: VoiceOourPalette.Signal.cyan.opacity(0.62)
        case .rest, .inFlight: VoiceOourPalette.Signal.cyan.opacity(0.42)
        }
    }

    private var fill: Color {
        switch state {
        case .disabled: .clear
        case .pressed: VoiceOourPalette.Signal.cyanDeep.opacity(0.22)
        case .hover, .focused, .selected: VoiceOourPalette.Signal.cyan.opacity(0.14)
        case .rest, .inFlight: VoiceOourPalette.Signal.cyan.opacity(0.08)
        }
    }

    private var foreground: Color {
        state == .disabled ? a11y.textLow : VoiceOourPalette.Signal.cyan
    }

    var body: some View {
        configuration.label
            .roleStyle(.micro, color: foreground)
            .padding(.horizontal, VoiceOourMetrics.Space.lg)
            .frame(height: VoiceOourMetrics.Control.large)
            .background(Capsule(style: .continuous).fill(fill))
            .environment(\.surfaceGround, inheritedGround.painting(fill))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: primaryStrokeWidth)
            }
            .overlay {
                if state == .focused {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            VoiceOourPalette.Signal.cyan.opacity(0.25),
                            lineWidth: VoiceOourMetrics.Space.hair
                        )
                        .padding(-VoiceOourMetrics.Space.hair)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(state == .pressed ? 0.985 : 1)
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }

    private var primaryStrokeWidth: CGFloat {
        if state == .focused || (state == .hover && a11y.differentiateWithoutColor) {
            return VoiceOourMetrics.Stroke.selected(a11y.contrast)
        }
        return VoiceOourMetrics.Stroke.hairline(a11y.contrast)
    }
}
