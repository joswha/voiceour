import AppKit

/// Where the recording body lives on a display: docked, or a free island the user left somewhere.
///
/// Docked is the body's home. On a display whose camera housing can wear a collar
/// (`RecordingOverlayLayout.forDisplay`) it is the collar, hung from the housing; on any other
/// display it is the island at its default spot, centred `topOffset` below the visible top. Free is
/// an island the user tore off and let go of: an island on every display, the notched one included,
/// because a collar exists only around its housing.
///
/// A free placement is relative, never an absolute position. `(u, v)` is the island envelope's
/// origin normalized into the range that origin may take on a display, its `visibleFrame` with
/// `screenPadding` kept on every side: (0, 0) is the lowest, leftmost origin the padding allows and
/// (1, 1) the highest, rightmost. One placement is therefore the same relative spot on every display,
/// whatever its size or place in the arrangement, and always clear of the menu bar and the Dock.
enum RecordingOverlayPlacement: Equatable, Sendable {
    case docked
    case free(u: Double, v: Double)

    /// What a placement lays out on one display.
    struct Arrangement: Equatable {
        /// The collar for a docked body on a display that can wear one; the island everywhere else.
        let layout: RecordingOverlayLayout
        /// The panel's frame, in AppKit global coordinates.
        let panelFrame: NSRect
        /// The point the body is centred on, in global coordinates: the island envelope's centre, or
        /// the collar's housing bottom centre, from which its chin hangs.
        let centre: CGPoint
    }

    /// The point a released island docks to, and the layout docking there takes.
    enum Anchor: Sendable, Equatable {
        /// The housing's bottom centre: docking re-lays the island out as the collar.
        case collar(CGPoint)
        /// The docked island's envelope centre: docking keeps the island.
        case island(CGPoint)

        var point: CGPoint {
            switch self {
            case .collar(let point), .island(let point): point
            }
        }
    }

    var isFree: Bool {
        if case .free = self { return true }
        return false
    }

    /// The layout and panel frame this placement takes on `display`.
    func arrangement(on display: OverlayDisplay) -> Arrangement {
        let envelope: NSRect
        switch self {
        case .docked:
            let layout = RecordingOverlayLayout.forDisplay(display)
            if layout.kind == .collar, let housing = display.housing {
                return Arrangement(
                    layout: layout,
                    panelFrame: RecordingOverlayFramePlacement.collarFrame(
                        panelSize: layout.panelSize,
                        housing: housing,
                        displayFrame: display.frame
                    ),
                    centre: CGPoint(x: housing.midX, y: housing.minY)
                )
            }
            envelope = RecordingOverlayFramePlacement.defaultFrame(
                on: display.visibleFrame,
                size: RecordingOverlayMetrics.islandSize,
                padding: RecordingOverlayMetrics.screenPadding,
                topOffset: RecordingOverlayMetrics.topOffset
            )
        case .free(let u, let v):
            envelope = RecordingOverlayFramePlacement.frame(
                u: u,
                v: v,
                size: RecordingOverlayMetrics.islandSize,
                in: display.visibleFrame,
                padding: RecordingOverlayMetrics.screenPadding
            )
        }
        return Arrangement(
            layout: .island,
            panelFrame: RecordingOverlayMetrics.windowFrame(forIsland: envelope),
            centre: CGPoint(x: envelope.midX, y: envelope.midY)
        )
    }

    /// The free placement of an island whose envelope is centred at `centre` on a display whose
    /// visible frame is `visibleFrame`. Each coordinate is held to 0…1, so an envelope past the
    /// padding is placed where the padding stops it.
    static func free(centredAt centre: CGPoint, on visibleFrame: NSRect) -> RecordingOverlayPlacement {
        let origin = RecordingOverlayFramePlacement.normalizedOrigin(
            of: RecordingOverlayFramePlacement.islandEnvelope(centredAt: centre),
            in: visibleFrame,
            padding: RecordingOverlayMetrics.screenPadding
        )
        return .free(u: origin.u, v: origin.v)
    }

    /// Where a body docks on `display`: the centre of the docked arrangement, so a release there puts
    /// the body exactly home.
    static func dockAnchor(on display: OverlayDisplay) -> Anchor {
        let docked = RecordingOverlayPlacement.docked.arrangement(on: display)
        return docked.layout.kind == .collar ? .collar(docked.centre) : .island(docked.centre)
    }
}

// MARK: - Persistence

extension RecordingOverlayPlacement {
    /// The user-defaults keys a placement persists under. A free placement writes both coordinates;
    /// docked removes them, so absent keys are docked.
    enum DefaultsKey {
        static let u = "Voiceour.RecordingOverlay.placement.u"
        static let v = "Voiceour.RecordingOverlay.placement.v"
        /// The absolute panel origin the island's position persisted as before placements existed.
        /// It pinned the island to a point in the global arrangement rather than to a display, and
        /// it is deleted at launch: a clean cutover, after which every install starts docked.
        static let legacyOrigin = ["Voiceour.RecordingOverlay.origin.x", "Voiceour.RecordingOverlay.origin.y"]
    }

    /// The placement `defaults` holds: free where both coordinates are present and finite, each held
    /// to 0…1, and docked otherwise.
    init(defaults: UserDefaults) {
        guard let u = defaults.object(forKey: DefaultsKey.u) as? Double,
            let v = defaults.object(forKey: DefaultsKey.v) as? Double,
            u.isFinite, v.isFinite
        else {
            self = .docked
            return
        }
        self = .free(u: Swift.min(Swift.max(u, 0), 1), v: Swift.min(Swift.max(v, 0), 1))
    }

