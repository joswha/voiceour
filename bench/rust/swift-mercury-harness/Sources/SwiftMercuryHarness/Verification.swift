import CoreGraphics
import Foundation

/// Equivalence of every Rust arm and every `swift-simd` build against the production Swift
/// path, in one process: full rasters for every corpus row, then (for the Rust library) the
/// components a raster is built from — room tables, room lookups, conductor Fresnel, sRGB
/// transfer, byte encoding, display lookup and the field's bounding box — compared bit for bit.
@MainActor
enum Verification {
    static func run(_ options: Options) throws -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        let corpus = Corpus.build(seedCount: options.seeds, motionFrames: options.motionFrames)
        let library: RustLibrary? =
            options.arms.map { $0.allSatisfy { SwiftSideArms.contains($0) } } == true
            ? nil : try RustLibrary(path: options.library)
        let reference = SwiftArm(name: "reference", corpus: corpus, environments: corpus.environments)
        let references = try corpus.rows.map { try Raster.bytes(of: reference.render($0)) }
        let names = options.arms ?? ["swift-simd", "swift-simd-unchecked"] + (library?.arms ?? [])
        var arms: [RasterArm] = []
        var rustArms: [RustArm] = []
        for name in names {
            if let arm = SwiftSideArms.make(name: name, corpus: corpus) {
                arms.append(arm)
            } else if let library, library.arms.contains(name) {
                let arm = try RustArm(name: name, library: library, corpus: corpus)
                arms.append(arm)
                rustArms.append(arm)
            } else {
                throw HarnessError.message("arm \(name) is not available")
            }
        }

        var identical = true
        var armReports: [String: Any] = [:]
        for arm in arms {
            var kinds: [String: [String: Int]] = [:]
            var mismatches: [[String: Any]] = []
            var maxAbs = 0
            var differingBytes = 0
            for (index, row) in corpus.rows.enumerated() {
                let bytes = try Raster.bytes(of: arm.render(row))
                var counts = kinds[row.kind.label] ?? ["rows": 0, "identical": 0]
                counts["rows", default: 0] += 1
                switch (bytes, references[index]) {
                case (nil, nil):
                    counts["identical", default: 0] += 1
                case (let actual?, let expected?):
                    let comparison = Raster.compare(actual, expected)
                    if comparison.identical {
                        counts["identical", default: 0] += 1
                    } else {
                        maxAbs = max(maxAbs, comparison.maxAbs)
                        differingBytes += comparison.differingBytes
                        mismatches.append([
                            "row_id": row.id,
                            "detail": row.detail,
                            "differing_bytes": comparison.differingBytes,
                            "max_abs": comparison.maxAbs,
                            "rel_l2": comparison.relativeL2,
                        ])
                    }
                default:
                    mismatches.append(["row_id": row.id, "detail": row.detail, "image_presence": bytes != nil])
                }
                kinds[row.kind.label] = counts
            }
            identical = identical && mismatches.isEmpty
            armReports[arm.name] = [
                "rows": corpus.rows.count,
                "identical_rows": corpus.rows.count - mismatches.count,
                "by_kind": kinds,
                "max_abs": maxAbs,
                "differing_bytes": differingBytes,
                "mismatches": mismatches,
            ] as [String: Any]
            let summary = kinds.keys.sorted().map { key in
                "\(key) \(kinds[key]!["identical"]!)/\(kinds[key]!["rows"]!)"
            }.joined(separator: ", ")
            print(
                "verify \(arm.name): \(corpus.rows.count - mismatches.count)/\(corpus.rows.count) rows "
                    + "byte-identical (\(summary)); differing bytes \(differingBytes), max |Δ| \(maxAbs)"
            )
        }

