import SwiftUI

struct GlassButtonStyle: PrimitiveButtonStyle {
    enum Kind {
        case ghost
        /// In-content emphasis (Sessions TEACH/ACCEPT, Glossary ADD TERM). NOT the
        /// pane's floating primary action — that is `PrimaryActionButtonStyle`.
        case accent
        case danger
    }

    var kind: Kind = .ghost
    var isInFlight: Bool = false
    var harnessState: ControlState? = nil

    func makeBody(configuration: Configuration) -> some View {
        let effectiveInFlight = isInFlight || harnessState == .inFlight
        let blocksActivation = effectiveInFlight || harnessState == .disabled

        return Button {
            guard !isInFlight else { return }
            guard harnessState != .inFlight else { return }
            configuration.trigger()
        } label: {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if effectiveInFlight {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: VoiceourMetrics.Icon.mark))
                        .accessibilityHidden(true)
                }
                configuration.label
            }
        }
        .buttonStyle(
            GlassButtonVisualStyle(
                kind: kind,
                isInFlight: effectiveInFlight,
                harnessState: harnessState
            )
        )
        .disabled(blocksActivation)
        .accessibilityValue(effectiveInFlight ? "In progress" : "")
        .accessibilityRepresentation {
            Button {
                guard !isInFlight else { return }
                guard harnessState != .inFlight else { return }
                configuration.trigger()
            } label: {
                configuration.label
            }
            .disabled(blocksActivation)
            .accessibilityValue(effectiveInFlight ? "In progress" : "")
        }
    }
}

private struct GlassButtonVisualStyle: ButtonStyle {
    let kind: GlassButtonStyle.Kind
    let isInFlight: Bool
    let harnessState: ControlState?

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(
            configuration: configuration,
            kind: kind,
            isInFlight: isInFlight,
            harnessState: harnessState
        )
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: GlassButtonStyle.Kind
    let isInFlight: Bool
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        kind: GlassButtonStyle.Kind,
        isInFlight: Bool,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.kind = kind
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

    private var baseState: ControlState {
        if configuration.isPressed {
            return .pressed
        }
        return isHovering ? .hover : .rest
    }

    private var cornerRadius: CGFloat {
        VoiceourMetrics.Radius.nested(VoiceourMetrics.Radius.card, inset: VoiceourMetrics.Space.md)
    }

    var body: some View {
        configuration.label
            .font(VoiceourTypography.micro)
            .kerning(TextRole.micro.tracking)
            .foregroundStyle(foreground)
            .recordTextRole(.micro, foreground: foreground)
            .padding(.horizontal, VoiceourMetrics.Button.horizontal)
            .frame(height: VoiceourMetrics.Control.medium)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            }
            .environment(\.surfaceGround, inheritedGround.painting(fill))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: strokeWidth)
            }
            .overlay {
                if hasFocusHalo {
                    RoundedRectangle(
                        cornerRadius: VoiceourMetrics.Radius.nested(
                            cornerRadius,
                            inset: -VoiceourMetrics.Space.hair
                        ),
                        style: .continuous
                    )
                    .strokeBorder(
                        VoiceourPalette.Signal.focusHalo,
                        lineWidth: VoiceourMetrics.Space.hair
                    )
                    .padding(-VoiceourMetrics.Space.hair)
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(state == .pressed ? VoiceourMetrics.Control.pressedScale : 1)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        if state == .disabled {
            return a11y.textLow
        }
        if kind == .danger, state == .rest || state == .inFlight {
            return VoiceourPalette.Signal.crimson
        }
        return VoiceourPalette.Text.high
    }

    private var fill: Color {
        switch state {
        case .disabled:
            Color.clear
        case .focused:
            interactionFill(for: baseState)
        case .selected:
            VoiceourPalette.Plate.hover
        case .inFlight:
            interactionFill(for: .rest)
        case .rest, .hover, .pressed:
            interactionFill(for: state)
        }
    }

    private func interactionFill(for state: ControlState) -> Color {
        switch kind {
        case .ghost:
            switch state {
            case .hover:
                VoiceourPalette.Plate.hover
            case .pressed:
                VoiceourPalette.Plate.pressed
            default:
                VoiceourPalette.Plate.rest
            }
        case .accent:
            switch state {
            case .hover:
                VoiceourPalette.Plate.hover
            case .pressed:
                VoiceourPalette.Signal.cyanDeep.opacity(0.16)
            default:
                VoiceourPalette.Signal.cyan.opacity(0.06)
            }
        case .danger:
            switch state {
            case .hover, .pressed:
                VoiceourPalette.Signal.crimson.opacity(0.08)
            default:
                VoiceourPalette.Signal.crimson.opacity(0.04)
            }
        }
    }

    private var stroke: Color {
        switch state {
        case .disabled:
            return a11y.lineRule
        case .focused:
            return VoiceourPalette.Line.focus
        case .selected:
            return VoiceourPalette.Signal.cyan.opacity(
                a11y.contrast == .increased ? 0.90 : 0.72
            )
        case .inFlight:
            return VoiceourPalette.Line.controlHover
        case .rest, .hover, .pressed:
            break
        }

        switch kind {
        case .ghost:
            return state == .rest
                ? a11y.lineControl
                : VoiceourPalette.Line.controlHover
        case .accent:
            switch state {
            case .rest:
                return VoiceourPalette.Signal.cyan.opacity(0.42)
            case .hover:
                return VoiceourPalette.Signal.cyan.opacity(0.70)
            case .pressed:
                return VoiceourPalette.Signal.cyan.opacity(0.90)
            default:
                return VoiceourPalette.Line.controlHover
            }
        case .danger:
            return VoiceourPalette.Signal.crimson.opacity(state == .rest ? 0.60 : 0.72)
        }
    }

    private var strokeWidth: CGFloat {
        if state == .hover, a11y.differentiateWithoutColor {
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        }
        if state == .focused || state == .selected {
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        }
        if kind == .accent, state == .hover || state == .pressed {
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        }
        return VoiceourMetrics.Stroke.hairline(a11y.contrast)
    }

    private var hasFocusHalo: Bool {
        state == .focused
    }
}
