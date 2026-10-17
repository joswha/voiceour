import CoreGraphics
import Darwin
import Foundation
import MercurySimd
import MercurySimdUnchecked

/// One implementation of "draw this row into a `CGImage`".
///
/// Every arm owns its rooms, display lookups and bitmap contexts, one per lighting, the
/// way one `MercuryEngine` owns them for a session; no arm reads another arm's warm
/// tables. The timed unit is the production raster call: `MercuryEngine.image(...)` minus
/// its hit-region store — field construction, pixel fill and `makeImage()`.
@MainActor
protocol RasterArm: AnyObject {
    var name: String { get }
    func render(_ row: Corpus.Row) -> CGImage?
}

/// The shipped `MercuryRasterizer`, compiled from the verbatim production copies.
@MainActor
final class SwiftArm: RasterArm {
    let name: String
    private let lightings: [Corpus.Lighting]
    private let environments: [MercuryEnvironment]
    private let rasterizers: [MercuryRasterizer]

    /// `environments` defaults to fresh rooms built from each lighting's seed.
    init(name: String, corpus: Corpus, environments: [MercuryEnvironment]? = nil) {
        self.name = name
        lightings = corpus.lightings
        self.environments =
            environments
            ?? corpus.lightings.map { MercuryEnvironment(world: .roomOfTen, seed: $0.seed) }
        rasterizers = corpus.lightings.map { _ in MercuryRasterizer() }
    }

    func render(_ row: Corpus.Row) -> CGImage? {
        let field = MercuryField(geometry: row.geometry, lateralOffset: row.lateralOffset)
        guard field.boundingBox.width > 0, field.boundingBox.height > 0 else { return nil }
        return rasterizers[row.lighting].image(
            field: field,
            environment: environments[row.lighting],
            response: lightings[row.lighting].response,
            appearance: row.appearance,
            scale: MercuryMetrics.rasterScale
        )
    }

    func environment(_ lighting: Int) -> MercuryEnvironment {
        environments[lighting]
    }
}

/// The arms that run in this process without the Rust library, and the implementation an
/// arm name selects: `name@suffix` is an A/A replicate of `name`.
enum SwiftSideArms {
    static let names = ["swift", "swift-simd", "swift-simd-unchecked"]

