import CoreGraphics
import Foundation
import VoiceCore

/// The raster inputs of `make ui-mercury-bench` (Sources/Voiceour/UIHarness/
/// MercuryChromeBenchmark.swift), regenerated through the copied production sources.
///
/// - `seed` rows: the 64-seed raster corpus. Each benchmark seed gets its own Room of Ten
///   and calibrated response; every row draws the same speaking body (default seed,
///   600 substeps), exactly as `rasterScreen` does.
/// - `motion` rows: the ten seconds at 120 Hz the benchmark's engine-plus-layer CPU loop
///   presents. `MercuryEngine.frame(advancing: 0)` resets the default-seed simulation to
///   the speaking drive, 240 timed single-substep frames follow, then the 1,200 frames of
///   the CPU loop: substeps 241...1,440, one raster each.
/// - `seedic` rows (verification only): the seed corpus with Increase Contrast, which
///   exercises the rasterizer's per-call response re-solve.
/// - `pose` rows (verification only): every pose of the ladder — warming, listening,
///   speaking, processing and the gathered, lurch and collapse outcomes — entered from a
///   speaking body the way a session does, so gesture impulses fire, at several substeps
///   after the transition, on four rooms, in both appearances. They cover the paths the
///   benchmark corpus does not: thin and short bodies, round caps at both ends and the
///   lurch's lateral offset.
@MainActor
struct Corpus {
    enum Kind: UInt32, CaseIterable {
        case seed = 0
        case motion = 1
        case seedIncreasedContrast = 2
        case pose = 3

        var label: String {
            switch self {
            case .seed: "seed"
            case .motion: "motion"
            case .seedIncreasedContrast: "seedic"
            case .pose: "pose"
            }
        }

        init?(label: String) {
            guard let kind = Self.allCases.first(where: { $0.label == label }) else { return nil }
            self = kind
        }
    }

    struct Lighting {
        let seed: UInt64
        let response: MercuryDisplayResponse
    }

    struct Row {
        let id: String
        let kind: Kind
        let index: Int
        let lighting: Int
        let geometry: MercurySimulation.Geometry
        let lateralOffset: CGFloat
        let appearance: MercuryAppearance
        /// What a `pose` row draws, for reports.
        var detail: String = ""
    }

    static let motionWarmupFrames = 240

    let lightings: [Lighting]
    /// The rooms the responses were metered against, one per lighting.
    let environments: [MercuryEnvironment]
    let rows: [Row]
    let calibrationMilliseconds: Double

    static func build(seedCount: Int, motionFrames: Int) -> Corpus {
        let calibrationStarted = DispatchTime.now().uptimeNanoseconds
        let calibration = MercuryCalibration.shared
        let calibrationMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - calibrationStarted) / 1e6
        let drive = Self.drive(speaking: true)

        var lightings: [Lighting] = []
        var environments: [MercuryEnvironment] = []
        func lighting(for seed: UInt64) -> Int {
            if let existing = lightings.firstIndex(where: { $0.seed == seed }) { return existing }
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            lightings.append(
                Lighting(
                    seed: seed,
                    response: calibration.displayResponse(for: room, bodySeed: seed)
                )
            )
            environments.append(room)
            return lightings.count - 1
        }

        // The benchmark's `speaking` field: default seed, reset, 600 substeps.
        let speakingSimulation = MercurySimulation(
            seed: MercuryMetrics.defaultSeed,
            gains: calibration.gains
        )
        speakingSimulation.reset(to: drive)
        speakingSimulation.advance(steps: 600, drive: drive)
        let speaking = speakingSimulation.geometry

        var rows: [Row] = []
        var seedLightings: [Int] = []
        for index in 0..<seedCount {
            let lightingIndex = lighting(for: benchmarkSeed(index))
            seedLightings.append(lightingIndex)
            rows.append(
                Row(
                    id: String(format: "seed-%02d", index),
                    kind: .seed,
                    index: index,
                    lighting: lightingIndex,
                    geometry: speaking,
                    lateralOffset: drive.pose.lateralOffset,
                    appearance: .standard
                )
            )
        }

