import AppKit
import Testing

@testable import Voiceour

struct RecordingOverlayPlacementTests {
    @Test func savedPositionTransfersToDestinationScreen() {
        let source = NSRect(x: 0, y: 0, width: 1_728, height: 1_084)
        let destination = NSRect(x: 1_728, y: -323, width: 2_560, height: 1_440)
        let size = NSSize(width: 260, height: 80)
        let padding: CGFloat = 14
        let saved = NSRect(x: 786, y: 169, width: size.width, height: size.height)

        let translated = RecordingOverlayFramePlacement.translatedFrame(
            saved,
            from: source,
            to: destination,
            size: size,
            padding: padding
        )

        #expect(translated.minX >= destination.minX + padding)
        #expect(translated.maxX <= destination.maxX - padding)
        #expect(translated.minY >= destination.minY + padding)
        #expect(translated.maxY <= destination.maxY - padding)
        #expect(!source.intersects(translated))
        #expect(
            abs(
                horizontalProgress(of: saved, in: source, size: size, padding: padding)
                    - horizontalProgress(of: translated, in: destination, size: size, padding: padding)) < 0.000_001)
        #expect(
            abs(
                verticalProgress(of: saved, in: source, size: size, padding: padding)
                    - verticalProgress(of: translated, in: destination, size: size, padding: padding)) < 0.000_001)
    }

    @Test func defaultPositionUsesDestinationTopCenter() {
        let destination = NSRect(x: 1_728, y: -323, width: 2_560, height: 1_440)
        let size = NSSize(width: 260, height: 80)

        let frame = RecordingOverlayFramePlacement.defaultFrame(
            on: destination,
            size: size,
            padding: 14,
            topOffset: 44
        )

        #expect(frame.midX == destination.midX)
        #expect(frame.maxY == destination.maxY - 44)
    }

    private func horizontalProgress(
        of frame: NSRect,
        in visibleFrame: NSRect,
        size: NSSize,
        padding: CGFloat
    ) -> CGFloat {
        let lower = visibleFrame.minX + padding
        let upper = visibleFrame.maxX - size.width - padding
        return (frame.minX - lower) / (upper - lower)
    }

    private func verticalProgress(
        of frame: NSRect,
        in visibleFrame: NSRect,
        size: NSSize,
        padding: CGFloat
    ) -> CGFloat {
        let lower = visibleFrame.minY + padding
        let upper = visibleFrame.maxY - size.height - padding
        return (frame.minY - lower) / (upper - lower)
    }
}
