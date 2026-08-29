#if UI_HARNESS

    import CoreGraphics
    import Darwin
    import Foundation

    /// Distribution and temporal benchmark for the selected isolated chrome candidate.
    ///
    /// Two corpora on purpose. The 4,096-seed screen samples a fixed reflection manifold
    /// cheaply enough to bound the random room. The 64-seed raster corpus then verifies
    /// the real body, Fresnel, coverage, tone response and 8-bit output. Neither is a
    /// substitute for the contact sheets; both reject failure modes an eye can miss.
    @MainActor
    enum MercuryChromeBenchmark {
        private static let distributionSeeds = 4_096
        private static let rasterSeeds = 64
        private static let scale = MercuryMetrics.rasterScale

        struct Percentiles: Codable {
            var p05: Double
            var p50: Double
            var p95: Double
        }

        struct DistributionSummary: Codable {
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

        struct PerformanceSummary: Codable {
            var launchCalibrationMilliseconds: Double
            var coldFirstFrameMilliseconds: Double
            var rasterP50Milliseconds: Double
            var rasterP95Milliseconds: Double
            var rasterP99Milliseconds: Double
            var rasterCoreFractionAt30Hz: Double
        }
        struct Report: Codable {
            var candidate: String
            var distribution: DistributionSummary
            var raster: RasterSummary
            var performance: PerformanceSummary
            var passed: Bool
            var failures: [String]
        }

        static func run(_ request: UIHarnessRequest) -> Bool {
            let started = ContinuousClock().now
            let calibrationStarted = ContinuousClock().now
            let gains = MercuryCalibration.shared.gains
            let calibrationMilliseconds =
                calibrationStarted.duration(to: ContinuousClock().now).milliseconds
            let listening = field(speaking: false, seed: MercuryMetrics.defaultSeed, gains: gains)
            let speaking = field(speaking: true, seed: MercuryMetrics.defaultSeed, gains: gains)
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
            var failures: [String] = []
            if distribution.failedSeeds > 0 {
                failures.append("distribution failures: \(distribution.failedSeeds)/\(distribution.seeds)")
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
            if performance.rasterCoreFractionAt30Hz > 0.055 {
                failures.append(
                    "raster CPU \(format(performance.rasterCoreFractionAt30Hz)) > 0.055 core"
                )
            }
            if performance.rasterP99Milliseconds
                > 3 * performance.rasterP50Milliseconds
            {
                failures.append(
                    "raster p99 \(format(performance.rasterP99Milliseconds))ms > 3× p50"
                )
            }
            let report = Report(
                candidate: productionCandidateLabel,
                distribution: distribution,
                raster: raster,
                performance: performance,
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
                    + " cpu=\(format(performance.rasterCoreFractionAt30Hz))core"
                    + " time=\(format(raster.milliseconds / 1000))s"
            )
            for failure in failures { fputs("mercury-benchmark: FAIL: \(failure)\n", stderr) }
            return failures.isEmpty
        }

        // MARK: - Distribution screen

        private static func distributionScreen(
            listeningDirections: [SIMD3<Double>],
            speakingDirections: [SIMD3<Double>]
        ) -> DistributionSummary {
            var listeningMedians: [Double] = []
            var speakingMedians: [Double] = []
            var darkTails: [Double] = []
            var highlightTails: [Double] = []
            var worstCrushed = 0.0
            var worstCeiling = 0.0
            var worstSaturation = 0.0
            var worstGround = Double.infinity
            var worstCast = 0.0
            var failed = 0
            var failureCounts: [String: Int] = [:]
            for index in 0..<distributionSeeds {
                let seed = benchmarkSeed(index)
                let room = RoomOfTenWorld(seed: seed)
                let listeningScene = listeningDirections.map {
                    room.radianceRGB($0.float, roughness: 0.03).double
                }
                let speakingScene = speakingDirections.map {
                    room.radianceRGB($0.float, roughness: 0.03).double
                }
                guard
                    let response = solveResponse(
                        listening: listeningScene,
                        speaking: speakingScene
                    )
                else {
                    failed += 1
                    failureCounts["solve", default: 0] += 1
                    continue
                }
                let listeningDisplay = listeningScene.map(response.map)
                let speakingDisplay = speakingScene.map(response.map)
                let listeningLuminance =
                    listeningDisplay
                    .map(MercuryDisplayResponse.luminance).sorted()
                let speakingLuminance =
                    speakingDisplay
                    .map(MercuryDisplayResponse.luminance).sorted()
                let listeningStats = percentiles(listeningLuminance)
                let speakingStats = percentiles(speakingLuminance)
                listeningMedians.append(listeningStats.p50)
                speakingMedians.append(speakingStats.p50)
                darkTails.append(contentsOf: [listeningStats.p05, speakingStats.p05])
                highlightTails.append(contentsOf: [listeningStats.p95, speakingStats.p95])

                let crushed = Swift.max(
                    crushedFraction(listeningDisplay),
                    crushedFraction(speakingDisplay)
                )
                let ceiling = Swift.max(
                    nearCeilingFraction(listeningDisplay),
                    nearCeilingFraction(speakingDisplay)
                )
                let saturation = Swift.max(
                    saturationP95(listeningDisplay),
                    saturationP95(speakingDisplay)
                )
                let roomCast = Swift.max(cast(listeningDisplay), cast(speakingDisplay))
                worstCrushed = Swift.max(worstCrushed, crushed)
                worstCeiling = Swift.max(worstCeiling, ceiling)
                worstSaturation = Swift.max(worstSaturation, saturation)
                worstCast = Swift.max(worstCast, roomCast)

                var seedFailed = false
                for stats in [listeningStats, speakingStats] {
                    if stats.p50 < 0.18 || stats.p50 > 0.55 {
                        failureCounts["median", default: 0] += 1
                        seedFailed = true
                    }
                    if stats.p95 < 0.60 || stats.p95 > 0.92 {
                        failureCounts["highlight", default: 0] += 1
                        seedFailed = true
                    }
                    if stats.p95 - stats.p05 < 0.30 {
                        failureCounts["flat", default: 0] += 1
                        seedFailed = true
                    }
                    for ground in [0.075, 0.45, 0.95] {
                        let separation = Swift.max(
                            contrastRatio(stats.p05, ground),
                            contrastRatio(stats.p95, ground)
                        )
                        worstGround = Swift.min(worstGround, separation)
                        if separation < 1.5 {
                            failureCounts["ground", default: 0] += 1
                            seedFailed = true
                        }
                    }
                }
                // Chrome needs real black-card structure. Reject only when it takes over
                // more than a quarter of the body; the earlier 10% bound mislabeled the
                // material cue itself as a failure.
                if crushed > 0.25 {
                    failureCounts["crushed", default: 0] += 1
                    seedFailed = true
                }
                if ceiling > 0.02 {
                    failureCounts["ceiling", default: 0] += 1
                    seedFailed = true
                }
                if saturation > 0.12 {
                    failureCounts["saturation", default: 0] += 1
                    seedFailed = true
                }
                if roomCast > 0.06 {
                    failureCounts["cast", default: 0] += 1
                    seedFailed = true
                }
                if seedFailed { failed += 1 }
            }
            return DistributionSummary(
                seeds: distributionSeeds,
                listeningMedianRange: range(listeningMedians),
                speakingMedianRange: range(speakingMedians),
                darkTailRange: range(darkTails),
                highlightTailRange: range(highlightTails),
                worstCrushedFraction: worstCrushed,
                worstNearCeilingFraction: worstCeiling,
                worstSaturationP95: worstSaturation,
                worstCast: worstCast,
                failedSeeds: failed,
                failureCounts: failureCounts,
                worstGroundSeparation: worstGround
            )
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
                let response = calibration.displayResponse(for: room, bodySeed: seed)
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
            let drive = drive(speaking: true)
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: drive)
            simulation.advance(steps: 600, drive: drive)
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed
            )
            let rasterizer = MercuryRasterizer()
            var centroids: [Double] = []
            var medians: [Double] = []
            for _ in 0..<400 {  // 30 seconds at 75 ms per sample.
                simulation.advance(steps: 9, drive: drive)
                let field = MercuryField(
                    geometry: simulation.geometry,
                    lateralOffset: drive.pose.lateralOffset
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

        private static func performanceScreen(
            field: MercuryField,
            calibrationMilliseconds: Double
        ) -> PerformanceSummary {
            let seed = MercuryMetrics.defaultSeed
            let coldStarted = ContinuousClock().now
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed
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

            var durations: [Double] = []
            durations.reserveCapacity(240)
            for _ in 0..<240 {
                let frameStarted = ContinuousClock().now
                _ = rasterizer.image(
                    field: field,
                    environment: room,
                    response: response,
                    appearance: .standard,
                    scale: scale
                )
                durations.append(
                    frameStarted.duration(to: ContinuousClock().now).milliseconds
                )
            }
            durations.sort()

            let representedSeconds = 10.0
            let cpuStarted = processCPUSeconds()
            var sink = 0
            for _ in 0..<300 {
                sink &+=
                    rasterizer.image(
                        field: field,
                        environment: room,
                        response: response,
                        appearance: .standard,
                        scale: scale
                    )?.width ?? 0
            }
            let coreFraction =
                (processCPUSeconds() - cpuStarted) / representedSeconds
            _ = sink
            return PerformanceSummary(
                launchCalibrationMilliseconds: calibrationMilliseconds,
                coldFirstFrameMilliseconds: cold,
                rasterP50Milliseconds: durations[durations.count / 2],
                rasterP95Milliseconds: durations[durations.count * 95 / 100],
                rasterP99Milliseconds: durations[durations.count * 99 / 100],
                rasterCoreFractionAt30Hz: coreFraction
            )
        }

        private static func processCPUSeconds() -> Double {
            var value = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
            return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
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

        private static func field(
            speaking: Bool,
            seed: UInt64,
            gains: MercuryGains
        ) -> MercuryField {
            let drive = drive(speaking: speaking)
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: drive)
            simulation.advance(steps: 600, drive: drive)
            return MercuryField(
                geometry: simulation.geometry,
                lateralOffset: drive.pose.lateralOffset
            )
        }

        private static func drive(speaking: Bool) -> MercurySimulation.Drive {
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