        if motionFrames > 0 {
            let motionLighting = lighting(for: MercuryMetrics.defaultSeed)
            let simulation = MercurySimulation(seed: MercuryMetrics.defaultSeed, gains: calibration.gains)
            simulation.reset(to: drive)
            for step in 1...(motionWarmupFrames + motionFrames) {
                simulation.advance(steps: 1, drive: drive)
                guard step > motionWarmupFrames else { continue }
                let index = step - motionWarmupFrames - 1
                rows.append(
                    Row(
                        id: String(format: "motion-%04d", index),
                        kind: .motion,
                        index: index,
                        lighting: motionLighting,
                        geometry: simulation.geometry,
                        lateralOffset: drive.pose.lateralOffset,
                        appearance: .standard
                    )
                )
            }
        }

        for (index, lightingIndex) in seedLightings.enumerated() {
            rows.append(
                Row(
                    id: String(format: "seedic-%02d", index),
                    kind: .seedIncreasedContrast,
                    index: index,
                    lighting: lightingIndex,
                    geometry: speaking,
                    lateralOffset: drive.pose.lateralOffset,
                    appearance: MercuryAppearance(increasedContrast: true)
                )
            )
        }

        let checkpoints = [1, 9, 45, 150]
        var poseIndex = 0
        for (name, poseDrive) in Self.poseDrives() {
            for lightingIndex in seedLightings.prefix(4) {
                let simulation = MercurySimulation(seed: lightings[lightingIndex].seed, gains: calibration.gains)
                simulation.reset(to: drive)
                simulation.advance(steps: 90, drive: drive)
                var advanced = 0
                for checkpoint in checkpoints {
                    simulation.advance(steps: checkpoint - advanced, drive: poseDrive)
                    advanced = checkpoint
                    for increased in [false, true] {
                        rows.append(
                            Row(
                                id: String(format: "pose-%04d", poseIndex),
                                kind: .pose,
                                index: poseIndex,
                                lighting: lightingIndex,
                                geometry: simulation.geometry,
                                lateralOffset: poseDrive.pose.lateralOffset,
                                appearance: MercuryAppearance(increasedContrast: increased),
                                detail: "\(name) room \(lightingIndex) substep \(checkpoint)"
                                    + (increased ? " increased-contrast" : "")
                            )
                        )
                        poseIndex += 1
                    }
                }
            }
        }
        return Corpus(
            lightings: lightings,
            environments: environments,
            rows: rows,
            calibrationMilliseconds: calibrationMilliseconds
        )
    }

    /// Every pose `MercuryPose.target(for:)` produces, reached through the overlay model.
    static func poseDrives() -> [(String, MercurySimulation.Drive)] {
        func drive(_ configure: (RecordingOverlayModel) -> Void) -> MercurySimulation.Drive {
            let model = RecordingOverlayModel()
            configure(model)
            return MercurySimulation.Drive(
                pose: MercuryPose.target(for: model),
                samples: model.samples,
                reduceMotion: false
            )
        }
        func outcome(_ state: SessionState) -> (RecordingOverlayModel) -> Void {
            { model in
                if let outcome = RecordingOverlayOutcome(state: state) { model.present(outcome) }
            }
        }
        return [
            ("warming", drive { $0.update(.recording) }),
            ("listening", Self.drive(speaking: false)),
            ("speaking", Self.drive(speaking: true)),
            ("processing", drive { $0.update(.transcribing) }),
            ("gathered", drive(outcome(.copiedOnly(reason: "benchmark")))),
            ("lurch", drive(outcome(.insertFailed(reason: "benchmark")))),
            ("collapse", drive(outcome(.error(.audioNotFound)))),
        ]
    }

    /// `MercuryChromeBenchmark.drive(speaking:)`.
    static func drive(speaking: Bool) -> MercurySimulation.Drive {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        let samples: [Float] =
            speaking
            ? [0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46]
            : [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]
        for value in samples { model.record(value) }
        return MercurySimulation.Drive(
            pose: MercuryPose.target(for: model),
            samples: model.samples,
            reduceMotion: false
        )
    }

    /// `MercuryChromeBenchmark.benchmarkSeed(_:)`.
    static func benchmarkSeed(_ index: Int) -> UInt64 {
        UInt64(index) &* 0x9e37_79b9_7f4a_7c15 &+ 0x5155_4943_4b53_4c56
    }
}
