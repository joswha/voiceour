import CoreGraphics
import Foundation
import Testing
import VoiceCore

@testable import Voiceour

/// The stock look, held to the renderer `main` shipped before the Island Garage was ported onto it.
///
/// Every digest below was printed by these cases running on `main` at `96fa829`, whose body is the
/// gel laid on its spine, on the island and around the notch collar, lit by the Studio room and
/// metered per layout. Comparing the patched code with itself cannot catch a stock constant that
/// drifted or an expression that was reassociated, because both sides move together; frozen bits
/// from the shipped implementation can. The overlay goldens pin the same property through whole
/// frames, but only at a few poses' pinned substep. These cases also reach emergence, a live meter,
/// every outcome gesture, Reduce Motion turned on mid-swing, containment under adversarial meters,
/// uneven step batching, a lean, arrival kicks, a moving panel, a swallow and a hand-off, on the
/// island and on the collar; the gains the calibration solves; the rooms and metered responses of
/// three seeds on both layouts; and four rastered frames in both contrasts.
@MainActor
struct MercuryStockBaselineTests {
    /// The balance the calibration solves for the gel law, rounded. Where calibration is not the
    /// point, the law runs on these, so a drifted solve fails its own cases and no other.
    private static let gains = MercuryGains(drive: 0.79, snake: 0.025)

    /// One syllable and the onset of the next, oldest first.
    private static let syllable: [Float] = [0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46]
    /// A live microphone in a quiet room: every level at or below the release level.
    private static let quietRoom: [Float] = [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]
    /// A few more syllables and the silence after them, one level per 40 ms meter tick. The
    /// buffer moves under the body as the live meter's does, and the seventh quiet level concedes
    /// silence, so the speaking body settles back onto the listening lip.
    private static let utterance: [Float] = [
        0.46, 0.71, 0.88, 0.52, 0.34, 0.64, 0.41, 0.19, 0.27, 0.15, 0.62, 0.83,
        0.57, 0.38, 0.22, 0.12, 0.04, 0.02, 0.0, 0.01, 0.03, 0.0, 0.02, 0.01,
    ]

    /// Where a stage draws the body: the island, or the collar around the 185×32 pt notch fixture.
    enum Place: String, Sendable, CustomStringConvertible {
        case island, collar

        var description: String { rawValue }

        var layout: RecordingOverlayLayout {
            switch self {
            case .island: .island
            case .collar: .forDisplay(.fixtureNotch)
            }
        }
    }

    /// What the session tells the body, as the model the ribbon reads holds it.
    enum Session: Sendable {
        /// Capture requested, no audio yet: the bead.
        case warming
        /// The quiet room's meter, held still.
        case listening
        /// The syllable's meter, held still.
        case speaking
        /// The syllable's meter, then `utterance` one level per frame.
        case utterance
        /// A live meter reading nothing at all.
        case silent
        /// Adversarial meters: every level at full scale, full scale every other level, and one
        /// full-scale level alone.
        case saturated, alternating, spike
        case processing
        /// The three outcome gestures: copy-only, insert failed and an error.
        case gathered, lurch, collapse
        /// Speaking while the panel fades out, so the ladder asks for nothing.
        case dismissing
    }

    /// One stretch of a session: the drive the ribbon builds from the model, and the substeps
    /// each frame advances, one checkpoint per frame.
    struct Stage: Sendable {
        let session: Session
        let steps: [Int]
        let reduceMotion: Bool
        /// Overrides the case's place: the display a hand-off delivers the body to.
        let place: Place?
        let context: MercuryPoseContext
        let lean: Double
        let forcing: MercuryBodyShape.Forcing
        let arrival: MercuryArrival?

        init(
            _ session: Session,
            _ steps: [Int] = [],
            reduceMotion: Bool = false,
            on place: Place? = nil,
            context: MercuryPoseContext = MercuryPoseContext(),
            lean: Double = 0,
            forcing: MercuryBodyShape.Forcing = .none,
            arrival: MercuryArrival? = nil
        ) {
            self.session = session
            self.steps = steps
            self.reduceMotion = reduceMotion
            self.place = place
            self.context = context
            self.lean = lean
            self.forcing = forcing
            self.arrival = arrival
        }
    }

