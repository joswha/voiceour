import SwiftUI
import VoiceCore

/// The transcript block: the chips that classify the capture, the text itself,
/// the metadata that annotates it and the two actions that act on it. It draws
/// no surface of its own. The SESSION card it fills *is* the content surface,
/// and a second bounded box around the whole card body would group nothing the
/// card does not already group while spending a brighter rim and a wider pad to
/// do it (architecture-decision §3).
struct TranscriptCard: View {
    var session: RecentSession
    var isCopied: Bool
    var isTeachEditorOpen: Bool
    var copy: () -> Void
    var delete: () -> Void
    var teach: () -> Void
    var onFixTeachWord: (String) -> Void

    /// Past this ceiling the transcript scrolls inside a fixed reading window;
    /// under it the text hugs, so a ten-word session gets a ten-word block and
    /// the metadata flows directly beneath it rather than after a fixed void.
    private static let maximumViewport = VoiceOourMetrics.Space.section * 8

    private var a11y = A11y()
    @State private var measuredTextHeight: CGFloat = 0
    @State private var selectedSurface: String?

    init(
        session: RecentSession,
        isCopied: Bool,
        isTeachEditorOpen: Bool,
        copy: @escaping () -> Void,
        delete: @escaping () -> Void,
        teach: @escaping () -> Void,
        onFixTeachWord: @escaping (String) -> Void
    ) {
        self.session = session
        self.isCopied = isCopied
        self.isTeachEditorOpen = isTeachEditorOpen
        self.copy = copy
        self.delete = delete
        self.teach = teach
        self.onFixTeachWord = onFixTeachWord
    }

    private var displayText: String {
        session.text.isEmpty ? "Empty transcript" : session.text
    }

    /// A one-line transcript gets a one-line viewport; past the ceiling the text
    /// scrolls inside a fixed reading window.
    private var viewportHeight: CGFloat {
        min(max(measuredTextHeight, VoiceOourMetrics.Space.lg), Self.maximumViewport)
    }

    private var rawTranscript: String? {
        guard let raw = session.rawTranscript,
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                != session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return raw
    }

    private var visibleSelectedSurface: String? {
        isTeachEditorOpen ? nil : selectedSurface
    }

    private var shouldShowRefinementMetadata: Bool {
        guard let refinement = session.refinement else { return false }
        guard refinement.kind == .skipped else { return true }
        let reasonWords =
            refinement.reason?
            .lowercased()
            .split(whereSeparator: { !$0.isLetter }) ?? []
        // Production emits "disabled"; the harness fixture predates it and says
        // "refiner disabled", so match the shared reason word.
        return !reasonWords.contains("disabled")
    }

    /// A `Grid` with every row suppressed still occupies a child slot in the
    /// stack below, so the card would spend a full `Space.md` step on nothing.
    private var hasMetadata: Bool {
        shouldShowRefinementMetadata || session.stages != nil || rawTranscript != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.lg) {
            chips
            transcript
            if let surface = visibleSelectedSurface {
                teachSelectionBar(surface)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.md) {
                if hasMetadata {
                    metadata
                }
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The block no longer paints a background, so give the right-click menu
        // an explicit shape rather than only the glyphs the text happens to fill.
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy transcript", action: copy)
            Button("Fix / Teach a word", action: teach)
            Button("Delete session", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
        .accessibilityValue(
            "\(session.wordCount) \(session.wordCount == 1 ? "word" : "words"), recorded \(SessionsFormatters.detailStamp.string(from: session.createdAt))"
        )
        .animation(
            a11y.reduceMotion ? nil : VoiceOourMotion.quick,
            value: visibleSelectedSurface
        )
        .onChange(of: session.id) {
            selectedSurface = nil
        }
    }

    private var chips: some View {
        HStack(alignment: .center, spacing: VoiceOourMetrics.Space.sm) {
            if session.mutedDuringCapture {
                Image(systemName: "mic.slash.fill")
                    .font(VoiceOourTypography.caption)
                    .foregroundStyle(a11y.textLow)
                    .help("System audio muted for this recording.")
                    .accessibilityLabel("Recorded with system audio muted")
            }
            if let outcome = session.outcome {
                StatusChip(label: outcome.chipLabel, mode: outcome.chipMode)
            }
            if let refinement = session.refinement {
                StatusChip(label: refinement.badgeLabel, mode: refinement.badgeMode)
                    .help(refinement.detailLine)
            }
            if let targetSafety = session.outcome?.targetSafety, targetSafety != .normalText {
                StatusChip(label: "TARGET \(targetSafety.displayLabel)", mode: .neutral)
            }
            StatusChip(label: "\(session.wordCount) \(session.wordCount == 1 ? "word" : "words")", mode: .neutral)
        }
    }

    private var transcript: some View {
        ScrollView {
            SelectableTranscriptText(
                identity: session.id,
                text: displayText,
                onFixTeach: onFixTeachWord,
                onSelectionChange: { selectedSurface = $0 }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptTextHeight.self, value: proxy.size.height)
                }
            }
        }
        .frame(height: viewportHeight)
        .onPreferenceChange(TranscriptTextHeight.self) { height in
            measuredTextHeight = height
        }
    }

    /// Label column and value column, one grid, so the timings row stops starting
    /// under the refinement row's *label*.
    private var metadata: some View {
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: VoiceOourMetrics.Space.md,
            verticalSpacing: VoiceOourMetrics.Space.xs
        ) {
            if let refinement = session.refinement, shouldShowRefinementMetadata {
                metadataRow("REFINEMENT", refinement.detailLine)
            }
            if let stages = session.stages {
                metadataRow("TIMINGS", stages.detailLine)
            }
            if let rawTranscript {
                metadataRow("RAW", rawTranscript, mono: true)
            }
        }
    }

    /// The two safe actions sit with the text they act on, on the transcript's own
    /// left edge — not in a strip at the detail card's bottom edge, and not
    /// disguised as a fourth read-only badge in the metadata row.
    private var actions: some View {
        HStack(spacing: VoiceOourMetrics.Space.sm) {
            Button(isCopied ? "COPIED" : "COPY", action: copy)
                .buttonStyle(GlassButtonStyle(kind: .ghost))
                .help("Copy the full transcript to the clipboard.")
                .accessibilityLabel(isCopied ? "Copied to clipboard" : "Copy transcript")
            if visibleSelectedSurface == nil {
                Button("FIX / TEACH", action: teach)
                    .buttonStyle(GlassButtonStyle(kind: .ghost))
                    .help("Teach a correction for a word in this transcript. Right-click a word to prefill it.")
            }
        }
    }

    private func teachSelectionBar(_ surface: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.sm) {
            Text("DETECTED AS")
                .roleStyle(.eyebrow)
            Text(surface)
                .font(VoiceOourTypography.bodyMono)
                .foregroundStyle(VoiceOourPalette.Text.monoStrong)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(surface)

            Spacer()

            Button("TEACH") {
                onFixTeachWord(surface)
            }
            .buttonStyle(GlassButtonStyle(kind: .accent))
            .accessibilityIdentifier("sessions.transcript.teachSelection")
            .accessibilityLabel("Teach correction for detected surface \(surface)")
        }
        .padding(VoiceOourMetrics.Space.md)
        .plateSurface(kind: .well, cornerRadius: sessionWellRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label)
                .roleStyle(.eyebrow)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? VoiceOourTypography.bodyMono : VoiceOourTypography.caption)
                .foregroundStyle(mono ? VoiceOourPalette.Text.low : a11y.textMid)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

/// The transcript's laid-out height, read back so its viewport can hug it.
private struct TranscriptTextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
