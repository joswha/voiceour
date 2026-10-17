import Darwin
import Foundation

/// `libvoiceour_text.dylib` (bench/rust/voiceour-text, C ABI `vtx_`, src/ffi.rs) loaded with
/// `dlopen`, so arm `rust-ffi` runs the Rust port in this process, row by row beside the Swift
/// arms. The image is never unloaded: a Rust runtime's thread-local destructors can outlive it.
final class RustTextLibrary {
    static let abiVersion: Int32 = 1
    static var defaultPath: String {
        Paths.repoRoot + "/bench/rust/voiceour-text/target/release/libvoiceour_text.dylib"
    }

    let path: String
    /// The arms `vtx_arms` advertises.
    let arms: [String]
    private let handle: UnsafeMutableRawPointer

    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw HarnessError.message("dlopen \(path): \(Self.loaderError())")
        }
        self.path = path
        self.handle = handle
        typealias VersionCall = @convention(c) () -> Int32
        typealias ArmsCall = @convention(c) () -> UnsafePointer<CChar>?
        let version = try Self.symbol(handle, "vtx_abi_version", as: VersionCall.self)()
        guard version == Self.abiVersion else {
            throw HarnessError.message("\(path): vtx_abi_version is \(version), expected \(Self.abiVersion)")
        }
        guard let list = try Self.symbol(handle, "vtx_arms", as: ArmsCall.self)() else {
            throw HarnessError.message("\(path): vtx_arms returned NULL")
        }
        arms = String(cString: list).split(separator: ",").map(String.init)
    }

    func function<Call>(_ name: String, as type: Call.Type) throws -> Call {
        try Self.symbol(handle, name, as: type)
    }

    private static func symbol<Call>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: Call.Type) throws
        -> Call
    {
        guard let address = dlsym(handle, name) else {
            throw HarnessError.message("missing symbol \(name): \(loaderError())")
        }
        return unsafeBitCast(address, to: type)
    }

    private static func loaderError() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown dyld error"
    }
}

/// One `vtx_engine`: the glossary decoded, its snapshot compiled and its repair engine built,
/// as in a warm app process.
final class RustTextEngine {
    enum Stage: Int32 {
        case text = 0
        case compile = 1
        case engine = 2
        /// The boundary alone: the input's bytes validated and copied back.
        case echo = 3
    }

    private typealias NewCall =
        @convention(c) (
            UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
        ) -> OpaquePointer?
    private typealias RunCall =
        @convention(c) (
            OpaquePointer?, Int32, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int64
    private typealias LastOutputCall = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int64
    private typealias HandleCall = @convention(c) (OpaquePointer?) -> Void

    private static let errorCapacity = 2_048

    private let engine: OpaquePointer
    private let runCall: RunCall
    private let lastOutputCall: LastOutputCall
    private let releaseCall: HandleCall
    private let freeCall: HandleCall
    private let error: UnsafeMutablePointer<CChar>
    private var output: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    /// Calls whose output outgrew the buffer and was fetched with `vtx_last_output`.
    private(set) var overflows = 0

    init(library: RustTextLibrary, glossaryJSON: Data, ordinaryWordsPath: String, arm: String) throws {
        let create = try library.function("vtx_engine_new", as: NewCall.self)
        runCall = try library.function("vtx_run", as: RunCall.self)
        lastOutputCall = try library.function("vtx_last_output", as: LastOutputCall.self)
        releaseCall = try library.function("vtx_release", as: HandleCall.self)
        freeCall = try library.function("vtx_engine_free", as: HandleCall.self)
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Self.errorCapacity)
        errorBuffer.initialize(repeating: 0, count: Self.errorCapacity)
        let created = glossaryJSON.withUnsafeBytes { bytes in
            create(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, ordinaryWordsPath, arm, errorBuffer,
                Self.errorCapacity)
        }
        guard let created else {
            let message = String(cString: errorBuffer)
            errorBuffer.deallocate()
            throw HarnessError.message("vtx_engine_new(\(arm)): \(message)")
        }
        engine = created
        error = errorBuffer
        capacity = 1 << 20
        output = .allocate(capacity: capacity)
    }

    deinit {
        freeCall(engine)
        error.deallocate()
        output.deallocate()
    }

    /// One `vtx_run`: `input`'s UTF-8 bytes in (no copy for a native string), the output
    /// decoded into a new `String`. Both conversions are part of what arm `rust-ffi` times.
    @inline(never)
    func run(_ stage: Stage, _ input: String) throws -> String {
        var input = input
        let length = input.withUTF8 { bytes in
            runCall(engine, stage.rawValue, bytes.baseAddress, bytes.count, output, capacity, error, Self.errorCapacity)
        }
        guard length >= 0 else {
            throw HarnessError.message("vtx_run: \(String(cString: error))")
        }
        if Int(length) > capacity {
            output.deallocate()
            capacity = Int(length)
            output = .allocate(capacity: capacity)
            guard lastOutputCall(engine, output, capacity) == length else {
                throw HarnessError.message("vtx_last_output disagrees with vtx_run")
            }
            overflows += 1
        }
        return String(decoding: UnsafeBufferPointer(start: output, count: Int(length)), as: UTF8.self)
    }

    /// Drops what the last run retained, outside the timed region.
    func release() {
        releaseCall(engine)
    }
}
