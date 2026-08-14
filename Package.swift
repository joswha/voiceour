// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voiceour",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voiceour", targets: ["Voiceour"]),
        .executable(name: "voiceour-bench", targets: ["VoiceourBench"]),
        .executable(name: "voiceour-capture-bench", targets: ["VoiceourCaptureBench"]),
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .library(name: "VoiceMac", targets: ["VoiceMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170")
    ],
    targets: [
        .executableTarget(
            name: "Voiceour",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .target(name: "VoiceCore"),
        .target(
            name: "VoiceMac",
            dependencies: ["VoiceCore"]
        ),
        .executableTarget(
            name: "VoiceourBench",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .executableTarget(
            name: "VoiceourCaptureBench",
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
            name: "VoiceourTests",
            dependencies: [
                "Voiceour",
                "VoiceMac",
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
