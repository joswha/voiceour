import SwiftUI

/// Shared row/hover/selected + keyboard-focus ladder for buttons whose label
/// is a bespoke layout (icon+text nav item, multi-line session row, a bare
/// segment label) rather than `GlassButtonStyle`'s fixed micro-label pill.
/// Composes the same `PlateSurface` kinds `GlassTextFieldStyle` uses, so a
/// selectable row/segment/nav-item follows the identical hover-then-focus-
/// then-selected ladder as everything else, and suppresses the native focus
/// ring in one place instead of three call sites each re-omitting it. Used
/// by `RailItem`, the Sessions list's row-selection button, and
/// `SegmentOption`.
struct PlateButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = VoiceOourMetrics.Radius.row
    var harnessState: ControlState? = nil

    func makeBody(configuration: Configuration) -> some View {
        PlateButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            harnessState: harnessState
        )
    }
}

private struct PlateButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let cornerRadius: CGFloat
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        isSelected: Bool,
        cornerRadius: CGFloat,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
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
            isSelected: isSelected,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering
        )
    }

    /// What the row would be if nothing were escalating it — the fill `.focused`
    /// falls back to, and the only route selection has to survive `.disabled`,
    /// which `ControlState.resolve` ranks above it.
    private var baseState: ControlState {
        if configuration.isPressed {
            return .pressed
        }
        if isHovering {
            return .hover
        }
        return isSelected ? .selected : .rest
    }

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(minHeight: VoiceOourMetrics.Control.medium)
            .plateSurface(
                kind: .row,
                cornerRadius: cornerRadius,
                state: state,
                baseState: baseState,
                showsFocusHalo: isFocused && state == .selected
            )
            .scaleEffect(state == .pressed ? 0.985 : 1)
            .disabled(harnessState == .disabled || harnessState == .inFlight)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
            .onHover { isHovering = $0 }
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