    /// A body placed on its first stage's drive, at rest or emerging, then advanced through every
    /// stage.
    struct Trajectory: Sendable, CustomTestStringConvertible {
        let name: String
        var place = Place.island
        let seed: UInt64
        var calibrated = false
        var emerging = false
        let stages: [Stage]
        let digest: UInt64

        var testDescription: String { "\(place), seed \(seed): \(name)" }
    }

    /// One FNV-1a 64 digest per case over every checkpoint's length, half-height, lateral offset,
    /// top and bottom bit patterns, the placement included.
    nonisolated static let trajectories: [Trajectory] = [
        Trajectory(
            name: "emerges as the bead, hears the room, speaks and trails off",
            seed: 3,
            emerging: true,
            stages: [
                Stage(.warming, frames(48)),
                Stage(.listening, frames(30)),
                Stage(.speaking, frames(30)),
                Stage(.utterance, ticks(40)),
            ],
            digest: 0x30c6_b534_5ca7_1675
        ),
        Trajectory(
            name: "listens under uneven batching",
            seed: MercuryMetrics.defaultSeed,
            stages: [Stage(.listening, [1, 2, 7, 90, 3, 1, 4, 1, 5, 9, 2, 6])],
            digest: 0xadfc_f7ae_cd42_b5fb
        ),
        Trajectory(
            name: "speaks, gathers for processing against its height wall, then collapses",
            seed: 19,
            stages: [
                Stage(.speaking, frames(30)),
                Stage(.processing, frames(120)),
                Stage(.collapse, frames(60) + frames(30, of: 4)),
            ],
            digest: 0x6f6f_f98d_8c1f_e83f
        ),
        Trajectory(
            name: "processing into the copy-only gather",
            seed: 5,
            stages: [Stage(.processing), Stage(.gathered, frames(120))],
            digest: 0xcaec_ec03_c2ee_53e8
        ),
        Trajectory(
            name: "processing into the lurch",
            seed: 23,
            stages: [Stage(.processing), Stage(.lurch, frames(30) + frames(30, of: 2) + frames(4, of: 30))],
            digest: 0x5591_ee98_6c3b_7786
        ),
        Trajectory(
            name: "the lurch, with Reduce Motion turned on mid-swing",
            seed: 23,
            stages: [
                Stage(.processing),
                Stage(.lurch, frames(12)),
                Stage(.lurch, frames(60) + frames(6, of: 10), reduceMotion: true),
            ],
            digest: 0xbf2a_251d_d102_67eb
        ),
        Trajectory(
            name: "Reduce Motion throughout: silence, speech, processing and the spent collapse",
            seed: 17,
            stages: [
                Stage(.silent, [1, 59], reduceMotion: true),
                Stage(.speaking, frames(30), reduceMotion: true),
                Stage(.processing, frames(60), reduceMotion: true),
                Stage(.collapse, frames(60), reduceMotion: true),
            ],
            digest: 0xb11b_20c1_9265_cf6d
        ),
        Trajectory(
            name: "a saturated meter presses it against its ceiling",
            seed: 1,
            stages: [Stage(.saturated, frames(240))],
            digest: 0x501d_daaf_3b06_6a4a
        ),
        Trajectory(
            name: "an alternating meter, then a lone spike",
            seed: 7,
            stages: [Stage(.alternating, frames(120)), Stage(.spike, frames(120))],
            digest: 0x2989_1dad_ba2a_8506
        ),
        Trajectory(
            name: "leans to its mark, into its wall and back, the last under Reduce Motion",
            seed: 9,
            stages: [
                Stage(.listening),
                Stage(.listening, frames(90) + frames(10, of: 30), lean: 1),
                Stage(.listening, frames(60), lean: 4),
                Stage(.speaking, frames(60), lean: -1),
                Stage(.speaking, frames(60), reduceMotion: true, lean: 1),
            ],
            digest: 0x3ee4_3d39_9b2e_4f3f
        ),
        Trajectory(
            name: "emerges with an arrival kick, handed over again, then a newer one",
            seed: 31,
            emerging: true,
            stages: [
                Stage(.speaking, frames(40), arrival: MercuryArrival(id: 1, swayRate: 60, aspectRate: -1.2)),
                Stage(.speaking, frames(20), arrival: MercuryArrival(id: 1, swayRate: 60, aspectRate: -1.2)),
                Stage(.speaking, frames(30), arrival: MercuryArrival(id: 2, swayRate: -60, aspectRate: 0.8)),
            ],
            digest: 0x5ed0_8bff_ba06_ca28
        ),
        Trajectory(
            name: "carried by a panel that accelerates, jumps at the clamp and stops",
            seed: 13,
            stages: [
                Stage(.listening),
                Stage(.listening, frames(30), forcing: Self.forcing(3_000, -12_500)),
                Stage(.listening, frames(10), forcing: Self.forcing(40_000, -40_000)),
                Stage(.listening, frames(60)),
                Stage(.listening, frames(30), reduceMotion: true, forcing: Self.forcing(-8_000, 2_000)),
            ],
            digest: 0x9862_b741_e2dd_27f4
        ),
        Trajectory(
            name: "swallowed as its panel fades, then grown back where it is",
            seed: 7,
            stages: [Stage(.speaking), Stage(.dismissing, frames(50)), Stage(.speaking, frames(60))],
            digest: 0x0a1e_cc02_70c6_3199
        ),
        Trajectory(
            name: "drains toward the notched display, then emerges as its collar with the arrival kick",
            seed: 37,
            stages: [
                Stage(.speaking),
                Stage(.speaking, frames(48), context: MercuryPoseContext(draining: true), lean: -1),
                Stage(
                    .speaking, frames(60), on: .collar,
                    arrival: MercuryArrival(id: 1, swayRate: -60, aspectRate: -1.2)
                ),
            ],
            digest: 0x71ad_209e_805c_e2dd
        ),
        Trajectory(
            name: "emerges as the bead, hears the room, speaks and trails off",
            place: .collar,
            seed: 3,
            emerging: true,
            stages: [
                Stage(.warming, frames(48)),
                Stage(.listening, frames(30)),
                Stage(.speaking, frames(30)),
                Stage(.utterance, ticks(40)),
            ],
            digest: 0x0bb2_fada_8dba_e099
        ),
        Trajectory(
            name: "spreads along the ears over a full-screen app, gives the walls back to the pointer, then listens",
            place: .collar,
            seed: 11,
            stages: [
                Stage(.speaking, frames(100, of: 3), context: MercuryPoseContext(fullScreen: true)),
                Stage(.speaking, frames(60), context: MercuryPoseContext(pointerInBand: true, fullScreen: true)),
                Stage(.listening, frames(60, of: 2)),
            ],
            digest: 0x9122_39ff_05f4_97c5
        ),
        Trajectory(
            name: "processing into the copy-only gather",
            place: .collar,
            seed: 5,
            stages: [Stage(.processing), Stage(.gathered, frames(90))],
            digest: 0xd229_f0b9_b2f3_7711
        ),
        Trajectory(
            name: "processing into the lurch",
            place: .collar,
            seed: 23,
            stages: [Stage(.processing), Stage(.lurch, frames(60) + frames(15, of: 4))],
            digest: 0xeb54_fbc5_c9ad_998b
        ),
        Trajectory(
            name: "processing into the collapse",
            place: .collar,
            seed: 19,
            stages: [Stage(.processing), Stage(.collapse, frames(60) + frames(15, of: 4))],
            digest: 0x29a4_b25b_8765_5c41
        ),
        Trajectory(
            name: "emerges, with Reduce Motion turned on mid-growth",
            place: .collar,
            seed: 29,
            emerging: true,
            stages: [Stage(.speaking, frames(20)), Stage(.speaking, frames(60), reduceMotion: true)],
            digest: 0x42fc_74ec_a4a9_7557
        ),
        Trajectory(
            name: "a saturated meter presses the spread frame against its walls and ceiling",
            place: .collar,
            seed: 1,
            stages: [Stage(.saturated, frames(240), context: MercuryPoseContext(fullScreen: true))],
            digest: 0xbf3a_5ecc_b8dc_6531
        ),
        Trajectory(
            name: "kicked, carried and leaned as it emerges, then drained",
            place: .collar,
            seed: 41,
            emerging: true,
            stages: [
                Stage(
                    .listening, frames(90), lean: 0.5, forcing: Self.forcing(2_000, -6_000),
                    arrival: MercuryArrival(id: 1, swayRate: -60, aspectRate: -1.2)
                ),
                Stage(.listening, frames(60, of: 2), lean: 0.5),
                Stage(.listening, frames(60), context: MercuryPoseContext(draining: true), lean: -1),
            ],
            digest: 0x2b89_2905_89d2_1045
        ),
        Trajectory(
            name: "speaks on the calibrated gains",
            seed: MercuryMetrics.defaultSeed,
            calibrated: true,
            stages: [Stage(.speaking, [600])],
            digest: 0x1af3_e541_d830_f009
        ),
        Trajectory(
            name: "speaks on the calibrated gains",
            place: .collar,
            seed: MercuryMetrics.defaultSeed,
            calibrated: true,
            stages: [Stage(.speaking, [600])],
            digest: 0x35af_3178_77b7_bd01
        ),
    ]

