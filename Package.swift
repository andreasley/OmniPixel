// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OmniPixel",
    platforms: [
        // The library itself only needs Foundation; the viewer's SwiftUI
        // interface sets the macOS floor. Linux is unaffected.
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OmniPixel",
            targets: ["OmniPixel"]
        ),
        .executable(
            name: "OmniPixelViewer",
            targets: ["OmniPixelViewer"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "OmniPixel",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "OmniPixelViewer",
            dependencies: ["OmniPixel"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "OmniPixelTests",
            dependencies: ["OmniPixel"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        // Randomized robustness testing. Its suites are skipped unless
        // selected, so the everyday suite stays fast; see the target's README.
        .testTarget(
            name: "OmniPixelFuzzTests",
            dependencies: ["OmniPixel"],
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
