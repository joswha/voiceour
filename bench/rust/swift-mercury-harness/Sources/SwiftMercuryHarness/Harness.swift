import Foundation

/// Bet B6: is the recording overlay's CPU mercury rasterizer faster in Rust than in Swift
/// at identical pixels?
///
///     swift-mercury-harness dump   [--out DIR] [--seeds N] [--motion-frames N]
///     swift-mercury-harness verify [--lib DYLIB] [--out FILE] [--arms a,b,...] [--seeds N] [--motion-frames N]
///     swift-mercury-harness time   [--lib DYLIB] [--out FILE] [--passes N] [--arms a,b,...]
///                                  [--rows seed,motion] [--seeds N] [--motion-frames N]
///
/// Arms: `swift` (the shipped rasterizer), `swift-simd` and `swift-simd-unchecked`
/// (raster_neon.rs's redesign in Swift SIMD types, built -O and -Ounchecked), and the
/// library's `mr_arms()` (`rust`, `rust-neon`). A Swift-side `name@aa` replicates `name`.
///
/// `dump` writes the inputs and the production Swift rasters for `mercury-replay`.
/// `verify` compares every `swift-simd` build and every Rust arm with the production bytes,
/// and the Rust library's component tables.
/// `time` writes contract timing rows: arms interleaved per row in a Williams order,
/// pass 0 warmup, every timed output checked against the production bytes.
///
/// Every command first proves the compiled production copies match the repository.
@main
@MainActor
struct SwiftMercuryHarness {
    static func main() {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try checkProductionSources(options)
            switch options.command {
            case "dump":
                try Dump.run(options)
            case "verify":
                if !(try Verification.run(options)) { exit(4) }
            case "time":
                try Timing.run(options)
            default:
                throw HarnessError.message("unknown command \(options.command); use dump, verify or time")
            }
        } catch {
            fputs("swift-mercury-harness: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Fails unless every compiled copy and its repository source still hash to the value
    /// recorded when the copy was made.
    static func checkProductionSources(_ options: Options) throws {
        var drift: [String] = []
        let target = options.harnessRoot.appending(path: "Sources/SwiftMercuryHarness")
        for file in ProductionSources.files {
            let repository = try Digest.sha256(file: options.repoRoot.appending(path: file.repository))
            let copy = try Digest.sha256(file: target.appending(path: file.copy))
            if repository != file.sha256 {
                drift.append("\(file.repository) changed since it was copied (\(repository) != \(file.sha256))")
            }
            if copy != file.sha256 {
                drift.append("\(file.copy) on disk is not the compiled copy (\(copy) != \(file.sha256))")
            }
        }
        guard drift.isEmpty else {
            throw HarnessError.message(
                "production sources drifted; run bench/rust/swift-mercury-harness/sync-production-sources.sh "
                    + "and rebuild:\n  " + drift.joined(separator: "\n  ")
            )
        }
    }
}

struct Options {
    var command = "verify"
    var repoRoot: URL
    var harnessRoot: URL
    var library: URL
    var output: URL?
    var passes = 10
    var seeds = 64
    var motionFrames = 1_200
    var arms: [String]?
    var rowKinds: [Corpus.Kind] = [.seed, .motion]

    var benchDirectory: URL { repoRoot.appending(path: ".build/rust-bench/mercury") }

    static func parse(_ arguments: [String]) throws -> Options {
        // This file sits at <repo>/bench/rust/swift-mercury-harness/Sources/SwiftMercuryHarness/.
        let source = URL(fileURLWithPath: #filePath)
        let harnessRoot = source.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var repoRoot = harnessRoot.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var library: URL?
        var options = Options(repoRoot: repoRoot, harnessRoot: harnessRoot, library: repoRoot)
        var remaining = arguments[...]
        if let first = remaining.first, !first.hasPrefix("-") {
            options.command = first
            remaining = remaining.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let next = remaining.popFirst() else { throw HarnessError.message("\(flag) needs a value") }
            return next
        }
        func count(_ flag: String) throws -> Int {
            guard let number = Int(try value(flag)), number >= 0 else {
                throw HarnessError.message("\(flag) needs a non-negative integer")
            }
            return number
        }
        while let flag = remaining.popFirst() {
            switch flag {
            case "--repo-root": repoRoot = URL(fileURLWithPath: try value(flag))
            case "--lib": library = URL(fileURLWithPath: try value(flag))
            case "--out": options.output = URL(fileURLWithPath: try value(flag))
            case "--passes": options.passes = try count(flag)
            case "--seeds": options.seeds = min(try count(flag), 64)
            case "--motion-frames": options.motionFrames = min(try count(flag), 1_200)
            case "--arms": options.arms = try value(flag).split(separator: ",").map(String.init)
            case "--rows":
                options.rowKinds = try value(flag).split(separator: ",").map { label in
                    guard let kind = Corpus.Kind(label: String(label)) else {
                        throw HarnessError.message("unknown row kind \(label); use seed, motion, seedic or pose")
                    }
                    return kind
                }
            default: throw HarnessError.message("unknown argument \(flag)")
            }
        }
        options.repoRoot = repoRoot
        options.library =
            library
            ?? repoRoot.appending(path: "bench/rust/mercury-raster/target/release/libmercury_raster.dylib")
        return options
    }
}
