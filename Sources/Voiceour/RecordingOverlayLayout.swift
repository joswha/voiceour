import AppKit
import SwiftUI

/// Every measurement this surface owns, in one place. `RecordingOverlayView` draws
/// from it and `RecordingOverlayHostingView` routes the mouse from it, so the pixels
/// and the clickable regions cannot drift apart.
enum RecordingOverlayMetrics {
    /// The panel window. Only the 180x34 island is visible; the rest of this box is
    /// bleed the island's shadow needs in order to draw without clipping at the window
    /// edge — 40pt each side, 16pt above, 30pt below. That shadow used to be the app's
    /// own two black blurs; on macOS 26 it is Liquid Glass's own adaptive one, which
    /// also draws outside the capsule and would clip just the same. The margin is not
    /// hit-tested, so it costs nothing but transparent pixels.
    static let windowSize = NSSize(width: 260, height: 80)
    static let islandSize = NSSize(width: 180, height: 34)

    static let contentTopInset: CGFloat = VoiceourMetrics.Space.lg
    /// A true screen margin for the visible pill on all four sides (see
    /// `islandFrame(forWindow:)`), not for the transparent box around it.
    static let screenPadding: CGFloat = VoiceourMetrics.Space.lg
    /// Distance from the screen's visible top edge to the ISLAND's top edge.
    static let topOffset: CGFloat = 44

    /// How long the island holds an unclean delivery before it dismisses itself. Long
    /// enough to read four characters and a symbol, short enough that it is gone before
    /// the user reaches for the keyboard again. A clean paste gets no dwell at all: the
    /// transcript arriving in the target app is already the confirmation, and that is
    /// the common path.
    static let outcomeDwell: Double = 1.2

    /// The two control discs.
    enum Disc {
        static let hitSize: CGFloat = VoiceourMetrics.Control.small
        /// 22 visual inside a 28 hit frame: in a 34pt capsule that is the value — and
        /// the only one on this surface off the 4pt grid — that makes the ring a
        /// uniform 6pt on every side.
        static let visualSize: CGFloat = 22
        static let pressedScale: CGFloat = 0.985

        /// Permanent rest chrome on the painted and opaque grounds. Finish out-ranks
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

    /// The input meter. This is the island's whole message, so it is drawn to be read
    /// rather than admired.
    enum Waveform {
        static let barWidth: CGFloat = VoiceourMetrics.Space.xs
        static let barSpacing: CGFloat = VoiceourMetrics.Space.xs
        /// The height of a bar at silence. It was 4pt, which in a 34pt capsule rendered
        /// an open microphone as eleven near-invisible dots — the single most important
        /// thing this surface says, said with its faintest mark. An even 8pt row is a
        /// deliberate statement that the capture path is live.
        static let restingHeight: CGFloat = 8
        static let maximumHeight: CGFloat = 20
        /// Reduce Motion shortens the travel instead of removing the smoothing.
        static let maximumHeightReduced: CGFloat = 12
        /// Perceptual: smoothstep crushed the bottom of the range, which is where
        /// conversational speech at desk distance lives.
        static let levelExponent: Double = 0.6
        static let opacityFloor: Double = 0.78
        static let opacityFloorIncreased: Double = 0.92
    }

    /// Voice-activity hysteresis. The meter followed the raw level, so a room's noise
    /// floor made the resting row twitch and "open" was never visually distinct from
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

    /// The working mark, sized to the disc it replaces while the finish action is
    /// unavailable. Drawn from the meter's own vocabulary so listening and working read
    /// as one instrument.
    enum WorkMark {
        static let dotSize: CGFloat = 3
        static let dotSpacing: CGFloat = 4
        static let dotCount: Int = 3
        /// One right-to-left hand-off, so the motion reads as speech being drawn in.
        static let cyclePeriod: Double = 0.72
        static let frameInterval: Double = 1.0 / 30.0
        static let dimOpacity: Double = 0.30
        static let dimOpacityIncreased: Double = 0.50
        static let brightOpacity: Double = 1.0
    }
}

/// Which ground the island is painting on. `RecordingOverlayView` decides once and
/// passes it down, because the foreground policy is a function of the ground's
/// luminance and the three grounds do not agree about it.
enum RecordingOverlaySurface {
    /// macOS 26 `.glassEffect(.regular, in: .capsule)`, untinted. Adaptive: this one may
    /// be light or dark, and the app cannot know which.
    case systemGlass
    /// macOS 14/15 behind-window frost plus the app's tint and rims. Always near-black.
    case painted
    /// Reduce Transparency, on every OS. Opaque `Ink.void`. Always near-black.
    case opaque

