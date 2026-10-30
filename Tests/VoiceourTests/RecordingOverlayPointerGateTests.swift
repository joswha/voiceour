import AppKit
import Testing

@testable import Voiceour

/// The panel takes the mouse only on the body it drew: within the drag slop of the field, below
/// the menu-bar band, and never while a dwell, a hand-off or a fade forces it click-through. The
/// regions are real fields, laid by the ladder the panel's own drive climbs.
@MainActor
struct RecordingOverlayPointerGateTests {
    /// The speaking collar over a full-screen app spreads its film along the walls and ears into
    /// the band, so the band holds drawn mercury that the gate must still refuse. Below the band the
    /// gate takes exactly what the field covers, and the chin under the housing is the body's.
    @Test func theCollarIgnoresItsBandAndTakesItsChin() {
        let layout = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let model = Self.speaking(on: layout)
        model.update(poseContext: MercuryPoseContext(fullScreen: true))
        let (region, field) = Self.drawn(model)
        let canvas = layout.canvasRect

        var coveredInBand = 0
        var taken = 0
        var mismatches = 0
        var forcedTaken = 0
        for x in stride(from: canvas.minX + 0.25, to: canvas.maxX, by: 0.5) {
            for y in stride(from: canvas.minY + 0.25, to: canvas.maxY, by: 0.5) {
                let point = CGPoint(x: x, y: y)
                let covered =
                    field.value(at: CGPoint(x: x - canvas.midX, y: canvas.midY - y)) >= -MercuryMetrics.dragSlop
                let ignores = Self.ignoresMouse(point, region: region)
                if y < layout.bandHeight {
                    if covered { coveredInBand += 1 }
                    if !ignores { mismatches += 1 }
                } else {
                    if ignores == covered { mismatches += 1 }
                    if !ignores { taken += 1 }
                }
                if !Self.ignoresMouse(point, region: region, forced: true) { forcedTaken += 1 }
            }
        }
        #expect(mismatches == 0)
        #expect(coveredInBand > 0)
        #expect(taken > 0)
        #expect(forcedTaken == 0)

        // 2 pt under the housing's centre, on the chin.
        let chin = CGPoint(x: canvas.midX, y: layout.statusRect.minY + 2)
        #expect(!Self.ignoresMouse(chin, region: region))
        #expect(Self.ignoresMouse(chin, region: region, forced: true))
        #expect(Self.ignoresMouse(nil, region: region))
        // The housing's own centre is in the band and under the housing: never the body's.
        #expect(Self.ignoresMouse(CGPoint(x: canvas.midX, y: layout.bandHeight / 2), region: region))
    }

    /// The island has no band. It takes its body and ignores the rest of its 260×80 panel, which a
    /// panel that never set the flag, or set it false, would have taken whole.
    @Test func theIslandTakesItsBodyAndIgnoresTheRestOfItsPanel() {
        let layout = RecordingOverlayLayout.island
        let (region, field) = Self.drawn(Self.speaking(on: layout))
        let canvas = layout.canvasRect

        let centre = CGPoint(x: canvas.midX, y: canvas.midY)
        #expect(field.value(at: .zero) > 0)
        #expect(!Self.ignoresMouse(centre, region: region))
        #expect(Self.ignoresMouse(centre, region: region, forced: true))
        #expect(Self.ignoresMouse(nil, region: region))
        for corner in [
            CGPoint(x: 1, y: 1), CGPoint(x: layout.panelSize.width - 1, y: 1),
            CGPoint(x: 1, y: layout.panelSize.height - 1),
            CGPoint(x: layout.panelSize.width - 1, y: layout.panelSize.height - 1),
        ] {
            #expect(Self.ignoresMouse(corner, region: region))
        }

        var mismatches = 0
        var taken = 0
        for x in stride(from: canvas.minX + 0.25, to: canvas.maxX, by: 0.5) {
            for y in stride(from: canvas.minY + 0.25, to: canvas.maxY, by: 0.5) {
                let covered =
                    field.value(at: CGPoint(x: x - canvas.midX, y: canvas.midY - y)) >= -MercuryMetrics.dragSlop
                let ignores = Self.ignoresMouse(CGPoint(x: x, y: y), region: region)
                if ignores == covered { mismatches += 1 }
                if !ignores { taken += 1 }
            }
        }
        #expect(mismatches == 0)
        #expect(taken > 0)

        // An empty region, the idle body's, takes nothing.
        region.clear()
        #expect(Self.ignoresMouse(centre, region: region))
    }

