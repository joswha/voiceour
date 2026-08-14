import AppKit
import SwiftUI

/// Public-SDK macOS glass: an `NSVisualEffectView` that samples content behind the
/// transparent window/panel. Voiceour keeps the type internal to the app module so
/// VoiceCore remains Foundation-only and VoiceMac owns platform side effects.
struct FrostedGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.layer?.cornerRadius = cornerRadius
    }
}
struct GlassSurface: ViewModifier {
    private var a11y = A11y()

    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if RenderOverrides.forceLegacyGlass {
                legacyBody(content: content)
            } else {
                content
                    .glassEffect(
                        .regular,
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .environment(\.surfaceGround, SurfaceGround(a11y.ground))
            }
        } else {
            legacyBody(content: content)
        }
    }

    private func legacyBody(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if a11y.reduceTransparency {
                        // Opaque, and deliberately *lighter* than the content
                        // plane — see `Ink.frost`. Reduce Transparency has to
                        // keep the ground above the cards, or the adaptation
                        // flattens the console instead of clarifying it.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(a11y.ground)
                    } else {
                        FrostedGlassBackground(cornerRadius: cornerRadius)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(VoiceourPalette.glassTint)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                VoiceourPalette.specularRim,
                                lineWidth: a11y.contrast == .increased
                                    ? 1
                                    : VoiceourMetrics.Stroke.specular
                            )
                            .blendMode(.plusLighter)
                    }
                    RoundedRectangle(
                        cornerRadius: VoiceourMetrics.Radius.nested(
                            cornerRadius,
                            inset: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                        ),
                        style: .continuous
                    )
                    .strokeBorder(
                        VoiceourPalette.Ink.rimDark,
                        lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    )
                    .padding(VoiceourMetrics.Stroke.hairline(a11y.contrast))
                }
            }
            .environment(\.surfaceGround, SurfaceGround(a11y.ground))
    }
}

enum ScrollEdgeTreatment {
    case hard
    case soft
}

private struct ScrollEdgeTreatmentModifier: ViewModifier {
    let treatment: ScrollEdgeTreatment
    let edges: Edge.Set

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if RenderOverrides.forceLegacyGlass {
                content
            } else {
                switch treatment {
                case .hard:
                    content.scrollEdgeEffectStyle(.hard, for: edges)
                case .soft:
                    content.scrollEdgeEffectStyle(.soft, for: edges)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func glassSurface(
        cornerRadius: CGFloat = VoiceourMetrics.Radius.window
    ) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }

    func scrollEdge(_ treatment: ScrollEdgeTreatment, for edges: Edge.Set) -> some View {
        modifier(ScrollEdgeTreatmentModifier(treatment: treatment, edges: edges))
    }

    func plateSurface(
        kind: PlateSurface.Kind,
        cornerRadius: CGFloat? = nil,
        state: ControlState? = nil,
        baseState: ControlState = .rest,
        showsFocusHalo: Bool = false
    ) -> some View {
        modifier(
            PlateSurface(
                kind: kind,
                cornerRadius: cornerRadius,
                state: state,
                baseState: baseState,
                showsFocusHalo: showsFocusHalo
            )
        )
    }
}

struct PlateSurface: ViewModifier {
    enum Kind {
        case row
        case hover
        case selected
        case input
        case well
        case group
    }

    private var a11y = A11y()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.surfaceGround) private var inheritedGround

    let kind: Kind
    let cornerRadius: CGFloat
    let requestedState: ControlState
    let baseState: ControlState
    let showsFocusHalo: Bool

    init(
        kind: Kind = .row,
        cornerRadius: CGFloat? = nil,
        state: ControlState? = nil,
        baseState: ControlState = .rest,
        showsFocusHalo: Bool = false
    ) {
        self.kind = kind
        self.cornerRadius = cornerRadius ?? Self.defaultRadius(for: kind)
        self.requestedState = state ?? Self.defaultState(for: kind)
        self.baseState = baseState
        self.showsFocusHalo = showsFocusHalo
    }

