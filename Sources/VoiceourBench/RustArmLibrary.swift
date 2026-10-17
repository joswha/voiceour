import Darwin
import Foundation

/// A Rust candidate cdylib behind one of the proof program's three C ABIs, loaded with `dlopen`.
///
/// Every library exports `<prefix>_abi_version` (which must return 1), `<prefix>_arms` (a static
/// comma-separated arm list), `<prefix>_engine_new`, the ABI's one work call, and
/// `<prefix>_engine_free`. Calls never unwind: a failing call returns -1 and fills the caller's
/// error buffer. Engine handles are single-threaded, and the harness drives them from one thread.
/// The image is never unloaded, because a Rust runtime's thread-local destructors can still point
/// into it at process exit.
final class RustArmLibrary {
    enum ABI: String {
        case tail = "vt"
        case mel = "vm"
        case encoder = "ve"
    }

    static let abiVersion: Int32 = 1

    let url: URL
    let abi: ABI
    let sha256: String
    /// The arms `<prefix>_arms` advertises, in its order.
    let arms: [String]
    private let handle: UnsafeMutableRawPointer

    init(url: URL, abi: ABI) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchError.io("rust library missing: \(url.path)")
        }
        self.url = url
        self.abi = abi
        self.sha256 = try BenchRunner.sha256(of: url)
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw BenchError.io("dlopen \(url.path): \(Self.lastLoaderError())")
        }
        self.handle = handle

        typealias VersionCall = @convention(c) () -> Int32
        typealias ArmsCall = @convention(c) () -> UnsafePointer<CChar>?
        let name = url.lastPathComponent
        let version = try Self.symbol(handle, "\(abi.rawValue)_abi_version", in: url, as: VersionCall.self)()
        guard version == Self.abiVersion else {
            throw BenchError.io("\(name): \(abi.rawValue)_abi_version is \(version), expected \(Self.abiVersion)")
        }
        guard let list = try Self.symbol(handle, "\(abi.rawValue)_arms", in: url, as: ArmsCall.self)() else {
            throw BenchError.io("\(name): \(abi.rawValue)_arms returned NULL")
        }
        let listed = String(cString: list)
        let arms = listed.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !arms.contains(where: \.isEmpty), Set(arms).count == arms.count else {
            throw BenchError.io("\(name): \(abi.rawValue)_arms must list distinct non-empty names, got '\(listed)'")
        }
        self.arms = arms
    }

    /// `<prefix>_<suffix>` from this library, as the C function type `type`.
    func function<Call>(_ suffix: String, as type: Call.Type) throws -> Call {
        try Self.symbol(handle, "\(abi.rawValue)_\(suffix)", in: url, as: type)
    }

    /// The requested arms in request order, refusing any the library does not advertise; every
    /// advertised arm when `requested` is nil.
    func select(_ requested: [String]?) throws -> [String] {
        guard let requested else { return arms }
        for arm in requested where !arms.contains(arm) {
            throw BenchError.usage(
                "\(url.lastPathComponent) has no arm '\(arm)'; it advertises: \(arms.joined(separator: ", "))"
            )
        }
        return requested
    }

    private static func symbol<Call>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        in url: URL,
        as type: Call.Type
    ) throws -> Call {
        guard let address = dlsym(handle, name) else {
            throw BenchError.io("\(url.lastPathComponent) does not export \(name): \(lastLoaderError())")
        }
        return unsafeBitCast(address, to: type)
    }

    private static func lastLoaderError() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown dyld error"
    }
}

/// The caller-owned `char *err, size_t err_len` buffer every ABI call fills on failure.
final class RustArmErrorBuffer {
    static let capacity = 2_048

    let pointer: UnsafeMutablePointer<CChar>

    init() {
        pointer = .allocate(capacity: Self.capacity)
        pointer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        pointer.deallocate()
    }

    func clear() {
        pointer[0] = 0
    }

    /// The message a failed call left, terminated here even if the callee did not.
    func message(fallback: String) -> String {
        pointer[Self.capacity - 1] = 0
        let text = String(cString: pointer)
        return text.isEmpty ? fallback : text
    }
}

/// Opens one arm's engine through `<prefix>_engine_new(model_path, arm, err, err_len)`.
private func openRustEngine(
    _ library: RustArmLibrary,
    arm: String,
    modelPath: String,
    error: RustArmErrorBuffer
) throws -> OpaquePointer {
    typealias NewCall =
        @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
        ) -> OpaquePointer?
    let create = try library.function("engine_new", as: NewCall.self)
    error.clear()
    guard let engine = create(modelPath, arm, error.pointer, RustArmErrorBuffer.capacity) else {
        let detail = error.message(fallback: "returned NULL without a message")
        throw BenchError.io(
            "\(library.url.lastPathComponent) arm \(arm): \(library.abi.rawValue)_engine_new: \(detail)"
        )
    }
    return engine
}

/// The `vt_token` layout: four `int32_t` then two `float`, 24 bytes, 4-byte aligned.
struct RustTailToken: Equatable {
    static let stride = 24

    var id: Int32
    var frameIndex: Int32
    var durationIndex: Int32
    var duration: Int32
    var p: Float
    var plog: Float
}

