// swift-tools-version: 6.4
import PackageDescription

// Bet B6 Swift harness: compiles verbatim copies of the production mercury raster sources
// (see sync-production-sources.sh; drift fails at startup), generates the production
// benchmark's inputs, and times the shipped `MercuryRasterizer` interleaved with the Rust
// port in ../mercury-raster loaded through dlopen. Benchmark-only; nothing here is linked
// into the app. Build with `swift build -c release`, the configuration the app ships in.
//
// The `swift-simd` control arms live in their own modules so one source can be compiled
// two ways: Sources/MercurySimd/SwiftNeonRaster.swift is raster_neon.rs's redesign written
// with Swift SIMD types. Both modules compile it together with the same verbatim
// production copies and shim (symlinks into Sources/SwiftMercuryHarness), so the only
// difference between `swift-simd` (MercurySimd, release -O) and `swift-simd-unchecked`
// (MercurySimdUnchecked, -Ounchecked) is the optimization mode.
let voiceCore = Target.Dependency.product(name: "VoiceCore", package: "voiceour")

let package = Package(
    name: "SwiftMercuryHarness",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "swift-mercury-harness", targets: ["SwiftMercuryHarness"])
    ],
    dependencies: [
        .package(name: "voiceour", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "SwiftMercuryHarness",
            dependencies: [voiceCore, "MercurySimd", "MercurySimdUnchecked"]
        ),
        .target(name: "MercurySimd", dependencies: [voiceCore]),
        .target(
            name: "MercurySimdUnchecked",
            dependencies: [voiceCore],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
    ]
)
