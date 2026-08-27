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

    /// Which ground this island is painting on, decided once and threaded down, because
    /// every colour on the surface is a function of it. Reduce Transparency outranks both
    /// glass paths on every OS: this is the app's only surface over unpredictable
    /// backdrops and the last place to ignore the setting.
    private var surface: RecordingOverlaySurface {
        if a11y.reduceTransparency {
            return .opaque
        }
        if #available(macOS 26, *), !RenderOverrides.forceLegacyGlass {
            return .systemGlass
        }
        return .painted
    }

    /// One capsule, one material, nothing drawn on top of it.
    ///
    /// The island casts no app-drawn shadow on any path. On macOS 26 that is because
    /// Liquid Glass already casts its own, and it is adaptive — it gains opacity over text
    /// and loses it over a solid light background, which is exactly the judgement an app
    /// cannot make for itself. Two static black blurs were previously stacked on top of
    /// the material, and because `.shadow` cannot recover a capsule's alpha out of a glass
    /// effect, Core Animation cast them from the view's rectangular layer bounds: a 216x76
    /// smudge around a 180x34 pill. On the painted and opaque grounds there is no shadow
    /// either, because the frost, the tint and the two rims already give the silhouette
    /// its separation and a black blur was never what made those readable.
    ///
    /// The effect is applied to the assembled row rather than to the readout alone, so the
    /// two controls are content ON the material and receive its automatic vibrancy
    /// treatment instead of being composited above it as unrelated siblings.
    @ViewBuilder
    private var island: some View {
        if #available(macOS 26, *), surface == .systemGlass {
            // Plain `.regular`, measured rather than assumed: `.interactive()` is inert on
            // this surface. Every press outside the two control rects leaves
            // `RecordingOverlayHostingView.mouseDown` for `window.performDrag` without
            // calling super, so SwiftUI never sees the press the modifier animates.
            // Holding a real mouse-down on the live pill over a bright backdrop left the
            // surface pixel-identical to `.regular` everywhere but the animating waveform
            // row, and the drag still landed to the pixel. It does not fight the drag; it
            // just buys nothing. `.regular` is also the documented choice over content the
            // app cannot predict, and it is left untinted because nothing about the
            // island's whole surface carries meaning — the marks inside it do.
            islandRow.glassEffect(.regular, in: .capsule)
        } else {
            islandRow.background { capsuleSurface }
        }
    }

    /// The island's contents at its own measure. Both caps are placed from
    /// `RecordingOverlayMetrics.controlInboardOffset`, the same value the panel's mouse
    /// routing reads, so the discs are concentric with their caps and the clickable rects
    /// land on the discs the user can see.
    ///
    /// While an outcome is showing there are no controls at all: the moment is a report,
    /// not a prompt, and the controller makes the panel click-through for its duration so
    /// it cannot swallow a click meant for the app underneath.
    private var islandRow: some View {
        centerSlot
            .padding(.horizontal, model.outcome == nil ? RecordingOverlayMetrics.controlSlot : 0)
            .frame(
                width: RecordingOverlayMetrics.islandSize.width,
                height: RecordingOverlayMetrics.islandSize.height
            )
            .overlay(alignment: .leading) {
                if model.outcome == nil {
                    cancelButton
                        .padding(.leading, RecordingOverlayMetrics.controlInboardOffset)
                }
            }
            .overlay(alignment: .trailing) {
                if model.outcome == nil {
                    trailingSlot
                        .padding(.trailing, RecordingOverlayMetrics.controlInboardOffset)
                }
            }
            .animation(
                a11y.reduceMotion ? nil : VoiceourMotion.deliberate,
                value: model.centerPhaseToken
            )
    }

    /// The macOS 14/15 and Reduce Transparency grounds.
    ///
    /// Under Reduce Transparency the two translucent layers collapse to one opaque capsule
    /// and the `.plusLighter` specular goes: `Line.edge` replaces it so the silhouette
    /// survives on a dark desktop, since `Ink.rimDark` alone would be a black line on a
    /// black pill.
    @ViewBuilder
    private var capsuleSurface: some View {
        if surface == .opaque {
            ZStack {
                Capsule(style: .continuous)
                    .fill(VoiceourPalette.Ink.void)

                Capsule(style: .continuous)
                    .strokeBorder(
                        a11y.lineEdge,
                        lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    )
            }
            .allowsHitTesting(false)
        } else {
            ZStack {
                // (1) Behind-window frost — the real material on this path. The CALayer
                //     corner radius masks it; a second .clipShape would be a second mask
                //     with a second curve model over the same layer.
                FrostedGlassBackground(
                    cornerRadius: RecordingOverlayMetrics.islandSize.height / 2
                )

                // (2) Arctic tint — a cold blue-white gradient with a darkened floor so
                //     white glyphs and the meter always sit on a clean, legible field.
                Capsule(style: .continuous)
                    .fill(VoiceourPalette.glassTint)

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

                definitionRim
            }
            .allowsHitTesting(false)
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
        if let outcome = model.outcome {
            outcomeReadout(outcome)
                .transition(.opacity)
        } else if model.isWarmingUp {
            // Warm-up and live capture used to share ONE view identity, on the reasoning
            // that the meter was already on screen and simply came alive as buffers
            // arrived. That was decided while warm-up was believed to be sub-100ms,
            // because liveness was measured off the first tap callback rather than the
            // first buffer holding a non-zero sample. Measured properly, a cold Bluetooth
            // link reaches real audio at 1422 ms (AirPods Max) against 99 ms on the
            // built-in microphone, and a flat meter held for a second and a half is
            // pixel-indistinguishable from a live meter listening to silence — so the
            // user speaks into the hole. A word says which one it is.
            stateLabel(model.warmingLabel)
                .transition(.opacity)
        } else if model.isRecording {
            RecordingWaveform(
                samples: model.samples,
                isSpeaking: model.isSpeaking,
                surface: surface
            )
            .transition(.opacity)
        } else if model.isProcessing {
            stateLabel(model.processingLabel ?? "")
                .transition(.opacity)
        } else {
            Color.clear
                .transition(.opacity)
        }
    }

    /// An unclean delivery, held long enough to read. A symbol and a word, never a hue
    /// alone: Differentiate Without Color has to be able to tell these apart, and so does
    /// anyone glancing at a 34pt pill from across a display.
    private func outcomeReadout(_ outcome: RecordingOverlayOutcome) -> some View {
        let color = outcome.isFailure ? surface.destroy : surface.caution
        return HStack(spacing: VoiceourMetrics.Space.xs) {
            Image(systemName: outcome.symbol)
                .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(outcome.word)
                .roleStyle(.micro)
                // The symbol carries the semantic hue; the 10pt word uses the
                // ground's neutral label so it gets system vibrancy on adaptive
                // glass and Text.high on the two near-black fallbacks. A fixed
                // amber or crimson cannot clear AA against both near-black and
                // pure white after text antialiasing, and hue is never the only
                // carrier here anyway.
                .foregroundStyle(surface.label)
                .lineLimit(1)
        }
    }

    /// Inside the capsule, where it composites against the island's own ground rather than
    /// against an arbitrary wallpaper — which measured 1.21:1 on a mid-grey desktop.
    /// `surface.label` is what keeps that true on all three grounds: the near-white
    /// `Text.high` this used to name is correct on the two dark ones and invisible on
    /// macOS 26's material over a light desktop.
    ///
    /// Static by construction: the only animation is the crossfade between two texts.
    /// Nothing here may breathe on a repeating or wall-clock-driven curve, because the
    /// warm-up word is now snapshotted by a scene golden.
    private func stateLabel(_ text: String) -> some View {
        Text(text)
            .roleStyle(.micro)
            .foregroundStyle(surface.label)
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
            surface: surface,
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
                surface: surface,
                accessibilityLabel: "Finish recording",
                help: "Stop recording and transcribe",
                action: onFinish
            )
            .accessibilitySortPriority(1)
            .transition(.opacity)
        } else if model.isProcessing {
            // The working mark takes the finish action's own slot while that action is
            // unavailable, so the pill keeps one silhouette in every state and the work
            // reads as happening where the confirm used to be. The slot used to hold a
            // 28pt Color.clear, which left 52pt of bare surface against 16pt on the other
            // side for the whole of every processing phase.
            RecordingWorkMark(surface: surface)
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
