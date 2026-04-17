// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReelabsMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "ReelabsMCPLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/ReelabsMCPLib",
            resources: [
                .copy("Resources/CLAUDE.md"),
                .copy("Resources/flows"),
                .copy("Resources/presets"),
                .copy("Resources/reference"),
            ]
        ),
        .executableTarget(
            name: "ReelabsMCP",
            dependencies: [
                "ReelabsMCPLib",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ReelabsMCP"
        ),
        .testTarget(
            name: "ReelabsMCPTests",
            dependencies: ["ReelabsMCPLib"],
            path: "Tests/ReelabsMCPTests"
        ),
    ]
)
