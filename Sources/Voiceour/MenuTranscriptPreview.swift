import Foundation
import SwiftUI

/// The last transcript, and the control that copies it.
///
/// The copy affordance belongs to the object it acts on. It used to live in the
/// global command list on the far side of a group separator, 133 pt below the
/// card, where it survived as a permanently-disabled dead row whenever the card
/// it belonged to was absent. Attached to the card, the action appears and
/// disappears with the transcript and the separator goes back to separating
/// unrelated things.
///
/// The well holds the transcript and nothing else: its tooltip and accessibility
/// label name the action, and `MenuReportBlock` confirms a copy under the well.
struct MenuTranscriptPreview: View {
    let text: String
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .roleStyle(.caption)
                .foregroundStyle(VoiceourPalette.Text.high)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(MenuWellButtonStyle())
        .accessibilityLabel("Copy last transcript")
        .accessibilityValue(text)
        .help("Click to copy the last transcript.")
    }
}

/// A well that is also the control, so this style owns the surface: it paints
/// Home's island pane and rims (``Kit/Island``'s recipe) in the popover's
/// concentric radius, and lifts that pane with the interaction ladder.
private struct MenuWellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuWellBody(configuration: configuration)
    }
}

private struct MenuWellBody: View {
    let configuration: ButtonStyle.Configuration

    init(configuration: ButtonStyle.Configuration) {
        self.configuration = configuration
    }

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

    var body: some View {
        configuration.label
            .padding(VoiceourMetrics.Space.sm)
            // Pinned rather than content-sized: the popover must not reflow its
            // own height as transcripts change length. Three 15 pt caption lines
            // and the `Space.sm` padding come to 61 pt, so one `Row.list` pitch
            // holds the tallest transcript and keeps the press target on the row
            // scale.
            .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Row.list, alignment: .topLeading)
            .background { surface }
            .overlay {
                if let interactionStroke {
                    MenuLayout.innerShape
                        .strokeBorder(interactionStroke, lineWidth: strokeWidth)
                }
            }
            // This body paints its pane and wash by hand, so it also has to
            // declare what it painted — otherwise every transcript sample is
            // measured against the popover's ground instead of the pane the
            // text actually sits on. Only the opaque layers: `glassTint` is a
            // gradient, and reporting its lightest stop would understate the
            // ground under the first line.
            .environment(\.surfaceGround, paintedGround)
            .contentShape(MenuLayout.innerShape)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var paintedGround: SurfaceGround {
        let pane =
            a11y.reduceTransparency
            ? SurfaceGround(VoiceourPalette.Ink.surface)
            : inheritedGround
                .painting(VoiceourPalette.Ink.void.opacity(0.55))
                .painting(VoiceourPalette.Ink.pane)
        return pane.painting(wash)
    }

    @ViewBuilder
    private var surface: some View {
        let shape = MenuLayout.innerShape
        if a11y.reduceTransparency {
            // With the material gone there is nothing for a highlight to be a
            // highlight of: an opaque pane bounded by a drawn edge.
            ZStack {
                shape.fill(VoiceourPalette.Ink.surface)
                shape.fill(wash)
                shape.strokeBorder(
                    a11y.lineEdge,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
            }
        } else {
            ZStack {
                shape.fill(VoiceourPalette.Ink.void.opacity(0.55))
                shape.fill(VoiceourPalette.Ink.pane)
                shape.fill(VoiceourPalette.glassTint)
                // On a near-black pane the only headroom left is upward, so
                // interaction lifts the fill rather than deepening it.
                shape.fill(wash)
                // The neon rim: a blurred stroke lights only the edge, where a
                // green shadow behind translucent fills would tint the pane.
                shape
                    .strokeBorder(VoiceourPalette.Alien.bloomGlow, lineWidth: 1.5)
                    .blur(radius: 2.5)
                    .blendMode(.plusLighter)
                shape
                    .strokeBorder(
                        VoiceourPalette.specularRim,
                        lineWidth: a11y.contrast == .increased ? 1 : VoiceourMetrics.Stroke.specular
                    )
                    .blendMode(.plusLighter)
                RoundedRectangle(
                    cornerRadius: VoiceourMetrics.Radius.nested(
                        MenuLayout.innerRadius,
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
    }

    /// The rim interaction adds over the pane's own; rest adds none.
    private var interactionStroke: Color? {
        switch state {
        case .focused, .selected:
            VoiceourPalette.Line.focus
        case .hover, .pressed, .inFlight:
            VoiceourPalette.Line.controlHover
        case .rest, .disabled:
            nil
        }
    }

    private var wash: Color {
        switch state {
        case .pressed:
            VoiceourPalette.Plate.hover
        case .hover, .focused, .selected:
            VoiceourPalette.Plate.rest
        case .rest, .disabled, .inFlight:
            Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        state == .focused || state == .selected
            ? VoiceourMetrics.Stroke.selected(a11y.contrast)
            : VoiceourMetrics.Stroke.hairline(a11y.contrast)
    }
}
