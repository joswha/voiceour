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
        .frame(minHeight: VoiceourMetrics.Control.small)
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
            .frame(minHeight: VoiceourMetrics.Control.medium)
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
        HStack(spacing: VoiceourMetrics.Space.md) {
            configuration.label
                .foregroundStyle(state == .disabled ? a11y.textLow : VoiceourPalette.Text.high)
                .recordTextRole(
                    .body,
                    foreground: state == .disabled ? a11y.textLow : VoiceourPalette.Text.high
                )
            Spacer(minLength: VoiceourMetrics.Space.sm)
            track
        }
        .frame(minHeight: VoiceourMetrics.Control.small)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
    }

    private var track: some View {
        Capsule()
            .fill(trackFill)
            .frame(
                width: VoiceourMetrics.Control.Toggle.trackWidth,
                height: VoiceourMetrics.Control.Toggle.trackHeight
            )
            .overlay {
                Capsule()
                    .strokeBorder(trackStroke, lineWidth: trackStrokeWidth)
            }
            .overlay {
                Circle()
                    .fill(knobFill)
                    .frame(
                        width: VoiceourMetrics.Control.Toggle.knob,
                        height: VoiceourMetrics.Control.Toggle.knob
                    )
                    .scaleEffect(state == .pressed ? 0.94 : 1)
                    .offset(
                        x: isOn
                            ? VoiceourMetrics.Control.Toggle.travel / 2
                            : -VoiceourMetrics.Control.Toggle.travel / 2
                    )
            }
            .overlay {
                if isOn, a11y.differentiateWithoutColor {
                    Image(systemName: "checkmark")
                        .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                        .foregroundStyle(VoiceourPalette.Text.high)
                        .offset(x: -VoiceourMetrics.Control.Toggle.travel / 2)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if hasFocusHalo {
                    Capsule()
                        .strokeBorder(
                            VoiceourPalette.Signal.focusHalo,
                            lineWidth: VoiceourMetrics.Space.hair
                        )
                        .padding(-VoiceourMetrics.Space.hair)
                        .allowsHitTesting(false)
                }
            }
            .frame(
                width: VoiceourMetrics.Control.Toggle.hitWidth,
                height: VoiceourMetrics.Control.Toggle.hitHeight
            )
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.standard, value: isOn)
            .accessibilityHidden(true)
    }

    private var trackFill: Color {
        guard state != .disabled else {
            return Color.clear
        }
        return isOn
            ? VoiceourPalette.Signal.cyan.opacity(0.22)
            : VoiceourPalette.Plate.rest
    }

    private var trackStroke: Color {
        switch state {
        case .disabled:
            a11y.lineRule
        case .focused:
            VoiceourPalette.Line.focus
        case .hover, .pressed, .selected:
            isOn ? VoiceourPalette.Signal.cyan.opacity(0.75) : VoiceourPalette.Line.controlHover
        case .rest:
            isOn ? VoiceourPalette.Signal.cyan.opacity(0.55) : a11y.lineControl
        case .inFlight:
            VoiceourPalette.Line.controlHover
        }
    }

    private var trackStrokeWidth: CGFloat {
        if state == .hover, a11y.differentiateWithoutColor {
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        }
        switch state {
        case .focused, .selected:
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        default:
            return VoiceourMetrics.Stroke.hairline(a11y.contrast)
        }
    }

    private var knobFill: Color {
        if state == .disabled {
            return a11y.markFaint
        }
        return isOn ? VoiceourPalette.Text.high : a11y.textMid
    }

    private var hasFocusHalo: Bool {
        state == .focused
    }
}