    /// `NSEvent.mouseLocation` is global and measured up from the bottom; the hit region reads
    /// points down from the panel's top-left.
    @Test func theMouseLocationTurnsIntoThePanelsFlippedSpace() throws {
        let display = OverlayDisplay.fixtureNotch
        let housing = try #require(display.housing)
        let layout = RecordingOverlayLayout.forDisplay(display)
        let panel = RecordingOverlayController.collarFrame(
            panelSize: layout.panelSize,
            housing: housing,
            displayFrame: display.frame
        )
        #expect(panel == CGRect(x: 707, y: 1_065, width: 314, height: 52))

        #expect(
            RecordingOverlayPointerGate.pointInPanel(CGPoint(x: 864, y: 1_077), panelFrame: panel)
                == CGPoint(x: 157, y: 40)
        )
        #expect(
            RecordingOverlayPointerGate.pointInPanel(CGPoint(x: 707, y: 1_065), panelFrame: panel)
                == CGPoint(x: 0, y: 52)
        )
        #expect(RecordingOverlayPointerGate.pointInPanel(CGPoint(x: 1_021, y: 1_100), panelFrame: panel) == nil)
        #expect(RecordingOverlayPointerGate.pointInPanel(CGPoint(x: 600, y: 1_100), panelFrame: panel) == nil)

        // 2 pt under the housing, in global coordinates, is the chin the collar takes.
        let model = Self.speaking(on: layout)
        let (region, _) = Self.drawn(model)
        let chin = RecordingOverlayPointerGate.pointInPanel(
            CGPoint(x: housing.midX, y: housing.minY - 2),
            panelFrame: panel
        )
        #expect(chin == CGPoint(x: layout.canvasRect.midX, y: layout.statusRect.minY + 2))
        #expect(!Self.ignoresMouse(chin, region: region))
    }

    /// A write per frame would be a window-server round trip for nothing, so the panel hears only
    /// the changes, and the first answer whatever it is: until then AppKit's alpha test decides.
    @Test func theGateWritesThePanelOnlyWhenItsAnswerChanges() {
        let panel = CountingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        var gate = RecordingOverlayPointerGate()
        #expect(gate.ignoresMouse == nil)

        for answer in [false, false, true, true, true, false, true] {
            gate.set(ignoresMouse: answer, on: panel)
        }
        #expect(panel.writes == [false, true, false, true])
        #expect(panel.ignoresMouseEvents)
        #expect(gate.ignoresMouse == true)
    }

    /// The band beside the housing, `bandReach` either side of it, is where the pointer reaches for
    /// a menu. A display without a housing has none.
    @Test func thePointerIsInTheBandBesideTheHousingOnly() throws {
        let display = OverlayDisplay.fixtureNotch
        let housing = try #require(display.housing)
        let top = display.frame.maxY
        let bandFloor = top - display.bandHeight
        let reach = RecordingOverlayController.bandReach
        func inBand(_ x: CGFloat, _ y: CGFloat, on display: OverlayDisplay = .fixtureNotch) -> Bool {
            RecordingOverlayController.isPointerInBand(CGPoint(x: x, y: y), display: display)
        }

        #expect(inBand(housing.midX, top - 10))
        #expect(inBand(housing.midX, top))
        #expect(inBand(housing.midX, bandFloor))
        #expect(!inBand(housing.midX, bandFloor - 0.5))
        #expect(inBand(housing.minX - reach, top - 10))
        #expect(!inBand(housing.minX - reach - 0.5, top - 10))
        #expect(inBand(housing.maxX + reach, top - 10))
        #expect(!inBand(housing.maxX + reach + 0.5, top - 10))
        #expect(!inBand(housing.midX, top - 10, on: .fixtureNotchless))
    }

    // MARK: - Helpers

    private static func ignoresMouse(_ point: CGPoint?, region: MercuryHitRegion, forced: Bool = false) -> Bool {
        RecordingOverlayPointerGate.ignoresMouse(pointerInPanel: point, hitRegion: region, forcedClickThrough: forced)
    }

    /// A speaking session on `layout`: live capture past the voice-activity hysteresis.
    private static func speaking(on layout: RecordingOverlayLayout) -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(layout: layout)
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in MercurySpeechMeter.syllable {
            model.record(level)
        }
        return model
    }

    /// The body `model`'s drive settles into after five seconds, laid on its layout, and the region
    /// the panel would route the mouse against.
    private static func drawn(_ model: RecordingOverlayModel) -> (region: MercuryHitRegion, field: MercuryField) {
        let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
        let simulation = MercurySimulation(seed: 21, gains: MercuryGains(drive: 1, snake: 0.011))
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        let layout = model.layout
        let field = MercuryField(geometry: simulation.geometry, spine: layout.spine, canvas: layout.canvasRect.size)
        let region = MercuryHitRegion()
        region.update(field, layout: layout)
        return (region, field)
    }
}

/// Records every value written to `ignoresMouseEvents`.
private final class CountingPanel: NSPanel {
    private(set) var writes: [Bool] = []

    override var ignoresMouseEvents: Bool {
        didSet { writes.append(ignoresMouseEvents) }
    }
}
