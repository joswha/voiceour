import CoreGraphics
import Darwin
import Foundation

/// Contract timing rows for bet B6.
///
/// Every row of every pass runs every arm once, in a Williams order that rotates per row
/// so each arm precedes each other arm equally often. One timed unit is one production
/// raster call (field construction, pixel fill, `makeImage()`) bracketed by
/// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. The output is copied out and compared with
/// the production Swift bytes after the clock stops. Pass 0 is warmup.
@MainActor
enum Timing {
    static func run(_ options: Options) throws {
        let corpus = Corpus.build(seedCount: options.seeds, motionFrames: options.motionFrames)
        // Without --arms every arm runs, so the library is required; a missing dylib must
        // fail the run rather than silently time Swift alone.
        let library: RustLibrary? =
            options.arms.map { $0.allSatisfy(SwiftSideArms.contains) } == true
            ? nil : try RustLibrary(path: options.library)
        let available = ["swift", "swift@aa", "swift-simd", "swift-simd-unchecked"] + (library?.arms ?? [])
        let names = options.arms ?? available
        var arms: [RasterArm] = []
        for name in names {
            if let arm = SwiftSideArms.make(name: name, corpus: corpus) {
                arms.append(arm)
            } else if let library, library.arms.contains(name) {
                arms.append(try RustArm(name: name, library: library, corpus: corpus))
            } else {
                throw HarnessError.message("arm \(name) is not available (have \(available.joined(separator: ",")))")
            }
        }
        guard !arms.isEmpty else { throw HarnessError.message("no arms") }

        let rows = corpus.rows.filter { options.rowKinds.contains($0.kind) }
        let reference = SwiftArm(name: "reference", corpus: corpus, environments: corpus.environments)
        let references = try rows.map { try Raster.bytes(of: reference.render($0)) }
        let work = rows.map(Self.work)

        let output =
            options.output
            ?? options.benchDirectory.appending(path: "timing-\(Int(Date().timeIntervalSince1970)).jsonl")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        var buffer = Data()
        func emit(_ object: [String: Any]) throws {
            buffer.append(contentsOf: Array(try JSON.line(object).utf8))
            buffer.append(0x0A)
            if buffer.count > 1 << 20 {
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        let sequences = williams(arms.count)
        let kinds = Set(rows.map(\.kind.label)).sorted()
        try emit([
            "type": "run_meta",
            "bet": "B6",
            "harness": "swift-mercury-harness",
            "git_sha": Host.gitSHA(repository: options.repoRoot),
            "started_at": JSON.isoNow(),
            "host": Host.description(),
            "arms": arms.map(\.name),
            "passes": options.passes,
            "order": [
                "design": "williams",
                "sequences": sequences.map { $0.map { arms[$0].name } },
                "rule": "row r of pass p uses sequence (r + p) mod count",
            ] as [String: Any],
            "corpus": "mercury: \(kinds.joined(separator: "+")); \(rows.count) rows "
                + "(64 benchmark seeds on the speaking body; engine motion substeps "
                + "\(Corpus.motionWarmupFrames + 1)-\(Corpus.motionWarmupFrames + options.motionFrames), default seed)",
            "notes": "elapsed_us = one production raster call: MercuryField init + pixel fill + "
                + "CGBitmapContext makeImage, 360x68 RGBA8 @2x. swift = verbatim production "
                + "MercuryRasterizer (swift build -c release); swift-simd = raster_neon.rs's redesign "
                + "in Swift SIMD types (Sources/MercurySimd/SwiftNeonRaster.swift with the production "
                + "copies, release -O); swift-simd-unchecked = the same sources compiled -Ounchecked; "
                + "rust* = libmercury_raster mr_render into an identical CGContext, then makeImage. "
                + "Every arm owns its rooms, lookups and contexts. "
                + "equal_ref compares the RGBA bytes with the production Swift raster of the same row.",
            "library": library.map { library in
                [
                    "path": library.path.path,
                    "sha256": (try? Digest.sha256(file: library.path)) ?? "unknown",
                    "arms": library.arms,
                ] as [String: Any]
            } ?? NSNull(),
            "production_sources": ProductionSources.files.map { [$0.repository, $0.sha256] },
            "calibration_ms": corpus.calibrationMilliseconds,
        ])

        var samples: [String: [String: [Double]]] = [:]
        var mismatches: [String: Int] = [:]
        var sequence = 0
        let runStarted = DispatchTime.now().uptimeNanoseconds
        for pass in 0...options.passes {
            for (rowIndex, row) in rows.enumerated() {
                for armIndex in sequences[(rowIndex + pass) % sequences.count] {
                    let arm = arms[armIndex]
                    let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let image = arm.render(row)
                    let ended = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let bytes = try Raster.bytes(of: image)
                    let elapsed = Double(ended - started) / 1_000

                    var comparison = Raster.Comparison()
                    switch (bytes, references[rowIndex]) {
                    case (nil, nil): break
                    case (let actual?, let expected?): comparison = Raster.compare(actual, expected)
                    default: comparison = Raster.Comparison(differingBytes: Raster.byteCount, maxAbs: 255, relativeL2: .infinity)
                    }
                    if !comparison.identical { mismatches[arm.name, default: 0] += 1 }
                    var rowWork = work[rowIndex]
                    rowWork["differing_bytes"] = comparison.differingBytes
                    try emit([
                        "type": "timing",
                        "bet": "B6",
                        "arm": arm.name,
                        "row_id": row.id,
                        "pass": pass,
                        "seq": sequence,
                        "elapsed_us": elapsed,
                        "output_sha256": bytes.map(Digest.sha256) ?? "",
                        "equal_ref": comparison.identical,
                        "audio_s": NSNull(),
                        "work": rowWork,
                        "err": [
                            "max_abs": Double(comparison.maxAbs),
                            "rel_l2": comparison.relativeL2.isFinite ? comparison.relativeL2 : -1,
                        ],
                    ])
                    sequence += 1
                    if pass > 0 { samples[arm.name, default: [:]][row.kind.label, default: []].append(elapsed) }
                }
            }
        }
        try file.write(contentsOf: buffer)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - runStarted) / 1e9

        print("time: \(sequence) rows in \(String(format: "%.1f", seconds)) s -> \(output.path)")
        for arm in arms {
            let byKind = (samples[arm.name] ?? [:]).keys.sorted().map { kind -> String in
                let values = samples[arm.name]![kind]!.sorted()
                let median = values[values.count / 2]
                let p99 = values[min(values.count - 1, values.count * 99 / 100)]
                return "\(kind) p50 \(String(format: "%.1f", median)) µs p99 \(String(format: "%.1f", p99)) µs"
            }
            print(
                "time \(arm.name): \(byKind.joined(separator: "; ")); "
                    + "non-identical outputs \(mismatches[arm.name] ?? 0)"
            )
        }
    }

    /// Size of the shaded work for a row, from the production field and rasterizer bounds.
    static func work(_ row: Corpus.Row) -> [String: Any] {
        let scale = Double(MercuryMetrics.rasterScale)
        let bounds = MercuryField.islandBounds
        let bounding = MercuryField(geometry: row.geometry, lateralOffset: row.lateralOffset).boundingBox
        let firstColumn = max(0, Int(((bounding.minX - bounds.minX) * scale).rounded(.down)))
        let lastColumn = min(Raster.width - 1, Int(((bounding.maxX - bounds.minX) * scale).rounded(.up)))
        let firstRow = max(0, Int(((bounds.maxY - bounding.maxY) * scale).rounded(.down)))
        let lastRow = min(Raster.height - 1, Int(((bounds.maxY - bounding.minY) * scale).rounded(.up)))
        return [
            "kind": row.kind.label,
            "box_pixels": max(0, lastColumn - firstColumn + 1) * max(0, lastRow - firstRow + 1),
        ]
    }

    /// Williams design: every arm in every position once per cycle and, for an even arm
    /// count, every ordered pair adjacent exactly once (odd counts add the reversals).
    static func williams(_ count: Int) -> [[Int]] {
        guard count > 1 else { return [[0]] }
        var first = [0]
        var low = 1
        var high = count - 1
        var takeLow = true
        while first.count < count {
            if takeLow {
                first.append(low)
                low += 1
            } else {
                first.append(high)
                high -= 1
            }
            takeLow.toggle()
        }
        var sequences = (0..<count).map { shift in first.map { ($0 + shift) % count } }
        if count % 2 == 1 { sequences += sequences.map { $0.reversed() } }
        return sequences
    }
}
