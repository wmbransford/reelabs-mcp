// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReelabsMCP",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReelabsMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ReelabsMCP",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReelabsMCPTests",
            dependencies: ["ReelabsMCP"],
            path: "Tests/ReelabsMCPTests"
        ),
    ]
)
