import CoreGraphics
import CryptoKit
import Darwin
import Foundation

enum Raster {
    static let width = 360
    static let height = 68
    static let bytesPerRow = width * 4
    static let byteCount = bytesPerRow * height

    /// The image's bytes, copied out so neither the image nor its provider outlives the
    /// call: the next raster into the same bitmap context must never pay a copy-on-write.
    static func bytes(of image: CGImage?) throws -> [UInt8]? {
        guard let image else { return nil }
        guard
            image.width == width, image.height == height, image.bytesPerRow == bytesPerRow,
            image.bitsPerPixel == 32, image.alphaInfo == .premultipliedLast
        else {
            throw HarnessError.message(
                "unexpected image layout \(image.width)x\(image.height), \(image.bytesPerRow) bytes per row"
            )
        }
        guard let data = image.dataProvider?.data else {
            throw HarnessError.message("image has no data provider")
        }
        let length = CFDataGetLength(data)
        guard length >= byteCount else {
            throw HarnessError.message("image provides \(length) bytes, expected \(byteCount)")
        }
        return [UInt8](unsafeUninitializedCapacity: byteCount) { buffer, count in
            CFDataGetBytes(data, CFRange(location: 0, length: byteCount), buffer.baseAddress)
            count = byteCount
        }
    }

    struct Comparison {
        var differingBytes = 0
        var maxAbs = 0
        var relativeL2 = 0.0

        var identical: Bool { differingBytes == 0 }
    }

    static func compare(_ actual: [UInt8], _ expected: [UInt8]) -> Comparison {
        guard actual.count == expected.count else {
            return Comparison(differingBytes: max(actual.count, expected.count), maxAbs: 255, relativeL2: .infinity)
        }
        let equal = actual.withUnsafeBytes { left in
            expected.withUnsafeBytes { right in memcmp(left.baseAddress, right.baseAddress, left.count) == 0 }
        }
        if equal { return Comparison() }
        var comparison = Comparison()
        var errorSquares = 0.0
        var referenceSquares = 0.0
        for index in 0..<actual.count {
            let difference = Int(actual[index]) - Int(expected[index])
            referenceSquares += Double(expected[index]) * Double(expected[index])
            guard difference != 0 else { continue }
            comparison.differingBytes += 1
            comparison.maxAbs = max(comparison.maxAbs, abs(difference))
            errorSquares += Double(difference * difference)
        }
        comparison.relativeL2 = referenceSquares > 0 ? (errorSquares / referenceSquares).squareRoot() : .infinity
        return comparison
    }
}

enum Digest {
    static func sha256(_ bytes: [UInt8]) -> String {
        hex(SHA256.hash(data: bytes))
    }

    static func sha256(file: URL) throws -> String {
        hex(SHA256.hash(data: try Data(contentsOf: file)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(64)
        for byte in digest {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }
}

/// SplitMix64 for probe inputs: deterministic and independent of the production streams.
struct ProbeRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    /// Uniform on `[low, high)`.
    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * (Double(next() >> 11) * 0x1p-53)
    }

    mutating func unitVector() -> SIMD3<Float> {
        let height = uniform(-1, 1)
        let angle = uniform(0, 2 * .pi)
        let radius = (1 - height * height).squareRoot()
        return SIMD3(Float(radius * cos(angle)), Float(radius * sin(angle)), Float(height))
    }
}

/// Machine description for `run_meta` and reports.
enum Host {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func sysctlInteger(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == 4 || size == 8 else { return nil }
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func powerSource() -> String {
        guard let output = run("/usr/bin/pmset", ["-g", "batt"]),
            let start = output.range(of: "'"),
            let end = output[start.upperBound...].range(of: "'")
        else { return "unknown" }
        return String(output[start.upperBound..<end.lowerBound])
    }

    static func description() -> [String: Any] {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        return [
            "chip": sysctlString("machdep.cpu.brand_string") ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "os_build": sysctlString("kern.osversion") ?? "unknown",
            "power": powerSource(),
            "load_avg": load,
            "cpu_threads": sysctlInteger("hw.logicalcpu") ?? 0,
            "perf_cores": sysctlInteger("hw.perflevel0.physicalcpu") ?? 0,
            "eff_cores": sysctlInteger("hw.perflevel1.physicalcpu") ?? 0,
            "memory_bytes": sysctlInteger("hw.memsize") ?? 0,
        ]
    }

    static func gitSHA(repository: URL) -> String {
        run("/usr/bin/git", ["-C", repository.path, "rev-parse", "HEAD"]) ?? "unknown"
    }
}

enum JSON {
    static func line(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

/// Little-endian binary writer for the replay dump.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ value: Double) { u64(value.bitPattern) }
    mutating func f32s(_ values: [Float]) {
        for value in values { u32(value.bitPattern) }
    }
}