    func save(to defaults: UserDefaults) {
        switch self {
        case .docked:
            defaults.removeObject(forKey: DefaultsKey.u)
            defaults.removeObject(forKey: DefaultsKey.v)
        case .free(let u, let v):
            defaults.set(u, forKey: DefaultsKey.u)
            defaults.set(v, forKey: DefaultsKey.v)
        }
    }

    static func removeLegacyOrigin(from defaults: UserDefaults) {
        for key in DefaultsKey.legacyOrigin {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Settings ▸ Island

extension RecordingOverlayPlacement {
    /// Where every placement read and write goes: `UserDefaults.standard`, unless the harness or a
    /// test points `RenderOverrides.islandPlacementDefaults` at a scratch suite, so neither reads nor
    /// moves the rendering Mac's own island. The overlay controller and Settings ▸ Island both go
    /// through it, so the Dock Island row describes the placement the controller follows.
    @MainActor static var defaults: UserDefaults {
        RenderOverrides.islandPlacementDefaults ?? .standard
    }

    /// The placement as persisted: what Settings ▸ Island's Dock Island row reads.
    @MainActor static var persisted: RecordingOverlayPlacement {
        RecordingOverlayPlacement(defaults: defaults)
    }

    /// Posted by ``requestDock()`` once docked is persisted. The overlay controller observes it: a
    /// visible free island docks as the status element's Dock island action docks it, and a hidden
    /// one starts its next session docked.
    static let dockRequestNotification = Notification.Name("Voiceour.RecordingOverlay.dockRequest")

    /// Settings ▸ Island's Dock Island: persists docked, then asks the overlay controller to follow.
    @MainActor static func requestDock() {
        RecordingOverlayPlacement.docked.save(to: defaults)
        NotificationCenter.default.post(name: dockRequestNotification, object: nil)
    }
}

// MARK: - Frames

/// The rectangle arithmetic behind placement, in AppKit global coordinates. Placement is computed on
/// the island's 180×34 envelope, never on its transparent 260×80 panel, so `screenPadding` and
/// `topOffset` are clearances a user can see.
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

    /// The collar's panel is its canvas, which centres the housing's outline: centred on the housing
    /// and flush with the display's top edge, the outline lies on the housing itself.
    static func collarFrame(panelSize: NSSize, housing: CGRect, displayFrame: CGRect) -> NSRect {
        NSRect(
            x: housing.midX - panelSize.width / 2,
            y: displayFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Where `frame`'s origin lies in the range the padding leaves it on `visibleFrame`: 0 at the
    /// range's low end and 1 at its high end along each axis, held to 0…1. Along an axis the display
    /// leaves no range on, the one origin it allows is 0.5.
    static func normalizedOrigin(of frame: NSRect, in visibleFrame: NSRect, padding: CGFloat) -> (u: Double, v: Double)
    {
        let xRange = originRange(min: visibleFrame.minX, max: visibleFrame.maxX, length: frame.width, padding: padding)
        let yRange = originRange(min: visibleFrame.minY, max: visibleFrame.maxY, length: frame.height, padding: padding)
        return (Double(normalized(frame.minX, in: xRange)), Double(normalized(frame.minY, in: yRange)))
    }

    /// The frame of `size` whose origin lies at `(u, v)` of the range the padding leaves it on
    /// `visibleFrame`: the inverse of ``normalizedOrigin(of:in:padding:)``.
    static func frame(u: Double, v: Double, size: NSSize, in visibleFrame: NSRect, padding: CGFloat) -> NSRect {
        let xRange = originRange(min: visibleFrame.minX, max: visibleFrame.maxX, length: size.width, padding: padding)
        let yRange = originRange(min: visibleFrame.minY, max: visibleFrame.maxY, length: size.height, padding: padding)
        return NSRect(
            x: xRange.lowerBound + CGFloat(u) * (xRange.upperBound - xRange.lowerBound),
            y: yRange.lowerBound + CGFloat(v) * (yRange.upperBound - yRange.lowerBound),
            width: size.width,
            height: size.height
        )
    }

    /// The island's 180×34 envelope centred at `centre`.
    static func islandEnvelope(centredAt centre: CGPoint) -> NSRect {
        let size = RecordingOverlayMetrics.islandSize
        return NSRect(
            x: centre.x - size.width / 2,
            y: centre.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The island's panel frame with its envelope centred at `centre`.
    static func islandPanelFrame(centredAt centre: CGPoint) -> NSRect {
        RecordingOverlayMetrics.windowFrame(forIsland: islandEnvelope(centredAt: centre))
    }

    /// The centre of the island envelope in the island's panel frame `frame`.
    static func islandCentre(ofPanel frame: NSRect) -> CGPoint {
        let envelope = RecordingOverlayMetrics.islandFrame(forWindow: frame)
        return CGPoint(x: envelope.midX, y: envelope.midY)
    }

    /// Every centre the island envelope may take on `visibleFrame` with `screenPadding` kept on every
    /// side: the centres of the frames a free placement can describe. Zero-sized along an axis the
    /// display leaves no range on.
    static func islandCentres(on visibleFrame: NSRect) -> CGRect {
        let size = RecordingOverlayMetrics.islandSize
        let padding = RecordingOverlayMetrics.screenPadding
        let xRange = originRange(min: visibleFrame.minX, max: visibleFrame.maxX, length: size.width, padding: padding)
        let yRange = originRange(min: visibleFrame.minY, max: visibleFrame.maxY, length: size.height, padding: padding)
        return CGRect(
            x: xRange.lowerBound + size.width / 2,
            y: yRange.lowerBound + size.height / 2,
            width: xRange.upperBound - xRange.lowerBound,
            height: yRange.upperBound - yRange.lowerBound
        )
    }

    private static func clamped(
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