    /// True where the app may assume a dark ground and use the light-on-dark palette.
    /// False on system glass, where an explicit near-white would land on near-white and
    /// a semantic `.primary` is what earns the material's vibrancy treatment.
    var isDarkGround: Bool {
        self != .systemGlass
    }
}

/// Every colour the island uses, resolved by ground rather than named directly at the
/// call site.
///
/// The island is the one surface in the app that floats over content it cannot see, and
/// on macOS 26 the material under its own content is adaptive: over a light desktop the
/// glass renders light. The existing palette cannot survive that, because it was authored
/// for the near-black painted pill and its contrast was measured there — `Text.mid` is
/// (0.64, 0.71, 0.80) and `Signal.mint` is (0.66, 0.96, 0.82), so both land on near-white.
///
/// So each semantic role resolves twice. On the two near-black grounds it resolves to the
/// existing token, which is correct there and unchanged. On system glass a neutral role
/// resolves to `.primary`/`.secondary`, because SwiftUI's vibrancy treatment applies to
/// the system semantic colours and an explicit literal is exactly what defeats it, and a
/// role that carries meaning resolves to `VoiceourPalette.OnGlass`, whose mid-tones clear
/// 3:1 against both white and black so one value works either way the material adapts.
extension RecordingOverlaySurface {
    /// The affirmative action.
    var affirm: Color {
        isDarkGround ? VoiceourPalette.Signal.mint : VoiceourPalette.OnGlass.mint
    }

    /// The destructive action, once the pointer is on it.
    var destroy: Color {
        isDarkGround ? VoiceourPalette.Signal.crimson : VoiceourPalette.OnGlass.crimson
    }

    /// A delivery that did not go as asked but cost the user nothing.
    var caution: Color {
        isDarkGround ? VoiceourPalette.Signal.amber : VoiceourPalette.OnGlass.amber
    }

    /// Live audio: the meter and the working mark.
    var live: Color {
        isDarkGround ? VoiceourPalette.Meter.accent : VoiceourPalette.OnGlass.cyan
    }

    /// The readout.
    var label: Color {
        isDarkGround ? VoiceourPalette.Text.high : .primary
    }

    /// The quiet escape, at rest.
    var quietLabel: Color {
        isDarkGround ? VoiceourPalette.Text.mid : .secondary
    }

    /// A control's own permanent rest plate, where that plate carries no meaning.
    var neutral: Color {
        isDarkGround ? VoiceourPalette.Text.monoStrong : .primary
    }

    /// Interaction washes layered over a rest plate. A white wash is invisible on a
    /// light ground, so on glass these follow the appearance instead of the palette.
    var wash: Color {
        isDarkGround ? VoiceourPalette.Plate.hover : Color.primary.opacity(0.09)
    }

    var washPressed: Color {
        isDarkGround ? VoiceourPalette.Plate.pressed : Color.primary.opacity(0.14)
    }

    var controlHover: Color {
        isDarkGround ? VoiceourPalette.Line.controlHover : Color.primary.opacity(0.48)
    }

    var focusRing: Color {
        isDarkGround ? VoiceourPalette.Line.focus : VoiceourPalette.OnGlass.cyan
    }

    var focusHalo: Color {
        isDarkGround
            ? VoiceourPalette.Signal.focusHalo
            : VoiceourPalette.OnGlass.cyan.opacity(0.25)
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
            .insetBy(dx: -VoiceourMetrics.Space.hair, dy: -VoiceourMetrics.Space.hair)
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
