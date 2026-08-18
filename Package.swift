// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "AnyRecKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
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