    @Test(arguments: trajectories)
    func stockDynamicsMatchTheShippedLaw(_ trajectory: Trajectory) throws {
        var hash = FNV()
        try Self.run(
            trajectory.stages,
            on: trajectory.place,
            seed: trajectory.seed,
            calibrated: trajectory.calibrated,
            emerging: trajectory.emerging
        ) { geometry in
            hash.add(geometry)
        }
        #expect(hash.value == trajectory.digest)
    }

    /// The drive and contact-line gains the calibration solves on the stock law, bit for bit:
    /// 0.7861759065776623 and 0.02460479736328125.
    @Test func stockCalibrationSolvesTheShippedGains() {
        let gains = MercuryCalibration.shared.gains
        #expect(gains.drive.bitPattern == 0x3fe9_285a_5ff4_ef4c)
        #expect(gains.snake.bitPattern == 0x3f99_3200_0000_0000)
    }

    /// One seed's Studio room and the responses it is metered to on each layout.
    struct Lighting: Sendable, CustomTestStringConvertible {
        let seed: UInt64
        /// Every level of the room at a fixed lattice, blended levels included.
        let room: UInt64
        /// Every field of the response metered on the island's bodies, and on the collar's.
        let island: UInt64
        let collar: UInt64

        var testDescription: String { "seed \(seed)" }
    }

