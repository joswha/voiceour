// swift-tools-version: 6.4
import PackageDescription

// Bet B3 Swift harness: runs the production post-ASR text path from VoiceCore (the
// exact shipped code, built in release) over the same inputs as the Rust port in
// ../voiceour-text, and dumps the Swift/Foundation/ICU Unicode tables that port is
// generated from. Benchmark-only; nothing here is linked into the app.
let package = Package(
    name: "SwiftTextHarness",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "swift-text-bench", targets: ["SwiftTextBench"])
    ],
    dependencies: [
        .package(name: "voiceour", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "SwiftTextBench",
            dependencies: [.product(name: "VoiceCore", package: "voiceour")]
        )
    ]
)
