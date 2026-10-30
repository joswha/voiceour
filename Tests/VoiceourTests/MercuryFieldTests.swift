import CoreGraphics
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// The invariant that keeps the clickable region and the drawn pixels from ever
/// disagreeing: they are the same scalar field.
///
/// This matters more here than on any other surface in the app. The island floats over
/// content it cannot see, and a transparent rectangle that swallows clicks the user
/// cannot see is worse than no island at all. The collar sits in the menu bar's own
/// band, where a stray covered pixel would sit on top of a menu.
@MainActor
struct MercuryFieldTests {
    /// One collar body, simulated and drawn once for every collar test.
    private struct CollarBody {
        var name: String
        var halfHeight: CGFloat
        var geometry: MercurySimulation.Geometry
        var field: MercuryField
        var image: CGImage
        var alpha: [UInt8]
    }

    private struct Collar {
        var name: String
        var layout: RecordingOverlayLayout
        var bodies: [CollarBody]
    }

    private static let gains = MercuryGains(drive: 1, snake: 0.011)
    private static let island = RecordingOverlayLayout.island
    private static let scale = MercuryMetrics.rasterScale
    private static let speaking = MercurySpeechMeter.syllable
    private static let environment = MercuryEnvironment(world: .roomOfTen, seed: 3)
    private static let response = MercuryCalibration.shared.displayResponse(
        for: environment, bodySeed: 3, layout: island)

    /// The collar on both measured housings: the 185×32 pt notch of the default 14-inch
    /// panel and the 220×38 pt one the same panel shows at More Space. Each wears speaking
    /// bodies at the speaking half-height and a deeper one: a chin that wraps the corners,
    /// one that climbs the walls, and one that runs the whole spine to the far ends of both
    /// ears, which is also swayed 8 pt so one end runs past its ear. The pose ladder's
    /// longest collar body stops short of the ears' ends, so these poses are built here.
    private static let collars: [Collar] = {
        let rasterizer = MercuryRasterizer()
        let displays = [("notch", OverlayDisplay.fixtureNotch), ("wide notch", OverlayDisplay.fixtureWideNotch)]
        return displays.compactMap { name, display in
            guard
                let housing = display.housing,
                let layout = RecordingOverlayLayout.collar(housingSize: housing.size, bandHeight: display.bandHeight)
            else { return nil }
            var bodies: [CollarBody] = []
            for fraction in [0.45, 0.7, 1.0] {
                for halfHeight: CGFloat in [11.5, 16] {
                    for lateralOffset: CGFloat in fraction == 1 ? [0, 8] : [0] {
                        let pose = MercuryPose(
                            length: CGFloat(fraction * layout.spine.length),
                            halfHeight: halfHeight,
                            lateralOffset: lateralOffset,
                            driveScale: 1,
                            gesture: nil
                        )
                        let geometry = Self.geometry(pose: pose, samples: speaking, seed: 29, layout: layout)
                        let field = MercuryField(
                            geometry: geometry,
                            spine: layout.spine,
                            canvas: layout.canvasRect.size
                        )
                        guard
                            let image = rasterizer.image(
                                field: field,
                                environment: environment,
                                response: response,
                                appearance: .standard,
                                scale: scale
                            ),
                            let alpha = alphaChannel(of: image)
                        else { continue }
                        bodies.append(
                            CollarBody(
                                name: "\(name), \(Int(fraction * 100))% of the spine, H \(halfHeight), "
                                    + "offset \(lateralOffset)",
                                halfHeight: halfHeight,
                                geometry: geometry,
                                field: field,
                                image: image,
                                alpha: alpha
                            )
                        )
                    }
                }
            }
            return Collar(name: name, layout: layout, bodies: bodies)
        }
    }()

    /// Both collars with every body drawn, or a failure that says which part is missing.
    private static func requireCollars() throws -> [Collar] {
        try #require(collars.count == 2, "a fixture housing laid no collar")
        for collar in collars {
            try #require(collar.bodies.count == 8, "\(collar.name) drew \(collar.bodies.count) of 8 bodies")
        }
        return collars
    }

    private static func poses() -> [(name: String, pose: MercuryPose, samples: [Float])] {
        let quiet: [Float] = [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]

        func model(_ levels: [Float], live: Bool, state: SessionState = .recording) -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(state)
            model.updateCaptureLive(live)
            for level in levels { model.record(level) }
            return model
        }

        let copied = RecordingOverlayModel()
        let copiedState = SessionState.copiedOnly(reason: "target_terminal")
        copied.update(copiedState)
        if let outcome = RecordingOverlayOutcome(state: copiedState) {
            copied.present(outcome)
        }

        let failed = RecordingOverlayModel()
        let failedState = SessionState.insertFailed(reason: "no focused element")
        failed.update(failedState)
        if let outcome = RecordingOverlayOutcome(state: failedState) {
            failed.present(outcome)
        }

        let errored = RecordingOverlayModel()
        let erroredState = SessionState.error(.inferenceFailed)
        errored.update(erroredState)
        if let outcome = RecordingOverlayOutcome(state: erroredState) {
            errored.present(outcome)
        }

