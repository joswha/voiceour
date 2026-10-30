import AppKit

/// Whether the recording panel takes the mouse, decided against the body that is drawn.
///
/// The panel is a window floating over every app, so whatever it takes, the app underneath loses.
/// AppKit's `ignoresMouseEvents` is tri-state: never set, the window server passes clicks through
/// the panel's transparent pixels; set `false`, it takes every click in its frame, transparent or
/// not, which made the whole 260×80 panel a click sink around a 180×34 body; set `true`, it takes
/// none. Neither reading of the alpha is the silhouette the field draws, so the flag is driven
/// explicitly: the panel takes the mouse only while the pointer is on the body itself, within the
/// drag slop and below the menu-bar band, and it ignores the mouse everywhere else.
///
/// The predicate is the hit region's, so it is the same field the rasterizer drew and the same
/// band rule the hosting view's hit test applies. It is re-asked on every presented frame and on
/// every tracking-area event over the canvas, and written to the panel only when its answer
/// changes: a write per frame would be a window-server round trip for nothing.
@MainActor
struct RecordingOverlayPointerGate {
    /// What the panel was last told; nil until the gate first writes, while AppKit's alpha test
    /// is still in force.
    private(set) var ignoresMouse: Bool?

    /// Tells `panel` to ignore the mouse, or to take it, if that is not what it was last told.
    mutating func set(ignoresMouse: Bool, on panel: NSWindow) {
        guard ignoresMouse != self.ignoresMouse else { return }
        self.ignoresMouse = ignoresMouse
        panel.ignoresMouseEvents = ignoresMouse
    }

    /// Whether the panel ignores a pointer at `pointerInPanel`: everywhere but on the drawn body,
    /// within `MercuryMetrics.dragSlop` of it and below the band. Nil is a pointer outside the
    /// panel. `forcedClickThrough` ignores it everywhere: an outcome dwell, a hand-off between
    /// displays and a hidden or fading panel report the session rather than offer the body.
    static func ignoresMouse(
        pointerInPanel: CGPoint?,
        hitRegion: MercuryHitRegion,
        forcedClickThrough: Bool
    ) -> Bool {
        guard !forcedClickThrough, let pointerInPanel else { return true }
        return !hitRegion.contains(pointerInPanel, slop: MercuryMetrics.dragSlop)
    }

    /// `location`, in AppKit global coordinates as `NSEvent.mouseLocation` reports it, in the
    /// panel's flipped space: points from its top-left corner, the space the hosting view and the
    /// hit region are written in. Nil outside `panelFrame`. The panel is borderless, so its content
    /// fills its frame.
    nonisolated static func pointInPanel(_ location: CGPoint, panelFrame: CGRect) -> CGPoint? {
        guard panelFrame.contains(location) else { return nil }
        return CGPoint(x: location.x - panelFrame.minX, y: panelFrame.maxY - location.y)
    }
}