    func body(content: Content) -> some View {
        content
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
            // A plate is its shape, whatever it is painted with. Without this
            // the hit region — and with it the AX frame — collapses onto the
            // drawn content the moment a state paints nothing: an unselected
            // rail row measured 31x16 instead of its 32 pt row, caught by the
            // harness `control-height` rule. `PrimaryActionBody` pins its
            // capsule for the same reason.
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.surfaceGround, inheritedGround.painting(fill))
    }

    private var state: ControlState {
        if kind == .well {
            return .rest
        }
        if requestedState == .inFlight {
            return .inFlight
        }
        return isEnabled ? requestedState : .disabled
    }

    private var fill: Color {
        if kind == .well {
            return VoiceourPalette.Ink.well
        }
        if kind == .group {
            return Color.clear
        }

        switch state {
        case .rest:
            return restingFill
        case .hover, .selected:
            return VoiceourPalette.Plate.hover
        case .pressed:
            return VoiceourPalette.Plate.pressed
        case .focused:
            if kind == .input, baseState == .rest {
                return VoiceourPalette.Plate.rest
            }
            return interactionFill(for: baseState)
        case .disabled:
            return isDisabledSelection ? VoiceourPalette.Plate.rest : restingFill
        case .inFlight:
            return VoiceourPalette.Plate.rest
        }
    }

    /// A `.row` at rest is not a plate. Painting a fill and a rim behind every
    /// nav item and every session row turns a seven-item list into seven
    /// outlined boxes, and then selection has to shout over six competitors —
    /// `lg-standard` rule 2, "a custom opaque plate behind every button is
    /// counter to system hierarchy". Hover, focus and selection own the chrome;
    /// at rest the row is just its content on the ground beneath it.
    ///
    /// `.input` goes the other way. A field with no fill at all is the quietest
    /// thing on the surface — its interior *is* the card, so only the rim says a
    /// field is there, and the ghost button beside it out-weighs the control the
    /// row exists for. It recesses instead: `Ink.well`, the token for exactly
    /// this, darker than the surface rather than the light plate an earlier
    /// draft rejected. Hover (0.09) and focus (0.05) still read as a lift above
    /// it, so the ladder keeps its direction.
    private var restingFill: Color {
        switch kind {
        case .row:
            return Color.clear
        case .input:
            return VoiceourPalette.Ink.well
        case .hover, .selected, .well, .group:
            return VoiceourPalette.Plate.rest
        }
    }

    private func interactionFill(for state: ControlState) -> Color {
        switch state {
        case .hover, .selected:
            VoiceourPalette.Plate.hover
        case .pressed:
            VoiceourPalette.Plate.pressed
        default:
            restingFill
        }
    }

    private var stroke: Color {
        switch state {
        case .focused:
            VoiceourPalette.Line.focus
        case .selected:
            VoiceourPalette.Signal.cyan.opacity(a11y.contrast == .increased ? 0.90 : 0.72)
        case .hover, .pressed, .inFlight:
            VoiceourPalette.Line.controlHover
        case .disabled:
            disabledStroke
        case .rest:
            restingStroke
        }
    }

    /// The rim a row drops (see `restingFill`) comes back for the two
    /// adaptations that ask for exactly it: Increase Contrast wants a
    /// contrasting border on everything, and Differentiate Without Colour wants
    /// a boundary that is not carried by a tint. `.input`, `.well` and `.group`
    /// keep their rim unconditionally — the rim *is* the affordance there.
    private var rowKeepsRim: Bool {
        kind != .row || a11y.contrast == .increased || a11y.differentiateWithoutColor
    }

    private var restingStroke: Color {
        rowKeepsRim ? a11y.lineControl : .clear
    }

    /// Disabled is quieter than rest, never louder: a row that paints no rim at
    /// rest paints none when disabled either, or switching a group off would
    /// *draw* it. And a disabled control still gets to say which option is
    /// chosen — `ControlState` resolves `.disabled` ahead of `.selected`, so
    /// without this a switched-off segment group renders its selection exactly
    /// like the options it was chosen over.
    private var disabledStroke: Color {
        if isDisabledSelection {
            return VoiceourPalette.Signal.cyan.opacity(a11y.contrast == .increased ? 0.60 : 0.40)
        }
        return rowKeepsRim ? a11y.lineRule : .clear
    }

    private var isDisabledSelection: Bool {
        state == .disabled && baseState == .selected
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
        state == .focused || (showsFocusHalo && state != .disabled && state != .inFlight)
    }

    private static func defaultState(for kind: Kind) -> ControlState {
        switch kind {
        case .hover:
            .hover
        case .selected:
            .selected
        case .row, .input, .well, .group:
            .rest
        }
    }

    private static func defaultRadius(for kind: Kind) -> CGFloat {
        switch kind {
        case .row, .hover, .selected, .input, .well, .group:
            VoiceourMetrics.Radius.nested(
                VoiceourMetrics.Radius.card,
                inset: VoiceourMetrics.Space.md
            )
        }
    }
}