/// One `vt_` engine: a Rust TDT tail arm.
final class RustTailEngine {
    private typealias DecodeCall =
        @convention(c) (
            OpaquePointer?, UnsafePointer<Float>?, Int32, Int32, UnsafeMutableRawPointer?, Int32,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32
    private typealias FreeCall = @convention(c) (OpaquePointer?) -> Void

    let arm: String
    let error: RustArmErrorBuffer
    private let engine: OpaquePointer
    private let decodeCall: DecodeCall
    private let freeCall: FreeCall

    init(library: RustArmLibrary, arm: String, modelPath: String) throws {
        precondition(library.abi == .tail)
        let error = RustArmErrorBuffer()
        self.error = error
        self.arm = arm
        decodeCall = try library.function("decode", as: DecodeCall.self)
        freeCall = try library.function("engine_free", as: FreeCall.self)
        engine = try openRustEngine(library, arm: arm, modelPath: modelPath, error: error)
    }

    deinit {
        freeCall(engine)
    }

    /// One `vt_decode` call writing at most `maxTokens` tokens to `tokens`; the token count, or -1
    /// with `error` filled. Nothing else runs here, so a caller can time exactly the call.
    func decode(
        states: UnsafePointer<Float>,
        frameCount: Int32,
        stateWidth: Int32,
        tokens: UnsafeMutableRawPointer,
        maxTokens: Int32
    ) -> Int32 {
        decodeCall(
            engine, states, frameCount, stateWidth, tokens, maxTokens, error.pointer, RustArmErrorBuffer.capacity
        )
    }

    static func tokens(in buffer: UnsafeRawPointer, count: Int) -> [RustTailToken] {
        (0..<count).map { index in
            let base = index * RustTailToken.stride
            return RustTailToken(
                id: buffer.loadUnaligned(fromByteOffset: base, as: Int32.self),
                frameIndex: buffer.loadUnaligned(fromByteOffset: base + 4, as: Int32.self),
                durationIndex: buffer.loadUnaligned(fromByteOffset: base + 8, as: Int32.self),
                duration: buffer.loadUnaligned(fromByteOffset: base + 12, as: Int32.self),
                p: buffer.loadUnaligned(fromByteOffset: base + 16, as: Float.self),
                plog: buffer.loadUnaligned(fromByteOffset: base + 20, as: Float.self)
            )
        }
    }
}

/// One `vm_` engine: a Rust mel front-end arm.
final class RustMelEngine {
    private typealias ComputeCall =
        @convention(c) (
            OpaquePointer?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<Float>?, Int32, Int32,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32
    private typealias FreeCall = @convention(c) (OpaquePointer?) -> Void

    let arm: String
    let error: RustArmErrorBuffer
    private let engine: OpaquePointer
    private let computeCall: ComputeCall
    private let freeCall: FreeCall

    init(library: RustArmLibrary, arm: String, modelPath: String) throws {
        precondition(library.abi == .mel)
        let error = RustArmErrorBuffer()
        self.error = error
        self.arm = arm
        computeCall = try library.function("compute", as: ComputeCall.self)
        freeCall = try library.function("engine_free", as: FreeCall.self)
        engine = try openRustEngine(library, arm: arm, modelPath: modelPath, error: error)
    }

    deinit {
        freeCall(engine)
    }

    /// One `vm_compute` call writing at most `maxFrames` frame-major `[frames][melBins]` frames to
    /// `output`; the frame count, or -1 with `error` filled.
    func compute(
        samples: UnsafePointer<Float>,
        sampleCount: Int32,
        output: UnsafeMutablePointer<Float>,
        maxFrames: Int32,
        melBins: Int32
    ) -> Int32 {
        computeCall(
            engine, samples, sampleCount, output, maxFrames, melBins, error.pointer, RustArmErrorBuffer.capacity
        )
    }
}

/// One `ve_` engine: a Rust encoder arm.
final class RustEncoderEngine {
    private typealias EncodeCall =
        @convention(c) (
            OpaquePointer?, UnsafePointer<Float>?, Int32, Int32, UnsafeMutablePointer<Float>?, Int32, Int32,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32
    private typealias FreeCall = @convention(c) (OpaquePointer?) -> Void

    let arm: String
    let error: RustArmErrorBuffer
    private let engine: OpaquePointer
    private let encodeCall: EncodeCall
    private let freeCall: FreeCall

    init(library: RustArmLibrary, arm: String, modelPath: String) throws {
        precondition(library.abi == .encoder)
        let error = RustArmErrorBuffer()
        self.error = error
        self.arm = arm
        encodeCall = try library.function("encode", as: EncodeCall.self)
        freeCall = try library.function("engine_free", as: FreeCall.self)
        engine = try openRustEngine(library, arm: arm, modelPath: modelPath, error: error)
    }

    deinit {
        freeCall(engine)
    }

    /// One `ve_encode` call over a frame-major `[melFrames][melBins]` mel, writing at most
    /// `maxFrames` frame-major `[frames][stateWidth]` encoder frames to `output`; the encoder frame
    /// count, or -1 with `error` filled.
    func encode(
        mel: UnsafePointer<Float>,
        melFrames: Int32,
        melBins: Int32,
        output: UnsafeMutablePointer<Float>,
        maxFrames: Int32,
        stateWidth: Int32
    ) -> Int32 {
        encodeCall(
            engine, mel, melFrames, melBins, output, maxFrames, stateWidth, error.pointer, RustArmErrorBuffer.capacity
        )
    }
}