        return [
            ("speaking", MercuryPose.target(for: model(speaking, live: true)), speaking),
            ("listening", MercuryPose.target(for: model(quiet, live: true)), quiet),
            ("warming", MercuryPose.target(for: model(speaking, live: false)), speaking),
            (
                "processing",
                MercuryPose.target(for: model([], live: false, state: .transcribing)),
                [Float](repeating: 0, count: 11)
            ),
            ("lurch", MercuryPose.target(for: failed), [Float](repeating: 0, count: 11)),
            ("gathered", MercuryPose.target(for: copied), [Float](repeating: 0, count: 11)),
            ("collapse", MercuryPose.target(for: errored), [Float](repeating: 0, count: 11)),
        ]
    }

    /// The body after 600 substeps at rest on `pose`, on a drive that lets it grow as long as
    /// the ribbon's own drive does on `layout`: the whole spine on a collar, 168 pt on the island.
    private static func geometry(
        pose: MercuryPose,
        samples: [Float],
        seed: UInt64,
        layout: RecordingOverlayLayout = island
    ) -> MercurySimulation.Geometry {
        let drive = MercurySimulation.Drive(
            pose: pose,
            samples: samples,
            reduceMotion: false,
            maxLength: layout.kind == .collar ? layout.spine.length : Double(MercuryMetrics.maxLength)
        )
        let simulation = MercurySimulation(seed: seed, gains: gains)
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        return simulation.geometry
    }

    private static func field(
        pose: MercuryPose,
        samples: [Float],
        seed: UInt64,
        layout: RecordingOverlayLayout = island
    ) -> MercuryField {
        MercuryField(
            geometry: geometry(pose: pose, samples: samples, seed: seed, layout: layout),
            spine: layout.spine,
            canvas: layout.canvasRect.size
        )
    }

    private static func outline(of spine: MercurySpine) -> MercurySpine.Outline? {
        guard case .collar(let outline) = spine.kind else { return nil }
        return outline
    }

    /// The drawn alpha and the drag predicate answer the same question everywhere except
    /// inside the one-pixel band the coverage ramp occupies, which is the band both of
    /// them define as the boundary, and inside the one-pixel band along the housing's
    /// outline, where the chart itself ends: a pixel centred under the housing is never drawn,
    /// and one centred just outside it keeps only its share outside the rim.
    @Test func theDrawnBodyAndTheClickableRegionAgree() throws {
        let rasterizer = MercuryRasterizer()
        for seed in [UInt64(3), 29, 0x5155_4943_4B53_4C56] {
            for entry in Self.poses() where entry.pose.length > 0 {
                let field = Self.field(pose: entry.pose, samples: entry.samples, seed: seed)
                guard
                    let image = rasterizer.image(
                        field: field,
                        environment: Self.environment,
                        response: Self.response,
                        appearance: .standard,
                        scale: Self.scale
                    ),
                    let alpha = Self.alphaChannel(of: image)
                else {
                    Issue.record("\(entry.name) produced no image")
                    continue
                }
                Self.expectAgreement(
                    "\(entry.name) seed \(seed)",
                    field: field,
                    image: image,
                    alpha: alpha,
                    seed: seed
                )
            }
        }
        for collar in try Self.requireCollars() {
            for body in collar.bodies {
                Self.expectAgreement(body.name, field: body.field, image: body.image, alpha: body.alpha, seed: 29)
            }
        }
    }

    private static func expectAgreement(
        _ name: String,
        field: MercuryField,
        image: CGImage,
        alpha: [UInt8],
        seed: UInt64
    ) {
        let bounds = field.canvasBounds
        let scale = Double(Self.scale)
        var checked = 0
        let generator = MercuryNoise(seed: seed &+ 99)
        for sample in 0..<4000 {
            let horizontal =
                Double(bounds.minX)
                + generator.uniform(stream: 1, counter: UInt64(sample) &* 2) * Double(bounds.width)
            let vertical =
                Double(bounds.minY)
                + generator.uniform(stream: 1, counter: UInt64(sample) &* 2 &+ 1) * Double(bounds.height)
            let column = Int(((horizontal - Double(bounds.minX)) * scale).rounded(.down))
            let row = Int(((Double(bounds.maxY) - vertical) * scale).rounded(.down))
            guard column >= 0, column < image.width, row >= 0, row < image.height else { continue }
            let center = SIMD2(
                Double(bounds.minX) + (Double(column) + 0.5) / scale,
                Double(bounds.maxY) - (Double(row) + 0.5) / scale
            )
            guard (field.sample(at: SIMD2(horizontal, vertical)) == nil) == (field.sample(at: center) == nil) else {
                continue
            }

            let point = CGPoint(x: horizontal, y: vertical)
            let value = Double(field.value(at: point))
            let gradient = field.gradient(at: point)
            let magnitude = (gradient.dx * gradient.dx + gradient.dy * gradient.dy).squareRoot()
            // Skip the one analytic pixel of edge: inside it the two answers are
            // allowed to differ, and outside it they may not.
            guard value == -.greatestFiniteMagnitude || (magnitude > 0 && abs(value) > Double(magnitude) / scale)
            else { continue }

            let opaque = alpha[row * image.width + column] > 127
            #expect(opaque == (value >= 0), "\(name) at \(point)")
            checked += 1
        }
        #expect(checked > 500, "\(name) sampled too few points to mean anything")
    }

    /// No island body reaches either end of its canvas. Its track ends 84 pt from the centre
    /// and a round end rounds off past that by its own half-thickness, so the canvas runs on
    /// to 98 pt. Every rung of the ladder leans fully either way with its sway asked past its
    /// wall, so it rides the end of its track, and is dragged by the panel at the clamp's
    /// acceleration along and across the spine, reversing several times a second; the voiced
    /// rungs also take adversarial meters, because the buffer is whatever the room hands it.
    ///
    /// At every frame no extent, grown by its coverage ramp, reaches the centre of a pixel in
    /// either outermost column: `theSparseRasterIsTheDenseRaster` holds every pixel the raster
    /// can draw to those boxes. The frame that reaches farthest is then rasterized, and both
    /// columns are clear. It reaches past the envelope's own 90 pt, where the canvas used to end.
    @Test func noIslandBodyReachesTheEndsOfItsCanvas() throws {
        let pixel = 1 / Double(Self.scale)
        let canvas = Self.island.canvasRect.size
        let outermost = Double(canvas.width) / 2 - pixel / 2
        let clamp = MercuryBodyShape.maxFrameAcceleration
        let adversarial: [[Float]] = [
            [Float](repeating: 1, count: 11),
            [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
        ]
        var farthest: (reach: Double, field: MercuryField?) = (0, nil)
        for seed in [UInt64(3), 29] {
            for entry in Self.poses() where entry.pose.length > 0 {
                for samples in [entry.samples] + (entry.pose.driveScale > 0 ? adversarial : []) {
                    for lean in [-1.0, 1.0] {
                        for dragged in [false, true] {
                            var drive = MercurySimulation.Drive(pose: entry.pose, samples: samples, reduceMotion: false)
                            let simulation = MercurySimulation(seed: seed, gains: Self.gains)
                            simulation.reset(to: drive)
                            drive.lean = lean
                            drive.pose.lateralOffset = CGFloat(lean * MercuryMetrics.maxSway)
                            for frame in 0..<120 {
                                if dragged {
                                    drive.forcing = MercuryBodyShape.Forcing(
                                        tangentialAcceleration: (frame / 15) % 2 == 0 ? clamp : -clamp,
                                        normalAcceleration: (frame / 21) % 2 == 0 ? clamp : -clamp
                                    )
                                }
                                simulation.advance(steps: 2, drive: drive)
                                let field = MercuryField(
                                    geometry: simulation.geometry,
                                    spine: Self.island.spine,
                                    canvas: canvas
                                )
                                let reach =
                                    field.extents.map {
                                        Swift.max(-$0.lower.x, $0.upper.x) + $0.rampReach * pixel
                                    }.max() ?? 0
                                #expect(reach < outermost, "\(entry.name) seed \(seed) lean \(lean) frame \(frame)")
                                if reach > farthest.reach { farthest = (reach, field) }
                            }
                        }
                    }
                }
            }
        }
        #expect(farthest.reach > 90)
        let field = try #require(farthest.field)
        let image = try #require(
            MercuryRasterizer().image(
                field: field,
                environment: Self.environment,
                response: Self.response,
                appearance: .standard,
                scale: Self.scale
            )
        )
        let alpha = try #require(Self.alphaChannel(of: image))
        for row in 0..<image.height {
            #expect(alpha[row * image.width] == 0 && alpha[row * image.width + image.width - 1] == 0, "row \(row)")
        }
    }

    /// The island's canvas grew from the envelope's 180 pt to 196 pt about the same centre,
    /// and nothing else about the island moved. Every rung of the ladder, settled on its pose
    /// as calibration meters it and as the harness pins it, draws on the wider canvas exactly
    /// the bytes it drew on the envelope, in the same columns 8 pt in, with both margins
    /// clear. The samples a room is metered with are the same samples in the same order, so
    /// every island response is the one it was.
    @Test func theWiderIslandCanvasOnlyAddsTransparentMargins() throws {
        let wideRasterizer = MercuryRasterizer()
        let narrowRasterizer = MercuryRasterizer()
        let narrowSpine = MercurySpine(straightLength: 180)
        let narrowCanvas = CGSize(width: 180, height: 34)
        let margin = Int(8 * Self.scale)
        for seed in [UInt64(3), 29, MercuryMetrics.defaultSeed] {
            for entry in Self.poses() where entry.pose.length > 0 {
                for steps in [180, 600] {
                    let drive = MercurySimulation.Drive(pose: entry.pose, samples: entry.samples, reduceMotion: false)
                    let simulation = MercurySimulation(seed: seed, gains: Self.gains)
                    simulation.reset(to: drive)
                    simulation.advance(steps: steps, drive: drive)
                    let wide = MercuryField(
                        geometry: simulation.geometry,
                        spine: Self.island.spine,
                        canvas: Self.island.canvasRect.size
                    )
                    let narrow = MercuryField(geometry: simulation.geometry, spine: narrowSpine, canvas: narrowCanvas)
                    func render(_ field: MercuryField, _ rasterizer: MercuryRasterizer) throws -> (
                        CGImage, [SIMD4<UInt8>]
                    ) {
                        let image = try #require(
                            rasterizer.image(
                                field: field,
                                environment: Self.environment,
                                response: Self.response,
                                appearance: .standard,
                                scale: Self.scale
                            )
                        )
                        return (image, try #require(Self.pixels(of: image)))
                    }
                    let (wideImage, widePixels) = try render(wide, wideRasterizer)
                    let (narrowImage, narrowPixels) = try render(narrow, narrowRasterizer)
                    #expect(wideImage.width == narrowImage.width + 2 * margin)
                    var moved = 0
                    var marginDrawn = 0
                    for row in 0..<wideImage.height {
                        for column in 0..<wideImage.width {
                            let pixel = widePixels[row * wideImage.width + column]
                            let inner = column - margin
                            if inner >= 0, inner < narrowImage.width {
                                if pixel != narrowPixels[row * narrowImage.width + inner] { moved += 1 }
                            } else if pixel != .zero {
                                marginDrawn += 1
                            }
                        }
                    }
                    let label = "\(entry.name) seed \(seed) after \(steps) substeps"
                    #expect(moved == 0, "\(label): \(moved) pixels moved")
                    #expect(marginDrawn == 0, "\(label): \(marginDrawn) margin pixels drawn")
                    #expect(
                        wideRasterizer.sampleSceneRadiance(
                            field: wide, environment: Self.environment, scale: Self.scale)
                            == narrowRasterizer.sampleSceneRadiance(
                                field: narrow,
                                environment: Self.environment,
                                scale: Self.scale
                            ),
                        "\(label) metered different samples"
                    )
                }
            }
        }
    }

    /// A single connected component with a positive radius everywhere, so a detached
    /// speck is unrepresentable rather than merely disallowed. On a collar the inner half
    /// lies under the housing, so the visible band is followed halfway out from the
    /// housing's edge to the outer edge instead of along the centre line.
    @Test func theBodyIsOneConnectedComponent() throws {
        var bodies: [(name: String, field: MercuryField)] = []
        for entry in Self.poses() where entry.pose.length > 0 {
            bodies.append((entry.name, Self.field(pose: entry.pose, samples: entry.samples, seed: 41)))
        }
        for collar in try Self.requireCollars() {
            bodies += collar.bodies.map { ($0.name, $0.field) }
        }
        for body in bodies {
            let field = body.field
            let spine = field.spine
            let straight = Self.outline(of: spine) == nil
            for step in 0...200 {
                let arcLength = field.spanStart + field.length * Double(step) / 200
                let station = field.stationSample(at: arcLength)
                #expect(station.radius > 0, "\(body.name) pinched at s = \(arcLength)")
                let offset = straight ? station.center : (station.center + station.radius) / 2
                let point = spine.point(at: arcLength) + offset * spine.frame(at: arcLength).normal
                #expect(
                    field.value(at: CGPoint(x: point.x, y: point.y)) > 0,
                    "\(body.name) broke at s = \(arcLength)"
                )
            }
        }
    }

    /// AppKit points are top-down while `MercuryField` is centre-local and y-up. Hold the
    /// conversion and drag slop to the same oracle over an asymmetric speaking body.
    @Test func hitRegionConvertsPanelCoordinatesBackIntoTheField() {
        let entry = Self.poses().first { $0.name == "speaking" }!
        let field = Self.field(
            pose: entry.pose,
            samples: entry.samples,
            seed: 53
        )
        let region = MercuryHitRegion()
        region.update(field, layout: .island)
        let island = Self.island.canvasRect
        let slop = MercuryMetrics.dragSlop

        for horizontal in stride(from: -96.0, through: 96.0, by: 8) {
            for vertical in stride(from: -16.0, through: 16.0, by: 4) {
                let local = CGPoint(x: horizontal, y: vertical)
                let panel = CGPoint(
                    x: island.midX + horizontal,
                    y: island.midY - vertical
                )
                #expect(
                    region.contains(panel, slop: slop)
                        == (field.value(at: local) >= -slop)
                )
            }
        }
    }

    /// The pixels, the drag predicate and the cursor region read `value(at:)`,
    /// `gradient(at:)` or `sample(at:)`. All three must be one evaluation, and where the
    /// spine has no chart none of them may find a body.
    @Test func sampleIsTheSameEvaluationAsValueAndGradient() throws {
        for collar in try Self.requireCollars() {
            for body in collar.bodies {
                let field = body.field
                let bounds = field.canvasBounds
                var charted = 0
                var uncharted = 0
                var disagreements: [CGPoint] = []
                for horizontal in stride(from: Double(bounds.minX) + 0.13, to: Double(bounds.maxX), by: 0.75) {
                    for vertical in stride(from: Double(bounds.minY) + 0.07, to: Double(bounds.maxY), by: 0.75) {
                        let point = CGPoint(x: horizontal, y: vertical)
                        let value = Double(field.value(at: point))
                        let vector = field.gradient(at: point)
                        let gradient = SIMD2(Double(vector.dx), Double(vector.dy))
                        guard let sample = field.sample(at: SIMD2(horizontal, vertical)) else {
                            if value != -.greatestFiniteMagnitude || gradient != .zero { disagreements.append(point) }
                            uncharted += 1
                            continue
                        }
                        if sample.value != value || sample.gradient != gradient { disagreements.append(point) }
                        charted += 1
                    }
                }
                #expect(disagreements.isEmpty, "\(body.name) disagrees at \(disagreements.prefix(5))")
                #expect(charted > 10_000, "\(body.name)")
                #expect(uncharted > 1_000, "\(body.name): the housing should leave a region with no chart")
            }
        }
    }

    /// The analytic gradient is the derivative of the drawn field, on every primitive a
    /// collar has (runs, walls, convex corners, concave fillets) and around both caps.
    ///
    /// Along the body the analytic rate interpolates the stations' finite-difference slopes,
    /// so the normal stays continuous, while the value interpolates the stations themselves.
    /// The two part by exactly that smoothing of the untapered stations, scaled by the taper
    /// at the point: `T·(|r₀_a − Δr₀| + |c₀_a − Δc₀|)/(L·metric)`, with `Δ` the chord of the
    /// enclosing station interval. The taper is read at the point itself, so its own slope
    /// enters exactly, and everything else, the metric included, must agree with central
    /// differences to rounding. Across the corners, where the taper turns from the chin to
    /// the film, nothing beyond that smoothing is left, so no facet is either. A cap is one
    /// exact round and has no smoothing.
    @Test func theGradientIsTheDerivativeOfTheDrawnField() throws {
        let step = 1e-5
        let stations = Double(MercuryMetrics.columns)
        for collar in try Self.requireCollars() {
            let spine = collar.layout.spine
            var counts: [String: Int] = [:]
            var worstCornerExcess = -Double.infinity
            for body in collar.bodies where body.halfHeight == 11.5 {
                let field = body.field
                let length = field.length
                let top = body.geometry.top.map(Double.init)
                let bottom = body.geometry.bottom.map(Double.init)
                let radii = zip(top, bottom).map { ($0 - $1) / 2 }
                let centres = zip(top, bottom).map { ($0 + $1) / 2 }
                // How far the interpolated finite-difference slope of an untapered quantity
                // strays from its interval's chord, per unit of the material coordinate.
                func stray(_ quantity: [Double], interval: Int, fraction: Double) -> Double {
                    func slope(_ station: Int) -> Double {
                        let low = Swift.max(station - 1, 0)
                        let high = Swift.min(station + 1, quantity.count - 1)
                        return (quantity[high] - quantity[low]) / Double(high - low)
                    }
                    let interpolated = slope(interval) + (slope(interval + 1) - slope(interval)) * fraction
                    return abs(interpolated - (quantity[interval + 1] - quantity[interval])) * stations
                }
                func derivative(at point: SIMD2<Double>) -> SIMD2<Double>? {
                    guard
                        let right = field.sample(at: point + SIMD2(step, 0)),
                        let left = field.sample(at: point - SIMD2(step, 0)),
                        let up = field.sample(at: point + SIMD2(0, step)),
                        let down = field.sample(at: point - SIMD2(0, step))
                    else { return nil }
                    return SIMD2(right.value - left.value, up.value - down.value) / (2 * step)
                }

                for interval in 0..<MercuryMetrics.columns {
                    for fraction in [0.25, 0.5, 0.75] {
                        let arcLength = field.spanStart + length * (Double(interval) + fraction) / stations
                        let station = field.stationSample(at: arcLength)
                        let frame = spine.frame(at: arcLength)
                        let untapered =
                            stray(radii, interval: interval, fraction: fraction)
                            + stray(centres, interval: interval, fraction: fraction)
                        for spread in [-0.6, -0.2, 0.2, 0.6, 1.15] {
                            let offset = station.center + spread * station.radius
                            let point = spine.point(at: arcLength) + offset * frame.normal
                            // Only points whose own foot is this station, which also leaves out
                            // the hidden half under the housing.
                            guard
                                let chart = spine.chart(at: point),
                                abs(chart.arcLength - arcLength) < 1e-7,
                                abs(chart.normalOffset - offset) < 1e-7,
                                let numeric = derivative(at: point),
                                let analytic = field.sample(at: point)?.gradient
                            else { continue }
                            let smoothing = spine.taper(at: arcLength) * untapered / (length * chart.metric)
                            let error = analytic - numeric
                            let size = (error * error).sum().squareRoot()
                            #expect(size <= smoothing + 1e-6, "\(body.name) at s = \(arcLength), n = \(offset)")
                            let primitive =
                                frame.curvature > 0
                                ? "corner" : frame.curvature < 0 ? "fillet" : frame.tangent.y != 0 ? "wall" : "run"
                            if primitive == "corner" {
                                worstCornerExcess = Swift.max(worstCornerExcess, size - smoothing)
                            }
                            counts[primitive, default: 0] += 1
                        }
                    }
                }

                for (end, direction) in [(field.spanStart, -1.0), (field.spanStart + length, 1.0)] {
                    let station = field.stationSample(at: end)
                    let frame = spine.frame(at: end)
                    let center = spine.point(at: end) + station.center * frame.normal
                    for degrees in stride(from: -75.0, through: 75.0, by: 15) {
                        let angle = degrees * .pi / 180
                        let outward = cos(angle) * direction * frame.tangent + sin(angle) * frame.normal
                        for reach in [0.3, 0.7, 1.0, 1.2] {
                            let point = center + reach * station.radius * outward
                            guard
                                let chart = spine.chart(at: point),
                                (chart.arcLength - end) * direction > 1e-4,
                                let numeric = derivative(at: point),
                                let analytic = field.sample(at: point)?.gradient
                            else { continue }
                            let error = analytic - numeric
                            #expect((error * error).sum().squareRoot() <= 1e-6, "\(body.name) cap at \(point)")
                            counts["cap", default: 0] += 1
                        }
                    }
                }
            }
            for primitive in ["run", "wall", "corner", "fillet", "cap"] {
                #expect(counts[primitive, default: 0] > 20, "\(collar.name) checked too few \(primitive) points")
            }
            #expect(worstCornerExcess <= 1e-6, "\(collar.name): a corner strays \(worstCornerExcess) past smoothing")
        }
    }

    /// The surface normal does not kink where the spine hands over from one primitive to the
    /// next. Every bend eases its curvature in from 0, so the metric `1 + κn`, and with it the
    /// gradient, is continuous across each join, convex and concave. Wherever the body's edges
    /// slope along the spine, points 1e-6 pt apart on either side of a join's normal have
    /// gradients within 1e-4; circular bends jumped there by up to 0.04.
    @Test func theGradientIsContinuousAcrossEveryJoin() throws {
        for collar in try Self.requireCollars() {
            let spine = collar.layout.spine
            let regions = spine.regions
            let filletStart = regions.ear
            let wallStart = filletStart + regions.fillet
            let cornerStart = wallStart + regions.wall
            let bottomStart = cornerStart + regions.corner
            let joins = [filletStart, wallStart, cornerStart, bottomStart].flatMap { [$0, spine.length - $0] }
            var checked: Set<Double> = []
            var worst = 0.0
            for body in collar.bodies {
                let field = body.field
                for join in joins {
                    let station = field.stationSample(at: join)
                    let outer = station.center + station.radius
                    // Only where the edges slope along the spine does the metric reach the normal.
                    guard abs(station.radiusSlope) + abs(station.centerSlope) > 0.1, outer > 0 else { continue }
                    let frame = spine.frame(at: join)
                    let base = spine.point(at: join)
                    for k in 1..<16 {
                        let point = base + outer * Double(k) / 16 * frame.normal
                        guard
                            let before = field.sample(at: point - 5e-7 * frame.tangent),
                            let after = field.sample(at: point + 5e-7 * frame.tangent),
                            before.value > 0, after.value > 0
                        else { continue }
                        let jump = after.gradient - before.gradient
                        worst = Swift.max(worst, (jump * jump).sum().squareRoot())
                        checked.insert(join)
                    }
                }
            }
            #expect(worst < 1e-4, "\(collar.name): the gradient jumps by \(worst) across a join")
            #expect(checked.count == joins.count, "\(collar.name) checked \(checked.count) of \(joins.count) joins")
        }
    }

    /// The sparse raster is the dense one, byte for byte: skipping the pixels no extent
    /// reaches never drops a pixel the body covers.
    ///
    /// Random bodies on the island and both collars, of any length up to the whole spine, any
    /// half-height, swayed either way and driven by random levels, are drawn by the rasterizer.
    /// Then every pixel of the canvas is drawn again here, one at a time: charted, sampled
    /// through `field.sample(at:)`, and shaded by the rasterizer's own per-pixel steps. Every
    /// byte must agree. Every pixel the scan covers must also lie inside some extent grown by
    /// its ramp, the guarantee the mask is built on. On a collar that includes the sliver
    /// between a corner's circular rim and the squarer spine, which charts below the spine.
    @Test func theSparseRasterIsTheDenseRaster() throws {
        let rasterizer = MercuryRasterizer()
        let lookup = MercuryDisplayLookup(response: Self.response)
        let pixelSize = 1 / Double(Self.scale)
        let epsilon = MercuryMetrics.crownFilterFraction * pixelSize
        let noise = MercuryNoise(seed: 0x5350_4152_5345_0000)
        var layouts = [("island", Self.island)]
        for collar in try Self.requireCollars() {
            layouts.append((collar.name, collar.layout))
        }
        var counter: UInt64 = 0
        func uniform() -> Double {
            counter += 1
            return noise.uniform(stream: 4, counter: counter)
        }
        for (name, layout) in layouts {
            let straight = layout.kind == .island
            var sliver = 0
            for body in 0..<10 {
                let length =
                    straight
                    ? 20 + (Double(MercuryMetrics.maxLength) - 20) * uniform()
                    : layout.spine.length * (0.08 + 0.92 * uniform())
                let pose = MercuryPose(
                    length: CGFloat(length),
                    halfHeight: CGFloat(4 + 13 * uniform()),
                    lateralOffset: CGFloat((straight ? 6 : 14) * (2 * uniform() - 1)),
                    driveScale: 1,
                    gesture: nil
                )
                let levels = (0..<11).map { _ in Float(uniform()) }
                let seed = UInt64(uniform() * 1e12)
                let field = MercuryField(
                    geometry: Self.geometry(pose: pose, samples: levels, seed: seed, layout: layout),
                    spine: layout.spine,
                    canvas: layout.canvasRect.size
                )
                let image = try #require(
                    rasterizer.image(
                        field: field,
                        environment: Self.environment,
                        response: Self.response,
                        appearance: .standard,
                        scale: Self.scale
                    )
                )
                let drawn = try #require(Self.pixels(of: image))
                let bounds = field.canvasBounds
                var covered = 0
                var mismatched = 0
                var unbounded = 0
                for row in 0..<image.height {
                    let vertical = Double(bounds.maxY) - (Double(row) + 0.5) * pixelSize
                    for column in 0..<image.width {
                        let point = SIMD2(Double(bounds.minX) + (Double(column) + 0.5) * pixelSize, vertical)
                        var expected = SIMD4<UInt8>(repeating: 0)
                        if let chart = field.spine.chart(at: point), let sample = field.sample(at: point),
                            sample.radius > 0
                        {
                            let coverage = MercuryRasterizer.coverage(of: sample, chart: chart, pixelSize: pixelSize)
                            if coverage > 0 {
                                covered += 1
                                if chart.bordersHousing, chart.normalOffset < 0 { sliver += 1 }
                                let scene = MercuryRasterizer.sceneRadiance(
                                    of: sample,
                                    at: point,
                                    epsilon: epsilon,
                                    environment: Self.environment
                                )
                                let display = lookup.map(scene)
                                expected = SIMD4(
                                    MercuryOptics.encodedByte(display.x, coverage: coverage),
                                    MercuryOptics.encodedByte(display.y, coverage: coverage),
                                    MercuryOptics.encodedByte(display.z, coverage: coverage),
                                    MercuryRasterizer.alphaByte(coverage)
                                )
                                let bounded = field.extents.contains { extent in
                                    let reach = SIMD2<Double>(repeating: extent.rampReach * pixelSize)
                                    return all(point .>= extent.lower - reach) && all(point .<= extent.upper + reach)
                                }
                                if !bounded { unbounded += 1 }
                            }
                        }
                        if drawn[row * image.width + column] != expected { mismatched += 1 }
                    }
                }
                let label = "\(name) body \(body), L \(Int(length)), \(pose.halfHeight) high"
                #expect(mismatched == 0, "\(label): \(mismatched) pixels differ from the dense scan")
                #expect(unbounded == 0, "\(label): \(unbounded) covered pixels lie outside every extent")
                #expect(covered > 300, "\(label) covered too little to mean anything")
            }
            if !straight {
                #expect(sliver > 0, "\(name): no covered pixel lay in a corner's sliver")
            }
        }
    }

    /// The housing's own rim is antialiased. A pixel that the bottom edge crosses keeps only its
    /// share below the edge, so a vertical scanline down through the chin reads 0 under the
    /// housing, then rises monotonically to the body's own alpha within 1 pt of the edge.
    ///
    /// The fixture housings are whole points tall, which puts their bottom edge on a pixel
    /// boundary at 2x. These are 0.05 to 0.45 pt taller, so the edge crosses a pixel row. In the
    /// first four it passes above that row's centre, which then lies outside the housing and is
    /// partly covered; in the rest the row's centre lies under the housing and stays clear.
    @Test func theHousingRimIsAntialiased() throws {
        let rasterizer = MercuryRasterizer()
        let pixel = 1 / Double(Self.scale)
        for (index, extra) in [0.05, 0.1, 0.15, 0.2, 0.3, 0.45].enumerated() {
            let layout = try #require(
                RecordingOverlayLayout.collar(housingSize: CGSize(width: 185, height: 32 + extra), bandHeight: 33)
            )
            let outline = try #require(Self.outline(of: layout.spine))
            let pose = MercuryPose(
                length: CGFloat(0.55 * layout.spine.length),
                halfHeight: 11.5,
                lateralOffset: 0,
                driveScale: 1,
                gesture: nil
            )
            let field = MercuryField(
                geometry: Self.geometry(pose: pose, samples: Self.speaking, seed: 29, layout: layout),
                spine: layout.spine,
                canvas: layout.canvasRect.size
            )
            let image = try #require(
                rasterizer.image(
                    field: field,
                    environment: Self.environment,
                    response: Self.response,
                    appearance: .standard,
                    scale: Self.scale
                )
            )
            let alpha = try #require(Self.alphaChannel(of: image))
            let top = Double(field.canvasBounds.maxY)
            let minX = Double(field.canvasBounds.minX)
            // From 2 pt under the housing down to 1 pt below its bottom edge.
            let firstRow = Int(((top - outline.bottom - 2) / pixel).rounded(.down))
            let lastRow = Int(((top - outline.bottom + 1) / pixel).rounded(.down))
            let rows = Array(firstRow...lastRow)
            // Across the bottom run, clear of both corners.
            let clearance = outline.cornerRadius + 4
            let chin = stride(from: outline.minX + clearance, to: outline.maxX - clearance, by: 6.5)
            var scanlines = 0
            var partial = 0
            for x in chin {
                let column = Int(((x - minX) / pixel).rounded(.down))
                let scanline = rows.map { alpha[$0 * image.width + column] }
                let underHousing = rows.map { top - (Double($0) + 0.5) * pixel > outline.bottom }
                let label = "\(32 + extra) pt housing at x = \(x)"
                #expect(zip(scanline, underHousing).allSatisfy { !$1 || $0 == 0 }, "\(label): drawn under the housing")
                #expect(zip(scanline, scanline.dropFirst()).allSatisfy { $0 <= $1 }, "\(label): \(scanline)")
                #expect(scanline.last == 255, "\(label): the chin is not reached within 1 pt: \(scanline)")
                if scanline.contains(where: { $0 > 0 && $0 < 255 }) { partial += 1 }
                scanlines += 1
            }
            #expect(scanlines > 15)
            #expect(partial == (index < 4 ? scanlines : 0), "\(32 + extra) pt housing: \(partial) of \(scanlines)")
        }
    }

    /// The inner half of the collar lies under the camera housing or above the screen's top
    /// edge. No pixel there may be drawn, and the image is the canvas itself.
    @Test func nothingIsDrawnWhereTheSpineHasNoChart() throws {
        let scale = Double(Self.scale)
        for collar in try Self.requireCollars() {
            let canvas = collar.layout.canvasRect.size
            for body in collar.bodies {
                let bounds = body.field.canvasBounds
                #expect(body.image.width == Int((Double(canvas.width) * scale).rounded()))
                #expect(body.image.height == Int((Double(canvas.height) * scale).rounded()))
                var drawn = 0
                var uncharted = 0
                for row in 0..<body.image.height {
                    for column in 0..<body.image.width where body.alpha[row * body.image.width + column] > 0 {
                        let center = SIMD2(
                            Double(bounds.minX) + (Double(column) + 0.5) / scale,
                            Double(bounds.maxY) - (Double(row) + 0.5) / scale
                        )
                        if body.field.spine.chart(at: center) == nil { uncharted += 1 }
                        drawn += 1
                    }
                }
                #expect(uncharted == 0, "\(body.name) drew \(uncharted) pixels with no chart")
                #expect(drawn > 1_000, "\(body.name)")
            }
        }
    }

    /// Menus, menu titles and status items own the band beside the notch, and past the frame's
    /// sides the collar lays only a film there. A pixel drawn in the band farther from the
    /// housing than the ceiling charts onto a fillet or an ear, within the band film and a pixel
    /// of the spine.
    @Test func pastTheFramesSidesTheBandHoldsOnlyFilm() throws {
        let pixel = 1 / Double(Self.scale)
        for collar in try Self.requireCollars() {
            let spine = collar.layout.spine
            let outline = try #require(Self.outline(of: spine))
            let reach = (outline.maxX - outline.minX) / 2 + spine.maxHalfHeight + pixel
            let earAndFillet = spine.regions.ear + spine.regions.fillet
            var past = 0
            var thick = 0
            for body in collar.bodies {
                let bounds = body.field.canvasBounds
                let bandBottom = Double(bounds.maxY) - Double(collar.layout.bandHeight)
                for row in 0..<body.image.height {
                    let vertical = Double(bounds.maxY) - (Double(row) + 0.5) * pixel
                    guard vertical >= bandBottom else { continue }
                    for column in 0..<body.image.width where body.alpha[row * body.image.width + column] > 0 {
                        let horizontal = Double(bounds.minX) + (Double(column) + 0.5) * pixel
                        guard abs(horizontal) > reach, let chart = spine.chart(at: SIMD2(horizontal, vertical)) else {
                            continue
                        }
                        past += 1
                        let local = Swift.min(chart.arcLength, spine.length - chart.arcLength)
                        if local >= earAndFillet || chart.normalOffset > outline.bandFilm + pixel { thick += 1 }
                    }
                }
            }
            #expect(thick == 0, "\(collar.name): \(thick) pixels past the frame's sides were more than film")
            #expect(past > 100, "\(collar.name): the band past the frame's sides was barely reached")
        }
    }

    /// The live frame's sides stay nearer their walls than the screen's top edge. A wall's offsets
    /// chart onto it only up to the bisector of the wall and the edge, `h/(1 − |N_y|)` for a foot
    /// `h` below the edge, so a side that reached it would be cut off there, and the containment
    /// gauge holds every station beside a wall short of it. The ladder's listening and speaking
    /// frames on both fixture housings keep there under the syllable, a meter pinned at full
    /// scale, one that alternates and a quiet room, at a deliberately strong drive, at every
    /// fifth of 600 substeps, measured every quarter point of arc rather than only at stations.
    @Test func theLiveFrameStaysNearerItsWallsThanTheBezel() throws {
        let meters: [[Float]] = [
            Self.speaking, [Float](repeating: 1, count: 11), [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
            MercurySpeechMeter.quietRoom,
        ]
        for display in [OverlayDisplay.fixtureNotch, .fixtureWideNotch] {
            let layout = RecordingOverlayLayout.forDisplay(display)
            let spine = layout.spine
            let outline = try #require(Self.outline(of: spine))
            let wallStart = spine.regions.ear + spine.regions.fillet
            let cornerEnd = wallStart + spine.regions.wall + spine.regions.corner
            var closest = Double.infinity
            var measured = 0
            for levels in meters {
                let model = RecordingOverlayModel()
                model.update(.recording)
                model.updateCaptureLive(true)
                for level in levels { model.record(level) }
                model.update(layout: layout)
                let drive = MercurySimulation.Drive.target(for: model, reduceMotion: false)
                let simulation = MercurySimulation(seed: 29, gains: Self.gains)
                simulation.reset(to: drive)
                for step in 1...600 {
                    simulation.advance(steps: 1, drive: drive)
                    guard step % 5 == 0 else { continue }
                    let field = MercuryField(
                        geometry: simulation.geometry, spine: spine, canvas: layout.canvasRect.size)
                    var s = Swift.max(field.spanStart, 0)
                    let end = Swift.min(field.spanStart + field.length, spine.length)
                    while s <= end {
                        let local = Swift.min(s, spine.length - s)
                        let normal = spine.frame(at: s).normal
                        if local >= wallStart, local < cornerEnd, abs(normal.y) < 1 {
                            let sample = field.stationSample(at: s)
                            let bisector = (outline.top - spine.point(at: s).y) / (1 - abs(normal.y))
                            closest = Swift.min(closest, bisector - (sample.center + sample.radius))
                            measured += 1
                        }
                        s += 0.25
                    }
                }
            }
            #expect(measured > 1_000, "\(display.id): the frame's sides were barely measured")
            #expect(closest > 0, "\(display.id): a side reached \(-closest) pt past its bisector")
        }
    }

    /// The island is today's straight ribbon, bit for bit, at the pixel centres the
    /// rasterizer evaluates. The oracle is the documented law with no spine: `x − lateralOffset`
    /// clamped to the span, `a = (x̂ + L/2)/L` over 96 station intervals, linear radius and
    /// centre, interpolated finite-difference slopes, `φ = r − |y − c|` with gradient
    /// `((r_a ± c_a)/L, ∓1)` inside the span and an exact round beyond it.
    @Test func theIslandIsTodaysStraightRibbon() {
        let scale = Double(Self.scale)
        let size = Self.island.canvasRect.size
        let columns = Int((Double(size.width) * scale).rounded())
        let rows = Int((Double(size.height) * scale).rounded())
        for seed in [UInt64(3), 0x5155_4943_4B53_4C56] {
            for entry in Self.poses() where entry.pose.length > 0 {
                let drive = MercurySimulation.Drive(pose: entry.pose, samples: entry.samples, reduceMotion: false)
                let simulation = MercurySimulation(seed: seed, gains: Self.gains)
                simulation.reset(to: drive)
                simulation.advance(steps: 600, drive: drive)
                let geometry = simulation.geometry
                let field = MercuryField(geometry: geometry, spine: Self.island.spine, canvas: size)
                let generator = MercuryNoise(seed: seed &+ 7)
                var disagreements: [SIMD2<Double>] = []
                for sample in 0..<2000 {
                    let column = Int(generator.uniform(stream: 2, counter: UInt64(sample) &* 2) * Double(columns))
                    let row = Int(generator.uniform(stream: 2, counter: UInt64(sample) &* 2 &+ 1) * Double(rows))
                    let point = SIMD2(
                        -Double(size.width) / 2 + (Double(column) + 0.5) / scale,
                        Double(size.height) / 2 - (Double(row) + 0.5) / scale
                    )
                    let expected = Self.straightRibbon(geometry, at: point)
                    let location = CGPoint(x: point.x, y: point.y)
                    let gradient = field.gradient(at: location)
                    if Double(field.value(at: location)) != expected.value
                        || SIMD2(Double(gradient.dx), Double(gradient.dy)) != expected.gradient
                    {
                        disagreements.append(point)
                    }
                }
                #expect(disagreements.isEmpty, "\(entry.name) seed \(seed) at \(disagreements.prefix(5))")
            }
        }
    }

    private static func straightRibbon(
        _ geometry: MercurySimulation.Geometry,
        at point: SIMD2<Double>
    ) -> (value: Double, gradient: SIMD2<Double>) {
        let top = geometry.top.map(Double.init)
        let bottom = geometry.bottom.map(Double.init)
        let stations = top.count - 1
        let length = Double(geometry.length)
        let half = length / 2
        let horizontal = point.x - Double(geometry.lateralOffset)
        let clamped = Swift.min(Swift.max(horizontal, -half), half)
        let material = length > 0 ? (clamped + half) / length : 0
        let position = material * Double(stations)
        let index = Swift.min(Int(position), stations)
        let fraction = position - Double(index)
        let next = Swift.min(index + 1, stations)

        func radius(_ station: Int) -> Double { (top[station] - bottom[station]) / 2 }
        func center(_ station: Int) -> Double { (top[station] + bottom[station]) / 2 }
        func slope(_ quantity: (Int) -> Double, _ station: Int) -> Double {
            let low = Swift.max(station - 1, 0)
            let high = Swift.min(station + 1, stations)
            return (quantity(high) - quantity(low)) / Double(high - low)
        }
        func mix(_ start: Double, _ end: Double) -> Double { start + (end - start) * fraction }

        let localRadius = mix(radius(index), radius(next))
        let localCenter = mix(center(index), center(next))
        let vertical = point.y - localCenter
        guard horizontal >= -half, horizontal <= half else {
            let capOffset = horizontal - clamped
            let distance = (capOffset * capOffset + vertical * vertical).squareRoot()
            return (
                localRadius - distance,
                distance > 1e-9 ? SIMD2(-capOffset / distance, -vertical / distance) : SIMD2(0, -1)
            )
        }
        let radiusSlope = mix(slope(radius, index), slope(radius, next)) * Double(stations)
        let centerSlope = mix(slope(center, index), slope(center, next)) * Double(stations)
        let sign: Double = vertical >= 0 ? 1 : -1
        return (
            localRadius - abs(vertical),
            SIMD2((radiusSlope + sign * centerSlope) / Swift.max(length, 1), -sign)
        )
    }

    private static func alphaChannel(of image: CGImage) -> [UInt8]? {
        pixels(of: image)?.map(\.w)
    }

    /// The image's premultiplied RGBA bytes, one pixel per element, row by row from the top.
    private static func pixels(of image: CGImage) -> [SIMD4<UInt8>]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        var result = [SIMD4<UInt8>](repeating: .zero, count: image.width * image.height)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<image.height {
                for column in 0..<image.width {
                    let offset = row * bytesPerRow + column * 4
                    result[row * image.width + column] = SIMD4(
                        base[offset],
                        base[offset + 1],
                        base[offset + 2],
                        base[offset + 3]
                    )
                }
            }
        }
        return result
    }
}
