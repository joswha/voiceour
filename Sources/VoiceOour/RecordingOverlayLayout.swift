import AppKit

/// Every measurement this surface owns, in one place. `RecordingOverlayView` draws
/// from it and `RecordingOverlayHostingView` routes the mouse from it, so the pixels
/// and the clickable regions cannot drift apart.
enum RecordingOverlayMetrics {
    /// The panel window. Only the 180x34 island is visible; the rest of this box is
    /// the bleed `Shadow.overlayOuter` (radius 18, y 6) needs in order to draw
    /// without clipping — 40pt each side, 16pt above, 30pt below.
    static let windowSize = NSSize(width: 260, height: 80)
    static let islandSize = NSSize(width: 180, height: 34)

    static let contentTopInset: CGFloat = VoiceOourMetrics.Space.lg
    /// A true screen margin for the visible pill on all four sides (see
    /// `islandFrame(forWindow:)`), not for the transparent box around it.
    static let screenPadding: CGFloat = VoiceOourMetrics.Space.lg
    /// Distance from the screen's visible top edge to the ISLAND's top edge.
    static let topOffset: CGFloat = 44

    /// The two control discs.
    enum Disc {
        static let hitSize: CGFloat = VoiceOourMetrics.Control.small
        /// Spec §5.16 pins 22 visual inside a 28 hit frame; in a 34pt capsule that
        /// is the value — and the only one on this surface off the 4pt grid — that
        /// makes the ring a uniform 6pt on every side.
        static let visualSize: CGFloat = 22
        static let pressedScale: CGFloat = 0.985

        /// Permanent rest chrome (spec §5.16 / bible §21.3 ¶4). Finish out-ranks
        /// cancel: the affirmative action is the loud one, the discard is the quiet
        /// escape. Increase Contrast raises both by one fixed step.
        static let cancelFillOpacity: Double = 0.08
        static let cancelStrokeOpacity: Double = 0.16
        static let finishFillOpacity: Double = 0.14
        static let finishStrokeOpacity: Double = 0.32
        static let increasedFillBoost: Double = 0.10
        static let increasedStrokeBoost: Double = 0.24
        static let activeStrokeOpacity: Double = 0.72
        static let pressedStrokeOpacity: Double = 0.90
    }

    /// The input meter.
    enum Waveform {
        static let barWidth: CGFloat = VoiceOourMetrics.Space.xs
        static let barSpacing: CGFloat = VoiceOourMetrics.Space.xs
        static let minimumHeight: CGFloat = VoiceOourMetrics.Space.xs
        static let maximumHeight: CGFloat = 20
        /// Reduce Motion halves the travel instead of removing the smoothing.
        static let maximumHeightReduced: CGFloat = 12
        /// Perceptual: smoothstep crushed the bottom of the range, which is where
        /// conversational speech at desk distance lives.
        static let levelExponent: Double = 0.6
        static let opacityFloor: Double = 0.45
        static let opacityFloorIncreased: Double = 0.62
        static let opacityRecency: Double = 0.10
        static let bloomBlur: CGFloat = 1.2
        static let bloomOpacity: Double = 0.55
    }

    /// The comet mark, sized to the disc it replaces while the finish action is
    /// unavailable.
    enum Comet {
        static let orbitPeriod: Double = 1.55
        static let breathePeriod: Double = 1.6
        static let breatheFloor: Double = 0.45
        static let restingPhase: CGFloat = 0.25
        static let frameInterval: Double = 1.0 / 60.0
        static let reducedFrameInterval: Double = 1.0 / 20.0
        static let orbitInset: CGFloat = 7
        static let trailFractionOfPerimeter: CGFloat = 0.42
        static let trailSampleCount: Int = 96
        static let ribbonHeadWidth: CGFloat = 2.2
        static let ribbonWidthExponent: Double = 0.72
        static let bloomBlur: CGFloat = 1.0
        static let bloomWidthScale: CGFloat = 1.7
        static let bloomAlphaScale: CGFloat = 0.55
        static let headFontSize: CGFloat = 9
        static let headGlowRadius: CGFloat = 4.5
        static let headGlowBlur: CGFloat = 2.0
    }
}
extension RecordingOverlayMetrics {
    /// The island's frame inside the panel's content view, in the hosting view's own
    /// TOP-DOWN (flipped) space — the space SwiftUI lays the overlay out in, so these
    /// rects and the published accessibility frames agree by construction.
    static func islandRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.midX - islandSize.width / 2,
            y: bounds.minY + contentTopInset,
            width: islandSize.width,
            height: islandSize.height
        )
    }

    /// The island plus the slop that keeps a click on the rim inside the pill.
    static func islandHitRect(in bounds: CGRect) -> CGRect {
        islandRect(in: bounds)
            .insetBy(dx: -VoiceOourMetrics.Space.hair, dy: -VoiceOourMetrics.Space.hair)
    }

    /// THE single source of control placement. Consumed by the SwiftUI overlay AND
    /// by `RecordingOverlayHostingView`'s mouse routing. Placing the discs visually
    /// without routing both consumers through this is the regression this exists to
    /// prevent: the harness renders `RecordingOverlayView` directly and never
    /// instantiates the hosting view, so matching pixels do not prove matching clicks.
    static var controlInboardOffset: CGFloat {
        (islandSize.height - Disc.hitSize) / 2
    }

    /// Width one cap consumes: the inboard offset plus the hit frame.
    static var controlSlot: CGFloat {
        controlInboardOffset + Disc.hitSize
    }

    static func controlRects(in islandRect: CGRect, includeFinish: Bool) -> [CGRect] {
        let size = Disc.hitSize
        let y = islandRect.midY - size / 2
        var rects = [
            CGRect(x: islandRect.minX + controlInboardOffset, y: y, width: size, height: size)
        ]
        if includeFinish {
            rects.append(
                CGRect(x: islandRect.maxX - controlInboardOffset - size, y: y, width: size, height: size)
            )
        }
        return rects
    }

    /// The island's frame in SCREEN (bottom-up) space, given the window that carries
    /// it. Placement and clamping run on this rect so `screenPadding` and `topOffset`
    /// describe the pill the user can see rather than the transparent box around it.
    static func islandFrame(forWindow frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX + (windowSize.width - islandSize.width) / 2,
            y: frame.maxY - contentTopInset - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
    }

    static func windowFrame(forIsland frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX - (windowSize.width - islandSize.width) / 2,
            y: frame.maxY + contentTopInset - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }
}
