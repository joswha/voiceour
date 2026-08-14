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
        max(1 / displayScale, VoiceOourMetrics.Stroke.hairline(a11y.contrast))
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

/// A mark, not a control. It carries a tinted fill and a label and nothing else:
/// a chip with a fill *and* a rim was pixel-identical to a ghost button at rest
/// (both sampled (21,22,24) on (51,52,54), same mono uppercase label, 100pt
/// apart in the Sessions transcript card), so the one cue that says "you can
/// press this" said nothing. Fill plus rim now means clickable; fill alone means
/// annotation.
struct StatusChip: View {
    enum Mode {
        case neutral
        case ok
        case warn
        case crit
        case live

        var differentiateSymbol: String? {
            switch self {
            case .neutral: nil
            case .ok: "checkmark"
            case .warn: "exclamationmark.triangle.fill"
            case .crit: "xmark.octagon.fill"
            case .live: "circle.fill"
            }
        }
    }

    enum Size {
        case regular
        case compact
    }

    let label: String
    let mode: Mode
    let size: Size
    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()
    @Environment(\.surfaceGround) private var inheritedGround

    init(label: String, mode: Mode = .neutral, size: Size = .regular) {
        self.label = label
        self.mode = mode
        self.size = size
    }

    var body: some View {
        HStack(spacing: VoiceOourMetrics.Space.xs) {
            if a11y.differentiateWithoutColor, let symbol = mode.differentiateSymbol {
                Image(systemName: symbol)
                    .font(.system(size: VoiceOourMetrics.Icon.mark))
                    .accessibilityHidden(true)
            }
            Text(label.uppercased())
                .font(size == .compact ? VoiceOourTypography.micro.monospacedDigit() : VoiceOourTypography.micro)
                .kerning(size == .compact ? 0.4 : TextRole.micro.tracking)
                .lineLimit(1)
        }
        .foregroundColor(foreground)
        .recordTextRole(.micro, foreground: foreground)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, size == .compact ? VoiceOourMetrics.Space.xs : VoiceOourMetrics.Chip.horizontal)
        .frame(
            height: size == .compact
                ? VoiceOourMetrics.Control.compactMark
                : VoiceOourMetrics.Control.mini
        )
        .background {
            RoundedRectangle(cornerRadius: VoiceOourMetrics.Radius.chip, style: .continuous)
                .fill(fill)
        }
        .environment(\.surfaceGround, inheritedGround.painting(fill))
        .accessibilityLabel(label.uppercased())
    }

    /// A chip inside a switched-off group keeps its shape, its label and its
    /// Differentiate Without Color symbol, and loses only its colour. The mode
    /// is still true — the group it grades is simply not in effect — so
    /// deleting the mark would be a lie, while leaving it at full signal
    /// strength would make a disabled block the brightest thing on the pane.
    private var foreground: Color {
        guard isEnabled else { return a11y.textLow }

        return switch mode {
        case .neutral:
            a11y.textMid
        case .ok:
            VoiceOourPalette.Signal.mint
        case .warn:
            VoiceOourPalette.Signal.amber
        case .crit:
            VoiceOourPalette.Signal.crimson
        case .live:
            VoiceOourPalette.Signal.cyan
        }
    }

    /// Increase Contrast escalates every mode, neutral included: with the rim
    /// gone the fill is the only thing bounding the mark, so it has to be the
    /// thing that strengthens. A disabled chip recedes to that same neutral
    /// plate rather than a fill of its own — one less state to keep in step.
    private var fill: Color {
        let increased = a11y.contrast == .increased
        guard isEnabled else {
            return increased ? VoiceOourPalette.Plate.hover : VoiceOourPalette.Plate.rest
        }

        return switch mode {
        case .neutral:
            increased ? VoiceOourPalette.Plate.hover : VoiceOourPalette.Plate.rest
        case .ok:
            VoiceOourPalette.Signal.mint.opacity(increased ? 0.18 : 0.08)
        case .warn:
            VoiceOourPalette.Signal.amber.opacity(increased ? 0.18 : 0.08)
        case .crit:
            VoiceOourPalette.Signal.crimson.opacity(increased ? 0.18 : 0.08)
        case .live:
            VoiceOourPalette.Signal.cyan.opacity(increased ? 0.18 : 0.08)
        }
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
            .font(VoiceOourTypography.micro)
            .foregroundColor(VoiceOourPalette.Text.monoStrong)
            .recordTextRole(.micro, foreground: VoiceOourPalette.Text.monoStrong)
            .lineLimit(1)
            .padding(.horizontal, VoiceOourMetrics.Space.sm)
            .frame(minHeight: VoiceOourMetrics.Control.mini)
            .background {
                RoundedRectangle(cornerRadius: VoiceOourMetrics.Radius.keycap, style: .continuous)
                    .fill(VoiceOourPalette.Plate.hover)
            }
            .environment(\.surfaceGround, inheritedGround.painting(VoiceOourPalette.Plate.hover))
            .overlay {
                RoundedRectangle(cornerRadius: VoiceOourMetrics.Radius.keycap, style: .continuous)
                    .strokeBorder(
                        a11y.lineControl,
                        lineWidth: VoiceOourMetrics.Stroke.hairline(a11y.contrast)
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
                    width: VoiceOourMetrics.Control.medium,
                    height: VoiceOourMetrics.Control.medium
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
                        width: VoiceOourMetrics.Control.medium,
                        height: VoiceOourMetrics.Control.medium
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
            .font(.system(size: VoiceOourMetrics.Icon.row, weight: .medium))
            .foregroundStyle(foreground)
            .frame(
                width: VoiceOourMetrics.Control.mini,
                height: VoiceOourMetrics.Control.mini
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
                        cornerRadius: VoiceOourMetrics.Radius.nested(
                            cornerRadius,
                            inset: -VoiceOourMetrics.Space.hair
                        ),
                        style: .continuous
                    )
                    .strokeBorder(
                        VoiceOourPalette.Signal.focusHalo,
                        lineWidth: VoiceOourMetrics.Space.hair
                    )
                    .padding(-VoiceOourMetrics.Space.hair)
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(state == .pressed ? VoiceOourMetrics.Control.pressedScale : 1)
            .frame(
                width: VoiceOourMetrics.Control.medium,
                height: VoiceOourMetrics.Control.medium
            )
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
    }

    private var cornerRadius: CGFloat {
        VoiceOourMetrics.Radius.nested(
            VoiceOourMetrics.Radius.row,
            inset: VoiceOourMetrics.Space.xs
        )
    }

    private var foreground: Color {
        switch state {
        case .disabled:
            a11y.textLow
        case .rest, .inFlight:
            a11y.textLow
        case .hover, .pressed, .focused, .selected:
            VoiceOourPalette.Text.high
        }
    }

    private var fill: Color {
        switch state {
        case .rest, .disabled, .inFlight:
            Color.clear
        case .hover, .selected:
            VoiceOourPalette.Plate.hover
        case .pressed:
            VoiceOourPalette.Plate.pressed
        case .focused:
            interactionFill(for: baseState)
        }
    }

    private func interactionFill(for state: ControlState) -> Color {
        switch state {
        case .hover:
            VoiceOourPalette.Plate.hover
        case .pressed:
            VoiceOourPalette.Plate.pressed
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
            VoiceOourPalette.Line.controlHover
        case .focused:
            VoiceOourPalette.Line.focus
        case .selected:
            VoiceOourPalette.Signal.cyan.opacity(a11y.contrast == .increased ? 0.90 : 0.72)
        }
    }

    private var strokeWidth: CGFloat {
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

    private var hasFocusHalo: Bool {
        state == .focused || (state == .selected && isFocused)
    }
}
