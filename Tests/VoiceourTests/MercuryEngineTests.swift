import CoreGraphics
import Foundation
import Testing

@testable import Voiceour

@MainActor
struct MercuryEngineTests {
    @Test func reseedingRebuildsTheBodyAndLightingTogether() throws {
        let drive = Drives.speaking()
        let reused = MercuryEngine(
            seed: 1,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        _ = reused.pinnedFrame(
            step: 600,
            seed: 1,
            world: .roomOfTen,
            drive: drive,
            appearance: .standard,
            layout: .island
        )
        let reseeded = try #require(
            reused.pinnedFrame(
                step: 600,
                seed: 2,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        let fresh = MercuryEngine(
            seed: 2,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let expected = try #require(
            fresh.pinnedFrame(
                step: 600,
                seed: 2,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        #expect(Self.bytes(reseeded) == Self.bytes(expected))
    }

    @Test func livePresentationRendersEveryCommittedStepAndCachesDuplicates() throws {
        let drive = Drives.speaking()
        let engine = MercuryEngine(
            seed: 7,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let first = try Self.emerged(engine, seed: 7, drive: drive, appearance: .standard, layout: .island)
        let duplicate = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        let next = try #require(
            engine.frame(
                advancing: 1,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )

        #expect(first === duplicate)
        #expect(first !== next)
    }

    @Test func appearanceChangesAlwaysRerasterTheCurrentGeometry() throws {
        let drive = Drives.speaking()
        let engine = MercuryEngine(
            seed: 9,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let standard = try Self.emerged(engine, seed: 9, drive: drive, appearance: .standard, layout: .island)
        let increased = try #require(
            engine.frame(
                advancing: 0,
                seed: 9,
                world: .roomOfTen,
                drive: drive,
                appearance: MercuryAppearance(increasedContrast: true),
                layout: .island
            )
        )

        #expect(standard !== increased)
    }

    /// A collar frame covers exactly its canvas at the raster scale, and not one of its
    /// pixels inside the camera housing is set. The body runs along nine tenths of the
    /// spine, so the walls, the fillets and both ears carry mercury right beside the housing
    /// edge; the housing is rebuilt from its outline here rather than read through the chart
    /// the rasterizer consults.
    @Test(arguments: [OverlayDisplay.fixtureNotch, .fixtureWideNotch])
    func collarPinnedFramesFillTheirCanvasAndNeverDrawInsideTheHousing(display: OverlayDisplay) throws {
        let layout = RecordingOverlayLayout.forDisplay(display)
        guard case .collar(let outline) = layout.spine.kind else {
            Issue.record("a notched display wears the collar")
            return
        }
        let engine = MercuryEngine(
            seed: 5,
            world: .roomOfTen,
            hitRegion: MercuryHitRegion()
        )
        let image = try #require(
            engine.pinnedFrame(
                step: 600,
                seed: 5,
                world: .roomOfTen,
                drive: Drives.collar(spine: layout.spine),
                appearance: .standard,
                layout: layout
            )
        )
        let scale = Double(MercuryMetrics.rasterScale)
        let canvas = layout.canvasRect.size
        #expect(image.width == Int((Double(canvas.width) * scale).rounded()))
        #expect(image.height == Int((Double(canvas.height) * scale).rounded()))

        let bytes = [UInt8](Self.bytes(image))
        var housed = 0
        var drawnInHousing = 0
        var drawnOutside = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * 4
                let drawn = bytes[offset..<offset + 4].contains { $0 != 0 }
                let centre = SIMD2(
                    (Double(column) + 0.5) / scale - Double(canvas.width) / 2,
                    Double(canvas.height) / 2 - (Double(row) + 0.5) / scale
                )
                if Self.housing(outline, contains: centre) {
                    housed += 1
                    if drawn { drawnInHousing += 1 }
                } else if drawn {
                    drawnOutside += 1
                }
            }
        }
        #expect(housed > 0)
        #expect(drawnInHousing == 0)
        #expect(drawnOutside > 0)
    }

    /// A repeated collar frame is the image already on the layer, a layout change is a new
    /// image, and the hit region answers in the layout of the frame it was last handed.
    @Test func collarFramesReuseTheirImageAndHandTheHitRegionTheirLayout() throws {
        let drive = Drives.speaking()
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let region = MercuryHitRegion()
        let engine = MercuryEngine(seed: 7, world: .roomOfTen, hitRegion: region)
        let island = try Self.emerged(engine, seed: 7, drive: drive, appearance: .standard, layout: .island)
        // 3 pt above the island's centre: on the island's body, and in the collar's band.
        let raised = CGPoint(x: 130, y: 30)
        #expect(region.contains(raised, slop: MercuryMetrics.dragSlop))

        let collared = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let repeated = try #require(
            engine.frame(
                advancing: 0,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        #expect(collared !== island)
        #expect(collared === repeated)
        #expect(collared.width == Int((collar.canvasRect.width * MercuryMetrics.rasterScale).rounded()))
        #expect(!region.contains(raised, slop: MercuryMetrics.dragSlop))
        // 2 pt under the housing's centre, on the chin.
        #expect(region.contains(CGPoint(x: collar.canvasRect.midX, y: collar.statusRect.minY + 2), slop: 0))

        let stepped = try #require(
            engine.frame(
                advancing: 1,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        #expect(stepped !== collared)

        let pinning = MercuryEngine(seed: 7, world: .roomOfTen, hitRegion: MercuryHitRegion())
        let pinned = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let pinnedAgain = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: collar
            )
        )
        let pinnedIsland = try #require(
            pinning.pinnedFrame(
                step: 120,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: .standard,
                layout: .island
            )
        )
        #expect(pinned === pinnedAgain)
        #expect(pinnedIsland !== pinned)
    }

    /// A room is metered against the bodies of the layout it lights. An engine meters once
    /// for the first layout it draws and keeps that response for every frame on it, whatever
    /// the appearance or the step; a frame on another layout meters again, in the same room.
    /// So a collar the engine reaches from the island is lit exactly as a collar it started
    /// on, and never by the island's response.
    @Test func lightingIsMeteredOnTheLayoutItLightsAndKeptUntilTheLayoutChanges() throws {
        let drive = Drives.speaking()
        let collar = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let room = MercuryEnvironment(world: .roomOfTen, seed: 7)
        let calibration = MercuryCalibration.shared
        // Two different responses, or nothing below could tell which one lit a frame.
        #expect(
            calibration.displayResponse(for: room, bodySeed: 7, layout: .island)
                != calibration.displayResponse(for: room, bodySeed: 7, layout: collar)
        )

        let engine = MercuryEngine(seed: 7, world: .roomOfTen, hitRegion: MercuryHitRegion())
        func frame(
            advancing steps: Int,
            on layout: RecordingOverlayLayout,
            appearance: MercuryAppearance = .standard
        ) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: 7,
                world: .roomOfTen,
                drive: drive,
                appearance: appearance,
                layout: layout
            )
        }
        // The emerging body's first frame is empty, and an empty frame lights nothing.
        #expect(frame(advancing: 0, on: .island) == nil)
        #expect(engine.meteredResponses == 0)
        for _ in 0..<60 {
            _ = frame(advancing: 2, on: .island)
        }
        _ = try #require(frame(advancing: 1, on: .island, appearance: MercuryAppearance(increasedContrast: true)))
        #expect(engine.meteredResponses == 1)

        _ = try #require(frame(advancing: 1, on: collar))
        #expect(engine.meteredResponses == 2)
        for _ in 0..<60 {
            _ = frame(advancing: 2, on: collar)
        }
        #expect(engine.meteredResponses == 2)
        _ = try #require(frame(advancing: 1, on: .island))
        #expect(engine.meteredResponses == 3)

        let travelled = MercuryEngine(seed: 7, world: .roomOfTen, hitRegion: MercuryHitRegion())
        let fresh = MercuryEngine(seed: 7, world: .roomOfTen, hitRegion: MercuryHitRegion())
        func pinned(_ engine: MercuryEngine, step: Int, on layout: RecordingOverlayLayout) throws -> CGImage {
            try #require(
                engine.pinnedFrame(
                    step: step,
                    seed: 7,
                    world: .roomOfTen,
                    drive: drive,
                    appearance: .standard,
                    layout: layout
                )
            )
        }
        _ = try pinned(travelled, step: 120, on: .island)
        let relit = try pinned(travelled, step: 120, on: collar)
        let collarFromTheStart = try pinned(fresh, step: 120, on: collar)
        #expect(Self.bytes(relit) == Self.bytes(collarFromTheStart))
        _ = try pinned(travelled, step: 240, on: collar)
        #expect(travelled.meteredResponses == 2)
        #expect(fresh.meteredResponses == 1)
    }

    /// Strictly inside the camera housing: between its walls and above its bottom edge, less
    /// the two rounded bottom corners.
    private static func housing(_ outline: MercurySpine.Outline, contains point: SIMD2<Double>) -> Bool {
        guard point.x > outline.minX, point.x < outline.maxX, point.y > outline.bottom else { return false }
        let radius = outline.cornerRadius
        let cornerY = outline.bottom + radius
        guard point.y < cornerY else { return true }
        let cornerX = Swift.min(Swift.max(point.x, outline.minX + radius), outline.maxX - radius)
        let lateral = point.x - cornerX
        let vertical = point.y - cornerY
        return lateral * lateral + vertical * vertical < radius * radius
    }

    private static func bytes(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    /// A fresh engine's emergence. Its first live frame is the empty body about to grow out of
    /// the top edge, which draws nothing; 0.6 s of full frames later the body is in its pose.
    private static func emerged(
        _ engine: MercuryEngine,
        seed: UInt64,
        drive: MercurySimulation.Drive,
        appearance: MercuryAppearance,
        layout: RecordingOverlayLayout
    ) throws -> CGImage {
        func frame(advancing steps: Int) -> CGImage? {
            engine.frame(
                advancing: steps,
                seed: seed,
                world: .roomOfTen,
                drive: drive,
                appearance: appearance,
                layout: layout
            )
        }
        #expect(frame(advancing: 0) == nil)
        var image: CGImage?
        for _ in 0..<18 {
            image = frame(advancing: MercuryMetrics.maxSubstepsPerFrame)
        }
        return try #require(image)
    }
}

