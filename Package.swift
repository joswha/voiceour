// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voiceoour",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceOour", targets: ["VoiceOour"]),
        .executable(name: "voiceoour-bench", targets: ["VoiceOourBench"]),
        .executable(name: "voiceoour-capture-bench", targets: ["VoiceOourCaptureBench"]),
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .library(name: "VoiceMac", targets: ["VoiceMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170")
    ],
    targets: [
        .executableTarget(
            name: "VoiceOour",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .target(name: "VoiceCore"),
        .target(
            name: "VoiceMac",
            dependencies: ["VoiceCore"]
        ),
        .executableTarget(
            name: "VoiceOourBench",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .executableTarget(
            name: "VoiceOourCaptureBench",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .testTarget(
            name: "VoiceCoreTests",
            dependencies: [
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "VoiceMacTests",
            dependencies: [
                "VoiceMac",
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "VoiceOourTests",
            dependencies: [
                "VoiceOour",
                "VoiceMac",
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
