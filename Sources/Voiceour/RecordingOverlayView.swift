import SwiftUI
import VoiceCore

/// The recording island, or the collar it becomes around a camera housing.
///
/// One borderless liquid-mercury body and one invisible accessibility element over it.
/// There is no capsule, no control disc, no waveform, no work mark, and no painted word
/// or symbol: every state the island reports — warming, listening, speaking, working, and
/// the three unclean deliveries — is carried by how much mercury there is and what it is
/// doing. What a VoiceOver reader hears is unchanged, because that never came from the
/// pixels: it comes from this element's label and value, and from named actions: Finish and
/// Cancel where the two discs used to be, and Dock island while the island is free.
///
/// Every measure comes from `model.layout`: the panel, the canvas the body is drawn on, and
/// the status element's fixed frame.
///
/// Internal rather than private so the offscreen UI harness can render the overlay
/// without launching the panel controller.
struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    let onCancel: () -> Void
    let onFinish: () -> Void
    /// Docks a free island, as releasing it onto its dock anchor would.
    let onDock: () -> Void
    /// The silhouette the panel routes the mouse against. The harness renders this view
    /// directly and never instantiates the hosting view, so it owns one of its own.
    let hitRegion: MercuryHitRegion
    /// What the body feels of its panel, read by the surface once per live frame. The harness
    /// moves no panel and leaves it nil.
    let panelMotion: MercuryPanelMotion?
    /// Read per frame rather than passed as a value, so the debug picker and a new
    /// session's world both arrive without a notification path.
    let world: @MainActor () -> MercuryWorld
    let seed: @MainActor () -> UInt64
    /// Told what each live frame shows, for the controller's hand-offs and pointer gate. The
    /// harness renders pinned frames, which report nothing, and leaves it nil.
    let onFrame: (@MainActor (MercuryFrameReport) -> Void)?
    /// Harness seam: renders the canvas alone, at the layout's `canvasRect` size, instead of
    /// the panel that frames it. Production never sets this.
    let islandOnly: Bool

    @MainActor
    init(
        model: RecordingOverlayModel,
        onCancel: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onDock: @escaping () -> Void,
        hitRegion: MercuryHitRegion? = nil,
        panelMotion: MercuryPanelMotion? = nil,
        world: @escaping @MainActor () -> MercuryWorld = { RenderOverrides.mercuryWorld ?? .default },
        seed: @escaping @MainActor () -> UInt64 = { RenderOverrides.mercurySeed ?? MercuryMetrics.defaultSeed },
        onFrame: (@MainActor (MercuryFrameReport) -> Void)? = nil,
        islandOnly: Bool = false
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onFinish = onFinish
        self.onDock = onDock
        // The harness renders this view directly and never instantiates the hosting
        // view, so it gets a region of its own rather than a nil one to special-case.
        self.hitRegion = hitRegion ?? MercuryHitRegion()
        self.panelMotion = panelMotion
        self.world = world
        self.seed = seed
        self.onFrame = onFrame
        self.islandOnly = islandOnly
    }

    @ViewBuilder
    var body: some View {
        if islandOnly {
            canvas
        } else {
            let layout = model.layout
            canvas
                .padding(.leading, layout.canvasRect.minX)
                .padding(.top, layout.canvasRect.minY)
                .frame(
                    width: layout.panelSize.width,
                    height: layout.panelSize.height,
                    alignment: .topLeading
                )
                .background(Color.clear)
        }
    }

    /// Idle with nothing to report draws nothing and publishes nothing: no body, no
    /// status element, and an emptied hit region, so a click lands on the app underneath.
    ///
    /// A dismissal keeps the body — the same surface, so the same simulation — while the panel
    /// fades, for it to swallow itself in the idle pose. It publishes the status element only for
    /// an outcome still latched there: a paste or a cancel has nothing left to report.
    @ViewBuilder
    private var canvas: some View {
        let reports = model.state.isActive || model.outcome != nil
        if reports || model.isDismissing {
            MercuryRibbon(
                model: model,
                hitRegion: hitRegion,
                panelMotion: panelMotion,
                world: world,
                seed: seed,
                onFrame: onFrame
            )
            .overlay(alignment: .topLeading) {
                if reports {
                    statusElement
                }
            }
        } else {
            Color.clear
                .frame(
                    width: model.layout.canvasRect.width,
                    height: model.layout.canvasRect.height
                )
                .onAppear { hitRegion.clear() }
        }
    }

    /// One accessibility element for the whole body, at the layout's fixed status frame so
    /// the VoiceOver cursor stays still while the body breathes: the island's 180×34
    /// envelope, centred in its wider canvas, or the collar's chin strip directly under the
    /// housing.
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
    ///
    /// A free island adds "Dock island" after them, the one way to send it home without
    /// dragging it there: a session's own actions come first, and an outcome offers none.
    private var statusElement: some View {
        let layout = model.layout
        return Color.clear
            .frame(width: layout.statusRect.width, height: layout.statusRect.height)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("overlay.status")
            .accessibilityLabel("Dictation status")
            .accessibilityValue(model.accessibilityStatus)
            .accessibilityAddTraits([.updatesFrequently, .isStaticText])
            .accessibilityHint(accessibilityHint)
            // Declared in reverse because SwiftUI publishes custom actions in reverse
            // declaration order: a VoiceOver reader reaches the affirmative action first,
            // then cancel, then docking. `overlay.recording.actions` locks the published
            // order of the first two, and `RecordingOverlayDockActionTests` all three.
            .accessibilityActions {
                if model.isFree, model.state.isActive {
                    Button("Dock island") { onDock() }
                }
                if model.state.isActive {
                    Button(model.isRecording ? "Cancel recording" : "Cancel dictation") { onCancel() }
                }
                if model.isRecording {
                    Button("Finish recording") { onFinish() }
                }
            }
            // Outside the element, so its frame stays the status rect alone: this only
            // places it inside the canvas it overlays.
            .padding(.leading, layout.statusRect.minX - layout.canvasRect.minX)
            .padding(.top, layout.statusRect.minY - layout.canvasRect.minY)
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
