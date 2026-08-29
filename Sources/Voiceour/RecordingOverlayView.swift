import SwiftUI
import VoiceCore

/// The recording island.
///
/// One borderless liquid-mercury body and one invisible accessibility element over it.
/// There is no capsule, no control disc, no waveform, no work mark, and no painted word
/// or symbol: every state the island reports — warming, listening, speaking, working, and
/// the three unclean deliveries — is carried by how much mercury there is and what it is
/// doing. What a VoiceOver reader hears is unchanged, because that never came from the
/// pixels: it comes from this element's label and value, and now from two named actions
/// where the two discs used to be.
///
/// Internal rather than private so the offscreen UI harness can render the overlay
/// without launching the panel controller.
struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    let onCancel: () -> Void
    let onFinish: () -> Void
    /// The silhouette the panel routes the mouse against. The harness renders this view
    /// directly and never instantiates the hosting view, so it owns one of its own.
    let hitRegion: MercuryHitRegion
    /// Read per frame rather than passed as a value, so the debug picker and a new
    /// session's world both arrive without a notification path.
    let world: @MainActor () -> MercuryWorld
    let seed: @MainActor () -> UInt64
    /// Harness seam: renders the island alone, at its own 180x34 measure, instead of the
    /// 260x80 panel that frames it. Production never sets this.
    let islandOnly: Bool

    @MainActor
    init(
        model: RecordingOverlayModel,
        onCancel: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        hitRegion: MercuryHitRegion? = nil,
        world: @escaping @MainActor () -> MercuryWorld = { RenderOverrides.mercuryWorld ?? .default },
        seed: @escaping @MainActor () -> UInt64 = { RenderOverrides.mercurySeed ?? MercuryMetrics.defaultSeed },
        islandOnly: Bool = false
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onFinish = onFinish
        // The harness renders this view directly and never instantiates the hosting
        // view, so it gets a region of its own rather than a nil one to special-case.
        self.hitRegion = hitRegion ?? MercuryHitRegion()
        self.world = world
        self.seed = seed
        self.islandOnly = islandOnly
    }

    @ViewBuilder
    var body: some View {
        if islandOnly {
            island
        } else {
            VStack(spacing: 0) {
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

    /// Idle with nothing to report draws nothing and publishes nothing: no body, no
    /// status element, and an emptied hit region, so a click lands on the app underneath.
    @ViewBuilder
    private var island: some View {
        if model.state.isActive || model.outcome != nil {
            MercuryRibbon(model: model, hitRegion: hitRegion, world: world, seed: seed)
                .overlay { statusElement }
        } else {
            Color.clear
                .frame(
                    width: RecordingOverlayMetrics.islandSize.width,
                    height: RecordingOverlayMetrics.islandSize.height
                )
                .onAppear { hitRegion.clear() }
        }
    }

    /// One accessibility element for the whole island, at a fixed 180x34 frame so the
    /// VoiceOver cursor stays still while the body breathes.
    ///
    /// A state change is a VALUE change on a stable, labelled node instead of a label
    /// change on an unlabelled image that VoiceOver only speaks if the user happens to be
    /// parked on it. `.isStaticText` is what makes that value reachable at all: measured
    /// against the in-process accessibility walk this app dumps, without the trait the
    /// element is `AXUnknown` and `accessibilityValue` answers nil through both the modern
    /// and the legacy attribute API.
    ///
    /// The retired discs' actions move here as named accessibility actions. The element
    /// also publishes one hint that distinguishes the affirmative and destructive
    /// choices. An outcome publishes neither: the moment is a report, not a prompt, and
    /// the panel is click-through for its duration.
    private var statusElement: some View {
        Color.clear
            .frame(
                width: RecordingOverlayMetrics.islandSize.width,
                height: RecordingOverlayMetrics.islandSize.height
            )
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("overlay.status")
            .accessibilityLabel("Dictation status")
            .accessibilityValue(model.accessibilityStatus)
            .accessibilityAddTraits([.updatesFrequently, .isStaticText])
            .accessibilityHint(accessibilityHint)
            // Declared cancel-first because SwiftUI publishes custom actions in reverse
            // declaration order, and a VoiceOver reader should reach the affirmative
            // action first. `overlay.recording.actions` locks the published order.
            .accessibilityActions {
                if model.state.isActive {
                    Button(model.isRecording ? "Cancel recording" : "Cancel dictation") { onCancel() }
                }
                if model.isRecording {
                    Button("Finish recording") { onFinish() }
                }
            }
    }

    private var accessibilityHint: String {
        if model.isRecording {
            return "Use the named actions to finish recording or cancel this dictation."
        }
        if model.state.isActive {
            return "Use the named action to cancel this dictation."
        }
        return ""
    }
}