/// The two layouts, held to the numbers they are built from: the island's established
/// frames, and each notch fixture's collar rebuilt here from its housing rect.
@MainActor
struct RecordingOverlayLayoutTests {
    /// The panel and the status element keep the island's established frames: the element is
    /// exactly the envelope placement measures, turned into the panel's flipped space. The
    /// canvas runs 8 pt past it at each end, centred on it, and the spine runs the canvas.
    @Test func theIslandKeepsItsEstablishedFrames() {
        let island = RecordingOverlayLayout.island
        #expect(island.kind == .island)
        #expect(island.panelSize == NSSize(width: 260, height: 80))
        #expect(island.statusRect == CGRect(x: 40, y: 16, width: 180, height: 34))
        let panel = NSRect(origin: .zero, size: RecordingOverlayMetrics.windowSize)
        let envelope = RecordingOverlayMetrics.islandFrame(forWindow: panel)
        #expect(island.statusRect == CGRect(x: envelope.minX, y: panel.maxY - envelope.maxY, width: 180, height: 34))
        #expect(island.canvasRect == CGRect(x: 32, y: 16, width: 196, height: 34))
        #expect(island.canvasRect.midX == island.statusRect.midX)
        #expect(island.spine == MercurySpine(straightLength: 196))
        #expect(island.bandHeight == 0)
    }

