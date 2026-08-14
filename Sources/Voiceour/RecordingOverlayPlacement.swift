import AppKit

enum RecordingOverlayFramePlacement {
    static func defaultFrame(
        on visibleFrame: NSRect,
        size: NSSize,
        padding: CGFloat,
        topOffset: CGFloat
    ) -> NSRect {
        clamped(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - topOffset,
                width: size.width,
                height: size.height
            ),
            to: visibleFrame,
            padding: padding
        )
    }

    static func translatedFrame(
        _ savedFrame: NSRect,
        from sourceVisibleFrame: NSRect,
        to destinationVisibleFrame: NSRect,
        size: NSSize,
        padding: CGFloat
    ) -> NSRect {
        let sourceX = originRange(
            min: sourceVisibleFrame.minX,
            max: sourceVisibleFrame.maxX,
            length: size.width,
            padding: padding
        )
        let sourceY = originRange(
            min: sourceVisibleFrame.minY,
            max: sourceVisibleFrame.maxY,
            length: size.height,
            padding: padding
        )
        let destinationX = originRange(
            min: destinationVisibleFrame.minX,
            max: destinationVisibleFrame.maxX,
            length: size.width,
            padding: padding
        )
        let destinationY = originRange(
            min: destinationVisibleFrame.minY,
            max: destinationVisibleFrame.maxY,
            length: size.height,
            padding: padding
        )
        let xProgress = normalized(savedFrame.minX, in: sourceX)
        let yProgress = normalized(savedFrame.minY, in: sourceY)

        return NSRect(
            x: destinationX.lowerBound + xProgress * (destinationX.upperBound - destinationX.lowerBound),
            y: destinationY.lowerBound + yProgress * (destinationY.upperBound - destinationY.lowerBound),
            width: size.width,
            height: size.height
        )
    }

    static func clamped(
        _ frame: NSRect,
        to visibleFrame: NSRect,
        padding: CGFloat
    ) -> NSRect {
        let xRange = originRange(
            min: visibleFrame.minX,
            max: visibleFrame.maxX,
            length: frame.width,
            padding: padding
        )
        let yRange = originRange(
            min: visibleFrame.minY,
            max: visibleFrame.maxY,
            length: frame.height,
            padding: padding
        )
        return NSRect(
            x: clamp(frame.minX, to: xRange),
            y: clamp(frame.minY, to: yRange),
            width: frame.width,
            height: frame.height
        )
    }

    private static func originRange(
        min: CGFloat,
        max: CGFloat,
        length: CGFloat,
        padding: CGFloat
    ) -> ClosedRange<CGFloat> {
        let lower = min + padding
        return lower...Swift.max(lower, max - length - padding)
    }

    private static func normalized(_ value: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        guard range.lowerBound < range.upperBound else { return 0.5 }
        return clamp(
            (value - range.lowerBound) / (range.upperBound - range.lowerBound),
            to: 0...1
        )
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}
