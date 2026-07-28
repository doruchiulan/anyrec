// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "anyrec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "anyrec", targets: ["anyrec"]),
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
    ]
)
