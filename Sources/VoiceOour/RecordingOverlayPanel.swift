import AppKit
import SwiftUI

final class RecordingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor
final class RecordingOverlayHostingView<Content: View>: NSHostingView<Content> {
    private let showsFinishButton: () -> Bool
    private var dragCursorArea: NSTrackingArea?

    init(
        rootView: Content,
        showsFinishButton: @escaping () -> Bool
    ) {
        self.showsFinishButton = showsFinishButton
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
        // `point` arrives in the SUPERVIEW's space, which is not flipped; every rect
        // below is written in this view's own flipped space. Convert before testing.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard RecordingOverlayMetrics.islandHitRect(in: bounds).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isOverControl(event) {
            super.mouseDown(with: event)
            return
        }

        guard let window else {
            super.mouseDown(with: event)
            return
        }

        window.performDrag(with: event)
    }

    /// The pill is repositionable and its position is remembered, which is
    /// undiscoverable without a cursor contract: everywhere but the two controls,
    /// the pointer says "you can pick this up".
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
        if isOverControl(event) {
            super.cursorUpdate(with: event)
        } else {
            NSCursor.openHand.set()
        }
    }

    private func isOverControl(_ event: NSEvent) -> Bool {
        // `locationInWindow` converts into this view's own flipped space, which is
        // the space `controlRects` is written in. Reading the rects bottom-up while
        // testing a top-down point sent 64% of every control press to
        // `window.performDrag`, so the pill crept across the screen on every finish.
        let point = convert(event.locationInWindow, from: nil)
        return
            RecordingOverlayMetrics
            .controlRects(
                in: RecordingOverlayMetrics.islandRect(in: bounds),
                includeFinish: showsFinishButton()
            )
            .contains { $0.contains(point) }
    }
}
