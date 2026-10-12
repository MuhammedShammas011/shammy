// Package.swift
// MacLink – Swift Package
// Defines the shared Protocol library and both executable targets.
// Open this package in Xcode to build both apps.

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacLink",
    platforms: [
        .macOS(.v13),   // ScreenCaptureKit requires 12.3; CryptoKit in Swift 5 requires 13+
        .iOS(.v16)
    ],
    products: [
        .library(name: "MacLinkProtocol", targets: ["MacLinkProtocol"]),
        .executable(name: "MacLinkHost",   targets: ["MacLinkHost"]),
        .executable(name: "MacLinkClient", targets: ["MacLinkClient"]),
    ],
    dependencies: [],
    targets: [
        // MARK: Shared protocol
        .target(
            name: "MacLinkProtocol",
            path: "shared/Protocol",
            swiftSettings: [
                .define("MACLINK_SHARED")
            ]
        ),

        // MARK: macOS host
        .executableTarget(
            name: "MacLinkHost",
            dependencies: ["MacLinkProtocol"],
            path: "macos/MacLinkHost",
            exclude: ["Resources"],
            swiftSettings: [
                .define("os_macOS")
            ]
        ),

        // MARK: iOS client
        .executableTarget(
            name: "MacLinkClient",
            dependencies: ["MacLinkProtocol"],
            path: "ios/MacLinkClient",
            exclude: ["Resources"],
            swiftSettings: [
                .define("os_iOS")
            ]
        ),

        // MARK: Tests
        .testTarget(
            name: "MacLinkTests",
            dependencies: ["MacLinkProtocol"],
            path: "tests"
        ),
    ]
)
