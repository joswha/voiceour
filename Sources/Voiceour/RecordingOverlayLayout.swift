import AppKit
import SwiftUI

/// Measurements shared by window placement and the stable 180×34 body envelope.
/// Pixel and click agreement does not depend on these rectangles: `MercuryField` is the
/// single silhouette and `MercuryHitRegion` converts panel points back into it.
enum RecordingOverlayMetrics {
    /// Transparent panel retained at its established measure so placement, which is measured
    /// on the envelope inside it, and the fixed accessibility frame do not migrate with the
    /// visual cutover. Only the island's canvas draws or accepts a hit: the centred
    /// 180×34 envelope and the room its round ends need beyond it (see
    /// `RecordingOverlayLayout.island`).
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

/// Where the body is laid out in its panel, and the line it lies along.
///
/// One value carries everything that differs between the two places the body lives, so the
/// view, the engine, the raster and the hit region all read one description of it:
///
/// - The island: a straight 196 pt spine on a 196×34 canvas, centred on the 180×34 envelope
///   `contentTopInset` below the top of the 260×80 panel. It sits below the menu bar, so it
///   has no band.
/// - The collar: the camera housing's outline as the spine, on a canvas that is the whole
///   panel and hangs flush from the screen's top edge. The housing fills the canvas's top
///   centre, and the menu-bar band runs across the panel's top.
///
/// Rectangles are in the panel's flipped space: points, origin at its top-left, the space
/// SwiftUI lays the overlay out in and the hosting view hit-tests in. The spine is
/// canvas-local: origin at the canvas centre, +y up, the space `MercuryField` is written in.
struct RecordingOverlayLayout: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case island
        case collar
    }

    let kind: Kind
    /// The panel's content size.
    let panelSize: NSSize
    /// The canvas the field is written on and the raster covers. The panel outside it never
    /// draws.
    let canvasRect: CGRect
    /// The fixed frame of the one `Dictation status` accessibility element. It stays still
    /// while the body breathes, so the VoiceOver cursor does too.
    let statusRect: CGRect
    let spine: MercurySpine
    /// How far the menu-bar band reaches down from the panel's top edge. Menus, menu titles
    /// and status items own that strip, so the hit region never claims a point in it.
    let bandHeight: CGFloat

    /// The established island: the 260×80 panel, and a status element covering exactly the
    /// 180×34 envelope placement measures, so stored placement and the accessibility frame
    /// are the ones the island has always had.
    ///
    /// The canvas runs `Island.endMargin` past each end of that envelope. The body rides a
    /// track `MercuryMetrics.maxLength` long, so its span ends at most 84 pt from the centre,
    /// and a round end reaches past that by its own half-thickness. The speaking body at full
    /// lean, or under the hardest drag, rounds off up to 93.5 pt out, 94 on an adversarial
    /// meter, and a canvas cut at the envelope's 90 pt cut its cap. At rest it stays inside
    /// 88 pt, so the body draws the pixels it always did, laid about the same centre, and the
    /// margins are transparent until a round end reaches into them.
    static let island: RecordingOverlayLayout = {
        let panel = RecordingOverlayMetrics.windowSize
        let envelope = CGRect(
            x: (panel.width - RecordingOverlayMetrics.islandSize.width) / 2,
            y: RecordingOverlayMetrics.contentTopInset,
            width: RecordingOverlayMetrics.islandSize.width,
            height: RecordingOverlayMetrics.islandSize.height
        )
        let canvas = envelope.insetBy(dx: -Island.endMargin, dy: 0)
        return RecordingOverlayLayout(
            kind: .island,
            panelSize: panel,
            canvasRect: canvas,
            statusRect: envelope,
            spine: MercurySpine(straightLength: Double(canvas.width)),
            bandHeight: 0
        )
    }()

    /// The collar around a camera housing of `housingSize`, on a display whose menu-bar band
    /// reaches `bandHeight` down from its top edge.
    ///
    /// The canvas reaches the fillet and the ear beyond each wall, `ρe + E`, and `endMargin`
    /// past each ear's end. Below the housing it holds the deepest chin the body can draw, the
    /// collar's own ceiling `Collar.maxHalfHeight`, and `chinMargin` under that. The status
    /// element spans the housing's width directly under it, down to the canvas bottom: the
    /// chin's own strip.
    ///
    /// Nil for a housing that cannot wear a collar. `MercurySpine.init(collar:)` accepts any
    /// housing taller than its fillet, rounding the corner down to fit. This refuses one no
    /// taller than `ρe + 6` pt, whose corner would round below the smallest 6 pt, and one no
    /// wider than its two corners, which leaves the chin no bottom run. Neither is a camera
    /// housing, and the island serves that display instead.
    static func collar(housingSize: CGSize, bandHeight: CGFloat) -> RecordingOverlayLayout? {
        let width = Double(housingSize.width)
        let height = Double(housingSize.height)
        guard width.isFinite, height.isFinite, height > Collar.filletRadius + Collar.cornerRadii.lowerBound else {
            return nil
        }
        let cornerRadius = Swift.min(
            Swift.max(Collar.cornerRatio * height, Collar.cornerRadii.lowerBound),
            Collar.cornerRadii.upperBound
        )
        guard width > 2 * cornerRadius else { return nil }

        let reach = CGFloat(Collar.filletRadius + Collar.earLength) + Collar.endMargin
        let canvas = CGSize(
            width: housingSize.width + 2 * reach,
            height: housingSize.height + CGFloat(Collar.maxHalfHeight) + Collar.chinMargin
        )
        // Flush with the canvas top and centred on it, in the canvas-local space the spine uses.
        let top = Double(canvas.height) / 2
        let outline = MercurySpine.Outline(
            minX: -width / 2,
            maxX: width / 2,
            bottom: top - height,
            top: top,
            cornerRadius: cornerRadius,
            filletRadius: Collar.filletRadius,
            earLength: Collar.earLength,
            bandFilm: Collar.bandFilm,
            maxHalfHeight: Collar.maxHalfHeight
        )
        return RecordingOverlayLayout(
            kind: .collar,
            panelSize: canvas,
            canvasRect: CGRect(origin: .zero, size: canvas),
            statusRect: CGRect(
                x: (canvas.width - housingSize.width) / 2,
                y: housingSize.height,
                width: housingSize.width,
                height: canvas.height - housingSize.height
            ),
            spine: MercurySpine(collar: outline),
            bandHeight: bandHeight
        )
    }

    /// The layout the body takes on `display`: the collar around its camera housing, or the
    /// island on a display without one, on a mirrored one (see `OverlayDisplay.hasNotch`) and
    /// around a housing that cannot wear a collar.
    static func forDisplay(_ display: OverlayDisplay) -> RecordingOverlayLayout {
        guard display.hasNotch, let housing = display.housing,
            let collar = collar(housingSize: housing.size, bandHeight: display.bandHeight)
        else { return .island }
        return collar
    }

    /// The spine's unit tangent and normal where a body with no sway is centred: the island's straight
    /// axis, +x and +y, or the collar's bottom run, +x and −y, out of the housing. The body shape's sway
    /// and aspect answer along these, so a pull on the body and its panel's acceleration are resolved
    /// into them. Canvas-local axes share AppKit's global orientation, +y up, so a global vector
    /// resolves as it is.
    struct BodyAxes: Sendable, Equatable {
        var tangent: SIMD2<Double>
        var normal: SIMD2<Double>

        /// `vector`'s components along the tangent and along the normal.
        func resolve(_ vector: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((vector * tangent).sum(), (vector * normal).sum())
        }
    }

    var bodyAxes: BodyAxes {
        let frame = spine.frame(at: spine.restCenter)
        return BodyAxes(tangent: frame.tangent, normal: frame.normal)
    }

    private init(
        kind: Kind,
        panelSize: NSSize,
        canvasRect: CGRect,
        statusRect: CGRect,
        spine: MercurySpine,
        bandHeight: CGFloat
    ) {
        self.kind = kind
        self.panelSize = panelSize
        self.canvasRect = canvasRect
        self.statusRect = statusRect
        self.spine = spine
        self.bandHeight = bandHeight
    }

    /// The island's measures, in points.
    private enum Island {
        /// Canvas past each end of the 180×34 envelope: room for the round end of a body at
        /// the end of its track, with its bleed. See ``RecordingOverlayLayout/island``.
        static let endMargin: CGFloat = 8
    }

    /// The collar's measures, in points.
    private enum Collar {
        /// ρe, the concave fillet that turns each wall into the screen's top edge.
        static let filletRadius = 4.5
        /// E, how far the collar runs along the top edge beyond each fillet.
        static let earLength = 56.0
        /// The outward thickness the taper leaves the body where it meets the screen's top edge:
        /// along the fillets and the ears, and at the top of each wall. Thinner than the fillet's
        /// plateau, so each fillet's offsets stay unique (see `MercurySpine`).
        static let bandFilm = 3.5
        /// H_c, the deepest half-height the body may draw below the housing and beside it. Only
        /// the body's outer half shows, the inner half lying under the hardware, so at the island's
        /// 17 pt the speaking chin hung 11.5 pt below a 32 pt notch, a sliver under it. At 24 pt
        /// every collar pose is 24/17 as deep: the speaking frame hangs about 16 pt below the notch
        /// and stands about 9 pt beside it, and the raster budget still holds its sides.
        static let maxHalfHeight = 24.0
        /// ρ, the housing's convex bottom corners, as a fraction of its depth, held to
        /// `cornerRadii`. Apple publishes no housing shape; 0.44 of the 32 pt housing is the
        /// 14 pt bottom radius notch overlays draw, and 6…16 pt bounds it at other depths.
        static let cornerRatio = 0.44
        static let cornerRadii: ClosedRange<Double> = 6...16
        /// Canvas past each ear's end: room for the round end of a body that reaches it, at
        /// most the band film, and its coverage ramp.
        static let endMargin: CGFloat = 4
        /// Canvas below the deepest chin, which holds its `MercuryMetrics.bleed`.
        static let chinMargin: CGFloat = 3
    }
}