    static func implementation(of name: String) -> String {
        String(name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    static func contains(_ name: String) -> Bool {
        names.contains(implementation(of: name))
    }

    /// Builds the arm `name` selects, or nil when it is not a Swift-side arm.
    @MainActor
    static func make(name: String, corpus: Corpus) -> RasterArm? {
        switch implementation(of: name) {
        case "swift": SwiftArm(name: name, corpus: corpus)
        case "swift-simd": SwiftSimdArm<MercurySimd.SimdRasterEngine>(name: name, corpus: corpus)
        case "swift-simd-unchecked":
            SwiftSimdArm<MercurySimdUnchecked.SimdRasterEngine>(name: name, corpus: corpus)
        default: nil
        }
    }
}

/// What `SwiftSimdArm` needs from either build of Sources/MercurySimd/SwiftNeonRaster.swift.
@MainActor
protocol SimdRasterEngineProtocol: AnyObject {
    init(
        seed: UInt64,
        exponent: Double,
        halfSaturation: Double,
        ceiling: Double,
        sceneMedian: Double,
        sceneHighlight: Double
    )
    func image(
        top: [Float],
        bottom: [Float],
        length: CGFloat,
        halfHeight: CGFloat,
        lateralOffset: CGFloat,
        increasedContrast: Bool,
        scale: CGFloat
    ) -> CGImage?
}

extension MercurySimd.SimdRasterEngine: SimdRasterEngineProtocol {}
extension MercurySimdUnchecked.SimdRasterEngine: SimdRasterEngineProtocol {}

/// `swift-simd` and `swift-simd-unchecked`: raster_neon.rs's redesign in Swift SIMD types,
/// built -O (MercurySimd) and -Ounchecked (MercurySimdUnchecked). One engine per lighting,
/// each owning its room, response lookup, bitmap context and scratch, like `SwiftArm`'s
/// rasterizers. The timed unit matches: field construction, pixel fill and `makeImage()`.
@MainActor
final class SwiftSimdArm<Engine: SimdRasterEngineProtocol>: RasterArm {
    let name: String
    private let engines: [Engine]

    init(name: String, corpus: Corpus) {
        self.name = name
        engines = corpus.lightings.map { lighting in
            let response = lighting.response
            return Engine(
                seed: lighting.seed,
                exponent: response.exponent,
                halfSaturation: response.halfSaturation,
                ceiling: response.ceiling,
                sceneMedian: response.sceneMedian,
                sceneHighlight: response.sceneHighlight
            )
        }
    }

    func render(_ row: Corpus.Row) -> CGImage? {
        engines[row.lighting].image(
            top: row.geometry.top,
            bottom: row.geometry.bottom,
            length: row.geometry.length,
            halfHeight: row.geometry.halfHeight,
            lateralOffset: row.lateralOffset,
            increasedContrast: row.appearance.increasedContrast,
            scale: MercuryMetrics.rasterScale
        )
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

/// `libmercury_raster.dylib` (bench/rust/mercury-raster), bound with `dlopen`.
@MainActor
final class RustLibrary {
    typealias AbiVersion = @convention(c) () -> Int32
    typealias Arms = @convention(c) () -> UnsafePointer<CChar>?
    typealias EngineNew =
        @convention(c) (
            UInt64, UnsafePointer<Double>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
        ) -> OpaquePointer?
    typealias Render =
        @convention(c) (
            OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, Double, Double,
            Int32, Double, UnsafeMutablePointer<UInt8>?, Int32, Int32, Int32,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32
    typealias EngineFree = @convention(c) (OpaquePointer?) -> Void
    typealias Tables = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Float>?, Int) -> Int32
    typealias Radiance =
        @convention(c) (OpaquePointer?, UnsafePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32
    typealias Display =
        @convention(c) (OpaquePointer?, Int32, UnsafePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    typealias ProbeFresnel = @convention(c) (Double, UnsafeMutablePointer<Double>?) -> Void
    typealias ProbeEncode = @convention(c) (Double) -> Double
    typealias ProbeByte = @convention(c) (Double, Double) -> UInt8
    typealias ProbeBox =
        @convention(c) (
            UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, Double, Double,
            UnsafeMutablePointer<Double>?
        ) -> Int32

    let path: URL
    let arms: [String]
    let engineNew: EngineNew
    let render: Render
    let engineFree: EngineFree
    let tables: Tables
    let radiance: Radiance
    let display: Display
    let probeFresnel: ProbeFresnel
    let probeEncodeSRGB: ProbeEncode
    let probeEncodedByte: ProbeByte
    let probeFieldBox: ProbeBox

    init(path: URL) throws {
        guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
            throw HarnessError.message("dlopen \(path.path): \(String(cString: dlerror()))")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw HarnessError.message("\(path.lastPathComponent) does not export \(name)")
            }
            return unsafeBitCast(address, to: T.self)
        }
        let version = try symbol("mr_abi_version", AbiVersion.self)()
        guard version == 1 else {
            throw HarnessError.message("\(path.lastPathComponent) speaks ABI \(version), expected 1")
        }
        guard let names = try symbol("mr_arms", Arms.self)() else {
            throw HarnessError.message("mr_arms returned null")
        }
        self.path = path
        arms = String(cString: names).split(separator: ",").map(String.init)
        engineNew = try symbol("mr_engine_new", EngineNew.self)
        render = try symbol("mr_render", Render.self)
        engineFree = try symbol("mr_engine_free", EngineFree.self)
        tables = try symbol("mr_engine_tables", Tables.self)
        radiance = try symbol("mr_engine_radiance", Radiance.self)
        display = try symbol("mr_engine_display", Display.self)
        probeFresnel = try symbol("mr_probe_fresnel", ProbeFresnel.self)
        probeEncodeSRGB = try symbol("mr_probe_encode_srgb", ProbeEncode.self)
        probeEncodedByte = try symbol("mr_probe_encoded_byte", ProbeByte.self)
        probeFieldBox = try symbol("mr_probe_field_box", ProbeBox.self)
    }

    func makeEngine(arm: String, lighting: Corpus.Lighting) throws -> OpaquePointer {
        let response = lighting.response
        let values = [
            response.exponent, response.halfSaturation, response.ceiling,
            response.sceneMedian, response.sceneHighlight,
        ]
        var error = [UInt8](repeating: 0, count: 512)
        let engine = values.withUnsafeBufferPointer { values in
            error.withUnsafeMutableBufferPointer { error in
                engineNew(
                    lighting.seed,
                    values.baseAddress,
                    arm,
                    UnsafeMutableRawPointer(error.baseAddress)?.assumingMemoryBound(to: CChar.self),
                    error.count
                )
            }
        }
        guard let engine else {
            let message = String(decoding: error.prefix(while: { $0 != 0 }), as: UTF8.self)
            throw HarnessError.message("mr_engine_new(\(arm)): \(message)")
        }
        return engine
    }
}

/// One Rust arm: an engine per lighting, rendering into a harness-owned bitmap context
/// configured exactly like `MercuryRasterizer.context(for:)`, then `makeImage()`.
@MainActor
final class RustArm: RasterArm {
    let name: String
    private let library: RustLibrary
    private(set) var engines: [OpaquePointer] = []
    private let contexts: [CGContext]
    private static let errorCapacity = 512
    private let error = UnsafeMutablePointer<CChar>.allocate(capacity: errorCapacity)

    init(name: String, library: RustLibrary, corpus: Corpus) throws {
        self.name = name
        self.library = library
        contexts = try corpus.lightings.map { _ in try Self.makeContext() }
        error.initialize(repeating: 0, count: Self.errorCapacity)
        for lighting in corpus.lightings {
            engines.append(try library.makeEngine(arm: name, lighting: lighting))
        }
    }

    isolated deinit {
        for engine in engines { library.engineFree(engine) }
        error.deallocate()
    }

    func render(_ row: Corpus.Row) -> CGImage? {
        let context = contexts[row.lighting]
        guard let data = context.data else { return nil }
        let engine = engines[row.lighting]
        let status = row.geometry.top.withUnsafeBufferPointer { top in
            row.geometry.bottom.withUnsafeBufferPointer { bottom in
                library.render(
                    engine,
                    top.baseAddress,
                    bottom.baseAddress,
                    Int32(top.count),
                    Double(row.geometry.length),
                    Double(row.lateralOffset),
                    row.appearance.increasedContrast ? 1 : 0,
                    Double(MercuryMetrics.rasterScale),
                    data.assumingMemoryBound(to: UInt8.self),
                    Int32(context.width),
                    Int32(context.height),
                    Int32(context.bytesPerRow),
                    error,
                    Self.errorCapacity
                )
            }
        }
        if status < 0 {
            fputs("swift-mercury-harness: \(name) \(row.id): \(String(cString: error))\n", stderr)
        }
        guard status == 0 else { return nil }
        return context.makeImage()
    }

    /// `MercuryRasterizer.context(for: MercuryMetrics.rasterScale)`.
    static func makeContext() throws -> CGContext {
        let scale = MercuryMetrics.rasterScale
        let width = Int((RecordingOverlayMetrics.islandSize.width * scale).rounded())
        let height = Int((RecordingOverlayMetrics.islandSize.height * scale).rounded())
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw HarnessError.message("cannot create a \(width)x\(height) bitmap context") }
        return context
    }
}
