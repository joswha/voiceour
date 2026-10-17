import AppKit
import SwiftUI

/// Measurements shared by window placement and the stable 180×34 body envelope.
/// Pixel and click agreement does not depend on these rectangles: `MercuryField` is the
/// single silhouette and `MercuryHitRegion` converts panel points back into it.
enum RecordingOverlayMetrics {
    /// Transparent panel retained at its established measure so stored placement,
    /// cross-display translation and the fixed accessibility frame do not migrate with
    /// the visual cutover. Only the centered 180×34 envelope draws or accepts a hit.
    static let windowSize = NSSize(width: 260, height: 80)
    static let islandSize = NSSize(width: 180, height: 34)

    static let contentTopInset: CGFloat = VoiceourMetrics.Space.lg
    /// A true screen margin for the visible body on all four sides (see
    /// `islandFrame(forWindow:)`), not for the transparent panel around it.
    static let screenPadding: CGFloat = VoiceourMetrics.Space.lg
    /// Distance from the screen's visible top edge to the ISLAND's top edge.
    static let topOffset: CGFloat = 44

    /// How long the island holds an unclean delivery's silhouette gesture and VoiceOver
    /// value before dismissing. A clean paste gets no dwell: text arriving in the target
    /// is already confirmation.
    static let outcomeDwell: Double = 1.2

    /// Voice-activity hysteresis. The drive followed the raw level, so a room's noise
    /// floor made the resting body twitch and "open" was never visually distinct from
    /// "hearing you". Two thresholds with asymmetric dwell give that boundary a stable
    /// place to sit: quick to notice speech, slow to concede silence.
    enum Speech {
        static let attackLevel: Float = 0.10
        static let releaseLevel: Float = 0.05
        /// 80ms at the meter's 25Hz.
        static let attackSamples: Int = 2
        /// 280ms at the meter's 25Hz.
        static let releaseSamples: Int = 7
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

    /// Tracking rect only. Whether a pointer is on the body is answered by the mercury
    /// field through `MercuryHitRegion`; transparent panel area never becomes clickable.
    static func islandHitRect(in bounds: CGRect) -> CGRect {
        islandRect(in: bounds)
            .insetBy(dx: -VoiceourMetrics.Space.hair, dy: -VoiceourMetrics.Space.hair)
    }

    /// The body's envelope in screen (bottom-up) space. Placement and clamping run on
    /// this rect so `screenPadding` and `topOffset` describe what the user can see.
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