        var components: [String: Any] = [:]
        if let library, let first = rustArms.first {
            components = try Self.components(
                corpus: corpus,
                reference: reference,
                library: library,
                arms: rustArms,
                probe: first
            )
            for key in components.keys.sorted() {
                guard let report = components[key] as? [String: Any] else { continue }
                let samples = report["samples"] as? Int ?? 0
                let equal = report["identical"] as? Int ?? 0
                identical = identical && samples == equal
                print("verify component \(key): \(equal)/\(samples) bit-identical, max |Δ| \(report["max_abs"] ?? 0)")
            }
        }

        let output = options.output ?? options.benchDirectory.appending(path: "equivalence.json")
        try JSON.write(
            [
                "bet": "B6",
                "created_at": JSON.isoNow(),
                "git_sha": Host.gitSHA(repository: options.repoRoot),
                "library": library.map { library in
                    [
                        "path": library.path.path,
                        "sha256": (try? Digest.sha256(file: library.path)) ?? "unknown",
                        "arms": library.arms,
                    ] as [String: Any]
                } ?? NSNull(),
                "rows": corpus.rows.count,
                "lightings": corpus.lightings.count,
                "motion_substeps": [
                    Corpus.motionWarmupFrames + 1, Corpus.motionWarmupFrames + options.motionFrames,
                ],
                "arms": armReports,
                "components": components,
                "identical": identical,
                "seconds": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9,
            ],
            to: output
        )
        print("verify: \(identical ? "IDENTICAL" : "DIFFERENT") — report \(output.path)")
        return identical
    }

    /// Bit-level tally of one component probe.
    struct Tally {
        var samples = 0
        var identical = 0
        var maxAbs = 0.0
        var firstDifference: String?

        mutating func add(_ swift: [Double], _ rust: [Double], _ label: @autoclosure () -> String) {
            samples += 1
            var same = true
            for (left, right) in zip(swift, rust) where left.bitPattern != right.bitPattern {
                same = false
                let difference = abs(left - right)
                maxAbs = max(maxAbs, difference.isNaN ? .infinity : difference)
            }
            if same {
                identical += 1
            } else if firstDifference == nil {
                firstDifference = "\(label()): swift \(swift) rust \(rust)"
            }
        }

        var report: [String: Any] {
            var result: [String: Any] = ["samples": samples, "identical": identical, "max_abs": maxAbs]
            if let firstDifference { result["first_difference"] = firstDifference }
            return result
        }
    }

    static func components(
        corpus: Corpus,
        reference: SwiftArm,
        library: RustLibrary,
        arms: [RustArm],
        probe: RustArm
    ) throws -> [String: Any] {
        var random = ProbeRandom(seed: 0xB6B6_B6B6_0000_0001)

        // Room tables: every texel of every level, for every Rust arm's engines.
        var tables = Tally()
        var rustTables = [Float](repeating: 0, count: Dump.levels * Dump.storage * Dump.storage * 3)
        for (index, _) in corpus.lightings.enumerated() {
            let swift = try Dump.roomTables(reference.environment(index))
            for arm in arms {
                let count = library.tables(arm.engines[index], &rustTables, rustTables.count)
                guard count == rustTables.count else { throw HarnessError.message("mr_engine_tables failed") }
                for texel in 0..<(swift.count / 3) {
                    tables.add(
                        (0..<3).map { Double(swift[texel * 3 + $0]) },
                        (0..<3).map { Double(rustTables[texel * 3 + $0]) },
                        "lighting \(index) texel \(texel)"
                    )
                }
            }
        }

        // Room lookups: random directions plus the axes and folds.
        var radiance = Tally()
        let axes: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1),
            SIMD3(0, 0, -1), SIMD3(0.5, -0.5, -0.70710677), SIMD3(0, 0, 0),
        ]
        for (index, _) in corpus.lightings.enumerated() {
            let environment = reference.environment(index)
            let directions = axes + (0..<8_000).map { _ in random.unitVector() }
            for direction in directions {
                let swift = environment.radiance(direction)
                var input = [direction.x, direction.y, direction.z]
                var output = [Float](repeating: 0, count: 3)
                _ = library.radiance(probe.engines[index], &input, &output)
                radiance.add(
                    [Double(swift.x), Double(swift.y), Double(swift.z)],
                    output.map(Double.init),
                    "lighting \(index) direction \(direction)"
                )
            }
        }

        // Conductor Fresnel: every table node, then random cosines including the clamps.
        var fresnel = Tally()
        let nodes = (0..<1_024).map { 1e-4 + (1 - 1e-4) * Double($0) / 1_023 }
        for cosine in nodes + (0..<100_000).map({ _ in random.uniform(-0.05, 1.05) }) {
            let swift = MercuryOptics.fresnel(cosine: cosine)
            var rust = [Double](repeating: 0, count: 3)
            library.probeFresnel(cosine, &rust)
            fresnel.add([swift.x, swift.y, swift.z], rust, "cosine \(cosine)")
        }

        // sRGB transfer and byte encoding.
        var transfer = Tally()
        let transferNodes = (0..<4_096).map { Double($0) / 4_095 }
        for value in transferNodes + (0..<100_000).map({ _ in random.uniform(-0.05, 1.05) }) {
            transfer.add([MercuryOptics.encodeSRGB(value)], [library.probeEncodeSRGB(value)], "value \(value)")
        }
        var encoded = Tally()
        for sample in 0..<200_000 {
            let value = random.uniform(-0.05, 1.05)
            let coverage = sample.isMultiple(of: 2) ? 1 : random.uniform(0, 1)
            encoded.add(
                [Double(MercuryOptics.encodedByte(value, coverage: coverage))],
                [Double(library.probeEncodedByte(value, coverage))],
                "value \(value) coverage \(coverage)"
            )
        }

        // Display lookup, both appearances, scenes across the whole luminance domain.
        var display = Tally()
        for (index, lighting) in corpus.lightings.enumerated() {
            for increased in [false, true] {
                let response =
                    increased
                    ? lighting.response.remapped(
                        medianTarget: MercuryMetrics.increasedContrastMedian,
                        highlightTarget: MercuryMetrics.increasedContrastHighlight
                    ) ?? lighting.response
                    : lighting.response
                let lookup = MercuryDisplayLookup(response: response)
                var scenes: [SIMD3<Double>] = [.zero, SIMD3(-1, 0.5, 0.2), SIMD3(.infinity, 1, 1)]
                for _ in 0..<2_000 {
                    let scale = exp(random.uniform(log(1e-6), log(1e4)))
                    scenes.append(
                        SIMD3(random.uniform(0, 2), random.uniform(0, 2), random.uniform(0, 2)) * scale
                    )
                }
                for scene in scenes {
                    let swift = lookup.map(scene)
                    var input = [scene.x, scene.y, scene.z]
                    var output = [Double](repeating: 0, count: 3)
                    _ = library.display(probe.engines[index], increased ? 1 : 0, &input, &output)
                    display.add([swift.x, swift.y, swift.z], output, "lighting \(index) scene \(scene)")
                }
            }
        }

        // The field's bounding box for every row geometry.
        var boxes = Tally()
        for row in corpus.rows {
            let bounding = MercuryField(geometry: row.geometry, lateralOffset: row.lateralOffset).boundingBox
            var output = [Double](repeating: 0, count: 4)
            _ = row.geometry.top.withUnsafeBufferPointer { top in
                row.geometry.bottom.withUnsafeBufferPointer { bottom in
                    library.probeFieldBox(
                        top.baseAddress,
                        bottom.baseAddress,
                        Int32(top.count),
                        Double(row.geometry.length),
                        Double(row.lateralOffset),
                        &output
                    )
                }
            }
            boxes.add(
                [bounding.minX, bounding.maxX, bounding.minY, bounding.maxY].map(Double.init),
                output,
                row.id
            )
        }

        return [
            "room_tables": tables.report,
            "room_radiance": radiance.report,
            "fresnel": fresnel.report,
            "encode_srgb": transfer.report,
            "encoded_byte": encoded.report,
            "display_lookup": display.report,
            "field_box": boxes.report,
        ]
    }
}