    nonisolated static let lightings: [Lighting] = [
        Lighting(seed: 2, room: 0xf5fd_be23_27f7_2b48, island: 0x87af_d1cc_1f13_01d3, collar: 0x3659_5282_1a3b_23f2),
        Lighting(seed: 19, room: 0xaa03_4047_7281_09a4, island: 0x9ecd_ed6c_44a3_2905, collar: 0xd02c_921c_607c_a392),
        Lighting(
            seed: MercuryMetrics.defaultSeed,
            room: 0x9c76_41ea_b5b8_a953,
            island: 0xd1f9_f0c5_e112_2d84,
            collar: 0x12c8_505e_dccd_58ac
        ),
    ]

    @Test(arguments: lightings)
    func stockStudioRoomsAndResponsesMatchTheShippedOnes(_ lighting: Lighting) {
        let environment = MercuryEnvironment(world: .roomOfTen, seed: lighting.seed)
        var room = FNV()
        for direction in Self.lattice {
            for roughness in Self.roughnesses {
                room.add(environment.radiance(direction, roughness: roughness))
            }
        }
        #expect(room.value == lighting.room)
        for (place, digest) in [(Place.island, lighting.island), (.collar, lighting.collar)] {
            var metered = FNV()
            metered.add(
                MercuryCalibration.shared.displayResponse(
                    for: environment,
                    bodySeed: lighting.seed,
                    layout: place.layout
                )
            )
            #expect(metered.value == digest, "\(place)")
        }
    }

