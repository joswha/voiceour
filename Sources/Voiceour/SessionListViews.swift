import SwiftUI
import VoiceCore

/// Both session wells and the recessed search input are full-bleed children of
/// content surfaces, so their radius derives concentrically from the card at the
/// card's own `Space.md` padding (§2.1) instead of repeating `Radius.card` one level down.
let sessionWellRadius = VoiceourMetrics.Radius.nested(
    VoiceourMetrics.Radius.card,
    inset: VoiceourMetrics.Space.md
)

/// C44: the session list is the only scroll view on this surface that carries a
/// scroll-edge treatment, and only on its bottom edge — `.soft` on macOS 26, a
/// painted `Ink.surface` fade on macOS 14. The fade is a no-op wherever the list
/// is shorter than its viewport, because it dissolves into the card's own ground.
struct ListScrollEdge: ViewModifier {
    private var a11y = A11y()

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !RenderOverrides.forceLegacyGlass {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [a11y.surface.opacity(0), a11y.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: VoiceourMetrics.Space.xl)
                .allowsHitTesting(false)
            }
        }
    }
}

/// The list viewport's own coordinate space. A row's frame resolved in it is
/// measured from the clip rect, not from the top of the document, so it answers
/// "is this still on screen" at any scroll offset.
let sessionListSpace = "sessions.list"

/// A day header is a promise that rows follow it, and at the clip line that
/// promise can go unkept: the header lands inside the viewport while the first
/// row it introduces falls entirely below it, leaving a section title hard
/// against the card's bottom edge with nothing under it. That header stops
/// painting. It keeps its slot, because suppressing it must not move the rows
/// and re-decide the question.
///
/// The test is deliberately narrow. A header wholly below the fold is already
/// invisible, so hiding it would buy no pixels and would only cost it its place
/// in the accessibility tree — where, like the rows under it, it is still worth
/// reaching.
struct SessionDayHeader: View {
    var title: String
    var viewportHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(sessionListSpace))
            let isOrphaned =
                frame.minY < viewportHeight
                && frame.maxY + VoiceourMetrics.Space.sm >= viewportHeight
            Text(title)
                .roleStyle(.eyebrow)
                .frame(height: VoiceourMetrics.Space.xl, alignment: .bottomLeading)
                .opacity(isOrphaned ? 0 : 1)
        }
        .frame(height: VoiceourMetrics.Space.xl)
    }
}

struct RecentSessionRow: View {
    var session: RecentSession

    private var previewText: String {
        let collapsed = session.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty transcript" : collapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(SessionsFormatters.timestamp.string(from: session.createdAt))
                    .roleStyle(.bodyMono)
                    .foregroundStyle(VoiceourPalette.Text.monoStrong)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: VoiceourMetrics.Space.sm)
                if session.mutedDuringCapture {
                    Image(systemName: "mic.slash.fill")
                        .font(VoiceourTypography.caption)
                        .foregroundStyle(VoiceourPalette.Text.low)
                        .help("System audio muted for this recording.")
                        .accessibilityLabel("Recorded with system audio muted")
                }
                if let outcome = session.outcome {
                    StatusChip(label: outcome.chip.label, mode: outcome.chip.mode, size: .compact)
                }
                StatusChip(
                    label: SessionsFormatters.wordCountLabel(session.wordCount),
                    mode: .neutral,
                    size: .compact
                )
            }

            Text(previewText)
                .font(VoiceourTypography.body)
                .lineLimit(1)
                .foregroundStyle(VoiceourPalette.Text.mid)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, VoiceourMetrics.Space.md)
        .padding(.vertical, VoiceourMetrics.Space.sm)
        .frame(minHeight: VoiceourMetrics.Space.section + VoiceourMetrics.Space.xl, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let prefix =
            "\(SessionsFormatters.timestamp.string(from: session.createdAt)), \(SessionsFormatters.wordCountLabel(session.wordCount, pluralOnly: true))"
        if session.mutedDuringCapture {
            return "\(prefix), recorded with system audio muted, \(previewText)"
        }
        return "\(prefix), \(previewText)"
    }
}

/// The list's filter. `GlassTextFieldStyle` has no leading/trailing slot, so this
/// composes the same primitives it does — `PlateSurface(.input)` at the derived
/// radius, `Control.medium` height, the shared `ControlState` ladder — around a
/// magnifier mark and a clear affordance, rather than shipping a bare box that
/// cannot say what it is or be emptied.
struct SessionSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var submit: () -> Void

    static let placeholder = "Search transcripts or timestamps"

    private var a11y = A11y()
    @State private var isHovering = false

    init(text: Binding<String>, focus: FocusState<Bool>.Binding, submit: @escaping () -> Void) {
        _text = text
        self.focus = focus
        self.submit = submit
    }

    private var state: ControlState {
        ControlState.resolve(isFocused: focus.wrappedValue, isHovering: isHovering)
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: VoiceourMetrics.Icon.row, weight: .medium))
                .foregroundStyle(a11y.textLow)
                .accessibilityHidden(true)

            TextField(
                Self.placeholder,
                text: $text,
                prompt: Text(Self.placeholder).foregroundStyle(a11y.textLow)
            )
            .textFieldStyle(.plain)
            .font(VoiceourTypography.bodyMono)
            .foregroundStyle(VoiceourPalette.Text.high)
            .focused(focus)
            .focusEffectDisabled()
            .onSubmit(submit)

            if !text.isEmpty {
                RowIconButton(
                    systemName: "xmark",
                    accessibilityLabel: "Clear search",
                    accessibilityIdentifier: "sessions.search.clear"
                ) {
                    text = ""
                }
            }
        }
        .padding(.leading, VoiceourMetrics.TextField.horizontal)
        .padding(.trailing, text.isEmpty ? VoiceourMetrics.TextField.horizontal : VoiceourMetrics.Space.xs)
        .frame(height: VoiceourMetrics.Control.medium)
        .plateSurface(
            kind: .input,
            cornerRadius: sessionWellRadius,
            state: state,
            baseState: isHovering ? .hover : .rest
        )
        .contentShape(RoundedRectangle(cornerRadius: sessionWellRadius, style: .continuous))
        .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
        .onHover { isHovering = $0 }
    }
}
