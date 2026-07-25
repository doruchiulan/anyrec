// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "slack-rec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "slack-rec", targets: ["slack-rec"]),
        .library(name: "SlackRecKit", targets: ["SlackRecKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SlackRecKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "slack-rec",
            dependencies: [
                "SlackRecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SlackRecKitTests",
            dependencies: ["SlackRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