    /// The canvas reaches the 4.5 pt fillet, the 56 pt ear and 4 pt more beyond each wall,
    /// and the collar's 24 pt ceiling + 3 pt below the housing, which hangs centred from its top
    /// edge. The status element is the chin's strip directly under the housing.
    @Test func notchedDisplaysWearACollarHungFromTheTopEdge() throws {
        let expectations: [(display: OverlayDisplay, canvas: CGSize, status: CGRect, outline: MercurySpine.Outline)] = [
            (
                .fixtureNotch,
                CGSize(width: 314, height: 59),
                CGRect(x: 64.5, y: 32, width: 185, height: 27),
                MercurySpine.Outline(
                    minX: -92.5,
                    maxX: 92.5,
                    bottom: -2.5,
                    top: 29.5,
                    cornerRadius: 0.44 * 32,
                    filletRadius: 4.5,
                    earLength: 56,
                    bandFilm: 3.5,
                    maxHalfHeight: 24
                )
            ),
            (
                .fixtureWideNotch,
                CGSize(width: 349, height: 65),
                CGRect(x: 64.5, y: 38, width: 220, height: 27),
                // 0.44 × 38 = 16.72 rounds to the largest corner, 16 pt.
                MercurySpine.Outline(
                    minX: -110,
                    maxX: 110,
                    bottom: -5.5,
                    top: 32.5,
                    cornerRadius: 16,
                    filletRadius: 4.5,
                    earLength: 56,
                    bandFilm: 3.5,
                    maxHalfHeight: 24
                )
            ),
        ]
        for expected in expectations {
            let layout = RecordingOverlayLayout.forDisplay(expected.display)
            #expect(layout.kind == .collar)
            #expect(layout.panelSize == expected.canvas)
            #expect(layout.canvasRect == CGRect(origin: .zero, size: expected.canvas))
            #expect(layout.statusRect == expected.status)
            #expect(layout.bandHeight == expected.display.bandHeight)
            #expect(layout.spine.kind == .collar(expected.outline))
            #expect(layout.spine == MercurySpine(collar: expected.outline))
            let housing = try #require(expected.display.housing)
            #expect(
                RecordingOverlayLayout.collar(housingSize: housing.size, bandHeight: expected.display.bandHeight)
                    == layout
            )
        }
    }

    @Test func displaysWithoutAWearableHousingGetTheIsland() {
        #expect(RecordingOverlayLayout.forDisplay(.fixtureNotchless) == .island)
        var mirrored = OverlayDisplay.fixtureNotch
        mirrored.isMirrored = true
        #expect(RecordingOverlayLayout.forDisplay(mirrored) == .island)
        var shallow = OverlayDisplay.fixtureNotch
        shallow.housing = CGRect(x: 771.5, y: 1_107, width: 185, height: 10)
        #expect(RecordingOverlayLayout.forDisplay(shallow) == .island)
    }

    /// The spine lays any housing taller than its fillet. The layout refuses one that would
    /// round its corner below 6 pt, `4.5 + 6` pt deep or less, and one no wider than its two
    /// corners, which leaves the chin no bottom run.
    @Test func housingsTooShallowOrTooNarrowAreNotCollars() {
        func collar(width: CGFloat, height: CGFloat) -> RecordingOverlayLayout? {
            RecordingOverlayLayout.collar(
                housingSize: CGSize(width: width, height: height),
                bandHeight: height + 1
            )
        }
        #expect(collar(width: 185, height: 10.5) == nil)
        #expect(collar(width: 185, height: 11)?.kind == .collar)
        let corners = CGFloat(2 * 0.44 * 32)
        #expect(collar(width: corners, height: 32) == nil)
        #expect(collar(width: corners + 0.5, height: 32)?.kind == .collar)
        #expect(collar(width: 0, height: 32) == nil)
        #expect(collar(width: .nan, height: 32) == nil)
        #expect(collar(width: 185, height: .infinity) == nil)
    }

    /// The collar's film in the menu-bar band is drawn but never claimed. Below the band the
    /// region is exactly the field with its drag slop, converted through the canvas.
    @Test func theCollarHitRegionRejectsTheMenuBarBandAndAcceptsTheChin() {
        let layout = RecordingOverlayLayout.forDisplay(.fixtureNotch)
        let drive = Drives.collar(spine: layout.spine)
        let simulation = MercurySimulation(seed: 21, gains: MercuryGains(drive: 1, snake: 0.011))
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        let field = MercuryField(
            geometry: simulation.geometry,
            spine: layout.spine,
            canvas: layout.canvasRect.size
        )
        let region = MercuryHitRegion()
        region.update(field, layout: layout)
        let slop = MercuryMetrics.dragSlop
        let canvas = layout.canvasRect

        var mismatches = 0
        var coveredInBand = 0
        var claimed = 0
        for x in stride(from: canvas.minX + 0.25, to: canvas.maxX, by: 0.5) {
            for y in stride(from: canvas.minY + 0.25, to: canvas.maxY, by: 0.5) {
                let covered = field.value(at: CGPoint(x: x - canvas.midX, y: canvas.midY - y)) >= -slop
                let contained = region.contains(CGPoint(x: x, y: y), slop: slop)
                if y < layout.bandHeight {
                    if covered { coveredInBand += 1 }
                    if contained { mismatches += 1 }
                } else {
                    if contained != covered { mismatches += 1 }
                    if contained { claimed += 1 }
                }
            }
        }
        #expect(mismatches == 0)
        #expect(coveredInBand > 0)
        #expect(claimed > 0)

        // 2 pt under the housing's centre, on the chin.
        let chin = CGPoint(x: canvas.midX, y: layout.statusRect.minY + 2)
        #expect(region.contains(chin, slop: 0))
        region.clear()
        #expect(!region.contains(chin, slop: slop))
    }
}

@MainActor
private enum Drives {
    static func speaking() -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in MercurySpeechMeter.syllable {
            model.record(level)
        }
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: false
        )
    }

    /// The speaking drive on a body nine tenths of the spine long, which the collar's whole
    /// spine lets it grow to: it covers the bottom and both corners, climbs the walls, turns
    /// the fillets and runs out along both ears.
    static func collar(spine: MercurySpine) -> MercurySimulation.Drive {
        var drive = speaking()
        drive.pose.length = CGFloat(0.9 * spine.length)
        drive.maxLength = spine.length
        return drive
    }
}
