import CoreGraphics
import Foundation

/// Writes the replay dump `mercury-replay` reads (little-endian throughout):
///
/// `rows.bin`: `"MRB6ROWS"`, u32 version 1, u32 width, u32 height, u32 bytesPerRow,
/// f64 scale, u32 stations, u32 lightingCount, u32 rowCount; per lighting u64 seed and
/// f64 exponent, halfSaturation, ceiling, sceneMedian, sceneHighlight; per row u32 kind,
/// u32 index, u32 lighting, u32 increasedContrast, f64 length, f64 lateralOffset,
/// f64 box minX/maxX/minY/maxY, u32 hasImage, u32 0, f32 top[stations],
/// f32 bottom[stations], u8 raster[height * bytesPerRow] (production Swift RGBA8).
///
/// `tables.bin`: `"MRB6TABL"`, u32 version 1, u32 levels, u32 storage, u32 lightingCount;
/// per lighting u64 seed and the room's f32 RGB lanes, levels × storage² texels.
///
/// `manifest.json`: the human-readable index with per-row SHA-256.
@MainActor
enum Dump {
    static let levels = 3
    static let storage = 98

    static func run(_ options: Options) throws {
        let directory = options.output ?? options.benchDirectory
        let corpus = Corpus.build(seedCount: options.seeds, motionFrames: options.motionFrames)
        let reference = SwiftArm(name: "reference", corpus: corpus, environments: corpus.environments)
        guard let stations = corpus.rows.first?.geometry.top.count else {
            throw HarnessError.message("empty corpus")
        }

        var rows = BinaryWriter()
        rows.bytes(Array("MRB6ROWS".utf8))
        rows.u32(1)
        rows.u32(UInt32(Raster.width))
        rows.u32(UInt32(Raster.height))
        rows.u32(UInt32(Raster.bytesPerRow))
        rows.f64(Double(MercuryMetrics.rasterScale))
        rows.u32(UInt32(stations))
        rows.u32(UInt32(corpus.lightings.count))
        rows.u32(UInt32(corpus.rows.count))
        for lighting in corpus.lightings {
            rows.u64(lighting.seed)
            rows.f64(lighting.response.exponent)
            rows.f64(lighting.response.halfSaturation)
            rows.f64(lighting.response.ceiling)
            rows.f64(lighting.response.sceneMedian)
            rows.f64(lighting.response.sceneHighlight)
        }
        var manifestRows: [[String: Any]] = []
        for row in corpus.rows {
            guard row.geometry.top.count == stations, row.geometry.bottom.count == stations else {
                throw HarnessError.message("\(row.id) has \(row.geometry.top.count) stations, expected \(stations)")
            }
            let bytes = try Raster.bytes(of: reference.render(row))
            let bounding = MercuryField(geometry: row.geometry, lateralOffset: row.lateralOffset).boundingBox
            rows.u32(row.kind.rawValue)
            rows.u32(UInt32(row.index))
            rows.u32(UInt32(row.lighting))
            rows.u32(row.appearance.increasedContrast ? 1 : 0)
            rows.f64(Double(row.geometry.length))
            rows.f64(Double(row.lateralOffset))
            rows.f64(Double(bounding.minX))
            rows.f64(Double(bounding.maxX))
            rows.f64(Double(bounding.minY))
            rows.f64(Double(bounding.maxY))
            rows.u32(bytes == nil ? 0 : 1)
            rows.u32(0)
            rows.f32s(row.geometry.top)
            rows.f32s(row.geometry.bottom)
            rows.bytes(bytes ?? [UInt8](repeating: 0, count: Raster.byteCount))
            manifestRows.append([
                "row_id": row.id,
                "detail": row.detail,
                "kind": row.kind.label,
                "lighting": row.lighting,
                "increased_contrast": row.appearance.increasedContrast,
                "raster_sha256": bytes.map(Digest.sha256) ?? NSNull(),
            ])
        }

        var tables = BinaryWriter()
        tables.bytes(Array("MRB6TABL".utf8))
        tables.u32(1)
        tables.u32(UInt32(levels))
        tables.u32(UInt32(storage))
        tables.u32(UInt32(corpus.lightings.count))
        for (index, lighting) in corpus.lightings.enumerated() {
            tables.u64(lighting.seed)
            tables.f32s(try roomTables(corpus.environments[index]))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rows.data.write(to: directory.appending(path: "rows.bin"), options: .atomic)
        try tables.data.write(to: directory.appending(path: "tables.bin"), options: .atomic)
        try JSON.write(
            [
                "bet": "B6",
                "created_at": JSON.isoNow(),
                "git_sha": Host.gitSHA(repository: options.repoRoot),
                "width": Raster.width,
                "height": Raster.height,
                "scale": Double(MercuryMetrics.rasterScale),
                "stations": stations,
                "motion_substeps": [
                    Corpus.motionWarmupFrames + 1, Corpus.motionWarmupFrames + options.motionFrames,
                ],
                "lightings": corpus.lightings.map { lighting in
                    [
                        "seed": String(format: "0x%016llx", lighting.seed),
                        "exponent": lighting.response.exponent,
                        "half_saturation": lighting.response.halfSaturation,
                        "ceiling": lighting.response.ceiling,
                        "scene_median": lighting.response.sceneMedian,
                        "scene_highlight": lighting.response.sceneHighlight,
                    ] as [String: Any]
                },
                "production_sources": ProductionSources.files.map { [$0.repository, $0.sha256] },
                "rows": manifestRows,
            ],
            to: directory.appending(path: "manifest.json")
        )
        print(
            "swift-mercury-harness: dumped \(corpus.rows.count) rows and \(corpus.lightings.count) rooms "
                + "to \(directory.path) (calibration \(String(format: "%.1f", corpus.calibrationMilliseconds)) ms)"
        )
    }

    /// The room's three bordered levels, RGB lanes, read through reflection so the
    /// production copy stays verbatim (`tables` is a private stored property).
    static func roomTables(_ environment: MercuryEnvironment) throws -> [Float] {
        var pointer: UnsafeMutablePointer<SIMD3<Float>>?
        var capacity: Int?
        for child in Mirror(reflecting: environment).children {
            switch child.label {
            case "tables": pointer = child.value as? UnsafeMutablePointer<SIMD3<Float>>
            case "capacity": capacity = child.value as? Int
            default: break
            }
        }
        guard let pointer, let capacity, capacity == levels * storage * storage else {
            throw HarnessError.message("MercuryEnvironment no longer stores `tables`/`capacity` as expected")
        }
        var result = [Float]()
        result.reserveCapacity(capacity * 3)
        for index in 0..<capacity {
            let texel = pointer[index]
            result.append(texel.x)
            result.append(texel.y)
            result.append(texel.z)
        }
        return result
    }
}
