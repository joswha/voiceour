import SwiftUI

struct GlassToggleStyle: ToggleStyle {
    var harnessState: ControlState? = nil

    func makeBody(configuration: Configuration) -> some View {
        GlassToggleBody(
            configuration: configuration,
            harnessState: harnessState
        )
    }
}

extension View {
    func compactGlassToggle() -> some View {
        toggleStyle(GlassToggleStyle())
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct GlassToggleBody: View {
    let configuration: ToggleStyle.Configuration
    let harnessState: ControlState?

    @Environment(\.isEnabled) private var isEnabled

    private var isOn: Binding<Bool> {
        Binding(
            get: { configuration.isOn },
            set: { configuration.isOn = $0 }
        )
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            guard harnessState != .disabled else { return }
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(
            GlassToggleButtonStyle(
                isOn: configuration.isOn,
                harnessState: harnessState
            )
        )
        .disabled(harnessState == .disabled)
        .frame(minHeight: VoiceOourMetrics.Control.small)
        .accessibilityRepresentation {
            Toggle(isOn: isOn) {
                configuration.label
            }
            .toggleStyle(GlassToggleAccessibilityStyle())
            .disabled(!isEnabled || harnessState == .disabled)
        }
    }
}

private struct GlassToggleAccessibilityStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: VoiceOourMetrics.Control.medium)
    }
}

private struct GlassToggleButtonStyle: ButtonStyle {
    let isOn: Bool
    let harnessState: ControlState?

    func makeBody(configuration: Configuration) -> some View {
        GlassToggleVisualBody(
            configuration: configuration,
            isOn: isOn,
            harnessState: harnessState
        )
    }
}

private struct GlassToggleVisualBody: View {
    let configuration: ButtonStyle.Configuration
    let isOn: Bool
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        isOn: Bool,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.isOn = isOn
        self.harnessState = harnessState
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            harnessState: harnessState,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering
        )
    }

    var body: some View {
        HStack(spacing: VoiceOourMetrics.Space.md) {
            configuration.label
                .foregroundStyle(state == .disabled ? a11y.textLow : VoiceOourPalette.Text.high)
                .recordTextRole(
                    .body,
                    foreground: state == .disabled ? a11y.textLow : VoiceOourPalette.Text.high
                )
            Spacer(minLength: VoiceOourMetrics.Space.sm)
            track
        }
        .frame(minHeight: VoiceOourMetrics.Control.small)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
    }

    private var track: some View {
        Capsule()
            .fill(trackFill)
            .frame(
                width: VoiceOourMetrics.Control.Toggle.trackWidth,
                height: VoiceOourMetrics.Control.Toggle.trackHeight
            )
            .overlay {
                Capsule()
                    .strokeBorder(trackStroke, lineWidth: trackStrokeWidth)
            }
            .overlay {
                Circle()
                    .fill(knobFill)
                    .frame(
                        width: VoiceOourMetrics.Control.Toggle.knob,
                        height: VoiceOourMetrics.Control.Toggle.knob
                    )
                    .scaleEffect(state == .pressed ? 0.94 : 1)
                    .offset(
                        x: isOn
                            ? VoiceOourMetrics.Control.Toggle.travel / 2
                            : -VoiceOourMetrics.Control.Toggle.travel / 2
                    )
            }
            .overlay {
                if isOn, a11y.differentiateWithoutColor {
                    Image(systemName: "checkmark")
                        .font(.system(size: VoiceOourMetrics.Icon.mark, weight: .semibold))
                        .foregroundStyle(VoiceOourPalette.Text.high)
                        .offset(x: -VoiceOourMetrics.Control.Toggle.travel / 2)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if hasFocusHalo {
                    Capsule()
                        .strokeBorder(
                            VoiceOourPalette.Signal.focusHalo,
                            lineWidth: VoiceOourMetrics.Space.hair
                        )
                        .padding(-VoiceOourMetrics.Space.hair)
                        .allowsHitTesting(false)
                }
            }
            .frame(
                width: VoiceOourMetrics.Control.Toggle.hitWidth,
                height: VoiceOourMetrics.Control.Toggle.hitHeight
            )
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.standard, value: isOn)
            .accessibilityHidden(true)
    }

    private var trackFill: Color {
        guard state != .disabled else {
            return Color.clear
        }
        return isOn
            ? VoiceOourPalette.Signal.cyan.opacity(0.22)
            : VoiceOourPalette.Plate.rest
    }

    private var trackStroke: Color {
        switch state {
        case .disabled:
            a11y.lineRule
        case .focused:
            VoiceOourPalette.Line.focus
        case .hover, .pressed, .selected:
            isOn ? VoiceOourPalette.Signal.cyan.opacity(0.75) : VoiceOourPalette.Line.controlHover
        case .rest:
            isOn ? VoiceOourPalette.Signal.cyan.opacity(0.55) : a11y.lineControl
        case .inFlight:
            VoiceOourPalette.Line.controlHover
        }
    }

    private var trackStrokeWidth: CGFloat {
        if state == .hover, a11y.differentiateWithoutColor {
            return VoiceOourMetrics.Stroke.selected(a11y.contrast)
        }
        switch state {
        case .focused, .selected:
            return VoiceOourMetrics.Stroke.selected(a11y.contrast)
        default:
            return VoiceOourMetrics.Stroke.hairline(a11y.contrast)
        }
    }

    private var knobFill: Color {
        if state == .disabled {
            return a11y.markFaint
        }
        return isOn ? VoiceOourPalette.Text.high : a11y.textMid
    }

    private var hasFocusHalo: Bool {
        state == .focused
    }
}
