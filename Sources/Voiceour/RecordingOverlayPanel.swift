import AppKit
import SwiftUI

final class RecordingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Routes the mouse against the mercury body's own silhouette.
///
/// There are no child controls left, so there is nothing to forward a press to and
/// `super.hitTest` is never called: a press either lands on the body and picks it up, or it
/// is not this window's press at all and falls through to whatever is underneath. The
/// predicate is the same scalar field the rasterizer drew, so a click ten points outside the
/// visible mercury reaches the app below rather than a transparent rectangle the user cannot
/// see.
@MainActor
final class RecordingOverlayHostingView<Content: View>: NSHostingView<Content> {
    private let hitRegion: MercuryHitRegion
    /// Owns the layout, and with it the canvas the drag cursor is asked over.
    private let model: RecordingOverlayModel
    /// Re-asks the controller's pointer gate. The gate itself reads the pointer: this only says
    /// that it has moved over the canvas, entered it or left it.
    private let onPointerEvent: @MainActor () -> Void
    /// Tells the controller of a press on the body, each move it makes and its release.
    private let onDrag: @MainActor (RecordingOverlayDrag.Event) -> Void
    private var dragCursorArea: NSTrackingArea?

    init(
        rootView: Content,
        hitRegion: MercuryHitRegion,
        model: RecordingOverlayModel,
        onPointerEvent: @escaping @MainActor () -> Void,
        onDrag: @escaping @MainActor (RecordingOverlayDrag.Event) -> Void
    ) {
        self.hitRegion = hitRegion
        self.model = model
        self.onPointerEvent = onPointerEvent
        self.onDrag = onDrag
        super.init(rootView: rootView)
        // The controller sizes the panel from the layout. A hosting view that held the window to
        // its content's size would clamp a re-frame onto another display to the layout it is
        // leaving, until SwiftUI next laid the new one out.
        sizingOptions = []
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
        guard hitRegion.contains(local, slop: MercuryMetrics.dragSlop) else {
            return nil
        }
        return self
    }

    /// A press on the body is direct manipulation: the press, every move and the release go to the
    /// controller, which pulls the docked body on its tether or carries the island itself, so the
    /// gel feels every move. `performDrag(with:)` would hand the move to the window server, where
    /// the body cannot feel it, and a `nextEvent` tracking loop would hold the main thread between
    /// frames; each event arrives on its own pass of the run loop instead, between the display
    /// link's frames. The pointer is read in global coordinates as it is when the event is handled:
    /// a location in the window is measured against a frame the drag itself keeps moving.
    override func mouseDown(with event: NSEvent) {
        onDrag(.began(NSEvent.mouseLocation))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag(.moved(NSEvent.mouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        onDrag(.ended(NSEvent.mouseLocation))
    }

    /// The body can be picked up, torn off its dock or carried as a free island, which is
    /// undiscoverable without a cursor contract: on the body, collar or island, the pointer
    /// says "you can pick this up".
    ///
    /// One tracking area over the layout's canvas rather than over the body, because the body
    /// changes shape every display frame and rebuilding a tracking area at up to 120 Hz is
    /// churn AppKit does not need. The rect decides where the cursor is *asked*; the
    /// field decides what the answer is. The canvas is read from the model's layout each
    /// time AppKit asks, which it does whenever the view is resized.
    ///
    /// The same area reports the pointer moving over the canvas, entering it and leaving it, so
    /// the controller's pointer gate answers at once rather than on the next presented frame. The
    /// frames re-ask the gate either way, so nothing depends on AppKit delivering these to a panel
    /// that is ignoring the mouse.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let dragCursorArea {
            removeTrackingArea(dragCursorArea)
        }
        let area = NSTrackingArea(
            rect: model.layout.canvasRect
                .insetBy(dx: -VoiceourMetrics.Space.hair, dy: -VoiceourMetrics.Space.hair),
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        dragCursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOnBody(event) {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
        onPointerEvent()
    }

    /// Moves set the cursor too, not only entries: the pointer gate hands the panel the mouse once
    /// the pointer is on the body, which can be after the pointer entered the canvas, and a panel
    /// that ignored the mouse then heard no entry to answer.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if isOnBody(event) {
            NSCursor.openHand.set()
        }
        onPointerEvent()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent()
    }

    /// `locationInWindow` converts into this view's own flipped space, which is the space the hit
    /// region is written in.
    private func isOnBody(_ event: NSEvent) -> Bool {
        hitRegion.contains(convert(event.locationInWindow, from: nil), slop: MercuryMetrics.dragSlop)
    }
}
