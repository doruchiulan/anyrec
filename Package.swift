// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "anyrec",
    /// 15.2 is where `SCContentFilter` began reporting what is in it, which is how the
    /// menu bar's system picker turns a selection back into a `CaptureTarget`.
    platforms: [.macOS("15.2")],
    products: [
        .executable(name: "anyrec", targets: ["anyrec"]),
        .executable(name: "AnyRecBar", targets: ["AnyRecBar"]),
        .library(name: "AnyRecKit", targets: ["AnyRecKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        /// On-device speaker diarization (pyannote community-1 on CoreML) and the
        /// voiceprints that let a voice be named across calls. Nothing it does leaves
        /// the machine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "AnyRecKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "whisper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        /// whisper.cpp as the framework its own CI builds — universal, Metal, with the
        /// VAD API — so whisper runs inside the app and nothing has to be installed. Only
        /// the nightly `b####` builds carry the xcframework; this one is the code of
        /// v1.9.5, built the same day.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .executableTarget(
            name: "anyrec",
            dependencies: [
                "AnyRecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AnyRecBar",
            dependencies: ["AnyRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnyRecKitTests",
            dependencies: ["AnyRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnyRecTests",
            dependencies: ["anyrec"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnyRecBarTests",
            dependencies: ["AnyRecBar", "AnyRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
