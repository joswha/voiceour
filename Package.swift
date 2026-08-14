// swift-tools-version: 5.9
import PackageDescription

// Feature guards for the vendored ggml/parakeet.cpp sources under Vendor/parakeet.
// They mirror the upstream CMake configuration this vendor drop was verified against:
// -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON with the Accelerate vendor.
// The union of per-CMake-target defines is safe on one SwiftPM target: they are feature
// guards, and ggml-backend-reg.cpp needs GGML_USE_{CPU,BLAS,METAL} to register backends.
let sharedDefines: [(String, String?)] = [
    ("_DARWIN_C_SOURCE", nil),
    ("GGML_SCHED_MAX_COPIES", "4"),
    ("GGML_USE_CPU", nil),
    ("GGML_USE_BLAS", nil),
    ("GGML_USE_METAL", nil)
]

let ggmlDefines: [(String, String?)] = sharedDefines + [
    // CMake-generated in upstream (ggml/CMakeLists.txt:6-9, :410-411); pinned here because
    // SwiftPM has no configure step. Values are ggml 0.19.0 at whisper.cpp 592feef0.
    ("GGML_VERSION", "\"0.19.0\""),
    ("GGML_COMMIT", "\"592feef04a1802b18cbeffd0fd0eb5d02570c2ec\""),
    ("GGML_USE_ACCELERATE", nil),
    ("GGML_USE_CPU_REPACK", nil),
    ("ACCELERATE_NEW_LAPACK", nil),
    ("ACCELERATE_LAPACK_ILP64", nil),
    ("GGML_BLAS_USE_ACCELERATE", nil),
    ("GGML_METAL_EMBED_LIBRARY", nil)
]

// "embed" carries ggml-metal-embed.metal, which ggml-metal-embed.c pulls in with .incbin;
// the assembler resolves that name through -I, so the directory must be searchable.
let ggmlHeaderPaths = ["src", "src/ggml-cpu", "src/ggml-metal", "embed"]

let ggmlCSettings: [CSetting] =
    ggmlDefines.map { CSetting.define($0.0, to: $0.1) }
    + ggmlHeaderPaths.map { CSetting.headerSearchPath($0) }
    + [
        // ggml-metal-device.m / ggml-metal-context.m are manual retain/release.
        // SwiftPM compiles .m with ARC on by default, which upstream CMake does not.
        .unsafeFlags(["-fno-objc-arc"]),
        .define("NDEBUG", .when(configuration: .release))
    ]

let ggmlCxxSettings: [CXXSetting] =
    ggmlDefines.map { CXXSetting.define($0.0, to: $0.1) }
    + ggmlHeaderPaths.map { CXXSetting.headerSearchPath($0) }
    + [.define("NDEBUG", .when(configuration: .release))]

let parakeetDefines: [(String, String?)] = sharedDefines + [
    ("PARAKEET_VERSION", "\"1.9.2\"")
]

let parakeetCSettings: [CSetting] =
    parakeetDefines.map { CSetting.define($0.0, to: $0.1) }
    + [.define("NDEBUG", .when(configuration: .release))]

let parakeetCxxSettings: [CXXSetting] =
    parakeetDefines.map { CXXSetting.define($0.0, to: $0.1) }
    + [.define("NDEBUG", .when(configuration: .release))]

let package = Package(
    name: "voiceour",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voiceour", targets: ["Voiceour"]),
        .executable(name: "voiceour-bench", targets: ["VoiceourBench"]),
        .executable(name: "voiceour-capture-bench", targets: ["VoiceourCaptureBench"]),
        .executable(name: "voiceour-asr", targets: ["VoiceourASR"]),
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .library(name: "VoiceMac", targets: ["VoiceMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170")
    ],
    targets: [
        .target(
            name: "CGgml",
            path: "Vendor/parakeet/ggml",
            exclude: [
                "embed/ggml-metal-embed.metal",
                "embed/regenerate.sh",
                "src/ggml-metal/ggml-metal.metal"
            ],
            sources: ["src", "embed"],
            publicHeadersPath: "include",
            cSettings: ggmlCSettings,
            cxxSettings: ggmlCxxSettings,
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        ),
        .target(
            name: "CParakeet",
            dependencies: ["CGgml"],
            path: "Vendor/parakeet",
            exclude: ["ggml", "NOTICE.md", "LICENSE"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: parakeetCSettings,
            cxxSettings: parakeetCxxSettings,
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(
            name: "Voiceour",
            dependencies: ["VoiceCore", "VoiceMac"]
        ),
        .target(name: "VoiceCore"),
        .target(
            name: "VoiceMac",
            dependencies: ["VoiceCore"]
        ),
        .target(
            name: "ASRSidecarCore",
            dependencies: ["VoiceCore", "CParakeet"]
        ),
        .executableTarget(
            name: "VoiceourASR",
            dependencies: ["ASRSidecarCore", "VoiceCore"]
        ),
        .executableTarget(
            name: "ASRSidecarStub",
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
        ),
        .testTarget(
            name: "ASRSidecarCoreTests",
            dependencies: [
                "ASRSidecarCore",
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "VoiceourASRTests",
            dependencies: [
                "VoiceCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx17
)
