import AppKit
import Testing

@testable import Voiceour

/// Where a placement puts the body on a display, how a free placement is normalized so it means the
/// same relative spot on every display, and how it persists.
struct RecordingOverlayPlacementTests {
    private static let padding = RecordingOverlayMetrics.screenPadding
    private static let island = RecordingOverlayMetrics.islandSize

    /// A free placement's `(u, v)` survives the round trip from an envelope to its frame on one
    /// display, and holds the same relative spot on a display of another size and place.
    @Test func aFreePlacementIsTheSameRelativeSpotOnEveryDisplay() {
        let source = NSRect(x: 0, y: 0, width: 1_728, height: 1_084)
        let destination = NSRect(x: 1_728, y: -323, width: 2_560, height: 1_440)
        let envelope = NSRect(x: 826, y: 205, width: Self.island.width, height: Self.island.height)

        let origin = RecordingOverlayFramePlacement.normalizedOrigin(of: envelope, in: source, padding: Self.padding)
        let back = RecordingOverlayFramePlacement.frame(
            u: origin.u, v: origin.v, size: Self.island, in: source, padding: Self.padding)
        #expect(abs(back.minX - envelope.minX) < 1e-9 && abs(back.minY - envelope.minY) < 1e-9)

        let moved = RecordingOverlayFramePlacement.frame(
            u: origin.u, v: origin.v, size: Self.island, in: destination, padding: Self.padding)
        #expect(moved.minX >= destination.minX + Self.padding && moved.maxX <= destination.maxX - Self.padding)
        #expect(moved.minY >= destination.minY + Self.padding && moved.maxY <= destination.maxY - Self.padding)
        let there = RecordingOverlayFramePlacement.normalizedOrigin(of: moved, in: destination, padding: Self.padding)
        #expect(abs(there.u - origin.u) < 1e-9 && abs(there.v - origin.v) < 1e-9)
        #expect(abs(origin.u - (826.0 - 16) / (1_728.0 - 180 - 32)) < 1e-12)

        // The same placement through the arrangement each display takes.
        let free = RecordingOverlayPlacement.free(
            centredAt: CGPoint(x: envelope.midX, y: envelope.midY), on: source)
        #expect(free == .free(u: origin.u, v: origin.v))
    }

    /// An envelope dragged past the padding is placed where the padding stops it.
    @Test func aFreePlacementIsHeldToThePaddedRange() {
        let visible = OverlayDisplay.fixtureNotchless.visibleFrame
        #expect(RecordingOverlayPlacement.free(centredAt: CGPoint(x: -400, y: 5_000), on: visible) == .free(u: 0, v: 1))
        #expect(RecordingOverlayPlacement.free(centredAt: CGPoint(x: 9_000, y: -80), on: visible) == .free(u: 1, v: 0))
        let corner = RecordingOverlayPlacement.free(u: 1, v: 1).arrangement(on: .fixtureNotchless)
        let envelope = RecordingOverlayMetrics.islandFrame(forWindow: corner.panelFrame)
        #expect(envelope.maxX == visible.maxX - Self.padding && envelope.maxY == visible.maxY - Self.padding)
        let centres = RecordingOverlayFramePlacement.islandCentres(on: visible)
        #expect(centres == CGRect(x: 106, y: 33, width: 1_300, height: 892))
    }

    /// Docked is the collar at the housing on a notched display and the island at its default spot
    /// on any other; free is the island everywhere, the notched display included.
    @Test func dockedAndFreeArrangeEachFixtureDisplay() throws {
        let collar = RecordingOverlayPlacement.docked.arrangement(on: .fixtureNotch)
        #expect(collar.layout.kind == .collar)
        #expect(collar.panelFrame == CGRect(x: 707, y: 1_065, width: 314, height: 52))
        #expect(collar.centre == CGPoint(x: 864, y: 1_085))
        #expect(RecordingOverlayPlacement.dockAnchor(on: .fixtureNotch) == .collar(CGPoint(x: 864, y: 1_085)))

        let docked = RecordingOverlayPlacement.docked.arrangement(on: .fixtureNotchless)
        #expect(docked.layout == .island)
        #expect(docked.panelFrame == CGRect(x: 626, y: 850, width: 260, height: 80))
        #expect(docked.centre == CGPoint(x: 756, y: 897))
        #expect(RecordingOverlayPlacement.dockAnchor(on: .fixtureNotchless) == .island(CGPoint(x: 756, y: 897)))
        let envelope = RecordingOverlayMetrics.islandFrame(forWindow: docked.panelFrame)
        #expect(envelope.maxY == OverlayDisplay.fixtureNotchless.visibleFrame.maxY - RecordingOverlayMetrics.topOffset)

        let free = RecordingOverlayPlacement.free(u: 0.25, v: 0.5).arrangement(on: .fixtureNotch)
        #expect(free.layout == .island)
        #expect(free.centre == RecordingOverlayFramePlacement.islandCentre(ofPanel: free.panelFrame))
        #expect(free.panelFrame == RecordingOverlayFramePlacement.islandPanelFrame(centredAt: free.centre))
    }

    /// Persisted under the placement keys: a free placement round-trips, absent keys and malformed
    /// ones are docked, docking removes the keys, and the legacy absolute origin is deleted alone.
    @Test func thePlacementPersistsUnderItsOwnKeys() throws {
        let suite = "RecordingOverlayPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Key = RecordingOverlayPlacement.DefaultsKey

        #expect(RecordingOverlayPlacement(defaults: defaults) == .docked)
        RecordingOverlayPlacement.free(u: 0.125, v: 0.75).save(to: defaults)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .free(u: 0.125, v: 0.75))
        RecordingOverlayPlacement.docked.save(to: defaults)
        #expect(defaults.object(forKey: Key.u) == nil && defaults.object(forKey: Key.v) == nil)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .docked)

        defaults.set(0.5, forKey: Key.u)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .docked)
        defaults.set(Double.nan, forKey: Key.v)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .docked)
        defaults.set(1.5, forKey: Key.v)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .free(u: 0.5, v: 1))

        defaults.set(786.0, forKey: "Voiceour.RecordingOverlay.origin.x")
        defaults.set(169.0, forKey: "Voiceour.RecordingOverlay.origin.y")
        RecordingOverlayPlacement.removeLegacyOrigin(from: defaults)
        #expect(defaults.object(forKey: "Voiceour.RecordingOverlay.origin.x") == nil)
        #expect(defaults.object(forKey: "Voiceour.RecordingOverlay.origin.y") == nil)
        #expect(RecordingOverlayPlacement(defaults: defaults) == .free(u: 0.5, v: 1))
    }

    @Test func defaultPositionUsesDestinationTopCenter() {
        let destination = NSRect(x: 1_728, y: -323, width: 2_560, height: 1_440)
        let frame = RecordingOverlayFramePlacement.defaultFrame(
            on: destination,
            size: NSSize(width: 260, height: 80),
            padding: 14,
            topOffset: 44
        )
        #expect(frame.midX == destination.midX)
        #expect(frame.maxY == destination.maxY - 44)
    }
}
