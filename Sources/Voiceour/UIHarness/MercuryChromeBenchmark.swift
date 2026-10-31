#if UI_HARNESS

    import CoreGraphics
    import Darwin
    import Foundation
    import QuartzCore
    import VoiceCore

    /// Distribution and temporal benchmark for the selected isolated chrome candidate.
    ///
    /// Three stock corpora on purpose. The 4,096-seed screen samples a fixed reflection manifold
    /// cheaply enough to bound the random room. The 64-seed raster corpus then verifies
    /// the real body, Fresnel, coverage, tone response and 8-bit output. The 64-seed collar
    /// corpus holds the collar around the 185×32 housing to the same per-seed bounds, lit by
    /// the response each seed's own collar bodies solve, as the engine lights them. None is a
    /// substitute for the contact sheets; each rejects failure modes an eye can miss.
    ///
    /// Both user rooms run the 4,096-seed screen on the stock look. The look corpus then
    /// holds every named look, on the island and on that collar, and the corners of tone,
    /// underglow, temperature and metal, to the same luminance bounds through the path a
    /// session takes: the look's room lighting, paint table, metered response and tuned body.
    /// One non-stock look repeats the 120 Hz budgets, because a look may change bake-time
    /// inputs only.
    ///
    /// Every speaking body hears a live microphone, whose meter shifts a new level into the buffer
    /// every 40 ms as a session's does, rather than one buffer held still. See ``MercurySpeechMeter``.
    @MainActor
    enum MercuryChromeBenchmark {
        private static let distributionSeeds = 4_096
        private static let rasterSeeds = 64
        /// The polished roughness both rooms' distribution screens sample at.
        private static let distributionRoughness: Float = 0.03
        /// Rooms every named look renders over on each layout, and every corner case on the
        /// island.
        private static let lookSeeds = 64
        private static let cornerSeeds = 64
        private static let scale = MercuryMetrics.rasterScale
        /// The non-stock performance arm. It changes every bake-time input at once — paint,
        /// finish, white balance, underglow, tone and body kit — and runs the fastest,
        /// most reactive motion law, so a per-look cost would show here first.
        private static let performanceLook = IslandLook.streetRacer

        struct Percentiles: Codable {
            var p05: Double
            var p50: Double
            var p95: Double
        }

        struct DistributionSummary: Codable {
            var room: String
            var seeds: Int
            var listeningMedianRange: [Double]
            var speakingMedianRange: [Double]
            var darkTailRange: [Double]
            var highlightTailRange: [Double]
            var worstCrushedFraction: Double
            var worstNearCeilingFraction: Double
            var worstSaturationP95: Double
            var worstCast: Double
            var failedSeeds: Int
            var failureCounts: [String: Int]
            var worstGroundSeparation: Double
        }

        struct RasterSummary: Codable {
            var seeds: Int
            var luminance: Percentiles
            var nearWhiteFraction: Double
            var increasedContrastNearWhiteFraction: Double
            var reflectedCoverageSteradians: Double
            var bandCountRange: [Int]
            var maxHighlightCentroidStepPixels: Double
            var medianDriftStops: Double
            var milliseconds: Double
        }

        /// One look-corpus case on one layout: its worst values over every room and both live
        /// poses.
        struct LookSummary: Codable {
            var name: String
            var appearance: String
            var seeds: Int
            var listeningMedianRange: [Double]
            var speakingMedianRange: [Double]
            var darkTailRange: [Double]
            var highlightTailRange: [Double]
            var narrowestSpan: Double
            var worstGroundSeparation: Double
            var worstCrushedFraction: Double
            var worstNearCeilingFraction: Double
            var worstIncreasedContrastNearWhiteFraction: Double
            var failedSeeds: Int
            var failureCounts: [String: Int]
        }

        struct LookCorpusSummary: Codable {
            /// Case-room pairs rendered, and how many of them failed a gate.
            var renders: Int
            var failedRenders: Int
            var looks: [LookSummary]
            var corners: [LookSummary]
            /// Every named look again, on the collar around the 185×32 housing.
            var collarLooks: [LookSummary]
            var milliseconds: Double
        }

        struct PerformanceSummary: Codable {
            var launchCalibrationMilliseconds: Double
            var coldFirstFrameMilliseconds: Double
            var rasterP50Milliseconds: Double
            var rasterP95Milliseconds: Double
            var rasterP99Milliseconds: Double
            var rasterCoreFractionAt120Hz: Double
            var engineLayerP50Milliseconds: Double
            var engineLayerP99Milliseconds: Double
            var engineLayerCoreFractionAt120Hz: Double
        }

        /// The collar around the 185×32 housing: its 64-seed corpus under the distribution
        /// screen's per-seed bounds, and the speaking collar's raster cost.
        struct CollarSummary: Codable {
            /// The canvas the collar is drawn on, points, width then height.
            var canvas: [Double]
            var seeds: Int
            var listeningMedianRange: [Double]
            var speakingMedianRange: [Double]
            var darkTailRange: [Double]
            var highlightTailRange: [Double]
            var nearWhiteFraction: Double
            var increasedContrastNearWhiteFraction: Double
            var worstCrushedFraction: Double
            var worstSaturationP95: Double
            var worstCast: Double
            var worstGroundSeparation: Double
            var failedSeeds: Int
            var failureCounts: [String: Int]
            var rasterP50Milliseconds: Double
            var rasterP95Milliseconds: Double
            var rasterP99Milliseconds: Double
            var rasterCoreFractionAt120Hz: Double
        }

        struct LookPerformanceSummary: Codable {
            var look: String
            var appearance: String
            var rasterP50Milliseconds: Double
            var rasterP95Milliseconds: Double
            var rasterP99Milliseconds: Double
            var rasterCoreFractionAt120Hz: Double
            var engineLayerP50Milliseconds: Double
            var engineLayerP99Milliseconds: Double
            var engineLayerCoreFractionAt120Hz: Double
        }

        struct Report: Codable {
            var candidate: String
            var distribution: DistributionSummary
            var overcastDistribution: DistributionSummary
            var raster: RasterSummary
            var looks: LookCorpusSummary
            var performance: PerformanceSummary
            var lookPerformance: LookPerformanceSummary
            var collar: CollarSummary
            var passed: Bool
            var failures: [String]
        }

        static func run(_ request: UIHarnessRequest) -> Bool {
            let started = ContinuousClock().now
            let calibrationStarted = ContinuousClock().now
            let gains = MercuryCalibration.shared.gains
            let calibrationMilliseconds =
                calibrationStarted.duration(to: ContinuousClock().now).milliseconds
            let listening = field(speaking: false, seed: MercuryMetrics.defaultSeed, gains: gains, layout: .island)
            let speaking = field(speaking: true, seed: MercuryMetrics.defaultSeed, gains: gains, layout: .island)
            let rasterizer = MercuryPrototypeRasterizer()
            let listeningDirections = subsample(
                rasterizer.reflectedDirections(field: listening, scale: scale),
                count: 256
            )
            let speakingDirections = subsample(
                rasterizer.reflectedDirections(field: speaking, scale: scale),
                count: 256
            )
            let distribution = distributionScreen(
                world: .roomOfTen,
                listeningDirections: listeningDirections,
                speakingDirections: speakingDirections
            )
            let raster = rasterScreen(
                listening: listening,
                speaking: speaking,
                rasterizer: rasterizer,
                started: started
            )
            let performance = performanceScreen(
                field: speaking,
                calibrationMilliseconds: calibrationMilliseconds
            )
            let collar = collarScreen(gains: gains)
            // The non-stock arm runs right after the stock arms and ahead of the long corpora,
            // so every stock number keeps its place in the run and the look arm is timed in
            // the same state.
            let lookPerformance = lookPerformanceScreen(gains: gains)
            let overcast = distributionScreen(
                world: .spectralWeather,
                listeningDirections: listeningDirections,
                speakingDirections: speakingDirections
            )
            let looks = lookCorpusScreen(gains: gains)
            var failures: [String] = []
            if distribution.failedSeeds > 0 {
                failures.append("distribution failures: \(distribution.failedSeeds)/\(distribution.seeds)")
            }
            if overcast.failedSeeds > 0 {
                failures.append(
                    "Overcast distribution failures: \(overcast.failedSeeds)/\(overcast.seeds)"
                )
            }
            if raster.nearWhiteFraction > 0.02 {
                failures.append("near-white area \(format(raster.nearWhiteFraction)) > 0.02")
            }
            if raster.increasedContrastNearWhiteFraction > 0.02 {
                failures.append(
                    "Increase Contrast near-white area "
                        + "\(format(raster.increasedContrastNearWhiteFraction)) > 0.02"
                )
            }
            if raster.reflectedCoverageSteradians < 2.0 {
                failures.append("reflected coverage \(format(raster.reflectedCoverageSteradians)) sr < 2.0 sr")
            }
            if raster.medianDriftStops > 1.0 {
                failures.append("median drift \(format(raster.medianDriftStops)) stops > 1.0")
            }
            if performance.launchCalibrationMilliseconds > 200 {
                failures.append(
                    "launch calibration \(format(performance.launchCalibrationMilliseconds))ms > 200ms"
                )
            }
            if performance.coldFirstFrameMilliseconds > 25 {
                failures.append(
                    "cold first frame \(format(performance.coldFirstFrameMilliseconds))ms > 25ms"
                )
            }
            failures += frameFailures(performance, arm: "")
            if collar.failedSeeds > 0 {
                failures.append("collar distribution failures: \(collar.failedSeeds)/\(collar.seeds)")
            }
            if collar.nearWhiteFraction > 0.02 {
                failures.append("collar near-white area \(format(collar.nearWhiteFraction)) > 0.02")
            }
            if collar.increasedContrastNearWhiteFraction > 0.02 {
                failures.append(
                    "collar Increase Contrast near-white area "
                        + "\(format(collar.increasedContrastNearWhiteFraction)) > 0.02"
                )
            }
            if collar.rasterP50Milliseconds > 0.55 {
                failures.append(
                    "collar raster p50 \(format(collar.rasterP50Milliseconds))ms > 0.55ms"
                )
            }
            if collar.rasterP99Milliseconds > 0.70 {
                failures.append(
                    "collar raster p99 \(format(collar.rasterP99Milliseconds))ms > 0.70ms"
                )
            }
            if collar.rasterCoreFractionAt120Hz > 0.066 {
                failures.append(
                    "collar 120 Hz raster CPU \(format(collar.rasterCoreFractionAt120Hz)) > 0.066 core"
                )
            }
            failures += frameFailures(lookPerformance, arm: "\(performanceLook.displayName) ")
            let lookCases = [("look", looks.looks + looks.corners), ("collar look", looks.collarLooks)]
            for (kind, summaries) in lookCases {
                for summary in summaries where summary.failedSeeds > 0 {
                    let counts = summary.failureCounts.keys.sorted()
                        .map { "\($0) \(summary.failureCounts[$0] ?? 0)" }
                        .joined(separator: ", ")
                    failures.append(
                        "\(kind) \(summary.name): \(summary.failedSeeds)/\(summary.seeds)"
                            + " rooms fail (\(counts))"
                    )
                }
            }
            let report = Report(
                candidate: productionCandidateLabel,
                distribution: distribution,
                overcastDistribution: overcast,
                raster: raster,
                looks: looks,
                performance: performance,
                lookPerformance: lookPerformance,
                collar: collar,
                passed: failures.isEmpty,
                failures: failures
            )
            let directory = request.outputDirectory.appendingPathComponent("mercury", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder.pretty.encode(report)
                try data.write(to: directory.appendingPathComponent("benchmark.json"), options: .atomic)
            } catch {
                fputs("mercury-benchmark: cannot write report: \(error)\n", stderr)
                return false
            }
            let collarFields =
                " collarFailed=\(collar.failedSeeds)/\(collar.seeds)"
                + " collarWhite=\(format(collar.nearWhiteFraction))/"
                + "\(format(collar.increasedContrastNearWhiteFraction))"
                + " collarRaster=\(format(collar.rasterP50Milliseconds))/"
                + "\(format(collar.rasterP99Milliseconds))ms"
                + " collarCPU@120=\(format(collar.rasterCoreFractionAt120Hz))core"
            print(
                "mercury-benchmark: seeds=\(distribution.seeds)"
                    + " failed=\(distribution.failedSeeds)"
                    + " coverage=\(format(raster.reflectedCoverageSteradians))sr"
                    + " white=\(format(raster.nearWhiteFraction))"
                    + " bands=\(raster.bandCountRange)"
                    + " highlightStep=\(format(raster.maxHighlightCentroidStepPixels))px"
                    + " drift=\(format(raster.medianDriftStops))stops"
                    + " calibration=\(format(performance.launchCalibrationMilliseconds))ms"
                    + " cold=\(format(performance.coldFirstFrameMilliseconds))ms"
                    + " raster=\(format(performance.rasterP50Milliseconds))/"
                    + "\(format(performance.rasterP99Milliseconds))ms"
                    + " cpu@120=\(format(performance.rasterCoreFractionAt120Hz))core"
                    + " frame=\(format(performance.engineLayerP50Milliseconds))/"
                    + "\(format(performance.engineLayerP99Milliseconds))ms"
                    + " engineLayerCPU@120=\(format(performance.engineLayerCoreFractionAt120Hz))core"
                    + collarFields
                    + " time=\(format(raster.milliseconds / 1000))s"
            )
            let lookLine = [
                "overcastSeeds=\(overcast.seeds)",
                "overcastFailed=\(overcast.failedSeeds)",
                "looks=\(looks.looks.count)x\(lookSeeds)",
                "corners=\(looks.corners.count)x\(cornerSeeds)",
                "collarLooks=\(looks.collarLooks.count)x\(lookSeeds)",
                "lookFailed=\(looks.failedRenders)/\(looks.renders)",
                lookPerformance.look,
                "raster=\(format(lookPerformance.rasterP50Milliseconds))/"
                    + "\(format(lookPerformance.rasterP99Milliseconds))ms",
                "cpu@120=\(format(lookPerformance.rasterCoreFractionAt120Hz))core",
                "frame=\(format(lookPerformance.engineLayerP50Milliseconds))/"
                    + "\(format(lookPerformance.engineLayerP99Milliseconds))ms",
                "engineLayerCPU@120=\(format(lookPerformance.engineLayerCoreFractionAt120Hz))core",
                "lookTime=\(format(looks.milliseconds / 1000))s",
                "total=\(format(started.duration(to: ContinuousClock().now).milliseconds / 1000))s",
            ]
            print("mercury-benchmark: \(lookLine.joined(separator: " "))")
            for failure in failures { fputs("mercury-benchmark: FAIL: \(failure)\n", stderr) }
            return failures.isEmpty
        }

        // MARK: - Distribution screen

        private static func distributionScreen(
            world: MercuryWorld,
            listeningDirections: [SIMD3<Double>],
            speakingDirections: [SIMD3<Double>]
        ) -> DistributionSummary {
            var tally = DistributionTally()
            // Spectral Weather has no per-direction form outside its bake, so its screen
            // runs the bake itself at the two manifolds' directions.
            let weatherBasis =
                world == .spectralWeather
                ? harmonicBasis((listeningDirections + speakingDirections).map(\.float))
                : []
            for index in 0..<distributionSeeds {
                let seed = benchmarkSeed(index)
                let listeningScene: [SIMD3<Double>]
                let speakingScene: [SIMD3<Double>]
                switch world {
                case .roomOfTen:
                    let room = RoomOfTenWorld(seed: seed)
                    listeningScene = listeningDirections.map {
                        room.radianceRGB($0.float, roughness: distributionRoughness).double
                    }
                    speakingScene = speakingDirections.map {
                        room.radianceRGB($0.float, roughness: distributionRoughness).double
                    }
                case .spectralWeather:
                    let sky = weatherRadiance(seed: seed, basis: weatherBasis)
                    listeningScene = Array(sky.prefix(listeningDirections.count))
                    speakingScene = Array(sky.dropFirst(listeningDirections.count))
                }
                guard
                    let response = solveResponse(
                        listening: listeningScene,
                        speaking: speakingScene
                    )
                else {
                    tally.reject("solve")
                    continue
                }
                tally.screen(
                    listening: listeningScene.map(response.map),
                    speaking: speakingScene.map(response.map)
                )
            }
            return DistributionSummary(
                room: world.displayName,
                seeds: distributionSeeds,
                listeningMedianRange: range(tally.listeningMedians),
                speakingMedianRange: range(tally.speakingMedians),
                darkTailRange: range(tally.darkTails),
                highlightTailRange: range(tally.highlightTails),
                worstCrushedFraction: tally.worstCrushed,
                worstNearCeilingFraction: tally.worstCeiling,
                worstSaturationP95: tally.worstSaturation,
                worstCast: tally.worstCast,
                failedSeeds: tally.failed,
                failureCounts: tally.failureCounts,
                worstGroundSeparation: tally.worstGround
            )
        }

        /// Spectral Weather's real harmonic basis at `directions`, one row per direction,
        /// built exactly as `MercuryEnvironment` builds it for its table's texels.
        private static func harmonicBasis(_ directions: [SIMD3<Float>]) -> [Float] {
            let count = SpectralWeatherWorld.coefficientCount
            var result = [Float](repeating: 0, count: directions.count * count)
            var scratch = [Double](repeating: 0, count: count)
            for (index, direction) in directions.enumerated() {
                SpectralWeatherWorld.evaluateBasis(
                    SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z)),
                    into: &scratch
                )
                for coefficient in 0..<count {
                    result[index * count + coefficient] = Float(scratch[coefficient])
                }
            }
            return result
        }

        /// One seed's Overcast sky in the directions `basis` holds, at the screen's polished
        /// roughness: the production generator and heat-kernel prefilter, through the very
        /// bake that fills the environment's table. Like Room of Ten's closed form it skips
        /// the table's grid band limit and normalization; the screen's response is scale-free.
        private static func weatherRadiance(seed: UInt64, basis: [Float]) -> [SIMD3<Double>] {
            let weather = SpectralWeatherWorld(seed: seed)
            var sky = [SIMD3<Float>](
                repeating: .zero,
                count: basis.count / SpectralWeatherWorld.coefficientCount
            )
            sky.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                weather.bake(into: base, basis: basis, roughness: Double(distributionRoughness))
            }
            return sky.map(\.double)
        }

        /// The distribution screen's per-seed bounds and their running verdict over a corpus:
        /// one definition of a failed seed, which both rooms' 4,096-seed screens and the collar
        /// corpus apply.
        @MainActor
        private struct DistributionTally {
            private(set) var listeningMedians: [Double] = []
            private(set) var speakingMedians: [Double] = []
            private(set) var darkTails: [Double] = []
            private(set) var highlightTails: [Double] = []
            private(set) var worstCrushed = 0.0
            private(set) var worstCeiling = 0.0
            private(set) var worstSaturation = 0.0
            private(set) var worstCast = 0.0
            private(set) var worstGround = Double.infinity
            private(set) var failed = 0
            private(set) var failureCounts: [String: Int] = [:]

            /// Holds one seed's displayed listening and speaking samples to every bound. A
            /// violation is tallied per body for the median, highlight and span bounds, per body
            /// and ground for the ground bound, and once per seed for the area, saturation and
            /// cast bounds.
            mutating func screen(listening: [SIMD3<Double>], speaking: [SIMD3<Double>]) {
                let listeningStats = percentiles(listening.map(MercuryDisplayResponse.luminance).sorted())
                let speakingStats = percentiles(speaking.map(MercuryDisplayResponse.luminance).sorted())
                listeningMedians.append(listeningStats.p50)
                speakingMedians.append(speakingStats.p50)
                darkTails.append(contentsOf: [listeningStats.p05, speakingStats.p05])
                highlightTails.append(contentsOf: [listeningStats.p95, speakingStats.p95])

                let crushed = Swift.max(crushedFraction(listening), crushedFraction(speaking))
                let ceiling = Swift.max(nearCeilingFraction(listening), nearCeilingFraction(speaking))
                let saturation = Swift.max(saturationP95(listening), saturationP95(speaking))
                let roomCast = Swift.max(cast(listening), cast(speaking))
                worstCrushed = Swift.max(worstCrushed, crushed)
                worstCeiling = Swift.max(worstCeiling, ceiling)
                worstSaturation = Swift.max(worstSaturation, saturation)
                worstCast = Swift.max(worstCast, roomCast)

                var violations: [String] = []
                for stats in [listeningStats, speakingStats] {
                    if stats.p50 < 0.18 || stats.p50 > 0.55 {
                        violations.append("median")
                    }
                    if stats.p95 < 0.60 || stats.p95 > 0.92 {
                        violations.append("highlight")
                    }
                    if stats.p95 - stats.p05 < 0.30 {
                        violations.append("flat")
                    }
                    for ground in [0.075, 0.45, 0.95] {
                        let separation = Swift.max(
                            contrastRatio(stats.p05, ground),
                            contrastRatio(stats.p95, ground)
                        )
                        worstGround = Swift.min(worstGround, separation)
                        if separation < 1.5 {
                            violations.append("ground")
                        }
                    }
                }
                // Chrome needs real black-card structure. Reject only when it takes over
                // more than a quarter of the body; the earlier 10% bound mislabeled the
                // material cue itself as a failure.
                if crushed > 0.25 {
                    violations.append("crushed")
                }
                if ceiling > 0.02 {
                    violations.append("ceiling")
                }
                if saturation > 0.12 {
                    violations.append("saturation")
                }
                if roomCast > 0.06 {
                    violations.append("cast")
                }
                for violation in violations {
                    failureCounts[violation, default: 0] += 1
                }
                if !violations.isEmpty { failed += 1 }
            }

            /// Counts a seed that never reached the bounds.
            mutating func reject(_ reason: String) {
                failed += 1
                failureCounts[reason, default: 0] += 1
            }
        }

        // MARK: - Raster and temporal screen

        private static func rasterScreen(
            listening: MercuryField,
            speaking: MercuryField,
            rasterizer coverageRasterizer: MercuryPrototypeRasterizer,
            started: ContinuousClock.Instant
        ) -> RasterSummary {
            let rasterizer = MercuryRasterizer()
            let calibration = MercuryCalibration.shared
            var everyLuminance: [Double] = []
            var worstWhite = 0.0
            var worstIncreasedWhite = 0.0
            var bandMinimum = Int.max
            var bandMaximum = 0
            for index in 0..<rasterSeeds {
                let seed = benchmarkSeed(index)
                let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
                let response = calibration.displayResponse(for: room, bodySeed: seed, layout: .island)
                let increased = response.remapped(
                    medianTarget: MercuryMetrics.increasedContrastMedian,
                    highlightTarget: MercuryMetrics.increasedContrastHighlight
                )!
                let scene = rasterizer.sampleSceneRadiance(
                    field: speaking,
                    environment: room,
                    scale: scale
                ).map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
                let samples = scene.map(response.map)
                let increasedSamples = scene.map(increased.map)
                everyLuminance.append(
                    contentsOf: samples.map(MercuryDisplayResponse.luminance)
                )
                worstWhite = Swift.max(worstWhite, nearCeilingFraction(samples))
                worstIncreasedWhite = Swift.max(
                    worstIncreasedWhite,
                    nearCeilingFraction(increasedSamples)
                )
                if let image = rasterizer.image(
                    field: speaking,
                    environment: room,
                    response: response,
                    appearance: .standard,
                    scale: scale
                ) {
                    let bands = bandCount(image: image)
                    bandMinimum = Swift.min(bandMinimum, bands)
                    bandMaximum = Swift.max(bandMaximum, bands)
                }
            }
            let motion = motionMetrics()
            let coverage = reflectedCoverage(
                coverageRasterizer.reflectedDirections(field: speaking, scale: scale)
            )
            let duration = started.duration(to: ContinuousClock().now)
            return RasterSummary(
                seeds: rasterSeeds,
                luminance: percentiles(everyLuminance.sorted()),
                nearWhiteFraction: worstWhite,
                increasedContrastNearWhiteFraction: worstIncreasedWhite,
                reflectedCoverageSteradians: coverage,
                bandCountRange: [bandMinimum == Int.max ? 0 : bandMinimum, bandMaximum],
                maxHighlightCentroidStepPixels: motion.step,
                medianDriftStops: motion.drift,
                milliseconds: duration.milliseconds
            )
        }

        private static func motionMetrics() -> (step: Double, drift: Double) {
            let seed = MercuryMetrics.defaultSeed
            let gains = MercuryCalibration.shared.gains
            let microphone = MercurySpeechMeter(speaking: true, seed: seed, layout: .island)
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: microphone.drive)
            microphone.advance(simulation, steps: 600)
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed,
                layout: .island
            )
            let rasterizer = MercuryRasterizer()
            var centroids: [Double] = []
            var medians: [Double] = []
            for _ in 0..<400 {  // 30 seconds at 75 ms per sample.
                microphone.advance(simulation, steps: 9)
                let field = MercuryField(
                    geometry: simulation.geometry,
                    spine: RecordingOverlayLayout.island.spine,
                    canvas: RecordingOverlayLayout.island.canvasRect.size
                )
                let samples = rasterizer.sampleSceneRadiance(
                    field: field,
                    environment: room,
                    scale: scale
                ).map {
                    response.map(
                        SIMD3(Double($0.x), Double($0.y), Double($0.z))
                    )
                }
                let luminance = samples.map(MercuryDisplayResponse.luminance)
                medians.append(percentiles(luminance.sorted()).p50)
                if let image = rasterizer.image(
                    field: field,
                    environment: room,
                    response: response,
                    appearance: .standard,
                    scale: scale
                ) {
                    centroids.append(highlightCentroid(image: image))
                }
            }
            let maximumStep =
                zip(centroids, centroids.dropFirst())
                .map { abs($1 - $0) }.max() ?? 0
            let positive = medians.filter { $0 > 0 }
            let drift =
                positive.isEmpty
                ? .infinity
                : log2((positive.max() ?? 1) / (positive.min() ?? 1))
            return (maximumStep, drift)
        }

        // MARK: - Look corpus

        /// The worst of one look-corpus case so far.
        private struct LookTally {
            var seeds = 0
            var failedSeeds = 0
            var failureCounts: [String: Int] = [:]
            var listeningMedians: [Double] = []
            var speakingMedians: [Double] = []
            var darkTails: [Double] = []
            var highlightTails: [Double] = []
            var narrowestSpan = Double.infinity
            var worstGround = Double.infinity
            var worstCrushed = 0.0
            var worstCeiling = 0.0
            var worstIncreasedWhite = 0.0
        }

        /// Every named look over 64 rooms on the island, then every corner over 64, then every
        /// named look over 64 rooms on the collar around the 185×32 housing, each through the
        /// look path a session takes: the room baked with the look's lighting, its paint table,
        /// the response calibration meters for that look in that room on that layout, and the
        /// tuned body settled 600 substeps under a live microphone. On the collar the body kit
        /// draws on the collar's terms and the response anchors the collar's own highlight.
        ///
        /// Saturation and colour cast stay stock-only gates: they measure liquid mercury's
        /// neutrality, and a look's colour is chosen.
        private static func lookCorpusScreen(gains: MercuryGains) -> LookCorpusSummary {
            let started = ContinuousClock().now
            let rasterizer = MercuryRasterizer()
            let looks = namedLooks(on: .island, gains: gains, rasterizer: rasterizer)

            // Room-major: the corners use three paints, one stock body and four room
            // lightings, so each room's bodies and baked lightings are built once and
            // shared by every corner that asks for the same ones.
            let corners = cornerAppearances()
            var tallies = [LookTally](repeating: LookTally(), count: corners.count)
            for index in 0..<cornerSeeds {
                let seed = benchmarkSeed(index)
                var environments: [MercuryEnvironment] = []
                var bodies: [(tune: MercuryTune, fields: [MercuryField])] = []
                for (cornerIndex, corner) in corners.enumerated() {
                    let look = MercuryLook(island: corner.appearance)
                    let environment: MercuryEnvironment
                    if let shared = environments.first(where: {
                        $0.world == look.world && $0.lighting == look.lighting
                    }) {
                        environment = shared
                    } else {
                        environment = MercuryEnvironment(
                            world: look.world,
                            seed: seed,
                            lighting: look.lighting
                        )
                        environments.append(environment)
                    }
                    let fields: [MercuryField]
                    if let shared = bodies.first(where: { $0.tune == look.tune }) {
                        fields = shared.fields
                    } else {
                        fields = livePoses(seed: seed, gains: gains, layout: .island, tune: look.tune)
                        bodies.append((look.tune, fields))
                    }
                    measure(
                        look: look,
                        seed: seed,
                        layout: .island,
                        fields: fields,
                        environment: environment,
                        paint: MercuryPaintLookup.lookup(for: look.paint),
                        rasterizer: rasterizer,
                        into: &tallies[cornerIndex]
                    )
                }
            }
            let cornerSummaries = zip(corners, tallies).map { corner, tally in
                summary(tally, name: corner.name, appearance: corner.appearance)
            }

            let collarLooks = namedLooks(
                on: UIFixtures.collarLayout(on: .fixtureNotch),
                gains: gains,
                rasterizer: rasterizer
            )
            let every = looks + cornerSummaries + collarLooks
            return LookCorpusSummary(
                renders: every.reduce(0) { $0 + $1.seeds },
                failedRenders: every.reduce(0) { $0 + $1.failedSeeds },
                looks: looks,
                corners: cornerSummaries,
                collarLooks: collarLooks,
                milliseconds: started.duration(to: ContinuousClock().now).milliseconds
            )
        }

        /// Every named look over `lookSeeds` rooms on `layout`. Look-major: calibration meters
        /// every room through the small process-wide paint cache, so one look's rooms run back
        /// to back. Each room is baked with that look's lighting and measured on that look's
        /// tuned bodies.
        private static func namedLooks(
            on layout: RecordingOverlayLayout,
            gains: MercuryGains,
            rasterizer: MercuryRasterizer
        ) -> [LookSummary] {
            IslandLook.allCases.map { island in
                let look = MercuryLook(island: island.appearance)
                let paint = MercuryPaintLookup.lookup(for: look.paint)
                var tally = LookTally()
                for index in 0..<lookSeeds {
                    let seed = benchmarkSeed(index)
                    measure(
                        look: look,
                        seed: seed,
                        layout: layout,
                        fields: livePoses(seed: seed, gains: gains, layout: layout, tune: look.tune),
                        environment: MercuryEnvironment(
                            world: look.world,
                            seed: seed,
                            lighting: look.lighting
                        ),
                        paint: paint,
                        rasterizer: rasterizer,
                        into: &tally
                    )
                }
                return summary(tally, name: island.rawValue, appearance: island.appearance)
            }
        }

        /// The extremes a user can combine and no named look reaches: every corner of
        /// brightness and contrast, without and with a full-strength saturated underglow,
        /// at both colour-temperature limits, on stock mercury, on chromium and on gold.
        private static func cornerAppearances() -> [(name: String, appearance: IslandAppearance)] {
            let tones = [(-100, 100), (100, -100), (-100, -100), (100, 100)]
            var corners: [(name: String, appearance: IslandAppearance)] = []
            for metal in [IslandMetal.mercury, .chromium, .gold] {
                for temperature in [-100, 100] {
                    for underglow in [false, true] {
                        for (brightness, contrast) in tones {
                            var island = IslandAppearance.stock
                            island.metal = metal
                            island.temperature = temperature
                            island.brightness = brightness
                            island.contrast = contrast
                            if underglow {
                                island.underglow = true
                                island.underglowHue = 300
                                island.underglowSaturation = 100
                                island.underglowStrength = 100
                            }
                            let glow = underglow ? "300/100/100" : "off"
                            corners.append(
                                (
                                    "\(metal.rawValue) brightness=\(brightness)"
                                        + " contrast=\(contrast) underglow=\(glow)"
                                        + " temperature=\(temperature)",
                                    island
                                )
                            )
                        }
                    }
                }
            }
            return corners
        }

        /// Gates one case over one room on `layout`. Both live poses render through the look's
        /// own paint table under the response calibration meters for that look in that room on
        /// that layout; Increase Contrast is that response's own remap, exactly as the
        /// rasterizer selects it.
        private static func measure(
            look: MercuryLook,
            seed: UInt64,
            layout: RecordingOverlayLayout,
            fields: [MercuryField],
            environment: MercuryEnvironment,
            paint: MercuryPaintLookup,
            rasterizer: MercuryRasterizer,
            into tally: inout LookTally
        ) {
            let response = MercuryCalibration.shared.displayResponse(
                for: environment,
                bodySeed: seed,
                layout: layout,
                look: look
            )
            let increased = response.remapped(
                medianTarget: MercuryMetrics.increasedContrastMedian,
                highlightTarget: MercuryMetrics.increasedContrastHighlight
            )
            var failures: [String] = []
            if increased == nil { failures.append("increasedContrastSolve") }
            for (pose, field) in fields.enumerated() {
                let scene = rasterizer.sampleSceneRadiance(
                    field: field,
                    environment: environment,
                    paint: paint,
                    scale: scale
                ).map(\.double)
                let display = scene.map(response.map)
                let stats = percentiles(display.map(MercuryDisplayResponse.luminance).sorted())
                if pose == 0 {
                    tally.listeningMedians.append(stats.p50)
                } else {
                    tally.speakingMedians.append(stats.p50)
                }
                tally.darkTails.append(stats.p05)
                tally.highlightTails.append(stats.p95)
                tally.narrowestSpan = Swift.min(tally.narrowestSpan, stats.p95 - stats.p05)
                if stats.p50 < 0.18 || stats.p50 > 0.55 { failures.append("median") }
                if stats.p95 < 0.60 || stats.p95 > 0.92 { failures.append("highlight") }
                if stats.p95 - stats.p05 < 0.30 { failures.append("flat") }
                for ground in [0.075, 0.45, 0.95] {
                    let separation = Swift.max(
                        contrastRatio(stats.p05, ground),
                        contrastRatio(stats.p95, ground)
                    )
                    tally.worstGround = Swift.min(tally.worstGround, separation)
                    if separation < 1.5 { failures.append("ground") }
                }
                let crushed = crushedFraction(display)
                let ceiling = nearCeilingFraction(display)
                tally.worstCrushed = Swift.max(tally.worstCrushed, crushed)
                tally.worstCeiling = Swift.max(tally.worstCeiling, ceiling)
                if crushed > 0.25 { failures.append("crushed") }
                if ceiling > 0.02 { failures.append("ceiling") }
                if let increased {
                    let white = nearCeilingFraction(scene.map(increased.map))
                    tally.worstIncreasedWhite = Swift.max(tally.worstIncreasedWhite, white)
                    if white > 0.02 { failures.append("increasedContrastWhite") }
                }
            }
            tally.seeds += 1
            for failure in failures { tally.failureCounts[failure, default: 0] += 1 }
            if !failures.isEmpty { tally.failedSeeds += 1 }
        }

        private static func summary(
            _ tally: LookTally,
            name: String,
            appearance: IslandAppearance
        ) -> LookSummary {
            LookSummary(
                name: name,
                appearance: appearance.canonicalDescription,
                seeds: tally.seeds,
                listeningMedianRange: range(tally.listeningMedians),
                speakingMedianRange: range(tally.speakingMedians),
                darkTailRange: range(tally.darkTails),
                highlightTailRange: range(tally.highlightTails),
                narrowestSpan: tally.narrowestSpan,
                worstGroundSeparation: tally.worstGround,
                worstCrushedFraction: tally.worstCrushed,
                worstNearCeilingFraction: tally.worstCeiling,
                worstIncreasedContrastNearWhiteFraction: tally.worstIncreasedWhite,
                failedSeeds: tally.failedSeeds,
                failureCounts: tally.failureCounts
            )
        }

        // MARK: - Performance

        private static func performanceScreen(
            field: MercuryField,
            calibrationMilliseconds: Double
        ) -> PerformanceSummary {
            let seed = MercuryMetrics.defaultSeed
            let coldStarted = ContinuousClock().now
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed,
                layout: .island
            )
            let rasterizer = MercuryRasterizer()
            _ = rasterizer.image(
                field: field,
                environment: room,
                response: response,
                appearance: .standard,
                scale: scale
            )
            let cold =
                coldStarted.duration(to: ContinuousClock().now).milliseconds
            let raster = rasterTiming(
                field: field,
                environment: room,
                response: response,
                paint: .stock,
                rasterizer: rasterizer
            )
            let engineLayer = engineLayerTiming(look: .stock, seed: seed)
            return PerformanceSummary(
                launchCalibrationMilliseconds: calibrationMilliseconds,
                coldFirstFrameMilliseconds: cold,
                rasterP50Milliseconds: raster.p50,
                rasterP95Milliseconds: raster.p95,
                rasterP99Milliseconds: raster.p99,
                rasterCoreFractionAt120Hz: raster.coreFractionAt120Hz,
                engineLayerP50Milliseconds: engineLayer.p50,
                engineLayerP99Milliseconds: engineLayer.p99,
                engineLayerCoreFractionAt120Hz: engineLayer.coreFractionAt120Hz
            )
        }

        /// The stock frame budgets, held by the non-stock arm's tuned speaking island body in
        /// its own lighting, paint and response.
        private static func lookPerformanceScreen(gains: MercuryGains) -> LookPerformanceSummary {
            let seed = MercuryMetrics.defaultSeed
            let island = performanceLook.appearance
            let look = MercuryLook(island: island)
            let speaking = field(speaking: true, seed: seed, gains: gains, layout: .island, tune: look.tune)
            let room = MercuryEnvironment(world: look.world, seed: seed, lighting: look.lighting)
            let paint = MercuryPaintLookup.lookup(for: look.paint)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed,
                layout: .island,
                look: look
            )
            let rasterizer = MercuryRasterizer()
            // Untimed, like the stock arm's cold frame: the first raster allocates the
            // bitmap and compiles the response table.
            _ = rasterizer.image(
                field: speaking,
                environment: room,
                response: response,
                appearance: .standard,
                paint: paint,
                scale: scale
            )
            let raster = rasterTiming(
                field: speaking,
                environment: room,
                response: response,
                paint: paint,
                rasterizer: rasterizer
            )
            let engineLayer = engineLayerTiming(look: look, seed: seed)
            return LookPerformanceSummary(
                look: performanceLook.rawValue,
                appearance: island.canonicalDescription,
                rasterP50Milliseconds: raster.p50,
                rasterP95Milliseconds: raster.p95,
                rasterP99Milliseconds: raster.p99,
                rasterCoreFractionAt120Hz: raster.coreFractionAt120Hz,
                engineLayerP50Milliseconds: engineLayer.p50,
                engineLayerP99Milliseconds: engineLayer.p99,
                engineLayerCoreFractionAt120Hz: engineLayer.coreFractionAt120Hz
            )
        }

        /// What the 120 Hz CPU fractions divide by: 1,200 frames at 120 Hz represent ten seconds.
        private static let representedSeconds = 10.0

        /// Untimed frames of one substep each, 0.75 s, before the engine's timing starts. A body
        /// emerging from empty then holds 99.5 % of its pose's volume and 99.8 % of its length.
        private static let emergenceFrames = 90

        /// Wall time per frame over 240 rasters of one body in `paint`, then the CPU 1,200 more
        /// cost as a fraction of one core at 120 Hz. `rasterizer` must already have drawn this
        /// canvas once, so neither measure carries its context allocation.
        private static func rasterTiming(
            field: MercuryField,
            environment: MercuryEnvironment,
            response: MercuryDisplayResponse,
            paint: MercuryPaintLookup,
            rasterizer: MercuryRasterizer
        ) -> (p50: Double, p95: Double, p99: Double, coreFractionAt120Hz: Double) {
            var durations: [Double] = []
            durations.reserveCapacity(240)
            for _ in 0..<240 {
                let frameStarted = ContinuousClock().now
                _ = rasterizer.image(
                    field: field,
                    environment: environment,
                    response: response,
                    appearance: .standard,
                    paint: paint,
                    scale: scale
                )
                durations.append(
                    frameStarted.duration(to: ContinuousClock().now).milliseconds
                )
            }
            durations.sort()

            let cpuStarted = processCPUSeconds()
            var sink = 0
            for _ in 0..<1_200 {
                sink &+=
                    rasterizer.image(
                        field: field,
                        environment: environment,
                        response: response,
                        appearance: .standard,
                        paint: paint,
                        scale: scale
                    )?.width ?? 0
            }
            let coreFraction = (processCPUSeconds() - cpuStarted) / representedSeconds
            _ = sink
            return (
                durations[durations.count / 2],
                durations[durations.count * 95 / 100],
                durations[durations.count * 99 / 100],
                coreFraction
            )
        }

        /// The engine plus the layer presentation the display link drives, for `look`'s speaking
        /// island body under a live microphone: wall time per frame over 240 frames, then the CPU
        /// 1,200 more cost as a fraction of one core at 120 Hz.
        private static func engineLayerTiming(
            look: MercuryLook,
            seed: UInt64
        ) -> (p50: Double, p99: Double, coreFractionAt120Hz: Double) {
            let microphone = MercurySpeechMeter(speaking: true, seed: seed, layout: .island)
            let engine = MercuryEngine(
                seed: seed,
                look: look,
                hitRegion: MercuryHitRegion()
            )
            let presentationLayer = CALayer()
            let initialImage = engine.frame(
                advancing: 0,
                seed: seed,
                look: look,
                drive: microphone.drive,
                appearance: .standard,
                layout: .island
            )
            MercuryLayerPresenter.present(initialImage, on: presentationLayer)
            // The first live frame starts the body empty, and it grows into its pose. The timing is of
            // a steady body, so the emergence plays out first, untimed, at the timed frames' one
            // substep each. The meter ticks between frames, as a level reaches the model between two
            // display-link callbacks: the engine meets each new buffer inside the next frame, as one
            // voice refresh, and the timed span is the frame alone.
            for _ in 0..<emergenceFrames {
                let image = engine.frame(
                    advancing: 1,
                    seed: seed,
                    look: look,
                    drive: microphone.drive,
                    appearance: .standard,
                    layout: .island
                )
                MercuryLayerPresenter.present(image, on: presentationLayer)
                microphone.elapse(1)
            }
            var durations: [Double] = []
            durations.reserveCapacity(240)
            for _ in 0..<240 {
                let frameStarted = ContinuousClock().now
                let image = engine.frame(
                    advancing: 1,
                    seed: seed,
                    look: look,
                    drive: microphone.drive,
                    appearance: .standard,
                    layout: .island
                )
                MercuryLayerPresenter.present(image, on: presentationLayer)
                durations.append(
                    frameStarted.duration(to: ContinuousClock().now).milliseconds
                )
                microphone.elapse(1)
            }
            durations.sort()

            var sink = 0
            let cpuStarted = processCPUSeconds()
            for _ in 0..<1_200 {
                let image = engine.frame(
                    advancing: 1,
                    seed: seed,
                    look: look,
                    drive: microphone.drive,
                    appearance: .standard,
                    layout: .island
                )
                MercuryLayerPresenter.present(image, on: presentationLayer)
                sink &+= image?.width ?? 0
                microphone.elapse(1)
            }
            let coreFraction = (processCPUSeconds() - cpuStarted) / representedSeconds
            _ = sink
            return (
                durations[durations.count / 2],
                durations[durations.count * 99 / 100],
                coreFraction
            )
        }

        /// The 120 Hz budgets. Every look is held to the stock ones: a look changes only
        /// bake-time inputs and per-instance scalars, never per-pixel work. `arm` names a
        /// non-stock arm in its messages.
        private static func frameFailures(
            _ cost: some MercuryFrameCost,
            arm: String
        ) -> [String] {
            var failures: [String] = []
            if cost.rasterP50Milliseconds > 0.55 {
                failures.append(
                    "\(arm)raster p50 \(format(cost.rasterP50Milliseconds))ms > 0.55ms"
                )
            }
            if cost.rasterP99Milliseconds > 0.70 {
                failures.append(
                    "\(arm)raster p99 \(format(cost.rasterP99Milliseconds))ms > 0.70ms"
                )
            }
            if cost.rasterCoreFractionAt120Hz > 0.066 {
                failures.append(
                    "\(arm)120 Hz raster CPU \(format(cost.rasterCoreFractionAt120Hz)) > 0.066 core"
                )
            }
            if cost.engineLayerP50Milliseconds > 0.65 {
                failures.append(
                    "\(arm)engine+layer p50 \(format(cost.engineLayerP50Milliseconds))ms > 0.65ms"
                )
            }
            if cost.engineLayerP99Milliseconds > 0.85 {
                failures.append(
                    "\(arm)engine+layer p99 \(format(cost.engineLayerP99Milliseconds))ms > 0.85ms"
                )
            }
            if cost.engineLayerCoreFractionAt120Hz > 0.08 {
                failures.append(
                    "\(arm)engine+layer CPU \(format(cost.engineLayerCoreFractionAt120Hz))"
                        + " > 0.08 core"
                )
            }
            return failures
        }

        private static func processCPUSeconds() -> Double {
            var value = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
            return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
        }

        // MARK: - Collar corpus

        /// The raster corpus on the collar around the 185×32 housing, and the speaking
        /// collar's raster cost.
        ///
        /// Each of the 64 seeds is a session: its own listening and speaking collar bodies, the
        /// speaking one hearing that seed's own speech, settled 600 substeps in its own room and
        /// lit through the shipping response the engine lights them with, which
        /// `MercuryCalibration` meters on that seed's collar bodies. The collar shows only its
        /// outer half, below and beside the housing, so it reflects a different part of the room
        /// than the island's whole crown, and a response metered on the island's body is not the
        /// collar's. The distribution screen's per-seed bounds apply unchanged, to the shipping
        /// raster's own samples rather than to a reflection manifold, and near-white is bounded
        /// in both bodies under both contrast settings.
        private static func collarScreen(gains: MercuryGains) -> CollarSummary {
            let layout = UIFixtures.collarLayout(on: .fixtureNotch)
            let calibration = MercuryCalibration.shared
            let rasterizer = MercuryRasterizer()
            var tally = DistributionTally()
            var worstIncreasedWhite = 0.0
            for index in 0..<rasterSeeds {
                let seed = benchmarkSeed(index)
                let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
                let response = calibration.displayResponse(for: room, bodySeed: seed, layout: layout)
                let increased = response.remapped(
                    medianTarget: MercuryMetrics.increasedContrastMedian,
                    highlightTarget: MercuryMetrics.increasedContrastHighlight
                )!
                let listening = rasterizer.sampleSceneRadiance(
                    field: field(speaking: false, seed: seed, gains: gains, layout: layout),
                    environment: room,
                    scale: scale
                ).map(\.double)
                let speaking = rasterizer.sampleSceneRadiance(
                    field: field(speaking: true, seed: seed, gains: gains, layout: layout),
                    environment: room,
                    scale: scale
                ).map(\.double)
                tally.screen(
                    listening: listening.map(response.map),
                    speaking: speaking.map(response.map)
                )
                worstIncreasedWhite = Swift.max(
                    worstIncreasedWhite,
                    nearCeilingFraction(listening.map(increased.map)),
                    nearCeilingFraction(speaking.map(increased.map))
                )
            }

            // Timed on the island performance screen's seed and room, so the two raster costs
            // differ by the body alone.
            let timingSeed = MercuryMetrics.defaultSeed
            let timingRoom = MercuryEnvironment(world: .roomOfTen, seed: timingSeed)
            let timingResponse = calibration.displayResponse(for: timingRoom, bodySeed: timingSeed, layout: layout)
            let timedBody = field(speaking: true, seed: timingSeed, gains: gains, layout: layout)
            let timingRasterizer = MercuryRasterizer()
            // The first frame allocates this canvas's context. The island's cold frame already
            // gates that cost, so the collar's timing starts warm, as the island's does.
            _ = timingRasterizer.image(
                field: timedBody,
                environment: timingRoom,
                response: timingResponse,
                appearance: .standard,
                scale: scale
            )
            let timing = rasterTiming(
                field: timedBody,
                environment: timingRoom,
                response: timingResponse,
                paint: .stock,
                rasterizer: timingRasterizer
            )
            return CollarSummary(
                canvas: [Double(layout.canvasRect.width), Double(layout.canvasRect.height)],
                seeds: rasterSeeds,
                listeningMedianRange: range(tally.listeningMedians),
                speakingMedianRange: range(tally.speakingMedians),
                darkTailRange: range(tally.darkTails),
                highlightTailRange: range(tally.highlightTails),
                nearWhiteFraction: tally.worstCeiling,
                increasedContrastNearWhiteFraction: worstIncreasedWhite,
                worstCrushedFraction: tally.worstCrushed,
                worstSaturationP95: tally.worstSaturation,
                worstCast: tally.worstCast,
                worstGroundSeparation: tally.worstGround,
                failedSeeds: tally.failed,
                failureCounts: tally.failureCounts,
                rasterP50Milliseconds: timing.p50,
                rasterP95Milliseconds: timing.p95,
                rasterP99Milliseconds: timing.p99,
                rasterCoreFractionAt120Hz: timing.coreFractionAt120Hz
            )
        }

        // MARK: - Metrics and fixtures

        private static var productionCandidateLabel: String {
            "M\(MercuryMetrics.roomLobeCount)"
                + " λ\(Int(MercuryMetrics.roomLambdaMin))-\(Int(MercuryMetrics.roomLambdaMax))"
                + " σ\(MercuryMetrics.roomLogIntensityRange)"
                + " b\(MercuryMetrics.roomBounceFraction)"
                + " c\(MercuryMetrics.roomChromaStrength)"
        }

        private static func solveResponse(
            listening: [SIMD3<Double>],
            speaking: [SIMD3<Double>]
        ) -> MercuryDisplayResponse? {
            let values = (listening + speaking)
                .map(MercuryDisplayResponse.luminance).sorted()
            guard values.count > 100 else { return nil }
            return MercuryDisplayResponse.solve(
                sceneMedian: values[values.count / 2],
                sceneHighlight: values[values.count * 98 / 100],
                medianTarget: MercuryMetrics.targetDisplayLuminance,
                highlightTarget: MercuryMetrics.targetHighlightLuminance,
                ceiling: MercuryMetrics.displayCeiling
            )
        }

        /// The body `seed` grows on `layout` under a live microphone, placed at rest on its pose and
        /// settled 600 substeps under `tune`, the look's law and drawing transform. It never
        /// emerges, so the raster timings drawn from it, the island's and the collar's, time a
        /// steady body with no warm-up of their own.
        private static func field(
            speaking: Bool,
            seed: UInt64,
            gains: MercuryGains,
            layout: RecordingOverlayLayout,
            tune: MercuryTune = .stock
        ) -> MercuryField {
            let microphone = MercurySpeechMeter(speaking: speaking, seed: seed, layout: layout)
            let simulation = MercurySimulation(seed: seed, gains: gains, tune: tune)
            simulation.reset(to: microphone.drive)
            microphone.advance(simulation, steps: 600)
            return MercuryField(
                geometry: simulation.geometry,
                spine: layout.spine,
                canvas: layout.canvasRect.size
            )
        }

        /// Both live poses of `seed`'s session on `layout` under `tune`: the listening body,
        /// then the speaking one.
        private static func livePoses(
            seed: UInt64,
            gains: MercuryGains,
            layout: RecordingOverlayLayout,
            tune: MercuryTune
        ) -> [MercuryField] {
            [false, true].map { speaking in
                field(speaking: speaking, seed: seed, gains: gains, layout: layout, tune: tune)
            }
        }

        private static func benchmarkSeed(_ index: Int) -> UInt64 {
            UInt64(index) &* 0x9e37_79b9_7f4a_7c15 &+ 0x5155_4943_4b53_4c56
        }

        private static func subsample(
            _ values: [SIMD3<Double>],
            count: Int
        ) -> [SIMD3<Double>] {
            guard values.count > count else { return values }
            return (0..<count).map { values[$0 * values.count / count] }
        }

        private static func percentiles(_ sorted: [Double]) -> Percentiles {
            guard !sorted.isEmpty else { return Percentiles(p05: 0, p50: 0, p95: 0) }
            return Percentiles(
                p05: sorted[sorted.count * 5 / 100],
                p50: sorted[sorted.count / 2],
                p95: sorted[sorted.count * 95 / 100]
            )
        }

        private static func range(_ values: [Double]) -> [Double] {
            [values.min() ?? 0, values.max() ?? 0]
        }

        private static func nearCeilingFraction(_ samples: [SIMD3<Double>]) -> Double {
            guard !samples.isEmpty else { return 1 }
            return Double(
                samples.filter { MercuryDisplayResponse.luminance($0) >= 0.93 }.count
            ) / Double(samples.count)
        }

        private static func crushedFraction(_ samples: [SIMD3<Double>]) -> Double {
            guard !samples.isEmpty else { return 1 }
            return Double(
                samples.filter { MercuryDisplayResponse.luminance($0) <= 0.01 }.count
            ) / Double(samples.count)
        }

        private static func contrastRatio(_ first: Double, _ second: Double) -> Double {
            (Swift.max(first, second) + 0.05)
                / (Swift.min(first, second) + 0.05)
        }

        private static func saturationP95(_ samples: [SIMD3<Double>]) -> Double {
            let values = samples.map { value in
                let maximum = value.max()
                return maximum > 0 ? (maximum - value.min()) / maximum : 0
            }.sorted()
            return values.isEmpty ? 0 : values[values.count * 95 / 100]
        }

        private static func cast(_ samples: [SIMD3<Double>]) -> Double {
            guard !samples.isEmpty else { return 1 }
            let mean = samples.reduce(SIMD3<Double>.zero, +) / Double(samples.count)
            let luminance = MercuryDisplayResponse.luminance(mean)
            return luminance > 0 ? (mean.max() - mean.min()) / luminance : 0
        }

        private static func reflectedCoverage(_ directions: [SIMD3<Double>]) -> Double {
            let columns = 72
            let rows = 36
            var counts = [Int](repeating: 0, count: columns * rows)
            for direction in directions {
                let azimuth = atan2(direction.y, direction.x)
                let column = Swift.min(
                    columns - 1,
                    Swift.max(0, Int((azimuth + .pi) / (2 * .pi) * Double(columns)))
                )
                let row = Swift.min(
                    rows - 1,
                    Swift.max(0, Int((direction.z + 1) / 2 * Double(rows)))
                )
                counts[row * columns + column] += 1
            }
            let total = Double(directions.count)
            guard total > 0 else { return 0 }
            let entropy = counts.reduce(0.0) { value, count in
                guard count > 0 else { return value }
                let probability = Double(count) / total
                return value - probability * log(probability)
            }
            return exp(entropy) * (4 * Double.pi / Double(columns * rows))
        }

        private static func bandCount(image: CGImage) -> Int {
            guard let data = image.dataProvider?.data as Data? else { return 0 }
            let column = image.width / 2
            var profile: [Double] = []
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<image.height {
                    let offset = row * image.bytesPerRow + column * 4
                    guard base[offset + 3] > 230 else { continue }
                    profile.append(
                        0.2126 * Double(base[offset])
                            + 0.7152 * Double(base[offset + 1])
                            + 0.0722 * Double(base[offset + 2])
                    )
                }
            }
            guard profile.count >= 7 else { return 0 }
            let weights = [1.0, 2.0, 3.0, 2.0, 1.0]
            let smooth = profile.indices.map { index in
                var total = 0.0
                var weight = 0.0
                for offset in -2...2 {
                    let sample = index + offset
                    guard sample >= 0, sample < profile.count else { continue }
                    let localWeight = weights[offset + 2]
                    total += localWeight * profile[sample]
                    weight += localWeight
                }
                return total / weight
            }
            var extrema = 0
            for index in 2..<(smooth.count - 2) {
                let left = smooth[index] - smooth[index - 1]
                let right = smooth[index + 1] - smooth[index]
                let prominence = Swift.max(
                    abs(smooth[index] - smooth[index - 2]),
                    abs(smooth[index] - smooth[index + 2])
                )
                if left * right < 0, prominence > 8 { extrema += 1 }
            }
            return extrema
        }

        private static func highlightCentroid(image: CGImage) -> Double {
            guard let data = image.dataProvider?.data as Data? else { return 0 }
            var pixels: [(x: Int, luminance: Double)] = []
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<image.height {
                    for column in 0..<image.width {
                        let offset = row * image.bytesPerRow + column * 4
                        guard base[offset + 3] > 127 else { continue }
                        pixels.append(
                            (
                                column,
                                0.2126 * Double(base[offset])
                                    + 0.7152 * Double(base[offset + 1])
                                    + 0.0722 * Double(base[offset + 2])
                            )
                        )
                    }
                }
            }
            let sorted = pixels.map(\.luminance).sorted()
            guard !sorted.isEmpty else { return 0 }
            let threshold = sorted[sorted.count * 75 / 100]
            var weighted = 0.0
            var total = 0.0
            for pixel in pixels {
                let weight = Swift.max(pixel.luminance - threshold, 0)
                weighted += Double(pixel.x) * weight
                total += weight
            }
            return total > 0 ? weighted / total : 0
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.4f", value)
        }
    }

    /// The steady-state frame cost both performance arms report and are gated on.
    private protocol MercuryFrameCost {
        var rasterP50Milliseconds: Double { get }
        var rasterP99Milliseconds: Double { get }
        var rasterCoreFractionAt120Hz: Double { get }
        var engineLayerP50Milliseconds: Double { get }
        var engineLayerP99Milliseconds: Double { get }
        var engineLayerCoreFractionAt120Hz: Double { get }
    }

    extension MercuryChromeBenchmark.PerformanceSummary: MercuryFrameCost {}
    extension MercuryChromeBenchmark.LookPerformanceSummary: MercuryFrameCost {}

    extension SIMD3 where Scalar == Float {
        fileprivate var double: SIMD3<Double> { SIMD3<Double>(Double(x), Double(y), Double(z)) }
    }

    extension SIMD3 where Scalar == Double {
        fileprivate var float: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
    }

    extension Duration {
        fileprivate var milliseconds: Double {
            let components = self.components
            return Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1e15
        }
    }

    extension JSONEncoder {
        fileprivate static var pretty: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return encoder
        }
    }

#endif
