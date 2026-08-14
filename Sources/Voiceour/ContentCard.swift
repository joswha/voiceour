import SwiftUI

/// An opaque content surface shared by the Home dashboard's bento grid and
/// settings sections. It establishes a quiet plane over the window glass with
/// one definition edge and no tint, specular rim, shadow, or offscreen group.
/// `interactive: true` adds a reduce-motion-gated hover wash behind the content.
/// Accessibility children stay independently addressable by default; read-only
/// metric tiles can explicitly opt into a combined leaf summary.
struct ContentCard<Content: View>: View {
    var eyebrow: String
    var interactive: Bool
    var summary: (value: String, detail: String?)?
    let content: Content

    private var a11y = A11y()
    @State private var isHovered = false

    init(
        eyebrow: String,
        interactive: Bool = false,
        summary: (value: String, detail: String?)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.interactive = interactive
        self.summary = summary
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if let summary {
            card
                .accessibilityElement(children: .combine)
                .accessibilityLabel(eyebrow)
                .accessibilityValue(accessibilityValue(for: summary))
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            Text(eyebrow)
                .font(VoiceourTypography.eyebrow)
                .kerning(TextRole.eyebrow.tracking)
                .foregroundStyle(a11y.textLow)
                .recordTextRole(.eyebrow, foreground: a11y.textLow)

            content
        }
        .padding(VoiceourMetrics.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.card, style: .continuous)
                .fill(a11y.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.card, style: .continuous)
                        .strokeBorder(
                            a11y.lineEdge,
                            lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                        )
                }
                .overlay {
                    if interactive && isHovered {
                        RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.card, style: .continuous)
                            .fill(VoiceourPalette.Plate.hover)
                            .overlay {
                                RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.card, style: .continuous)
                                    .strokeBorder(
                                        VoiceourPalette.Line.controlHover,
                                        lineWidth: hoverStrokeWidth
                                    )
                            }
                            .allowsHitTesting(false)
                    }
                }
        }
        .environment(\.surfaceGround, cardGround)
        .containerShape(.rect(cornerRadius: VoiceourMetrics.Radius.card))
        .onHover { hovering in
            guard interactive else { return }
            if a11y.reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(VoiceourMotion.quick) { isHovered = hovering }
            }
        }
    }

    private var cardGround: SurfaceGround {
        let ground = SurfaceGround(a11y.surface)
        return interactive && isHovered
            ? ground.painting(VoiceourPalette.Plate.hover)
            : ground
    }

    private var hoverStrokeWidth: CGFloat {
        a11y.differentiateWithoutColor
            ? VoiceourMetrics.Stroke.selected(a11y.contrast)
            : VoiceourMetrics.Stroke.hairline(a11y.contrast)
    }

    private func accessibilityValue(for summary: (value: String, detail: String?)) -> String {
        guard let detail = summary.detail else {
            return summary.value
        }
        return "\(summary.value), \(detail)"
    }
}