    /// One frame rastered as the engine rasters it: the body on the calibrated gains, in its
    /// seed's room, through the response metered on its layout.
    struct Raster: Sendable, CustomTestStringConvertible {
        let name: String
        var place = Place.island
        let seed: UInt64
        var increasedContrast = false
        let stages: [Stage]
        let digest: UInt64

        var testDescription: String { "\(place), seed \(seed): \(name)" }
    }

    /// One FNV-1a 64 digest per frame over its size and every byte of its premultiplied RGBA pixels.
    nonisolated static let rasters: [Raster] = [
        Raster(
            name: "speaking with a lean",
            seed: 7,
            stages: [Stage(.speaking), Stage(.speaking, [240], lean: 0.5)],
            digest: 0xbb41_82f0_1ef8_148f
        ),
        Raster(
            name: "the lurch, in increased contrast",
            seed: 23,
            increasedContrast: true,
            stages: [Stage(.processing), Stage(.lurch, [30])],
            digest: 0x4960_895c_1320_b4e1
        ),
        Raster(
            name: "speaking along the ears",
            place: .collar,
            seed: MercuryMetrics.defaultSeed,
            stages: [Stage(.speaking, [360], context: MercuryPoseContext(fullScreen: true))],
            digest: 0xbde2_8a52_5bf4_c943
        ),
        Raster(
            name: "the collapse, in increased contrast",
            place: .collar,
            seed: 11,
            increasedContrast: true,
            stages: [Stage(.processing), Stage(.collapse, [90])],
            digest: 0xc00d_fec8_39a4_078c
        ),
    ]

