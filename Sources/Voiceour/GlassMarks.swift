import SwiftUI

struct HairlineDivider: View {
    enum Axis {
        case horizontal
        case vertical
    }

    @Environment(\.displayScale) private var displayScale
    private var a11y = A11y()

    var axis: Axis = .horizontal

    init(axis: Axis = .horizontal) {
        self.axis = axis
    }

    private var thickness: CGFloat {
        max(1 / displayScale, VoiceourMetrics.Stroke.hairline(a11y.contrast))
    }

    var body: some View {
        Rectangle()
            .fill(a11y.lineRule)
            .frame(
                width: axis == .vertical ? thickness : nil,
                height: axis == .horizontal ? thickness : nil
            )
    }
}

struct KeyCap: View {
    let label: String
    private var a11y = A11y()
    @Environment(\.surfaceGround) private var inheritedGround

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(VoiceourTypography.micro)
            .foregroundColor(VoiceourPalette.Text.monoStrong)
            .recordTextRole(.micro, foreground: VoiceourPalette.Text.monoStrong)
            .lineLimit(1)
            .padding(.horizontal, VoiceourMetrics.Space.sm)
            .frame(minHeight: VoiceourMetrics.Control.mini)
            .background {
                RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.keycap, style: .continuous)
                    .fill(VoiceourPalette.Plate.hover)
            }
            .environment(\.surfaceGround, inheritedGround.painting(VoiceourPalette.Plate.hover))
            .overlay {
                RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.keycap, style: .continuous)
                    .strokeBorder(
                        a11y.lineControl,
                        lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    )
            }
            .accessibilityLabel(label)
    }
}

/// Compact icon-only affordance for repeated row actions (remove a glossary
/// entry, dismiss a suggestion) where a full text button would out-weigh the
/// row it sits in. Ghost by default; `.danger` tints on hover for destructive use.
struct RowIconButton: View {
    enum Kind {
        case ghost
        case danger
    }

    var systemName: String
    var kind: Kind = .ghost
    var accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var harnessState: ControlState? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(
                    width: VoiceourMetrics.Control.medium,
                    height: VoiceourMetrics.Control.medium
                )
                .accessibilityHidden(true)
        }
        .buttonStyle(RowIconButtonStyle(kind: kind, harnessState: harnessState))
        .disabled(harnessState == .disabled || harnessState == .inFlight)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityRepresentation {
            Button(action: action) {
                Color.clear
                    .frame(
                        width: VoiceourMetrics.Control.medium,
                        height: VoiceourMetrics.Control.medium
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier ?? systemName)
        }
    }
}

private struct RowIconButtonStyle: ButtonStyle {
    let kind: RowIconButton.Kind
    let harnessState: ControlState?

    func makeBody(configuration: Configuration) -> some View {
        RowIconButtonBody(
            configuration: configuration,
            kind: kind,
            harnessState: harnessState
        )
    }
}

private struct RowIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: RowIconButton.Kind
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        kind: RowIconButton.Kind,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.kind = kind
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

    private var baseState: ControlState {
        if configuration.isPressed {
            return .pressed
        }
        return isHovering ? .hover : .rest
    }

    var body: some View {
        configuration.label
            .font(.system(size: VoiceourMetrics.Icon.row, weight: .medium))
            .foregroundStyle(foreground)
            .frame(
                width: VoiceourMetrics.Control.mini,
                height: VoiceourMetrics.Control.mini
            )
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            }
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
            .frame(
                width: VoiceourMetrics.Control.medium,
                height: VoiceourMetrics.Control.medium
            )
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
    }

    private var cornerRadius: CGFloat {
        VoiceourMetrics.Radius.nested(
            VoiceourMetrics.Radius.row,
            inset: VoiceourMetrics.Space.xs
        )
    }

    private var foreground: Color {
        switch state {
        case .disabled:
            a11y.textLow
        case .rest, .inFlight:
            a11y.textLow
        case .hover, .pressed, .focused, .selected:
            VoiceourPalette.Text.high
        }
    }

    private var fill: Color {
        switch state {
        case .rest, .disabled, .inFlight:
            Color.clear
        case .hover, .selected:
            VoiceourPalette.Plate.hover
        case .pressed:
            VoiceourPalette.Plate.pressed
        case .focused:
            interactionFill(for: baseState)
        }
    }

    private func interactionFill(for state: ControlState) -> Color {
        switch state {
        case .hover:
            VoiceourPalette.Plate.hover
        case .pressed:
            VoiceourPalette.Plate.pressed
        default:
            Color.clear
        }
    }

    private var stroke: Color {
        switch state {
        case .rest, .disabled:
            Color.clear
        case .hover:
            a11y.lineControl
        case .pressed, .inFlight:
            VoiceourPalette.Line.controlHover
        case .focused:
            VoiceourPalette.Line.focus
        case .selected:
            VoiceourPalette.Signal.cyan.opacity(a11y.contrast == .increased ? 0.90 : 0.72)
        }
    }

    private var strokeWidth: CGFloat {
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

    private var hasFocusHalo: Bool {
        state == .focused || (state == .selected && isFocused)
    }
}
