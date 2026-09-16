// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Apple27Prototypes",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "apple27-speech", targets: ["SpeechLab"]),
        .executable(name: "apple27-foundation", targets: ["FoundationLab"]),
        .executable(name: "apple27-coreai", targets: ["CoreAILab"])
    ],
    dependencies: [
        .package(name: "voiceour", path: "../.."),
        .package(name: "coreai-models", path: "../../.build/apple27/upstream/coreai-models")
    ],
    targets: [
        .target(
            name: "PrototypeSupport",
            dependencies: [.product(name: "VoiceCore", package: "voiceour")]
        ),
        .executableTarget(name: "SpeechLab", dependencies: ["PrototypeSupport"]),
        .executableTarget(name: "FoundationLab", dependencies: ["PrototypeSupport"]),
        .executableTarget(
            name: "CoreAILab",
            dependencies: [
                "PrototypeSupport",
                .product(name: "CoreAISpeech", package: "coreai-models")
            ]
        )
    ]
)