    @Test(arguments: rasters)
    func stockFramesMatchTheShippedRaster(_ raster: Raster) throws {
        let layout = raster.place.layout
        let simulation = try Self.run(raster.stages, on: raster.place, seed: raster.seed, calibrated: true)
        let environment = MercuryEnvironment(world: .roomOfTen, seed: raster.seed)
        let image = try #require(
            MercuryRasterizer().image(
                field: MercuryField(
                    geometry: simulation.geometry,
                    spine: layout.spine,
                    canvas: layout.canvasRect.size
                ),
                environment: environment,
                response: MercuryCalibration.shared.displayResponse(
                    for: environment,
                    bodySeed: raster.seed,
                    layout: layout
                ),
                appearance: MercuryAppearance(increasedContrast: raster.increasedContrast),
                scale: MercuryMetrics.rasterScale
            )
        )
        var hash = FNV()
        try hash.add(image)
        #expect(hash.value == raster.digest)
    }

    // MARK: Fixtures

    /// `count` frames of `steps` substeps each.
    nonisolated private static func frames(_ count: Int, of steps: Int = 1) -> [Int] {
        Array(repeating: steps, count: count)
    }

    /// `count` frames at the live meter's cadence: a level every 40 ms, 24 substeps per five levels.
    nonisolated private static func ticks(_ count: Int) -> [Int] {
        (0..<count).map { $0 % 5 == 4 ? 4 : 5 }
    }

    nonisolated private static func forcing(_ tangential: Double, _ normal: Double) -> MercuryBodyShape.Forcing {
        MercuryBodyShape.Forcing(tangentialAcceleration: tangential, normalAcceleration: normal)
    }

    /// Roughnesses the room is read at: each prefiltered level, and a blend between each pair.
    private static let roughnesses: [Float] = [0.03, 0.05, 0.09, 0.16, 0.25]

    /// A 512-point Fibonacci lattice over the whole sphere.
    private static let lattice: [SIMD3<Float>] = (0..<512).map { index in
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let height = 1 - 2 * (Double(index) + 0.5) / 512
        let radius = Swift.max(0, 1 - height * height).squareRoot()
        let angle = golden * Double(index)
        return SIMD3(Float(radius * cos(angle)), Float(radius * sin(angle)), Float(height))
    }

    /// A body on `seed`, placed on the first stage's drive, at rest or `emerging`, then advanced
    /// through every stage. `checkpoint` sees its geometry after the placement and after every
    /// frame.
    @discardableResult
    private static func run(
        _ stages: [Stage],
        on place: Place,
        seed: UInt64,
        calibrated: Bool,
        emerging: Bool = false,
        checkpoint: (MercurySimulation.Geometry) -> Void = { _ in }
    ) throws -> MercurySimulation {
        let simulation = MercurySimulation(seed: seed, gains: calibrated ? MercuryCalibration.shared.gains : gains)
        let first = try #require(stages.first)
        let placement = try model(first, on: place)
        simulation.reset(to: drive(first, model: placement), emerging: emerging)
        checkpoint(simulation.geometry)
        for stage in stages {
            let model = try model(stage, on: place)
            for (frame, steps) in stage.steps.enumerated() {
                if case .utterance = stage.session {
                    model.record(utterance[Swift.min(frame, utterance.count - 1)])
                }
                simulation.advance(steps: steps, drive: drive(stage, model: model))
                checkpoint(simulation.geometry)
            }
        }
        return simulation
    }

    /// The drive the ribbon builds from `model`, with the stage's lean, panel forcing and arrival.
    private static func drive(_ stage: Stage, model: RecordingOverlayModel) -> MercurySimulation.Drive {
        var drive = MercurySimulation.Drive.target(for: model, reduceMotion: stage.reduceMotion)
        drive.lean = stage.lean
        drive.forcing = stage.forcing
        drive.arrival = stage.arrival
        return drive
    }

    private static func model(_ stage: Stage, on place: Place) throws -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(layout: (stage.place ?? place).layout)
        model.update(poseContext: stage.context)
        switch stage.session {
        case .warming:
            model.update(.recording)
        case .listening:
            listen(model, to: quietRoom)
        case .speaking, .utterance:
            listen(model, to: syllable)
        case .silent:
            listen(model, to: [Float](repeating: 0, count: 11))
        case .saturated:
            listen(model, to: [Float](repeating: 1, count: 11))
        case .alternating:
            listen(model, to: [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1])
        case .spike:
            listen(model, to: [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])
        case .processing:
            model.update(.transcribing)
        case .gathered:
            try present(.copiedOnly(reason: "target_terminal"), on: model)
        case .lurch:
            try present(.insertFailed(reason: "no focused element"), on: model)
        case .collapse:
            try present(.error(.inferenceFailed), on: model)
        case .dismissing:
            listen(model, to: syllable)
            model.beginDismissal()
        }
        return model
    }

    private static func listen(_ model: RecordingOverlayModel, to levels: [Float]) {
        model.update(.recording)
        model.updateCaptureLive(true)
        for level in levels {
            model.record(level)
        }
    }

    /// The outcome `state` presents, latched as the controller latches it.
    private static func present(_ state: SessionState, on model: RecordingOverlayModel) throws {
        model.update(state)
        model.present(try #require(RecordingOverlayOutcome(state: state)))
    }

    private struct FNV {
        private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

        mutating func add(byte: UInt8) {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }

        mutating func add(word: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                add(byte: UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }

        mutating func add(_ value: Double) {
            add(word: value.bitPattern)
        }

        mutating func add(_ value: Float) {
            add(word: UInt64(value.bitPattern))
        }

        mutating func add(_ geometry: MercurySimulation.Geometry) {
            add(Double(geometry.length))
            add(Double(geometry.halfHeight))
            add(Double(geometry.lateralOffset))
            for value in geometry.top { add(value) }
            for value in geometry.bottom { add(value) }
        }

        mutating func add(_ radiance: SIMD3<Float>) {
            add(radiance.x)
            add(radiance.y)
            add(radiance.z)
        }

        mutating func add(_ response: MercuryDisplayResponse) {
            add(response.exponent)
            add(response.halfSaturation)
            add(response.ceiling)
            add(response.sceneMedian)
            add(response.sceneHighlight)
        }

        /// The size, then each row's pixels without any row padding.
        mutating func add(_ image: CGImage) throws {
            add(word: UInt64(image.width))
            add(word: UInt64(image.height))
            let data = try #require(image.dataProvider?.data as Data?)
            let rowBytes = image.width * image.bitsPerPixel / 8
            data.withUnsafeBytes { pixels in
                for row in 0..<image.height {
                    let start = row * image.bytesPerRow
                    for byte in pixels[start..<start + rowBytes] {
                        add(byte: byte)
                    }
                }
            }
        }
    }
}
