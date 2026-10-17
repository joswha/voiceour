import CryptoKit
import Darwin
import Foundation
import VoiceCore

/// One utterance: `{"id", "text"}` per JSONL line (same files as the Rust `text-bench`).
struct Case: Decodable {
    let id: String
    let text: String
}

/// `{"name", "terms": [ProtectedTerm]}`; terms decode through the app's own `Codable`.
struct GlossaryFile: Decodable {
    let name: String
    let terms: [ProtectedTerm]
}

enum IO {
    static func readCases(_ path: String) throws -> [Case] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        var cases: [Case] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            cases.append(try decoder.decode(Case.self, from: Data(line)))
        }
        return cases
    }

    static func readGlossary(_ path: String) throws -> GlossaryFile {
        try JSONDecoder().decode(GlossaryFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(data: Data(text.utf8))
    }

    static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func jsonLine(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func readJSONLines(_ path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map {
            try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:]
        }
    }

    /// Writes lines through one buffered handle.
    static func writeLines(_ lines: [String], to path: String) throws {
        var data = Data()
        data.reserveCapacity(lines.reduce(0) { $0 + $1.utf8.count + 1 })
        for line in lines {
            data.append(contentsOf: line.utf8)
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func uptimeNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

/// SplitMix64, bit-identical to the Rust harness's, so both visit rows in the same order.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        let bound = UInt64(bound)
        let zone = UInt64.max - (UInt64.max % bound)
        while true {
            let value = next()
            if value < zone { return Int(value % bound) }
        }
    }

    mutating func shuffle<T>(_ items: inout [T]) {
        guard items.count > 1 else { return }
        for index in stride(from: items.count - 1, through: 1, by: -1) {
            items.swapAt(index, below(index + 1))
        }
    }

    static func passOrder(rows: Int, pass: Int, seed: UInt64) -> [Int] {
        var order = Array(0..<rows)
        var rng = SplitMix64(state: seed ^ (UInt64(pass) &* 0xA24B_AED4_963E_E407))
        rng.shuffle(&order)
        return order
    }
}

enum Host {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func meta() -> [String: Any] {
        var load = [Double](repeating: 0, count: 3)
        let loaded = getloadavg(&load, 3)
        let battery = run("/usr/bin/pmset", ["-g", "batt"]) ?? ""
        let power = battery.contains("AC Power") ? "AC" : battery.contains("Battery Power") ? "battery" : "unknown"
        return [
            "chip": sysctlString("machdep.cpu.brand_string") as Any,
            "os": sysctlString("kern.osproductversion") as Any,
            "os_build": sysctlString("kern.osversion") as Any,
            "power": power,
            "load_avg": loaded == 3 ? load : [],
            "cpu_threads": sysctlInt("hw.ncpu") as Any,
            "perf_cores": sysctlInt("hw.perflevel0.physicalcpu") as Any,
            "eff_cores": sysctlInt("hw.perflevel1.physicalcpu") as Any,
            "memory_bytes": sysctlInt("hw.memsize") as Any,
        ]
    }

    static func gitSHA(repo: String) -> String? {
        run("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"])
    }

    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

/// Minimal `--key value` argument parsing, as the Rust harness does it.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            if raw[index].hasPrefix("--") {
                options[String(raw[index].dropFirst(2))] = index + 1 < raw.count ? raw[index + 1] : ""
                index += 2
            } else {
                positional.append(raw[index])
                index += 1
            }
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = options[key] else { throw HarnessError.message("missing --\(key)") }
        return value
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        options[key].flatMap(Int.init) ?? fallback
    }
}
