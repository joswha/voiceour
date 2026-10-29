import AppKit
import QuartzCore
import SwiftUI
import VoiceCore

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

/// The AppKit edge that binds mercury presentation to the display containing the view.
/// SwiftUI updates only its drive configuration; no frame index enters the view graph.
@MainActor
final class MercurySurfaceView: NSView {
    struct Configuration {
        var seed: UInt64
        var world: MercuryWorld
        var drive: MercurySimulation.Drive
        var appearance: MercuryAppearance
        /// The canvas the image covers and the spine the body lies along.
        var layout: RecordingOverlayLayout
        var pinnedStep: Int?
    }

    private let engine: MercuryEngine
    private var configuration: Configuration?
    private var screenLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    /// Never reset, least of all when the link is rebuilt for a new screen. The new display's
    /// frames are counted from the epoch the old one's were, so the hand-off neither drops a
    /// substep nor presents one twice, and a new link that starts late is a stall the clock
    /// absorbs without fast-forwarding the body.
    private var clock = MercuryClock()
    private var currentImage: CGImage?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(seed: UInt64, world: MercuryWorld, hitRegion: MercuryHitRegion) {
        engine = MercuryEngine(seed: seed, world: world, hitRegion: hitRegion)
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
        self.configuration = configuration
        if let step = configuration.pinnedStep {
            screenLink?.isPaused = true
            setImage(
                engine.pinnedFrame(
                    step: step,
                    seed: configuration.seed,
                    world: configuration.world,
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
        if currentImage == nil {
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
        guard window != nil, let configuration, configuration.pinnedStep == nil else {
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
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        renderLive(steps: clock.steps(forTargetTimestamp: link.targetTimestamp))
    }

    private func renderLive(steps: Int) {
        guard let configuration, configuration.pinnedStep == nil else { return }
        setImage(
            engine.frame(
                advancing: steps,
                seed: configuration.seed,
                world: configuration.world,
                drive: configuration.drive,
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
            world: configuration.world,
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
