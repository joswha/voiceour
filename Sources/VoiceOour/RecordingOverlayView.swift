import SwiftUI

// Internal rather than private so the offscreen UI harness can render the
// overlay without launching the panel controller.
struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    let onCancel: () -> Void
    let onFinish: () -> Void
    /// Harness seam: renders the island capsule alone, at its own 180x34
    /// measure, instead of the 260x80 panel that frames it. Production never
    /// sets this, so the shipped layout is unchanged.
    let islandOnly: Bool

    private var a11y = A11y()

    init(
        model: RecordingOverlayModel,
        onCancel: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        islandOnly: Bool = false
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onFinish = onFinish
        self.islandOnly = islandOnly
    }

    @ViewBuilder
    var body: some View {
        if islandOnly {
            island
        } else {
            island
                .padding(.top, RecordingOverlayMetrics.contentTopInset)
                .frame(
                    width: RecordingOverlayMetrics.windowSize.width,
                    height: RecordingOverlayMetrics.windowSize.height,
                    alignment: .top
                )
                .background(Color.clear)
        }
    }

    /// One row, three positions: the discard at the leading cap, the readout in the
    /// centre, and the affirmative action — or, while it is unavailable, the comet —
    /// at the trailing cap. Both caps are placed from
    /// RecordingOverlayMetrics.controlInboardOffset, the same value the panel's mouse
    /// routing reads, so the discs are concentric with their caps and the clickable
    /// rects land on the discs the user can see.
    @ViewBuilder
    private var island: some View {
        if #available(macOS 26, *) {
            if RenderOverrides.forceLegacyGlass {
                legacyIsland
            } else {
                islandControls(
                    centerSlot
                        .padding(.horizontal, RecordingOverlayMetrics.controlSlot)
                        .frame(
                            width: RecordingOverlayMetrics.islandSize.width,
                            height: RecordingOverlayMetrics.islandSize.height
                        )
                        .glassEffect(.regular, in: .capsule)
                )
            }
        } else {
            legacyIsland
        }
    }

    private var legacyIsland: some View {
        islandControls(
            ZStack {
                capsuleSurface
                centerSlot
                    .padding(.horizontal, RecordingOverlayMetrics.controlSlot)
            }
            .frame(
                width: RecordingOverlayMetrics.islandSize.width,
                height: RecordingOverlayMetrics.islandSize.height
            )
        )
    }

    private func islandControls<Surface: View>(_ surface: Surface) -> some View {
        surface
            .overlay(alignment: .leading) {
                cancelButton
                    .padding(.leading, RecordingOverlayMetrics.controlInboardOffset)
            }
            .overlay(alignment: .trailing) {
                trailingSlot
                    .padding(.trailing, RecordingOverlayMetrics.controlInboardOffset)
            }
            .animation(
                a11y.reduceMotion ? nil : VoiceOourMotion.deliberate,
                value: model.centerPhaseToken
            )
    }

    /// Bible §21.3's four layers. Under Reduce Transparency the two glass layers
    /// collapse to one opaque capsule and the .plusLighter specular goes (spec §7.1):
    /// this is the app's only surface over unpredictable backdrops and the last place
    /// to ignore the setting. Line.edge replaces the specular there so the silhouette
    /// survives on a dark desktop, exactly as §1.5 defines an opaque surface —
    /// Ink.rimDark alone would be a black line on a black pill.
    @ViewBuilder
    private var capsuleSurface: some View {
        if a11y.reduceTransparency {
            Capsule(style: .continuous)
                .fill(VoiceOourPalette.Ink.void)
                .shadow(
                    color: VoiceOourMetrics.Shadow.overlayOuter.color,
                    radius: VoiceOourMetrics.Shadow.overlayOuter.radius,
                    y: VoiceOourMetrics.Shadow.overlayOuter.y
                )
                .allowsHitTesting(false)

            Capsule(style: .continuous)
                .strokeBorder(
                    a11y.lineEdge,
                    lineWidth: VoiceOourMetrics.Stroke.hairline(a11y.contrast)
                )
                .allowsHitTesting(false)
        } else {
            // (1) Behind-window frost — the real liquid glass. The CALayer corner
            //     radius masks it; a second .clipShape would be a second mask with a
            //     second curve model over the same layer.
            FrostedGlassBackground(
                cornerRadius: RecordingOverlayMetrics.islandSize.height / 2
            )
            .allowsHitTesting(false)

            // (2) Arctic tint — a cold blue-white gradient with a darkened floor so
            //     white glyphs and the comet always sit on a clean, legible field.
            Capsule(style: .continuous)
                .fill(VoiceOourPalette.glassTint)
                .shadow(
                    color: VoiceOourMetrics.Shadow.overlayOuter.color,
                    radius: VoiceOourMetrics.Shadow.overlayOuter.radius,
                    y: VoiceOourMetrics.Shadow.overlayOuter.y
                )
                .shadow(
                    color: VoiceOourMetrics.Shadow.overlayInner.color,
                    radius: VoiceOourMetrics.Shadow.overlayInner.radius,
                    y: VoiceOourMetrics.Shadow.overlayInner.y
                )
                .allowsHitTesting(false)

            // (3) Specular rim — a hairline highlight, brightest at the top lip.
            Capsule(style: .continuous)
                .strokeBorder(
                    VoiceOourPalette.specularRim,
                    lineWidth: max(
                        VoiceOourMetrics.Stroke.specular,
                        VoiceOourMetrics.Stroke.hairline(a11y.contrast)
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            definitionRim
        }
    }

    /// (4) Definition rim — a thin dark line so the pill keeps a crisp silhouette
    /// against bright wallpapers. Inset at the SHAPE, not with .padding: two
    /// independently padded sub-pixel strokes rasterise out of phase, which is why
    /// the dark line used to land on the left edge only.
    private var definitionRim: some View {
        Capsule(style: .continuous)
            .inset(by: VoiceOourMetrics.Stroke.hairline)
            .strokeBorder(
                VoiceOourPalette.Ink.rimDark,
                lineWidth: VoiceOourMetrics.Stroke.hairline(a11y.contrast)
            )
            .allowsHitTesting(false)
    }

    /// One accessibility element for the whole readout, so a state change is a VALUE
    /// change on a stable, labelled node instead of a label change on an unlabelled
    /// image that VoiceOver only speaks if the user happens to be parked on it.
    private var centerSlot: some View {
        centerContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictation status")
            .accessibilityValue(model.state.displayName)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilitySortPriority(2)
    }

    @ViewBuilder
    private var centerContent: some View {
        if model.isRecording {
            // Warm-up and live capture share ONE view identity: the meter is already
            // on screen when the pill appears and comes alive as buffers arrive,
            // instead of crossfading a comet into a waveform. That also leaves the
            // comet meaning exactly one thing — the session is being processed.
            RecordingWaveform(samples: model.samples)
                .transition(.opacity)
        } else if model.isProcessing {
            stateLabel
                .transition(.opacity)
        } else {
            Color.clear
                .transition(.opacity)
        }
    }

    /// Inside the capsule, where it composites against the pill's own glass at
    /// Text.high instead of against an arbitrary wallpaper at Text.low — which
    /// measured 1.21:1 on a mid-grey desktop.
    private var stateLabel: some View {
        Text(model.processingLabel ?? "")
            .roleStyle(.micro)
            .foregroundStyle(VoiceOourPalette.Text.high)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(
                a11y.reduceMotion ? nil : VoiceOourMotion.deliberate,
                value: model.processingLabel
            )
    }

    private var cancelButton: some View {
        RecordingOverlayButton(
            kind: .cancel,
            accessibilityLabel: model.isRecording ? "Cancel recording" : "Cancel dictation",
            help: "Discard this dictation",
            action: onCancel
        )
        .accessibilitySortPriority(3)
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if model.showsFinishButton {
            RecordingOverlayButton(
                kind: .finish,
                accessibilityLabel: "Finish recording",
                help: "Stop recording and transcribe",
                action: onFinish
            )
            .accessibilitySortPriority(1)
            .transition(.opacity)
        } else if model.isProcessing {
            // The comet takes the finish action's own slot while that action is
            // unavailable, so the pill keeps one silhouette in every state and the
            // work reads as happening where the confirm used to be. The slot used to
            // hold a 28pt Color.clear, which left 52pt of bare gradient against 16pt
            // on the other side for the whole of every processing phase.
            FrostedCometIndicator(head: model.cometHead)
                .transition(.opacity)
        } else {
            Color.clear
                .frame(
                    width: RecordingOverlayMetrics.Disc.hitSize,
                    height: RecordingOverlayMetrics.Disc.hitSize
                )
                .accessibilityHidden(true)
        }
    }
}
