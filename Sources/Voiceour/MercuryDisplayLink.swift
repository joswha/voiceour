import AppKit
import QuartzCore
import SwiftUI
import VoiceCore

/// Converts an attached display's cadence into the simulation's fixed 120 Hz clock.
///
/// Presentation follows the screen, capped at 120 fps. Physics never changes step size:
/// a 120 Hz display advances once before each image; a 60 Hz display advances twice.
/// Other fixed rates carry the fractional remainder so one wall-clock second always
/// contains exactly 120 closed-form substeps.
struct MercuryFramePacer {
    private var remainder = 0.0

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

    static func callbackInterval(
        timestamp: Double,
        targetTimestamp: Double,
        reportedDuration: Double,
        fallback: Double
    ) -> Double {
        let targetInterval = targetTimestamp - timestamp
        if targetInterval.isFinite, targetInterval > 0 {
            return targetInterval
        }
        if reportedDuration.isFinite, reportedDuration > 0 {
            return reportedDuration
        }
        return fallback.isFinite && fallback > 0 ? fallback : MercuryMetrics.substep
    }

    mutating func simulationSteps(frameDuration: Double) -> Int {
        guard frameDuration.isFinite, frameDuration > 0 else { return 0 }
        let maximumDuration =
            Double(MercuryMetrics.maxSubstepsPerFrame) * MercuryMetrics.substep
        remainder += Swift.min(frameDuration, maximumDuration)
        let available = Int(
            (remainder + MercuryMetrics.substep * 1e-9) / MercuryMetrics.substep
        )
        let steps = Swift.min(
            Swift.max(available, 0),
            MercuryMetrics.maxSubstepsPerFrame
        )
        remainder -= Double(steps) * MercuryMetrics.substep
        if available > MercuryMetrics.maxSubstepsPerFrame {
            remainder = 0
        }
        return steps
    }

    mutating func reset() {
        remainder = 0
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
        var pinnedStep: Int?
    }

    private let engine: MercuryEngine
    private var configuration: Configuration?
    private var screenLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    private var pacer = MercuryFramePacer()
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
                    appearance: configuration.appearance
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
        pacer.reset()
        guard window != nil, let configuration, configuration.pinnedStep == nil else {
            return
        }

        let link = displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        let maximum = window?.screen?.maximumFramesPerSecond ?? 60
        link.preferredFrameRateRange = MercuryFramePacer.preferredFrameRateRange(
            screenMaximum: maximum
        )
        link.add(to: .main, forMode: .common)
        screenLink = link
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        let fallback =
            1
            / Double(
                MercuryFramePacer.presentationFramesPerSecond(
                    screenMaximum: window?.screen?.maximumFramesPerSecond ?? 60
                )
            )
        let interval = MercuryFramePacer.callbackInterval(
            timestamp: link.timestamp,
            targetTimestamp: link.targetTimestamp,
            reportedDuration: link.duration,
            fallback: fallback
        )
        let steps = pacer.simulationSteps(frameDuration: interval)
        renderLive(steps: steps)
    }

    private func renderLive(steps: Int) {
        guard let configuration, configuration.pinnedStep == nil else { return }
        setImage(
            engine.frame(
                advancing: steps,
                seed: configuration.seed,
                world: configuration.world,
                drive: configuration.drive,
                appearance: configuration.appearance
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
