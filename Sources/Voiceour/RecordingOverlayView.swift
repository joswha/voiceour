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
            VStack(spacing: 6) {
                island
            }
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
                    islandShadow(
                        centerSlot
                            .padding(.horizontal, RecordingOverlayMetrics.controlSlot)
                            .frame(
                                width: RecordingOverlayMetrics.islandSize.width,
                                height: RecordingOverlayMetrics.islandSize.height
                            )
                            // Plain `.regular`, measured rather than assumed:
                            // `.interactive()` is inert on this surface. Every press
                            // outside the two control rects leaves
                            // `RecordingOverlayHostingView.mouseDown` for
                            // `window.performDrag` without calling super, so SwiftUI
                            // never sees the press the modifier animates, and the two
                            // discs are `.overlay` siblings above this glass rather
                            // than descendants of it. Holding a real mouse-down on the
                            // live pill over a bright backdrop (one host, dark
                            // appearance, 2x) left the surface pixel-identical to
                            // `.regular` everywhere but the animating waveform row,
                            // and the drag still landed to the pixel. It does not
                            // fight the drag; it just buys nothing.
                            .glassEffect(.regular, in: .capsule)
                    )
                )
            }
        } else {
            legacyIsland
        }
    }

    /// Bible §6.4 — the island is the only thing in the app that casts a shadow — and
    /// §21.3 rule 2 keeps that shadow two-layer. The system glass brings none of its own
    /// and the panel is `hasShadow = false` (RecordingOverlayController.makePanel), so
    /// the macOS 26 branch has to spend the same two tokens `capsuleSurface` spends,
    /// and drop the tight inner one under Reduce Transparency for the same reason it
    /// does there. Applied to the capsule, inside the controls: the two discs are
    /// overlaid on top of this and cast nothing, exactly as on the legacy path.
    @ViewBuilder
    private func islandShadow<Surface: View>(_ surface: Surface) -> some View {
        let outer = surface.shadow(
            color: VoiceourMetrics.Shadow.overlayOuter.color,
            radius: VoiceourMetrics.Shadow.overlayOuter.radius,
            y: VoiceourMetrics.Shadow.overlayOuter.y
        )
        if a11y.reduceTransparency {
            outer
        } else {
            outer.shadow(
                color: VoiceourMetrics.Shadow.overlayInner.color,
                radius: VoiceourMetrics.Shadow.overlayInner.radius,
                y: VoiceourMetrics.Shadow.overlayInner.y
            )
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
                a11y.reduceMotion ? nil : VoiceourMotion.deliberate,
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
                .fill(VoiceourPalette.Ink.void)
                .shadow(
                    color: VoiceourMetrics.Shadow.overlayOuter.color,
                    radius: VoiceourMetrics.Shadow.overlayOuter.radius,
                    y: VoiceourMetrics.Shadow.overlayOuter.y
                )
                .allowsHitTesting(false)

            Capsule(style: .continuous)
                .strokeBorder(
                    a11y.lineEdge,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
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
                .fill(VoiceourPalette.glassTint)
                .shadow(
                    color: VoiceourMetrics.Shadow.overlayOuter.color,
                    radius: VoiceourMetrics.Shadow.overlayOuter.radius,
                    y: VoiceourMetrics.Shadow.overlayOuter.y
                )
                .shadow(
                    color: VoiceourMetrics.Shadow.overlayInner.color,
                    radius: VoiceourMetrics.Shadow.overlayInner.radius,
                    y: VoiceourMetrics.Shadow.overlayInner.y
                )
                .allowsHitTesting(false)

            // (3) Specular rim — a hairline highlight, brightest at the top lip.
            Capsule(style: .continuous)
                .strokeBorder(
                    VoiceourPalette.specularRim,
                    lineWidth: max(
                        VoiceourMetrics.Stroke.specular,
                        VoiceourMetrics.Stroke.hairline(a11y.contrast)
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
            .inset(by: VoiceourMetrics.Stroke.hairline)
            .strokeBorder(
                VoiceourPalette.Ink.rimDark,
                lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
            )
            .allowsHitTesting(false)
    }

    /// One accessibility element for the whole readout, so a state change is a VALUE
    /// change on a stable, labelled node instead of a label change on an unlabelled
    /// image that VoiceOver only speaks if the user happens to be parked on it.
    ///
    /// `.isStaticText` is what makes that value reachable at all. Measured against the
    /// in-process accessibility walk this app dumps: without the trait the element is
    /// `AXUnknown` and `accessibilityValue` answers nil through both the modern and the
    /// legacy attribute API, so the readout published a label and nothing else. With it
    /// the element is `AXStaticText`, keeps its content-sized frame, and finally carries
    /// the value — which is the only thing that distinguishes warm-up from listening in
    /// the accessibility tree, since both draw one unlabelled element in this slot.
    private var centerSlot: some View {
        centerContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictation status")
            .accessibilityValue(model.accessibilityStatus)
            .accessibilityAddTraits([.updatesFrequently, .isStaticText])
            .accessibilitySortPriority(2)
    }

    @ViewBuilder
    private var centerContent: some View {
        if model.isWarmingUp {
            // Warm-up and live capture used to share ONE view identity, on the reasoning
            // that the meter was already on screen and simply came alive as buffers
            // arrived. That was decided while warm-up was believed to be sub-100ms,
            // because liveness was measured off the first tap callback rather than the
            // first buffer holding a non-zero sample. Measured properly, a cold Bluetooth
            // link reaches real audio at 1422 ms (AirPods Max) against 99 ms on the
            // built-in microphone, and a flat meter held for a second and a half is
            // pixel-indistinguishable from a live meter listening to silence — so the
            // user speaks into the hole. A word says which one it is. The comet still
            // means exactly one thing: the session is being processed.
            stateLabel(model.warmingLabel)
                .transition(.opacity)
        } else if model.isRecording {
            RecordingWaveform(samples: model.samples)
                .transition(.opacity)
        } else if model.isProcessing {
            stateLabel(model.processingLabel ?? "")
                .transition(.opacity)
        } else {
            Color.clear
                .transition(.opacity)
        }
    }

    /// Inside the capsule, where it composites against the pill's own glass at
    /// Text.high instead of against an arbitrary wallpaper at Text.low — which
    /// measured 1.21:1 on a mid-grey desktop.
    ///
    /// Static by construction: the only animation is the crossfade between two texts.
    /// Nothing here may breathe on a repeating or wall-clock-driven curve, because the
    /// warm-up word is now snapshotted by a scene golden.
    private func stateLabel(_ text: String) -> some View {
        Text(text)
            .roleStyle(.micro)
            .foregroundStyle(VoiceourPalette.Text.high)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(
                a11y.reduceMotion ? nil : VoiceourMotion.deliberate,
                value: text
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
