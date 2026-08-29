import AppKit
import SwiftUI

final class RecordingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Routes the mouse against the mercury body's own silhouette.
///
/// There are no child controls left, so there is nothing to forward a press to and
/// `super.hitTest` is never called: a press either lands on the body and starts a window
/// drag, or it is not this window's press at all and falls through to whatever is
/// underneath. The predicate is the same scalar field the rasterizer drew, so a click ten
/// points outside the visible mercury reaches the app below rather than a transparent
/// rectangle the user cannot see.
@MainActor
final class RecordingOverlayHostingView<Content: View>: NSHostingView<Content> {
    private let hitRegion: MercuryHitRegion
    private var dragCursorArea: NSTrackingArea?

    init(rootView: Content, hitRegion: MercuryHitRegion) {
        self.hitRegion = hitRegion
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the SUPERVIEW's space, which is not flipped; the hit region
        // is written in this view's own flipped space. Convert before testing.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard hitRegion.contains(local, in: bounds, slop: MercuryMetrics.dragSlop) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }

    /// The island is repositionable and its position is remembered, which is
    /// undiscoverable without a cursor contract: on the body, the pointer says "you can
    /// pick this up".
    ///
    /// One tracking area over the island rect rather than over the body, because the body
    /// changes shape every display frame and rebuilding a tracking area at up to 120 Hz is
    /// churn AppKit does not need. The rect decides where the cursor is *asked*; the
    /// field decides what the answer is.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let dragCursorArea {
            removeTrackingArea(dragCursorArea)
        }
        let area = NSTrackingArea(
            rect: RecordingOverlayMetrics.islandHitRect(in: bounds),
            options: [.cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        dragCursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        // `locationInWindow` converts into this view's own flipped space, which is the
        // space the hit region is written in.
        let point = convert(event.locationInWindow, from: nil)
        if hitRegion.contains(point, in: bounds, slop: MercuryMetrics.dragSlop) {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}
