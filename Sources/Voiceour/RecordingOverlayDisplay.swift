import AppKit

/// One display as the recording island lays itself out on it: the whole screen, the part
/// windows may use, the camera housing if there is one, the menu-bar band beside it, and the
/// fastest cadence it presents at.
///
/// A plain value read once per hand-off rather than an `NSScreen`: layout, hit-testing and the
/// move policy are then testable without a screen, and the harness can pin one so a golden
/// never encodes the monitors of the Mac that rendered it. Rectangles are AppKit global screen
/// coordinates — points, origin at the bottom-left of the primary display — the space
/// `NSScreen` reports all of them in.
struct OverlayDisplay: Sendable, Equatable {
    /// The `CGDirectDisplayID` AppKit reports as `NSScreenNumber`. Stable for as long as the
    /// display stays attached, which is what the move policy compares displays by.
    var id: UInt32
    /// The whole display, menu bar included.
    var frame: CGRect
    /// `frame` less the menu bar and the Dock.
    var visibleFrame: CGRect
    /// The camera housing, hanging from `frame.maxY`; nil on a display without one.
    var housing: CGRect?
    /// How far the menu-bar band reaches down from `frame.maxY`. Menus, menu titles and
    /// status items own this strip, so the collar keeps only a film inside it and never takes
    /// a click there. See `OverlayDisplayGeometry.bandHeight`.
    var bandHeight: CGFloat
    /// `NSScreen.maximumFramesPerSecond`: the ceiling the display link may ask for.
    var maximumFramesPerSecond: Int
    /// The display belongs to a mirror set (`CGDisplayIsInMirrorSet`).
    var isMirrored: Bool

    /// Whether the body wears the collar. A mirror set shows these pixels on another panel
    /// that has no housing, where a collar would hug a notch that is not there, so a mirrored
    /// notched display gets the island like any other.
    var hasNotch: Bool { housing != nil && !isMirrored }
}

extension OverlayDisplay {
    /// A display without a camera housing, the size of the 14-inch MacBook Pro's default
    /// 1512×982 pt, with a 24 pt menu bar: the island case.
    static let fixtureNotchless = OverlayDisplay(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 958),
        housing: nil,
        bandHeight: 24,
        maximumFramesPerSecond: 120,
        isMirrored: false
    )

    /// A 16-inch MacBook Pro at its default 1728×1117 pt, as AppKit reported the panel this
    /// was measured on: `safeAreaInsets.top` 32, `auxiliaryTopLeftArea.maxX` 771.5,
    /// `auxiliaryTopRightArea.minX` 956.5, and a visible frame that stops 33 pt below the top.
    static let fixtureNotch = OverlayDisplay(
        id: 2,
        frame: CGRect(x: 0, y: 0, width: 1_728, height: 1_117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_084),
        housing: CGRect(x: 771.5, y: 1_085, width: 185, height: 32),
        bandHeight: 33,
        maximumFramesPerSecond: 120,
        isMirrored: false
    )

    /// The same 3456×2234-pixel panel scaled to More Space, 2056×1329 pt. The housing is fixed
    /// in device pixels (370×64 at the default 2×), so at 3456/2056 ≈ 1.68 px/pt it spans
    /// 220×38 pt: a wide housing with a 39 pt band.
    static let fixtureWideNotch = OverlayDisplay(
        id: 3,
        frame: CGRect(x: 0, y: 0, width: 2_056, height: 1_329),
        visibleFrame: CGRect(x: 0, y: 0, width: 2_056, height: 1_290),
        housing: CGRect(x: 918, y: 1_291, width: 220, height: 38),
        bandHeight: 39,
        maximumFramesPerSecond: 120,
        isMirrored: false
    )
}

/// The arithmetic between what `NSScreen` reports and an `OverlayDisplay`, as pure functions
/// of plain values so it is testable without a screen.
enum OverlayDisplayGeometry {
    /// The camera housing in global coordinates, or nil.
    ///
    /// AppKit has no housing rectangle; it reports what is left of the top edge on either side
    /// of it. Both auxiliary areas are documented to be in global screen coordinates, so the
    /// housing runs from `leftArea.maxX` to `rightArea.minX` on any display of the arrangement
    /// with no origin arithmetic, `safeAreaTop` tall from the top edge.
    ///
    /// Nil without a top inset, or without both areas (AppKit reports both or neither). Also
    /// nil for an empty gap, or one at least half the display wide: no camera housing comes
    /// close, so such a report describes some other inset, and a collar around it would cover
    /// the menu bar.
    static func housing(
        frame: CGRect,
        safeAreaTop: CGFloat,
        leftArea: CGRect?,
        rightArea: CGRect?
    ) -> CGRect? {
        guard safeAreaTop > 0, let leftArea, let rightArea else { return nil }
        let width = rightArea.minX - leftArea.maxX
        guard width > 0, width < frame.width / 2 else { return nil }
        return CGRect(x: leftArea.maxX, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
    }

    /// How far the menu-bar band reaches down from the display's top edge.
    ///
    /// Without a housing it is the strip the menu bar takes from the visible frame, and zero on
    /// a display that draws no menu bar. With one it is at least a point deeper than the
    /// housing — the menu bar's own depth on the measured panel, 33 pt beside a 32 pt housing —
    /// because the strips beside the housing stay menu territory even while an auto-hidden menu
    /// bar lets `visibleFrame` reach the top edge.
    static func bandHeight(frame: CGRect, visibleFrame: CGRect, housing: CGRect?) -> CGFloat {
        let menuBar = max(0, frame.maxY - visibleFrame.maxY)
        guard let housing else { return menuBar }
        return max(menuBar, housing.height + 1)
    }

    /// The display the island lays itself out on, as `screen` reports it now, unless the
    /// harness has pinned one.
    @MainActor
    static func display(for screen: NSScreen) -> OverlayDisplay {
        RenderOverrides.overlayDisplay ?? read(screen)
    }

    @MainActor
    private static func read(_ screen: NSScreen) -> OverlayDisplay {
        // AppKit always supplies the number; the null display keeps a malformed device
        // description from aliasing a real display in the move policy.
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let id = number?.uint32Value ?? kCGNullDirectDisplay
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let housing = Self.housing(
            frame: frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea
        )
        return OverlayDisplay(
            id: id,
            frame: frame,
            visibleFrame: visibleFrame,
            housing: housing,
            bandHeight: bandHeight(frame: frame, visibleFrame: visibleFrame, housing: housing),
            maximumFramesPerSecond: screen.maximumFramesPerSecond,
            isMirrored: CGDisplayIsInMirrorSet(id) != 0
        )
    }
}
