import AppKit
import QuartzCore
import SwiftUI

/// The rate the display link asks the attached display for.
///
/// Presentation follows the screen, capped at 120 fps. Physics never changes step size:
/// `MercuryClock` counts fixed 120 Hz substeps against each frame's target timestamp, so
/// past 120 fps some frames would carry no new substep and only repeat the image before
/// them. A screen that reports no maximum gets 60.
enum MercuryFrameRate {
    static func presentationFramesPerSecond(screenMaximum: Int) -> Int {
        guard screenMaximum > 0 else { return 60 }
        return Swift.min(screenMaximum, 120)
    }

    static func preferredFrameRateRange(screenMaximum: Int) -> CAFrameRateRange {
        let target = Float(
            presentationFramesPerSecond(screenMaximum: screenMaximum)
        )
        return CAFrameRateRange(
            minimum: target,
            maximum: target,
            preferred: target
        )
    }
}

enum MercuryLayerPresenter {
    @inline(__always)
    static func present(_ image: CGImage?, on layer: CALayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

/// What one presented live frame shows: how much mercury, and on which substep of the clock.
///
/// The controller conducts hand-offs between displays on the substep clock, against the body's
/// volume, and each report is its cue to re-read the pointer against the field the frame just
/// handed the hit region.
struct MercuryFrameReport: Equatable, Sendable {
    /// `L·H` of the presented geometry, pt².
    var volume: Double
    /// `MercuryClock.presentedStep`: substeps presented since the surface's first frame.
    var step: Int
}

/// The AppKit edge that binds mercury presentation to the display containing the view.
/// SwiftUI updates only its drive configuration; no frame index enters the view graph.
@MainActor
final class MercurySurfaceView: NSView {
    /// `replayGeneration` is a counter the owner bumps to replay the outcome gesture from
    /// `replaySource`: every increase replays once. The recording island never replays and
    /// leaves it at 0.
    ///
    /// The owner sets `isSuspended` while the surface cannot be seen. A suspended surface
    /// keeps its last image, runs no display link and draws nothing, live or pinned, until a
    /// configuration clears it. The update that clears it draws the current configuration at
    /// once, so the kept image never stands in for a newer look. The recording island
    /// leaves it false.
    struct Configuration {
        var seed: UInt64
        var look: MercuryLook
        var drive: MercurySimulation.Drive
        var appearance: MercuryAppearance
        /// The canvas the image covers and the spine the body lies along.
        var layout: RecordingOverlayLayout
        var pinnedStep: Int?
        var isSuspended = false
        var replayGeneration: Int = 0
        var replaySource: MercuryPose?
        /// Called after each frame the display link presents. Never for a pinned harness frame,
        /// which has no clock, and never for the image a new surface draws inside SwiftUI's update
        /// pass, where what the controller does with a report — re-frame, re-gate, re-pose — would
        /// publish model changes from within a view update.
        var onFrame: (@MainActor (MercuryFrameReport) -> Void)?
        /// What the body feels of the panel it is drawn in, read once per live frame for the forcing
        /// that frame advances under, in place of the drive's own. Never for a pinned harness frame,
        /// and nil in the harness, which moves no panel.
        var panelMotion: MercuryPanelMotion?
    }

    private let engine: MercuryEngine
    private var configuration: Configuration?
    /// Taken from the first configuration, never replayed on: a view that appears after
    /// earlier replays — scrolled back in, or rebuilt by SwiftUI — must not replay on
    /// arrival.
    private var lastReplayGeneration: Int?
    private var screenLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    /// Never reset, least of all when the link is rebuilt for a new screen; the new link's first
    /// frame re-phases it instead. Counted on the old display's grid, a display whose vsyncs fall
    /// half a substep off it puts its frames on rounding boundaries, where jitter splits an even
    /// cadence into 1s and 3s for as long as the panel stays there. The re-phase moves the epoch
    /// by at most half a substep, so the hand-off neither drops a substep nor presents one twice,
    /// and a new link that starts late is a stall the clock absorbs without fast-forwarding the
    /// body.
    private var clock = MercuryClock()
    /// True from a link's creation until its first callback, which re-phases the clock.
    private var linkIsNew = false
    /// The image on the layer.
    private(set) var currentImage: CGImage?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(seed: UInt64, look: MercuryLook, hitRegion: MercuryHitRegion) {
        engine = MercuryEngine(seed: seed, look: look, hitRegion: hitRegion)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.contentsScale = MercuryMetrics.rasterScale
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        screenObserver.map(NotificationCenter.default.removeObserver)
        screenObserver = nil
        if let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuildDisplayLink()
                }
            }
        }
        rebuildDisplayLink()
    }

    func update(_ configuration: Configuration) {
        let wasSuspended = self.configuration?.isSuspended ?? false
        self.configuration = configuration
        if let lastReplayGeneration, configuration.replayGeneration > lastReplayGeneration {
            engine.replayGesture(from: configuration.replaySource)
        }
        lastReplayGeneration = configuration.replayGeneration
        if configuration.isSuspended {
            screenLink?.isPaused = true
            return
        }
        if let step = configuration.pinnedStep {
            screenLink?.isPaused = true
            setImage(
                engine.pinnedFrame(
                    step: step,
                    seed: configuration.seed,
                    look: configuration.look,
                    drive: configuration.drive,
                    appearance: configuration.appearance,
                    layout: configuration.layout
                )
            )
            return
        }

        if screenLink == nil, window != nil {
            rebuildDisplayLink()
        } else {
            screenLink?.isPaused = false
        }
        // The link's first callback is a frame away, so a surface with no image yet, or one
        // leaving suspension, draws now rather than show nothing or its kept image until then.
        if currentImage == nil || wasSuspended {
            renderLive(steps: 0)
        }
    }

    func stop() {
        screenLink?.invalidate()
        screenLink = nil
        screenObserver.map(NotificationCenter.default.removeObserver)
        screenObserver = nil
    }

    private func rebuildDisplayLink() {
        screenLink?.invalidate()
        screenLink = nil
        guard window != nil, let configuration, configuration.pinnedStep == nil, !configuration.isSuspended else {
            return
        }

        let link = displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        let maximum = window?.screen?.maximumFramesPerSecond ?? 60
        link.preferredFrameRateRange = MercuryFrameRate.preferredFrameRateRange(
            screenMaximum: maximum
        )
        link.add(to: .main, forMode: .common)
        screenLink = link
        linkIsNew = true
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        if linkIsNew {
            linkIsNew = false
            renderLive(steps: clock.rephase(forTargetTimestamp: target))
        } else {
            renderLive(steps: clock.steps(forTargetTimestamp: target))
        }
        reportLiveFrame()
    }

    /// Last in the callback: a report can re-frame the panel onto another display, and the screen
    /// change rebuilds the link that is calling.
    private func reportLiveFrame() {
        guard let configuration, configuration.pinnedStep == nil, let onFrame = configuration.onFrame else {
            return
        }
        onFrame(MercuryFrameReport(volume: engine.liveVolume, step: clock.presentedStep))
    }

    /// One live frame. The display link supplies `steps`; tests step a view that has no
    /// window through here. A pinned or suspended configuration draws nothing here.
    func renderLive(steps: Int) {
        guard let configuration, configuration.pinnedStep == nil, !configuration.isSuspended else { return }
        var drive = configuration.drive
        if let panelMotion = configuration.panelMotion {
            drive.forcing = panelMotion.forcing(advancing: steps, layout: configuration.layout)
        }
        setImage(
            engine.frame(
                advancing: steps,
                seed: configuration.seed,
                look: configuration.look,
                drive: drive,
                appearance: configuration.appearance,
                layout: configuration.layout
            )
        )
    }

    private func setImage(_ image: CGImage?) {
        guard image !== currentImage else { return }
        currentImage = image
        MercuryLayerPresenter.present(image, on: layer)
    }
}

struct MercurySurface: NSViewRepresentable {
    var configuration: MercurySurfaceView.Configuration
    let hitRegion: MercuryHitRegion

    func makeNSView(context: Context) -> MercurySurfaceView {
        MercurySurfaceView(
            seed: configuration.seed,
            look: configuration.look,
            hitRegion: hitRegion
        )
    }

    func updateNSView(_ view: MercurySurfaceView, context: Context) {
        view.update(configuration)
    }

    static func dismantleNSView(_ view: MercurySurfaceView, coordinator: Void) {
        view.stop()
    }
}
